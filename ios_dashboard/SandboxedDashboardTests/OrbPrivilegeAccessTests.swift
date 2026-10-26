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
