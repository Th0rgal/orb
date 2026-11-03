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

    func testAutoManagedAsyncGetActionResolvesRunningAndConcreteNodeLabel() throws {
        let events: [StoredEvent] = [
            StoredEvent(id: 1, missionId: "p", sequence: 1, eventType: "tool_call", timestamp: "", eventId: nil,
                        toolCallId: "c-start", toolName: "mcp__sandboxed__start_mission",
                        content: #"{"title":"R15-EvmEkFk","backend":"opencode","model_override":"google/gemini-4-carbon-eap","remote_node_id":"auto-managed:boat:xlarge"}"#,
                        metadata: [:]),
            StoredEvent(id: 2, missionId: "p", sequence: 2, eventType: "tool_result", timestamp: "", eventId: nil,
                        toolCallId: "c-start", toolName: "mcp__sandboxed__start_mission",
                        content: #"{"content":[{"type":"text","text":"{\"accepted\":\"yes\",\"action_id\":\"act-1\",\"state\":\"queued\"}"}]}"#,
                        metadata: [:]),
            StoredEvent(id: 3, missionId: "p", sequence: 3, eventType: "tool_call", timestamp: "", eventId: nil,
                        toolCallId: "c-poll", toolName: "mcp__sandboxed__get_action",
                        content: #"{"action_id":"act-1"}"#,
                        metadata: [:]),
            StoredEvent(id: 4, missionId: "p", sequence: 4, eventType: "tool_result", timestamp: "", eventId: nil,
                        toolCallId: "c-poll", toolName: "mcp__sandboxed__get_action",
                        content: #"{"content":[{"type":"text","text":"{\"action_id\":\"act-1\",\"state\":\"succeeded\",\"result\":{\"mission\":{\"id\":\"005ca1ac-1111-2222-3333-444455556666\",\"status\":\"active\",\"execution\":{\"scope_unit\":\"remote-node:managed-mmf4ywkaxw\"}},\"managed_machine\":{\"id\":\"mmf4ywkaxw\",\"node_id\":\"managed-mmf4ywkaxw\",\"size\":\"xlarge\",\"state\":\"online\"}}}"}]}"#,
                        metadata: [:]),
        ]
        let compacted = events.map(\.compacted)
        let refs = OrbOrchestration.build(from: compacted)
        let subagents = refs.compactMap { if case .subagent(let s) = $0 { return s } else { return nil } }
        let child = try XCTUnwrap(subagents.first)
        XCTAssertEqual(child.missionID, "005ca1ac-1111-2222-3333-444455556666")
        XCTAssertEqual(child.status, "running")
        XCTAssertEqual(child.nodeID, "managed-mmf4ywkaxw")
        XCTAssertEqual(OrbOrchestration.nodeLabel(child.nodeID, refs: refs, fallbackSize: child.nodeSize), "xlarge · mmf4ywkaxw")
    }
}
