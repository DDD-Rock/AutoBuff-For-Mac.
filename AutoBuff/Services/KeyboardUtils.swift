import CoreGraphics
import Foundation

enum KeyboardUtils {
    @discardableResult
    static func pressKey(_ key: String) throws -> TimeInterval {
        let name = KeyCodeMap.resolveKeyName(key)
        guard let keyCode = KeyCodeMap.virtualKeyCode(for: name) else {
            throw InputError.unsupportedKey(key)
        }
        let hold = Double.random(in: Double(AppConstants.keyHoldMinMS)...Double(AppConstants.keyHoldMaxMS)) / 1000.0
        postKey(keyCode, keyDown: true)
        let pressedAt = Date().timeIntervalSince1970
        Thread.sleep(forTimeInterval: hold)
        postKey(keyCode, keyDown: false)
        return pressedAt
    }
    
    static func postKey(_ keyCode: CGKeyCode, keyDown: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown) else { return }
        event.post(tap: .cghidEventTap)
    }
    
    enum InputError: Error, LocalizedError {
        case unsupportedKey(String)
        
        var errorDescription: String? {
            switch self {
            case .unsupportedKey(let key):
                return "不支持的按键：\(key)"
            }
        }
    }
}
