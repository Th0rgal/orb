import XCTest
@testable import sandboxed_sh

/// Replays shared/orb-spec/fixtures/loose-pipe-tables.json (desktop: orb/tests/pipe-tables.test.tsx).
final class OrbPipeTablesTests: XCTestCase {
    private func cases() throws -> [[String: String]] {
        try XCTUnwrap(OrbSpec.json("fixtures/loose-pipe-tables.json")["cases"] as? [[String: String]])
    }
    private func input(_ prefix: String) throws -> String {
        try XCTUnwrap(cases().first { $0["name"]!.hasPrefix(prefix) }?["input"])
    }

    func testSharedFixtures() throws {
        for c in try cases() {
            let name = c["name"]!, output = c["output"]!
            XCTAssertEqual(OrbPipeTables.normalize(c["input"]!), output, name)
            XCTAssertEqual(OrbPipeTables.normalize(output), output, "\(name) is idempotent")
        }
    }

    func testProdUsageReplyParsesAsRightAlignedTable() throws {
        let blocks = OrbNativeMarkdownView.parseBlocks(try input("prod 55518e2b"))
        XCTAssertEqual(blocks.count, 2)
        guard case .table(let headers, let rows, let right) = blocks[1] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(headers, ["modèle", "input", "output", "cache read", "cache write", "USD", "appels"])
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0][1], "3 915 038 024")
        XCTAssertEqual(right, [false, true, true, true, true, true, true])
    }

    func testHeaderlessAndUntouchedCases() throws {
        guard case .table(let headers, let rows, _) = OrbNativeMarkdownView.parseBlocks(try input("headerless"))[1] else { return XCTFail() }
        XCTAssertTrue(headers.allSatisfy(\.isEmpty))
        XCTAssertEqual(rows.count, 2)
        for name in ["mixed column", "single line", "pipes inside code fences", "GFM table is unchanged"] {
            let text = try input(name)
            XCTAssertEqual(OrbPipeTables.normalize(text), text, name)
        }
    }

    func testStreamingNeverDropsATableOnceShown() throws {
        let text = try input("prod 55518e2b")
        var seen = false
        var prefix = ""
        for ch in text {
            prefix.append(ch)
            let tables = OrbNativeMarkdownView.parseBlocks(prefix).filter { if case .table = $0 { return true }; return false }
            if seen { XCTAssertEqual(tables.count, 1, prefix) }
            if !tables.isEmpty { seen = true }
        }
        XCTAssertTrue(seen)
    }
}
