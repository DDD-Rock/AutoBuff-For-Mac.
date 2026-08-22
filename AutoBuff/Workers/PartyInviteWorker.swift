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
    private let samePopupTolerance: CGFloat = 18

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
        await ChatInputTransactionCoordinator.shared.withTransaction {
            onLog?("检测到队伍邀请，自动同意")
            guard await ensureGameFocus(windowID: windowID) else {
                onLog?("无法确认游戏窗口焦点，本次不点击也不报告入队")
                return
            }

            var clickPoint = initialPoint
            for attempt in 1...3 where isRunning && !Task.isCancelled {
                onLog?(
                    "第 \(attempt) 次點擊同意按鈕：(\(Int(clickPoint.x)), \(Int(clickPoint.y)))"
                )
                await human.clickAt(screenPoint: clickPoint, offsetRange: 2)
                var popupGoneFrames = 0
                for _ in 0..<4 where isRunning && !Task.isCancelled {
                    await sleep(0.15)
                    let currentPoint = try? await detector.findAcceptButtonScreenPoint()
                    if isSamePopup(clickPoint, currentPoint, tolerance: samePopupTolerance) {
                        popupGoneFrames = 0
                        if let currentPoint {
                            clickPoint = currentPoint
                        }
                        continue
                    }
                    popupGoneFrames += 1
                    if popupGoneFrames >= 2 {
                        onLog?("已同意队伍邀请")
                        onInviteAccepted?()
                        return
                    }
                }
            }
            onLog?("邀请弹窗点击后仍未消失，本次不报告入队成功")
        }
    }

    private func ensureGameFocus(windowID: CGWindowID) async -> Bool {
        guard windowSelector.isWindowValid(windowID: windowID) else { return false }
        for _ in 0..<8 where isRunning && !Task.isCancelled {
            _ = windowSelector.bringWindowToFront(windowID: windowID)
            await sleep(0.15)
            if windowSelector.isWindowOwnerFrontmost(windowID: windowID) {
                _ = windowSelector.bringWindowToFront(windowID: windowID)
                await sleep(0.10)
                return windowSelector.isWindowOwnerFrontmost(windowID: windowID)
            }
        }
        return false
    }

    private func isSamePopup(_ initialPoint: CGPoint, _ currentPoint: CGPoint?, tolerance: CGFloat) -> Bool {
        guard let currentPoint else { return false }
        return abs(currentPoint.x - initialPoint.x) <= tolerance
            && abs(currentPoint.y - initialPoint.y) <= tolerance
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
