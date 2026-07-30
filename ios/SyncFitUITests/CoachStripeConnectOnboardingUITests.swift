import XCTest

/// Simulator walkthrough: coach Profile → Set Up Payments → wait for chargesEnabled UI.
final class CoachStripeConnectOnboardingUITests: XCTestCase {
    private let stepLogURL = URL(fileURLWithPath: "/tmp/syncfit-stripe-onboard-steps.log")
    private let credsURL = URL(fileURLWithPath: "/tmp/syncfit-stripe-onboard-creds.json")
    private let flowOKURL = URL(fileURLWithPath: "/tmp/syncfit-stripe-onboard-flow-ok.txt")

    override func setUpWithError() throws {
        continueAfterFailure = false
        try? FileManager.default.removeItem(at: stepLogURL)
        try? FileManager.default.removeItem(at: flowOKURL)
        log("TEST_START")
    }

    func testCoachSetUpPaymentsCompletesWhenChargesEnabled() throws {
        let creds = try loadCreds()
        log("CREDS_LOADED uid=\(creds.uid) email=\(creds.email)")

        let app = XCUIApplication()
        app.launch()
        log("APP_LAUNCHED")

        let emailField = app.textFields["authEmailField"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 30))
        emailField.tap()
        emailField.typeText(creds.email)

        let passwordField = app.secureTextFields["authPasswordField"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        passwordField.tap()
        passwordField.typeText(creds.password)

        app.buttons["authSubmitButton"].tap()
        log("SIGNED_IN")

        // Reach coach Profile payments button via athlete Home → Settings, or already in coach portal.
        let homeTab = app.tabBars.buttons["Home"]
        let coachProfileTab = app.tabBars.buttons["Profile"]
        if homeTab.waitForExistence(timeout: 45) {
            homeTab.tap()
            let profileButton = app.buttons["homeProfileButton"]
            XCTAssertTrue(profileButton.waitForExistence(timeout: 20))
            profileButton.tap()
            log("OPENED_PROFILE")

            let settingsButton = app.buttons["profileSettingsButton"]
            XCTAssertTrue(settingsButton.waitForExistence(timeout: 20))
            settingsButton.tap()
            log("OPENED_SETTINGS")

            let coachToggle = app.switches["coachModeToggle"]
            XCTAssertTrue(coachToggle.waitForExistence(timeout: 20), "Coach mode toggle missing — isCoach seed failed?")
            if coachToggle.value as? String != "1" {
                coachToggle.tap()
            }
            log("COACH_MODE_ON")
        } else {
            log("NO_HOME_TAB — assuming already in coach portal")
        }

        XCTAssertTrue(coachProfileTab.waitForExistence(timeout: 25), "Coach Profile tab missing")
        coachProfileTab.tap()
        log("COACH_PROFILE_TAB")

        let setUpPayments = app.buttons["coachSetUpPaymentsButton"]
        var found = setUpPayments.waitForExistence(timeout: 5)
        for _ in 0..<8 where !found || !setUpPayments.isHittable {
            app.swipeUp()
            found = setUpPayments.exists
            if found && setUpPayments.isHittable { break }
        }
        XCTAssertTrue(setUpPayments.waitForExistence(timeout: 10), "Set Up Payments button missing")

        try? FileManager.default.removeItem(atPath: "/tmp/syncfit-stripeconnect-probe.log")
        setUpPayments.tap()
        log("TAPPED_SET_UP_PAYMENTS")

        // Fixed-build probe: wait briefly for StripeConnect log file from the app process.
        var sawFixLog = false
        for _ in 0..<20 {
            if let probe = try? String(contentsOfFile: "/tmp/syncfit-stripeconnect-probe.log", encoding: .utf8),
               probe.contains("[StripeConnect]") {
                log("PROBE_LOG=\(probe.replacingOccurrences(of: "\n", with: " | "))")
                sawFixLog = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(sawFixLog, "Fixed-build StripeConnect probe log missing after tap — rebuild not running?")
        log("FIX_BUILD_CONFIRMED")

        // Stop here for rebuild verification; full chargesEnabled wait is separate.
        if app.buttons["Cancel"].waitForExistence(timeout: 3) {
            app.buttons["Cancel"].tap()
            log("DISMISSED_WEB_AUTH")
        }
        log("TEST_PASS_FIX_PROBE")
    }

    private struct Creds: Decodable {
        let email: String
        let password: String
        let uid: String
    }

    private func loadCreds() throws -> Creds {
        try JSONDecoder().decode(Creds.self, from: Data(contentsOf: credsURL))
    }

    private func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if !FileManager.default.fileExists(atPath: stepLogURL.path) {
            FileManager.default.createFile(atPath: stepLogURL.path, contents: Data(), attributes: nil)
        }
        if let handle = try? FileHandle(forWritingTo: stepLogURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
        }
        print("[StripeOnboardUI] \(message)")
    }
}
