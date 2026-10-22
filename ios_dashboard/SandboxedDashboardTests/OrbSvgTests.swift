import XCTest
@testable import sandboxed_sh

/// Agent SVGs (shared/orb-spec/svg-images.json; Android runs the same spec in OrbSvgTest).
final class OrbSvgTests: XCTestCase {
    func testAspectRatioMatchesSharedSpec() throws {
        let spec = try OrbSpec.json("svg-images.json")
        XCTAssertEqual(spec["limit_bytes"] as? Int, OrbSvg.limit)
        let cases = try XCTUnwrap(spec["aspect"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for entry in cases {
            let name = entry["name"] as? String ?? "?"
            let ratio = OrbSvg.aspectRatio(try XCTUnwrap(entry["svg"] as? String))
            if let want = entry["ratio"] as? Double { XCTAssertEqual(try XCTUnwrap(ratio, name), want, accuracy: 0.0001, name) }
            else { XCTAssertNil(ratio, name) }
        }
    }

    func testHostileSvgIsOnlyEverAnInlineImage() {
        let hostile = Data(#"<svg xmlns="http://www.w3.org/2000/svg" onload="fetch('https://evil.test')"><script>alert(1)</script><image href="https://evil.test/x.png"/></svg>"#.utf8)
        let html = OrbSvg.html(hostile)
        XCTAssertTrue(html.contains("default-src 'none'; img-src data:"))
        XCTAssertTrue(html.contains("<img alt=\"\" src=\"data:image/svg+xml;base64,\(hostile.base64EncodedString())\">"))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("evil.test"))
    }

    func testReadRefusesOversizedOrBinaryFiles() throws {
        let dir = FileManager.default.temporaryDirectory
        let small = dir.appendingPathComponent("orb-svg-small.svg"), big = dir.appendingPathComponent("orb-svg-big.svg"), binary = dir.appendingPathComponent("orb-svg-bin.svg")
        defer { [small, big, binary].forEach { try? FileManager.default.removeItem(at: $0) } }
        try Data("<svg/>".utf8).write(to: small)
        try Data(count: OrbSvg.limit + 1).write(to: big)
        try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: binary)
        XCTAssertEqual(OrbSvg.read(small), Data("<svg/>".utf8))
        XCTAssertNil(OrbSvg.read(big))
        XCTAssertNil(OrbSvg.read(binary))
        XCTAssertEqual(OrbFileKind.of("logos/svg/maxwell.svg"), .svg)
    }
}
