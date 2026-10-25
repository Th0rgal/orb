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
}
