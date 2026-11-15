import AppKit
import CoreGraphics
import Foundation

/// Runs the Mac game's smoke/channel loop for its supported 960 x 628 layout.
@available(macOS 14.0, *)
@MainActor
final class InfiniteSmokeWorker: ObservableObject {
    var onLog: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onStopped: (() -> Void)?

    private enum Layout {
        static let size = CGSize(width: 960, height: 628)
        // Window-image coordinates, including the 28-point macOS title bar.
        static let socialButton = CGPoint(x: 882, y: 64)
        // Measured from the live 960 x 628 Mac login screen. The old point
        // (740, 383) lands to the upper-right of the orange login button.
        static let loginButton = CGPoint(x: 692, y: 398)
        // Measured from the live 960 x 628 Mac character screen. The action
        // target is the "选择角色" button, not the selected character sprite.
        static let characterButton = CGPoint(x: 622, y: 270)
        static let dailyRewardConfirm = CGPoint(x: 610, y: 363)
        static let signInClose = CGPoint(x: 682, y: 174)
        // Measured from the live Mac confirmation dialog's "是" button center.
        static let togetherGameConfirm = CGPoint(x: 422, y: 377)
        static let socialRegion = CGRect(x: 720, y: 145, width: 230, height: 370)
        // Measured from the live game screenshot with OCR: the action row center
        // is (-4, +58) from the friend's name center. It is anchored to the name,
        // not to the exact pixel used to click the friend row.
        static let togetherActionOffset = CGPoint(x: -4, y: 58)
    }

    private let human = HumanInput()
    private let windowSelector = WindowSelector()
    private let minimap = MinimapMonitor()
    private let capture = GameCaptureService()
    private var task: Task<Void, Never>?
    private var runID = UUID()
    /// Saved on first area selection. This worker never asks the detector to find
    /// a new minimap because login and transition screens can legitimately omit it.
    private var fixedMinimapRegion: CGRect?
    private(set) var isRunning = false

    func start(settings: AppSettings, windowID: CGWindowID) {
        stop()
        let id = UUID()
        runID = id
        isRunning = true
        minimap.setWindow(windowID)
        fixedMinimapRegion = settings.smokeMinimapRegion
        if let fixedMinimapRegion { minimap.setMinimapRegion(fixedMinimapRegion) }
        task = Task { await run(settings: settings, windowID: windowID, runID: id) }
    }

    func stop() {
        isRunning = false
        runID = UUID()
        task?.cancel()
        task = nil
        fixedMinimapRegion = nil
        Task { await human.releaseAll() }
    }

    private func run(settings: AppSettings, windowID: CGWindowID, runID id: UUID) async {
        do {
            guard !settings.smokeFriendName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SmokeError.message("请设置好友名称")
            }
            guard fixedMinimapRegion != nil, let smokeBuffZone = settings.smokeBuffZone else {
                throw SmokeError.message("请重新圈选放烟允许区域并保存小地图区域")
            }
            _ = try await supportedCapture(windowID: windowID)
            try await requireFocus(windowID, reason: "无限烟启动")

            var socialOpen = try await isSocialPanelOpen(windowID: windowID)
            if let page = try await visibleGamePage(windowID: windowID) {
                log("启动时检测到\(page == .login ? "登录" : "角色选择")页面，正在进入游戏")
                try await enterGame(from: page, windowID: windowID)
                try await waitForMinimapAndDismissOverlays(windowID: windowID)
                socialOpen = false
            } else if socialOpen {
                log("社交好友列表已打开，直接开始频道刷新")
            }

            while active(id) {
                if !socialOpen {
                    try await moveToBuffZone(
                        smokeBuffZone,
                        jumpKey: settings.jumpKey,
                        windowID: windowID
                    )
                    try await castSmoke(settings.smokeKey, windowID: windowID)
                    try await clickImagePoint(Layout.socialButton, windowID: windowID, label: "社交入口")
                }
                try await refreshChannel(friendName: settings.smokeFriendName, windowID: windowID)
                try await waitForMinimapAndDismissOverlays(windowID: windowID)
                log("本轮频道刷新完成，继续下一轮烟雾流程")
                socialOpen = false
            }
        } catch is CancellationError {
        } catch let error as SmokeError {
            onError?(error.localizedDescription)
        } catch {
            onError?("无限烟流程异常：\(error.localizedDescription)")
        }
        await human.releaseAll()
        if runID == id {
            isRunning = false
            task = nil
            onStopped?()
        }
    }

    private func moveToBuffZone(_ zone: MonitorSafeZone, jumpKey: String, windowID: CGWindowID) async throws {
        guard let minimapSize = minimap.minimapSize, minimapSize.width > 0, minimapSize.height > 0 else {
            throw SmokeError.message("未读取到小地图尺寸，请重新圈选放烟允许区域")
        }
        let allowedArea = zone.rect(in: minimapSize)
        var point = try await locatePlayer(jumpKey: jumpKey, windowID: windowID, down: false)
        while active() && !zone.contains(point, in: minimapSize) {
            if point.y > allowedArea.maxY { throw SmokeError.message("角色位于放烟允许区域下方，不能继续下跳") }
            if point.y < allowedArea.minY {
                log("下跳进入放烟允许区域")
                try await requireFocus(windowID, reason: "下跳")
                try await human.performDownJump(jumpKey: jumpKey, downLeadMS: 90, jumpHoldMS: 120, downReleaseAfterJumpMS: 65)
                try await pause(1.2)
                point = try await locatePlayer(jumpKey: jumpKey, windowID: windowID, down: true)
                continue
            }
            let direction: HumanInput.Direction = point.x < allowedArea.minX ? .right : .left
            let distance = point.x < allowedArea.minX
                ? allowedArea.minX - point.x
                : point.x - allowedArea.maxX
            let hold = distance <= 15 ? 120...200 : 250...420
            try await requireFocus(windowID, reason: "移动到烟雾位置")
            await human.tapDirection(direction, holdMS: hold, intervalMS: 80...160)
            try await pause(0.25)
            point = try await locatePlayer(jumpKey: jumpKey, windowID: windowID, down: false)
        }
        guard active() else { throw CancellationError() }
        log("已进入放烟允许区域 X=\(Int(point.x)) Y=\(Int(point.y))")
    }

    private func locatePlayer(jumpKey: String, windowID: CGWindowID, down: Bool) async throws -> CGPoint {
        var jumped = false
        while active() {
            if let point = try await findSavedRegionPlayer() {
                if jumped { try await pause(1.2) }
                return point
            }
            log(down ? "黄点暂时不可见，继续下跳寻找位置" : "黄点不可见，原地跳跃确认位置")
            try await requireFocus(windowID, reason: "寻找小地图黄点")
            if down {
                try await human.performDownJump(jumpKey: jumpKey, downLeadMS: 90, jumpHoldMS: 120, downReleaseAfterJumpMS: 65)
            } else {
                _ = try await human.tapNamedKey(jumpKey, holdMS: 80...120)
            }
            jumped = true
            try await pause(1.2)
        }
        throw CancellationError()
    }

    private func castSmoke(_ key: String, windowID: CGWindowID) async throws {
        log("连续两次释放烟雾技能")
        try await requireFocus(windowID, reason: "释放烟雾")
        _ = try await human.tapNamedKey(key, holdMS: 80...120)
        try await pause(Double.random(in: 0.1...0.3))
        try await requireFocus(windowID, reason: "释放烟雾")
        _ = try await human.tapNamedKey(key, holdMS: 80...120)
    }

    private func refreshChannel(friendName: String, windowID: CGWindowID) async throws {
        log("等待在线好友")
        var attempt = 0
        while active() {
            // A slow transition may finish after the previous short observation
            // window. Always recognize the destination before looking for the
            // friend again so a late login screen cannot strand this loop.
            if let page = try await visibleGamePage(windowID: windowID) {
                try await enterGame(from: page, windowID: windowID)
                return
            }

            attempt += 1
            // The friend row or its menu can remain stale after an unavailable
            // action. Re-read the row on every attempt instead of waiting on a
            // single menu click to recover by itself.
            let friend = try await findValue(
                windowID: windowID,
                region: nil,
                timeout: 4,
                pollInterval: 0.1,
                { blocks in SmokeTextRecognizer.matchingFriend(blocks, name: friendName) }
            )
            guard let friend else {
                try await pause(0.4)
                continue
            }

            try await clickImagePoint(friend, windowID: windowID, label: "在线好友")
            try await pause(Double.random(in: 0.65...1.0))
            log("第 \(attempt) 次识别一起畅游游戏菜单")
            let action = try await findValue(
                windowID: windowID,
                region: togetherActionSearchRegion(below: friend),
                timeout: 5,
                pollInterval: 0.2,
                minimumConfidence: 0.12,
                { blocks in SmokeTextRecognizer.togetherAction(blocks) }
            )
            guard let action else {
                try await pause(0.4)
                continue
            }

            try await clickImagePoint(action, windowID: windowID, label: "一起畅游游戏")
            // A temporarily unavailable action may consume the click without
            // opening the confirmation panel. Observe only briefly, then retry
            // the whole friend/menu sequence instead of entering a long wait.
            try await pause(Double.random(in: 0.45...0.8))
            let pageAfterAction = try await findValue(
                windowID: windowID,
                region: nil,
                timeout: 1.2,
                pollInterval: 0.2,
                { blocks in SmokeTextRecognizer.gamePage(blocks) }
            )
            if let page = pageAfterAction {
                try await enterGame(from: page, windowID: windowID)
                return
            }

            // The confirmation text is small and Vision may miss it, so the
            // fixed native button remains the authoritative click target.
            try await clickImagePoint(
                Layout.togetherGameConfirm,
                windowID: windowID,
                label: "确认一起进行游戏",
                offsetRange: 0
            )
            log("已尝试确认一起进行游戏，等待登录或角色选择页面")
            let pageAfterConfirm = try await findValue(
                windowID: windowID,
                region: nil,
                timeout: 6,
                pollInterval: 0.3,
                { blocks in SmokeTextRecognizer.gamePage(blocks) }
            )
            if let page = pageAfterConfirm {
                try await enterGame(from: page, windowID: windowID)
                return
            }

            log("本次邀请未进入下一阶段，重新点击好友重试")
            try await pause(Double.random(in: 0.35...0.7))
        }
        throw CancellationError()
    }

    private func enterGame(from initialPage: SmokeGamePage, windowID: CGWindowID) async throws {
        if initialPage == .login {
            log("登录页面已识别，持续点击登录并只等待角色选择页面")
            while active() {
                // Do not OCR the login page again here. The pointer remains on
                // its button after clicking and can obscure the login text.
                try await clickImagePoint(Layout.loginButton, windowID: windowID, label: "登录")
                try await pause(Double.random(in: 0.8...1.45))
                let blocks = try await recognize(windowID: windowID, region: nil)
                if SmokeTextRecognizer.isCharacterSelection(blocks) {
                    log("角色选择页面已识别")
                    break
                }
            }
            guard active() else { throw CancellationError() }
        } else {
            log("角色选择页面已识别")
        }

        log("持续点击选择角色并等待进入游戏")
        var gameFrames = 0
        while active() {
            // Keep retrying this fixed point while the game enables or loads
            // the button. Unlike checking for vanished button text, a player
            // marker is a positive signal that the next game stage is ready.
            try await clickImagePoint(Layout.characterButton, windowID: windowID, label: "进入角色")
            try await pause(Double.random(in: 0.8...1.45))
            if try await findSavedRegionPlayer() != nil {
                gameFrames += 1
                if gameFrames >= 2 { return }
            } else {
                gameFrames = 0
            }
        }
        throw CancellationError()
    }

    private func waitForMinimapAndDismissOverlays(windowID: CGWindowID) async throws {
        while active() {
            if try await findSavedRegionPlayer() != nil { break }
            try await pause(0.5)
        }
        guard active() else { throw CancellationError() }
        try await dismissLoginOverlays(windowID: windowID)
        while active() {
            if try await findSavedRegionPlayer() != nil { return }
            try await pause(0.5)
        }
        throw CancellationError()
    }

    private func dismissLoginOverlays(windowID: CGWindowID) async throws {
        while active() {
            let blocks = try await recognize(windowID: windowID, region: nil)
            if SmokeTextRecognizer.dailyRewardVisible(blocks) {
                try await clickImagePoint(Layout.dailyRewardConfirm, windowID: windowID, label: "每日奖励确认")
            } else if SmokeTextRecognizer.signInVisible(blocks) {
                try await clickImagePoint(Layout.signInClose, windowID: windowID, label: "签到窗口关闭")
            } else { return }
            try await pause(1)
        }
        throw CancellationError()
    }

    private func isSocialPanelOpen(windowID: CGWindowID) async throws -> Bool {
        SmokeTextRecognizer.isSocialPanel(try await recognize(windowID: windowID, region: Layout.socialRegion))
    }

    private func findSavedRegionPlayer() async throws -> CGPoint? {
        guard let fixedMinimapRegion else {
            throw SmokeError.message("未保存小地图区域，请重新圈选放烟允许区域")
        }
        // Keep the configured crop installed before every read. `MinimapMonitor`
        // only falls back to automatic detection when no region is configured.
        minimap.setMinimapRegion(fixedMinimapRegion)
        return try await minimap.findPlayerPosition(minArea: 2)
    }

    private func togetherActionSearchRegion(below friend: CGPoint) -> CGRect {
        let point = CGPoint(
            x: friend.x + Layout.togetherActionOffset.x,
            y: friend.y + Layout.togetherActionOffset.y
        )
        let bounds = CGRect(origin: .zero, size: Layout.size)
        // Keep the menu's left edge stable and give its text room on the right.
        return CGRect(x: point.x - 75, y: point.y - 50, width: 190, height: 100)
            .intersection(bounds)
    }

    private func visibleGamePage(windowID: CGWindowID) async throws -> SmokeGamePage? {
        SmokeTextRecognizer.gamePage(try await recognize(windowID: windowID, region: nil))
    }

    /// A bounded poll used by recoverable UI actions. Unlike waitForValue it
    /// returns nil on timeout so callers can start a fresh attempt.
    private func findValue<T>(
        windowID: CGWindowID,
        region: CGRect?,
        timeout: Double,
        pollInterval: Double = 0.35,
        minimumConfidence: Float = 0.25,
        _ predicate: @escaping ([SmokeTextBlock]) -> T?
    ) async throws -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while active() && Date() < deadline {
            let blocks = try await recognize(
                windowID: windowID,
                region: region,
                minimumConfidence: minimumConfidence
            )
            if let value = predicate(blocks) { return value }
            try await pause(pollInterval)
        }
        return nil
    }

    private func recognize(
        windowID: CGWindowID,
        region: CGRect?,
        minimumConfidence: Float = 0.25
    ) async throws -> [SmokeTextBlock] {
        let frame = try await supportedCapture(windowID: windowID)
        return await Task.detached(priority: .userInitiated) {
            SmokeTextRecognizer.recognize(
                frame.buffer,
                region: region,
                minimumConfidence: minimumConfidence
            )
        }.value
    }

    private func clickImagePoint(
        _ point: CGPoint,
        windowID: CGWindowID,
        label: String,
        offsetRange: Int = 2
    ) async throws {
        try await requireFocus(windowID, reason: label)
        let frame = try await supportedCapture(windowID: windowID)
        guard CGRect(origin: .zero, size: Layout.size).contains(point) else {
            throw SmokeError.message("\(label)点击坐标超出当前游戏窗口")
        }
        await human.clickAt(screenPoint: frame.screenPoint(for: point), offsetRange: offsetRange)
    }

    private func supportedCapture(windowID: CGWindowID) async throws -> CapturedGameFrame {
        let frame = try await capture.captureBGR(windowID: windowID)
        guard frame.buffer.width == Int(Layout.size.width), frame.buffer.height == Int(Layout.size.height) else {
            throw SmokeError.message("无限烟模式仅支持当前 960 × 628 游戏窗口")
        }
        return frame
    }

    private func requireFocus(_ windowID: CGWindowID, reason: String) async throws {
        if windowSelector.isWindowOwnerFrontmost(windowID: windowID) { return }
        for _ in 0..<24 where active() {
            _ = windowSelector.bringWindowToFront(windowID: windowID)
            try await pause(0.25)
            if windowSelector.isWindowOwnerFrontmost(windowID: windowID) { return }
        }
        throw SmokeError.message("无法将游戏窗口置于前台（\(reason)）")
    }

    private func active(_ id: UUID? = nil) -> Bool {
        isRunning && !Task.isCancelled && (id == nil || id == runID)
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1_000)))
    }

    private func log(_ message: String) { onLog?(message) }

    private enum SmokeError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case let .message(text) = self { return text }
            return nil
        }
    }
}
