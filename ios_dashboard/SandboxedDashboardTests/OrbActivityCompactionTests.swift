import XCTest
@testable import sandboxed_sh

final class OrbActivityCompactionTests: XCTestCase {
    func testPrivilegeCommandCoalescingMatchesSharedSpec() throws {
        let spec = try OrbSpec.json("fixtures/mobile-debloat.json")
        for c in try XCTUnwrap(spec["privilege_commands"] as? [[String: Any]]) {
            let name = c["name"] as? String ?? "?"
            let rawInput = try JSONSerialization.data(withJSONObject: c["input"] ?? [])
            let commands = try JSONDecoder().decode([OrbJSON].self, from: rawInput)
            let got = OrbActivityCompaction.coalescePrivilegeCommands(commands)
            let expected = try XCTUnwrap(c["expected"] as? [[String: Any]])
            XCTAssertEqual(got.count, expected.count, name)
            for (item, exp) in zip(got, expected) {
                XCTAssertEqual(item.id, exp["id"] as? String, name)
                XCTAssertEqual(item.status, exp["status"] as? String, name)
                XCTAssertEqual(item.host, exp["host"] as? String, name)
                XCTAssertEqual(item.command, exp["command"] as? String, name)
            }
        }
    }

    func testErrorCoalescingMatchesSharedSpec() throws {
        let spec = try OrbSpec.json("fixtures/mobile-debloat.json")
        for c in try XCTUnwrap(spec["error_coalescing"] as? [[String: Any]]) {
            let name = c["name"] as? String ?? "?"
            let input = try XCTUnwrap(c["input"] as? [[String: Any]]).map {
                OrbActivityCompaction.ErrorInput(
                    category: $0["category"] as? String ?? "",
                    summary: $0["summary"] as? String ?? "",
                    detail: $0["detail"] as? String ?? "",
                    at: ($0["at"] as? NSNumber)?.doubleValue ?? 0
                )
            }
            let got = OrbActivityCompaction.coalesceErrors(input)
            let expected = try XCTUnwrap(c["expected"] as? [[String: Any]])
            XCTAssertEqual(got.count, expected.count, name)
            for (item, exp) in zip(got, expected) {
                XCTAssertEqual(item.category, exp["category"] as? String, name)
                XCTAssertEqual(item.summary, exp["summary"] as? String, name)
                XCTAssertEqual(item.count, exp["count"] as? Int, name)
                XCTAssertEqual(item.at, (exp["at"] as? NSNumber)?.doubleValue, name)
            }
        }
    }

    func testGrantDeduplicationMatchesSharedSpec() throws {
        let spec = try OrbSpec.json("fixtures/mobile-debloat.json")
        for c in try XCTUnwrap(spec["grant_deduplication"] as? [[String: Any]]) {
            let name = c["name"] as? String ?? "?"
            let rawInput = try JSONSerialization.data(withJSONObject: c["input"] ?? [])
            let grants = try JSONDecoder().decode([OrbJSON].self, from: rawInput)
            let got = OrbActivityCompaction.dedupeMissionGrants(grants)
            XCTAssertEqual(got.map { $0["id"].text }, c["expected_ids"] as? [String], name)
        }
    }

    func testCooldownFormatMatchesSharedSpec() throws {
        let spec = try OrbSpec.json("fixtures/mobile-debloat.json")
        for c in try XCTUnwrap(spec["cooldown_format"] as? [[String: Any]]) {
            let secs = try XCTUnwrap(c["seconds"] as? Int)
            XCTAssertEqual(OrbActivityCompaction.formatCooldown(secs), c["expected"] as? String)
        }
    }

    func testInboxPreviewSanitizationMatchesSharedSpec() throws {
        let spec = try OrbSpec.json("fixtures/mobile-debloat.json")
        for c in try XCTUnwrap(spec["inbox_preview"] as? [[String: Any]]) {
            let input = try XCTUnwrap(c["input"] as? String)
            XCTAssertEqual(OrbActivityCompaction.cleanInboxPreview(input), c["expected"] as? String, c["name"] as? String ?? "?")
        }
    }

    func testPlaceholderTurnsAndCanonicalUUIDMatchSharedSpec() throws {
        let spec = try OrbSpec.json("fixtures/mobile-debloat.json")
        for c in try XCTUnwrap(spec["placeholder_turns"] as? [[String: Any]]) {
            let text = try XCTUnwrap(c["text"] as? String)
            XCTAssertEqual(OrbActivityCompaction.isPlaceholderTurn(text), c["expected"] as? Bool, "placeholder: \(text)")
        }
        for c in try XCTUnwrap(spec["canonical_uuid"] as? [[String: Any]]) {
            let id = try XCTUnwrap(c["id"] as? String)
            XCTAssertEqual(OrbActivityCompaction.isCanonicalUUID(id), c["expected"] as? Bool, "uuid: \(id)")
        }
    }
}
