import XCTest

/// Files an agent shared: chips in the transcript (never raw `<file>` markup), previews
/// (image, PDF, highlighted code, unknown binary with download progress and the share
/// sheet), a deleted file's error, and the Files tab with the read-only workspace.
/// Run `python3 ios_dashboard/TestsSupport/orb_fixture_server.py` first (port 18766):
/// mission `shared-files`.
final class OrbFilesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func open(_ mission: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-api_base_url", "http://127.0.0.1:18766", "-orb_test_reset", "YES"]
        for _ in 0..<2 {
            app.terminate()
            app.launch()
            if app.buttons["project.orb-test"].waitForExistence(timeout: 15) { break }
        }
        app.buttons["project.orb-test"].tap()
        XCTAssertTrue(app.buttons["mission.\(mission)"].waitForExistence(timeout: 10))
        app.buttons["mission.\(mission)"].tap()
        return app
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor private func chip(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons["file.chip.\(name)"]
    }

    @MainActor private func preview(_ app: XCUIApplication, chip name: String, expect id: String, shot: String, timeout: TimeInterval = 15) {
        let element = chip(app, name)
        XCTAssertTrue(element.waitForExistence(timeout: 10), "chip \(name)")
        element.tap()
        XCTAssertTrue(app.descendants(matching: .any)[id].waitForExistence(timeout: timeout), "\(name) shows \(id)")
        capture(app, shot)
        app.buttons["file.viewer.done"].tap()
        XCTAssertTrue(element.waitForExistence(timeout: 5))
    }

    @MainActor func testSharedFilesRenderAsChipsAndOpenPreviews() throws {
        let app = open("shared-files")
        for name in ["chart.png", "report.pdf", "analyse.py", "dataset.bin"] {
            XCTAssertTrue(chip(app, name).waitForExistence(timeout: 15), "\(name) is a chip")
        }
        let raw = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '<file' OR label CONTAINS '<image'"))
        XCTAssertEqual(raw.count, 0, "no raw markup in the transcript")
        XCTAssertTrue(chip(app, "report.pdf").label.contains("Quarterly report"))
        capture(app, "files-transcript-chips")

        preview(app, chip: "chart.png", expect: "file.viewer.image", shot: "files-preview-image")
        preview(app, chip: "report.pdf", expect: "file.viewer.pdf", shot: "files-preview-pdf")
        preview(app, chip: "analyse.py", expect: "file.viewer.text", shot: "files-preview-code")

        // Unknown 3 MB binary: chunked download with progress, then the share sheet.
        chip(app, "dataset.bin").tap()
        XCTAssertTrue(app.descendants(matching: .any)["file.viewer.loading"].waitForExistence(timeout: 5), "progress while downloading")
        capture(app, "files-download-progress")
        XCTAssertTrue(app.descendants(matching: .any)["file.viewer.unsupported"].waitForExistence(timeout: 20))
        let share = app.buttons["file.viewer.shareButton"]
        XCTAssertTrue(share.exists)
        capture(app, "files-preview-unknown")
        share.tap()
        let sheet = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'ActivityListView' OR label == 'Save to Files' OR label == 'Copy'")).firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "system share sheet")
        capture(app, "files-share-sheet")
        app.swipeDown(velocity: .fast)
        if !app.buttons["file.viewer.done"].waitForExistence(timeout: 3) { app.tap() }
        app.buttons["file.viewer.done"].tap()

        // A file deleted since it was shared.
        let gone = chip(app, "gone.csv")
        for _ in 0..<6 where !gone.isHittable { app.swipeDown() }
        XCTAssertTrue(gone.waitForExistence(timeout: 5))
        gone.tap()
        let error = app.staticTexts["file.viewer.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertTrue(error.label.contains("no longer"), error.label)
        capture(app, "files-preview-missing")
        app.buttons["file.viewer.done"].tap()
    }

    @MainActor func testFilesTabListsSharedFilesAndWorkspace() throws {
        let app = open("shared-files")
        let menu = app.buttons["conversation.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        let files = app.buttons["conversation.files"]
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        files.tap()
        let rows = ["dataset.bin", "analyse.py", "report.pdf", "chart.png", "gone.csv"].map { app.buttons["files.row.\($0)"] }
        XCTAssertTrue(rows[0].waitForExistence(timeout: 15))
        XCTAssertTrue(rows.allSatisfy(\.exists), "every shared file is listed")
        XCTAssertLessThan(rows[3].frame.minY, rows[4].frame.minY, "newest message first")
        XCTAssertTrue(app.buttons["files.row.report.pdf"].label.contains("KB") || app.buttons["files.row.report.pdf"].label.contains("bytes"), "size from shared_files")
        capture(app, "files-tab")

        app.buttons["files.row.report.pdf"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["file.viewer.pdf"].waitForExistence(timeout: 15))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let workspace = app.buttons["files.workspace"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10), "workspace section")
        workspace.tap()
        XCTAssertTrue(app.buttons["workspace.row.data.csv"].waitForExistence(timeout: 10))
        capture(app, "files-workspace")
        app.buttons["workspace.row.data.csv"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["file.viewer.csv"].waitForExistence(timeout: 15))
        capture(app, "files-preview-csv")
    }
}
