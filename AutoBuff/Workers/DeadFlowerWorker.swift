import CoreGraphics
import Foundation

@available(macOS 14.0, *)
@MainActor
final class DeadFlowerWorker: ObservableObject {
    var onLog: ((String) -> Void)?
    var onCountdown: (([Int: Int]) -> Void)?
    var onError: ((String) -> Void)?
    var onStopped: (() -> Void)?
    
    private let human = HumanInput()
    private let windowSelector = WindowSelector()
    private let minimap = MinimapMonitor()
    private let marketDetector = MarketButtonDetector()
    private let dialogDetector = DialogDetector()
    private let countdownPublisher = CountdownPublisher()
    
    private var task: Task<Void, Never>?
    private var runID = UUID()
    private(set) var isRunning = false
    
    private let tolerance: CGFloat = 5
    private let batchCastWindow = 10.0
    private let blackScreenWait = 2.5
    private let sceneCheckInterval = 2.0
    
    func start(settings: AppSettings, windowID: CGWindowID) {
        stop()
        let currentRunID = UUID()
        runID = currentRunID
        isRunning = true
        countdownPublisher.start { [weak self] info in
            self?.onCountdown?(info)
        }
        minimap.setWindow(windowID)
        marketDetector.setWindow(windowID)
        dialogDetector.setWindow(windowID)
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
        guard !buffs.isEmpty else {
            onError?("没有可运行的 Buff 配置")
            isRunning = false
            countdownPublisher.stop()
            return
        }
        
        log("死花模式启动...")
        if !windowSelector.bringWindowToFront(windowID: windowID) {
            log("⚠️ 无法将游戏窗口置于前台")
        }
        await sleep(0.5)
        
        var nextCast: [Int: TimeInterval] = [:]
        var dialogMissCount = 0
        var dialogCheckDone = false
        var lastDialogCheck: TimeInterval = 0
        var cachedButtonScreen: CGPoint?
        var cachedPortal: CGPoint?
        var cachedWindowBounds = windowSelector.getWindowInfo(windowID: windowID)?.bounds
        var isSitting = false
        
        if (try? await minimap.autoDetectDarkRegion()) == nil {
            log("⚠️ 暂未识别到小地图：\(minimap.lastDetectionSummary)")
            log("将在离开市场前重试")
        }
        
        while isRunning && !Task.isCancelled {
            guard windowSelector.isWindowValid(windowID: windowID) else {
                onError?("游戏窗口已关闭或不可见")
                break
            }
            refreshCachesIfWindowChanged(
                windowID: windowID,
                cachedBounds: &cachedWindowBounds,
                cachedButton: &cachedButtonScreen,
                cachedPortal: &cachedPortal
            )
            
            let dueNow = buffsToCast(
                buffs: buffs,
                nextCast: nextCast,
                includeUpcoming: false
            )
            
            if !dueNow.isEmpty {
                if !windowSelector.bringWindowToFront(windowID: windowID) {
                    log("⚠️ 无法将游戏窗口置于前台")
                }
                await sleep(0.3)
                
                let inMarket = (try? await marketDetector.isInMarket()) ?? false
                let inMonsterMap = inMarket ? false : ((try? await marketDetector.isInMonsterMap()) ?? false)
                log("状态检测: 市场=\(inMarket), 怪物地图=\(inMonsterMap)")
                
                var didCast = false
                if inMonsterMap {
                    let batch = buffsToCast(buffs: buffs, nextCast: nextCast, includeUpcoming: true)
                    await castAllReady(buffs: batch, nextCast: &nextCast)
                    didCast = true
                    isSitting = false
                } else if inMarket {
                    let manualPortal = manualPortalPoint(from: settings)
                    if await leaveMarket(
                        windowID: windowID,
                        jumpKey: settings.jumpKey,
                        manualPortal: manualPortal,
                        cachedPortal: &cachedPortal
                    ) {
                        await preSkillMove(settings.preSkillMoveMode)
                        let batch = buffsToCast(buffs: buffs, nextCast: nextCast, includeUpcoming: true)
                        await castAllReady(buffs: batch, nextCast: &nextCast)
                        didCast = true
                        isSitting = false
                    } else {
                        log("离开市场失败，5 秒后重试")
                        await sleep(5)
                    }
                } else {
                    log("位置状态未知，等待画面稳定...")
                    await sleep(2)
                }
                
                if didCast {
                    log("等待技能后摇结束...")
                    await randomSleep(0.8...1.0)
                    var returned = false
                    for attempt in 1...10 where isRunning {
                        if await returnToMarket(cachedButton: &cachedButtonScreen) {
                            returned = true
                            break
                        }
                        log("回到市场失败，第 \(attempt)/10 次重试...")
                        await randomSleep(2.0...4.0)
                    }
                    if returned {
                        log("技能释放完成，回到市场等待")
                        dialogMissCount = 0
                        dialogCheckDone = false
                        lastDialogCheck = 0
                    } else {
                        log("⚠️ 多次尝试后仍未确认回到市场")
                    }
                }
            } else {
                let now = Date().timeIntervalSince1970
                if !dialogCheckDone && now - lastDialogCheck >= 5 {
                    lastDialogCheck = now
                    if let point = try? await dialogDetector.findConfirmButtonScreenPoint() {
                        log("检测到弹窗，自动点击确定")
                        await human.clickAt(screenPoint: point, offsetRange: 5)
                        dialogMissCount = 0
                    } else {
                        dialogMissCount += 1
                        if dialogMissCount >= 2 {
                            dialogCheckDone = true
                            log("弹窗检测已暂停（连续 2 次未检测到）")
                        }
                    }
                }
                
                let wait = minWait(nextCast)
                if settings.sitChairEnabled && !isSitting && wait > 5,
                   (try? await marketDetector.isInMarket()) == true {
                    do {
                        try await human.pressNamedKey(settings.chairKey)
                        isSitting = true
                        log("空闲时间较长，已按下椅子键")
                    } catch {
                        onError?("椅子键错误: \(error.localizedDescription)")
                    }
                }
                await sleep(max(0.5, min(wait, 1.0)))
            }
        }
        
        await human.releaseAll()
        countdownPublisher.stop()
        log("死花模式已停止")
        if runID == currentRunID {
            isRunning = false
            task = nil
            onStopped?()
        }
    }
    
    private func manualPortalPoint(from settings: AppSettings) -> CGPoint? {
        guard let x = settings.manualPortalX, let y = settings.manualPortalY else { return nil }
        return CGPoint(x: x, y: y)
    }
    
    private func leaveMarket(
        windowID: CGWindowID,
        jumpKey: String,
        manualPortal: CGPoint?,
        cachedPortal: inout CGPoint?
    ) async -> Bool {
        log("正在离开市场...")
        if (try? await minimap.autoDetectDarkRegion()) == nil && minimap.minimapSize == nil {
            log("❌ 小地图检测失败：\(minimap.lastDetectionSummary)")
            return false
        }
        
        let portal: CGPoint?
        if let manualPortal {
            portal = manualPortal
            log("使用手动标记的传送门位置")
        } else if let cachedPortal {
            portal = cachedPortal
        } else {
            portal = try? await minimap.findBluePortal(leftmost: true)
            cachedPortal = portal
        }
        guard let portal else {
            log("❌ 未找到传送门")
            return false
        }
        log("传送门位置: \(Int(portal.x)), \(Int(portal.y))")

        guard await ensureGameFocus(windowID: windowID, reason: "离开市场") else {
            log("❌ 无法让游戏窗口获得焦点，取消本次导航")
            return false
        }
        
        do {
            try await human.pressNamedKey(jumpKey)
            await randomSleep(0.1...0.3)
        } catch {
            onError?("跳跃键错误: \(error.localizedDescription)")
        }
        
        var currentDirection: HumanInput.Direction?
        var lastPlayerX: CGFloat?
        var stuckCount = 0
        var missingPlayerCount = 0
        var enteredPortal = false
        
        var initialPlayer: CGPoint?
        for _ in 0..<10 where isRunning {
            if let player = try? await minimap.findPlayerPosition() {
                initialPlayer = player
                break
            }
            await sleep(0.2)
        }
        guard let initialPlayer else {
            log("❌ 导航前无法定位玩家：\(minimap.lastPlayerDetectionSummary)")
            return false
        }
        
        let initialDistance = portal.x - initialPlayer.x
        log("导航坐标: 玩家X=\(format(initialPlayer.x))，传送门X=\(format(portal.x))，距离=\(format(initialDistance))")
        if abs(initialDistance) <= tolerance {
            guard await ensureGameFocus(windowID: windowID, reason: "进入传送门") else {
                log("❌ 进入传送门前无法确认游戏窗口焦点")
                return false
            }
            await human.usePortal()
            enteredPortal = true
        } else {
            currentDirection = initialDistance > 0 ? .right : .left
            guard await startMoving(currentDirection!, windowID: windowID) else {
                log("❌ 导航开始前无法确认游戏焦点")
                return false
            }
        }
        
        for attempt in 0..<300 where isRunning && !Task.isCancelled && !enteredPortal {
            if !windowSelector.isWindowOwnerFrontmost(windowID: windowID) {
                currentDirection = nil
                lastPlayerX = nil
                stuckCount = 0
                log("⚠️ 检测到游戏窗口失去焦点，已停止移动并正在恢复")
                guard await ensureGameFocus(windowID: windowID, reason: "导航恢复") else {
                    log("❌ 无法恢复游戏窗口焦点，终止本次导航")
                    break
                }
                // Key-up events must be delivered after the game is frontmost.
                // Otherwise the AutoBuff window receives them and the game can
                // retain a stale direction state.
                await human.releaseAll()
                log("✅ 游戏窗口焦点已恢复，继续导航")
            }

            guard let player = try? await minimap.findPlayerPosition() else {
                missingPlayerCount += 1
                if currentDirection != nil {
                    await human.stopMove()
                    currentDirection = nil
                }
                if missingPlayerCount == 1 || missingPlayerCount % 5 == 0 {
                    log("⚠️ 丢失玩家黄点 \(missingPlayerCount) 次，已停止移动：\(minimap.lastPlayerDetectionSummary)")
                }
                if missingPlayerCount >= 15 {
                    log("❌ 连续无法定位玩家，终止本次导航")
                    break
                }
                await randomSleep(0.15...0.25)
                continue
            }
            
            if missingPlayerCount > 0 {
                log("已重新定位玩家: X=\(format(player.x))")
            }
            missingPlayerCount = 0
            let distance = portal.x - player.x
            if attempt % 10 == 0 {
                log("导航中: 玩家X=\(format(player.x))，目标X=\(format(portal.x))，距离=\(format(distance))")
            }
            if abs(distance) <= tolerance {
                await human.stopMove()
                currentDirection = nil
                await randomSleep(0.1...0.3)
                guard await ensureGameFocus(windowID: windowID, reason: "进入传送门") else {
                    log("❌ 进入传送门前无法确认游戏窗口焦点")
                    break
                }
                await human.usePortal()
                enteredPortal = true
                break
            }
            
            if let lastPlayerX, abs(player.x - lastPlayerX) <= 1 {
                stuckCount += 1
            } else {
                stuckCount = 0
            }
            lastPlayerX = player.x
            
            if stuckCount >= 5 {
                await human.stopMove()
                currentDirection = nil
                log("检测到移动停滞（游戏焦点正常），重新按方向键")
                await randomSleep(0.1...0.3)
                stuckCount = 0
            }
            
            let neededDirection: HumanInput.Direction = distance > tolerance ? .right : .left
            if currentDirection != neededDirection {
                if currentDirection != nil {
                    log("已越过目标，切换移动方向")
                    await human.stopMove()
                    await randomSleep(0.1...0.2)
                }
                guard await startMoving(neededDirection, windowID: windowID) else {
                    log("❌ 移动前无法确认游戏窗口焦点")
                    break
                }
                currentDirection = neededDirection
            }
            await randomSleep(0.15...0.25)
        }
        
        await human.stopMove()
        guard enteredPortal else {
            log("⚠️ 未能到达传送门")
            return false
        }
        
        log("等待传送...")
        await sleep(blackScreenWait)
        for _ in 0..<8 where isRunning {
            if (try? await marketDetector.isInMonsterMap()) == true {
                log("✅ 已离开市场")
                return true
            }
            await sleep(sceneCheckInterval)
        }
        log("⚠️ 离开市场超时")
        return false
    }
    
    private func format(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }
    
    private func returnToMarket(cachedButton: inout CGPoint?) async -> Bool {
        log("正在回到市场...")
        if cachedButton == nil {
            cachedButton = try? await marketDetector.findMarketButtonScreenPoint()
        }
        guard let button = cachedButton else {
            log("❌ 未找到自由市场按钮")
            return false
        }
        
        let clickCount = Int.random(in: 2...3)
        for index in 0..<clickCount where isRunning {
            await human.clickAt(screenPoint: button, offsetRange: 8)
            if index < clickCount - 1 {
                await randomSleep(0.15...0.4)
            }
        }
        
        log("等待传送...")
        await sleep(blackScreenWait)
        for _ in 0..<8 where isRunning {
            if (try? await marketDetector.isInMarket()) == true {
                log("✅ 已回到市场")
                return true
            }
            await sleep(sceneCheckInterval)
        }
        cachedButton = nil
        log("⚠️ 回到市场超时")
        return false
    }
    
    private func preSkillMove(_ mode: PreSkillMoveMode) async {
        switch mode {
        case .leftOnly:
            await wiggle(.left)
        case .rightOnly:
            await wiggle(.right)
        case .rightLeft:
            await wiggle(.right)
            await randomSleep(0.3...0.8)
            await wiggle(.left)
        }
        await human.stopMove()
        await randomSleep(0.3...0.8)
    }
    
    private func wiggle(_ direction: HumanInput.Direction) async {
        log("向\(direction == .left ? "左" : "右")微调")
        await startMoving(direction)
        await sleep(Double.random(in: 0.1...0.3))
        await human.stopMove()
    }
    
    @discardableResult
    private func startMoving(
        _ direction: HumanInput.Direction,
        windowID: CGWindowID? = nil
    ) async -> Bool {
        if let windowID,
           !windowSelector.isWindowOwnerFrontmost(windowID: windowID) {
            let focused = await ensureGameFocus(windowID: windowID, reason: "方向移动")
            if !focused {
                return false
            }
        }
        if direction == .left {
            await human.moveLeft()
        } else {
            await human.moveRight()
        }
        return true
    }

    private func ensureGameFocus(windowID: CGWindowID, reason: String) async -> Bool {
        if windowSelector.isWindowOwnerFrontmost(windowID: windowID) {
            return true
        }
        for attempt in 1...24 where isRunning && !Task.isCancelled {
            _ = windowSelector.bringWindowToFront(windowID: windowID)
            // Switching back to a full-screen Space can take noticeably longer
            // than activating a normal desktop window.
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
    
    private func castAllReady(
        buffs: [BuffConfig],
        nextCast: inout [Int: TimeInterval]
    ) async {
        guard !buffs.isEmpty else { return }
        log("准备释放 \(buffs.count) 个技能")
        for (index, buff) in buffs.enumerated() where isRunning {
            log("释放技能: \(buff.key)")
            do {
                let pressedAt = try await human.pressNamedKey(buff.key)
                let releaseAt = CountdownTiming.nextRelease(
                    pressedAt: pressedAt,
                    interval: buff.duration
                )
                nextCast[buff.id] = releaseAt
                countdownPublisher.replaceDeadlines(nextCast, now: pressedAt)
                log(
                    "技能 \(buff.key) 倒计时 \(CountdownTiming.remainingSeconds(until: releaseAt, now: pressedAt)) 秒，"
                    + "下次释放 \(CountdownTiming.clockText(for: releaseAt))"
                )
            } catch {
                onError?("按键 \(buff.key) 失败: \(error.localizedDescription)")
            }
            if index < buffs.count - 1 {
                await randomSleep(1.0...2.0)
            }
        }
    }
    
    private func refreshCachesIfWindowChanged(
        windowID: CGWindowID,
        cachedBounds: inout CGRect?,
        cachedButton: inout CGPoint?,
        cachedPortal: inout CGPoint?
    ) {
        guard let current = windowSelector.getWindowInfo(windowID: windowID)?.bounds else { return }
        if let previous = cachedBounds, previous != current {
            log("窗口位置或大小发生变化，清除检测缓存")
            cachedButton = nil
            cachedPortal = nil
            minimap.clearMinimapRegion()
        }
        cachedBounds = current
    }
    
    private func minWait(_ nextCast: [Int: TimeInterval]) -> TimeInterval {
        let now = Date().timeIntervalSince1970
        return nextCast.values.map { max(0, $0 - now) }.min() ?? 1
    }
    
    private func randomSleep(_ range: ClosedRange<Double>) async {
        await sleep(Double.random(in: range))
    }
    
    private func sleep(_ seconds: Double) async {
        guard seconds > 0, isRunning, !Task.isCancelled else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    
    private func log(_ message: String) {
        onLog?(message)
    }
}
