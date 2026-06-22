import ApplicationServices
import AppKit
import Security

enum PermissionManager {
    enum AccessibilitySigningStatus {
        case stable
        case adHoc
        case unknown
    }
    
    static func requestAccessibility(prompt: Bool = true) -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    
    static var accessibilityStatusText: String {
        AXIsProcessTrusted() ? "已授权" : "未授权"
    }
    
    static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }
    
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }
    
    static var accessibilitySigningStatus: AccessibilitySigningStatus {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            Bundle.main.bundleURL as CFURL,
            [],
            &staticCode
        ) == errSecSuccess, let staticCode else {
            return .unknown
        }
        
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let dictionary = information as? [String: Any] else {
            return .unknown
        }
        
        let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate]
        return (certificates?.isEmpty == false) ? .stable : .adHoc
    }
    
    static var isAdHocSigned: Bool {
        accessibilitySigningStatus == .adHoc
    }
    
    @discardableResult
    static func resetAccessibilityConsent() -> Bool {
        resetConsent(service: "Accessibility")
    }
    
    @discardableResult
    static func resetScreenRecordingConsent() -> Bool {
        resetConsent(service: "ScreenCapture")
    }
    
    private static func resetConsent(service: String) -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleIdentifier]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    static func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
