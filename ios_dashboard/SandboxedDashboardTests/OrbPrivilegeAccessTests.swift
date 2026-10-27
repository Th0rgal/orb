import XCTest
@testable import sandboxed_sh

/// Privileged access labels match desktop and Android via shared/orb-spec.
@MainActor
final class OrbPrivilegeAccessTests: XCTestCase {
    private func json(_ any: Any) throws -> OrbJSON {
        try JSONDecoder().decode(OrbJSON.self, from: JSONSerialization.data(withJSONObject: any))
    }

    func testLabelsMatchSharedFixture() throws {
        let spec = try OrbSpec.json("fixtures/privilege-access.json")
        let cases = try XCTUnwrap(spec["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let r = try json(try XCTUnwrap(c["request"]))
            XCTAssertEqual(OrbPrivilegeAccessMonitor.title(r), c["title"] as? String)
            XCTAssertEqual(OrbPrivilegeAccessMonitor.unlocks(r), c["unlocks"] as? String)
            XCTAssertEqual(OrbPrivilegeAccessMonitor.lifetime(r), c["lifetime"] as? String)
            XCTAssertEqual(OrbPrivilegeAccessMonitor.requester(r), c["requester"] as? String)
        }
    }

    func testOnlyApprovedUnexpiredUnrevokedGrantsAreLive() throws {
        let now = Date()
        let iso = ISO8601DateFormatter()
        let later = iso.string(from: now.addingTimeInterval(600))
        let earlier = iso.string(from: now.addingTimeInterval(-600))
        XCTAssertTrue(OrbPrivilegeAccessMonitor.isLive(try json(["state": "approved", "expires_at": later]), now: now))
        XCTAssertFalse(OrbPrivilegeAccessMonitor.isLive(try json(["state": "pending", "expires_at": later]), now: now))
        XCTAssertFalse(OrbPrivilegeAccessMonitor.isLive(try json(["state": "approved", "expires_at": earlier]), now: now))
        XCTAssertFalse(OrbPrivilegeAccessMonitor.isLive(try json(["state": "approved", "expires_at": later, "revoked_at": earlier]), now: now))
    }

    func testApproveAllSummaryMatchesSharedFixture() throws {
        let spec = try OrbSpec.json("fixtures/privilege-access.json")
        let cases = try XCTUnwrap(spec["cases"] as? [[String: Any]])
        let batches = try XCTUnwrap(spec["batches"] as? [[String: Any]])
        XCTAssertFalse(batches.isEmpty)
        for b in batches {
            let idx = try XCTUnwrap(b["requests"] as? [Int])
            let rs = try idx.enumerated().map { n, i -> OrbJSON in
                var r = try XCTUnwrap(cases[i]["request"] as? [String: Any])
                r["id"] = "b\(n)"
                return try json(r)
            }
            let s = OrbPrivilegeAccessMonitor.batchSummary(rs)
            XCTAssertEqual(s.tiers, b["tiers"] as? String)
            XCTAssertEqual(s.hosts, b["hosts"] as? String)
            XCTAssertEqual(s.missions, b["missions"] as? String)
            XCTAssertEqual(s.root, b["root"] as? Int)
            XCTAssertEqual(OrbPrivilegeAccessMonitor.batchApprovable(rs, includeRoot: false).count, b["without_root"] as? Int)
            XCTAssertEqual(OrbPrivilegeAccessMonitor.batchApprovable(rs, includeRoot: true).count, rs.count)
        }
    }

    func testApproveAllBodyListsEachRequestAndConfirmsRootOnlyWhenIncluded() throws {
        let deploy = try json(["id": "p1", "requester_mission_id": "m1", "target_host": "agent-core", "scope": "service_deploy",
                               "allowed_unit": NSNull(), "ttl_minutes": 240, "session_scoped": true, "reason": "x"])
        let root = try json(["id": "p2", "requester_mission_id": "m2", "target_host": "self", "scope": "root_exec",
                             "allowed_unit": "", "ttl_minutes": 60, "session_scoped": false])
        let body = OrbPrivilegeAccessMonitor.batchBody([deploy, root])
        XCTAssertEqual(body["confirm_root"], .bool(true))
        let items = body["items"].items
        XCTAssertEqual(items.map { $0["id"].text }, ["p1", "p2"])
        XCTAssertEqual(items[0]["target_host"].text, "agent-core")
        XCTAssertEqual(items[1]["scope"].text, "root_exec")
        XCTAssertEqual(items[1]["requester_mission_id"].text, "m2")
        XCTAssertEqual(items[1]["allowed_unit"], .null)
        XCTAssertEqual(items[1]["session_scoped"], .bool(false))
        if case .object(let o) = items[0] { XCTAssertEqual(o.count, 7, "only the fields Core checks") } else { XCTFail("item is not an object") }
        XCTAssertEqual(OrbPrivilegeAccessMonitor.batchBody([deploy])["confirm_root"], .bool(false))
    }

    func testBunkerStateLabels() {
        XCTAssertEqual(OrbPrivilegeAccessMonitor.bunkerLabel(0), "Normal")
        XCTAssertEqual(OrbPrivilegeAccessMonitor.bunkerLabel(1), "Soft Quarantine")
        XCTAssertEqual(OrbPrivilegeAccessMonitor.bunkerLabel(2), "Hard Lockdown")
        XCTAssertEqual(OrbPrivilegeAccessMonitor.bunkerLabel(3), "Sovereign Dead-Man Tripped")
    }

    func testEscapePreservesUnreservedUUIDHyphens() {
        let uuid = "1722a8ac-49c5-4193-9317-7498a0dceffd"
        XCTAssertEqual(OrbCore.escape(uuid), uuid)
        XCTAssertFalse(OrbCore.escape(uuid).contains("%"))
    }

    func testRemoteNodeIDResolvesJobNodeAndScopeUnit() throws {
        let fromJob = try json(["remote_job": ["node_id": "nippur"]])
        XCTAssertEqual(OrbContinuation.remoteNodeID(for: fromJob), "nippur")

        let fromScope = try json(["execution": ["scope_unit": "remote-node:ashur:mission-1"]])
        XCTAssertEqual(OrbContinuation.remoteNodeID(for: fromScope), "ashur")

        let local = try json(["id": "m1"])
        XCTAssertEqual(OrbContinuation.remoteNodeID(for: local), "core")
    }
}
