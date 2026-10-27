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

    func testBunkerCardShowsAboveNormalUntilDismissedAtThatLevel() {
        XCTAssertFalse(OrbPrivilegeAccessMonitor.showsBunkerCard(state: 0, dismissedLevel: 0))
        XCTAssertTrue(OrbPrivilegeAccessMonitor.showsBunkerCard(state: 2, dismissedLevel: 0))
        XCTAssertFalse(OrbPrivilegeAccessMonitor.showsBunkerCard(state: 2, dismissedLevel: 2))
        // Escalating after a dismissal shows the card again.
        XCTAssertTrue(OrbPrivilegeAccessMonitor.showsBunkerCard(state: 3, dismissedLevel: 2))
    }

    func testLatestIncidentReasonSkipsCanaryDryRuns() throws {
        let incidents = try json([
            ["reason": "canary test", "dry_run": true, "new_bunker_state": 0],
            ["reason": "honeytoken read by pid 4242", "dry_run": false, "new_bunker_state": 2],
            ["reason": "older", "dry_run": false, "new_bunker_state": 1],
        ]).items
        XCTAssertEqual(OrbPrivilegeAccessMonitor.latestIncidentReason(incidents), "honeytoken read by pid 4242")
        XCTAssertNil(OrbPrivilegeAccessMonitor.latestIncidentReason([]))
    }

    func testEnrollmentPromptOnlyWhenSignaturesAreAskedAndThisKeyIsMissing() {
        XCTAssertFalse(OrbApprovalEnrollmentMonitor.shouldPrompt(mode: "off", enrolled: false, dismissedMode: nil))
        XCTAssertFalse(OrbApprovalEnrollmentMonitor.shouldPrompt(mode: "", enrolled: false, dismissedMode: nil))
        XCTAssertTrue(OrbApprovalEnrollmentMonitor.shouldPrompt(mode: "warn", enrolled: false, dismissedMode: nil))
        XCTAssertTrue(OrbApprovalEnrollmentMonitor.shouldPrompt(mode: "enforce", enrolled: false, dismissedMode: nil))
        XCTAssertFalse(OrbApprovalEnrollmentMonitor.shouldPrompt(mode: "enforce", enrolled: true, dismissedMode: nil))
        XCTAssertFalse(OrbApprovalEnrollmentMonitor.shouldPrompt(mode: "warn", enrolled: false, dismissedMode: "warn"))
        // Core moving from warn to enforce asks again.
        XCTAssertTrue(OrbApprovalEnrollmentMonitor.shouldPrompt(mode: "enforce", enrolled: false, dismissedMode: "warn"))
    }

    func testThisDeviceIsEnrolledOnlyWhenItsKeyIsListed() throws {
        let devices = try json([["public_key": "AAA"], ["public_key": "BBB"]]).items
        XCTAssertTrue(OrbApprovalEnrollmentMonitor.isEnrolled(publicKey: "BBB", devices: devices))
        XCTAssertFalse(OrbApprovalEnrollmentMonitor.isEnrolled(publicKey: "CCC", devices: devices))
        XCTAssertFalse(OrbApprovalEnrollmentMonitor.isEnrolled(publicKey: nil, devices: devices))
        XCTAssertFalse(OrbApprovalEnrollmentMonitor.isEnrolled(publicKey: "", devices: [try json(["public_key": ""])]))
    }
}
