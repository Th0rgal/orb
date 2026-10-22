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

    // MARK: /btw side sheet (`btw-chat`: one answered thread, one live thread answering ~8 s after a reset)

    @MainActor private func openSideSheet() async throws -> XCUIApplication {
        try await Self.resetFixture()
        let app = open("btw-chat")
        let composer = app.textFields["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("/btw")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.textFields["btw.input"].waitForExistence(timeout: 3), "the side sheet opens")
        return app
    }

    private func label(contains text: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// History of every thread is on screen at once, rendered by the conversation's Markdown renderer.
    @MainActor func testSideSheetShowsThreadsAtOnceAsRenderedMarkdown() async throws {
        let app = try await openSideSheet()
        XCTAssertTrue(label(contains: "BTW_DONE_OK", in: app).waitForExistence(timeout: 1), "the answered thread shows within 1 s")
        XCTAssertTrue(app.staticTexts["Summarise the build"].exists, "the question is a bubble, without the embedded context")
        XCTAssertTrue(app.staticTexts["What is running now?"].exists, "the live thread is shown too")
        XCTAssertTrue(app.descendants(matching: .any)["btw.progress"].waitForExistence(timeout: 2), "the live thread shows the Working row")
        XCTAssertFalse(app.staticTexts["btw.intro"].exists)
        let raw = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '**' OR label CONTAINS '`' OR label CONTAINS '## Objective' OR label CONTAINS 'Continue if you have next steps'"))
        XCTAssertEqual(raw.count, 0, "Markdown is rendered and compaction blocks are stripped")
        XCTAssertTrue(app.buttons["Copy response"].exists, "answers have the conversation's copy button")
        let narration = app.buttons["btw.narration"].firstMatch
        XCTAssertTrue(narration.exists)
        XCTAssertEqual(narration.label, "2 progress updates")
        XCTAssertFalse(app.staticTexts["Checking the tests."].exists, "narration is folded")
        narration.tap()
        XCTAssertTrue(app.staticTexts["Checking the tests."].waitForExistence(timeout: 2))
        capture(app, "btw-history")
        XCTAssertTrue(label(contains: "LIVE_ANSWER_OK", in: app).waitForExistence(timeout: 60), "the live thread is followed to its answer")
        XCTAssertFalse(app.descendants(matching: .any)["btw.progress"].exists)
        capture(app, "btw-live-answered")
    }

    /// The sheet keeps the large detent when the keyboard hides; an upward drag never dismisses it.
    @MainActor func testSideSheetStaysLargeAndUpwardDragDoesNotDismiss() async throws {
        let app = try await openSideSheet()
        let bar = app.navigationBars["Side question"]
        XCTAssertTrue(bar.waitForExistence(timeout: 2))
        let top = bar.frame.minY
        let input = app.textFields["btw.input"]
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        label(contains: "BTW_DONE_OK", in: app).tap() // tapping the transcript hides the keyboard
        let hidden = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        await fulfillment(of: [hidden], timeout: 3)
        sleep(1)
        XCTAssertEqual(bar.frame.minY, top, accuracy: 2, "no drop to a half detent after the keyboard hides")
        let grabber = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        grabber.press(forDuration: 0.1, thenDragTo: grabber.withOffset(CGVector(dx: 0, dy: -300)))
        app.scrollViews.firstMatch.swipeUp()
        sleep(1)
        XCTAssertTrue(bar.exists, "an upward drag does not dismiss the sheet")
        XCTAssertEqual(bar.frame.minY, top, accuracy: 2)
        capture(app, "btw-after-upward-drag")
        app.buttons["btw.done"].tap()
        XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 3))
    }

    /// Send: the optimistic bubble at once, the live Working row, then the streamed answer.
    @MainActor func testSideQuestionSendShowsBubbleThenStreamsAnswer() async throws {
        let app = try await openSideSheet()
        XCTAssertTrue(label(contains: "LIVE_ANSWER_OK", in: app).waitForExistence(timeout: 60))
        let input = app.textFields["btw.input"]
        input.tap()
        input.typeText("Is it green?")
        XCTAssertEqual(app.buttons["dictation.microphone"].exists, true, "the conversation composer, with dictation")
        app.buttons["btw.send"].tap()
        XCTAssertTrue(app.staticTexts["Is it green?"].waitForExistence(timeout: 1), "the question shows at once")
        XCTAssertTrue(app.descendants(matching: .any)["btw.progress"].waitForExistence(timeout: 2))
        XCTAssertTrue(label(contains: "Looking into it", in: app).waitForExistence(timeout: 12), "the answer streams")
        capture(app, "btw-streaming")
        XCTAssertTrue(label(contains: "SEND_ANSWER_OK", in: app).waitForExistence(timeout: 25))
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.descendants(matching: .any)["btw.progress"])
        await fulfillment(of: [gone], timeout: 5)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == 'Is it green?'")).count, 1, "the optimistic bubble is replaced, not doubled")
        XCTAssertTrue(app.buttons["1 progress update"].exists)
        var received: [String] = []
        received = try await Self.received()
        XCTAssertEqual(received, ["Is it green?"], "the question continues the latest thread")
        capture(app, "btw-sent-answered")
    }

    /// `orb://mission/<id>` opened while the app launches opens that conversation.
    @MainActor func testColdStartDeepLinkOpensMission() async throws {
        try await Self.resetFixture()
        // Keep the app on "Connecting…" while the link arrives, as on a cold start against prod.
        var slow = URLRequest(url: URL(string: "http://127.0.0.1:18766/__health_delay")!)
        slow.httpMethod = "POST"; slow.httpBody = Data(#"{"seconds": 4}"#.utf8)
        _ = try await URLSession.shared.data(for: slow)
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18766", "-orb_test_reset", "YES"]
        app.terminate()
        app.open(URL(string: "orb://mission/agent-done")!)
        XCTAssertTrue(app.staticTexts["The build is fixed and the PR is open."].waitForExistence(timeout: 20), "the cold-start link is not dropped")
        capture(app, "deep-link-cold-start")
        try await Self.resetFixture()
    }

    /// A finished answer says when it completed; a long press shows the date and how long it worked.
    @MainActor func testFinishedAnswerShowsCompletionTimeAndWorkedFor() async throws {
        try await Self.resetFixture()
        let app = open("idle-send")
        let label = app.descendants(matching: .any)["turn-time"]
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        XCTAssertTrue(label.label.hasPrefix("Completed "), label.label)
        XCTAssertTrue(label.label.hasSuffix("worked for 10s"), label.label)
        save(app, "ios-turn-time")
        label.press(forDuration: 1.0)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Worked for 10s")).firstMatch.waitForExistence(timeout: 5))
        save(app, "ios-turn-time-menu")
    }

    @MainActor private func save(_ app: XCUIApplication, _ name: String) {
        capture(app, name)
        if let dir = ProcessInfo.processInfo.environment["ORB_UI_REPORT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
