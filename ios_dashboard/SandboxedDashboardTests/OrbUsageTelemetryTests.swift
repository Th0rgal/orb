import XCTest
@testable import sandboxed_sh

/// Usage telemetry against shared/orb-spec/fixtures/usage-telemetry.json (Core's allowlist).
@MainActor
final class OrbUsageTelemetryTests: XCTestCase {
    private func fixture() throws -> [String: Any] { try OrbSpec.json("fixtures/usage-telemetry.json") }
    private func schema(_ name: String) throws -> [String: Any] {
        try XCTUnwrap((try fixture()["schemas"] as? [String: Any])?[name] as? [String: Any])
    }

    func testEnumsMatchFixture() throws {
        XCTAssertEqual(try schema("orb.action.v1")["action"] as? [String], OrbTelemetryAction.allCases.map(\.rawValue))
        let approval = try schema("orb.approval.v1")
        XCTAssertEqual(approval["kind"] as? [String], OrbTelemetryApprovalKind.allCases.map(\.rawValue))
        XCTAssertEqual(approval["decision"] as? [String], OrbTelemetryDecision.allCases.map(\.rawValue))
        XCTAssertEqual(approval["method"] as? [String], OrbTelemetryMethod.allCases.map(\.rawValue))
        XCTAssertEqual(try schema("orb.page.v1")["surface"] as? [String], OrbTelemetrySurface.allCases.map(\.rawValue))
        XCTAssertEqual(try fixture()["ident_pattern"] as? String, "^[A-Za-z0-9_.:/+@-]{1,120}$")
        XCTAssertTrue((try fixture()["clients"] as? [String] ?? []).contains("ios"))
    }

    @MainActor final class FakeHub {
        var down = false
        var sent: [OrbJSON] = []
    }

    private func activeTelemetry(_ hub: FakeHub = FakeHub()) -> OrbUsageTelemetry {
        let t = OrbUsageTelemetry(transport: { batch in
            if hub.down { throw OrbHTTPError(status: 503, detail: "down") }
            hub.sent += batch
        }, fetchStatus: { .object(["active": .bool(true)]) })
        t.apply(OrbTelemetryStatus(.object(["enabled": .bool(true), "active": .bool(true)])))
        return t
    }

    func testBuiltEventsUseOnlyAllowlistedKeys() throws {
        let fx = try fixture()
        let common = Set(try XCTUnwrap(fx["common"] as? [String: Any]).keys)
        let clientSchemas = try XCTUnwrap(fx["client_schemas"] as? [String])
        let t = activeTelemetry()
        t.trackAction(.fork, surface: "fork_sheet", count: 2)
        t.trackAction(.inboxDone, surface: "has spaces")
        t.trackApproval(kind: .tool, decision: .approved, method: .faceId, waitMs: 4200, toolName: "ssh_sign", commandClass: "git")
        t.trackPage(screen: "settings.usage-telemetry", surface: .pane, entryPoint: "settings.account").close()
        XCTAssertEqual(t.queue.count, 4)
        for event in t.queue {
            guard case .object(let fields) = event else { return XCTFail("not an object") }
            let name = fields["schema"]?.text ?? ""
            XCTAssertTrue(clientSchemas.contains(name), name)
            let allowed = common.union(try schema(name).keys)
            XCTAssertTrue(Set(fields.keys).isSubset(of: allowed), "\(name): \(Set(fields.keys).subtracting(allowed))")
            XCTAssertNil(fields["quick_close"])
            XCTAssertEqual(fields["client"], .string("ios"))
            for key in ["event_id", "ts", "app_version"] {
                XCTAssertTrue(OrbUsageTelemetry.isIdent(fields[key]?.text ?? ""), key)
            }
            for (_, v) in fields { if case .string(let s) = v { XCTAssertTrue(OrbUsageTelemetry.isIdent(s), s) } }
        }
        XCTAssertNil(t.queue[1]["surface"].doubleValue)
        XCTAssertEqual(t.queue[1]["surface"], .null)
        XCTAssertNotNil(t.queue[3]["dwell_ms"].doubleValue)
    }

    func testNothingQueuedWhileInactive() async {
        let hub = FakeHub()
        let t = OrbUsageTelemetry(transport: { hub.sent += $0 }, fetchStatus: { .object(["enabled": .bool(false), "active": .bool(false)]) })
        XCTAssertFalse(t.active)
        t.trackAction(.queue)
        t.trackPage(screen: "inbox", surface: .screen).close()
        XCTAssertTrue(t.queue.isEmpty)
        await t.refreshStatus()
        t.trackAction(.btw)
        await t.flush()
        XCTAssertTrue(t.queue.isEmpty)
        XCTAssertTrue(hub.sent.isEmpty)
    }

    func testFailedFlushKeepsEventsAndRetries() async {
        let hub = FakeHub()
        hub.down = true
        let t = activeTelemetry(hub)
        t.trackAction(.sidebarMove, surface: "conversation")
        t.trackAction(.messageEdit, surface: "queue")
        await t.flush()
        XCTAssertEqual(t.queue.count, 2)
        XCTAssertTrue(hub.sent.isEmpty)
        hub.down = false
        await t.flush()
        XCTAssertTrue(t.queue.isEmpty)
        XCTAssertEqual(hub.sent.map { $0["action"].text }, ["sidebar_move", "message_edit"])
    }

    func testQueueCapDropsOldest() {
        let t = OrbUsageTelemetry(transport: { _ in throw OrbHTTPError(status: 503, detail: "down") }, fetchStatus: { .null })
        t.apply(OrbTelemetryStatus(.object(["active": .bool(true)])))
        for i in 0..<(OrbUsageTelemetry.maxQueued + 10) { t.trackAction(.fork, count: i) }
        XCTAssertEqual(t.queue.count, OrbUsageTelemetry.maxQueued)
        XCTAssertEqual(t.queue.first?["count"].doubleValue, 10)
    }

    func testApprovalWaitIsMeasuredFromShown() {
        let t = OrbUsageTelemetry(transport: { _ in }, fetchStatus: { .null })
        XCTAssertNil(t.approvalWait("r1"))
        t.approvalShown("r1")
        XCTAssertNotNil(t.approvalWait("r1"))
        XCTAssertNil(t.approvalWait("r1"))
    }
}
