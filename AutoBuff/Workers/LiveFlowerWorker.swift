import CoreGraphics
import Foundation

@available(macOS 14.0, *)
@MainActor
final class LiveFlowerWorker: ObservableObject {
    var onLog: ((String) -> Void)?
    var onCountdown: (([Int: Int]) -> Void)?
    var onError: ((String) -> Void)?
    var onStopped: (() -> Void)?
    
    private let human = HumanInput()
    private let windowSelector = WindowSelector()
    private let countdownPublisher = CountdownPublisher()
    private var task: Task<Void, Never>?
    private var nextRelease: [Int: TimeInterval] = [:]
    private var runID = UUID()
    private(set) var isRunning = false
    
    func start(skills: [SkillConfig], windowID: CGWindowID, movementMode: MovementMode, sitChairEnabled: Bool, chairKey: String) {
        stop()
        let currentRunID = UUID()
        runID = currentRunID
        isRunning = true
        nextRelease = [:]
        countdownPublisher.start { [weak self] info in
            self?.onCountdown?(info)
        }
        task = Task {
            await run(
                skills: skills,
                windowID: windowID,
                movementMode: movementMode,
                sitChairEnabled: sitChairEnabled,
                chairKey: chairKey,
                runID: currentRunID
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
        skills: [SkillConfig],
        windowID: CGWindowID,
        movementMode: MovementMode,
        sitChairEnabled: Bool,
        chairKey: String,
        runID currentRunID: UUID
    ) async {
        log("活花模式启动...")
        var isSitting = false
        
        await releaseBatch(skills: skills, windowID: windowID, movementMode: movementMode)
        
        while isRunning && !Task.isCancelled {
            guard windowSelector.isWindowValid(windowID: windowID) else {
                onError?("游戏窗口已关闭或不可见")
                break
            }
            let current = Date().timeIntervalSince1970
            let due = skills.filter { current >= (nextRelease[$0.id] ?? 0) }
            if !due.isEmpty {
                await releaseBatch(skills: due, windowID: windowID, movementMode: movementMode)
                isSitting = false
            }
            if sitChairEnabled && !isSitting {
                let chairCheckTime = Date().timeIntervalSince1970
                let minRemaining = skills.compactMap { skill -> TimeInterval? in
                    guard let t = nextRelease[skill.id] else { return nil }
                    return t - chairCheckTime
                }.min() ?? 0
                if minRemaining > 5 {
                    do {
                        try await human.pressNamedKey(chairKey)
                        isSitting = true
                        log("空闲时间较长，已按下椅子键")
                    } catch {
                        onError?("椅子键错误: \(error.localizedDescription)")
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await human.releaseAll()
        countdownPublisher.stop()
        log("活花模式已停止")
        if runID == currentRunID {
            isRunning = false
            task = nil
            onStopped?()
        }
    }
    
    private func releaseBatch(
        skills: [SkillConfig],
        windowID: CGWindowID,
        movementMode: MovementMode
    ) async {
        if !windowSelector.bringWindowToFront(windowID: windowID) {
            onError?("无法将游戏窗口置于前台")
        }
        await moveBeforeSkill(movementMode)
        if movementMode != .none {
            await human.stopMove()
            try? await Task.sleep(nanoseconds: UInt64.random(in: 300_000_000...500_000_000))
        }
        for (index, skill) in skills.enumerated() {
            guard isRunning else { break }
            guard let pressedAt = await releaseSkill(skill) else { continue }
            let randomDelay = skill.randomDelay > 0 ? Double.random(in: 0...skill.randomDelay) : 0
            let releaseAt = CountdownTiming.nextRelease(
                pressedAt: pressedAt,
                interval: skill.interval,
                earlyBy: randomDelay
            )
            nextRelease[skill.id] = releaseAt
            countdownPublisher.replaceDeadlines(nextRelease, now: pressedAt)
            log(
                "技能 \(skill.key) 倒计时 \(CountdownTiming.remainingSeconds(until: releaseAt, now: pressedAt)) 秒，"
                + "下次释放 \(CountdownTiming.clockText(for: releaseAt))"
            )
            if index < skills.count - 1 {
                let gap = UInt64.random(in: 2_000_000_000...3_000_000_000)
                try? await Task.sleep(nanoseconds: gap)
            }
        }
        await moveAfterSkill(movementMode)
        await human.stopMove()
    }
    
    private func releaseSkill(_ skill: SkillConfig) async -> TimeInterval? {
        log("准备释放技能: \(skill.key)")
        var lastPressedAt: TimeInterval?
        do {
            lastPressedAt = try await human.pressNamedKey(skill.key)
            try await Task.sleep(nanoseconds: UInt64.random(in: 100_000_000...300_000_000))
            lastPressedAt = try await human.pressNamedKey(skill.key)
        } catch {
            onError?("按键错误: \(error.localizedDescription)")
        }
        return lastPressedAt
    }
    
    private func moveBeforeSkill(_ mode: MovementMode) async {
        switch mode {
        case .none: break
        case .right: await moveDirection(.right, ms: 500...1000)
        case .left: await moveDirection(.left, ms: 500...1000)
        }
    }
    
    private func moveAfterSkill(_ mode: MovementMode) async {
        switch mode {
        case .none: break
        case .right: await moveDirection(.left, ms: 2000...3000)
        case .left: await moveDirection(.right, ms: 2000...3000)
        }
    }
    
    private func moveDirection(_ direction: HumanInput.Direction, ms: ClosedRange<Int>) async {
        let duration = UInt64.random(in: UInt64(ms.lowerBound * 1_000_000)...UInt64(ms.upperBound * 1_000_000))
        if direction == .left { await human.moveLeft() } else { await human.moveRight() }
        try? await Task.sleep(nanoseconds: duration)
        await human.stopMove()
    }
    
    private func log(_ message: String) {
        onLog?(message)
    }
}
