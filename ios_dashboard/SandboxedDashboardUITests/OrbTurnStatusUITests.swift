import XCTest

/// Desktop parity from the 2026-10-18 audit, on the fixture's `agent-work` (mid-turn)
/// and `agent-done` (finished, PR linked) conversations.
/// Run `python3 ios_dashboard/TestsSupport/orb_fixture_server.py` first (port 18766).
final class OrbTurnStatusUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func open(_ mission: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18766", "-orb_test_reset", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        app.buttons["project.orb-test"].tap()
        XCTAssertTrue(app.buttons["mission.\(mission)"].waitForExistence(timeout: 10))
        app.buttons["mission.\(mission)"].tap()
        return app
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    /// "done"/"in-progress" count as progress, and the clock starts at the turn's server time.
    @MainActor func testWorkingTurnCountsHarnessStatusesAndUsesServerClock() throws {
        let app = open("agent-work")
        XCTAssertTrue(app.staticTexts["1/4 tasks"].waitForExistence(timeout: 10), "a task marked done must count")
        XCTAssertTrue(app.staticTexts["· Fix the type-check timeout"].exists, "the in-progress task is the active one")
        // The fixture's turn started 95 s before the request: never "3 s".
        let clock = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[1-9] min [0-9]{2} s$'")).firstMatch
        XCTAssertTrue(clock.waitForExistence(timeout: 5), "elapsed time must come from the turn start")
        capture(app, "turn-working-status")
    }

    /// The finished turn counts only its own work and shows what changed and where it ships.
    @MainActor func testFinishedTurnShowsChangesAndPullRequest() throws {
        let app = open("agent-done")
        XCTAssertTrue(app.staticTexts["Worked — 1 read, 2 edits, 1 command"].waitForExistence(timeout: 10), "the earlier turn's edit is not this turn's work")
        XCTAssertTrue(app.staticTexts["3 files changed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["turn.changes.pr"].exists)
        XCTAssertEqual(app.buttons["turn.changes.pr"].label, "Th0rgal/orb#1132")
        app.buttons["turn.changes.summary"].tap()
        XCTAssertTrue(app.staticTexts["repo/ios/App.swift"].waitForExistence(timeout: 3))
        capture(app, "turn-changes-expanded")
    }

    /// `/btw <question>` sends once: the question shows at once with a live stage until the answer.
    @MainActor func testSideQuestionSendsFromComposerWithLiveProgress() throws {
        let app = open("agent-done")
        let composer = app.textFields["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("/btw what is the agent doing?")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["btw.progress"].waitForExistence(timeout: 2), "no silent wait after sending")
        XCTAssertTrue(app.staticTexts["what is the agent doing?"].exists, "the question shows before Core answers")
        capture(app, "btw-progress")
        XCTAssertTrue(app.staticTexts["SIDE_ANSWER_OK: the agent is fixing the build."].waitForExistence(timeout: 20))
        XCTAssertFalse(app.descendants(matching: .any)["btw.progress"].exists)
        capture(app, "btw-answer")
    }
}
