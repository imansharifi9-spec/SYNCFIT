import XCTest
@testable import SyncFit

final class CoachStripeOnboardingCallbackValidatorTests: XCTestCase {
    func testAcceptsReturnCallback() {
        XCTAssertEqual(result("syncfit://stripe-onboarding-return"), .returned)
        XCTAssertEqual(result("syncfit://stripe-onboarding-return/"), .returned)
    }

    func testAcceptsRefreshCallback() {
        XCTAssertEqual(result("syncfit://stripe-onboarding-return?refresh=1"), .refresh)
        XCTAssertEqual(result("syncfit://stripe-onboarding-return/?refresh=1"), .refresh)
    }

    func testRejectsMalformedCallbacks() {
        let invalid = [
            "syncfit://stripe-onboarding-return?refresh=0",
            "syncfit://stripe-onboarding-return?refresh=1&extra=1",
            "syncfit://stripe-onboarding-return?foo=1",
            "syncfit://stripe-onboarding-return#frag",
            "syncfit://user@stripe-onboarding-return",
            "syncfit://stripe-onboarding-return/path",
            "syncfit://coach-checkout-success?session_id=x",
            "https://stripe-onboarding-return",
        ]
        invalid.forEach { XCTAssertEqual(result($0), .invalid, $0) }
    }

    private func result(_ rawURL: String) -> CoachStripeOnboardingCallbackResult {
        CoachStripeOnboardingCallbackValidator.result(for: URL(string: rawURL)!)
    }
}
