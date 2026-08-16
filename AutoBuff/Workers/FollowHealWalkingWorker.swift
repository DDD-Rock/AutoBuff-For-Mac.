import CoreGraphics
import Foundation

private enum FollowHealWalkingNavigation {
    static let centerAdjustInterval: ClosedRange<TimeInterval> = 12...15
    static let adjustDurationMS: ClosedRange<Int> = 200...300
    static let arrivalTolerance: CGFloat = 3
    static let returnTimeout: TimeInterval = 5

    static func directionToBase(currentX: CGFloat, baseX: CGFloat) -> HumanInput.Direction? {
        let delta = currentX - baseX
        guard abs(delta) > arrivalTolerance else { return nil }
        return delta > 0 ? .left : .right
    }

    static func isOutsideAnchorBand(currentX: CGFloat, baseX: CGFloat, tolerance: CGFloat) -> Bool {
        abs(currentX - baseX) > tolerance
    }

    static func centerDirection(currentX: CGFloat, baseX: CGFloat) -> HumanInput.Direction {
        directionToBase(currentX: currentX, baseX: baseX) ?? .right
    }
}

@available(macOS 14.0, *)
@MainActor
final class FollowHealWalkingWorker: ObservableObject {
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
    private let batchCastWindow = 10.0

    func start(settings: AppSettings, windowID: CGWindowID) {
        stop()
        let currentRunID = UUID()
        runID = currentRunID
        isRunning = true
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
        let buffs = settings.buffs.filter { $0.enabled && !$0.key.isEmpty && $0.duration > 0 }
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

        log("跟补左右走模式启动...")
        if buffs.isEmpty { log("未启用 BUFF，将只执行补血和位置修正") }
        guard await ensureGameFocus(windowID: windowID, reason: "跟补启动") else {
            onError?("无法将游戏窗口置于前台")
            await finish(runID: currentRunID)
            return
        }

        let baseX = CGFloat(healAnchorX)
        let tolerance = CGFloat(settings.followHealBoundaryTolerance)
        log("使用手动跟补基准点 X=\(format(baseX))，左右界限 ±\(format(tolerance))，纯方向键回位")
        if let region = settings.healMinimapRegion {
            minimap.clearMinimapRegion()
            minimap.setMinimapRegion(region)
            minimap.setExpectedPlayerPoint(nil)
            log("使用标记时的小地图区域 x=\(Int(region.minX))，y=\(Int(region.minY))，\(Int(region.width))×\(Int(region.height))")
        } else {
            minimap.clearMinimapRegion()
            minimap.setExpectedPlayerPoint(nil)
            log("未保存小地图区域，将在补血后再识别，避免开局空等")
        }

        var nextCast: [Int: TimeInterval] = [:]
        var nextAdjustAt = Date().timeIntervalSince1970
            + Double.random(in: FollowHealWalkingNavigation.centerAdjustInterval)

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
            if !buffsToCast(buffs: buffs, nextCast: nextCast, includeUpcoming: false).isEmpty {
                _ = await castAllReady(buffs: buffsToCast(buffs: buffs, nextCast: nextCast, includeUpcoming: true), nextCast: &nextCast, windowID: windowID)
                await randomSleep(0.8...1.2)
                continue
            }

            if minimap.minimapSize == nil {
                await performHealCycle(healKey: settings.healSkillKey, buffs: buffs, nextCast: &nextCast, windowID: windowID)
                if let rect = try? await minimap.autoDetectDarkRegion() {
                    log("小地图识别完成：\(Int(rect.width))×\(Int(rect.height))")
                }
                continue
            }

            if let player = try? await minimap.findPlayerPosition() {
                if FollowHealWalkingNavigation.isOutsideAnchorBand(currentX: player.x, baseX: baseX, tolerance: tolerance) {
                    await walkBackToAnchor(startX: player.x, baseX: baseX, tolerance: tolerance, buffs: buffs, nextCast: &nextCast, windowID: windowID)
                    continue
                }
                if Date().timeIntervalSince1970 >= nextAdjustAt {
                    await walkCenterAdjustment(currentX: player.x, baseX: baseX, buffs: buffs, nextCast: &nextCast, windowID: windowID)
                    nextAdjustAt = Date().timeIntervalSince1970 + Double.random(in: FollowHealWalkingNavigation.centerAdjustInterval)
                    continue
                }
            }

            await performHealCycle(healKey: settings.healSkillKey, buffs: buffs, nextCast: &nextCast, windowID: windowID)
        }
        await finish(runID: currentRunID)
    }

    private func walkBackToAnchor(
        startX: CGFloat,
        baseX: CGFloat,
        tolerance: CGFloat,
        buffs: [BuffConfig],
        nextCast: inout [Int: TimeInterval],
        windowID: CGWindowID
    ) async {
        guard var direction = FollowHealWalkingNavigation.directionToBase(currentX: startX, baseX: baseX) else {
            await human.stopMove()
            return
        }
        guard await ensureGameFocus(windowID: windowID, reason: "左右走回位") else { return }
        await move(direction)
        let startedAt = Date().timeIntervalSince1970
        while isRunning && !Task.isCancelled {
            if await castIfBuffDue(buffs: buffs, nextCast: &nextCast, windowID: windowID) { return }
            await randomSleep(0.08...0.14)
            guard let player = try? await minimap.findPlayerPosition() else {
                await human.stopMove()
                log("⚠️ 左右走回位时丢失玩家黄点，停止移动")
                return
            }
            if !FollowHealWalkingNavigation.isOutsideAnchorBand(currentX: player.x, baseX: baseX, tolerance: tolerance) {
                await human.stopMove()
                log("已回到基准区域：当前X=\(format(player.x))，基准X=\(format(baseX))")
                return
            }
            guard let needed = FollowHealWalkingNavigation.directionToBase(currentX: player.x, baseX: baseX) else {
                await human.stopMove()
                return
            }
            if needed != direction {
                await human.stopMove()
                await randomSleep(0.08...0.18)
                direction = needed
                await move(direction)
            }
            if Date().timeIntervalSince1970 - startedAt > FollowHealWalkingNavigation.returnTimeout {
                await human.stopMove()
                log("⚠️ 左右走回位超时，等待下轮检测")
                return
            }
        }
        await human.stopMove()
    }

    private func walkCenterAdjustment(
        currentX: CGFloat,
        baseX: CGFloat,
        buffs: [BuffConfig],
        nextCast: inout [Int: TimeInterval],
        windowID: CGWindowID
    ) async {
        let direction = FollowHealWalkingNavigation.centerDirection(currentX: currentX, baseX: baseX)
        log("左右走修正：当前X=\(format(currentX))，向\(direction == .left ? "左" : "右")小走后继续补血")
        if await castIfBuffDue(buffs: buffs, nextCast: &nextCast, windowID: windowID) { return }
        guard await ensureGameFocus(windowID: windowID, reason: "左右走修正") else { return }
        await move(direction)
        await sleep(Double.random(in: FollowHealWalkingNavigation.adjustDurationMS) / 1000)
        await human.stopMove()
        await randomSleep(0.22...0.75)
    }

    private func performHealCycle(healKey: String, buffs: [BuffConfig], nextCast: inout [Int: TimeInterval], windowID: CGWindowID) async {
        if await castIfBuffDue(buffs: buffs, nextCast: &nextCast, windowID: windowID) { return }
        guard await ensureGameFocus(windowID: windowID, reason: "释放加血技能") else { return }
        let roll = Int.random(in: 1...100)
        if roll <= 25 {
            await burstHeal(healKey: healKey, buffs: buffs, nextCast: &nextCast, windowID: windowID)
        } else if roll <= 45 {
            await timedHealTap(healKey: healKey, holdMS: 180...420, afterDelay: 0.12...0.30)
        } else {
            await interruptibleHealHold(healKey: healKey, buffs: buffs, nextCast: &nextCast, windowID: windowID)
            await randomSleep(0.16...0.36)
        }
    }

    private func burstHeal(healKey: String, buffs: [BuffConfig], nextCast: inout [Int: TimeInterval], windowID: CGWindowID) async {
        let count = Int.random(in: 2...4)
        for index in 0..<count where isRunning && !Task.isCancelled {
            if await castIfBuffDue(buffs: buffs, nextCast: &nextCast, windowID: windowID) { return }
            await timedHealTap(healKey: healKey, holdMS: 45...120, afterDelay: 0.06...0.18)
            if index == count - 1 { await randomSleep(0.12...0.35) }
        }
    }

    private func timedHealTap(healKey: String, holdMS: ClosedRange<Int>, afterDelay: ClosedRange<Double>) async {
        do {
            _ = try await human.tapNamedKey(healKey, holdMS: holdMS)
            await randomSleep(afterDelay)
        } catch {
            onError?("加血键错误: \(error.localizedDescription)")
        }
    }

    private func interruptibleHealHold(healKey: String, buffs: [BuffConfig], nextCast: inout [Int: TimeInterval], windowID: CGWindowID) async {
        do {
            let keyCode = try await human.holdNamedKey(healKey)
            let endAt = Date().timeIntervalSince1970 + Double.random(in: 0.65...1.40)
            while isRunning && !Task.isCancelled && Date().timeIntervalSince1970 < endAt {
                if !buffsToCast(buffs: buffs, nextCast: nextCast, includeUpcoming: false).isEmpty {
                    await human.releaseKey(keyCode)
                    _ = await castIfBuffDue(buffs: buffs, nextCast: &nextCast, windowID: windowID)
                    return
                }
                await randomSleep(0.10...0.15)
            }
            await human.releaseKey(keyCode)
        } catch {
            onError?("加血键错误: \(error.localizedDescription)")
        }
    }

    private func castIfBuffDue(buffs: [BuffConfig], nextCast: inout [Int: TimeInterval], windowID: CGWindowID) async -> Bool {
        let due = buffsToCast(buffs: buffs, nextCast: nextCast, includeUpcoming: false)
        guard !due.isEmpty else { return false }
        await human.stopMove()
        _ = await castAllReady(buffs: buffsToCast(buffs: buffs, nextCast: nextCast, includeUpcoming: true), nextCast: &nextCast, windowID: windowID)
        await randomSleep(0.8...1.2)
        return true
    }

    private func castAllReady(buffs: [BuffConfig], nextCast: inout [Int: TimeInterval], windowID: CGWindowID) async -> Bool {
        guard !buffs.isEmpty else { return false }
        guard await ensureGameFocus(windowID: windowID, reason: "释放 BUFF") else { return false }
        for (index, buff) in buffs.enumerated() where isRunning && !Task.isCancelled {
            log("释放 BUFF: \(buff.key)")
            do {
                _ = try await human.pressNamedKey(buff.key)
                await randomSleep(0.1...0.3)
                let pressedAt = try await human.pressNamedKey(buff.key)
                let releaseAt = CountdownTiming.nextRelease(pressedAt: pressedAt, interval: buff.duration)
                nextCast[buff.id] = releaseAt
                countdownPublisher.replaceDeadlines(nextCast, now: pressedAt)
            } catch {
                onError?("BUFF \(buff.key) 失败: \(error.localizedDescription)")
            }
            if index < buffs.count - 1 { await randomSleep(0.25...0.65) }
        }
        return true
    }

    private func buffsToCast(buffs: [BuffConfig], nextCast: [Int: TimeInterval], includeUpcoming: Bool) -> [BuffConfig] {
        let now = Date().timeIntervalSince1970
        let window = includeUpcoming ? batchCastWindow : 0
        return buffs.filter { (nextCast[$0.id] ?? 0) - now <= window }
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
        return false
    }

    private func move(_ direction: HumanInput.Direction) async {
        if direction == .left {
            await human.moveLeft()
        } else {
            await human.moveRight()
        }
    }

    private func finish(runID currentRunID: UUID) async {
        await human.releaseAll()
        countdownPublisher.stop()
        log("跟补左右走模式已停止")
        if runID == currentRunID {
            isRunning = false
            task = nil
            onStopped?()
        }
    }

    private func randomSleep(_ range: ClosedRange<Double>) async { await sleep(Double.random(in: range)) }
    private func sleep(_ seconds: Double) async {
        guard seconds > 0, isRunning, !Task.isCancelled else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    private func format(_ value: CGFloat) -> String { String(format: "%.1f", value) }
    private func log(_ message: String) { onLog?(message) }
}
