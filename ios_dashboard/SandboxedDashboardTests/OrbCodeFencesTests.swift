import XCTest
@testable import sandboxed_sh

/// Replays shared/orb-spec/fixtures/glued-code-fences.json (desktop: orb/tests/code-fences.test.tsx).
@MainActor
final class OrbCodeFencesTests: XCTestCase {
    private func cases() throws -> [[String: String]] {
        try XCTUnwrap(OrbSpec.json("fixtures/glued-code-fences.json")["cases"] as? [[String: String]])
    }

    private func input(_ prefix: String) throws -> String {
        try XCTUnwrap(cases().first { $0["name"]!.hasPrefix(prefix) }?["input"])
    }

    func testSharedFixtures() throws {
        for c in try cases() {
            let name = c["name"]!, output = c["output"]!
            XCTAssertEqual(OrbCodeFences.normalize(c["input"]!), output, name)
            XCTAssertEqual(OrbCodeFences.normalize(output), output, "\(name) is idempotent")
        }
    }

    func testProdBtwReplySplitsMermaidAndPreservesTrailingSummary() throws {
        let blocks = OrbNativeMarkdownView.parseBlocks(try input("prod c7a89ff3 seq 219"))
        let suffix = Array(blocks.suffix(4))
        XCTAssertEqual(suffix.count, 4)

        guard case .paragraph(let intro) = suffix[0] else {
            return XCTFail("expected intro paragraph, got \(suffix[0])")
        }
        XCTAssertTrue(intro.hasSuffix("Let's present the updated diagram cleanly!"))
        XCTAssertFalse(intro.contains("```mermaid"))

        guard case .mermaid(let code, let complete) = suffix[1] else {
            return XCTFail("expected complete mermaid block, got \(suffix[1])")
        }
        XCTAssertTrue(complete)
        XCTAssertTrue(code.contains("flowchart TD"))
        XCTAssertTrue(code.contains("Z[\"Final certificate\"]"))

        guard case .paragraph(let summary) = suffix[2] else {
            return XCTFail("expected trailing summary paragraph, got \(suffix[2])")
        }
        XCTAssertEqual(summary, "Changes at `HEAD` (`fc02f3ccc`):")

        guard case .list(let ordered, let items) = suffix[3] else {
            return XCTFail("expected trailing bullet list, got \(suffix[3])")
        }
        XCTAssertFalse(ordered)
        XCTAssertEqual(items.count, 3)
    }

    func testIncrementalStreamingMatchesFullParseOnAllGluedCases() throws {
        for c in try cases() {
            let doc = c["input"]!, name = c["name"]!
            for stride in [1, 3, 7] {
                let parser = OrbStreamBlocks()
                var shown = ""
                var rest = Substring(doc)
                while !rest.isEmpty {
                    shown += rest.prefix(stride)
                    rest = rest.dropFirst(stride)
                    XCTAssertEqual(
                        parser.blocks(shown),
                        OrbNativeMarkdownView.parseBlocks(shown),
                        "\(name) stride \(stride): \(shown.debugDescription)"
                    )
                }
            }
        }
    }

    func testLargeGluedFenceStreamsInLinearCostAndMatchesFullParse() {
        let parser = OrbStreamBlocks()
        var acc = ""
        acc.reserveCapacity(64 * 1024 + 512)
        var lastBlocks: [OrbNativeMarkdownView.Block] = []
        for k in 0..<64 {
            var chunk = k == 0 ? "Updated diagram cleanly!```mermaid\nflowchart TD\n" : ""
            var li = 0
            while chunk.utf8.count < 1024 {
                chunk += "  N\(k)_\(li) --> M\(k)_\(li)\n"
                li += 1
            }
            let sliceIdx = chunk.utf8.index(chunk.utf8.startIndex, offsetBy: 1024)
            acc += String(Substring(chunk.utf8[..<sliceIdx]))
            lastBlocks = parser.blocks(acc)
        }
        let openBytes = acc.utf8.count
        XCTAssertLessThanOrEqual(parser.scannedBytes, openBytes)
        XCTAssertLessThanOrEqual(parser.parsedBytes, openBytes * 2)
        XCTAssertEqual(lastBlocks, OrbNativeMarkdownView.parseBlocks(acc))

        acc += "\n```\n\nChanges at HEAD:\n- Done\n\n"
        let closedBlocks = parser.blocks(acc)
        XCTAssertEqual(closedBlocks, OrbNativeMarkdownView.parseBlocks(acc))
    }

    func testPipesInsideGluedFenceAreNotRewrittenAsLooseTable() throws {
        let blocks = OrbNativeMarkdownView.parseBlocks(try input("pipes inside a glued code fence"))
        XCTAssertEqual(blocks, [
            .paragraph("Raw log:"),
            .code(language: "text", code: "a | b | c\nd | e | f"),
            .paragraph("Summary."),
        ])
    }

    func testInlinePreviewCutsBeforeGluedFence() {
        let src = "Let's present the updated diagram cleanly!```mermaid\nflowchart TD\n  A --> B\n  B --> C\n```\n"
        XCTAssertEqual(OrbNativeMarkdownView.inlinePreview(src, limit: 65), "Let's present the updated diagram cleanly!")
    }
}
