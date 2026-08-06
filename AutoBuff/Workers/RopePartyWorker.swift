import CoreGraphics
import Foundation

@available(macOS 14.0, *)
@MainActor
final class RopePartyWorker: ObservableObject {
    var onLog: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onStopped: (() -> Void)?
    var onTeamCreated: (() -> Void)?
    var onInvitationSent: ((String) -> Void)?
    var onTeamDisbanded: ((Int64) -> Void)?
    var onBuffDue: (() -> Void)?
    var onBossJoined: ((Int64) -> Void)?
    var onBossBuffsCompleted: ((Int64) -> Void)?
    var onBossKicked: ((Int64) -> Void)?

    private let human = HumanInput()
    private let windowSelector = WindowSelector()
    private let minimap = MinimapMonitor()
    private var task: Task<Void, Never>?
    private var runID = UUID()
    private var pendingCommands: [String] = []
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
    private var pendingBossBuffCycleID: Int64?
    private var pendingBossKick: (cycleID: Int64, roleName: String)?
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
        activeBossCycleID = nil
        pendingBossBuffCycleID = nil
        pendingBossKick = nil
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
        activeBossCycleID = cycleID
        bossRoleName = roleName
        bossOrangeBaseline = nil
        bossOrangeCandidate = nil
        bossOrangeCandidateFrames = 0
        bossMinimapReady = false
        nextBossInviteAt = 0
        log("老板 Buff 周期 \(cycleID) 启动，等待小地图基线后邀请 \(roleName)")
    }

    func castBossBuffs(cycleID: Int64) {
        guard isRunning, cycleID > 0 else { return }
        pendingBossBuffCycleID = cycleID
        activeBossCycleID = nil
        log("收到老板进队广播，准备强制释放全部已勾选 BUFF")
    }

    func kickBoss(cycleID: Int64, roleName: String) {
        guard isRunning, cycleID > 0, !roleName.isEmpty else { return }
        pendingBossKick = (cycleID, roleName)
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
            await createPartyAndInvite(
                roleNames: settings.ropePartyInviteRoleNames,
                windowID: windowID
            )
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
            if let cycleID = pendingBossBuffCycleID {
                pendingBossBuffCycleID = nil
                if await castAllConfiguredBuffs(windowID: windowID) {
                    onBossBuffsCompleted?(cycleID)
                }
            }
            if let kick = pendingBossKick {
                pendingBossKick = nil
                let command = "/踢出隊伍 \(kick.roleName)"
                guard await sendChatCommand(command, windowID: windowID) else { break }
                log("已发送老板踢出指令：\(command)")
                onBossKicked?(kick.cycleID)
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
        log("神殿模式 · 挂绳组队已停止")
        onStopped?()
    }

    private func createPartyAndInvite(roleNames: [String], windowID: CGWindowID) async {
        log("首次创建队伍，开始发送建队指令")
        var commands = ["/退出隊伍", "/建立隊伍"]
        commands.append(contentsOf: roleNames.map { "/邀請組隊 \($0)" })
        for (index, command) in commands.enumerated() where isRunning && !Task.isCancelled {
            guard await sendChatCommand(command, windowID: windowID) else { return }
            log("已发送队伍指令：\(command)")
            if command == "/建立隊伍" {
                onTeamCreated?()
            } else if command.hasPrefix("/邀請組隊 ") {
                let roleName = String(command.dropFirst("/邀請組隊 ".count))
                onInvitationSent?(roleName)
            }
            if index < commands.count - 1 {
                await randomSleep(0.55...1.15)
            }
        }
        log("首次建队指令已发送完毕")
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
        guard count != bossOrangeBaseline else { return }
        log("橙点数量由 \(bossOrangeBaseline ?? 0) 变为 \(count)，判定老板已进队")
        activeBossCycleID = nil
        onBossJoined?(cycleID)
    }

    private func reportBuffDueIfNeeded() {
        guard !configuredBuffs.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        let minimumRemaining = configuredBuffs.compactMap { buff in
            buffDeadlines[buff.id].map { $0 - now }
        }.min()
        guard let minimumRemaining, minimumRemaining <= 10, now >= nextBuffDueReportAt else { return }
        onBuffDue?()
        nextBuffDueReportAt = now + 8
    }

    private func castAllConfiguredBuffs(windowID: CGWindowID) async -> Bool {
        if configuredBuffs.isEmpty {
            return true
        }
        guard await ensureGameFocus(windowID: windowID) else { return false }
        for (index, buff) in configuredBuffs.enumerated() where isRunning && !Task.isCancelled {
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
        let now = Date().timeIntervalSince1970
        buffDeadlines = Dictionary(uniqueKeysWithValues: configuredBuffs.map { ($0.id, now + $0.duration) })
        nextBuffDueReportAt = 0
        return true
    }

    private func sendChatCommand(_ command: String, windowID: CGWindowID) async -> Bool {
        guard await ensureGameFocus(windowID: windowID) else { return false }
        do {
            try await human.pressNamedKey("Enter")
        } catch {
            onError?("激活聊天窗口失败：\(error.localizedDescription)")
            return false
        }
        await randomSleep(0.18...0.42)
        guard isRunning, !Task.isCancelled else { return false }
        guard await ensureGameFocus(windowID: windowID) else { return false }
        await human.typeText(command)
        await randomSleep(0.12...0.32)
        guard isRunning, !Task.isCancelled else { return false }
        guard await ensureGameFocus(windowID: windowID) else { return false }
        do {
            try await human.pressNamedKey("Enter")
            return true
        } catch {
            onError?("发送聊天指令失败：\(error.localizedDescription)")
            return false
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
