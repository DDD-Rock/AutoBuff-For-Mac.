import AppKit
import CoreGraphics
import Foundation
import SwiftUI

@available(macOS 14.0, *)
@MainActor
final class MainViewModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var mode: AppMode = .deadFlower
    @Published var selectedWindow: GameWindowInfo?
    @Published var windowStatusText = "未识别"
    @Published var logs: [String] = []
    @Published var countdowns: [Int: Int] = [:]
    @Published var isRunning = false
    @Published var accessibilityGranted = false
    @Published var accessibilityUsesAdHocSignature = false
    @Published var screenRecordingGranted = false
    @Published var showWindowPicker = false
    @Published var showVirtualKeyboard = false
    @Published var showPortalMarker = false
    @Published var showFollowHealMarker = false
    @Published var showMapTopologyEditor = false
    @Published var isCheckingPortalMarker = false
    @Published var portalMarkerAlert: PortalMarkerAlert?
    @Published var keyboardTarget: KeyboardTarget = .buff(0)
    @Published var debugExpanded = false
    @Published var previewImage: NSImage?
    @Published var previewInfo = ""
    @Published var expDataCollection = EXPDataCollectionSnapshot()
    @Published var isPartyInviteWorkerActive = false
    @Published var monitorImage: NSImage?
    @Published var monitorContentSize: CGSize = .zero
    @Published var monitorPlayerPoint: CGPoint?
    @Published var monitorTeammatePoints: [CGPoint] = []
    @Published var monitorOtherPlayerPoints: [CGPoint] = []
    @Published var monitorMatchedTopology: MapTopology?
    @Published var monitorStatusText = "尚未开始监控"
    @Published var monitorFPS = 0.0
    @Published var monitorEXPReading: EXPRecognitionResult?
    @Published var monitorEXPStatus = "尚未开始识别 EXP"
    @Published var monitorRuneAlertPresent = false
    @Published var monitorRuneAlertDetection: RuneAlertDetection?
    @Published var remoteMonitorPassword = ""
    @Published var remoteMonitorAuthenticated = false
    @Published var remoteMonitorAuthBusy = false
    @Published var remoteMonitorAuthStatus = "未登录远程监控账号"
    @Published var remoteMonitorPreviewURL = ""

    private let settingsManager = SettingsManager()
    private let windowSelector = WindowSelector()
    private let liveWorker = LiveFlowerWorker()
    private let deadWorker = DeadFlowerWorker()
    private let followHealWorker = FollowHealWorker()
    private let partyInviteWorker = PartyInviteWorker()
    private let monitoringSession = MonitoringSession()
    private let remoteMonitorClient = RemoteMonitorClient()
    private let expDataCollectionSession = EXPDataCollectionSession()
    private var screenRecordingRequestIssued = false
    private var reportedPersistenceErrors: Set<String> = []
    private var remoteMonitorPublishURL = ""

    enum KeyboardTarget: Equatable {
        case buff(Int)
        case jumpKey
        case chairKey
        case healSkillKey
    }

    struct PortalMarkerAlert: Identifiable {
        let id = UUID()
        let message: String
    }

    init() {
        settings = settingsManager.load()
        mode = settings.mode
        wireWorkers()
        wireEXPDataCollector()
        settingsManager.protectionWarnings.forEach {
            appendLog("⚠️ \($0)")
        }
        refreshPermissions()
        if accessibilityUsesAdHocSignature {
            appendLog("⚠️ 当前使用临时代码签名；重新构建后辅助功能授权可能失效")
        }
        autoIdentifyWindow()
        syncPartyInviteWorker(logMissingRequirements: false)
        Task { [weak self] in
            await self?.restoreRemoteMonitorAccount()
        }
    }

    func refreshPermissions() {
        accessibilityGranted = PermissionManager.requestAccessibility(prompt: false)
        accessibilityUsesAdHocSignature = PermissionManager.isAdHocSigned
        screenRecordingGranted = PermissionManager.screenRecordingGranted
        syncPartyInviteWorker(logMissingRequirements: false)
    }

    func requestAccessibility() {
        _ = PermissionManager.requestAccessibility(prompt: true)
        PermissionManager.openAccessibilitySettings()
        refreshPermissions()
    }

    func repairAccessibility() {
        stopWorker()
        let accessibilityReset = PermissionManager.resetAccessibilityConsent()
        let screenRecordingReset = PermissionManager.resetScreenRecordingConsent()
        if accessibilityReset && screenRecordingReset {
            appendLog("已清除旧权限记录，请为当前 AutoBuff 重新授权辅助功能和屏幕录制")
        } else {
            appendLog("无法完整清除旧权限，请在系统设置中删除旧 AutoBuff 后重新添加")
        }
        _ = PermissionManager.requestAccessibility(prompt: true)
        _ = PermissionManager.requestScreenRecording()
        PermissionManager.openAccessibilitySettings()
        refreshPermissions()
    }

    func requestScreenRecording() {
        if PermissionManager.screenRecordingGranted {
            screenRecordingGranted = true
            screenRecordingRequestIssued = false
            return
        }
        guard !screenRecordingRequestIssued else {
            appendLog("屏幕录制授权变更后需要退出并重新从 Xcode 运行 AutoBuff")
            PermissionManager.openScreenRecordingSettings()
            return
        }
        screenRecordingRequestIssued = true
        screenRecordingGranted = PermissionManager.requestScreenRecording()
        if !screenRecordingGranted {
            appendLog("请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许 AutoBuff，然后重新打开应用")
        }
    }

    func setMode(_ newMode: AppMode) {
        guard !isRunning else { return }
        mode = newMode
        settings.mode = newMode
        settings.returnToMarket = newMode == .deadFlower
        clearMonitorState(status: "尚未开始监控")
        saveSettings()
        syncPartyInviteWorker(logMissingRequirements: false)
    }

    func saveSettings() {
        let result = settingsManager.save(settings)
        for error in result.errors where reportedPersistenceErrors.insert(error).inserted {
            appendLog("⚠️ \(error)")
        }
    }

    func autoIdentifyWindow() {
        if let window = windowSelector.autoDetectGameWindow() {
            selectWindow(window)
        }
    }

    func identifyWindow() {
        if let window = windowSelector.autoDetectGameWindow() {
            selectWindow(window)
            appendLog("自动识别成功: \(window.title)")
        } else {
            showWindowPicker = true
        }
    }

    func selectWindow(_ window: GameWindowInfo) {
        if isRunning {
            stopWorker()
        }
        if expDataCollectionSession.isRunning {
            expDataCollectionSession.stop()
            appendLog("游戏窗口已切换，EXP 样本采集已停止")
        }
        selectedWindow = window
        windowStatusText = "\(window.title) (\(Int(window.size.width))×\(Int(window.size.height)))"
        syncPartyInviteWorker(logMissingRequirements: false)
    }

    func setAutoAcceptPartyInviteEnabled(_ enabled: Bool) {
        settings.autoAcceptPartyInviteEnabled = enabled
        saveSettings()
        if enabled {
            syncPartyInviteWorker(logMissingRequirements: true)
        } else {
            partyInviteWorker.stop()
            isPartyInviteWorkerActive = false
            appendLog("自动同意组队已关闭")
        }
    }

    func toggleWorker() {
        isRunning ? stopWorker() : startWorker()
    }

    func startWorker() {
        refreshPermissions()
        guard let window = selectedWindow else {
            appendLog("请先识别游戏窗口")
            return
        }
        guard windowSelector.isWindowValid(windowID: window.windowID) else {
            appendLog("游戏窗口已失效，请重新识别")
            selectedWindow = nil
            windowStatusText = "未识别"
            return
        }
        if ModeRequirements.requiresAccessibility(mode), !accessibilityGranted {
            appendLog("请先授予辅助功能权限")
            requestAccessibility()
            return
        }
        if ModeRequirements.requiresScreenRecording(mode), !screenRecordingGranted {
            appendLog("\(mode.title)需要屏幕录制权限")
            requestScreenRecording()
            return
        }
        let validationErrors = WorkerConfigurationValidator.validationErrors(
            settings: settings,
            mode: mode
        )
        guard validationErrors.isEmpty else {
            validationErrors.forEach(appendLog)
            return
        }
        settings.mode = mode
        settings.returnToMarket = mode == .deadFlower
        saveSettings()
        isRunning = true
        countdowns = [:]
        switch mode {
        case .liveFlower:
            let skills = buildLiveSkills()
            liveWorker.start(
                skills: skills,
                windowID: window.windowID,
                movementMode: settings.movementMode,
                sitChairEnabled: settings.sitChairEnabled,
                chairKey: settings.chairKey
            )
            appendLog("活花模式已启动")
        case .deadFlower:
            deadWorker.start(settings: settings, windowID: window.windowID)
            appendLog("死花模式已启动")
        case .followHeal:
            followHealWorker.start(settings: settings, windowID: window.windowID)
            appendLog("跟补模式已启动")
        case .monitor:
            partyInviteWorker.stop()
            if remoteMonitorAuthenticated, !remoteMonitorPublishURL.isEmpty {
                do {
                    try remoteMonitorClient.connectPublisher(to: remoteMonitorPublishURL)
                    appendLog("远程纯标注同步已连接")
                } catch {
                    appendLog("远程同步连接失败，将继续使用本地监控：\(error.localizedDescription)")
                }
            } else {
                appendLog("未登录远程账号，仅使用软件内本地预览")
            }
            monitoringSession.start(
                windowID: window.windowID,
                maps: settings.mapTopologies
            )
            appendLog("监控模式已启动（只读，不发送输入）")
        }
    }

    func stopWorker(resumePartyInvite: Bool = true) {
        liveWorker.stop()
        deadWorker.stop()
        followHealWorker.stop()
        monitoringSession.stop()
        remoteMonitorClient.disconnectPublisher()
        isRunning = false
        countdowns = [:]
        clearMonitorState(status: "监控已停止")
        if resumePartyInvite {
            syncPartyInviteWorker(logMissingRequirements: false)
        }
        appendLog("已停止")
    }

    func buildLiveSkills() -> [SkillConfig] {
        let randomDelay = settings.randomBehaviorEnabled ? Double(settings.randomBehaviorValue) : 0
        return settings.buffs
            .filter { $0.enabled && !$0.key.isEmpty && $0.duration > 0 }
            .map { SkillConfig(id: $0.id, key: $0.key, interval: $0.duration, randomDelay: randomDelay) }
    }

    func appendLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(timestamp)] \(message)")
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
    }

    func clearLogs() {
        logs.removeAll()
    }

    func applySelectedKey(_ key: String) {
        switch keyboardTarget {
        case .buff(let index):
            guard settings.buffs.indices.contains(index) else { return }
            settings.buffs[index].key = key
        case .jumpKey:
            settings.jumpKey = key
        case .chairKey:
            settings.chairKey = key
        case .healSkillKey:
            settings.healSkillKey = key
        }
        saveSettings()
    }

    func openKeyboard(for target: KeyboardTarget) {
        keyboardTarget = target
        showVirtualKeyboard = true
    }

    func requestPortalMarker() async {
        guard !isRunning, !isCheckingPortalMarker else { return }
        guard let window = selectedWindow else {
            portalMarkerAlert = PortalMarkerAlert(message: "请先识别游戏窗口。")
            return
        }
        guard windowSelector.isWindowValid(windowID: window.windowID) else {
            selectedWindow = nil
            windowStatusText = "未识别"
            portalMarkerAlert = PortalMarkerAlert(message: "游戏窗口已失效，请重新识别。")
            return
        }

        isCheckingPortalMarker = true
        defer { isCheckingPortalMarker = false }

        let detector = MarketButtonDetector()
        detector.setWindow(window.windowID)
        do {
            guard try await detector.isInMarket() else {
                appendLog("传送门标记已取消：当前未检测到自由市场")
                portalMarkerAlert = PortalMarkerAlert(
                    message: "当前未检测到自由市场，请先进入自由市场后再标记传送门。"
                )
                return
            }
            showPortalMarker = true
        } catch {
            appendLog("传送门标记前置检测失败: \(error.localizedDescription)")
            portalMarkerAlert = PortalMarkerAlert(
                message: "无法确认当前地图，请检查屏幕录制权限和游戏窗口后重试。"
            )
        }
    }

    func requestFollowHealMarker() {
        guard !isRunning else { return }
        guard let window = selectedWindow else {
            portalMarkerAlert = PortalMarkerAlert(message: "请先识别游戏窗口。")
            return
        }
        guard windowSelector.isWindowValid(windowID: window.windowID) else {
            selectedWindow = nil
            windowStatusText = "未识别"
            portalMarkerAlert = PortalMarkerAlert(message: "游戏窗口已失效，请重新识别。")
            return
        }
        guard screenRecordingGranted else {
            portalMarkerAlert = PortalMarkerAlert(message: "标记跟补基准点需要屏幕录制权限。")
            requestScreenRecording()
            return
        }
        showFollowHealMarker = true
    }

    func requestMapTopologyEditor() {
        guard !isRunning else { return }
        guard let window = selectedWindow else {
            portalMarkerAlert = PortalMarkerAlert(message: "请先识别游戏窗口。")
            return
        }
        guard windowSelector.isWindowValid(windowID: window.windowID) else {
            selectedWindow = nil
            windowStatusText = "未识别"
            portalMarkerAlert = PortalMarkerAlert(message: "游戏窗口已失效，请重新识别。")
            return
        }
        guard screenRecordingGranted else {
            portalMarkerAlert = PortalMarkerAlert(message: "地图标注需要屏幕录制权限。")
            requestScreenRecording()
            return
        }
        showMapTopologyEditor = true
    }

    func addBuff() {
        guard !isRunning, settings.buffs.count < AppConstants.maxBuffSlotCount else { return }
        settings.buffs.append(BuffConfig(id: settings.buffs.count + 1))
        saveSettings()
    }

    func removeBuff(at index: Int) {
        guard !isRunning,
              settings.buffs.count > AppConstants.defaultBuffSlotCount,
              settings.buffs.indices.contains(index) else { return }
        settings.buffs.remove(at: index)
        for index in settings.buffs.indices {
            settings.buffs[index].id = index + 1
        }
        saveSettings()
    }

    func capturePreview() async {
        guard let window = selectedWindow else {
            appendLog("请先识别游戏窗口")
            return
        }
        let capture = GameCaptureService()
        do {
            let result = try await capture.captureBGR(windowID: window.windowID)
            previewImage = result.buffer.toNSImage()
            previewInfo = "\(result.buffer.width)×\(result.buffer.height) px"
            appendLog("截图成功 \(previewInfo)")
        } catch {
            appendLog("截图失败: \(error.localizedDescription)")
        }
    }

    func toggleEXPDataCollection() {
        if expDataCollectionSession.isRunning {
            expDataCollectionSession.stop()
            appendLog("EXP 样本采集已停止")
            return
        }
        refreshPermissions()
        guard let window = selectedWindow else {
            appendLog("请先识别游戏窗口")
            return
        }
        guard windowSelector.isWindowValid(windowID: window.windowID) else {
            selectedWindow = nil
            windowStatusText = "未识别"
            appendLog("游戏窗口已失效，请重新识别")
            return
        }
        guard screenRecordingGranted else {
            appendLog("EXP 样本采集需要屏幕录制权限")
            requestScreenRecording()
            return
        }
        expDataCollectionSession.start(windowID: window.windowID)
    }

    func revealEXPDataCollectionDirectory() {
        expDataCollectionSession.revealDatasetDirectory()
    }

    func shutdown() {
        expDataCollectionSession.stop()
        partyInviteWorker.stop()
        stopWorker(resumePartyInvite: false)
        saveSettings()
    }

    func loginRemoteMonitor() {
        guard !remoteMonitorAuthBusy else { return }
        let username = settings.monitorAccountUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !remoteMonitorPassword.isEmpty else {
            remoteMonitorAuthStatus = "请输入用户名和密码"
            return
        }
        remoteMonitorAuthBusy = true
        remoteMonitorAuthStatus = "正在登录..."
        Task { [weak self] in
            guard let self else { return }
            defer { remoteMonitorAuthBusy = false }
            do {
                let account = try await remoteMonitorClient.authenticate(
                    baseURL: settings.monitorServerBaseURL,
                    username: username,
                    password: remoteMonitorPassword
                )
                settings.monitorAccountUsername = account
                remoteMonitorPassword = ""
                remoteMonitorAuthenticated = true
                saveSettings()
                try await restoreOrCreateRemoteMonitorSession()
                appendLog("远程监控账号登录成功")
            } catch {
                remoteMonitorAuthenticated = false
                remoteMonitorAuthStatus = error.localizedDescription
                appendLog("远程监控登录失败：\(error.localizedDescription)")
            }
        }
    }

    func openRemoteMonitorRegistrationPage() {
        let baseURL = settings.monitorServerBaseURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseURL)/register") else {
            remoteMonitorAuthStatus = "注册网址无效"
            return
        }
        NSWorkspace.shared.open(url)
        remoteMonitorAuthStatus = "已打开网页注册页面"
    }

    func logoutRemoteMonitor() {
        if isRunning && mode == .monitor {
            stopWorker()
        }
        remoteMonitorClient.logout()
        remoteMonitorAuthenticated = false
        remoteMonitorPreviewURL = ""
        remoteMonitorPublishURL = ""
        remoteMonitorAuthStatus = "已退出远程监控账号"
    }

    func copyRemoteMonitorPreviewURL() {
        guard !remoteMonitorPreviewURL.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(remoteMonitorPreviewURL, forType: .string)
        remoteMonitorAuthStatus = "预览链接已复制"
    }

    func openRemoteMonitorPreviewURL() {
        guard let url = URL(string: remoteMonitorPreviewURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private func restoreRemoteMonitorAccount() async {
        guard let storedToken = await remoteMonitorClient.loadStoredAccessToken() else {
            return
        }
        remoteMonitorAuthBusy = true
        remoteMonitorAuthStatus = "正在恢复登录..."
        defer { remoteMonitorAuthBusy = false }
        do {
            let account = try await remoteMonitorClient.restore(
                baseURL: settings.monitorServerBaseURL,
                storedToken: storedToken
            )
            settings.monitorAccountUsername = account
            remoteMonitorAuthenticated = true
            try await restoreOrCreateRemoteMonitorSession()
        } catch {
            remoteMonitorAuthenticated = false
            remoteMonitorAuthStatus = "登录已失效，请重新登录"
        }
    }

    private func restoreOrCreateRemoteMonitorSession() async throws {
        if let session = try await remoteMonitorClient.restoreSession() {
            applyRemoteMonitorSession(session)
            remoteMonitorAuthStatus = "已登录 · 原预览链接已恢复"
            return
        }
        try await createRemoteMonitorSession()
    }

    private func createRemoteMonitorSession() async throws {
        remoteMonitorAuthStatus = "正在生成预览链接..."
        let session = try await remoteMonitorClient.createSession(
            deviceName: Host.current().localizedName ?? "我的 Mac"
        )
        applyRemoteMonitorSession(session)
        remoteMonitorAuthStatus = "已登录 · 预览链接已生成"
    }

    private func applyRemoteMonitorSession(_ session: RemoteMonitorSessionInfo) {
        remoteMonitorPreviewURL = session.previewURL
        remoteMonitorPublishURL = session.publishURL
    }

    private func wireWorkers() {
        liveWorker.onLog = { [weak self] msg in self?.appendLog(msg) }
        liveWorker.onCountdown = { [weak self] info in self?.countdowns = info }
        liveWorker.onError = { [weak self] msg in self?.appendLog("错误: \(msg)") }
        liveWorker.onStopped = { [weak self] in
            self?.isRunning = false
            self?.countdowns = [:]
        }

        deadWorker.onLog = { [weak self] msg in self?.appendLog(msg) }
        deadWorker.onCountdown = { [weak self] info in self?.countdowns = info }
        deadWorker.onError = { [weak self] msg in self?.appendLog("错误: \(msg)") }
        deadWorker.onStopped = { [weak self] in
            self?.isRunning = false
            self?.countdowns = [:]
        }

        followHealWorker.onLog = { [weak self] msg in self?.appendLog(msg) }
        followHealWorker.onCountdown = { [weak self] info in self?.countdowns = info }
        followHealWorker.onError = { [weak self] msg in self?.appendLog("错误: \(msg)") }
        followHealWorker.onStopped = { [weak self] in
            self?.isRunning = false
            self?.countdowns = [:]
        }

        partyInviteWorker.onLog = { [weak self] msg in self?.appendLog(msg) }
        partyInviteWorker.onError = { [weak self] msg in self?.appendLog("错误: \(msg)") }
        partyInviteWorker.onStateChanged = { [weak self] active in
            self?.isPartyInviteWorkerActive = active
        }

        monitoringSession.onFrame = { [weak self] frame in
            guard let self else { return }
            monitorImage = frame.buffer.mapEditorImage()
            monitorContentSize = CGSize(width: frame.buffer.width, height: frame.buffer.height)
            monitorPlayerPoint = frame.playerPoint
            monitorTeammatePoints = frame.teammatePoints
            monitorOtherPlayerPoints = frame.otherPlayerPoints
            monitorMatchedTopology = frame.matchedTopology
            monitorFPS = frame.framesPerSecond
            remoteMonitorClient.publish(frame: frame)
        }
        monitoringSession.onStatus = { [weak self] status in
            self?.monitorStatusText = status
        }
        monitoringSession.onEXPReading = { [weak self] reading in
            self?.monitorEXPReading = reading
        }
        monitoringSession.onEXPStatus = { [weak self] status in
            guard let self else { return }
            monitorEXPStatus = status
            remoteMonitorClient.publishEXP(
                reading: monitorEXPReading,
                status: status
            )
        }
        monitoringSession.onRuneAlert = { [weak self] isPresent, detection in
            guard let self else { return }
            if isPresent != monitorRuneAlertPresent {
                appendLog(isPresent ? "⚠️ 检测到符文诅咒提示" : "符文诅咒提示已消失")
            }
            monitorRuneAlertPresent = isPresent
            monitorRuneAlertDetection = detection
            remoteMonitorClient.publishRuneAlert(isPresent: isPresent, detection: detection)
        }
        monitoringSession.onStopped = { [weak self] reason in
            guard let self else { return }
            isRunning = false
            clearMonitorState(status: reason)
            appendLog(reason)
            syncPartyInviteWorker(logMissingRequirements: false)
        }
    }

    private func wireEXPDataCollector() {
        expDataCollectionSession.onSnapshot = { [weak self] snapshot in
            self?.expDataCollection = snapshot
        }
        expDataCollectionSession.onLog = { [weak self] message in
            self?.appendLog(message)
        }
    }

    private func syncPartyInviteWorker(logMissingRequirements: Bool) {
        if isRunning && mode == .monitor {
            partyInviteWorker.stop()
            isPartyInviteWorkerActive = false
            return
        }
        guard settings.autoAcceptPartyInviteEnabled else {
            partyInviteWorker.stop()
            isPartyInviteWorkerActive = false
            return
        }
        guard let window = selectedWindow else {
            partyInviteWorker.stop()
            isPartyInviteWorkerActive = false
            if logMissingRequirements { appendLog("请先识别游戏窗口后再开启自动同意组队") }
            return
        }
        guard windowSelector.isWindowValid(windowID: window.windowID) else {
            selectedWindow = nil
            windowStatusText = "未识别"
            partyInviteWorker.stop()
            isPartyInviteWorkerActive = false
            if logMissingRequirements { appendLog("游戏窗口已失效，请重新识别") }
            return
        }
        guard accessibilityGranted else {
            partyInviteWorker.stop()
            isPartyInviteWorkerActive = false
            if logMissingRequirements {
                appendLog("自动同意组队需要辅助功能权限")
                requestAccessibility()
            }
            return
        }
        guard screenRecordingGranted else {
            partyInviteWorker.stop()
            isPartyInviteWorkerActive = false
            if logMissingRequirements {
                appendLog("自动同意组队需要屏幕录制权限")
                requestScreenRecording()
            }
            return
        }

        let wasRunning = partyInviteWorker.isRunning
        let previousWindowID = partyInviteWorker.currentWindowID
        partyInviteWorker.start(windowID: window.windowID)
        if !wasRunning || previousWindowID != window.windowID {
            appendLog("自动同意组队已开启")
        }
    }

    private func clearMonitorState(status: String) {
        monitorImage = nil
        monitorContentSize = .zero
        monitorPlayerPoint = nil
        monitorTeammatePoints = []
        monitorOtherPlayerPoints = []
        monitorMatchedTopology = nil
        monitorFPS = 0
        monitorEXPReading = nil
        monitorEXPStatus = "尚未开始识别 EXP"
        monitorRuneAlertPresent = false
        monitorRuneAlertDetection = nil
        monitorStatusText = status
    }

}

enum WorkerConfigurationValidator {
    static func validationErrors(settings: AppSettings, mode: AppMode) -> [String] {
        if mode == .monitor {
            return []
        }
        let enabled = settings.buffs.filter(\.enabled)
        var errors: [String] = []
        if enabled.isEmpty && mode != .followHeal {
            errors.append("请至少启用一个 Buff")
        }
        for buff in enabled {
            if buff.key.isEmpty {
                errors.append("Buff #\(buff.id) 尚未设置按键")
            } else if KeyCodeMap.virtualKeyCode(for: buff.key) == nil {
                errors.append("Buff #\(buff.id) 的按键“\(buff.key)”不受支持")
            }
            if buff.duration < AppConstants.minInterval || buff.duration > AppConstants.maxInterval {
                errors.append("Buff #\(buff.id) 的持续时间需为 \(AppConstants.minInterval)～\(Int(AppConstants.maxInterval)) 秒")
            }
        }
        if settings.sitChairEnabled && KeyCodeMap.virtualKeyCode(for: settings.chairKey) == nil {
            errors.append("椅子键“\(settings.chairKey)”不受支持")
        }
        if mode == .deadFlower && KeyCodeMap.virtualKeyCode(for: settings.jumpKey) == nil {
            errors.append("跳跃键“\(settings.jumpKey)”不受支持")
        }
        if mode == .followHeal {
            if settings.healSkillKey.isEmpty {
                errors.append("请设置加血技能键")
            } else if KeyCodeMap.virtualKeyCode(for: settings.healSkillKey) == nil {
                errors.append("加血技能键“\(settings.healSkillKey)”不受支持")
            }
            if settings.healAnchorX == nil {
                errors.append("请先标记跟补基准点")
            }
        }
        return errors
    }
}

private extension ImageBuffer {
    func toNSImage() -> NSImage? {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        var dst = 0
        for i in stride(from: 0, to: bgr.count, by: 3) {
            rgba[dst] = bgr[i + 2]
            rgba[dst + 1] = bgr[i + 1]
            rgba[dst + 2] = bgr[i]
            rgba[dst + 3] = 255
            dst += 4
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }
}
