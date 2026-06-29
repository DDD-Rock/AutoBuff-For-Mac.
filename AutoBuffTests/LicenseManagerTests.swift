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
}
