import AppKit
import ApplicationServices
import CoreGraphics

struct GameWindowInfo: Identifiable, Equatable {
    let windowID: CGWindowID
    let processID: pid_t
    let title: String
    let ownerName: String
    let bounds: CGRect
    let size: CGSize
    
    var id: CGWindowID { windowID }
}

final class WindowSelector {
    /// Do not restrict discovery to the current Space. Opening AutoBuff from a
    /// full-screen game switches Spaces, so `.optionOnScreenOnly` would hide
    /// the very window the user is trying to select.
    static let discoveryOptions: CGWindowListOption = [.excludeDesktopElements]

    func getAllWindows(minSize: CGSize = CGSize(width: 100, height: 100)) -> [GameWindowInfo] {
        guard let list = CGWindowListCopyWindowInfo(
            Self.discoveryOptions,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        let windows = list.compactMap {
            makeWindowInfo(from: $0, minSize: minSize, requireTitle: true)
        }
        return windows.sorted { $0.size.width * $0.size.height > $1.size.width * $1.size.height }
    }
    
    func autoDetectGameWindow(prefix: String = AppConstants.gameWindowTitlePrefix) -> GameWindowInfo? {
        getAllWindows().first {
            $0.title.localizedCaseInsensitiveContains(prefix)
                || Self.isKnownGameOwner($0.ownerName)
        }
    }

    static func pickerTitle(rawTitle: String, ownerName: String) -> String? {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }
        guard isKnownGameOwner(ownerName) else {
            return nil
        }
        return ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isKnownGameOwner(_ ownerName: String) -> Bool {
        ownerName.localizedCaseInsensitiveContains("MapleStory Worlds")
    }
    
    func getWindowInfo(windowID: CGWindowID) -> GameWindowInfo? {
        // Do not use optionOnScreenOnly here. A full-screen game moves to a
        // different Space when the user clicks AutoBuff, but it must still be
        // discoverable so that we can activate it again.
        let options: CGWindowListOption = [.optionIncludingWindow, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]] else {
            return nil
        }
        return list
            .first { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }
            .flatMap { makeWindowInfo(from: $0, minSize: .zero, requireTitle: false) }
    }
    
    func isWindowValid(windowID: CGWindowID) -> Bool {
        getWindowInfo(windowID: windowID) != nil
    }

    func isWindowOwnerFrontmost(windowID: CGWindowID) -> Bool {
        guard let info = getWindowInfo(windowID: windowID) else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == info.processID
    }
    
    @discardableResult
    func bringWindowToFront(windowID: CGWindowID) -> Bool {
        guard let info = getWindowInfo(windowID: windowID) else { return false }
        var requested = false
        if let app = NSRunningApplication(processIdentifier: info.processID) {
            app.unhide()
            if NSApp.isActive {
                // macOS 14 requires cooperative activation when the currently
                // active app deliberately hands focus to another app.
                NSApp.yieldActivation(to: app)
                requested = app.activate(
                    from: NSRunningApplication.current,
                    options: [.activateAllWindows]
                )
            } else {
                requested = app.activate(options: [.activateAllWindows])
            }
        }
        requested = raiseAccessibilityWindow(info) || requested
        return requested
    }

    func focusDebugDescription(windowID: CGWindowID) -> String {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontName = frontmost?.localizedName ?? "未知"
        let frontPID = frontmost?.processIdentifier ?? -1
        guard let target = getWindowInfo(windowID: windowID) else {
            return "目标窗口ID=\(windowID)已无法查询；当前前台=\(frontName)(PID \(frontPID))"
        }
        return "目标=\(target.ownerName)(PID \(target.processID), 窗口ID \(windowID))；当前前台=\(frontName)(PID \(frontPID))"
    }

    private func makeWindowInfo(
        from info: [String: Any],
        minSize: CGSize,
        requireTitle: Bool
    ) -> GameWindowInfo? {
        guard let windowID = info[kCGWindowNumber as String] as? CGWindowID,
              let processID = info[kCGWindowOwnerPID as String] as? pid_t,
              let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else {
            return nil
        }
        let rawTitle = info[kCGWindowName as String] as? String ?? ""
        let owner = info[kCGWindowOwnerName as String] as? String ?? ""
        let title: String
        if requireTitle {
            guard let pickerTitle = Self.pickerTitle(
                rawTitle: rawTitle,
                ownerName: owner
            ) else {
                return nil
            }
            title = pickerTitle
        } else {
            title = rawTitle
        }
        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
        guard layer == 0, alpha > 0,
              bounds.width >= minSize.width,
              bounds.height >= minSize.height else {
            return nil
        }
        return GameWindowInfo(
            windowID: windowID,
            processID: processID,
            title: title,
            ownerName: owner,
            bounds: bounds,
            size: bounds.size
        )
    }

    private func raiseAccessibilityWindow(_ info: GameWindowInfo) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let application = AXUIElementCreateApplication(info.processID)
        var requested = AXUIElementSetAttributeValue(
            application,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        ) == .success

        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success,
              let windows = windowsValue as? [AXUIElement],
              !windows.isEmpty else {
            return requested
        }

        let target = windows.first { accessibilityWindow($0, matches: info) } ?? windows[0]
        if AXUIElementPerformAction(target, kAXRaiseAction as CFString) == .success {
            requested = true
        }
        _ = AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return requested
    }

    private func accessibilityWindow(_ window: AXUIElement, matches info: GameWindowInfo) -> Bool {
        var titleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &titleValue
        ) == .success,
           let title = titleValue as? String,
           !info.title.isEmpty,
           title == info.title {
            return true
        }

        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
              AXUIElementCopyAttributeValue(
                window,
                kAXSizeAttribute as CFString,
                &sizeValue
              ) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return false
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return false
        }
        return abs(position.x - info.bounds.origin.x) <= 2
            && abs(position.y - info.bounds.origin.y) <= 2
            && abs(size.width - info.bounds.width) <= 2
            && abs(size.height - info.bounds.height) <= 2
    }
}
