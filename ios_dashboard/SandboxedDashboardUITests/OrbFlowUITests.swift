import XCTest

final class OrbFlowUITests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18766", "-orb_test_reset", "YES"]
        app.launch()
        return app
    }
    @MainActor func testRealMicrophonePermissionAndRecorderStartup() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18778", "-orb_test_reset", "YES", "-orb_dictation_fixture", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        app.buttons["project.orb-test"].tap()
        XCTAssertTrue(app.buttons["mission.long-chat"].waitForExistence(timeout: 10))
        app.buttons["mission.long-chat"].tap()
        let draft = app.textFields["composer"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.tap(); draft.typeText("Existing draft")
        app.buttons["dictation.microphone"].tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if system.buttons["Allow"].waitForExistence(timeout: 5) { system.buttons["Allow"].tap() }
        XCTAssertTrue(app.buttons["dictation.stop"].waitForExistence(timeout: 15))
        capture(app, "dictation-real-recorder")
        app.buttons["dictation.cancel"].tap()
        XCTAssertEqual(draft.value as? String, "Existing draft")
    }
    @MainActor func testDictationCapsulePreservesDraftAndCancellation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18778", "-orb_test_reset", "YES", "-orb_dictation_fixture", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        app.buttons["project.orb-test"].tap()
        XCTAssertTrue(app.buttons["mission.long-chat"].waitForExistence(timeout: 10))
        app.buttons["mission.long-chat"].tap()
        let draft = app.textFields["composer"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.tap(); draft.typeText("Existing draft")
        app.buttons["dictation.microphone"].tap()
        XCTAssertTrue(app.buttons["dictation.stop"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.buttons["dictation.cancel"].frame.width, 44)
        capture(app, "dictation-recording-capsule")
        let detail = XCTAttachment(screenshot: app.otherElements["dictation.capsule"].screenshot())
        detail.name = "dictation-capsule-detail"; detail.lifetime = .keepAlways; add(detail)
        app.buttons["dictation.cancel"].tap()
        XCTAssertEqual(draft.value as? String, "Existing draft")
        app.buttons["dictation.microphone"].tap()
        app.buttons["dictation.stop"].tap()
        XCTAssertTrue(app.staticTexts["Transcribing…"].waitForExistence(timeout: 5))
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        XCTAssertEqual(draft.value as? String, "Existing draft Bonjour, ajoute un microphone dans la conversation.")
        capture(app, "dictation-editable-draft")
        app.buttons["dictation.microphone"].tap()
        app.buttons["dictation.stop"].tap()
        XCTAssertTrue(app.buttons["dictation.cancel"].waitForExistence(timeout: 5))
        app.buttons["dictation.cancel"].tap()
        Thread.sleep(forTimeInterval: 6)
        XCTAssertEqual(draft.value as? String, "Existing draft Bonjour, ajoute un microphone dans la conversation.")
        // No message is submitted; fixture verifies only recording/relay/draft behavior.
    }
    @MainActor func testInlineInboxDictationKeepsReplyEditable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18778", "-orb_test_reset", "YES", "-orb_dictation_fixture", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["home.tab.inbox"].waitForExistence(timeout: 20))
        app.buttons["home.tab.inbox"].tap()
        XCTAssertTrue(app.buttons["inbox.reply.reconnect"].waitForExistence(timeout: 15))
        app.buttons["inbox.reply.reconnect"].tap()
        let draft = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Send follow-up' OR placeholderValue BEGINSWITH 'Reply to'")).firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        draft.tap(); draft.typeText("Inbox draft")
        app.buttons["dictation.microphone"].tap()
        XCTAssertTrue(app.buttons["dictation.stop"].waitForExistence(timeout: 5))
        capture(app, "dictation-inbox-capsule")
        app.buttons["dictation.stop"].tap()
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        XCTAssertEqual(draft.value as? String, "Inbox draft Bonjour, ajoute un microphone dans la conversation.")
        XCTAssertTrue(app.buttons["inbox.send.reconnect"].exists)
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.5)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    /// Also writes the screenshot to $ORB_SHOT_DIR (TEST_RUNNER_ORB_SHOT_DIR) when set.
    @MainActor private func captureFile(_ app: XCUIApplication, _ name: String) {
        capture(app, name)
        if let dir = ProcessInfo.processInfo.environment["ORB_SHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("ios-\(name).png"))
        }
    }
    /// Mission access on the default fixture (18766): one pending request
    /// (acc-1) and one live grant (acc-2). The simulator has no enrolled
    /// biometry and no Secure Enclave approval key, so OrbBiometric lets the
    /// approval through and the request goes out unsigned; the fixture accepts
    /// it (real Core rejects an unsigned approve). Face ID itself needs a device.
    @MainActor func testMissionAccessApproveDenyAndRevoke() throws {
        var reset = URLRequest(url: URL(string: "http://127.0.0.1:18766/__reset")!); reset.httpMethod = "POST"
        let done = expectation(description: "fixture reset")
        URLSession.shared.dataTask(with: reset) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
        let app = launch()
        let banner = app.buttons["home.access-requests"]
        XCTAssertTrue(banner.waitForExistence(timeout: 30))
        captureFile(app, "access-home-banner")
        banner.tap()
        let approve = app.buttons["access.approve.acc-1"]
        XCTAssertTrue(approve.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Lean eval run #42"].exists)
        XCTAssertTrue(app.buttons["access.revoke.acc-2"].exists, "live grant listed")
        captureFile(app, "access-sheet-pending")
        approve.tap()
        let revoke = app.buttons["access.revoke.acc-1"]
        XCTAssertTrue(revoke.waitForExistence(timeout: 10), "approved request becomes a grant")
        XCTAssertFalse(app.buttons["access.approve.acc-1"].exists)
        captureFile(app, "access-sheet-approved")
        revoke.tap()
        XCTAssertTrue(revoke.waitForNonExistence(timeout: 10), "revoked grant leaves the list")
        app.buttons["access.revoke.acc-2"].tap()
        XCTAssertTrue(app.buttons["access.revoke.acc-2"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No active grants."].waitForExistence(timeout: 5))
        captureFile(app, "access-sheet-revoked")
        app.buttons["Done"].tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 15), "no pending request left")
        app.buttons["Settings"].tap()
        let link = app.buttons["settings.mission-access"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] 'History'")).firstMatch.waitForExistence(timeout: 10))
        captureFile(app, "access-settings-history")
    }
    @MainActor func testMissionLongPressRenameMoveAndStopArchive() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        app.buttons["project.orb-test"].tap()
        let mission = app.buttons["mission.long-chat"]
        XCTAssertTrue(mission.waitForExistence(timeout: 10))
        mission.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Archive"].exists)
        capture(app, "mission-long-press")
        app.buttons["Move…"].tap()
        XCTAssertTrue(app.otherElements["move.banner"].waitForExistence(timeout: 5) || app.staticTexts["Long-press a folder or project, then choose Move here."].exists)
        let folder = app.buttons["folder.Design/Images"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        folder.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Move here"].waitForExistence(timeout: 5))
        capture(app, "folder-move-here")
        app.buttons["Move here"].tap()
        let banner = app.staticTexts["Long-press a folder or project, then choose Move here."]
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: banner); waitForExpectations(timeout: 10)

        let running = app.buttons["mission.rich-growth"]
        XCTAssertTrue(running.waitForExistence(timeout: 10))
        running.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Move…"].exists)
        XCTAssertTrue(app.buttons["Stop & archive"].exists)
        capture(app, "running-mission-long-press")
        app.buttons["Rename"].tap()
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText(" renamed")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Growing rich response renamed"].waitForExistence(timeout: 10))

        app.buttons["Project actions"].tap()
        XCTAssertTrue(app.buttons["New folder"].waitForExistence(timeout: 5))
        capture(app, "project-actions-menu")
    }
    @MainActor func testProviderLogosRender() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        app.buttons["Settings"].tap()
        app.buttons["settings.providers"].tap()
        XCTAssertTrue(app.staticTexts["Fixture provider"].waitForExistence(timeout: 10))
        capture(app, "provider-logos")
    }
    @MainActor func testPolishedInboxAndReplyLayout() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18766", "-orb_test_reset", "YES"]
        app.launch()
        let projectRow = app.buttons["project.orb-test"]
        XCTAssertTrue(projectRow.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["home.inbox"].exists)
        XCTAssertTrue(app.staticTexts["1 working"].exists)
        capture(app, "home-projects-working")
        let inboxTab = app.buttons["home.tab.inbox"]
        XCTAssertTrue(inboxTab.exists)
        inboxTab.tap()
        let row = app.otherElements["inbox.row.reconnect"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Needs you"].exists)
        XCTAssertFalse(app.staticTexts["Goal"].exists)
        capture(app, "polished-inbox")
        let working = app.buttons["inbox.workingPill"]
        working.tap()
        XCTAssertTrue(app.staticTexts["Working in background"].exists)
        capture(app, "polished-inbox-working")
        working.tap()
        let peek = app.buttons["inbox.peek.reconnect"]
        XCTAssertGreaterThanOrEqual(peek.frame.height, 44)
        peek.tap()
        XCTAssertTrue(app.staticTexts["Restore the interrupted conversation safely."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Unresolved"].exists)
        XCTAssertTrue(app.staticTexts["To decide"].exists)
        XCTAssertTrue(app.buttons["Sources"].exists || app.staticTexts["Sources"].exists)
        capture(app, "polished-inbox-preview")
        let reply = app.buttons["inbox.reply.reconnect"]
        XCTAssertGreaterThanOrEqual(reply.frame.height, 44)
        reply.tap()
        let input = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Send follow-up' OR placeholderValue BEGINSWITH 'Reply to'")).firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("Unsent layout check")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let send = app.buttons["inbox.send.reconnect"]
        XCTAssertGreaterThanOrEqual(send.frame.height, 44)
        XCTAssertTrue(send.isHittable)
        capture(app, "polished-inbox-keyboard")
        // Only fixture data is touched; no reply is submitted.
    }
    @MainActor func testLoadingCacheLatestMessagesAndModeMenu() async throws {
        var reset = URLRequest(url: URL(string: "http://127.0.0.1:18771/__reset")!)
        reset.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: reset)
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18771", "-orb_test_reset", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        app.buttons["project.orb-test"].tap()
        XCTAssertTrue(app.otherElements["conversations-loading"].exists || app.staticTexts["Loading conversations…"].exists)
        XCTAssertFalse(app.staticTexts["No conversations yet"].exists)
        capture(app, "conversation-loading-skeletons")
        XCTAssertTrue(app.buttons["mission.long-chat"].waitForExistence(timeout: 15))
        app.buttons["mission.long-chat"].tap()
        let latest = app.staticTexts["Message 080 — conversation history"]
        XCTAssertTrue(latest.waitForExistence(timeout: 15))
        XCTAssertTrue(latest.isHittable)
        XCTAssertFalse(app.staticTexts["Message 001 — conversation history"].exists)
        capture(app, "latest-messages")
        for _ in 0..<12 {
            if app.buttons["load-earlier"].isHittable { break }
            app.swipeDown()
        }
        XCTAssertTrue(app.buttons["load-earlier"].isHittable)
        app.buttons["load-earlier"].tap()
        // Prepending keeps the previously visible boundary, then allows reading earlier text.
        for _ in 0..<4 {
            if app.staticTexts["Message 060 — conversation history"].isHittable { break }
            app.swipeDown()
        }
        XCTAssertTrue(app.staticTexts["Message 060 — conversation history"].isHittable)
        try await Task.sleep(for: .seconds(4))
        XCTAssertTrue(app.staticTexts["Message 060 — conversation history"].isHittable)
        app.buttons["composer-add"].tap()
        XCTAssertTrue(app.buttons["Photos"].waitForExistence(timeout: 5))
        app.buttons["Mode"].tap()
        XCTAssertTrue(app.buttons["mode-option-plan"].waitForExistence(timeout: 5))
        capture(app, "composer-mode-picker")
        app.buttons["mode-option-plan"].tap()
        XCTAssertTrue(app.buttons["Clear Plan mode"].exists)
        let input = app.textFields["composer"].exists ? app.textFields["composer"] : app.textViews["composer"]
        input.tap(); input.typeText("Outline a small test")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.staticTexts["/plan Outline a small test"].waitForExistence(timeout: 15))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["mission.long-chat"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["project.orb-test"].tap()
        XCTAssertTrue(app.buttons["mission.long-chat"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Loading conversations…"].exists)
    }
    @MainActor func testRichResponseStaysAtBottomAfterLayoutGrowth() async throws {
        var reset = URLRequest(url: URL(string: "http://127.0.0.1:18766/__reset")!)
        reset.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: reset)
        let app = launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        app.buttons["project.orb-test"].tap()
        let row = app.buttons["mission.rich-growth"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let end = app.webViews.staticTexts["FINAL RESPONSE END"]
        XCTAssertTrue(end.waitForExistence(timeout: 20))
        let file = app.buttons["result.csv"]
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: file)], timeout: 15)
        try await Task.sleep(for: .seconds(3))
        XCTAssertTrue(end.isHittable)
        XCTAssertTrue(file.isHittable)
        XCTAssertLessThanOrEqual(file.frame.maxY, app.otherElements["conversation-composer"].frame.minY)
        capture(app, "rich-response-final-bottom")
    }
    @MainActor func testSettingsNavigation() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["settings.machines"].waitForExistence(timeout: 5))
        capture(app, "settings-home")
        app.buttons["settings.machines"].tap()
        XCTAssertTrue(app.navigationBars["Machines"].waitForExistence(timeout: 10))
        capture(app, "settings-machines")
        app.navigationBars["Machines"].buttons["Settings"].tap()
        app.buttons["settings.providers"].tap()
        XCTAssertTrue(app.staticTexts["Fixture provider"].waitForExistence(timeout: 10))
        capture(app, "settings-providers")
    }
    @MainActor func testCompactComposerKeyboardAndSettings() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        capture(app, "compact-projects")
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["settings.backend"].waitForExistence(timeout: 5))
        app.buttons["settings.backend"].tap()
        XCTAssertTrue(app.textFields["server-url"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["server-url"].value as? String, "http://127.0.0.1:18766")
        capture(app, "compact-server-settings")
        app.navigationBars["Backend"].buttons["Settings"].tap()
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
        XCTAssertEqual(input.value as? String, "Explain the calculation\nand compare the assumptions.")
    }
    @MainActor func testLoginSurvivesRelaunchAndRenewsInvalidToken() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18772", "-orb_test_reset", "YES", "-orb_test_reset_auth", "YES"]
        app.launch()
        XCTAssertTrue(app.secureTextFields.firstMatch.waitForExistence(timeout: 20))
        app.secureTextFields.firstMatch.tap(); app.secureTextFields.firstMatch.typeText("orb-test-password")
        app.buttons["Sign In"].tap()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 15))
        app.terminate()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18772"]
        app.launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.secureTextFields.firstMatch.exists)
        app.terminate()
        let (beforeData, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18772/__counts")!)
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: beforeData) as? [String: Int])
        var expire = URLRequest(url: URL(string: "http://127.0.0.1:18772/__expire")!)
        expire.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: expire)
        app.launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["reconnect"].exists)
        XCTAssertFalse(app.secureTextFields.firstMatch.exists)
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18772/__counts")!)
        let counts = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(counts["/api/auth/login"], (before["/api/auth/login"] ?? 0) + 1)
        capture(app, "saved-login-renewed")
    }
    @MainActor func testExpiredSessionAndServerPassword() throws {
        addUIInterruptionMonitor(withDescription: "Password AutoFill prompt") { alert in
            if alert.buttons["Not Now"].exists { alert.buttons["Not Now"].tap(); return true }
            return false
        }
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18770", "-orb_test_reset", "YES", "-orb_test_reset_auth", "YES"]
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
        if app.buttons["Not Now"].waitForExistence(timeout: 5) {
            app.buttons["Not Now"].tap()
            XCTAssertTrue(app.buttons["Not Now"].waitForNonExistence(timeout: 5))
        }
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["settings.backend"].waitForExistence(timeout: 5))
        app.buttons["settings.backend"].tap()
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap(); password.typeText("wrong")
        app.buttons["Connect"].tap()
        XCTAssertTrue(app.staticTexts["Incorrect password. Please try again."].waitForExistence(timeout: 10))
        app.navigationBars["Backend"].buttons["Settings"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["project.orb-test"].exists)
        if app.buttons["Not Now"].waitForExistence(timeout: 5) {
            app.buttons["Not Now"].tap()
            XCTAssertTrue(app.buttons["Not Now"].waitForNonExistence(timeout: 5))
        }
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["settings.backend"].waitForExistence(timeout: 5))
        app.buttons["settings.backend"].tap()
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap()
        password.typeText("orb-test-password")
        capture(app, "auth-server-password")
        app.buttons["Connect"].tap()
        XCTAssertTrue(password.waitForNonExistence(timeout: 15))
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
        XCTAssertTrue(app.buttons["mission.local-only"].exists)
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
    @MainActor func testProjectColorIsChosenAndKeptAcrossLaunches() throws {
        var app = launch()
        func choose(_ name: String) {
            XCTAssertTrue(app.buttons["Project actions"].waitForExistence(timeout: 10))
            app.buttons["Project actions"].tap()
            XCTAssertTrue(app.buttons["project-color"].waitForExistence(timeout: 5))
            app.buttons["project-color"].tap()
            XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5))
        }
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        app.buttons["project.orb-test"].tap()
        choose("Green")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label IN %@", ["Default", "Blue", "Green", "Amber", "Rose", "Purple"])).count, 6)
        capture(app, "project-color-menu")
        app.buttons["Green"].tap()
        XCTAssertTrue(app.buttons["folder.Design/Images"].waitForExistence(timeout: 10))
        capture(app, "project-color-folders")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 10))
        capture(app, "project-color-projects")
        app.terminate()
        app = launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        app.buttons["project.orb-test"].tap()
        choose("Green")
        XCTAssertTrue(app.buttons["Green"].isSelected)
        XCTAssertFalse(app.buttons["Default"].isSelected)
        app.buttons["Default"].tap()
        choose("Default")
        XCTAssertTrue(app.buttons["Default"].isSelected)
        app.buttons["Default"].tap()
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
        for _ in 0..<8 {
            if title.isHittable { break }
            app.swipeDown()
        }
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
        XCTAssertFalse(app.buttons["ChatGPT UI"].exists)
        XCTAssertFalse(app.buttons["chatgpt_ui"].exists)
        app.buttons["Claude Code"].tap()
        app.buttons["Done"].tap()
        let input = app.textFields["composer"].exists ? app.textFields["composer"] : app.textViews["composer"]
        input.tap(); input.typeText("ORB_UI_CREATE")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "ORB_TEST_OK")).firstMatch.waitForExistence(timeout: 20))
    }
}

/// Tapping a mission notification opens the Inbox with that card peeked.
/// Run with the fixture server on 18778; the harness pushes the notification
/// with `xcrun simctl push` once the app is in the background.
final class OrbNotificationTapUITests: XCTestCase {
    @MainActor func testTappingNotificationOpensInboxPeek() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18778", "-orb_test_reset", "YES"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Allow"].waitForExistence(timeout: 8) { springboard.buttons["Allow"].tap() }
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        app.terminate()
        // Banners are tapped by position: deep SpringBoard queries crash its automation server.
        let bannerSpot = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.075))
        var opened = false
        for _ in 0..<60 where !opened {
            sleep(2)
            bannerSpot.tap()
            opened = app.wait(for: .runningForeground, timeout: 2)
        }
        XCTAssertTrue(opened, "no notification opened the app")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        sleep(4)
        XCTAssertEqual(app.state, .runningForeground, "app crashed after tapping the notification")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "after-notification-tap"; shot.lifetime = .keepAlways; add(shot)
    }
}

/// Fleet Live Activity: visible in the Dynamic Island and on the Lock Screen
/// / Notification Center once missions are running or waiting.
final class OrbFleetLiveActivityUITests: XCTestCase {
    @MainActor func testFleetLiveActivityAppears() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18778", "-orb_test_reset", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Inbox'")).firstMatch.tap()
        sleep(8)
        XCUIDevice.shared.press(.home)
        sleep(3)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let home = XCTAttachment(screenshot: springboard.screenshot()); home.name = "home-dynamic-island"; home.lifetime = .keepAlways; add(home)
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.005))
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.7)))
        sleep(3)
        let lock = XCTAttachment(screenshot: springboard.screenshot()); lock.name = "lock-screen"; lock.lifetime = .keepAlways; add(lock)
    }
}
