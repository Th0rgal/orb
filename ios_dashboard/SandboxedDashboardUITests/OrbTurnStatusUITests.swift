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

    /// Queue while running -> Core delivers it -> the queued row becomes the transcript
    /// bubble, the reply streams in and the Working row goes away once the mission completes.
    @MainActor func testQueuedFollowUpBecomesBubbleWithReply() async throws {
        var reset = URLRequest(url: URL(string: "http://127.0.0.1:18766/__reset")!)
        reset.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: reset) // the fixture's turn runs again
        let app = open("queue-run")
        let composer = app.textFields["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        if !app.descendants(matching: .any)["agent-working"].waitForExistence(timeout: 10) { capture(app, "queue-run-not-working"); XCTFail("the turn is running") }
        composer.tap()
        composer.typeText("third message while running")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.staticTexts["1 Queued"].waitForExistence(timeout: 5), "a follow-up during a turn is queued")
        capture(app, "queue-while-running")
        XCTAssertTrue(app.staticTexts["QUEUED_REPLY_OK"].waitForExistence(timeout: 25), "the reply to the delivered message shows")
        XCTAssertTrue(app.staticTexts["third message while running"].exists, "the delivered message is a transcript bubble")
        let gone = NSPredicate(format: "exists == false")
        let queuedGone = expectation(for: gone, evaluatedWith: app.staticTexts["1 Queued"])
        let workingGone = expectation(for: gone, evaluatedWith: app.descendants(matching: .any)["agent-working"])
        await fulfillment(of: [queuedGone, workingGone], timeout: 10)
        capture(app, "queue-delivered")
    }

    private nonisolated static func resetFixture() async throws {
        var reset = URLRequest(url: URL(string: "http://127.0.0.1:18766/__reset")!)
        reset.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: reset)
    }

    /// A second send tapped while the first is in flight is queued at once, never dropped,
    /// and the Working clock starts from the new turn, not the old one (~36 min ago).
    @MainActor func testSendWhileSendingIsQueuedAndClockStartsFresh() async throws {
        try await Self.resetFixture()
        let app = open("idle-send")
        let composer = app.textFields["composer"]
        let send = app.buttons["composer.send"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("fourth idle")
        send.tap()
        composer.typeText("fifth queued")
        XCTAssertEqual(send.value as? String, "Sending", "the first send is still in flight")
        send.tap()
        XCTAssertTrue(app.staticTexts["1 Queued"].waitForExistence(timeout: 2), "the tap is accepted at once")
        XCTAssertFalse((composer.value as? String ?? "").contains("fifth queued"), "the text leaves the composer")
        let stale = app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' min '")).firstMatch
        XCTAssertFalse(stale.exists, "the clock never counts from the old turn")
        capture(app, "send-while-sending")
        XCTAssertTrue(app.descendants(matching: .any)["agent-working"].waitForExistence(timeout: 10))
        XCTAssertFalse(stale.exists, "the clock never counts from the old turn")
        // Core must actually receive the second message, while the first turn still runs.
        var received: [String] = []
        for _ in 0..<20 where !received.contains("fifth queued") {
            received = try await Self.received()
            if !received.contains("fifth queued") { try await Task.sleep(for: .milliseconds(250)) }
        }
        XCTAssertEqual(received, ["fourth idle", "fifth queued"], "the fixture server received both messages, in order")
        XCTAssertTrue(app.staticTexts["QUEUED_REPLY_OK"].waitForExistence(timeout: 25), "the deferred message was delivered")
        XCTAssertTrue(app.staticTexts["fifth queued"].exists)
        let gone = NSPredicate(format: "exists == false")
        let queuedGone = expectation(for: gone, evaluatedWith: app.staticTexts["1 Queued"])
        let workingGone = expectation(for: gone, evaluatedWith: app.descendants(matching: .any)["agent-working"])
        await fulfillment(of: [queuedGone, workingGone], timeout: 10)
    }

    private nonisolated static func received() async throws -> [String] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18766/__received")!)
        return try JSONDecoder().decode([String].self, from: data)
    }

    /// Text typed right after the conversation opens is kept.
    @MainActor func testEarlyComposerInputIsKept() async throws {
        try await Self.resetFixture()
        let app = open("agent-done")
        let composer = app.textFields["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("early words")
        sleep(2) // the open path (draft restore, first refresh) has run
        XCTAssertEqual(composer.value as? String, "early words")
    }
}
