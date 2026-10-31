import Foundation
import XCTest
@testable import OrbModel

final class OrbModelPackageTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testLoosePipeTablesSharedFixturesIncludingCRLF() throws {
        let url = repoRoot.appendingPathComponent("shared/orb-spec/fixtures/loose-pipe-tables.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 16)
        for item in cases {
            let name = item["name"] as? String ?? "<unnamed>"
            let input = try XCTUnwrap(item["input"] as? String, name)
            let expected = try XCTUnwrap(item["output"] as? String, name)
            let actual = OrbPipeTables.normalize(input)
            XCTAssertEqual(actual, expected, name)
            XCTAssertEqual(OrbPipeTables.normalize(actual), expected, "\(name) idempotence")
        }

        // Regression for Linux Swift 6 where "\r\n" is a single Character grapheme cluster:
        // scalar-level "\n" splitting must normalize CRLF loose-pipe blocks identically to LF.
        let lfDoc = "Intro:\na | b | c\nx | 1 | 2\nOutro."
        let crlfDoc = "Intro:\r\na | b | c\r\nx | 1 | 2\r\nOutro."
        XCTAssertEqual(
            OrbPipeTables.normalize(crlfDoc).replacingOccurrences(of: "\r\n", with: "\n"),
            OrbPipeTables.normalize(lfDoc)
        )
    }

    func testTranscriptGatesMatchLeanFixtures() throws {
        let url = repoRoot.appendingPathComponent("shared/orb-spec/fixtures/transcript-gates.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 60)

        for (idx, item) in cases.enumerated() {
            let op = try XCTUnwrap(item["op"] as? String, "case \(idx)")
            switch op {
            case "allocTurnKeys":
                let rawCands = try XCTUnwrap(item["candidates"] as? [[String: Any]])
                let cands = rawCands.map {
                    OrbTranscriptGates.CandidateKey(
                        tag: $0["tag"] as? Int ?? 0,
                        item: $0["item"] as? Int ?? 0
                    )
                }
                let rawExp = try XCTUnwrap(item["expected"] as? [[String: Any]])
                let expected = rawExp.map {
                    OrbTranscriptGates.TurnKey(
                        tag: $0["tag"] as? Int ?? 0,
                        item: $0["item"] as? Int ?? 0,
                        gen: $0["gen"] as? Int ?? 0
                    )
                }
                let got = OrbTranscriptGates.allocTurnKeys(cands)
                XCTAssertEqual(got, expected, "allocTurnKeys case \(idx)")
                XCTAssertEqual(Set(got).count, got.count, "allocTurnKeys nodup case \(idx)")

            case "latexSpanAdmitted":
                let label = item["name"] as? String ?? "case-\(idx)"
                let got = OrbTranscriptGates.latexSpanAdmitted(
                    len: item["len"] as? Int ?? 0,
                    prevBlocked: item["prevBlocked"] as? Bool ?? false,
                    nextDigit: item["nextDigit"] as? Bool ?? false,
                    leadSpace: item["leadSpace"] as? Bool ?? false,
                    trailSpace: item["trailSpace"] as? Bool ?? false,
                    hasNewline: item["hasNewline"] as? Bool ?? false,
                    firstDigit: item["firstDigit"] as? Bool ?? false,
                    internalSpace: item["internalSpace"] as? Bool ?? false,
                    hasMathOp: item["hasMathOp"] as? Bool ?? false
                )
                XCTAssertEqual(got, item["expected"] as? Bool, label)

            case "windowBudget":
                let total = item["total"] as? Int ?? 0
                let baseLimit = item["baseLimit"] as? Int ?? 24
                let steps = item["expandedSteps"] as? Int ?? 0
                let stepSize = item["stepSize"] as? Int ?? 24
                XCTAssertEqual(
                    OrbTranscriptGates.visibleTurnCount(total: total, baseLimit: baseLimit, expandedSteps: steps, stepSize: stepSize),
                    item["expectedVisible"] as? Int,
                    "windowBudget visible case \(idx)"
                )
                XCTAssertEqual(
                    OrbTranscriptGates.hiddenTurnCount(total: total, baseLimit: baseLimit, expandedSteps: steps, stepSize: stepSize),
                    item["expectedHidden"] as? Int,
                    "windowBudget hidden case \(idx)"
                )

            case "admitMount":
                let res = OrbTranscriptGates.admitMount(
                    active: item["active"] as? Int ?? 0,
                    cap: item["cap"] as? Int ?? 0
                )
                XCTAssertEqual(res.admitted, item["expectedAdmitted"] as? Bool, "admitMount admitted case \(idx)")
                XCTAssertEqual(res.nextActive, item["expectedNextActive"] as? Int, "admitMount nextActive case \(idx)")

            default:
                XCTFail("Unknown transcript-gates op: \(op)")
            }
        }
    }

    func testDeterministicPropertyFuzzPipeTablesAndTurnKeys() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func nextU64() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 0x2545_F491_4F6C_DD1D
        }
        let fragments = [
            "colA | colB | colC",
            "🔹 | 12 | 3.5%",
            "alpha | beta | 42",
            "```",
            "~~~",
            "| gfm | 1 |",
            "`a | b` | x | 9",
            "",
            "$15 and $20"
        ]
        let keyPool = ["", "turn-0-user", "turn-0-user#1", "cloud:u", "cloud:a", "optimistic-user", "seq-7"]

        for seed in 0..<500 {
            let lineCount = Int(nextU64() % 12)
            let sep = (nextU64() & 1) == 0 ? "\n" : "\r\n"
            var lines: [String] = []
            for _ in 0..<lineCount {
                lines.append(fragments[Int(nextU64() % UInt64(fragments.count))])
            }
            let doc = lines.joined(separator: sep)
            let once = OrbPipeTables.normalize(doc)
            let twice = OrbPipeTables.normalize(once)
            XCTAssertEqual(twice, once, "normalize idempotence failed at seed \(seed)")

            let idCount = Int(nextU64() % 32)
            var rawIds: [String] = []
            var cands: [OrbTranscriptGates.CandidateKey] = []
            for _ in 0..<idCount {
                rawIds.append(keyPool[Int(nextU64() % UInt64(keyPool.count))])
                cands.append(OrbTranscriptGates.CandidateKey(tag: Int(nextU64() % 4), item: Int(nextU64() % 6)))
            }
            let uniqueStrings = OrbTranscriptGates.ensureUniqueIds(rawIds)
            XCTAssertEqual(uniqueStrings.count, rawIds.count)
            XCTAssertEqual(Set(uniqueStrings).count, uniqueStrings.count, "duplicate string ID at seed \(seed)")
            XCTAssertTrue(uniqueStrings.allSatisfy { !$0.isEmpty })

            let uniqueKeys = OrbTranscriptGates.allocTurnKeys(cands)
            XCTAssertEqual(uniqueKeys.count, cands.count)
            XCTAssertEqual(Set(uniqueKeys).count, uniqueKeys.count, "duplicate TurnKey at seed \(seed)")
        }
    }
}
