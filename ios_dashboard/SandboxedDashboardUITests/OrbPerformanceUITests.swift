import XCTest

/// Push/pop cost of opening conversations from the project list (A7).
/// Run `python3 ios_dashboard/TestsSupport/orb_fixture_server.py` first (port 18766).
/// Not part of the default regression pass: compare durations and hitch ratios
/// before/after a change on the same machine.
final class OrbPerformanceUITests: XCTestCase {
    @MainActor private func listApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18766", "-orb_test_reset", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        app.buttons["project.orb-test"].tap()
        XCTAssertTrue(app.buttons["mission.long-rich"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor private func measureOpen(_ mission: String) {
        let app = listApp()
        // Warm caches once so every measured iteration opens from the read cache.
        app.buttons["mission.\(mission)"].tap()
        XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 15))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["mission.\(mission)"].waitForExistence(timeout: 10))
        let options = XCTMeasureOptions(); options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.navigationTransitionMetric, XCTClockMetric()], options: options) {
            app.buttons["mission.\(mission)"].tap()
            XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 15))
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["mission.\(mission)"].waitForExistence(timeout: 10))
        }
    }

    /// Streaming cost: an 8 KB Markdown reply arrives as ~2,000 four-character deltas
    /// (`STREAM_LONG` in the fixture) on a finished mission with a long transcript.
    /// CPU time is the app's work to re-render the growing reply (the 40 s wait covers the
    /// fixture's ~25 s of pacing), so compare CPU and memory, not clock.
    @MainActor func testStreamLongAnswer() {
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18766", "-orb_test_reset", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        app.buttons["project.orb-test"].tap()
        let row = app.buttons["mission.finished-antigravity"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
        row.tap()
        let composer = app.textFields["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        let options = XCTMeasureOptions(); options.iterationCount = 3
        var round = 0
        measure(metrics: [XCTCPUMetric(application: app), XCTMemoryMetric(application: app), XCTClockMetric()], options: options) {
            round += 1
            composer.tap()
            composer.typeText("STREAM_LONG round \(round)")
            app.buttons["composer.send"].tap()
            // Wait without querying: each XCUITest query snapshots the app's whole
            // accessibility tree on its main thread (95% of its CPU in a Time Profiler
            // trace), which would measure the test harness instead of the app.
            Thread.sleep(forTimeInterval: 40)
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'STREAM_LONG_END'")).element(boundBy: round - 1).waitForExistence(timeout: 30))
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Scroll cost on the long rich transcript: hitch ratio while flicking up and down.
    @MainActor func testScrollLongRichConversation() {
        let app = listApp()
        app.buttons["mission.long-rich"].tap()
        XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 15))
        let options = XCTMeasureOptions(); options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTCPUMetric(application: app)], options: options) {
            app.swipeDown(velocity: .fast); app.swipeDown(velocity: .fast)
            app.swipeUp(velocity: .fast); app.swipeUp(velocity: .fast)
        }
    }

    /// Memory after opening the heavy conversations one after the other (long tool output,
    /// 25 KB answers, rich Markdown), as when browsing missions; caches keep all three.
    @MainActor func testBrowseHeavyMissionsMemory() {
        let app = listApp()
        let options = XCTMeasureOptions(); options.iterationCount = 3
        measure(metrics: [XCTMemoryMetric(application: app), XCTCPUMetric(application: app)], options: options) {
            for mission in ["long-running", "finished-antigravity", "long-rich"] {
                let row = app.buttons["mission.\(mission)"]
                for _ in 0..<8 where !row.isHittable { app.swipeUp() }
                row.tap()
                XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 30))
                app.navigationBars.buttons.element(boundBy: 0).tap()
                XCTAssertTrue(row.waitForExistence(timeout: 10))
            }
        }
    }

    @MainActor func testOpenLongRichConversation() { measureOpen("long-rich") }
    @MainActor func testOpenShortConversation() { measureOpen("idle-send") }
}
