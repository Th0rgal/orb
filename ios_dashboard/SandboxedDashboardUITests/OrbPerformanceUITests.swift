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

    @MainActor func testOpenLongRichConversation() { measureOpen("long-rich") }
    @MainActor func testOpenShortConversation() { measureOpen("idle-send") }
}
