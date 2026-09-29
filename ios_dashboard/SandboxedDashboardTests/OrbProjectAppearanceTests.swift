import XCTest
@testable import sandboxed_sh

/// Same palette and storage rules as the desktop `projectAppearance.ts`.
@MainActor
final class OrbProjectAppearanceTests: XCTestCase {
    private let suite = "OrbProjectAppearanceTests"
    private var defaults: UserDefaults!
    private var endpoint = "https://core.example"

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        endpoint = "https://core.example"
    }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }
    private func store() -> OrbProjectAppearance { OrbProjectAppearance(defaults: defaults, endpoint: { [unowned self] in endpoint }) }

    func testPaletteMatchesDesktop() {
        XCTAssertEqual(OrbProjectAppearance.colors.map(\.name), ["Default", "Blue", "Green", "Amber", "Rose", "Purple"])
        XCTAssertEqual(OrbProjectAppearance.colors.map(\.value), ["", "#8aaed4", "#94b89a", "#c5aa70", "#cb929f", "#ad9acb"])
        for choice in OrbProjectAppearance.colors.dropFirst() { XCTAssertNotNil(OrbProjectAppearance.components(choice.value)) }
        let blue = OrbProjectAppearance.components("#8aaed4")
        XCTAssertEqual(blue?.red ?? 0, 138.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(blue?.green ?? 0, 174.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(blue?.blue ?? 0, 212.0 / 255, accuracy: 0.0001)
    }

    func testProjectWithoutAColorUsesTheDefault() {
        XCTAssertEqual(store().value("alpha"), "")
        XCTAssertNil(store().color("alpha"))
    }

    func testChosenColorIsStoredUnderTheDesktopKey() {
        let appearance = store()
        appearance.set("alpha", "#94b89a")
        XCTAssertEqual(appearance.value("alpha"), "#94b89a")
        XCTAssertNotNil(appearance.color("alpha"))
        XCTAssertEqual(defaults.string(forKey: "orb.projectColor:https://core.example:alpha"), "#94b89a")
        XCTAssertEqual(appearance.value("beta"), "")
    }

    func testDefaultRemovesTheStoredColor() {
        let appearance = store()
        appearance.set("alpha", "#cb929f")
        appearance.set("alpha", "")
        XCTAssertEqual(appearance.value("alpha"), "")
        XCTAssertNil(defaults.object(forKey: "orb.projectColor:https://core.example:alpha"))
    }

    func testValuesOutsideThePaletteAreIgnored() {
        let appearance = store()
        appearance.set("alpha", "#8aaed4")
        appearance.set("alpha", "#ff0000")
        XCTAssertEqual(appearance.value("alpha"), "#8aaed4")
        defaults.set("#ff0000", forKey: "orb.projectColor:https://core.example:alpha")
        XCTAssertEqual(appearance.value("alpha"), "")
        XCTAssertNil(OrbProjectAppearance.components("red"))
    }

    func testColorsAreScopedToTheConnectedBackend() {
        let appearance = store()
        appearance.set("alpha", "#ad9acb")
        endpoint = "https://other.example"
        XCTAssertEqual(appearance.value("alpha"), "")
        endpoint = "https://core.example"
        XCTAssertEqual(appearance.value("alpha"), "#ad9acb")
    }
}
