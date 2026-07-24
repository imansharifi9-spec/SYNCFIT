import XCTest
@testable import SyncFit
import FirebaseFunctions

final class DeleteAccountErrorMapperTests: XCTestCase {
    func testFailedPreconditionMapsToActiveClientSubscriptionsMessage() {
        let error = NSError(
            domain: FunctionsErrorDomain,
            code: FunctionsErrorCode.failedPrecondition.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Active client subscriptions remain."]
        )

        XCTAssertEqual(
            DeleteAccountErrorMapper.displayMessage(for: error),
            DeleteAccountErrorMapper.activeClientSubscriptionsMessage
        )
        XCTAssertTrue(DeleteAccountErrorMapper.isActiveClientSubscriptionBlock(error))
    }

    func testOtherFunctionsErrorUsesServerMessage() {
        let serverMessage = "Sign in required."
        let error = NSError(
            domain: FunctionsErrorDomain,
            code: FunctionsErrorCode.unauthenticated.rawValue,
            userInfo: [NSLocalizedDescriptionKey: serverMessage]
        )

        XCTAssertEqual(DeleteAccountErrorMapper.displayMessage(for: error), serverMessage)
        XCTAssertFalse(DeleteAccountErrorMapper.isActiveClientSubscriptionBlock(error))
    }

    func testGenericErrorFallsBackToLocalizedDescription() {
        let error = NSError(
            domain: "TestDomain",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Network offline"]
        )

        XCTAssertEqual(DeleteAccountErrorMapper.displayMessage(for: error), "Network offline")
    }
}
