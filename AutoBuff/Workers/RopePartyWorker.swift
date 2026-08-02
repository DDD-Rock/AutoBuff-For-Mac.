import CoreGraphics
import Foundation

@available(macOS 14.0, *)
@MainActor
final class RopePartyWorker: ObservableObject {
    var onLog: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onStopped: (() -> Void)?

    private let human = HumanInput()
    private let windowSelector = WindowSelector()
    private var task: Task<Void, Never>?
    private var runID = UUID()
    private(set) var isRunning = false

    func start(settings: AppSettings, windowID: CGWindowID) {
        stop()
        let currentRunID = UUID()
        runID = currentRunID
        isRunning = true
        task = Task {
            await run(settings: settings, windowID: windowID, runID: currentRunID)
        }
    }

    func stop() {
        isRunning = false
        runID = UUID()
        task?.cancel()
        task = nil
        Task { await human.releaseAll() }
    }

    func disbandParty(windowID: CGWindowID) {
        stop()
        let currentRunID = UUID()
        runID = currentRunID
        isRunning = true
        task = Task {
            log("收到网页解散队伍指令")
            guard await ensureGameFocus(windowID: windowID) else {
                finishOneShot(runID: currentRunID)
                return
            }
            do {
                try await sendChatCommand("/退出隊伍")
                log("已发送解散队伍指令：/退出隊伍")
            } catch {
                onError?("解散队伍指令发送失败：\(error.localizedDescription)")
            }
            await human.releaseAll()
            finishOneShot(runID: currentRunID)
        }
    }

    private func finishOneShot(runID currentRunID: UUID) {
        guard runID == currentRunID else { return }
        isRunning = false
        task = nil
        onStopped?()
    }

    private func run(settings: AppSettings, windowID: CGWindowID, runID currentRunID: UUID) async {
        log("神殿模式 · 挂绳组队启动...")
        if settings.ropePartyIsLeader && !settings.ropePartyInviteRoleNames.isEmpty {
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
            await sleep(1)
        }
        await human.releaseAll()
        guard runID == currentRunID else { return }
        isRunning = false
        task = nil
        log("神殿模式 · 挂绳组队已停止")
        onStopped?()
    }

    private func createPartyAndInvite(roleNames: [String], windowID: CGWindowID) async {
        guard await ensureGameFocus(windowID: windowID) else { return }
        log("首次创建队伍，开始发送建队指令")
        var commands = ["/退出队伍", "/建立队伍"]
        commands.append(contentsOf: roleNames.map { "/邀请组队 \($0)" })
        for (index, command) in commands.enumerated() where isRunning && !Task.isCancelled {
            do {
                try await sendChatCommand(command)
                log("已发送队伍指令：\(command)")
            } catch {
                onError?("队伍指令发送失败：\(error.localizedDescription)")
                return
            }
            if index < commands.count - 1 {
                await randomSleep(0.55...1.15)
            }
        }
        log("首次建队指令已发送完毕")
    }

    private func sendChatCommand(_ command: String) async throws {
        try await human.pressNamedKey("Enter")
        await randomSleep(0.18...0.42)
        guard isRunning, !Task.isCancelled else { return }
        await human.typeText(command)
        await randomSleep(0.12...0.32)
        guard isRunning, !Task.isCancelled else { return }
        try await human.pressNamedKey("Enter")
    }

    private func ensureGameFocus(windowID: CGWindowID) async -> Bool {
        if windowSelector.isWindowOwnerFrontmost(windowID: windowID) { return true }
        for _ in 1...24 where isRunning && !Task.isCancelled {
            _ = windowSelector.bringWindowToFront(windowID: windowID)
            await sleep(0.25)
            if windowSelector.isWindowOwnerFrontmost(windowID: windowID) { return true }
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
