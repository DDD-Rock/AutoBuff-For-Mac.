import CoreGraphics

enum KeyCodeMap {
    static func virtualKeyCode(for key: String) -> CGKeyCode? {
        keyMap[normalize(key)]
    }
    
    static func resolveKeyName(_ key: String) -> String {
        normalize(key)
    }
    
    private static func normalize(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliases = [
            "↑": "up", "↓": "down", "←": "left", "→": "right",
            "esc": "escape", "return": "enter", "control": "ctrl",
            "option": "alt", "page up": "pageup", "page_up": "pageup",
            "page down": "pagedown", "page_down": "pagedown"
        ]
        let lowercased = trimmed.lowercased()
        return aliases[lowercased] ?? aliases[trimmed] ?? lowercased
    }
    
    // macOS virtual key codes are keyboard-position codes, not alphabetic indexes.
    private static let keyMap: [String: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B,
        "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
        "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D,
        "]": 0x1E, "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23,
        "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E,
        ".": 0x2F, "`": 0x32,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "space": 0x31, "enter": 0x24, "tab": 0x30, "caps": 0x39,
        "escape": 0x35, "delete": 0x33, "backspace": 0x33,
        "forwarddelete": 0x75, "shift": 0x38, "ctrl": 0x3B, "alt": 0x3A,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        "pageup": 0x74, "pagedown": 0x79, "home": 0x73, "end": 0x77,
        "insert": 0x72
    ]
    
    static let keyboardRows: [[String]] = [
        ["Esc", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"],
        ["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="],
        ["Tab", "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "[", "]", "\\"],
        ["Caps", "A", "S", "D", "F", "G", "H", "J", "K", "L", ";", "'", "Enter"],
        ["Shift", "Z", "X", "C", "V", "B", "N", "M", ",", ".", "/", "Shift"],
        ["Ctrl", "Alt", "Space", "Alt", "Ctrl"]
    ]
}
