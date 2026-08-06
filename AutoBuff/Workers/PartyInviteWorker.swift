import CoreGraphics
import Foundation

@available(macOS 14.0, *)
@MainActor
final class PartyInviteWorker: ObservableObject {
    var onLog: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onStateChanged: ((Bool) -> Void)?
    var onInviteAccepted: (() -> Void)?

    private let detector = PartyInviteDetector()
    private let human = HumanInput()
    private let windowSelector = WindowSelector()
    private var task: Task<Void, Never>?
    private var runID = UUID()

    private(set) var isRunning = false
    private(set) var currentWindowID: CGWindowID?

    func start(windowID: CGWindowID) {
        if isRunning, currentWindowID == windowID {
            return
        }
        stop()
        let currentRunID = UUID()
        runID = currentRunID
        currentWindowID = windowID
        isRunning = true
        detector.setWindow(windowID)
        onStateChanged?(true)
        task = Task {
            await run(windowID: windowID, runID: currentRunID)
        }
    }

    func stop() {
        guard isRunning || task != nil else { return }
        isRunning = false
        currentWindowID = nil
        runID = UUID()
        task?.cancel()
        task = nil
        onStateChanged?(false)
    }

    private func run(windowID: CGWindowID, runID currentRunID: UUID) async {
        while isRunning && !Task.isCancelled {
            guard windowSelector.isWindowValid(windowID: windowID) else {
                onError?("游戏窗口已失效，自动同意组队已停止")
                break
            }

            do {
                if let point = try await detector.findAcceptButtonScreenPoint() {
                    await acceptInvite(at: point, windowID: windowID)
                    await sleep(Double.random(in: 4.0...7.0))
                } else {
                    await sleep(Double.random(in: 1.0...2.0))
                }
            } catch {
                await sleep(2.0)
            }
        }

        if runID == currentRunID {
            isRunning = false
            currentWindowID = nil
            task = nil
            onStateChanged?(false)
        }
    }

    private func acceptInvite(at initialPoint: CGPoint, windowID: CGWindowID) async {
        onLog?("检测到队伍邀请，自动同意")
        if !windowSelector.bringWindowToFront(windowID: windowID) {
            onLog?("⚠️ 无法将游戏窗口置于前台，仍会尝试同意组队")
        }
        await sleep(0.15)

        await human.clickAt(screenPoint: initialPoint, offsetRange: 2)
        for _ in 0..<14 where isRunning && !Task.isCancelled {
            await sleep(0.15)
            if (try? await detector.findAcceptButtonScreenPoint()) == nil {
                onLog?("已同意队伍邀请")
                onInviteAccepted?()
                return
            }
        }
        onLog?("邀请弹窗点击后仍未消失，本次不报告入队成功")
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
