import AppKit
import SwiftUI

final class AutoBuffAppDelegate: NSObject, NSApplicationDelegate {
    private var didApplyInitialWindowSize = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        for application in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        where application.processIdentifier != currentProcessID {
            application.terminate()
        }
        applyInitialWindowSize()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        applyInitialWindowSize()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func applyInitialWindowSize() {
        guard !didApplyInitialWindowSize else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self,
                  !self.didApplyInitialWindowSize,
                  let window = NSApp.windows.first(where: { $0.title == "YzY - Auto Buff" }) else {
                return
            }
            window.setContentSize(NSSize(width: 520, height: 620))
            window.minSize = NSSize(width: 480, height: 500)
            window.makeFirstResponder(nil)
            if let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame {
                window.setFrameOrigin(
                    NSPoint(
                        x: visibleFrame.midX - window.frame.width / 2,
                        y: visibleFrame.midY - window.frame.height / 2
                    )
                )
            }
            self.didApplyInitialWindowSize = true
        }
    }
}

@main
struct AutoBuffApp: App {
    @NSApplicationDelegateAdaptor(AutoBuffAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("YzY - Auto Buff") {
            if #available(macOS 14.0, *) {
                ContentView()
            } else {
                Text("AutoBuff 需要 macOS 14.0 或更高版本")
                    .padding()
            }
        }
        .defaultSize(width: 520, height: 620)
        .windowResizability(.contentMinSize)
    }
}
