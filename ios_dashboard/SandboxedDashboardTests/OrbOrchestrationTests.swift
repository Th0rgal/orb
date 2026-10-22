import XCTest
@testable import sandboxed_sh

/// Same cases as the desktop `orchestration-model.test.ts`, on the real events of
/// mission 3a510e9b (an OpenCode mission that spawned a boat machine and ran a subagent on it).
final class OrbOrchestrationTests: XCTestCase {
    private func realEvents() throws -> [StoredEvent] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/boat-subagent-3a510e9b-events.json")
        return try JSONDecoder().decode([StoredEvent].self, from: Data(contentsOf: url))
    }

    func testToolNamesAcrossHarnesses() {
        for name in ["sandboxed_start_mission", "mcp__sandboxed__start_mission", "mcp_sandboxed_assistant_start_mission", "functions.sandboxed_start_mission", "start_mission"] {
            XCTAssertEqual(OrbOrchestration.kind(name), .subagent, name)
        }
        XCTAssertEqual(OrbOrchestration.kind("mcp__sandboxed__spawn_managed_machine"), .machineSpawn)
        XCTAssertEqual(OrbOrchestration.kind("sandboxed_destroy_managed_machine"), .machineDestroy)
        for name in ["restart_mission", "sandboxed_get_mission", "sandboxed_get_action", "bash"] { XCTAssertNil(OrbOrchestration.kind(name), name) }
    }

    func testRealBoatSubagentTranscript() throws {
        let refs = OrbOrchestration.build(from: try realEvents())
        let subagents = refs.compactMap { if case .subagent(let s) = $0 { return s } else { return nil } }
        let child = try XCTUnwrap(subagents.first { $0.missionID == "26e6bbcd-2e3e-4c61-8839-578dcb978211" })
        XCTAssertEqual(child.status, "done")
        XCTAssertEqual(child.backend, "opencode")
        XCTAssertEqual(child.model, "builtin/smart")
        XCTAssertEqual(child.nodeID, "managed-mm4b8tgs9y")
        XCTAssertTrue(child.summary.contains("Diagonal Sums"))
        XCTAssertEqual(OrbOrchestration.nodeLabel(child.nodeID, refs: refs), "xlarge · mm4b8tgs9y")
        let failures = subagents.filter { $0.status == "failed" }.map(\.error).joined(separator: "\n")
        XCTAssertTrue(failures.contains("REMOTE_MODEL_REQUIRED"))
        XCTAssertTrue(failures.contains("Child mission project must match its parent"))
        let machines = refs.compactMap { if case .machine(let m) = $0 { return m } else { return nil } }
        let boat = try XCTUnwrap(machines.first { !$0.destroy && $0.machineID == "mm4b8tgs9y" })
        XCTAssertEqual(boat.state, "destroyed")
        XCTAssertEqual(boat.costUSD, 0.0106)
    }
}
