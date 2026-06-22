import AppKit
import CoreGraphics
import Foundation

actor HumanInput {
    private var currentDirection: Direction?
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
    
    func clickAt(screenPoint: CGPoint, offsetRange: Int = 10) {
        let offsetX = CGFloat.random(in: CGFloat(-offsetRange)...CGFloat(offsetRange))
        let offsetY = CGFloat.random(in: CGFloat(-offsetRange)...CGFloat(offsetRange))
        let target = CGPoint(x: screenPoint.x + offsetX, y: screenPoint.y + offsetY)
        
        // CGEvent and CGWindow use the same top-left global display coordinate
        // system. NSEvent.mouseLocation is unflipped (bottom-left), so do not mix it in.
        let current = CGEvent(source: nil)?.location ?? screenPoint
        let steps = Int.random(in: mouseMoveSteps)
        for step in 1...steps {
            let progress = Double(step) / Double(steps)
            let eased = 1 - pow(1 - progress, 2)
            let x = current.x + (target.x - current.x) * eased
            let y = current.y + (target.y - current.y) * eased
            postMouseMove(to: CGPoint(x: x, y: y))
            Thread.sleep(forTimeInterval: Double.random(in: 0.01...0.03))
        }
        postMouseMove(to: target)
        Thread.sleep(forTimeInterval: Double.random(in: 0.05...0.15))
        let duration = randomDuration(mouseClickDuration)
        postMouse(down: true, at: target)
        Thread.sleep(forTimeInterval: duration)
        postMouse(down: false, at: target)
    }
    
    @discardableResult
    func pressNamedKey(_ key: String) throws -> TimeInterval {
        try KeyboardUtils.pressKey(key)
    }
    
    func releaseAll() {
        currentDirection = nil
        for code: CGKeyCode in [0x7B, 0x7C, 0x7D, 0x7E] {
            KeyboardUtils.postKey(code, keyDown: false)
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
