import CoreGraphics
import Foundation

struct LoungeMarkerCounts: Equatable, Sendable {
    let yellow: Int
    let orange: Int

    var summary: String { "黄点 \(yellow) 个，橙点 \(orange) 个" }

    func hasIncrease(comparedWith previous: LoungeMarkerCounts) -> Bool {
        yellow > previous.yellow || orange > previous.orange
    }
}

struct LoungePopulationChange: Equatable {
    let previous: LoungeMarkerCounts
    let current: LoungeMarkerCounts

    var increased: Bool { current.hasIncrease(comparedWith: previous) }
}

/// 小地图色点会偶尔丢一帧。连续看到相同数量后才承认变化，但每次确认的
/// 减少也会更新基线，因此 3 → 2 → 3 仍然会被识别为一次增加。
struct LoungePopulationTracker {
    let confirmationFrames: Int
    private(set) var baseline: LoungeMarkerCounts?
    private var candidate: LoungeMarkerCounts?
    private var candidateFrames = 0

    init(confirmationFrames: Int = 2) {
        self.confirmationFrames = max(1, confirmationFrames)
    }

    mutating func observe(_ counts: LoungeMarkerCounts) -> LoungePopulationChange? {
        if counts == baseline {
            candidate = nil
            candidateFrames = 0
            return nil
        }

        if candidate == counts {
            candidateFrames += 1
        } else {
            candidate = counts
            candidateFrames = 1
        }
        guard candidateFrames >= confirmationFrames else { return nil }

        let previous = baseline
        baseline = counts
        candidate = nil
        candidateFrames = 0
        guard let previous else { return nil }
        return LoungePopulationChange(previous: previous, current: counts)
    }
}

@available(macOS 14.0, *)
@MainActor
final class LoungeWorker: ObservableObject {
    var onLog: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onStopped: (() -> Void)?

    private let human = HumanInput()
    private let windowSelector = WindowSelector()
    private let minimap = MinimapMonitor()
    private var task: Task<Void, Never>?
    private var runID = UUID()
    private var pendingPartyAcceptedTriggers = 0
    private var lastAnnouncementBase: String?
    private(set) var isRunning = false

    func start(settings: AppSettings, windowID: CGWindowID) {
        stop()
        let currentRunID = UUID()
        runID = currentRunID
        isRunning = true
        pendingPartyAcceptedTriggers = 0
        minimap.setWindow(windowID)
        task = Task {
            await run(settings: settings, windowID: windowID, runID: currentRunID)
        }
    }

    func stop() {
        isRunning = false
        runID = UUID()
        task?.cancel()
        task = nil
        pendingPartyAcceptedTriggers = 0
        Task { await human.releaseAll() }
    }

    func partyInviteAccepted() {
        guard isRunning else { return }
        pendingPartyAcceptedTriggers += 1
        log("自动接受组队成功，已加入一次 BUFF 释放队列")
    }

    private func run(
        settings: AppSettings,
        windowID: CGWindowID,
        runID currentRunID: UUID
    ) async {
        let buffs = settings.buffs.filter { $0.enabled && !$0.key.isEmpty }
        guard !buffs.isEmpty else {
            finish(currentRunID, error: "没有可运行的 BUFF 配置")
            return
        }

        log("神殿模式 · 休息室启动...")
        if !windowSelector.bringWindowToFront(windowID: windowID) {
            log("⚠️ 无法将游戏窗口置于前台")
        }
        await sleep(0.5)

        log("首次启动，立即释放一轮 BUFF")
        await castBuffsAndAnnounce(buffs, windowID: windowID)
        guard isRunning, !Task.isCancelled else {
            await human.releaseAll()
            finish(currentRunID)
            return
        }

        guard (try? await minimap.autoDetectDarkRegion()) != nil else {
            finish(currentRunID, error: "未识别到小地图：\(minimap.lastDetectionSummary)")
            return
        }

        let interval = settings.loungeMoveIntervalMinutes
        var nextMovementAt = movementDeadline(minutes: interval)
        var tracker = LoungePopulationTracker()
        var lastCaptureErrorLogAt: TimeInterval = 0
        log("防卡移动间隔：\(interval.lowerBound)～\(interval.upperBound) 分钟")

        while isRunning && !Task.isCancelled {
            guard windowSelector.isWindowValid(windowID: windowID) else {
                finish(currentRunID, error: "游戏窗口已关闭或不可见")
                return
            }

            if pendingPartyAcceptedTriggers > 0 {
                pendingPartyAcceptedTriggers -= 1
                log("自动接受组队触发，释放一轮 BUFF")
                await castBuffsAndAnnounce(buffs, windowID: windowID)
                guard isRunning, !Task.isCancelled else { break }
            }

            do {
                let frame = try await minimap.captureMinimap()
                let counts = await Task.detached(priority: .userInitiated) {
                    LoungeMarkerCounts(
                        yellow: ColorDetector.detectPlayerMarker(in: frame).candidateCount,
                        orange: ColorDetector.detectTeammateMarkers(in: frame).points.count
                    )
                }.value
                if let change = tracker.observe(counts) {
                    log("休息室人数变化：\(change.previous.summary) → \(change.current.summary)")
                    if change.increased {
                        await castBuffsAndAnnounce(buffs, windowID: windowID)
                    }
                }
            } catch {
                let now = Date().timeIntervalSince1970
                if now - lastCaptureErrorLogAt >= 10 {
                    log("⚠️ 小地图读取失败，将继续重试：\(error.localizedDescription)")
                    lastCaptureErrorLogAt = now
                }
            }

            if Date().timeIntervalSince1970 >= nextMovementAt {
                await performAntiStuckMovement(windowID: windowID)
                nextMovementAt = movementDeadline(minutes: interval)
            }
            await sleep(1.0)
        }

        await human.releaseAll()
        finish(currentRunID)
    }

    private func castBuffsAndAnnounce(_ buffs: [BuffConfig], windowID: CGWindowID) async {
        guard await ensureGameFocus(windowID: windowID, reason: "释放休息室 BUFF") else { return }
        log("检测到人数增加，释放 \(buffs.count) 个 BUFF")
        for (index, buff) in buffs.enumerated() where isRunning && !Task.isCancelled {
            do {
                log("释放 BUFF: \(buff.key)")
                try await human.pressNamedKey(buff.key)
                await randomSleep(0.1...0.3)
                try await human.pressNamedKey(buff.key)
            } catch {
                onError?("BUFF \(buff.key) 失败：\(error.localizedDescription)")
            }
            if index < buffs.count - 1 {
                await randomSleep(2.0...3.0)
            }
        }
        guard isRunning, !Task.isCancelled else { return }
        do {
            await randomSleep(0.25...0.6)
            try await sendChatMessage("/隊伍")
            await randomSleep(0.35...0.8)
            let announcement = nextAnnouncement()
            let clockTime = currentClockTime()
            try await sendChatMessage(announcement, suffix: clockTime)
            log("已发送：\(announcement) \(clockTime)")
        } catch {
            onError?("发送 BUFF 完成消息失败：\(error.localizedDescription)")
        }
    }

    private func nextAnnouncement() -> String {
        let regular = [
            "BUFF放好了", "BUFF好了", "buff放完了", "buff好了", "状态放好了",
            "状态补好了", "技能放完了", "已经放好了", "都放好了", "这轮好了"
        ]
        let short = ["补完了", "好了", "可以了", "搞定", "搞定了"]
        let preferredPool = Int.random(in: 0..<100) < 85 ? regular : short
        let available = preferredPool.filter { $0 != lastAnnouncementBase }
        let base = (available.isEmpty ? regular + short : available).randomElement()
            ?? "BUFF放好了"
        lastAnnouncementBase = base

        let punctuationRoll = Int.random(in: 0..<100)
        let punctuation: String
        switch punctuationRoll {
        case 0..<70: punctuation = ""
        case 70..<90: punctuation = "。"
        default: punctuation = "~"
        }
        return base + punctuation
    }

    private func currentClockTime() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
    }

    /// 每条消息都重新打开聊天框。字符本身由 HumanInput 使用 50～120ms
    /// 的随机间隔输入，这里再为打开聊天和发送前留出短暂停顿。
    private func sendChatMessage(_ message: String, suffix: String? = nil) async throws {
        try await ChatInputTransactionCoordinator.shared.withTransaction {
            guard isRunning, !Task.isCancelled else { return }
            try await human.pressNamedKey("Enter")
            await randomSleep(0.18...0.42)
            try await human.pressNamedKey("Delete")
            await randomSleep(0.08...0.18)
            await human.typeText(message)
            await randomSleep(0.12...0.32)
            if let suffix {
                try await human.pressNamedKey("Space")
                await randomSleep(0.08...0.18)
                await human.typeText(suffix)
                await randomSleep(0.12...0.32)
            }
            try await human.pressNamedKey("Enter")
        }
    }

    private func performAntiStuckMovement(windowID: CGWindowID) async {
        guard await ensureGameFocus(windowID: windowID, reason: "防卡移动") else { return }
        log("执行防卡移动：短暂向右，再短暂向左")
        await human.tapDirection(.right, holdMS: 120...260, intervalMS: 80...220)
        guard isRunning, !Task.isCancelled else { return }
        await human.tapDirection(.left, holdMS: 120...260, intervalMS: 80...220)
    }

    private func movementDeadline(minutes: ClosedRange<Int>) -> TimeInterval {
        let selected = Int.random(in: minutes)
        log("下次防卡移动约在 \(selected) 分钟后")
        return Date().timeIntervalSince1970 + Double(selected * 60)
    }

    private func ensureGameFocus(windowID: CGWindowID, reason: String) async -> Bool {
        if windowSelector.isWindowOwnerFrontmost(windowID: windowID) { return true }
        for attempt in 1...24 where isRunning && !Task.isCancelled {
            _ = windowSelector.bringWindowToFront(windowID: windowID)
            await sleep(0.25)
            if windowSelector.isWindowOwnerFrontmost(windowID: windowID) {
                if attempt > 1 { log("\(reason)：第 \(attempt) 次尝试后游戏窗口已获得焦点") }
                return true
            }
        }
        log("⚠️ \(reason)焦点恢复失败：\(windowSelector.focusDebugDescription(windowID: windowID))")
        return false
    }

    private func finish(_ currentRunID: UUID, error: String? = nil) {
        if let error { onError?(error) }
        guard runID == currentRunID else { return }
        isRunning = false
        task = nil
        log("神殿模式 · 休息室已停止")
        onStopped?()
    }

    private func randomSleep(_ range: ClosedRange<Double>) async {
        await sleep(Double.random(in: range))
    }

    private func sleep(_ seconds: Double) async {
        guard seconds > 0, isRunning, !Task.isCancelled else { return }
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func log(_ message: String) {
        onLog?(message)
    }
}
