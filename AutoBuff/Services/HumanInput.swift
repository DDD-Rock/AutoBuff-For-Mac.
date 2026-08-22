import AppKit
import CoreGraphics
import Foundation

actor ChatInputTransactionCoordinator {
    static let shared = ChatInputTransactionCoordinator()

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withTransaction<T>(_ operation: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

actor HumanInput {
    private var currentDirection: Direction?
    private var pressedNamedKeyCodes: Set<CGKeyCode> = []
    private var pressedDirectionKeyCodes: Set<CGKeyCode> = []
    private let directionTapDuration: ClosedRange<Int> = 40...120
    private let directionChangeDelay: ClosedRange<Int> = 50...200
    private let portalPressDuration: ClosedRange<Int> = 200...800
    private let mouseClickDuration: ClosedRange<Int> = 50...150
    private let mouseMoveSteps: ClosedRange<Int> = 3...8
    
    enum Direction: String {
        case left, right, up, down
    }
    
    func moveLeft() { changeDirection(.left) }
    func moveRight() { changeDirection(.right) }
    func stopMove() { changeDirection(nil) }
    
    func usePortal() {
        changeDirection(nil)
        sleepMs(100)
        let duration = randomDuration(portalPressDuration)
        KeyboardUtils.postKey(0x7E, keyDown: true)
        Thread.sleep(forTimeInterval: duration)
        KeyboardUtils.postKey(0x7E, keyDown: false)
    }
    
    func tapDirection(_ direction: Direction) {
        changeDirection(nil)
        sleepMs(50)
        let duration = randomDuration(directionTapDuration)
        let code = keyCode(for: direction)
        KeyboardUtils.postKey(code, keyDown: true)
        Thread.sleep(forTimeInterval: duration)
        KeyboardUtils.postKey(code, keyDown: false)
    }

    func tapDirection(
        _ direction: Direction,
        holdMS: ClosedRange<Int>,
        intervalMS: ClosedRange<Int>
    ) async {
        changeDirection(nil)
        try? await Task.sleep(for: .milliseconds(Int(randomDuration(intervalMS) * 1000)))
        guard !Task.isCancelled else { return }
        let code = keyCode(for: direction)
        KeyboardUtils.postKey(code, keyDown: true)
        do {
            try await Task.sleep(for: .milliseconds(Int(randomDuration(holdMS) * 1000)))
        } catch {
            KeyboardUtils.postKey(code, keyDown: false)
            return
        }
        KeyboardUtils.postKey(code, keyDown: false)
        try? await Task.sleep(for: .milliseconds(Int(randomDuration(intervalMS) * 1000)))
    }
    
    func clickAt(screenPoint: CGPoint, offsetRange: Int = 10) {
        let offsetX = CGFloat.random(in: CGFloat(-offsetRange)...CGFloat(offsetRange))
        let offsetY = CGFloat.random(in: CGFloat(-offsetRange)...CGFloat(offsetRange))
        let target = CGPoint(x: screenPoint.x + offsetX, y: screenPoint.y + offsetY)

        moveMouse(to: target)
        Thread.sleep(forTimeInterval: Double.random(in: 0.05...0.15))
        let duration = randomDuration(mouseClickDuration)
        postMouse(down: true, at: target)
        Thread.sleep(forTimeInterval: duration)
        postMouse(down: false, at: target)
    }

    func moveMouse(to screenPoint: CGPoint) {
        // CGEvent and CGWindow use the same top-left global display coordinate
        // system. NSEvent.mouseLocation is unflipped (bottom-left), so do not mix it in.
        let current = CGEvent(source: nil)?.location ?? screenPoint
        let steps = Int.random(in: mouseMoveSteps)
        for step in 1...steps {
            let progress = Double(step) / Double(steps)
            let eased = 1 - pow(1 - progress, 2)
            let x = current.x + (screenPoint.x - current.x) * eased
            let y = current.y + (screenPoint.y - current.y) * eased
            postMouseMove(to: CGPoint(x: x, y: y))
            Thread.sleep(forTimeInterval: Double.random(in: 0.01...0.03))
        }
        postMouseMove(to: screenPoint)
    }
    
    @discardableResult
    func pressNamedKey(_ key: String) throws -> TimeInterval {
        try KeyboardUtils.pressKey(key)
    }

    @discardableResult
    func tapNamedKey(_ key: String, holdMS: ClosedRange<Int>) throws -> TimeInterval {
        let name = KeyCodeMap.resolveKeyName(key)
        guard let keyCode = KeyCodeMap.virtualKeyCode(for: name) else {
            throw KeyboardUtils.InputError.unsupportedKey(key)
        }
        let duration = randomDuration(holdMS)
        KeyboardUtils.postKey(keyCode, keyDown: true)
        let pressedAt = Date().timeIntervalSince1970
        Thread.sleep(forTimeInterval: duration)
        KeyboardUtils.postKey(keyCode, keyDown: false)
        return pressedAt
    }

    @discardableResult
    func holdNamedKey(_ key: String) throws -> CGKeyCode {
        try pressNamedKeyDown(key)
    }

    @discardableResult
    func pressNamedKeyDown(_ key: String) throws -> CGKeyCode {
        let name = KeyCodeMap.resolveKeyName(key)
        guard let keyCode = KeyCodeMap.virtualKeyCode(for: name) else {
            throw KeyboardUtils.InputError.unsupportedKey(key)
        }
        KeyboardUtils.postKey(keyCode, keyDown: true)
        pressedNamedKeyCodes.insert(keyCode)
        return keyCode
    }

    func releaseKey(_ keyCode: CGKeyCode) {
        KeyboardUtils.postKey(keyCode, keyDown: false)
        pressedNamedKeyCodes.remove(keyCode)
    }

    /// Keeps any already-held named key (for example, heal) pressed while
    /// performing direction-down -> skill tap -> skill-up -> direction-up.
    func performDirectionalSkill(
        _ direction: Direction,
        skillKey: String,
        directionLeadMS: Int,
        skillHoldMS: Int,
        directionReleaseDelayMS: Int
    ) async throws {
        let directionCode = keyCode(for: direction)
        var skillCode: CGKeyCode?
        pressDirectionRaw(direction)
        do {
            try await Task.sleep(for: .milliseconds(directionLeadMS))
            try Task.checkCancellation()
            skillCode = try pressNamedKeyDown(skillKey)
            try await Task.sleep(for: .milliseconds(skillHoldMS))
            if let skillCode {
                releaseKey(skillCode)
            }
            try await Task.sleep(for: .milliseconds(directionReleaseDelayMS))
            releaseDirectionRaw(direction)
        } catch {
            if let skillCode {
                releaseKey(skillCode)
            }
            KeyboardUtils.postKey(directionCode, keyDown: false)
            pressedDirectionKeyCodes.remove(directionCode)
            throw error
        }
    }
    
    func releaseAll() {
        currentDirection = nil
        for code: CGKeyCode in [0x7B, 0x7C, 0x7D, 0x7E] {
            KeyboardUtils.postKey(code, keyDown: false)
        }
        pressedDirectionKeyCodes.removeAll()
        for code in pressedNamedKeyCodes {
            KeyboardUtils.postKey(code, keyDown: false)
        }
        pressedNamedKeyCodes.removeAll()
    }

    func typeText(_ text: String) {
        KeyboardUtils.postText(text)
    }

    func performJumpGrabRope(
        jumpKey: String,
        direction: Direction,
        directionLeadMS: Int,
        upLeadMS: Int,
        jumpHoldMS: Int,
        directionReleaseGapMS: Int,
        upHoldMS: Int
    ) async throws {
        releaseAll()
        pressDirectionRaw(direction)
        do {
            try await Task.sleep(for: .milliseconds(directionLeadMS))
            let jumpCode = try pressNamedKeyDown(jumpKey)
            try await Task.sleep(for: .milliseconds(upLeadMS))
            pressDirectionRaw(.up)
            try await Task.sleep(for: .milliseconds(max(1, jumpHoldMS - upLeadMS)))
            releaseKey(jumpCode)
            try await Task.sleep(for: .milliseconds(max(1, directionReleaseGapMS)))
            releaseDirectionRaw(direction)
            try await Task.sleep(for: .milliseconds(upHoldMS))
            releaseDirectionRaw(.up)
        } catch {
            releaseAll()
            throw error
        }
    }

    func performRopeDismount(
        jumpKey: String,
        direction: Direction,
        directionLeadMS: Int,
        jumpHoldMS: Int,
        directionReleaseGapMS: Int
    ) async throws {
        releaseAll()
        pressDirectionRaw(direction)
        do {
            try await Task.sleep(for: .milliseconds(directionLeadMS))
            let jumpCode = try pressNamedKeyDown(jumpKey)
            try await Task.sleep(for: .milliseconds(jumpHoldMS))
            releaseKey(jumpCode)
            try await Task.sleep(for: .milliseconds(max(1, directionReleaseGapMS)))
            releaseDirectionRaw(direction)
        } catch {
            releaseAll()
            throw error
        }
    }

    func holdDirection(_ direction: Direction) { changeDirection(direction) }

    private func pressDirectionRaw(_ direction: Direction) {
        let code = keyCode(for: direction)
        guard !pressedDirectionKeyCodes.contains(code) else { return }
        KeyboardUtils.postKey(code, keyDown: true)
        pressedDirectionKeyCodes.insert(code)
    }

    private func releaseDirectionRaw(_ direction: Direction) {
        let code = keyCode(for: direction)
        KeyboardUtils.postKey(code, keyDown: false)
        pressedDirectionKeyCodes.remove(code)
    }

    func performDownJump(
        jumpKey: String,
        downLeadMS: Int,
        jumpHoldMS: Int,
        downReleaseAfterJumpMS: Int
    ) async throws {
        changeDirection(.down)
        do {
            try await Task.sleep(for: .milliseconds(downLeadMS))
            let jumpCode = try pressNamedKeyDown(jumpKey)
            do {
                let downHoldAfterJump = min(max(1, downReleaseAfterJumpMS), max(1, jumpHoldMS - 1))
                try await Task.sleep(for: .milliseconds(downHoldAfterJump))
                changeDirection(nil)
                try await Task.sleep(for: .milliseconds(max(1, jumpHoldMS - downHoldAfterJump)))
            } catch {
                releaseKey(jumpCode)
                changeDirection(nil)
                throw error
            }
            releaseKey(jumpCode)
        } catch {
            changeDirection(nil)
            throw error
        }
    }
    
    private func changeDirection(_ newDirection: Direction?) {
        if currentDirection == newDirection { return }
        if let currentDirection {
            KeyboardUtils.postKey(keyCode(for: currentDirection), keyDown: false)
            Thread.sleep(forTimeInterval: randomDuration(directionChangeDelay))
        }
        currentDirection = newDirection
        if let newDirection {
            KeyboardUtils.postKey(keyCode(for: newDirection), keyDown: true)
        }
    }
    
    private func keyCode(for direction: Direction) -> CGKeyCode {
        switch direction {
        case .left: return 0x7B
        case .right: return 0x7C
        case .down: return 0x7D
        case .up: return 0x7E
        }
    }
    
    private func randomDuration(_ range: ClosedRange<Int>) -> TimeInterval {
        let minMs = Double(range.lowerBound)
        let maxMs = Double(range.upperBound)
        let mean = (minMs + maxMs) / 2
        let std = (maxMs - minMs) / 4
        let value = Double.random(in: 0...1)
        let gauss = mean + std * (value - 0.5) * 2
        return min(max(gauss, minMs), maxMs) / 1000.0
    }
    
    private func sleepMs(_ ms: Int) {
        Thread.sleep(forTimeInterval: Double(ms) / 1000.0)
    }
    
    private func postMouseMove(to point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }
    
    private func postMouse(down: Bool, at point: CGPoint) {
        let type: CGEventType = down ? .leftMouseDown : .leftMouseUp
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }
}
