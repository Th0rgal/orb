import XCTest

/// Sending on a finished conversation with a long transcript (the 1c33522d shape:
/// antigravity, model override, 25 KB answers behind "Show full response") must keep
/// the app responsive. Build 1393 spun the main thread in a scroll-position feedback
/// loop right after the tap, and iOS killed the app.
/// Run `python3 ios_dashboard/TestsSupport/orb_fixture_server.py` first (port 18766).
final class OrbSendCrashUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor func testSendOnFinishedLongMissionKeepsAppResponsive() throws {
        // ORB_REPLAY_MISSION points at a `--replay` export instead of the synthetic mission.
        let mission = ProcessInfo.processInfo.environment["ORB_REPLAY_MISSION"] ?? "finished-antigravity"
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18766", "-orb_test_reset", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["project.orb-test"].waitForExistence(timeout: 20))
        app.buttons["project.orb-test"].tap()
        let row = app.buttons["mission.\(mission)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
        row.tap()
        let composer = app.textFields["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap()
        composer.typeText("Great start this plan and implement it till the end")
        app.buttons["composer.send"].tap()
        // A spinning main thread makes every query time out; the resumed turn's reply must show.
        XCTAssertTrue(app.staticTexts["REPLAY_REPLY_OK: still building."].waitForExistence(timeout: 30), "the app stays responsive after the send")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(composer.exists, "still in the conversation after the send")
    }
}
