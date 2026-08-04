import CoreGraphics
import Foundation

enum FollowHealNavigation {
    static let playerMarkerMinArea = 5
    static let centerAdjustIntervalRange: ClosedRange<TimeInterval> = 4...7
    static let healHoldRange: ClosedRange<TimeInterval> = 8...12
    static let healGapRange: ClosedRange<TimeInterval> = 0.25...0.60
    static let newCollisionDistance: CGFloat = 1
    static let protectiveBoundaryRatio: CGFloat = 0.75

    struct TeleportExcursionGuard {
        private(set) var lastTeleportDirection: HumanInput.Direction?
        private(set) var awaitingStablePosition = false
        private(set) var guardedReverseDirection: HumanInput.Direction?
        private(set) var guardedDistance: CGFloat?

        mutating func recordTeleport(direction: HumanInput.Direction) {
            lastTeleportDirection = direction
            awaitingStablePosition = true
            guardedReverseDirection = nil
            guardedDistance = nil
        }

        mutating func shouldCorrect(
            currentX: CGFloat,
            baseX: CGFloat,
            tolerance: CGFloat
        ) -> Bool {
            guard FollowHealNavigation.isOutsideAnchorBand(
                currentX: currentX,
                baseX: baseX,
                tolerance: tolerance
            ) else {
                clearGuard()
                return false
            }

            let direction = FollowHealNavigation.teleportDirectionToBase(
                currentX: currentX,
                baseX: baseX
            )
            let distance = abs(currentX - baseX)

            if awaitingStablePosition {
                awaitingStablePosition = false
                // Still outside on the original side: the marker has settled,
                // so another teleport toward the anchor is allowed.
                if direction == lastTeleportDirection {
                    guardedReverseDirection = nil
                    guardedDistance = nil
                    return true
                }

                // Crossing the anchor is the result of this teleport, not a
                // new collision. Do not immediately teleport back.
                guardedReverseDirection = direction
                guardedDistance = distance
                return false
            }

            if direction == guardedReverseDirection {
                let baseline = guardedDistance ?? distance
                if distance >= baseline + FollowHealNavigation.newCollisionDistance {
                    guardedReverseDirection = nil
                    guardedDistance = nil
                    return true
                }
                guardedDistance = min(baseline, distance)
                return false
            }

            guardedReverseDirection = nil
            guardedDistance = nil
            return true
        }

        private mutating func clearGuard() {
            awaitingStablePosition = false
            guardedReverseDirection = nil
            guardedDistance = nil
        }
    }

    static func teleportDirectionToBase(currentX: CGFloat, baseX: CGFloat) -> HumanInput.Direction? {
        if currentX < baseX { return .right }
        if currentX > baseX { return .left }
        return nil
    }

    static func isOutsideAnchorBand(
        currentX: CGFloat,
        baseX: CGFloat,
        tolerance: CGFloat
    ) -> Bool {
        abs(currentX - baseX) > tolerance
    }

    static func protectiveAnchorTolerance(_ boundaryTolerance: CGFloat) -> CGFloat {
        max(0.5, boundaryTolerance * protectiveBoundaryRatio)
    }

    static func requiresImmediateLeftRecovery(
        currentX: CGFloat,
        baseX: CGFloat,
        boundaryTolerance: CGFloat
    ) -> Bool {
        currentX < baseX - max(0, boundaryTolerance)
    }

    static func nextCenterAdjustInterval() -> TimeInterval {
        Double.random(in: centerAdjustIntervalRange)
    }

    static func updatedCenterAdjustDeadline(
        currentDeadline: TimeInterval,
        now: TimeInterval,
        scheduledTriggered: Bool
    ) -> TimeInterval {
        guard scheduledTriggered else { return currentDeadline }
        return now + nextCenterAdjustInterval()
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
        guard !settings.teleportSkillKey.isEmpty else {
            onError?("请先设置瞬移技能键")
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
        let boundaryTolerance = CGFloat(settings.followHealBoundaryTolerance)
        let protectiveTolerance = FollowHealNavigation.protectiveAnchorTolerance(
            boundaryTolerance
        )
        log(
            "使用手动跟补基准点 X=\(format(baseX))，"
                + "左右界限 ±\(format(boundaryTolerance))，"
                + "提前保护 ±\(format(protectiveTolerance))"
        )
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
        var nextCenterAdjustAt = Date().timeIntervalSince1970 + FollowHealNavigation.nextCenterAdjustInterval()
        var excursionGuard = FollowHealNavigation.TeleportExcursionGuard()

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
                await randomSleep(0.18...0.42)
                continue
            }

            if minimap.minimapSize == nil {
                await performContinuousHealCycle(
                    healKey: settings.healSkillKey,
                    teleportKey: settings.teleportSkillKey,
                    baseX: baseX,
                    boundaryTolerance: protectiveTolerance,
                    hardBoundaryTolerance: boundaryTolerance,
                    buffs: buffs,
                    nextCast: &nextCast,
                    nextCenterAdjustAt: &nextCenterAdjustAt,
                    excursionGuard: &excursionGuard,
                    windowID: windowID
                )
                if let rect = try? await minimap.autoDetectDarkRegion() {
                    log("小地图识别完成：\(Int(rect.width))×\(Int(rect.height))")
                } else {
                    log("⚠️ 暂未识别到小地图：\(minimap.lastDetectionSummary)")
                }
                continue
            }

            await performContinuousHealCycle(
                healKey: settings.healSkillKey,
                teleportKey: settings.teleportSkillKey,
                baseX: baseX,
                boundaryTolerance: protectiveTolerance,
                hardBoundaryTolerance: boundaryTolerance,
                buffs: buffs,
                nextCast: &nextCast,
                nextCenterAdjustAt: &nextCenterAdjustAt,
                excursionGuard: &excursionGuard,
                windowID: windowID
            )
        }

        await finish(runID: currentRunID)
    }

    private func performContinuousHealCycle(
        healKey: String,
        teleportKey: String,
        baseX: CGFloat,
        boundaryTolerance: CGFloat,
        hardBoundaryTolerance: CGFloat,
        buffs: [BuffConfig],
        nextCast: inout [Int: TimeInterval],
        nextCenterAdjustAt: inout TimeInterval,
        excursionGuard: inout FollowHealNavigation.TeleportExcursionGuard,
        windowID: CGWindowID
    ) async {
        guard await ensureGameFocus(windowID: windowID, reason: "持续释放加血技能") else {
            return
        }

        let healKeyCode: CGKeyCode
        do {
            healKeyCode = try await human.holdNamedKey(healKey)
        } catch {
            onError?("加血键错误: \(error.localizedDescription)")
            return
        }
        let endAt = Date().timeIntervalSince1970
            + Double.random(in: FollowHealNavigation.healHoldRange)
        var missingPlayerCount = 0
        while isRunning && !Task.isCancelled && Date().timeIntervalSince1970 < endAt {
            if !buffsToCast(buffs: buffs, nextCast: nextCast, includeUpcoming: false).isEmpty {
                await human.releaseKey(healKeyCode)
                _ = await castIfBuffDue(buffs: buffs, nextCast: &nextCast, windowID: windowID)
                return
            }
            guard windowSelector.isWindowValid(windowID: windowID),
                  windowSelector.isWindowOwnerFrontmost(windowID: windowID) else {
                await human.releaseKey(healKeyCode)
                return
            }

            if minimap.minimapSize != nil,
               let player = try? await minimap.findPlayerPosition(
                   minArea: FollowHealNavigation.playerMarkerMinArea
               ) {
                missingPlayerCount = 0
                logPlayerCoordinateIfDue(player, baseX: baseX, phase: "持续补血")
                let now = Date().timeIntervalSince1970
                let isNewExcursion = excursionGuard.shouldCorrect(
                    currentX: player.x,
                    baseX: baseX,
                    tolerance: boundaryTolerance
                )
                let forceLeftRecovery = FollowHealNavigation.requiresImmediateLeftRecovery(
                    currentX: player.x,
                    baseX: baseX,
                    boundaryTolerance: hardBoundaryTolerance
                )
                let isScheduledAdjustment = now >= nextCenterAdjustAt
                if isNewExcursion || forceLeftRecovery || isScheduledAdjustment {
                    if let direction = FollowHealNavigation.teleportDirectionToBase(
                        currentX: player.x,
                        baseX: baseX
                    ) {
                        let teleported = await teleportTowardBase(
                            direction: direction,
                            teleportKey: teleportKey,
                            currentX: player.x,
                            baseX: baseX,
                            urgent: isNewExcursion || forceLeftRecovery
                        )
                        if teleported {
                            excursionGuard.recordTeleport(direction: direction)
                        }
                    }
                    nextCenterAdjustAt = FollowHealNavigation.updatedCenterAdjustDeadline(
                        currentDeadline: nextCenterAdjustAt,
                        now: now,
                        scheduledTriggered: isScheduledAdjustment
                    )
                }
            } else if minimap.minimapSize != nil {
                missingPlayerCount += 1
                if missingPlayerCount == 1 || missingPlayerCount % 8 == 0 {
                    log("⚠️ 暂时丢失玩家黄点 \(missingPlayerCount) 次：\(minimap.lastPlayerDetectionSummary)")
                }
            }
            await randomSleep(0.035...0.065)
        }
        await human.releaseKey(healKeyCode)
        if isRunning && !Task.isCancelled {
            await randomSleep(FollowHealNavigation.healGapRange)
        }
    }

    private func teleportTowardBase(
        direction: HumanInput.Direction,
        teleportKey: String,
        currentX: CGFloat,
        baseX: CGFloat,
        urgent: Bool
    ) async -> Bool {
        log(
            "\(urgent ? "快速回位" : "跟补修正")：当前X=\(format(currentX))，"
                + "按住\(direction == .left ? "左" : "右")方向并短按瞬移"
        )
        do {
            try await human.performDirectionalSkill(
                direction,
                skillKey: teleportKey,
                directionLeadMS: Int.random(in: 35...75),
                skillHoldMS: Int.random(in: 50...110),
                directionReleaseDelayMS: Int.random(in: 25...65)
            )
            if urgent {
                await waitForPlayerMarkerStability()
            } else {
                await randomSleep(0.50...0.80)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            onError?("瞬移键错误: \(error.localizedDescription)")
            return false
        }
    }

    private func waitForPlayerMarkerStability() async {
        let startedAt = Date().timeIntervalSince1970
        let minimumEnd = startedAt + Double.random(in: 0.15...0.25)
        let deadline = startedAt + 0.40
        var previousX: CGFloat?
        var stableFrames = 0

        while isRunning && !Task.isCancelled && Date().timeIntervalSince1970 < deadline {
            if let player = try? await minimap.findPlayerPosition(
                minArea: FollowHealNavigation.playerMarkerMinArea
            ) {
                if let previousX, abs(player.x - previousX) <= 0.75 {
                    stableFrames += 1
                } else {
                    stableFrames = 1
                }
                previousX = player.x
                if Date().timeIntervalSince1970 >= minimumEnd && stableFrames >= 2 {
                    return
                }
            } else {
                previousX = nil
                stableFrames = 0
            }
            await randomSleep(0.03...0.05)
        }
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
        await randomSleep(0.18...0.42)
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
