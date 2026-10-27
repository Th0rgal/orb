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

    func testRiskMatchesCoreRiskTable() throws {
        let risks = try XCTUnwrap(try OrbSpec.json("fixtures/approvals.json")["risk"] as? [[String: Any]])
        for c in risks {
            let request = try json(["all_projects": (c["all_projects"] as? Bool) ?? false])
            XCTAssertEqual(OrbApprovalQueue.riskOf(kind: c["kind"] as! String, tier: c["tier"] as! String, request: request), c["risk"] as? String, "\(c)")
        }
    }

    /// A Core without /api/approvals: the per-kind lists still produce cards,
    /// and a list that failed (nil) hides nothing else.
    func testLegacyListsBuildTheSameItems() throws {
        let privilege = try json(["requests": [
            ["id": "p1", "state": "pending", "scope": "service_deploy", "target_host": "agent-core", "requester_mission_id": "m1",
             "requester_title": "Ship usage fix", "reason": "deploy", "ttl_minutes": 240, "session_scoped": true, "created_at": "2026-10-27T10:00:00Z"],
            ["id": "p0", "state": "approved", "scope": "ops_read", "target_host": "ashur", "requester_mission_id": "m1", "created_at": "2026-10-27T08:00:00Z"],
        ]])
        let missions = try json(["requests": [
            ["id": "a1", "state": "pending", "requester_mission_id": "m2", "requester_title": "Fleet health", "target_mission_id": "t1",
             "target_title": "Disk cleanup", "reason": "r", "ttl_hours": 24, "created_at": "2026-10-27T09:00:00Z"],
        ]])
        let items = OrbApprovalQueue.legacyItems(privilege: privilege, secrets: nil, missions: missions)
        XCTAssertEqual(items.map { OrbApprovalQueue.title($0) }, ["Service deploy on agent-core", "Read Disk cleanup"])
        XCTAssertEqual(items.map { OrbApprovalQueue.requester($0) }, ["Ship usage fix", "Fleet health"])
        XCTAssertEqual(items.map { $0["risk"].text }, ["elevated", "elevated"])
        XCTAssertTrue(items.allSatisfy { $0["legacy"].flag })
        XCTAssertEqual(OrbApprovalQueue.detail(items[0]), "Allows restart and deploy services, including production · for this session (max 4 h)")
        let (path, body) = OrbApprovalQueue.legacyApprove(items[0])
        XCTAssertEqual(path, "/api/privilege-access/p1/approve")
        XCTAssertEqual(body, .object(["ttl_minutes": .number(240), "session_scoped": .bool(true)]))
        XCTAssertEqual(OrbApprovalQueue.legacyApprove(items[1]).0, "/api/mission-access/a1/approve")
        let secret = OrbApprovalQueue.legacyItem(kind: "secret", try json(["id": "s1", "status": "pending", "kind": "delete", "mission_id": "m3", "key": "OLD", "reason": "x"]))
        XCTAssertEqual(secret["risk"].text, "critical")
        XCTAssertEqual(OrbApprovalQueue.legacyApprove(secret).0, "/api/bitwarden/requests/s1/approve")
    }
}
