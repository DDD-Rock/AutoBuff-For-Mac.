import CoreGraphics
import Foundation

enum PortalNavigation {
    // ScreenCaptureKit captures this app at Quartz point resolution. On a
    // Retina display, the Windows baseline's 5 native pixels are about 2.5
    // captured points. Keep that as the default while allowing per-user tuning.
    static let defaultWidthThreshold: CGFloat = 2.5
    static let fineAdjustmentMargin: CGFloat = 4
    static let targetFramesPerSecond = 30.0
    static let missingPlayerGrace = Duration.milliseconds(120)
    static let missingPlayerAbort = Duration.seconds(3)
    static let recoveryJumpInterval = Duration.milliseconds(450)
    static let stuckTimeout = Duration.milliseconds(900)
    static let fineAdjustmentHoldMS = 180...280
    static let fineAdjustmentIntervalMS = 80...160
    static let transitionCheckAttempts = 3

    static func widthThreshold(from settings: AppSettings) -> CGFloat {
        min(20, max(0.5, CGFloat(settings.portalWidthThreshold)))
    }

    static func hasArrived(
        playerX: CGFloat,
        portalX: CGFloat,
        widthThreshold: CGFloat = defaultWidthThreshold
    ) -> Bool {
        abs(portalX - playerX) < widthThreshold
    }

    static func shouldFineAdjust(distance: CGFloat, widthThreshold: CGFloat) -> Bool {
        abs(distance) < widthThreshold + fineAdjustmentMargin
    }
}

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
    
    private let batchCastWindow = 10.0
    private let blackScreenWait = 2.5
    private let sceneCheckInterval = 2.0
    
    func start(
        settings: AppSettings,
        windowID: CGWindowID,
        displayName: String = "死花模式"
    ) {
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
            await run(
                settings: settings,
                windowID: windowID,
                runID: currentRunID,
                displayName: displayName
            )
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
    
    private func run(
        settings: AppSettings,
        windowID: CGWindowID,
        runID currentRunID: UUID,
        displayName: String
    ) async {
        let buffs = settings.buffs.filter {
            $0.enabled && !$0.key.isEmpty && $0.duration > 0
        }
        guard !buffs.isEmpty else {
            onError?("没有可运行的 Buff 配置")
            isRunning = false
            countdownPublisher.stop()
            return
        }
        
        log("\(displayName)启动...")
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
                
                let location = try? await marketDetector.detectLocation()
                let inMarket = location?.state == .market
                let inMonsterMap = location?.state == .monsterMap
                let evidence = location?.debugSummary ?? "检测失败"
                log("状态检测: 市场=\(inMarket), 怪物地图=\(inMonsterMap)（\(evidence)）")
                
                var didCast = false
                if inMonsterMap {
                    let batch = buffsToCast(buffs: buffs, nextCast: nextCast, includeUpcoming: true)
                    didCast = await castAllReady(
                        buffs: batch,
                        nextCast: &nextCast,
                        windowID: windowID
                    )
                    isSitting = false
                } else if inMarket {
                    let manualPortal = manualPortalPoint(from: settings)
                    if await leaveMarket(
                        windowID: windowID,
                        jumpKey: settings.jumpKey,
                        portalWidthThreshold: PortalNavigation.widthThreshold(from: settings),
                        manualPortal: manualPortal,
                        cachedPortal: &cachedPortal
                    ) {
                        await preSkillMove(settings.preSkillMoveMode)
                        let batch = buffsToCast(buffs: buffs, nextCast: nextCast, includeUpcoming: true)
                        didCast = await castAllReady(
                            buffs: batch,
                            nextCast: &nextCast,
                            windowID: windowID
                        )
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
                    await randomSleep(1.2...1.8)
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
                    if await dismissDialogIfPresent(windowID: windowID) {
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
                   (try? await marketDetector.detectLocation().state) == .market {
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
        log("\(displayName)已停止")
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

    private func dismissDialogIfPresent(windowID: CGWindowID) async -> Bool {
        guard var point = try? await dialogDetector.findConfirmButtonScreenPoint() else {
            return false
        }

        log("检测到弹窗，自动点击确定（\(dialogDetector.lastDetectionSummary)）")
        for attempt in 1...2 where isRunning && !Task.isCancelled {
            guard await ensureGameFocus(windowID: windowID, reason: "关闭弹窗") else {
                log("❌ 关闭弹窗前无法确认游戏窗口焦点")
                return true
            }
            await sleep(0.15)
            if attempt > 1,
               let refreshedPoint = try? await dialogDetector.findConfirmButtonScreenPoint() {
                point = refreshedPoint
            }
            await human.clickAt(screenPoint: point, offsetRange: 3)
            await sleep(0.25)
            if (try? await dialogDetector.findConfirmButtonScreenPoint()) == nil {
                log("弹窗已关闭")
                return true
            }
            if attempt == 1 {
                log("弹窗仍在，准备再次点击确定")
            }
        }
        return true
    }
    
    private func leaveMarket(
        windowID: CGWindowID,
        jumpKey: String,
        portalWidthThreshold: CGFloat,
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

        let stream: GameRegionCaptureStream
        do {
            stream = try await minimap.startMinimapStream(
                targetFramesPerSecond: PortalNavigation.targetFramesPerSecond
            )
        } catch {
            log("⚠️ 无法启动 30 FPS 小地图流，改用兼容导航：\(error.localizedDescription)")
            return await leaveMarketLegacy(
                windowID: windowID,
                jumpKey: jumpKey,
                portalWidthThreshold: portalWidthThreshold,
                manualPortal: manualPortal,
                cachedPortal: &cachedPortal
            )
        }

        guard await ensureGameFocus(windowID: windowID, reason: "离开市场") else {
            await stream.stop()
            log("❌ 无法让游戏窗口获得焦点，取消本次导航")
            return false
        }
        do {
            try await human.pressNamedKey(jumpKey)
            await randomSleep(0.1...0.3)
        } catch {
            onError?("跳跃键错误: \(error.localizedDescription)")
        }
        log("小地图导航已启用最高 30 FPS 识别")

        let enteredPortal = await navigateToPortal(
            stream: stream,
            portal: portal,
            portalWidthThreshold: portalWidthThreshold,
            jumpKey: jumpKey,
            windowID: windowID
        )
        await stream.stop()

        guard enteredPortal else {
            log("⚠️ 未能到达传送门")
            return false
        }

        log("等待传送...")
        await sleep(blackScreenWait)
        for _ in 0..<8 where isRunning {
            if (try? await marketDetector.detectLocation().state) == .monsterMap {
                log("✅ 已离开市场")
                return true
            }
            await sleep(sceneCheckInterval)
        }
        log("⚠️ 离开市场超时")
        return false
    }

    private func leaveMarketLegacy(
        windowID: CGWindowID,
        jumpKey: String,
        portalWidthThreshold: CGFloat,
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
        var isFineAdjusting = false
        var directApproachDirection: HumanInput.Direction?
        
        var initialPlayer: CGPoint?
        for _ in 0..<10 where isRunning {
            if let player = try? await minimap.findPlayerPosition() {
                initialPlayer = player
                break
            }
            await sleep(0.2)
        }
        if initialPlayer == nil {
            log("导航前黄点被遮挡，尝试跳跃定位...")
            if let jumpedPlayer = await findPlayerPositionDuringJump(
                jumpKey: jumpKey,
                windowID: windowID
            ) {
                initialPlayer = jumpedPlayer
                log("跳跃时定位到玩家: X=\(format(jumpedPlayer.x))")
            }
        }
        guard let initialPlayer else {
            log("❌ 导航前无法定位玩家：\(minimap.lastPlayerDetectionSummary)")
            return false
        }
        
        let initialDistance = portal.x - initialPlayer.x
        log("导航坐标: 玩家X=\(format(initialPlayer.x))，传送门X=\(format(portal.x))，距离=\(format(initialDistance))")
        if PortalNavigation.hasArrived(
            playerX: initialPlayer.x,
            portalX: portal.x,
            widthThreshold: portalWidthThreshold
        ) {
            guard await ensureGameFocus(windowID: windowID, reason: "进入传送门") else {
                log("❌ 进入传送门前无法确认游戏窗口焦点")
                return false
            }
            log("已到达传送门范围，按上键进入（距离=\(format(initialDistance))）")
            await human.usePortal()
            enteredPortal = true
        } else if PortalNavigation.shouldFineAdjust(
            distance: initialDistance,
            widthThreshold: portalWidthThreshold
        ) {
            // Already close enough that a full hold is likely to overshoot.
            // The first short tap is still a direct attempt; correction mode
            // only continues if that attempt misses the target range.
            isFineAdjusting = true
        } else {
            let direction: HumanInput.Direction = initialDistance > 0 ? .right : .left
            directApproachDirection = direction
            currentDirection = direction
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

            var recoveredByJump = false
            var detectedPlayer = try? await minimap.findPlayerPosition()
            if detectedPlayer == nil {
                missingPlayerCount += 1
                if currentDirection != nil {
                    await human.stopMove()
                    currentDirection = nil
                }
                lastPlayerX = nil
                stuckCount = 0
                if missingPlayerCount == 1 || missingPlayerCount % 5 == 0 {
                    log("⚠️ 丢失玩家黄点 \(missingPlayerCount) 次，已停止移动，尝试跳跃定位：\(minimap.lastPlayerDetectionSummary)")
                }
                detectedPlayer = await findPlayerPositionDuringJump(
                    jumpKey: jumpKey,
                    windowID: windowID
                )
                recoveredByJump = detectedPlayer != nil
                if detectedPlayer == nil {
                    if missingPlayerCount >= 15 {
                        log("❌ 连续无法定位玩家，终止本次导航")
                        break
                    }
                    await randomSleep(0.15...0.25)
                    continue
                }
            }
            guard let player = detectedPlayer else { continue }
            
            if missingPlayerCount > 0 {
                let prefix = recoveredByJump ? "跳跃时重新定位玩家" : "已重新定位玩家"
                log("\(prefix): X=\(format(player.x))")
            }
            missingPlayerCount = 0
            let distance = portal.x - player.x
            if attempt % 10 == 0 {
                log("导航中: 玩家X=\(format(player.x))，目标X=\(format(portal.x))，距离=\(format(distance))")
            }
            if PortalNavigation.hasArrived(
                playerX: player.x,
                portalX: portal.x,
                widthThreshold: portalWidthThreshold
            ) {
                await human.stopMove()
                currentDirection = nil
                guard await ensureGameFocus(windowID: windowID, reason: "进入传送门") else {
                    log("❌ 进入传送门前无法确认游戏窗口焦点")
                    break
                }
                log("已到达传送门范围，按上键进入（距离=\(format(distance))）")
                await human.usePortal()
                enteredPortal = true
                break
            }
            
            if currentDirection != nil {
                if let lastPlayerX, abs(player.x - lastPlayerX) <= 1 {
                    stuckCount += 1
                } else {
                    stuckCount = 0
                }
                lastPlayerX = player.x

                if stuckCount >= 5 {
                    await human.stopMove()
                    currentDirection = nil
                    log("检测到移动停滞（游戏焦点正常），重新按方向键：\(minimap.lastPlayerDetectionSummary)")
                    await randomSleep(0.1...0.3)
                    stuckCount = 0
                }
            } else {
                lastPlayerX = nil
                stuckCount = 0
            }

            let neededDirection: HumanInput.Direction = distance > 0 ? .right : .left
            if isFineAdjusting {
                if currentDirection != nil {
                    await human.stopMove()
                    currentDirection = nil
                    log("首次接近未进入范围，松开方向键准备微调")
                    await randomSleep(0.10...0.18)
                    continue
                }
                guard await ensureGameFocus(windowID: windowID, reason: "传送门微调") else {
                    log("❌ 微调前无法确认游戏窗口焦点")
                    break
                }
                await human.tapDirection(
                    neededDirection,
                    holdMS: 60...110,
                    intervalMS: 80...160
                )
                continue
            }

            if let directApproachDirection,
               neededDirection != directApproachDirection {
                if currentDirection != nil {
                    await human.stopMove()
                    currentDirection = nil
                }
                isFineAdjusting = true
                log("首次直行越过传送门，切换为自然短按微调")
                await randomSleep(0.10...0.18)
                continue
            }

            if currentDirection != neededDirection {
                guard await startMoving(neededDirection, windowID: windowID) else {
                    log("❌ 移动前无法确认游戏窗口焦点")
                    break
                }
                currentDirection = neededDirection
            }
            if PortalNavigation.shouldFineAdjust(
                distance: distance,
                widthThreshold: portalWidthThreshold
            ) {
                // Keep walking on the first approach, but sample more often so
                // the center is likely to be observed inside the target band.
                await randomSleep(0.06...0.10)
            } else {
                await randomSleep(0.15...0.25)
            }
        }
        
        await human.stopMove()
        guard enteredPortal else {
            log("⚠️ 未能到达传送门")
            return false
        }
        
        log("等待传送...")
        await sleep(blackScreenWait)
        for _ in 0..<8 where isRunning {
            if (try? await marketDetector.detectLocation().state) == .monsterMap {
                log("✅ 已离开市场")
                return true
            }
            await sleep(sceneCheckInterval)
        }
        log("⚠️ 离开市场超时")
        return false
    }

    private func navigateToPortal(
        stream: GameRegionCaptureStream,
        portal: CGPoint,
        portalWidthThreshold: CGFloat,
        jumpKey: String,
        windowID: CGWindowID
    ) async -> Bool {
        var currentDirection: HumanInput.Direction?
        var directApproachDirection: HumanInput.Direction?
        var isFineAdjusting = false
        var hasInitialPosition = false
        var didInitialRecoveryJump = false
        var initialDeadline = ContinuousClock.now + .seconds(2)
        var missingSince: ContinuousClock.Instant?
        var lastRecoveryJumpAt: ContinuousClock.Instant?
        var lastMissingLogAt: ContinuousClock.Instant?
        var progressAnchorX: CGFloat?
        var progressAnchorAt: ContinuousClock.Instant?
        let navigationStartedAt = ContinuousClock.now
        var enteredPortal = false

        do {
            for try await frame in stream.frames {
                guard isRunning, !Task.isCancelled else { break }
                guard navigationStartedAt.duration(to: .now) < .seconds(30) else {
                    log("⚠️ 传送门导航超时")
                    break
                }

                if !windowSelector.isWindowOwnerFrontmost(windowID: windowID) {
                    currentDirection = nil
                    progressAnchorX = nil
                    progressAnchorAt = nil
                    log("⚠️ 检测到游戏窗口失去焦点，已停止移动并正在恢复")
                    guard await ensureGameFocus(windowID: windowID, reason: "导航恢复") else {
                        log("❌ 无法恢复游戏窗口焦点，终止本次导航")
                        break
                    }
                    await human.releaseAll()
                    log("✅ 游戏窗口焦点已恢复，继续导航")
                }

                let detectedPlayer = await minimap.findPlayerPosition(in: frame)
                let now = ContinuousClock.now

                if !hasInitialPosition {
                    guard let player = detectedPlayer else {
                        if now < initialDeadline {
                            continue
                        }
                        if !didInitialRecoveryJump {
                            log("导航前黄点被遮挡，尝试跳跃定位...")
                            _ = await performRecoveryJump(
                                jumpKey: jumpKey,
                                windowID: windowID
                            )
                            didInitialRecoveryJump = true
                            initialDeadline = ContinuousClock.now + .milliseconds(500)
                            continue
                        }
                        log("❌ 导航前无法定位玩家：\(minimap.lastPlayerDetectionSummary)")
                        break
                    }

                    hasInitialPosition = true
                    let distance = portal.x - player.x
                    log("导航坐标: 玩家X=\(format(player.x))，传送门X=\(format(portal.x))，距离=\(format(distance))")
                    if PortalNavigation.hasArrived(
                        playerX: player.x,
                        portalX: portal.x,
                        widthThreshold: portalWidthThreshold
                    ) {
                        enteredPortal = await tryEnterPortal(windowID: windowID)
                        isFineAdjusting = !enteredPortal
                    } else {
                        let direction: HumanInput.Direction = distance > 0 ? .right : .left
                        directApproachDirection = direction
                        guard await startMoving(direction, windowID: windowID) else { break }
                        currentDirection = direction
                        progressAnchorX = player.x
                        progressAnchorAt = ContinuousClock.now
                    }
                    if enteredPortal { break }
                    continue
                }

                guard let player = detectedPlayer else {
                    if missingSince == nil {
                        missingSince = now
                    }
                    let missingDuration = missingSince?.duration(to: now) ?? .zero
                    if missingDuration < PortalNavigation.missingPlayerGrace {
                        continue
                    }
                    if currentDirection != nil {
                        await human.stopMove()
                        currentDirection = nil
                    }
                    progressAnchorX = nil
                    progressAnchorAt = nil
                    if lastMissingLogAt == nil
                        || lastMissingLogAt!.duration(to: now) >= .seconds(1) {
                        log("⚠️ 玩家黄点持续丢失，已停止移动，尝试跳跃定位：\(minimap.lastPlayerDetectionSummary)")
                        lastMissingLogAt = now
                    }
                    if lastRecoveryJumpAt == nil
                        || lastRecoveryJumpAt!.duration(to: now) >= PortalNavigation.recoveryJumpInterval {
                        _ = await performRecoveryJump(
                            jumpKey: jumpKey,
                            windowID: windowID
                        )
                        lastRecoveryJumpAt = ContinuousClock.now
                    }
                    if missingDuration >= PortalNavigation.missingPlayerAbort {
                        log("❌ 连续无法定位玩家，终止本次导航")
                        break
                    }
                    continue
                }

                if missingSince != nil {
                    log("已重新定位玩家: X=\(format(player.x))")
                }
                missingSince = nil
                let distance = portal.x - player.x
                let neededDirection: HumanInput.Direction = distance > 0 ? .right : .left

                // 按上键失败后即使仍在容差内，也先朝传送门中心多走一步。
                if isFineAdjusting {
                    guard await ensureGameFocus(windowID: windowID, reason: "传送门微调") else { break }
                    log("向\(neededDirection == .right ? "右" : "左")微调后尝试进入传送门")
                    await human.tapDirection(
                        neededDirection,
                        holdMS: PortalNavigation.fineAdjustmentHoldMS,
                        intervalMS: PortalNavigation.fineAdjustmentIntervalMS
                    )
                    currentDirection = nil
                    progressAnchorX = nil
                    progressAnchorAt = nil
                    enteredPortal = await tryEnterPortal(windowID: windowID)
                    if enteredPortal { break }
                    continue
                }

                if PortalNavigation.hasArrived(
                    playerX: player.x,
                    portalX: portal.x,
                    widthThreshold: portalWidthThreshold
                ) {
                    await human.stopMove()
                    currentDirection = nil
                    log("已到达传送门范围，按上键进入（距离=\(format(distance))）")
                    enteredPortal = await tryEnterPortal(windowID: windowID)
                    isFineAdjusting = !enteredPortal
                    if enteredPortal { break }
                    continue
                }

                if let directApproachDirection,
                   neededDirection != directApproachDirection {
                    if currentDirection != nil {
                        await human.stopMove()
                        currentDirection = nil
                    }
                    isFineAdjusting = true
                    progressAnchorX = nil
                    progressAnchorAt = nil
                    log("首次直行越过传送门，切换为长按微调并逐次试按上键")
                    continue
                }

                if currentDirection != nil {
                    if progressAnchorX == nil {
                        progressAnchorX = player.x
                        progressAnchorAt = now
                    } else if abs(player.x - progressAnchorX!) > 1 {
                        progressAnchorX = player.x
                        progressAnchorAt = now
                    } else if let anchorAt = progressAnchorAt,
                              anchorAt.duration(to: now) >= PortalNavigation.stuckTimeout {
                        await human.stopMove()
                        currentDirection = nil
                        progressAnchorX = nil
                        progressAnchorAt = nil
                        log("检测到移动停滞（游戏焦点正常），重新按方向键：\(minimap.lastPlayerDetectionSummary)")
                        await randomSleep(0.1...0.3)
                    }
                }

                if currentDirection != neededDirection {
                    guard await startMoving(neededDirection, windowID: windowID) else { break }
                    currentDirection = neededDirection
                    progressAnchorX = player.x
                    progressAnchorAt = ContinuousClock.now
                }
            }
        } catch {
            log("❌ 小地图视频流中断：\(error.localizedDescription)")
        }

        await human.stopMove()
        return enteredPortal
    }

    private func performRecoveryJump(
        jumpKey: String,
        windowID: CGWindowID
    ) async -> Bool {
        guard isRunning, !Task.isCancelled else { return false }
        guard await ensureGameFocus(windowID: windowID, reason: "跳跃定位") else {
            log("❌ 跳跃定位前无法确认游戏窗口焦点")
            return false
        }

        let jumpDuration = Double.random(in: 0.08...0.16)
        let keyCode: CGKeyCode
        do {
            keyCode = try await human.pressNamedKeyDown(jumpKey)
        } catch {
            onError?("跳跃键错误: \(error.localizedDescription)")
            return false
        }
        await sleep(jumpDuration)
        await human.releaseKey(keyCode)
        return true
    }

    private func tryEnterPortal(windowID: CGWindowID) async -> Bool {
        guard await ensureGameFocus(windowID: windowID, reason: "进入传送门") else {
            log("❌ 进入传送门前无法确认游戏窗口焦点")
            return false
        }
        await human.usePortal()

        var consecutiveLogoMisses = 0
        for _ in 0..<PortalNavigation.transitionCheckAttempts where isRunning {
            if (try? await marketDetector.isMarketLogoVisible()) == true {
                consecutiveLogoMisses = 0
            } else {
                consecutiveLogoMisses += 1
                if consecutiveLogoMisses >= 2 {
                    log("已触发传送，等待切换场景")
                    return true
                }
            }
            await sleep(0.08)
        }
        return false
    }

    private func findPlayerPositionDuringJump(
        jumpKey: String,
        windowID: CGWindowID
    ) async -> CGPoint? {
        guard isRunning, !Task.isCancelled else { return nil }
        guard await ensureGameFocus(windowID: windowID, reason: "跳跃定位") else {
            log("❌ 跳跃定位前无法确认游戏窗口焦点")
            return nil
        }

        let jumpDuration = Double.random(in: 0.08...0.16)
        let sampleDelay = min(jumpDuration, Double.random(in: 0.04...0.08))
        let keyCode: CGKeyCode
        do {
            keyCode = try await human.pressNamedKeyDown(jumpKey)
        } catch {
            onError?("跳跃键错误: \(error.localizedDescription)")
            return nil
        }

        await sleep(sampleDelay)
        let player: CGPoint?
        if isRunning && !Task.isCancelled {
            player = try? await minimap.findPlayerPosition()
        } else {
            player = nil
        }
        await human.releaseKey(keyCode)
        let remaining = jumpDuration - sampleDelay
        if remaining > 0 {
            await sleep(remaining)
        }
        return player
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
            if (try? await marketDetector.detectLocation().state) == .market {
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
        await randomSleep(0.5...1.0)
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
        nextCast: inout [Int: TimeInterval],
        windowID: CGWindowID
    ) async -> Bool {
        guard !buffs.isEmpty else { return false }
        log("准备释放 \(buffs.count) 个技能")
        guard await ensureGameFocus(windowID: windowID, reason: "释放技能") else {
            log("❌ 释放技能前无法确认游戏窗口焦点")
            return false
        }
        for (index, buff) in buffs.enumerated() where isRunning {
            log("释放技能: \(buff.key)")
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
                    "技能 \(buff.key) 倒计时 \(CountdownTiming.remainingSeconds(until: releaseAt, now: finalPressedAt)) 秒，"
                    + "下次释放 \(CountdownTiming.clockText(for: releaseAt))"
                )
            } catch {
                onError?("按键 \(buff.key) 失败: \(error.localizedDescription)")
            }
            if index < buffs.count - 1 {
                await randomSleep(1.0...2.0)
            }
        }
        return true
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
