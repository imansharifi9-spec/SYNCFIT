import XCTest
@testable import SyncFit

final class CoachCheckoutCallbackValidatorTests: XCTestCase {
    func testAcceptsOnlyExactSuccessCallbacks() {
        XCTAssertEqual(
            result("syncfit://coach-checkout-success?session_id=cs_test_123"),
            .success
        )
        XCTAssertEqual(
            result("syncfit://coach-checkout-success/?session_id=cs_test_123"),
            .success
        )
    }

    func testAcceptsOnlyExactCancelCallbacks() {
        XCTAssertEqual(result("syncfit://coach-checkout-cancel"), .canceled)
        XCTAssertEqual(result("syncfit://coach-checkout-cancel/"), .canceled)
    }

    func testRejectsMalformedSuccessCallbacks() {
        let invalidURLs = [
            "syncfit://coach-checkout-success",
            "syncfit://coach-checkout-success?session_id=",
            "syncfit://coach-checkout-success?session_id=%20",
            "syncfit://coach-checkout-success?session_id=one&extra=value",
            "syncfit://coach-checkout-success?session_id=one&session_id=two",
            "syncfit://coach-checkout-success?session_id=one#fragment",
            "syncfit://user@coach-checkout-success?session_id=one",
            "syncfit://user:password@coach-checkout-success?session_id=one",
            "syncfit://coach-checkout-success:443?session_id=one",
            "syncfit://coach-checkout-success/path?session_id=one",
            "syncfit://wrong-host?session_id=one",
            "https://coach-checkout-success?session_id=one",
        ]

        invalidURLs.forEach { XCTAssertEqual(result($0), .invalid, $0) }
    }

    func testRejectsMalformedCancelCallbacks() {
        let invalidURLs = [
            "syncfit://coach-checkout-cancel?",
            "syncfit://coach-checkout-cancel?session_id=one",
            "syncfit://coach-checkout-cancel#fragment",
            "syncfit://user@coach-checkout-cancel",
            "syncfit://user:password@coach-checkout-cancel",
            "syncfit://coach-checkout-cancel:443",
            "syncfit://coach-checkout-cancel/path",
            "syncfit://wrong-host",
            "https://coach-checkout-cancel",
        ]

        invalidURLs.forEach { XCTAssertEqual(result($0), .invalid, $0) }
    }

    private func result(_ rawURL: String) -> CoachCheckoutCallbackResult {
        CoachCheckoutCallbackValidator.result(for: URL(string: rawURL)!)
    }
}
