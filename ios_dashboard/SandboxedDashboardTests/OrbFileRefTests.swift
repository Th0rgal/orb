import XCTest
@testable import sandboxed_sh

/// Shared-file markup (shared/orb-spec/file-references.json, real prod samples; Android
/// runs the same spec in OrbFileRefsTest).
final class OrbFileRefTests: XCTestCase {
    private func spec() throws -> [String: Any] { try OrbSpec.json("file-references.json") }

    func testParsesProdMarkupSamples() throws {
        let cases = try XCTUnwrap(spec()["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for entry in cases {
            let name = entry["name"] as? String ?? "?"
            let input = try XCTUnwrap(entry["input"] as? String)
            let expected = try XCTUnwrap(entry["refs"] as? [[String: String]])
            let refs = OrbFileRefs.refs(input)
            XCTAssertEqual(refs.count, expected.count, name)
            for (ref, want) in zip(refs, expected) {
                XCTAssertEqual(ref.type, want["type"], name)
                XCTAssertEqual(ref.path, want["path"], name)
                XCTAssertEqual(ref.label, want["label"], name)
                XCTAssertEqual(ref.mime, want["mime"], name)
            }
            XCTAssertEqual(OrbFileRefs.plainText(input), entry["text"] as? String, name)
            XCTAssertFalse(OrbFileRefs.segments(input).contains { if case .text(let t) = $0 { t.contains("<file path") && !t.contains("```") } else { false } },
                           "\(name): no raw tag reaches the Markdown renderer")
        }
    }

    func testFileKindsMatchSpec() throws {
        let kinds = try XCTUnwrap(spec()["kinds"] as? [String: String])
        for (name, kind) in kinds { XCTAssertEqual(OrbFileKind.of(name).rawValue, kind, name) }
        XCTAssertEqual(OrbFileKind.of("download", mime: "application/pdf"), .pdf)
    }

    func testSharedFilesMetadataEnrichesTag() throws {
        let shared = try XCTUnwrap(spec()["sharedFiles"] as? [String: Any])
        let files = OrbFileRefs.sharedFiles(["shared_files": shared["metadata"] as Any])
        XCTAssertEqual(files.count, 1)
        let expect = try XCTUnwrap(shared["expect"] as? [String: Any])
        let ref = try XCTUnwrap(OrbFileRefs.refs(try XCTUnwrap(shared["content"] as? String)).first)
        let enriched = OrbFileRefs.enrich(ref, shared: files)
        XCTAssertEqual(enriched.path, expect["path"] as? String)
        XCTAssertEqual(enriched.size, (expect["size"] as? NSNumber)?.int64Value)
        XCTAssertNotNil(enriched.url)
        XCTAssertTrue(files[0].sourcePath?.hasSuffix("/mission-abf62858/pr31-receipt-refresh2.patch") == true)
    }

    func testCollectIsNewestFirstAndDeduplicated() {
        let messages = [
            OrbFileRefs.Message(content: "<file path=\"./a.txt\" name=\"Old A\" />", shared: [], at: "2026-10-01T10:00:00Z", sequence: 1),
            OrbFileRefs.Message(content: "<image path=\"./chart.png\" alt=\"Chart\" />\n<file path=\"a.txt\" name=\"New A\" />", shared: [], at: "2026-10-02T10:00:00Z", sequence: 5),
            OrbFileRefs.Message(content: "No tag here.", shared: [OrbSharedFile(name: "out.zip", size: 10, url: "/api/fs/download?path=%2Fw%2Fout.zip", contentType: nil)], at: "2026-10-03T10:00:00Z", sequence: 9)
        ]
        let files = OrbFileRefs.collect(messages)
        XCTAssertEqual(files.map(\.name), ["out.zip", "chart.png", "a.txt"])
        XCTAssertEqual(files.last?.label, "New A", "the newest share of a path wins")
        XCTAssertEqual(files.first?.path, "/w/out.zip")
        XCTAssertEqual(files.first?.size, 10)
    }

    func testStreamingHidesUnfinishedTag() {
        let segments = OrbFileRefs.segments("Here it is:\n\n<file path=\"./rep", streaming: true)
        XCTAssertEqual(segments, [.text("Here it is:")])
    }

    func testEventsJSONShapes() {
        let row: OrbJSON = .object(["event_type": .string("assistant_message"), "content": .string("<file path=\"x.pdf\" />"), "timestamp": .string("t"), "sequence": .number(3),
                                    "metadata": .object(["shared_files": .array([.object(["name": .string("x.pdf"), "size_bytes": .number(2048), "url": .string("/api/fs/download?path=%2Fx.pdf")])])])])
        for json in [OrbJSON.array([row]), .object(["events": .array([row])])] {
            let files = OrbFileRefs.collect(OrbFileRefs.messages(json))
            XCTAssertEqual(files.count, 1)
            XCTAssertEqual(files.first?.size, 2048)
        }
    }

    func testErrorsMapToActionableCauses() {
        XCTAssertEqual(OrbFileError.from(status: 502, body: "Remote file source is unreachable", name: "a"), .machineOffline)
        XCTAssertEqual(OrbFileError.from(status: 409, body: "Remote file source is unavailable", name: "a"), .machineOffline)
        XCTAssertEqual(OrbFileError.from(status: 404, body: "", name: "a"), .notFound("a"))
        XCTAssertEqual(OrbFileError.from(status: 401, body: "", name: "a"), .unauthorized)
        XCTAssertEqual(OrbFileError.from(URLError(.notConnectedToInternet), name: "a"), .offline)
    }

    func testHighlighterAndCSV() {
        let tokens = OrbCodeHighlight.tokens("let x = \"hi\" // note\n", language: "swift")
        XCTAssertEqual(tokens.map(\.1), [.keyword, .string, .comment])
        XCTAssertEqual(OrbCodeHighlight.tokens("# c\nx = 1", language: "py").map(\.1), [.comment, .number])
        XCTAssertEqual(OrbCodeHighlight.tokens("+a\n-b\n", language: "diff").map(\.1), [.added, .removed])
        XCTAssertEqual(OrbCSV.parse("a,b\n\"x, y\",\"say \"\"hi\"\"\"\n"), [["a", "b"], ["x, y", "say \"hi\""]])
        XCTAssertEqual(OrbCSV.parse("a\tb\n1\t2", delimiter: "\t"), [["a", "b"], ["1", "2"]])
    }
}
