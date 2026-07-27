import Foundation
import Testing
@testable import AutoBuff

struct LicenseManagerTests {
    @Test func activationCodeUsesExpectedMd5Rule() {
        #expect(LicenseManager.expectedActivationCode(for: "ABC123") == "1B9DD7E03E89921DCFC2B041F38B55E4")
    }

    @Test func activationCodeAcceptsGroupedInput() {
        #expect(LicenseManager.expectedActivationCode(for: "ABC-123") == "1B9DD7E03E89921DCFC2B041F38B55E4")
    }

    @Test func masterActivationCodeIsAlwaysValid() {
        #expect(LicenseManager.isValidActivationCode("zhimakaimenyzy"))
    }

    @Test func legacyActivationStorageDoesNotUnlockCurrentApp() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: LicenseManager.activationStorageKey)
        defaults.set("ZHIMAKAIMENYZY", forKey: LicenseManager.legacyActivationStorageKey)
        defer {
            defaults.removeObject(forKey: LicenseManager.activationStorageKey)
            defaults.removeObject(forKey: LicenseManager.legacyActivationStorageKey)
        }

        #expect(LicenseManager.savedActivationCode().isEmpty)
        #expect(!LicenseManager.isActivated())
    }
}
