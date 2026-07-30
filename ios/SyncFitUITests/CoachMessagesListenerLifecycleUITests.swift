import XCTest

/// Repro from BUG 2 diagnosis: Messages list / thread must show Firestore data
/// after tab navigation without needing a new incoming message.
final class CoachMessagesListenerLifecycleUITests: XCTestCase {
    private let logURL = URL(fileURLWithPath: "/tmp/syncfit-messages-listener-repro-after.log")

    override func setUpWithError() throws {
        continueAfterFailure = true
        try? FileManager.default.removeItem(at: logURL)
        log("TEST_START")
    }

    func testMessagesPersistAfterTabSwitchAwayAndBack() throws {
        let app = XCUIApplication()
        app.launch()
        log("APP_LAUNCHED")

        let messagesTab = app.tabBars.buttons["Messages"]
        let homeTab = app.tabBars.buttons["Home"]
        if !messagesTab.waitForExistence(timeout: 8), homeTab.waitForExistence(timeout: 5) {
            log("IN_ATHLETE_MODE — enabling coach mode via Settings")
            homeTab.tap()
            let profileButton = app.buttons["homeProfileButton"]
            XCTAssertTrue(profileButton.waitForExistence(timeout: 15))
            profileButton.tap()
            let settingsButton = app.buttons["profileSettingsButton"]
            XCTAssertTrue(settingsButton.waitForExistence(timeout: 15))
            settingsButton.tap()
            let coachToggle = app.switches["coachModeToggle"]
            XCTAssertTrue(coachToggle.waitForExistence(timeout: 15))
            if (coachToggle.value as? String) != "1" {
                coachToggle.tap()
            }
        }

        XCTAssertTrue(messagesTab.waitForExistence(timeout: 25), "Messages tab missing")
        messagesTab.tap()
        log("OPENED_MESSAGES_TAB")
        // Allow Auth-backed conversations listener to populate.
        var sawConversation = false
        for _ in 0..<15 {
            Thread.sleep(forTimeInterval: 1.0)
            if app.staticTexts["Iman"].exists
                || app.staticTexts["Hey!"].exists
                || app.staticTexts["Client"].exists
                || app.staticTexts["SyncFit"].exists {
                sawConversation = true
                break
            }
        }
        attachScreenshot(app, name: "after-01-messages-list")
        log("LIST_HAS_CONVERSATION=\(sawConversation) emptyPlaceholder=\(app.staticTexts["No messages yet."].exists)")

        if app.staticTexts["Iman"].waitForExistence(timeout: 3) {
            app.staticTexts["Iman"].tap()
            log("OPENED_CONVERSATION iman")
        } else if app.staticTexts["Hey!"].waitForExistence(timeout: 3) {
            app.staticTexts["Hey!"].tap()
            log("OPENED_CONVERSATION Hey!")
        } else if app.staticTexts["Client"].waitForExistence(timeout: 3) {
            app.staticTexts["Client"].tap()
            log("OPENED_CONVERSATION Client")
        } else if app.cells.firstMatch.waitForExistence(timeout: 3) {
            app.cells.firstMatch.tap()
            log("OPENED_CONVERSATION firstCell")
        } else {
            log("FAIL_LIST_STILL_EMPTY")
            attachScreenshot(app, name: "after-01-still-empty")
            XCTFail("Conversations still empty after fix — Auth participant listener did not populate")
            return
        }

        Thread.sleep(forTimeInterval: 2.0)
        attachScreenshot(app, name: "after-02-thread-before-leave")
        let heyBefore = app.staticTexts["Hey!"].waitForExistence(timeout: 10)
        log("BEFORE_LEAVE heyVisible=\(heyBefore)")
        XCTAssertTrue(heyBefore, "Expected Hey! in thread before leaving")

        let profileTab = app.tabBars.buttons["Profile"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 5))
        profileTab.tap()
        log("SWITCHED_TO_PROFILE")
        Thread.sleep(forTimeInterval: 2.0)

        messagesTab.tap()
        log("RETURNED_TO_MESSAGES")
        Thread.sleep(forTimeInterval: 2.5)
        attachScreenshot(app, name: "after-03-thread-after-return")
        let heyAfter = app.staticTexts["Hey!"].waitForExistence(timeout: 8)
        log("AFTER_RETURN heyVisible=\(heyAfter)")

        let clientsTab = app.tabBars.buttons["Clients"]
        if clientsTab.waitForExistence(timeout: 3) {
            clientsTab.tap()
            log("SWITCHED_TO_CLIENTS")
            Thread.sleep(forTimeInterval: 2.0)
            messagesTab.tap()
            log("RETURNED_FROM_CLIENTS")
            Thread.sleep(forTimeInterval: 2.5)
            attachScreenshot(app, name: "after-04-after-clients-roundtrip")
        }
        let heyFinal = app.staticTexts["Hey!"].waitForExistence(timeout: 8)
        log("AFTER_CLIENTS_ROUNDTRIP heyVisible=\(heyFinal)")

        XCUIDevice.shared.press(.home)
        log("BACKGROUNDED")
        Thread.sleep(forTimeInterval: 3.0)
        app.activate()
        log("FOREGROUNDED")
        Thread.sleep(forTimeInterval: 2.5)
        attachScreenshot(app, name: "after-05-after-background")
        let heyBG = app.staticTexts["Hey!"].waitForExistence(timeout: 8)
        log("AFTER_BG_FG heyVisible=\(heyBG)")

        if heyAfter && heyFinal && heyBG {
            log("REPRO_FIXED messages_visible_without_new_write")
        } else {
            log("REPRO_STILL_BROKEN after=\(heyAfter) clients=\(heyFinal) bg=\(heyBG)")
        }
        XCTAssertTrue(heyAfter && heyFinal && heyBG, "Messages must remain visible after lifecycle without a new write")
        log("TEST_DONE")
    }

    private func log(_ line: String) {
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
        print(stamped, terminator: "")
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? shot.pngRepresentation.write(
            to: URL(fileURLWithPath: "/tmp/syncfit-messages-\(name).png")
        )
    }
}
