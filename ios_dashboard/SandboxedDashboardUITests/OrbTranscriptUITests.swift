import XCTest

/// Scroll, keyboard and composer behaviour of the chat transcript (conversation and /btw).
/// Run `python3 ios_dashboard/TestsSupport/orb_fixture_server.py` first (port 18766).
/// Offsets come from the DEBUG-only `*.scrollProbe` accessibility element.
final class OrbTranscriptUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    struct Probe {
        var raw = ""
        var x: Double = 0, maxX: Double = 0, fromBottom: Double = 0, progress: Double = 0, contentW: Double = 0, containerW: Double = 0
        init(_ value: String) {
            raw = value
            for pair in value.split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2, let v = Double(kv[1]) else { continue }
                switch kv[0] {
                case "x": x = v
                case "maxX": maxX = v
                case "fromBottom": fromBottom = v
                case "progress": progress = v
                case "contentW": contentW = v
                case "containerW": containerW = v
                default: break
                }
            }
        }
    }

    @MainActor private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18766", "-orb_test_reset", "YES", "-orb_slow_thumb_fade", "YES"] + extra
        // The first UI launch of an xcodebuild invocation sometimes comes up without its
        // arguments (signed-in endpoint, default text size). Relaunch once if the fixture
        // project is missing, so the test always runs against the fixture.
        for _ in 0..<2 {
            app.terminate()
            app.launch()
            if app.buttons["project.orb-test"].waitForExistence(timeout: 15) || app.buttons["home.tab.inbox"].isSelected { break }
        }
        return app
    }

    @MainActor private func open(_ mission: String) -> XCUIApplication {
        let app = launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        app.buttons["project.orb-test"].tap()
        XCTAssertTrue(app.buttons["mission.\(mission)"].waitForExistence(timeout: 10))
        app.buttons["mission.\(mission)"].tap()
        return app
    }

    @MainActor private func probe(_ app: XCUIApplication, _ id: String = "conversation.scrollProbe") -> Probe {
        let element = app.descendants(matching: .any)[id]
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(id) exists (DEBUG build)")
        return Probe(element.value as? String ?? "")
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if condition() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        return condition()
    }

    private var jump: String { "conversation.jumpToLatest" }

    /// Opening a long conversation lands on the latest message, and stays there once
    /// late content (rich text, images) finishes laying out.
    @MainActor func testConversationOpensAtBottom() throws {
        for mission in ["long-rich", "long-chat"] {
            let app = open(mission)
            XCTAssertTrue(waitUntil(8) { probe(app).fromBottom < 4 }, "\(mission) opens at the bottom: \(probe(app))")
            sleep(3)
            XCTAssertLessThan(probe(app).fromBottom, 4, "\(mission) is still at the bottom after layout settles")
            XCTAssertFalse(app.buttons[jump].exists, "no jump pill at the bottom")
            capture(app, "opens-at-bottom-\(mission)")
            app.terminate()
        }
    }

    /// Horizontal drags never move the transcript sideways (code and tables scroll inside themselves).
    @MainActor func testNoHorizontalScrollOffset() throws {
        let app = open("long-rich")
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(8) { probe(app).fromBottom < 4 })
        for dy in [0.2, 0.4, 0.6, 0.8] {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: dy))
            start.press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: dy)))
            // Diagonal drags (mostly vertical) must not leak sideways either. (A pure
            // left-to-right drag is iOS 26's full-width back gesture, so not tested here.)
            let diag = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: dy))
            diag.press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: min(0.95, dy + 0.15))))
        }
        scroll.swipeLeft()
        let p = probe(app)
        XCTAssertEqual(p.maxX, 0, accuracy: 0.5, "the transcript never scrolls horizontally: \(p)")
        XCTAssertLessThanOrEqual(p.contentW, p.containerW + 0.5, "content is never wider than the screen: \(p)")
    }

    /// Scrolling up shows a jump-to-latest pill; tapping it returns to the bottom and hides it.
    @MainActor func testJumpToLatestAppearsWhenScrolledUp() throws {
        let app = open("long-rich")
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(8) { probe(app).fromBottom < 4 })
        scroll.swipeDown(); scroll.swipeDown()
        XCTAssertTrue(app.buttons[jump].waitForExistence(timeout: 3), "pill appears when scrolled up")
        XCTAssertGreaterThan(probe(app).fromBottom, 200)
        capture(app, "jump-to-latest-visible")
        app.buttons[jump].tap()
        XCTAssertTrue(waitUntil(4) { probe(app).fromBottom < 4 }, "tapping the pill returns to the bottom: \(probe(app))")
        XCTAssertTrue(waitUntil(3) { !app.buttons[jump].exists }, "pill hides at the bottom")
    }

    /// The scroll indicator becomes a draggable thumb: dragging it to the top jumps to the start.
    @MainActor func testFastScrollThumbDragsThroughTranscript() throws {
        let app = open("long-rich")
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(8) { probe(app).fromBottom < 4 })
        scroll.swipeDown()
        let thumb = app.descendants(matching: .any)["conversation.scrollThumb"]
        XCTAssertTrue(thumb.waitForExistence(timeout: 3), "the thumb shows while scrolling")
        let top = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.0))
        thumb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.3, thenDragTo: top)
        XCTAssertLessThan(probe(app).progress, 0.05, "dragging the thumb to the top reaches the start: \(probe(app))")
        capture(app, "fast-scroll-top")
        let bottom = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 1.0))
        scroll.swipeUp()
        XCTAssertTrue(thumb.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(thumb.frame.width, 24, "a touchable target")
        thumb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.3, thenDragTo: bottom)
        XCTAssertTrue(waitUntil(3) { probe(app).fromBottom < 4 }, "dragging to the bottom reaches the end: \(probe(app))")
    }

    /// Characters typed the moment the composer appears are all kept.
    @MainActor func testComposerKeepsEarlyInput() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        app.buttons["project.orb-test"].tap()
        XCTAssertTrue(app.buttons["mission.long-rich"].waitForExistence(timeout: 10))
        app.buttons["mission.long-rich"].tap()
        let composer = app.textFields["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("first words typed at once")
        sleep(3)
        XCTAssertEqual(composer.value as? String, "first words typed at once")
        // The keyboard keeps the latest message visible.
        XCTAssertTrue(waitUntil(4) { probe(app).fromBottom < 4 }, "focusing the composer keeps the bottom visible: \(probe(app))")
    }

    /// The header menu opens on the first tap, right after the conversation appears.
    @MainActor func testHeaderMenuOpensOnFirstTap() throws {
        let app = open("long-rich")
        let menu = app.buttons["conversation.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 2), "one tap opens the menu")
    }

    /// At Accessibility XL text the transcript still opens at the bottom, never scrolls
    /// sideways, and the composer and menu stay reachable.
    @MainActor func testAccessibilityTextSizeKeepsLayoutUsable() throws {
        let app = launch(["-orb_dynamic_type", "accessibility3"])
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        capture(app, "a11y-xl-projects")
        app.buttons["project.orb-test"].tap()
        XCTAssertTrue(app.buttons["mission.agent-done"].waitForExistence(timeout: 10))
        capture(app, "a11y-xl-missions")
        app.buttons["mission.agent-done"].tap()
        let composer = app.textFields["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(8) { probe(app).fromBottom < 4 }, "opens at the bottom: \(probe(app))")
        app.scrollViews.firstMatch.swipeLeft()
        let p = probe(app)
        XCTAssertEqual(p.maxX, 0, accuracy: 0.5)
        XCTAssertLessThanOrEqual(p.contentW, p.containerW + 0.5)
        XCTAssertTrue(composer.isHittable)
        XCTAssertTrue(app.buttons["conversation.menu"].isHittable)
        XCTAssertLessThanOrEqual(app.buttons["Send message"].frame.maxX, app.frame.maxX)
        capture(app, "a11y-xl-conversation")
    }

    /// Move picks a project from the roster instead of typing a slug.
    @MainActor func testMoveSheetListsProjects() throws {
        let app = open("long-rich")
        let menu = app.buttons["conversation.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons["Move"].tap()
        let row = app.buttons["move.project.orb-test"]
        XCTAssertTrue(row.waitForExistence(timeout: 8), "the project roster is listed")
        XCTAssertTrue(row.isSelected, "the current project is preselected")
        XCTAssertTrue(app.textFields["move.folder"].exists)
        capture(app, "move-sheet")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 5))
    }

    /// The Inbox reply uses the shared composer box.
    @MainActor func testInboxReplyUsesSharedComposer() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["home.tab.inbox"].waitForExistence(timeout: 20))
        app.buttons["home.tab.inbox"].tap()
        XCTAssertTrue(app.buttons["inbox.filter.all"].waitForExistence(timeout: 10))
        app.buttons["inbox.filter.all"].tap()
        let reply = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'inbox.reply.'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15))
        let id = reply.identifier.replacingOccurrences(of: "inbox.reply.", with: "")
        reply.tap()
        let field = app.textFields["inbox.reply.field.\(id)"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "shared composer field")
        XCTAssertTrue(app.buttons["dictation.microphone"].exists)
        let send = app.buttons["inbox.send.\(id)"]
        XCTAssertTrue(send.exists)
        XCTAssertFalse(send.isEnabled, "send waits for text")
        field.tap(); field.typeText("Inbox words")
        XCTAssertEqual(field.value as? String, "Inbox words")
        XCTAssertTrue(send.isEnabled)
        XCTAssertGreaterThanOrEqual(send.frame.width, 44)
        capture(app, "inbox-shared-composer")
    }

    /// With no server and nothing cached, the Inbox shows an error with Retry, not "Inbox zero".
    @MainActor func testInboxErrorStateOffersRetry() async throws {
        var fail = URLRequest(url: URL(string: "http://127.0.0.1:18766/__fail_missions")!)
        fail.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: fail)
        defer {
            var reset = URLRequest(url: URL(string: "http://127.0.0.1:18766/__reset")!)
            reset.httpMethod = "POST"
            Task { _ = try? await URLSession.shared.data(for: reset) }
        }
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18766", "-orb_test_reset", "YES"]
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["home.tab.inbox"].waitForExistence(timeout: 20))
        app.buttons["home.tab.inbox"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["inbox.error"].waitForExistence(timeout: 30), "error state")
        XCTAssertTrue(app.buttons["inbox.retry"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["inbox.empty"].exists, "not Inbox zero")
        capture(app, "inbox-error")
    }

    /// Only the unanswered permission request shows a card (questions are decoded once per event change).
    @MainActor func testOnlyOpenQuestionShowsACard() throws {
        let app = open("ask-question")
        XCTAssertTrue(app.staticTexts["OPEN_REQUEST run the suite"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["OLD_REQUEST lint"].exists, "an answered request has no card")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == 'Review request'")).count, 1)
        XCTAssertTrue(app.buttons["Approve"].exists)
        capture(app, "open-question-card")
    }

    /// /btw uses the same transcript system: opens at the bottom, never scrolls sideways,
    /// same composer, and stays a single large sheet.
    @MainActor func testSideSheetStaysConsistent() async throws {
        var reset = URLRequest(url: URL(string: "http://127.0.0.1:18766/__reset")!)
        reset.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: reset)
        let app = open("btw-chat")
        let menu = app.buttons["conversation.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons["Side question (/btw)"].tap()
        let input = app.textFields["btw.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["btw-composer"].exists, "shared composer box")
        XCTAssertTrue(waitUntil(6) { probe(app, "btw.scrollProbe").fromBottom < 4 }, "opens at the latest answer: \(probe(app, "btw.scrollProbe"))")
        let scroll = app.scrollViews.firstMatch
        scroll.swipeLeft()
        XCTAssertEqual(probe(app, "btw.scrollProbe").maxX, 0, accuracy: 0.5)
        input.tap(); input.typeText("early side text")
        XCTAssertEqual(input.value as? String, "early side text")
        let frame = app.descendants(matching: .any)["btw-composer"].frame
        XCTAssertGreaterThan(frame.minY, app.frame.height * 0.3, "the sheet stays large with the keyboard up")
        capture(app, "btw-consistent")
    }
}

/// Opt-in live capture on the operator's signed-in app (no fixture, no reset):
/// `TEST_RUNNER_ORB_UX_LIVE_MISSION=<uuid> xcodebuild … -only-testing:SandboxedDashboardUITests/OrbTranscriptLiveCapture test`
/// Only reads and scrolls a dedicated test mission; never sends.
final class OrbTranscriptLiveCapture: XCTestCase {
    @MainActor func testCaptureLiveTranscript() throws {
        guard let mission = ProcessInfo.processInfo.environment["ORB_UX_LIVE_MISSION"], !mission.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_ORB_UX_LIVE_MISSION")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-orb_slow_thumb_fade", "YES"]
        app.launch()
        app.open(URL(string: "orb://mission/\(mission)")!)
        let composer = app.textFields["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        sleep(4)
        shot(app, "live-1-open")
        let probe = app.descendants(matching: .any)["conversation.scrollProbe"]
        XCTContext.runActivity(named: "probe after open: \(probe.value as? String ?? "-")") { _ in }
        let scroll = app.scrollViews.firstMatch
        scroll.swipeDown(); scroll.swipeDown()
        shot(app, "live-2-scrolled-up-pill-thumb")
        scroll.swipeLeft()
        XCTContext.runActivity(named: "probe after swipes: \(probe.value as? String ?? "-")") { _ in }
        app.buttons["conversation.jumpToLatest"].tap()
        sleep(1)
        composer.tap()
        sleep(2)
        shot(app, "live-3-keyboard")
        XCTContext.runActivity(named: "probe with keyboard: \(probe.value as? String ?? "-")") { _ in }
    }

    @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
