import XCTest

/// Drives the real Settings two-step delete confirmation in Simulator
/// (Delete Account → Continue → Delete permanently) against a pre-seeded throwaway account.
final class DeleteAccountManualFlowUITests: XCTestCase {
    private let stepLogURL = URL(fileURLWithPath: "/tmp/syncfit-ui-delete-steps.log")
    private let credsURL = URL(fileURLWithPath: "/tmp/syncfit-ui-delete-creds.json")

    override func setUpWithError() throws {
        continueAfterFailure = false
        try? FileManager.default.removeItem(at: stepLogURL)
        logStep("TEST_START")
    }

    func testDeleteAccountTwoStepConfirmationWipesAndLogsOut() throws {
        let creds = try loadCreds()
        logStep("CREDS_LOADED email=\(creds.email) uid=\(creds.uid)")

        let app = XCUIApplication()
        app.launchArguments += ["-UITesting"]
        app.launch()
        logStep("APP_LAUNCHED")

        // Auth screen
        let emailField = app.textFields["authEmailField"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 30), "Auth email field missing")
        emailField.tap()
        emailField.typeText(creds.email)

        let passwordField = app.secureTextFields["authPasswordField"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5), "Auth password field missing")
        passwordField.tap()
        passwordField.typeText(creds.password)
        logStep("TYPED_CREDENTIALS")

        let signIn = app.buttons["authSubmitButton"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        signIn.tap()
        logStep("TAPPED_SIGN_IN")

        // Home tab after cloud restore (onboarding + program setup pre-seeded)
        let homeTab = app.tabBars.buttons["Home"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 60), "Did not reach MainTabView / Home")
        homeTab.tap()
        logStep("REACHED_HOME")

        let profileButton = app.buttons["homeProfileButton"]
        XCTAssertTrue(profileButton.waitForExistence(timeout: 20), "Profile button missing")
        profileButton.tap()
        logStep("OPENED_PROFILE")

        let settingsButton = app.buttons["profileSettingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 20), "Settings row missing")
        settingsButton.tap()
        logStep("OPENED_SETTINGS")

        let deleteAccount = app.buttons["deleteAccountButton"]
        XCTAssertTrue(deleteAccount.waitForExistence(timeout: 20), "Delete Account button missing")
        // Scroll into view if needed
        if !deleteAccount.isHittable {
            app.swipeUp()
        }
        deleteAccount.tap()
        logStep("TAPPED_DELETE_ACCOUNT")

        // First confirmation sheet
        let continueButton = app.sheets.buttons["Continue"].firstMatch
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10), "Continue confirmation missing")
        XCTAssertTrue(app.staticTexts["Delete your account?"].waitForExistence(timeout: 5))
        continueButton.tap()
        logStep("TAPPED_CONTINUE")

        // Final confirmation sheet
        let deletePermanently = app.sheets.buttons["Delete permanently"].firstMatch
        XCTAssertTrue(deletePermanently.waitForExistence(timeout: 10), "Delete permanently confirmation missing")
        XCTAssertTrue(app.staticTexts["Delete permanently?"].waitForExistence(timeout: 5))
        deletePermanently.tap()
        logStep("TAPPED_DELETE_PERMANENTLY")

        // Should return to Auth (logged out) without error alert
        let errorAlert = app.alerts["Couldn't delete account"]
        let backOnAuth = emailField.waitForExistence(timeout: 90)
        if errorAlert.exists {
            let body = errorAlert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
            logStep("ERROR_ALERT \(body)")
            XCTFail("Delete failed with alert: \(body)")
        }
        XCTAssertTrue(backOnAuth, "Did not return to Auth / Sign In after deletion")
        XCTAssertFalse(homeTab.exists, "Home tab still present — residual logged-in UI")
        logStep("LOGGED_OUT_AUTH_VISIBLE")

        // Write marker for post-query script
        try "UI_DELETE_FLOW_OK uid=\(creds.uid)".write(
            to: URL(fileURLWithPath: "/tmp/syncfit-ui-delete-flow-ok.txt"),
            atomically: true,
            encoding: .utf8
        )
        logStep("TEST_PASS")
    }

    private struct Creds: Decodable {
        let email: String
        let password: String
        let uid: String
    }

    private func loadCreds() throws -> Creds {
        let data = try Data(contentsOf: credsURL)
        return try JSONDecoder().decode(Creds.self, from: data)
    }

    private func logStep(_ message: String) {
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
        print("[UIDelete] \(message)")
    }
}
