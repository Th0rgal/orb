import XCTest

/// Opt-in operator tests. The restricted localhost bridge owns test credentials.
final class OrbLiveUITests: XCTestCase {
    @MainActor private func create(_ service: String, account: String, model: String? = nil) throws {
        guard ProcessInfo.processInfo.environment["ORB_LIVE_TESTS"] == "1" else { throw XCTSkip("Start the scoped live bridge and explicitly enable ORB_LIVE_TESTS") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18767", "-orb_test_reset", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["project.orb-ios-validation"].waitForExistence(timeout: 30))
        app.buttons["project.orb-ios-validation"].tap(); app.buttons["new-agent"].tap(); app.buttons["agent-selection"].tap()
        app.buttons["picker.service"].tap(); app.buttons[service].tap()
        app.buttons["picker.account"].tap(); app.buttons.matching(identifier: account).allElementsBoundByIndex.last!.tap()
        if service == "Cursor Cloud" {
            app.buttons["picker.repository"].tap()
            let repo = app.buttons["https://github.com/Th0rgal/sandboxed.sh"]
            for _ in 0..<30 { if repo.isHittable { break }; app.swipeUp() }
            repo.tap()
            app.textFields["picker.git-ref"].tap(); app.textFields["picker.git-ref"].typeText("master")
        }
        if let model { app.buttons["picker.model"].tap(); app.buttons[model].tap() }
        app.buttons["Done"].tap()
        let input = app.textFields["composer"].exists ? app.textFields["composer"] : app.textViews["composer"]
        input.tap(); input.typeText("Bounded Orb iOS integration test. Do not use tools, modify files, or create a PR. Reply exactly ORB_IOS_LIVE_OK.")
        app.buttons["Send message"].tap()
        // Require an assistant response, not the echoed user request.
        let response = app.staticTexts["ORB_IOS_LIVE_OK"]
        XCTAssertTrue(response.waitForExistence(timeout: 300))
        input.tap(); input.typeText("Same conversation follow-up. Reply exactly ORB_IOS_FOLLOWUP_OK. No tools or edits.")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.staticTexts["ORB_IOS_FOLLOWUP_OK"].waitForExistence(timeout: 300))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "live-\(service)"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testCursor() throws { try create("Cursor Cloud", account: "Cursor Cloud") }
    @MainActor func testGrok() throws { try create("Grok Bot", account: "Grok Bot") }

    @MainActor func testProductionInboxFlow() throws {
        guard ProcessInfo.processInfo.environment["ORB_INBOX_PROD_BRIDGE"] == "1" else {
            throw XCTSkip("Start the localhost production bridge on :18779 and set ORB_INBOX_PROD_BRIDGE=1")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18779", "-orb_test_reset", "YES"]
        app.launch()

        let homeInbox = app.buttons["home.tab.inbox"]
        XCTAssertTrue(homeInbox.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 1.0)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/orb-ios-home-prod.png"))

        homeInbox.tap()
        XCTAssertTrue(app.staticTexts["Needs you"].waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 1.0)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/orb-ios-inbox-prod.png"))

        let workingPill = app.buttons["inbox.workingPill"]
        if workingPill.exists {
            workingPill.tap()
            XCTAssertTrue(app.staticTexts["Working in background"].waitForExistence(timeout: 5))
            Thread.sleep(forTimeInterval: 0.4)
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/orb-ios-inbox-working-prod.png"))
            workingPill.tap()
        }

        let firstDone = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'inbox.done.'")).firstMatch
        XCTAssertTrue(firstDone.waitForExistence(timeout: 10))
        firstDone.tap()

        let undoBtn = app.buttons["inbox.undo"]
        XCTAssertTrue(undoBtn.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.4)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/orb-ios-inbox-undo-prod.png"))
        undoBtn.tap()
    }

    @MainActor func testProductionLargeMissionPickerAndContextTagging() throws {
        guard ProcessInfo.processInfo.environment["ORB_PROD_VERIFY"] == "1" else {
            throw XCTSkip("Set ORB_PROD_VERIFY=1 to run the production verification flow")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        let defaultProject = app.buttons["project.default"]
        XCTAssertTrue(defaultProject.waitForExistence(timeout: 20))
        defaultProject.tap()

        // 1. Verify "New agent" composer before selecting a model/agent (and @ context tagging)
        let newAgentBtn = app.buttons["new-agent"]
        XCTAssertTrue(newAgentBtn.waitForExistence(timeout: 15))
        newAgentBtn.tap()

        let agentSelectionBtn = app.buttons["agent-selection"]
        XCTAssertTrue(agentSelectionBtn.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.5)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/Users/thomas/.gemini/antigravity-cli/brain/d438faae-ff03-44f2-b954-ba174b48e842/scratch/verify_1_new_agent_selector.png"))

        // Verify @ context tagging popup in composer
        let composer = app.textFields["composer"].exists ? app.textFields["composer"] : app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        if !app.buttons["context-browse-back"].exists {
            composer.tap()
            composer.typeText("@")
            Thread.sleep(forTimeInterval: 1.0)
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/Users/thomas/.gemini/antigravity-cli/brain/d438faae-ff03-44f2-b954-ba174b48e842/scratch/verify_2_context_picker.png"))

            let firstContextItem = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'context-item-'")).firstMatch
            if firstContextItem.waitForExistence(timeout: 3) {
                firstContextItem.tap()
                Thread.sleep(forTimeInterval: 0.8)
                try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/Users/thomas/.gemini/antigravity-cli/brain/d438faae-ff03-44f2-b954-ba174b48e842/scratch/verify_3_context_tagged.png"))
            }
        }

        // Navigate back to Default project mission list
        app.navigationBars.buttons.element(boundBy: 0).tap()
        Thread.sleep(forTimeInterval: 1.0)

        // 2. Open large mission "Yukon (sig.golf)" (763 KB, 87 history items)
        let yukonMission = app.buttons["mission.85cce150-8b72-4a5f-be57-61aea8043104"]
        if yukonMission.waitForExistence(timeout: 10) {
            yukonMission.tap()
            Thread.sleep(forTimeInterval: 2.5)
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/Users/thomas/.gemini/antigravity-cli/brain/d438faae-ff03-44f2-b954-ba174b48e842/scratch/verify_4_yukon_mission.png"))
            app.navigationBars.buttons.element(boundBy: 0).tap()
            Thread.sleep(forTimeInterval: 1.0)
        }

        // 3. Open large replacement mission "DGX Spark" (178 KB, 91 history items, 43 KB replacement continuation envelope)
        let dgxMission = app.buttons["mission.d2415091-a5e0-4e38-8582-62f6175ed355"]
        if !dgxMission.exists {
            // Switch filter to All or scroll down if needed
            for _ in 0..<4 {
                if dgxMission.exists && dgxMission.isHittable { break }
                app.swipeUp()
            }
        }
        if dgxMission.waitForExistence(timeout: 10) {
            dgxMission.tap()
            Thread.sleep(forTimeInterval: 2.5)
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/Users/thomas/.gemini/antigravity-cli/brain/d438faae-ff03-44f2-b954-ba174b48e842/scratch/verify_5_dgx_spark_mission.png"))
            // Also test tapping Load earlier messages to ensure unpacked continuation turns render without freezing
            let loadEarlier = app.buttons["load-earlier"]
            for _ in 0..<3 {
                app.swipeDown()
                if loadEarlier.exists && loadEarlier.isHittable {
                    loadEarlier.tap()
                    Thread.sleep(forTimeInterval: 0.8)
                }
            }
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/Users/thomas/.gemini/antigravity-cli/brain/d438faae-ff03-44f2-b954-ba174b48e842/scratch/verify_6_dgx_spark_earlier.png"))
        }
    }
}

