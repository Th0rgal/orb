import XCTest

/// Landscape on a notched iPhone: the background fills the side safe areas (no bars of
/// another color beside the content) on every main screen, and the transcript follows the
/// window when the phone turns instead of staying a portrait-wide column. Run
/// `python3 ios_dashboard/TestsSupport/orb_fixture_server.py` first (port 18766).
/// Set `TEST_RUNNER_ORB_SHOT_DIR` to also write the PNGs.
final class OrbLandscapeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }
    override func tearDown() { XCUIDevice.shared.orientation = .portrait }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18766", "-orb_test_reset", "YES"]
        XCUIDevice.shared.orientation = .portrait
        // A freshly booted simulator can miss the first load: relaunch once, like OrbFilesUITests.
        for _ in 0..<2 {
            app.terminate()
            app.launch()
            if app.buttons["project.orb-test"].waitForExistence(timeout: 20) { break }
        }
        XCTAssertTrue(app.buttons["project.orb-test"].exists)
        return app
    }

    /// Navigates in portrait, where the fixture rows are on screen, then turns to landscape.
    @MainActor private func tapInPortrait(_ app: XCUIApplication, _ id: String) {
        XCUIDevice.shared.orientation = .portrait
        let element = app.buttons[id]
        XCTAssertTrue(element.waitForExistence(timeout: 10), id)
        element.tap()
    }

    /// Captures the screen and checks both outer columns match the column just inside
    /// the safe area, row by row: a bar of the window background shows up as a mismatch.
    @MainActor private func check(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.8)
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let dir = ProcessInfo.processInfo.environment["ORB_SHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("landscape-\(name).png"))
        }
        guard let image = shot.image.cgImage else { return XCTFail("\(name): no image") }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // The screen buffer stays in the device's portrait frame: the landscape sides are its short edges.
        let portraitBuffer = height > width
        let long = max(width, height), short = min(width, height)
        func pixel(along a: Int, across b: Int) -> [Int] {
            let (x, y) = portraitBuffer ? (b, a) : (a, b)
            let i = (y * width + x) * 4; return [Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])]
        }
        // Probe just past the side safe area: 44 pt on notched phones (375 pt tall in landscape), 62 pt with a Dynamic Island.
        let shortPoints = Double(min(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height))
        let inset = Int((shortPoints <= 375 ? 48 : 66) * Double(short) / shortPoints)
        var mismatched = 0, sampled = 0
        for b in stride(from: short / 5, to: short * 4 / 5, by: 8) {
            for (edge, inner) in [(2, inset), (long - 3, long - 1 - inset)] {
                sampled += 1
                if zip(pixel(along: edge, across: b), pixel(along: inner, across: b)).contains(where: { abs($0 - $1) > 12 }) { mismatched += 1 }
            }
        }
        // Content (text, rows) can sit at the inner column; a background bar mismatches nearly everywhere.
        XCTAssertLessThan(Double(mismatched) / Double(sampled), 0.5, "\(name): side bars beside the content in landscape")
    }

    @MainActor private func checkLandscape(_ app: XCUIApplication, _ name: String) {
        XCUIDevice.shared.orientation = .landscapeLeft
        check(app, name)
    }

    @MainActor func testMainScreensFillLandscapeSafeAreas() throws {
        let app = launch()
        checkLandscape(app, "projects")
        tapInPortrait(app, "home.tab.inbox")
        checkLandscape(app, "inbox")
        tapInPortrait(app, "home.tab.projects")
        tapInPortrait(app, "project.orb-test")
        XCTAssertTrue(app.buttons["mission.long-chat"].waitForExistence(timeout: 10))
        checkLandscape(app, "missions")
        tapInPortrait(app, "mission.long-chat")
        let composer = app.textFields["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        checkLandscape(app, "conversation")
        assertTranscriptFillsWidth(app, "conversation")
        // Turning back and forth must not leave the transcript at an earlier width.
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 1)
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1)
        assertTranscriptFillsWidth(app, "conversation")
        composer.tap()
        check(app, "composer-keyboard")
        composer.typeText("/btw")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.textFields["btw.input"].waitForExistence(timeout: 5))
        check(app, "side-question")
        assertTranscriptFillsWidth(app, "btw")
    }

    /// The transcript column follows the window: after a rotation its content is as wide
    /// as the scroll view, not left at the portrait width with bare bands beside it.
    @MainActor private func assertTranscriptFillsWidth(_ app: XCUIApplication, _ id: String) {
        let probe = app.descendants(matching: .any)["\(id).scrollProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        let fields = Dictionary(uniqueKeysWithValues: ((probe.value as? String) ?? "").split(separator: ";").compactMap { pair -> (String, Double)? in
            let kv = pair.split(separator: "="); return kv.count == 2 ? (String(kv[0]), Double(kv[1]) ?? 0) : nil
        })
        let content = fields["contentW"] ?? 0, container = fields["containerW"] ?? 0
        XCTAssertGreaterThan(container, app.windows.firstMatch.frame.height, "\(id): transcript is landscape-wide")
        XCTAssertEqual(content, container, accuracy: 1, "\(id): transcript content fills the scroll view")
    }

    /// Opening a conversation while already in landscape lays it out the same way.
    @MainActor func testConversationOpenedInLandscape() throws {
        let app = launch()
        tapInPortrait(app, "project.orb-test")
        let row = app.buttons["mission.long-chat"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 0.8)
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 10))
        check(app, "conversation-opened-landscape")
        assertTranscriptFillsWidth(app, "conversation")
    }

    @MainActor func testSettingsAndFilesFillLandscapeSafeAreas() throws {
        let app = launch()
        tapInPortrait(app, "Settings")
        XCTAssertTrue(app.buttons["settings.models"].waitForExistence(timeout: 5))
        checkLandscape(app, "settings")
        tapInPortrait(app, "settings.models")
        XCTAssertTrue(app.buttons["settings.providers"].waitForExistence(timeout: 5))
        tapInPortrait(app, "settings.providers")
        XCTAssertTrue(app.staticTexts["Fixture provider"].waitForExistence(timeout: 10))
        checkLandscape(app, "providers")
        app.terminate()
        let files = launch()
        tapInPortrait(files, "project.orb-test")
        tapInPortrait(files, "mission.shared-files")
        tapInPortrait(files, "file.chip.report.pdf")
        XCTAssertTrue(files.descendants(matching: .any)["file.viewer.pdf"].waitForExistence(timeout: 15))
        checkLandscape(files, "pdf-viewer")
    }
}
