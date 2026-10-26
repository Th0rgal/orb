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

    func testApproveAllSignsEachRequestByCoreDigestAndConfirmsRootOnlyWhenIncluded() throws {
        let deploy = try json(["id": "p1", "scope": "service_deploy", "target_host": "agent-core", "digest": "d1", "reason": "x"])
        let root = try json(["id": "p2", "scope": "root_exec", "target_host": "self", "digest": "d2"])
        let body = OrbPrivilegeAccessMonitor.batchBody([deploy, root])
        XCTAssertEqual(body["confirm_critical"], .bool(true))
        XCTAssertEqual(body["items"], .array([
            .object(["kind": .string("privilege"), "id": .string("p1"), "digest": .string("d1")]),
            .object(["kind": .string("privilege"), "id": .string("p2"), "digest": .string("d2")]),
        ]))
        XCTAssertEqual(OrbPrivilegeAccessMonitor.batchBody([deploy])["confirm_critical"], .bool(false))
    }
}
