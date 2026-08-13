import CoreGraphics
import Foundation

@available(macOS 14.0, *)
@MainActor
final class RopePartyWorker: ObservableObject {
    var onLog: ((String) -> Void)?
    var onCountdown: (([Int: Int]) -> Void)?
    var onError: ((String) -> Void)?
    var onStopped: (() -> Void)?
    var onTeamDisbanded: ((Int64) -> Void)?
    var onBuffDue: (() -> Void)?
    var onBossJoined: ((Int64) -> Void)?
    var onBossBuffsCompleted: ((Int64) -> Void)?
    var onPartyCommandsFinished: (() -> Void)?
    var onPartyRebuildCommandsFinished: ((Int64) -> Void)?

    private let human = HumanInput()
    private let windowSelector = WindowSelector()
    private let minimap = MinimapMonitor()
    private let countdownPublisher = CountdownPublisher()
    private var task: Task<Void, Never>?
    private var runID = UUID()
    private var pendingCommands: [String] = []
    private var pendingRebuilds: [(cycleID: Int64, roleNames: [String])] = []
    private var configuredBuffs: [BuffConfig] = []
    private var buffDeadlines: [Int: TimeInterval] = [:]
    private var nextBuffDueReportAt: TimeInterval = 0
    private var activeBossCycleID: Int64?
    private var bossRoleName = ""
    private var bossOrangeBaseline: Int?
    private var bossOrangeCandidate: Int?
    private var bossOrangeCandidateFrames = 0
    private var bossMinimapReady = false
    private var nextBossInviteAt: TimeInterval = 0
    private var bossJoinDetectedCycleID: Int64?
    private var nextBossJoinedReportAt: TimeInterval = 0
    private var latestBossBuffCycleID: Int64 = 0
    private var processedRebuildKeys: Set<String> = []
    private var pendingBossInviteStart: (cycleID: Int64, roleName: String)?
    private var pendingBossBuffCycleID: Int64?
    private(set) var isRunning = false

    func start(settings: AppSettings, windowID: CGWindowID, firstCreation: Bool) {
        stop()
        let currentRunID = UUID()
        runID = currentRunID
        isRunning = true
        configuredBuffs = settings.buffs.filter { $0.enabled && !$0.key.isEmpty }
        let now = Date().timeIntervalSince1970
        buffDeadlines = Dictionary(uniqueKeysWithValues: configuredBuffs.map { ($0.id, now + $0.duration) })
        nextBuffDueReportAt = 0
        countdownPublisher.start { [weak self] info in
            self?.onCountdown?(info)
        }
        countdownPublisher.replaceDeadlines(buffDeadlines, now: now)
        minimap.setWindow(windowID)
        task = Task {
            await run(
                settings: settings,
                windowID: windowID,
                firstCreation: firstCreation,
                runID: currentRunID
            )
        }
    }

    func stop() {
        isRunning = false
        runID = UUID()
        task?.cancel()
        task = nil
        pendingCommands = []
        pendingRebuilds = []
        activeBossCycleID = nil
        bossJoinDetectedCycleID = nil
        latestBossBuffCycleID = 0
        processedRebuildKeys = []
        pendingBossInviteStart = nil
        pendingBossBuffCycleID = nil
        countdownPublisher.stop()
        Task { await human.releaseAll() }
    }

    func disbandParty(teamID: Int64, windowID: CGWindowID) {
        stop()
        let currentRunID = UUID()
        runID = currentRunID
        isRunning = true
        task = Task {
            log("收到网页解散队伍指令")
            guard await sendChatCommand("/退出隊伍", windowID: windowID) else {
                finishOneShot(runID: currentRunID)
                return
            }
            log("已发送解散队伍指令：/退出隊伍")
            onTeamDisbanded?(teamID)
            await human.releaseAll()
            finishOneShot(runID: currentRunID)
        }
    }

    func removeMember(roleName: String, windowID: CGWindowID) {
        let command = "/踢出隊伍 \(roleName)"
        if isRunning, task != nil {
            pendingCommands.append(command)
            log("移除成员指令已加入发送队列：\(roleName)")
            return
        }

        stop()
        let currentRunID = UUID()
        runID = currentRunID
        isRunning = true
        task = Task {
            log("收到网页移除队伍成员指令")
            guard await sendChatCommand(command, windowID: windowID) else {
                finishOneShot(runID: currentRunID)
                return
            }
            log("已发送移除成员指令：\(command)")
            await human.releaseAll()
            finishOneShot(runID: currentRunID)
        }
    }

    func startBossInviteCycle(cycleID: Int64, roleName: String) {
        guard isRunning, cycleID > 0, !roleName.isEmpty else { return }
        if activeBossCycleID == cycleID || pendingBossInviteStart?.cycleID == cycleID {
            return
        }
        pendingBossInviteStart = (cycleID, roleName)
        log("老板邀请周期已加入执行队列：\(roleName)")
    }

    private func applyBossInviteStart(cycleID: Int64, roleName: String) {
        activeBossCycleID = cycleID
        bossRoleName = roleName
        bossOrangeBaseline = nil
        bossOrangeCandidate = nil
        bossOrangeCandidateFrames = 0
        bossMinimapReady = false
        nextBossInviteAt = 0
        bossJoinDetectedCycleID = nil
        nextBossJoinedReportAt = 0
        log("老板 Buff 周期 \(cycleID) 启动，等待小地图基线后邀请 \(roleName)")
    }

    func castBossBuffs(cycleID: Int64) {
        guard isRunning, cycleID > 0 else { return }
        guard cycleID > latestBossBuffCycleID else { return }
        latestBossBuffCycleID = cycleID
        pendingBossBuffCycleID = cycleID
        activeBossCycleID = nil
        bossJoinDetectedCycleID = nil
        log("收到老板进队广播，准备强制释放全部已勾选 BUFF")
    }

    func disbandBossParty(cycleID: Int64, phase: String, roleNames: [String], windowID: CGWindowID) {
        guard isRunning, cycleID > 0 else { return }
        let rebuildKey = "\(cycleID):\(phase)"
        guard !processedRebuildKeys.contains(rebuildKey) else { return }
        let normalizedRoleNames = roleNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        processedRebuildKeys.insert(rebuildKey)
        pendingRebuilds.append((cycleID: cycleID, roleNames: normalizedRoleNames))
    }

    private func finishOneShot(runID currentRunID: UUID) {
        guard runID == currentRunID else { return }
        isRunning = false
        task = nil
        onStopped?()
    }

    private func run(
        settings: AppSettings,
        windowID: CGWindowID,
        firstCreation: Bool,
        runID currentRunID: UUID
    ) async {
        log("神殿模式 · 挂绳组队启动...")
        if settings.ropePartyIsLeader && firstCreation {
            if await createPartyAndInvite(
                roleNames: settings.ropePartyInviteRoleNames,
                windowID: windowID
            ) { onPartyCommandsFinished?() }
        } else if settings.ropePartyIsLeader {
            log("队长客户端已启动；本次为修改队伍，不重复发送建队邀请")
        } else {
            log("队员客户端已启动，等待并自动接受队伍邀请")
        }

        while isRunning && !Task.isCancelled {
            guard windowSelector.isWindowValid(windowID: windowID) else {
                onError?("游戏窗口已关闭或不可见")
                break
            }
            if let start = pendingBossInviteStart {
                pendingBossInviteStart = nil
                applyBossInviteStart(cycleID: start.cycleID, roleName: start.roleName)
            }
            if let cycleID = pendingBossBuffCycleID {
                pendingBossBuffCycleID = nil
                if await castAllConfiguredBuffs(windowID: windowID) {
                    onBossBuffsCompleted?(cycleID)
                }
            }
            if !pendingRebuilds.isEmpty {
                let rebuild = pendingRebuilds.removeFirst()
                guard await sendChatCommand("/退出隊伍", windowID: windowID) else { break }
                log("老板 BUFF 周期完成，已发送解散队伍指令：/退出隊伍")
                await randomSleep(0.8...1.4)
                if await createPartyAndInvite(roleNames: rebuild.roleNames, windowID: windowID, includeExit: false) {
                    onPartyRebuildCommandsFinished?(rebuild.cycleID)
                }
                continue
            }
            if !pendingCommands.isEmpty {
                let command = pendingCommands.removeFirst()
                guard await sendChatCommand(command, windowID: windowID) else { break }
                log("已发送移除成员指令：\(command)")
            }
            await processBossInviteCycle(windowID: windowID)
            reportBuffDueIfNeeded()
            await sleep(0.5)
        }
        await human.releaseAll()
        guard runID == currentRunID else { return }
        isRunning = false
        task = nil
        countdownPublisher.stop()
        log("神殿模式 · 挂绳组队已停止")
        onStopped?()
    }

    private func createPartyAndInvite(roleNames: [String], windowID: CGWindowID, includeExit: Bool = true) async -> Bool {
        log("首次创建队伍，开始发送建队指令")
        var commands = includeExit ? ["/退出隊伍", "/建立隊伍"] : ["/建立隊伍"]
        commands.append(contentsOf: roleNames.map { "/邀請組隊 \($0)" })
        for (index, command) in commands.enumerated() where isRunning && !Task.isCancelled {
            guard await sendChatCommand(command, windowID: windowID) else { return false }
            log("已发送队伍指令：\(command)")
            if index < commands.count - 1 {
                // The game has no acknowledgement for chat commands. Give the
                // party state enough time to settle before the next invite.
                await randomSleep(command == "/建立隊伍" ? 1.5...2.2 : 1.0...1.6)
            }
        }
        log("首次建队指令已发送完毕")
        return true
    }

    private func processBossInviteCycle(windowID: CGWindowID) async {
        guard let cycleID = activeBossCycleID else { return }
        if !bossMinimapReady {
            guard (try? await minimap.autoDetectDarkRegion()) != nil else { return }
            bossMinimapReady = true
        }
        do {
            let frame = try await minimap.captureMinimap()
            let orangeCount = await Task.detached(priority: .userInitiated) {
                ColorDetector.detectTeammateMarkers(in: frame).points.count
            }.value
            observeBossOrangeCount(orangeCount, cycleID: cycleID)
        } catch {
            return
        }
        guard activeBossCycleID == cycleID, bossOrangeBaseline != nil else { return }
        let now = Date().timeIntervalSince1970
        if bossJoinDetectedCycleID == cycleID {
            if now >= nextBossJoinedReportAt {
                onBossJoined?(cycleID)
                log("已上报老板进队，等待服务端下发放 BUFF")
                activeBossCycleID = nil
            }
            return
        }
        if now >= nextBossInviteAt {
            let command = "/邀請組隊 \(bossRoleName)"
            if await sendChatCommand(command, windowID: windowID) {
                log("已发送老板邀请：\(command)")
            }
            nextBossInviteAt = Date().timeIntervalSince1970 + 8
        }
    }

    private func observeBossOrangeCount(_ count: Int, cycleID: Int64) {
        if bossOrangeCandidate == count {
            bossOrangeCandidateFrames += 1
        } else {
            bossOrangeCandidate = count
            bossOrangeCandidateFrames = 1
        }
        guard bossOrangeCandidateFrames >= 2 else { return }
        if bossOrangeBaseline == nil {
            bossOrangeBaseline = count
            log("老板邀请前橙点基线：\(count)")
            return
        }
        guard let baseline = bossOrangeBaseline, count > baseline else { return }
        log("橙点数量由 \(bossOrangeBaseline ?? 0) 变为 \(count)，判定老板已进队")
        bossJoinDetectedCycleID = cycleID
        nextBossJoinedReportAt = 0
    }

    private func reportBuffDueIfNeeded() {
        guard !configuredBuffs.isEmpty else { return }
        guard pendingBossInviteStart == nil,
              activeBossCycleID == nil,
              pendingBossBuffCycleID == nil else { return }
        let now = Date().timeIntervalSince1970
        let minimumRemaining = configuredBuffs.compactMap { buff in
            buffDeadlines[buff.id].map { $0 - now }
        }.min()
        guard let minimumRemaining, minimumRemaining <= 10, now >= nextBuffDueReportAt else { return }
        onBuffDue?()
        nextBuffDueReportAt = now + 8
    }

    private func castAllConfiguredBuffs(windowID: CGWindowID) async -> Bool {
        await ChatInputTransactionCoordinator.shared.withTransaction {
            if configuredBuffs.isEmpty {
                return true
            }
            guard await ensureGameFocus(windowID: windowID) else { return false }
            for (index, buff) in configuredBuffs.enumerated() {
                guard isRunning, !Task.isCancelled else { return false }
                do {
                    try await human.pressNamedKey(buff.key)
                    await randomSleep(0.1...0.3)
                    try await human.pressNamedKey(buff.key)
                    log("老板进队触发，已释放 BUFF：\(buff.key)")
                } catch {
                    onError?("强制释放 BUFF \(buff.key) 失败：\(error.localizedDescription)")
                }
                if index < configuredBuffs.count - 1 {
                    await randomSleep(2.0...3.0)
                }
            }
            guard isRunning, !Task.isCancelled else { return false }
            let now = Date().timeIntervalSince1970
            buffDeadlines = Dictionary(uniqueKeysWithValues: configuredBuffs.map { ($0.id, now + $0.duration) })
            countdownPublisher.replaceDeadlines(buffDeadlines, now: now)
            nextBuffDueReportAt = 0
            return true
        }
    }

    private func sendChatCommand(_ command: String, windowID: CGWindowID) async -> Bool {
        await ChatInputTransactionCoordinator.shared.withTransaction {
            guard await ensureGameFocus(windowID: windowID) else { return false }
            guard isRunning, !Task.isCancelled else { return false }
            do {
                // Cancellation is deliberately ignored after this first Enter.
                // The second Enter must be sent before another command can begin.
                try await human.pressNamedKey("Enter")
                await randomSleep(0.18...0.42)
                try await human.pressNamedKey("Delete")
                await randomSleep(0.08...0.18)
                await human.typeText(command)
                await randomSleep(0.12...0.32)
                try await human.pressNamedKey("Enter")
                return true
            } catch {
                onError?("发送聊天指令失败：\(error.localizedDescription)")
                return false
            }
        }
    }

    private func ensureGameFocus(windowID: CGWindowID) async -> Bool {
        guard windowSelector.isWindowValid(windowID: windowID) else {
            onError?("发送队伍指令前游戏窗口已失效")
            return false
        }
        for _ in 1...24 where isRunning && !Task.isCancelled {
            // Always raise the selected window. Checking only the owning process can
            // mistake another window from the same game process for the input target.
            _ = windowSelector.bringWindowToFront(windowID: windowID)
            await sleep(0.25)
            if windowSelector.isWindowOwnerFrontmost(windowID: windowID) {
                // Raise it once more after activation has settled so the selected
                // game window, rather than merely its application, receives input.
                _ = windowSelector.bringWindowToFront(windowID: windowID)
                await sleep(0.15)
                if windowSelector.isWindowOwnerFrontmost(windowID: windowID) {
                    return true
                }
            }
        }
        onError?("发送队伍指令前无法确认游戏窗口焦点")
        return false
    }

    private func randomSleep(_ range: ClosedRange<Double>) async {
        await sleep(Double.random(in: range))
    }

    private func sleep(_ seconds: Double) async {
        guard seconds > 0, isRunning, !Task.isCancelled else { return }
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func log(_ message: String) { onLog?(message) }
}
