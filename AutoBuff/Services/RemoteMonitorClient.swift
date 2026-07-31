import CoreGraphics
import Foundation

private struct RemoteMonitorStoredCredentials: Codable {
    var accessToken: String?
    var clientID: String?
    var clientName: String?
}

struct RemoteMonitorLocalStore {
    static let shared = RemoteMonitorLocalStore()

    private let directoryURL: URL

    init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            self.directoryURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("AutoBuff", isDirectory: true)
        }
    }

    var fileURL: URL {
        directoryURL.appendingPathComponent("remote-monitor.json", isDirectory: false)
    }

    private func load() -> RemoteMonitorStoredCredentials? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(RemoteMonitorStoredCredentials.self, from: data)
    }

    private func save(_ credentials: RemoteMonitorStoredCredentials) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        let data = try JSONEncoder().encode(credentials)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    func loadToken() -> String? {
        load()?.accessToken
    }

    func saveToken(_ token: String) throws {
        var credentials = load() ?? RemoteMonitorStoredCredentials()
        credentials.accessToken = token
        try save(credentials)
    }

    func loadOrCreateIdentity() throws -> (id: String, name: String?) {
        var credentials = load() ?? RemoteMonitorStoredCredentials()
        if credentials.clientID == nil {
            credentials.clientID = UUID().uuidString.lowercased()
            try save(credentials)
        }
        return (credentials.clientID!, credentials.clientName)
    }

    func saveClientName(_ name: String) throws {
        var credentials = load() ?? RemoteMonitorStoredCredentials()
        credentials.clientName = name
        try save(credentials)
    }

    func deleteCredentials() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func deleteAccessToken() {
        guard var credentials = load() else { return }
        credentials.accessToken = nil
        try? save(credentials)
    }
}

enum RemoteMonitorError: LocalizedError {
    case invalidServerURL
    case invalidResponse
    case server(String)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: return "监控服务器地址无效"
        case .invalidResponse: return "监控服务器返回了无效数据"
        case .server(let message): return message
        case .notAuthenticated: return "请先登录监控账号"
        }
    }
}

private struct RemoteAuthRequest: Encodable {
    let username: String
    let password: String
}

private struct RemoteUser: Codable {
    let id: Int64
    let username: String
}

private struct RemoteAuthResponse: Decodable {
    let accessToken: String
    let expiresAt: Int64
    let user: RemoteUser
}

private struct RemoteClientBindRequest: Encodable {
    let clientId: String
}

private struct RemoteClientBindResponse: Decodable {
    let id: String
    let clientId: String
    let name: String
}

private struct RemoteAPIError: Decodable {
    let message: String
}

private struct RemoteEnvelope<Payload: Encodable>: Encodable {
    let type: String
    let sequence: UInt64
    let payload: Payload
}

private struct RemoteMapPayload: Encodable {
    struct Platform: Encodable {
        let id: String
        let points: [NormalizedMapPoint]
    }
    struct Rope: Encodable {
        let id: String
        let x: Double
        let topY: Double
        let bottomY: Double
    }
    struct Portal: Encodable {
        let id: String
        let point: NormalizedMapPoint
        let type: String
    }

    let id: String
    let name: String
    let aspectRatio: Double
    let platforms: [Platform]
    let ropes: [Rope]
    let portals: [Portal]
}

private struct RemoteFramePayload: Encodable {
    let player: NormalizedMapPoint?
    let teammates: [NormalizedMapPoint]
    let others: [NormalizedMapPoint]
    let sourceFPS: Double
    let capturedAt: Int64
}

private struct RemoteStatusPayload: Encodable {
    let online: Bool
    let message: String
}

private struct RemoteEXPPayload: Encodable {
    let currentEXP: Int?
    let percent: Double?
    let confidence: Double?
    let status: String
    let recognizedAt: Int64
}

private struct RemoteRunePayload: Encodable {
    let detected: Bool
    let confidence: Double?
    let detectedAt: Int64
}

private struct RemoteZoneRect: Encodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct RemoteZonePayload: Encodable {
    let outside: Bool
    let rect: RemoteZoneRect?
    let detectedAt: Int64
}

private struct RemoteClientStatePayload: Encodable {
    let mode: String
    let running: Bool
}

private struct RemoteServerMessage: Decodable {
    let type: String
    let clientId: String?
    let name: String?
    let action: String?
}

/// 布尔型监控状态（符文提示、安全区越界）的上报节奏。
///
/// 状态一变化就立刻发送，让服务器第一时间知道；状态没变化时按心跳间隔
/// 重发，服务器据此判断数据是否新鲜，客户端掉线后不会被当成状态仍然成立。
enum MonitorStatePublishPolicy {
    static let heartbeatInterval = Duration.seconds(3)

    static func shouldSend(
        isActive: Bool,
        lastSentState: Bool?,
        sinceLastSend: Duration
    ) -> Bool {
        guard let lastSentState else { return true }
        return lastSentState != isActive || sinceLastSend >= heartbeatInterval
    }
}

@MainActor
final class RemoteMonitorClient {
    private(set) var accessToken: String?
    private(set) var username: String?
    private(set) var clientID: String?
    private(set) var clientName: String?
    var onIdentity: ((String) -> Void)?
    var onCommand: ((String) -> Void)?
    private var baseURL = ""
    private var socket: URLSessionWebSocketTask?
    private var publisherURL: URL?
    private var publisherEnabled = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var sequence: UInt64 = 0
    private var lastFrameSentAt = ContinuousClock.now - .seconds(1)
    private var lastMapID: String?
    private var isSendInProgress = false
    private var pendingControlMessages: [Data] = []
    private var pendingFrameMessage: Data?
    private var pendingEXPMessage: Data?
    private var pendingRuneMessage: Data?
    private var lastRuneState: Bool?
    private var lastRuneSentAt = ContinuousClock.now
    private var pendingZoneMessage: Data?
    private var lastZoneState: Bool?
    private var lastZoneSentAt = ContinuousClock.now
    private var latestMode = "dead"
    private var latestRunning = false

    func loadStoredAccessToken() async -> String? {
        await Task.detached(priority: .utility) {
            RemoteMonitorLocalStore.shared.loadToken()
        }.value
    }

    func authenticate(baseURL: String, username: String, password: String) async throws -> String {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let response: RemoteAuthResponse = try await request(
            path: "/api/auth/login",
            method: "POST",
            body: RemoteAuthRequest(username: username, password: password),
            authenticated: false
        )
        accessToken = response.accessToken
        self.username = response.user.username
        do {
            try await prepareLocalIdentity()
            try await bindCurrentClient()
            try await Task.detached(priority: .utility) {
                try RemoteMonitorLocalStore.shared.saveToken(response.accessToken)
            }.value
            return response.user.username
        } catch {
            RemoteMonitorLocalStore.shared.deleteAccessToken()
            accessToken = nil
            self.username = nil
            throw error
        }
    }

    func restore(baseURL: String, storedToken: String) async throws -> String {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        accessToken = storedToken
        do {
            let user: RemoteUser = try await request(
                path: "/api/auth/me",
                method: "GET",
                body: Optional<String>.none,
                authenticated: true
            )
            username = user.username
            try await prepareLocalIdentity()
            try await validateCurrentClient()
            return user.username
        } catch {
            logout()
            throw error
        }
    }

    func connectPublisher() throws {
        guard let accessToken else {
            throw RemoteMonitorError.notAuthenticated
        }
        guard var components = URLComponents(string: baseURL) else {
            throw RemoteMonitorError.invalidServerURL
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/ws/device"
        guard let clientID else {
            throw RemoteMonitorError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "client_id", value: clientID)]
        components.fragment = nil
        guard let url = components.url else {
            throw RemoteMonitorError.invalidServerURL
        }
        disconnectPublisher(sendOffline: false)
        publisherURL = url
        publisherEnabled = true
        reconnectAttempt = 0
        startPublisherSocket(url: url, accessToken: accessToken)
    }

    private func startPublisherSocket(url: URL, accessToken: String) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        resetSendQueue()
        sequence = 0
        lastMapID = nil
        lastFrameSentAt = .now - .seconds(1)
        task.resume()
        sendStatus(online: true, message: "客户端已连接")
        publishClientState(mode: latestMode, running: latestRunning)
        Task { [weak self, weak task] in
            guard let self, let task else { return }
            do {
                while publisherEnabled, socket === task {
                    let message = try await task.receive()
                    self.handleServerMessage(message)
                }
            } catch {
                handlePublisherDisconnected(task)
            }
        }
    }

    func publishClientState(mode: String, running: Bool) {
        latestMode = mode
        latestRunning = running
        send(
            type: "client_state",
            payload: RemoteClientStatePayload(mode: mode, running: running)
        )
    }

    func publish(frame: MonitoringFrame) {
        guard socket != nil else { return }
        let contentSize = CGSize(width: frame.buffer.width, height: frame.buffer.height)
        guard contentSize.width > 0, contentSize.height > 0 else { return }

        if let topology = frame.matchedTopology {
            let displayName = topology.mapName.isEmpty ? "未命名地图" : topology.mapName
            let mapID = topology.mapName.isEmpty
                ? "map-\(topology.referenceWidth)x\(topology.referenceHeight)"
                : topology.mapName
            if lastMapID != mapID {
                let payload = RemoteMapPayload(
                    id: mapID,
                    name: displayName,
                    aspectRatio: Double(contentSize.width / contentSize.height),
                    platforms: topology.platforms.map {
                        .init(id: $0.id.uuidString, points: $0.points)
                    },
                    ropes: topology.ropes.map {
                        .init(id: $0.id.uuidString, x: $0.x, topY: $0.topY, bottomY: $0.bottomY)
                    },
                    portals: topology.portals.map {
                        .init(id: $0.id.uuidString, point: $0.point, type: $0.type.rawValue)
                    }
                )
                send(type: "map", payload: payload)
                lastMapID = mapID
            }
        }

        guard lastFrameSentAt.duration(to: .now) >= .milliseconds(100) else { return }
        lastFrameSentAt = .now
        let payload = RemoteFramePayload(
            player: frame.playerPoint.map { NormalizedMapPoint($0, in: contentSize) },
            teammates: frame.teammatePoints.map { NormalizedMapPoint($0, in: contentSize) },
            others: frame.otherPlayerPoints.map { NormalizedMapPoint($0, in: contentSize) },
            sourceFPS: frame.framesPerSecond,
            capturedAt: Int64(Date().timeIntervalSince1970 * 1000)
        )
        send(type: "frame", payload: payload)
    }

    func publishEXP(reading: EXPRecognitionResult?, status: String) {
        guard socket != nil else { return }
        send(
            type: "exp",
            payload: RemoteEXPPayload(
                currentEXP: reading?.currentEXP,
                percent: reading?.percent,
                confidence: reading?.confidence,
                status: status,
                recognizedAt: Int64(Date().timeIntervalSince1970 * 1000)
            )
        )
    }

    func publishRuneAlert(isPresent: Bool, detection: RuneAlertDetection?) {
        guard socket != nil else { return }
        guard MonitorStatePublishPolicy.shouldSend(
            isActive: isPresent,
            lastSentState: lastRuneState,
            sinceLastSend: lastRuneSentAt.duration(to: .now)
        ) else {
            return
        }
        lastRuneState = isPresent
        lastRuneSentAt = .now
        send(
            type: "rune",
            payload: RemoteRunePayload(
                detected: isPresent,
                confidence: isPresent ? detection?.confidence : nil,
                detectedAt: Int64(Date().timeIntervalSince1970 * 1000)
            )
        )
    }

    /// 上报安全区状态。`zone` 为 nil 表示用户没有配置安全区，
    /// 此时发一条不带矩形的「未越界」，让网页停止画框。
    func publishZone(isOutside: Bool, zone: MonitorSafeZone?) {
        guard socket != nil else { return }
        guard MonitorStatePublishPolicy.shouldSend(
            isActive: isOutside,
            lastSentState: lastZoneState,
            sinceLastSend: lastZoneSentAt.duration(to: .now)
        ) else {
            return
        }
        lastZoneState = isOutside
        lastZoneSentAt = .now
        let rect = zone?.normalizedRect
        send(
            type: "zone",
            payload: RemoteZonePayload(
                outside: isOutside,
                rect: rect.map {
                    RemoteZoneRect(
                        x: $0.minX,
                        y: $0.minY,
                        width: $0.width,
                        height: $0.height
                    )
                },
                detectedAt: Int64(Date().timeIntervalSince1970 * 1000)
            )
        )
    }

    func disconnectPublisher(sendOffline: Bool = true) {
        if sendOffline {
            sendStatus(online: false, message: "本机监控已停止")
        }
        publisherEnabled = false
        reconnectTask?.cancel()
        reconnectTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        resetSendQueue()
        publisherURL = nil
        lastMapID = nil
    }

    func logout() {
        disconnectPublisher(sendOffline: false)
        RemoteMonitorLocalStore.shared.deleteAccessToken()
        accessToken = nil
        username = nil
    }

    private func sendStatus(online: Bool, message: String) {
        send(type: "status", payload: RemoteStatusPayload(online: online, message: message))
    }

    private func prepareLocalIdentity() async throws {
        let identity = try await Task.detached(priority: .utility) {
            try RemoteMonitorLocalStore.shared.loadOrCreateIdentity()
        }.value
        clientID = identity.id
        clientName = identity.name
        if let name = identity.name {
            onIdentity?(name)
        }
    }

    private func bindCurrentClient() async throws {
        guard let clientID else {
            throw RemoteMonitorError.invalidResponse
        }
        let response: RemoteClientBindResponse = try await request(
            path: "/api/clients/bind",
            method: "POST",
            body: RemoteClientBindRequest(clientId: clientID),
            authenticated: true
        )
        clientName = response.name
        onIdentity?(response.name)
        try await Task.detached(priority: .utility) {
            try RemoteMonitorLocalStore.shared.saveClientName(response.name)
        }.value
    }

    private func validateCurrentClient() async throws {
        guard let clientID,
              var components = URLComponents(string: baseURL + "/api/clients/authorization")
        else {
            throw RemoteMonitorError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "client_id", value: clientID)]
        guard let url = components.url else {
            throw RemoteMonitorError.invalidServerURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let accessToken else {
            throw RemoteMonitorError.notAuthenticated
        }
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteMonitorError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? JSONDecoder().decode(RemoteAPIError.self, from: data)
            throw RemoteMonitorError.server(
                apiError?.message ?? "客户端授权检查失败（\(httpResponse.statusCode)）"
            )
        }
    }

    private func handleServerMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let value):
            data = value
        case .string(let value):
            guard let value = value.data(using: .utf8) else { return }
            data = value
        @unknown default:
            return
        }
        guard let decoded = try? JSONDecoder().decode(RemoteServerMessage.self, from: data) else {
            return
        }
        if decoded.type == "identity", let name = decoded.name {
            // The server identity confirms that the reconnect completed.
            // A later transient failure should restart at the shortest delay.
            reconnectAttempt = 0
            clientName = name
            onIdentity?(name)
            Task.detached(priority: .utility) {
                try? RemoteMonitorLocalStore.shared.saveClientName(name)
            }
        } else if decoded.type == "command", let action = decoded.action {
            onCommand?(action)
        }
    }

    private func handlePublisherDisconnected(_ task: URLSessionWebSocketTask) {
        guard publisherEnabled, socket === task,
              let publisherURL, let accessToken else { return }
        socket = nil
        resetSendQueue()
        reconnectTask?.cancel()
        let delaySeconds = min(15, 1 << min(reconnectAttempt, 4))
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard let self, !Task.isCancelled, publisherEnabled else { return }
            startPublisherSocket(url: publisherURL, accessToken: accessToken)
        }
    }

    private func send<Payload: Encodable>(type: String, payload: Payload) {
        guard socket != nil else { return }
        sequence += 1
        do {
            let data = try JSONEncoder().encode(
                RemoteEnvelope(type: type, sequence: sequence, payload: payload)
            )
            switch type {
            case "frame":
                pendingFrameMessage = data
            case "exp":
                pendingEXPMessage = data
            case "rune":
                pendingRuneMessage = data
            case "zone":
                pendingZoneMessage = data
            default:
                pendingControlMessages.append(data)
                if pendingControlMessages.count > 4 {
                    pendingControlMessages.removeFirst(
                        pendingControlMessages.count - 4
                    )
                }
            }
            drainSendQueue()
        } catch {
            return
        }
    }

    private func drainSendQueue() {
        guard !isSendInProgress, let socket else { return }
        let message: Data
        if !pendingControlMessages.isEmpty {
            message = pendingControlMessages.removeFirst()
        } else if let pendingRuneMessage {
            // 告警类消息最紧急，排在 EXP 和位置帧之前。
            message = pendingRuneMessage
            self.pendingRuneMessage = nil
        } else if let pendingZoneMessage {
            message = pendingZoneMessage
            self.pendingZoneMessage = nil
        } else if let pendingEXPMessage {
            message = pendingEXPMessage
            self.pendingEXPMessage = nil
        } else if let pendingFrameMessage {
            message = pendingFrameMessage
            self.pendingFrameMessage = nil
        } else {
            return
        }

        isSendInProgress = true
        socket.send(.data(message)) { [weak self, weak socket] error in
            Task { @MainActor in
                guard let self, let socket, self.socket === socket else { return }
                self.isSendInProgress = false
                if error != nil {
                    self.handlePublisherDisconnected(socket)
                } else {
                    self.drainSendQueue()
                }
            }
        }
    }

    private func resetSendQueue() {
        isSendInProgress = false
        pendingControlMessages.removeAll(keepingCapacity: true)
        pendingFrameMessage = nil
        pendingEXPMessage = nil
        pendingRuneMessage = nil
        pendingZoneMessage = nil
        // 重连后必须重新上报一次告警状态，不能沿用断线前的判断。
        lastRuneState = nil
        lastZoneState = nil
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body?,
        authenticated: Bool
    ) async throws -> Response {
        guard let url = URL(string: baseURL + path) else {
            throw RemoteMonitorError.invalidServerURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated {
            guard let accessToken else { throw RemoteMonitorError.notAuthenticated }
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteMonitorError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? JSONDecoder().decode(RemoteAPIError.self, from: data)
            throw RemoteMonitorError.server(apiError?.message ?? "服务器请求失败（\(httpResponse.statusCode)）")
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw RemoteMonitorError.invalidResponse
        }
    }
}
