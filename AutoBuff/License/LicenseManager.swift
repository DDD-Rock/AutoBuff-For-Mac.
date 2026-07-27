import CryptoKit
import Foundation
import IOKit

enum LicenseManager {
    static let activationStorageKey = "autobuff.activationCode.v2"
    static let legacyActivationStorageKey = "autobuff.activationCode"
    private static let licenseSecret = "wxw752"
    private static let masterActivationCode = "ZHIMAKAIMENYZY"

    static func currentMachineCode() -> String {
        let source = platformUUID() ?? "\(Host.current().localizedName ?? "unknown")-\(NSUserName())"
        return md5Hex("\(source)\(AppConstants.appName)")
    }

    static func expectedActivationCode(for machineCode: String) -> String {
        md5Hex("\(normalize(machineCode))\(AppConstants.appName)\(licenseSecret)")
    }

    static func savedActivationCode() -> String {
        UserDefaults.standard.string(forKey: activationStorageKey) ?? ""
    }

    static func isActivated() -> Bool {
        isValidActivationCode(savedActivationCode())
    }

    @discardableResult
    static func saveActivationCode(_ code: String) -> Bool {
        let normalized = normalize(code)
        guard isValidActivationCode(normalized) else {
            return false
        }
        UserDefaults.standard.set(normalized, forKey: activationStorageKey)
        return true
    }

    static func clearActivation() {
        UserDefaults.standard.removeObject(forKey: activationStorageKey)
        UserDefaults.standard.removeObject(forKey: legacyActivationStorageKey)
    }

    static func normalize(_ value: String) -> String {
        value
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    static func isValidActivationCode(_ code: String) -> Bool {
        let normalized = normalize(code)
        return normalized == masterActivationCode || normalized == expectedActivationCode(for: currentMachineCode())
    }

    private static func md5Hex(_ value: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    private static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let uuid = IORegistryEntryCreateCFProperty(
            service,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String else {
            return nil
        }
        return uuid
    }
}
