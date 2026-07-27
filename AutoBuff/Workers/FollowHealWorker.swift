import CoreGraphics
import Foundation

enum FollowHealNavigation {
    static let arrivalTolerance: CGFloat = 3.0
    static let movementObservedTolerance: CGFloat = 1.0
    static let anchorBandTolerance: CGFloat = 6.0
    static let playerMarkerMinArea = 5
    static let centerAdjustIntervalRange: ClosedRange<TimeInterval> = 12...15

    static func directionToBase(currentX: CGFloat, baseX: CGFloat) -> HumanInput.Direction? {
        let delta = currentX - baseX
        if abs(delta) <= arrivalTolerance { return nil }
        return delta > 0 ? .left : .right
    }

    static func isOutsideAnchorBand(currentX: CGFloat, baseX: CGFloat) -> Bool {
        abs(currentX - baseX) > anchorBandTolerance
    }

    static func directionForCenterAdjustment(currentX: CGFloat, baseX: CGFloat) -> HumanInput.Direction {
        directionToBase(currentX: currentX, baseX: baseX) ?? .right
    }

    static func nextCenterAdjustInterval() -> TimeInterval {
        Double.random(in: centerAdjustIntervalRange)
    }
}

@available(macOS 14.0, *)
@MainActor
final class FollowHealWorker: ObservableObject {
    var onLog: ((String) -> Void)?
    var onCountdown: (([Int: Int]) -> Void)?
    var onError: ((String) -> Void)?
    var onStopped: (() -> Void)?

    private let human = HumanInput()
    private let windowSelector = WindowSelector()
    private let minimap = MinimapMonitor()
    private let countdownPublisher = CountdownPublisher()

    private var task: Task<Void, Never>?
    private var runID = UUID()
    private(set) var isRunning = false
    private var nextPlayerCoordinateLogAt: TimeInterval = 0

    private let batchCastWindow = 10.0
    private let playerCoordinateLogInterval: TimeInterval = 1.0

    func start(settings: AppSettings, windowID: CGWindowID) {
        stop()
        let currentRunID = UUID()
        runID = currentRunID
        isRunning = true
        nextPlayerCoordinateLogAt = 0
        countdownPublisher.start { [weak self] info in
            self?.onCountdown?(info)
        }
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
        countdownPublisher.stop()
        Task { await human.releaseAll() }
    }

    private func run(settings: AppSettings, windowID: CGWindowID, runID currentRunID: UUID) async {
        let buffs = settings.buffs.filter {
            $0.enabled && !$0.key.isEmpty && $0.duration > 0
        }
        guard !settings.healSkillKey.isEmpty else {
            onError?("请先设置加血技能键")
            await finish(runID: currentRunID)
            return
        }
        guard let healAnchorX = settings.healAnchorX else {
            onError?("请先标记跟补基准点")
            await finish(runID: currentRunID)
            return
        }

        log("跟补模式启动...")
        if buffs.isEmpty {
            log("未启用 BUFF，将只执行补血和位置修正")
        }
        guard await ensureGameFocus(windowID: windowID, reason: "跟补启动") else {
            onError?("无法将游戏窗口置于前台")
            await finish(runID: currentRunID)
            return
        }

        let baseX = CGFloat(healAnchorX)
        log("使用手动跟补基准点 X=\(format(baseX))")
        if let savedRegion = settings.healMinimapRegion {
            minimap.clearMinimapRegion()
            minimap.setMinimapRegion(savedRegion)
            // The marked anchor is the destination, not necessarily the
            // player's current position. Biasing the first detection toward it
            // can lock tracking onto a static yellow map decoration.
            minimap.setExpectedPlayerPoint(nil)
            log(
                "使用标记时的小地图区域 x=\(Int(savedRegion.minX)), "
                    + "y=\(Int(savedRegion.minY)), "
                    + "\(Int(savedRegion.width))×\(Int(savedRegion.height))"
            )
        } else {
            minimap.clearMinimapRegion()
            minimap.setExpectedPlayerPoint(nil)
            log("未保存小地图区域，将在补血后再识别，避免开局空等")
        }

        var nextCast: [Int: TimeInterval] = [:]
        var lastKnownX = baseX
        var nextCenterAdjustAt = Date().timeIntervalSince1970 + FollowHealNavigation.nextCenterAdjustInterval()
        var missingPlayerCount = 0

        while isRunning && !Task.isCancelled {
            guard windowSelector.isWindowValid(windowID: windowID) else {
                onError?("游戏窗口已关闭或不可见")
                break
            }
            if !windowSelector.isWindowOwnerFrontmost(windowID: windowID) {
                await human.releaseAll()
                guard await ensureGameFocus(windowID: windowID, reason: "跟补恢复") else {
                    onError?("无法恢复游戏窗口焦点")
                    break
                }
            }

            var due = buffsToCast(buffs: buffs, nextCast: nextCast, includeUpcoming: false)
            if !due.isEmpty {
                due = buffsToCast(buffs: buffs, nextCast: nextCast, includeUpcoming: true)
                _ = await castAllReady(buffs: due, nextCast: &nextCast, windowID: windowID)
                await randomSleep(0.8...1.2)
                continue
            }

            if minimap.minimapSize == nil {
                await performHealCycle(
                    healKey: settings.healSkillKey,
                    buffs: buffs,
                    nextCast: &nextCast,
                    windowID: windowID
                )
                if let rect = try? await minimap.autoDetectDarkRegion() {
                    log("小地图识别完成：\(Int(rect.width))×\(Int(rect.height))")
                } else {
                    log("⚠️ 暂未识别到小地图：\(minimap.lastDetectionSummary)")
                }
                continue
            }

            if let player = try? await minimap.findPlayerPosition(
                minArea: FollowHealNavigation.playerMarkerMinArea
            ) {
                missingPlayerCount = 0
                logPlayerCoordinateIfDue(
                    player,
                    baseX: baseX,
                    phase: "常规检测"
                )
                if abs(player.x - lastKnownX) > FollowHealNavigation.movementObservedTolerance {
                    lastKnownX = player.x
                }

                if FollowHealNavigation.isOutsideAnchorBand(currentX: player.x, baseX: baseX) {
                    log("检测到离开基准区域：当前X=\(format(player.x))，基准X=\(format(baseX))")
                    let canContinue = await returnToBase(
                        baseX: baseX,
                        startX: player.x,
                        buffs: buffs,
                        nextCast: &nextCast,
                        windowID: windowID
                    )
                    if !canContinue { break }
                    continue
                }

                let now = Date().timeIntervalSince1970
                if now >= nextCenterAdjustAt {
                    await centerAdjustStep(
                        currentX: player.x,
                        baseX: baseX,
                        adjustDurationMS: settings.followHealAdjustDurationMS,
                        buffs: buffs,
                        nextCast: &nextCast,
                        windowID: windowID
                    )
                    nextCenterAdjustAt = Date().timeIntervalSince1970 + FollowHealNavigation.nextCenterAdjustInterval()
                    continue
                }
            } else {
                missingPlayerCount += 1
                await human.stopMove()
                if missingPlayerCount == 1 || missingPlayerCount % 8 == 0 {
                    log("⚠️ 暂时丢失玩家黄点 \(missingPlayerCount) 次：\(minimap.lastPlayerDetectionSummary)")
                }
            }

            await performHealCycle(
                healKey: settings.healSkillKey,
                buffs: buffs,
                nextCast: &nextCast,
                windowID: windowID
            )
        }

        await finish(runID: currentRunID)
    }

    private func returnToBase(
        baseX: CGFloat,
        startX: CGFloat,
        buffs: [BuffConfig],
        nextCast: inout [Int: TimeInterval],
        windowID: CGWindowID
    ) async -> Bool {
        var currentX = startX
        guard var currentDirection = FollowHealNavigation.directionToBase(currentX: currentX, baseX: baseX) else {
            await human.stopMove()
            return true
        }
        guard await ensureGameFocus(windowID: windowID, reason: "回基准区域") else {
            return false
        }
        if currentDirection == .left {
            await human.moveLeft()
        } else {
            await human.moveRight()
        }

        let startedAt = Date().timeIntervalSince1970
        while isRunning && !Task.isCancelled {
            if await castIfBuffDue(buffs: buffs, nextCast: &nextCast, windowID: windowID) {
                return true
            }
            await sleep(Double.random(in: 0.08...0.14))
            guard let player = try? await minimap.findPlayerPosition(
                minArea: FollowHealNavigation.playerMarkerMinArea
            ) else {
                await human.stopMove()
                log("⚠️ 回基准区域时丢失玩家黄点，停止移动")
                return true
            }
            currentX = player.x
            logPlayerCoordinateIfDue(
                player,
                baseX: baseX,
                phase: "回基准移动"
            )
            if !FollowHealNavigation.isOutsideAnchorBand(currentX: currentX, baseX: baseX) {
                await human.stopMove()
                log("已回到基准区域：当前X=\(format(currentX))，基准X=\(format(baseX))")
                return true
            }
            guard let neededDirection = FollowHealNavigation.directionToBase(currentX: currentX, baseX: baseX) else {
                await human.stopMove()
                return true
            }
            if neededDirection != currentDirection {
                await human.stopMove()
                await randomSleep(0.08...0.18)
                if neededDirection == .left {
                    await human.moveLeft()
                } else {
                    await human.moveRight()
                }
                currentDirection = neededDirection
            }
            if Date().timeIntervalSince1970 - startedAt > 5 {
                await human.stopMove()
                log("⚠️ 回基准区域超时，停止移动等待下轮检测")
                return true
            }
        }
        await human.stopMove()
        return true
    }

    private func centerAdjustStep(
        currentX: CGFloat,
        baseX: CGFloat,
        adjustDurationMS: ClosedRange<Int>,
        buffs: [BuffConfig],
        nextCast: inout [Int: TimeInterval],
        windowID: CGWindowID
    ) async {
        let direction = FollowHealNavigation.directionForCenterAdjustment(currentX: currentX, baseX: baseX)
        log("跟补修正：当前X=\(format(currentX))，向\(direction == .left ? "左" : "右")小走后继续补血")
        if await castIfBuffDue(buffs: buffs, nextCast: &nextCast, windowID: windowID) {
            return
        }
        guard await ensureGameFocus(windowID: windowID, reason: "跟补修正") else {
            return
        }
        if direction == .left {
            await human.moveLeft()
        } else {
            await human.moveRight()
        }
        let durationMS = Int.random(in: adjustDurationMS)
        await sleep(Double(durationMS) / 1000)
        await human.stopMove()
        await randomSleep(0.22...0.75)
    }

    private func performHealCycle(
        healKey: String,
        buffs: [BuffConfig],
        nextCast: inout [Int: TimeInterval],
        windowID: CGWindowID
    ) async {
        if await castIfBuffDue(buffs: buffs, nextCast: &nextCast, windowID: windowID) {
            return
        }
        guard await ensureGameFocus(windowID: windowID, reason: "释放加血技能") else {
            return
        }

        let roll = Int.random(in: 1...100)
        if roll <= 25 {
            await burstHeal(healKey: healKey, buffs: buffs, nextCast: &nextCast, windowID: windowID)
        } else if roll <= 45 {
            await timedHealTap(
                healKey: healKey,
                holdMS: 180...420,
                afterDelay: 0.12...0.30
            )
        } else {
            await interruptibleHealHold(
                healKey: healKey,
                holdMS: 650...1400,
                buffs: buffs,
                nextCast: &nextCast,
                windowID: windowID
            )
            await randomSleep(0.16...0.36)
        }
    }

    private func burstHeal(
        healKey: String,
        buffs: [BuffConfig],
        nextCast: inout [Int: TimeInterval],
        windowID: CGWindowID
    ) async {
        let count = Int.random(in: 2...4)
        for index in 0..<count where isRunning && !Task.isCancelled {
            if await castIfBuffDue(buffs: buffs, nextCast: &nextCast, windowID: windowID) {
                return
            }
            await timedHealTap(healKey: healKey, holdMS: 45...120, afterDelay: 0.06...0.18)
            if index == count - 1 {
                await randomSleep(0.12...0.35)
            }
        }
    }

    private func timedHealTap(
        healKey: String,
        holdMS: ClosedRange<Int>,
        afterDelay: ClosedRange<Double>
    ) async {
        do {
            _ = try await human.tapNamedKey(healKey, holdMS: holdMS)
            await randomSleep(afterDelay)
        } catch {
            onError?("加血键错误: \(error.localizedDescription)")
        }
    }

    private func interruptibleHealHold(
        healKey: String,
        holdMS: ClosedRange<Int>,
        buffs: [BuffConfig],
        nextCast: inout [Int: TimeInterval],
        windowID: CGWindowID
    ) async {
        let keyCode: CGKeyCode
        do {
            keyCode = try await human.holdNamedKey(healKey)
        } catch {
            onError?("加血键错误: \(error.localizedDescription)")
            return
        }

        let endAt = Date().timeIntervalSince1970 + Double.random(in: Double(holdMS.lowerBound)...Double(holdMS.upperBound)) / 1000
        while isRunning && !Task.isCancelled && Date().timeIntervalSince1970 < endAt {
            if !buffsToCast(buffs: buffs, nextCast: nextCast, includeUpcoming: false).isEmpty {
                await human.releaseKey(keyCode)
                _ = await castIfBuffDue(buffs: buffs, nextCast: &nextCast, windowID: windowID)
                return
            }
            await randomSleep(0.10...0.15)
        }
        await human.releaseKey(keyCode)
    }

    private func castIfBuffDue(
        buffs: [BuffConfig],
        nextCast: inout [Int: TimeInterval],
        windowID: CGWindowID
    ) async -> Bool {
        let due = buffsToCast(buffs: buffs, nextCast: nextCast, includeUpcoming: false)
        guard !due.isEmpty else { return false }
        let batch = buffsToCast(buffs: buffs, nextCast: nextCast, includeUpcoming: true)
        await human.stopMove()
        _ = await castAllReady(buffs: batch, nextCast: &nextCast, windowID: windowID)
        await randomSleep(0.8...1.2)
        return true
    }

    private func castAllReady(
        buffs: [BuffConfig],
        nextCast: inout [Int: TimeInterval],
        windowID: CGWindowID
    ) async -> Bool {
        guard !buffs.isEmpty else { return false }
        log("准备释放 \(buffs.count) 个 BUFF")
        guard await ensureGameFocus(windowID: windowID, reason: "释放 BUFF") else {
            log("❌ 释放 BUFF 前无法确认游戏窗口焦点")
            return false
        }
        for (index, buff) in buffs.enumerated() where isRunning && !Task.isCancelled {
            log("释放 BUFF: \(buff.key)")
            do {
                try await human.pressNamedKey(buff.key)
                await randomSleep(0.1...0.3)
                let finalPressedAt = try await human.pressNamedKey(buff.key)
                let releaseAt = CountdownTiming.nextRelease(
                    pressedAt: finalPressedAt,
                    interval: buff.duration
                )
                nextCast[buff.id] = releaseAt
                countdownPublisher.replaceDeadlines(nextCast, now: finalPressedAt)
                log(
                    "BUFF \(buff.key) 倒计时 \(CountdownTiming.remainingSeconds(until: releaseAt, now: finalPressedAt)) 秒，"
                    + "下次释放 \(CountdownTiming.clockText(for: releaseAt))"
                )
            } catch {
                onError?("BUFF \(buff.key) 失败: \(error.localizedDescription)")
            }
            if index < buffs.count - 1 {
                await randomSleep(0.25...0.65)
            }
        }
        return true
    }

    private func buffsToCast(
        buffs: [BuffConfig],
        nextCast: [Int: TimeInterval],
        includeUpcoming: Bool
    ) -> [BuffConfig] {
        let now = Date().timeIntervalSince1970
        let window = includeUpcoming ? batchCastWindow : 0
        return buffs.filter {
            (nextCast[$0.id] ?? 0) - now <= window
        }
    }

    private func ensureGameFocus(windowID: CGWindowID, reason: String) async -> Bool {
        if windowSelector.isWindowOwnerFrontmost(windowID: windowID) {
            return true
        }
        for attempt in 1...24 where isRunning && !Task.isCancelled {
            _ = windowSelector.bringWindowToFront(windowID: windowID)
            await sleep(0.25)
            if windowSelector.isWindowOwnerFrontmost(windowID: windowID) {
                if attempt > 1 {
                    log("\(reason)：第 \(attempt) 次尝试后游戏窗口已获得焦点")
                }
                return true
            }
        }
        log("⚠️ \(reason)焦点恢复失败：\(windowSelector.focusDebugDescription(windowID: windowID))")
        return false
    }

    private func finish(runID currentRunID: UUID) async {
        await human.releaseAll()
        countdownPublisher.stop()
        log("跟补模式已停止")
        if runID == currentRunID {
            isRunning = false
            task = nil
            onStopped?()
        }
    }

    private func randomSleep(_ range: ClosedRange<Double>) async {
        await sleep(Double.random(in: range))
    }

    private func sleep(_ seconds: Double) async {
        guard seconds > 0, isRunning, !Task.isCancelled else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func format(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }

    private func logPlayerCoordinateIfDue(
        _ point: CGPoint,
        baseX: CGFloat,
        phase: String
    ) {
        let now = Date().timeIntervalSince1970
        guard now >= nextPlayerCoordinateLogAt else { return }
        nextPlayerCoordinateLogAt = now + playerCoordinateLogInterval
        log(
            "黄点坐标 [\(phase)] X=\(format(point.x)), "
                + "Y=\(format(point.y)), 基准X=\(format(baseX))"
        )
    }

    private func log(_ message: String) {
        onLog?(message)
    }
}
