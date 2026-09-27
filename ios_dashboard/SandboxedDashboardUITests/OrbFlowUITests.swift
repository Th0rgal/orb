import XCTest

final class OrbFlowUITests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18766", "-orb_test_reset", "YES"]
        app.launch()
        return app
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.5)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testCompactComposerKeyboardAndSettings() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        capture(app, "compact-projects")
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.textFields["server-url"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["server-url"].value as? String, "http://127.0.0.1:18766")
        capture(app, "compact-server-settings")
        app.buttons["Done"].tap()
        app.buttons["project.orb-test"].tap()
        capture(app, "compact-project-folders")
        app.buttons["mission.rich-chatgpt"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Rendement annualisé"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["response complete"].exists)
        let composer = app.otherElements["conversation-composer"]
        XCTAssertGreaterThan(composer.frame.height, 60)
        XCTAssertLessThanOrEqual(composer.frame.height, 110)
        XCTContext.runActivity(named: "Idle composer height: \(composer.frame.height) pt") { _ in }
        XCTAssertGreaterThanOrEqual(app.buttons["Send message"].frame.width, 44)
        capture(app, "compact-composer-idle")
        let input = app.textFields["composer"].exists ? app.textFields["composer"] : app.textViews["composer"]
        input.tap(); input.typeText("Explain the calculation\nand compare the assumptions.")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(composer.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
        XCTAssertTrue(app.buttons["Send message"].isHittable)
        capture(app, "compact-composer-keyboard")
        app.buttons["agent-selection"].tap()
        XCTAssertTrue(app.buttons["picker.model"].waitForExistence(timeout: 10))
        capture(app, "compact-agent-settings")
        app.buttons["Done"].tap()
    }
    @MainActor func testExpiredSessionAndServerPassword() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18770", "-orb_test_reset", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["reconnect"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["New project"].exists)
        XCTAssertFalse(app.searchFields.firstMatch.exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "401")).firstMatch.exists)
        capture(app, "auth-reconnect")
        app.buttons["reconnect"].tap()
        let password = app.secureTextFields["server-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap(); password.typeText("wrong")
        app.buttons["Connect"].tap()
        XCTAssertTrue(app.staticTexts["Incorrect password. Please try again."].waitForExistence(timeout: 10))
        password.tap(); password.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "orb-test-password")
        app.buttons["Connect"].tap()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 15))
        app.buttons["Settings"].tap()
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap(); password.typeText("wrong")
        app.buttons["Connect"].tap()
        XCTAssertTrue(app.staticTexts["Incorrect password. Please try again."].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["project.orb-test"].exists)
        app.buttons["Settings"].tap()
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: password)], timeout: 10), .completed)
        password.tap(); password.typeText("orb-test-password")
        capture(app, "auth-server-password")
        app.buttons["Connect"].tap()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 15))
    }
    @MainActor func testCloudReconnectNoticeRemainsVisible() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        app.buttons["project.orb-test"].tap(); app.buttons["mission.reconnect"].tap()
        XCTAssertTrue(app.staticTexts["Reconnect your ChatGPT account in Orb on your Mac."].waitForExistence(timeout: 15))
        let input = app.textFields["composer"].exists ? app.textFields["composer"] : app.textViews["composer"]
        input.tap(); input.typeText("Continue")
        XCTAssertFalse(app.buttons["Send message"].isEnabled)
        capture(app, "compact-reconnect-notice")
    }
    @MainActor func testLoginLayoutWithKeyboard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18769", "-orb_test_reset", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Sign in to Orb"].waitForExistence(timeout: 15))
        let password = app.secureTextFields.firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap(); password.typeText("layout-only")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Sign In"].isHittable)
        capture(app, "compact-login-keyboard")
    }
    @MainActor func testProjectsFoldersConversationAndContext() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        app.buttons["project.orb-test"].tap()
        XCTAssertTrue(app.buttons["folder.Design/Images"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["mission.local-only"].exists)
        app.buttons["mission.existing"].tap()
        XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 10) || app.textViews["composer"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "orb-conversation"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Conversation actions"].tap()
        app.buttons["Project context"].tap()
        XCTAssertTrue(app.buttons["README.md"].waitForExistence(timeout: 10))
        app.buttons["README.md"].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 10))
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.textViews["document-editor"].exists)
        capture(app, "compact-document-editor")
        app.textViews["document-editor"].tap(); app.textViews["document-editor"].typeText("\nUX review")
        app.buttons["Preview"].tap()
        XCTAssertTrue(app.buttons["Save"].exists)
        XCTAssertTrue(app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "UX review")).firstMatch.waitForExistence(timeout: 15))
        capture(app, "compact-document-preview")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 10))
    }
    @MainActor func testRichChatGPTConversationAndReopen() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        app.buttons["project.orb-test"].tap()
        let row = app.buttons["mission.rich-chatgpt"]
        for _ in 0..<12 { if row.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(row.exists); row.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15))
        let title = app.webViews.staticTexts["Rendement annualisé"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "chatgpt-rich-conversation"; shot.lifetime = .keepAlways; add(shot)
        // Rendering stays available after the app process is stopped and restarted.
        app.terminate(); app.launch()
        app.buttons["project.orb-test"].tap()
        for _ in 0..<12 { if row.isHittable { break }; app.swipeUp() }
        row.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        let artifact = app.webViews.buttons["Graphique généré"]
        for _ in 0..<12 {
            if artifact.exists && artifact.frame.midY > 120 && artifact.frame.midY < app.frame.height * 0.70 { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        }
        XCTAssertTrue(artifact.exists); artifact.tap()
        XCTAssertTrue(app.buttons["Close preview"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.images["artifact-image"].waitForExistence(timeout: 15))
        let previewShot = XCTAttachment(screenshot: app.screenshot()); previewShot.name = "chatgpt-image-preview"; previewShot.lifetime = .keepAlways; add(previewShot)
        app.buttons["Close preview"].tap()
        let dataFile = app.webViews.links["Télécharger les données"]
        for _ in 0..<6 {
            if dataFile.exists && dataFile.frame.midY < app.frame.height * 0.70 { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        }
        dataFile.tap()
        XCTAssertTrue(app.staticTexts["artifact-text"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["artifact-text"].label.contains("1999,243"))
        app.buttons["Close preview"].tap()
    }
    @MainActor func testCreateChatGPT() throws { try createCloud("ChatGPT", account: "chatgpt account") }
    @MainActor func testCreateCursorCloud() throws { try createCloud("Cursor Cloud", account: "cursor_cloud account") }
    @MainActor func testCreateGrokBot() throws { try createCloud("Grok Bot", account: "grok_bot account") }
    @MainActor private func createCloud(_ service: String, account: String) throws {
        let app = launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        app.buttons["project.orb-test"].tap(); app.buttons["new-agent"].tap(); app.buttons["agent-selection"].tap()
        app.buttons["picker.service"].tap(); app.buttons[service].tap()
        app.buttons["picker.account"].tap(); app.buttons[account].tap()
        if service == "Cursor Cloud" { app.buttons["picker.repository"].tap(); app.buttons["https://github.com/example/orb-test"].tap(); app.textFields["picker.git-ref"].tap(); app.textFields["picker.git-ref"].typeText("main") }
        app.buttons["Done"].tap()
        let input = app.textFields["composer"].exists ? app.textFields["composer"] : app.textViews["composer"]
        input.tap(); input.typeText("ORB_CLOUD_TEST")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "ORB_TEST_OK")).firstMatch.waitForExistence(timeout: 20))
        input.tap(); input.typeText("Follow up")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "FOLLOWUP_OK")).firstMatch.waitForExistence(timeout: 20))
    }
    @MainActor func testCreateClassicAgent() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        app.buttons["project.orb-test"].tap()
        app.buttons["new-agent"].tap()
        app.buttons["agent-selection"].tap()
        app.buttons["picker.harness"].tap()
        app.buttons["Claude Code"].tap()
        app.buttons["Done"].tap()
        let input = app.textFields["composer"].exists ? app.textFields["composer"] : app.textViews["composer"]
        input.tap(); input.typeText("ORB_UI_CREATE")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "ORB_TEST_OK")).firstMatch.waitForExistence(timeout: 20))
    }
}
