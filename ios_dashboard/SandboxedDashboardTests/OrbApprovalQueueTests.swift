import XCTest
@testable import sandboxed_sh

/// The approval queue labels, summarizes and signs exactly like desktop and
/// Android, via shared/orb-spec/fixtures/approvals.json.
@MainActor
final class OrbApprovalQueueTests: XCTestCase {
    private func json(_ any: Any) throws -> OrbJSON {
        try JSONDecoder().decode(OrbJSON.self, from: JSONSerialization.data(withJSONObject: any))
    }

    private func item(_ label: [String: Any], _ n: Int) throws -> OrbJSON {
        var i = try XCTUnwrap(label["item"] as? [String: Any])
        i["id"] = "i\(n)"
        i["digest"] = "d\(n)"
        return try json(i)
    }

    func testLabelsMatchSharedFixture() throws {
        let spec = try OrbSpec.json("fixtures/approvals.json")
        let labels = try XCTUnwrap(spec["labels"] as? [[String: Any]])
        XCTAssertFalse(labels.isEmpty)
        for (n, c) in labels.enumerated() {
            let i = try item(c, n)
            XCTAssertEqual(OrbApprovalQueue.title(i), c["title"] as? String)
            XCTAssertEqual(OrbApprovalQueue.requester(i), c["requester"] as? String)
            XCTAssertEqual(OrbApprovalQueue.detail(i), c["detail"] as? String)
        }
    }

    func testSummaryAndCriticalExclusionMatchSharedFixture() throws {
        let spec = try OrbSpec.json("fixtures/approvals.json")
        let labels = try XCTUnwrap(spec["labels"] as? [[String: Any]])
        let summaries = try XCTUnwrap(spec["summaries"] as? [[String: Any]])
        for s in summaries {
            let idx = try XCTUnwrap(s["items"] as? [Int])
            let items = try idx.enumerated().map { n, k in try item(labels[k], n) }
            let got = OrbApprovalQueue.summary(items)
            XCTAssertEqual(got.risks, s["risks"] as? String)
            XCTAssertEqual(got.missions, s["missions"] as? String)
            XCTAssertEqual(OrbApprovalQueue.batchApprovable(items, includeCritical: false).count, s["without_critical"] as? Int)
            XCTAssertEqual(OrbApprovalQueue.batchApprovable(items, includeCritical: true).count, items.count)
        }
    }

    func testSignsKindIdAndDigestAndConfirmsCriticalOnlyWhenListed() throws {
        let labels = try XCTUnwrap(try OrbSpec.json("fixtures/approvals.json")["labels"] as? [[String: Any]])
        let deploy = try item(labels[0], 0), root = try item(labels[1], 1), read = try item(labels[2], 2)
        let body = OrbApprovalQueue.batchBody([deploy, read])
        XCTAssertEqual(body["confirm_critical"], .bool(false))
        XCTAssertEqual(body["items"], .array([
            .object(["kind": .string("privilege"), "id": .string("i0"), "digest": .string("d0")]),
            .object(["kind": .string("secret"), "id": .string("i2"), "digest": .string("d2")]),
        ]))
        XCTAssertEqual(OrbApprovalQueue.batchBody([root])["confirm_critical"], .bool(true))
        XCTAssertEqual(
            OrbApprovalQueue.signingReason([deploy, try item(labels[9], 9), read]),
            "Approve 3 requests (1 critical · 1 elevated · 1 routine): Move OLD_TOKEN; Service deploy on agent-core; Read OPENAI_API_KEY"
        )
    }

    func testDeniesThroughEachKindsRoute() throws {
        let labels = try XCTUnwrap(try OrbSpec.json("fixtures/approvals.json")["labels"] as? [[String: Any]])
        XCTAssertEqual(OrbApprovalQueue.denyPath(try item(labels[0], 0)), "/api/privilege-access/i0/deny")
        XCTAssertEqual(OrbApprovalQueue.denyPath(try item(labels[2], 2)), "/api/bitwarden/requests/i2/reject")
        XCTAssertEqual(OrbApprovalQueue.denyPath(try item(labels[7], 7)), "/api/mission-access/i7/deny")
    }
}
