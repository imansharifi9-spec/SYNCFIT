import XCTest
import SwiftData
@testable import SyncFit

@MainActor
final class CoachCheckoutConfirmationTests: XCTestCase {
    override func tearDown() {
        CoachCheckoutConfirmationTiming.forceImmediateTimeout = false
        super.tearDown()
    }

    func testImmediateTimeoutDebugFlagUsesZeroDelay() {
        CoachCheckoutConfirmationTiming.forceImmediateTimeout = false
        XCTAssertEqual(
            CoachCheckoutConfirmationTiming.timeoutNanoseconds,
            CoachCheckoutConfirmationTiming.standardTimeoutNanoseconds
        )

        CoachCheckoutConfirmationTiming.forceImmediateTimeout = true
        XCTAssertEqual(CoachCheckoutConfirmationTiming.timeoutNanoseconds, 0)
    }

    func testConfirmationCopyMatchesHireUI() {
        XCTAssertEqual(
            CoachCheckoutConfirmationCopy.confirmingTitle,
            "Confirming your subscription..."
        )
        XCTAssertEqual(
            CoachCheckoutConfirmationCopy.timeoutMessage,
            "Still confirming — this can take a moment. Check back shortly."
        )
        XCTAssertEqual(CoachCheckoutConfirmationCopy.refreshTitle, "Refresh")
        XCTAssertEqual(
            CoachCheckoutConfirmationCopy.canceledMessage,
            "Checkout was canceled"
        )
    }

    func testDebugTimeoutFallbackReachesTimedOutStateWithoutWaiting15Seconds() async {
        let service = makeService()
        let coachUID = "coach_debug_timeout"

        service.debugSimulateConfirmationTimeoutFallback(coachUID: coachUID)

        XCTAssertEqual(service.hireCheckoutCoachUID, coachUID)
        XCTAssertEqual(service.hireCheckoutState, .confirming)

        let expectation = expectation(description: "confirmation timed out")
        for _ in 0..<40 {
            if service.hireCheckoutState == .confirmationTimedOut {
                expectation.fulfill()
                break
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(service.hireCheckoutState, .confirmationTimedOut)
        XCTAssertEqual(
            CoachCheckoutConfirmationCopy.timeoutMessage,
            "Still confirming — this can take a moment. Check back shortly."
        )
    }

    func testDebugSuccessPathEntersConfirmedStateFromConfirming() async {
        let service = makeService()
        let coachUID = "coach_debug_success"

        await service.debugSimulateConfirmationSuccess(coachUID: coachUID)

        XCTAssertEqual(service.hireCheckoutCoachUID, coachUID)
        XCTAssertEqual(service.hireCheckoutState, .confirmed)
    }

    private func makeService() -> CoachService {
        let container = try! SyncFitModelContainer.make(inMemory: true)
        return CoachService(context: ModelContext(container))
    }
}
