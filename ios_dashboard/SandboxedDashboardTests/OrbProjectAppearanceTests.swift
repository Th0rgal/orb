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
        sent = []
        failure = nil
    }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }
    /// Color writes the store sent to the server, as (slug, palette name or nil).
    private var sent: [[String?]] = []
    /// What the server answers to a color write; nil accepts it.
    private var failure: Error?
    private func store() -> OrbProjectAppearance {
        OrbProjectAppearance(defaults: defaults, endpoint: { [unowned self] in endpoint }, send: { [unowned self] slug, color in
            sent.append([slug, color])
            if let failure { throw failure }
        })
    }
    private func row(_ slug: String, _ color: OrbJSON? = nil) -> OrbJSON {
        var fields: [String: OrbJSON] = ["slug": .string(slug), "status": .string("active")]
        if let color { fields["color"] = color }
        return .object(fields)
    }
    private var later: Date { Date().addingTimeInterval(1) }
    private let colorKey = "orb.projectColor:https://core.example:alpha"
    private let syncKey = "orb.projectColorSync:https://core.example:alpha"

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

    func testWireNamesAreThePaletteNamesInLowercase() {
        XCTAssertEqual(OrbProjectAppearance.colors.map { OrbProjectAppearance.wireName($0.value) }, [nil, "blue", "green", "amber", "rose", "purple"])
        XCTAssertEqual(OrbProjectAppearance.value(wireName: "rose"), "#cb929f")
        XCTAssertEqual(OrbProjectAppearance.value(wireName: " Blue "), "#8aaed4")
        XCTAssertNil(OrbProjectAppearance.value(wireName: "teal"))
        XCTAssertNil(OrbProjectAppearance.value(wireName: "default"))
        XCTAssertNil(OrbProjectAppearance.value(wireName: ""))
    }

    func testAChangeIsWrittenToTheServerAndAResetAsNull() async {
        let appearance = store()
        appearance.set("alpha", "#94b89a")
        await appearance.settle()
        appearance.set("alpha", "")
        await appearance.settle()
        XCTAssertEqual(sent, [["alpha", "green"], ["alpha", nil]])
        XCTAssertEqual(defaults.string(forKey: syncKey), "1")
    }

    func testTheServerColorWinsOverTheLocalOne() async {
        defaults.set("#8aaed4", forKey: colorKey)
        defaults.set("1", forKey: syncKey)
        let appearance = store()
        await appearance.apply(roster: [row("alpha", .string("rose")), row("beta", .string("purple"))], fetchedAt: later)
        XCTAssertEqual(appearance.value("alpha"), "#cb929f")
        XCTAssertEqual(appearance.value("beta"), "#ad9acb")
        XCTAssertEqual(sent, [])
    }

    func testAColorChosenBeforeTheServerStoredAnyIsUploadedOnce() async {
        defaults.set("#8aaed4", forKey: colorKey)
        let appearance = store()
        await appearance.apply(roster: [row("alpha", .null)], fetchedAt: later)
        XCTAssertEqual(appearance.value("alpha"), "#8aaed4")
        XCTAssertEqual(sent, [["alpha", "blue"]])
        // Another device cleared it afterwards: the server's "none" now wins.
        await appearance.apply(roster: [row("alpha", .null)], fetchedAt: later)
        XCTAssertEqual(appearance.value("alpha"), "")
        XCTAssertEqual(sent.count, 1)
    }

    func testALocalColorIsNotUploadedOverTheServerColor() async {
        defaults.set("#8aaed4", forKey: colorKey)
        let appearance = store()
        await appearance.apply(roster: [row("alpha", .string("green"))], fetchedAt: later)
        XCTAssertEqual(appearance.value("alpha"), "#94b89a")
        XCTAssertEqual(sent, [])
    }

    func testABackendWithoutTheFieldKeepsTheLocalColor() async {
        defaults.set("#8aaed4", forKey: colorKey)
        let appearance = store()
        await appearance.apply(roster: [row("alpha")], fetchedAt: later)
        XCTAssertEqual(appearance.value("alpha"), "#8aaed4")
        XCTAssertFalse(appearance.synced)
        appearance.set("alpha", "#ad9acb")
        await appearance.settle()
        XCTAssertEqual(appearance.value("alpha"), "#ad9acb")
        XCTAssertEqual(sent, [])
    }

    func testABackendWithoutTheEndpointKeepsTheLocalColor() async {
        failure = OrbHTTPError(status: 404, detail: "Not Found")
        let appearance = store()
        appearance.set("alpha", "#8aaed4")
        await appearance.settle()
        XCTAssertEqual(appearance.value("alpha"), "#8aaed4")
        XCTAssertEqual(sent.count, 1)
    }

    func testAChangeThatFailedIsSentAgainWithTheNextRoster() async {
        failure = URLError(.notConnectedToInternet)
        let appearance = store()
        appearance.set("alpha", "#8aaed4")
        await appearance.settle()
        failure = nil
        // The server still has the old color: the unsent local change is not lost.
        await appearance.apply(roster: [row("alpha", .string("rose"))], fetchedAt: later)
        XCTAssertEqual(appearance.value("alpha"), "#8aaed4")
        XCTAssertEqual(sent, [["alpha", "blue"], ["alpha", "blue"]])
        await appearance.apply(roster: [row("alpha", .string("blue"))], fetchedAt: later)
        XCTAssertEqual(sent.count, 2)
    }

    func testARosterRequestedBeforeTheChangeIsIgnored() async {
        let before = Date().addingTimeInterval(-1)
        let appearance = store()
        appearance.set("alpha", "#8aaed4")
        await appearance.settle()
        await appearance.apply(roster: [row("alpha", .string("rose"))], fetchedAt: before)
        XCTAssertEqual(appearance.value("alpha"), "#8aaed4")
    }

    func testAnUnknownServerColorLeavesTheLocalOne() async {
        defaults.set("#8aaed4", forKey: colorKey)
        let appearance = store()
        await appearance.apply(roster: [row("alpha", .string("teal"))], fetchedAt: later)
        XCTAssertEqual(appearance.value("alpha"), "#8aaed4")
        XCTAssertEqual(sent, [])
        XCTAssertTrue(appearance.synced)
    }
}
