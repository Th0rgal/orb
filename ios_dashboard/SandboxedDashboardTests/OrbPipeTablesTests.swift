import XCTest
@testable import sandboxed_sh

/// Replays shared/orb-spec/fixtures/loose-pipe-tables.json (desktop: orb/tests/pipe-tables.test.tsx).
@MainActor
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

    func testNegativeRowOffsetIsRejected() {
        XCTAssertTrue(OrbKernel.gfmPipeRowAdmitted(rowOff: 0, rowLen: 12, bufLen: 12, colCount: 3, sepCols: 3))
        XCTAssertFalse(OrbKernel.gfmPipeRowAdmitted(rowOff: -1, rowLen: 12, bufLen: 12, colCount: 3, sepCols: 3))
        XCTAssertFalse(OrbKernel.gfmPipeRowAdmitted(rowOff: 4, rowLen: 12, bufLen: 12, colCount: 3, sepCols: 3))
    }

    func testTablesAreCappedAt64Columns() {
        XCTAssertFalse(OrbKernel.gfmPipeRowAdmitted(rowOff: 0, rowLen: 200, bufLen: 200, colCount: 65, sepCols: 65))
        let wide = { (n: Int) in (0..<n).map { "c\($0)" }.joined(separator: " | ") }
        let src65 = "\(wide(65))\n\(wide(65))"
        XCTAssertEqual(OrbPipeTables.normalize(src65), src65)
        XCTAssertTrue(OrbPipeTables.normalize("\(wide(64))\n\(wide(64))").contains("| --- |"))
    }

    func testTagKind4IsRejected() {
        XCTAssertTrue(OrbKernel.richTagAdmitted(tagOff: 0, tagLen: 24, attrOff: 5, attrLen: 14, bufLen: 24, tagKind: 3))
        XCTAssertFalse(OrbKernel.richTagAdmitted(tagOff: 0, tagLen: 24, attrOff: 5, attrLen: 14, bufLen: 24, tagKind: 4))
    }

    func testUtilizationOver100HidesThePercentage() {
        let over = OrbKernel.usageLimitBadge(status: "allowed_warning", claim: "five_hour", hasUtilization: true, utilizationPct: 150, hasReset: false, resetRemSecs: 0)
        XCTAssertEqual(over?.label, "Approaching limit · 5h")
        let full = OrbKernel.usageLimitBadge(status: "allowed_warning", claim: "five_hour", hasUtilization: true, utilizationPct: 100, hasReset: false, resetRemSecs: 0)
        XCTAssertEqual(full?.label, "Approaching limit · 5h 100%")
    }

    func testWrappingDeltaSaturates() {
        let next = OrbKernel.transcriptPatchStep(stateLen: 0xFFFF_FFF0, stateSeq: 7, eventKind: 0, deltaLen: 0x20)
        XCTAssertEqual(next.len, UInt32.max)
        XCTAssertEqual(next.seq, 8)
    }

    func testUnknownEventKindLeavesStateUnchanged() {
        let next = OrbKernel.transcriptPatchStep(stateLen: 42, stateSeq: 9, eventKind: 3, deltaLen: 100)
        XCTAssertEqual(next.len, 42)
        XCTAssertEqual(next.seq, 9)
    }

    func testWave7NativeCAbiDomainGatesAndSteppers() {
        XCTAssertEqual(OrbKernel.scrollMaxTop(content: 4442, viewport: 625), 3817)
        XCTAssertEqual(OrbKernel.scrollGap(content: 4442, viewport: 625, top: 3716), 101)
        XCTAssertFalse(OrbKernel.scrollShowsJump(pinned: false, content: 4442, viewport: 625, top: 3716, pillThreshold: 160))
        XCTAssertTrue(OrbKernel.scrollShowsJump(pinned: false, content: 4442, viewport: 625, top: 2116, pillThreshold: 160))

        let idleFrame = OrbKernel.streamCoalescerStep(opKind: 1, shownLen: 10, pendingLen: 0, deltaLen: 0)
        XCTAssertEqual(idleFrame.shownLen, 10)
        XCTAssertFalse(idleFrame.rendered)
        let activeFrame = OrbKernel.streamCoalescerStep(opKind: 1, shownLen: 10, pendingLen: 4, deltaLen: 0)
        XCTAssertEqual(activeFrame.shownLen, 14)
        XCTAssertTrue(activeFrame.rendered)

        XCTAssertEqual(OrbKernel.missionSortRank(11), 0)
        XCTAssertEqual(OrbKernel.missionSortRank(16), 1)
        XCTAssertEqual(OrbKernel.missionSortRank(17), 2)
        XCTAssertEqual(OrbKernel.missionSortRank(99), 9)
        XCTAssertEqual(OrbKernel.missionInboxSection(22), 2)
        XCTAssertEqual(OrbKernel.missionInboxSection(23), 3)

        let spanOk = OrbFileRefs.validLineSpan(startLine: 10, endLine: 15, totalLines: 20)
        XCTAssertTrue(spanOk.admitted)
        XCTAssertEqual(spanOk.count, 6)
        XCTAssertFalse(OrbFileRefs.validLineSpan(startLine: 15, endLine: 10, totalLines: 20).admitted)

        XCTAssertTrue(OrbKernel.verifyIosJetsamBudget(dirtyRssBytes: 100_000_000, allocBytes: 16_384, maxJetsamBytes: 1_400_000_000))
        XCTAssertTrue(OrbKernel.verifyWorkerBudget(activeWorkers: 4, maxWorkers: 6, microChunks: 8, totalLen: 4096))
    }
}
