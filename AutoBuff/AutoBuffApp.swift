import AppKit
import SwiftUI

enum MainWindowLayout {
    static let sidebarWidth: CGFloat = 56
    static let minimumContentWidth: CGFloat = 540
    static let preferredContentWidth: CGFloat = 600

    static func preferredContentHeight(
        visibleScreenHeight: CGFloat,
        windowChromeHeight: CGFloat
    ) -> CGFloat {
        let availableHeight = max(
            500,
            visibleScreenHeight - max(0, windowChromeHeight) - 32
        )
        let proportionalHeight = visibleScreenHeight * 0.82
        return min(availableHeight, min(860, max(740, proportionalHeight)))
    }
}

final class AutoBuffAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        for application in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        where application.processIdentifier != currentProcessID {
            application.terminate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct AutoBuffApp: App {
    @NSApplicationDelegateAdaptor(AutoBuffAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("YzY - Auto Buff") {
            if #available(macOS 14.0, *) {
                AccountLoginGateView {
                    ContentView()
                }
            } else {
                Text("AutoBuff 需要 macOS 14.0 或更高版本")
                    .padding()
            } 
        }
        .defaultSize(
            width: MainWindowLayout.preferredContentWidth,
            height: 820
        )
        .windowResizability(.automatic)
    }
}
