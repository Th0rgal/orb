import XCTest
@testable import sandboxed_sh

/// Replays `shared/orb-spec/fixtures/background-sync-policy.json` and tests direct
/// in-memory reduction of live `/api/control/sync` WebSocket frames into `StoredEvent`.
@MainActor
final class OrbBackgroundSyncTests: XCTestCase {
    private func spec() throws -> [String: Any] {
        try OrbSpec.json("fixtures/background-sync-policy.json")
    }

    func testSharedFixtureConstantsAndNormalization() throws {
        let root = try spec()
        let constants = try XCTUnwrap(root["constants"] as? [String: Any])
        XCTAssertEqual(OrbBackgroundSyncPolicy.maxWarmMissions, constants["maxWarmMissions"] as? Int)
        XCTAssertEqual(StoredEvent.resultKeepUTF8, constants["maxPayloadBytes"] as? Int)
        XCTAssertEqual(OrbBackgroundSyncPolicy.rttSlowThresholdMs, constants["highRttThresholdMs"] as? Int)
        XCTAssertEqual(OrbBackgroundSyncPolicy.rttSlowStreakToPause, constants["highRttConsecutiveTrips"] as? Int)
        XCTAssertEqual(OrbBackgroundSyncPolicy.rttFastThresholdMs, constants["lowRttThresholdMs"] as? Int)
        XCTAssertEqual(OrbBackgroundSyncPolicy.rttFastStreakToResume, constants["lowRttConsecutiveRecover"] as? Int)
        XCTAssertEqual(OrbBackgroundSyncPolicy.resumeCooldownMs, (constants["recoveryCooldownMs"] as? NSNumber)?.int64Value)
        XCTAssertEqual(OrbBackgroundSyncPolicy.disconnectWindowMs, (constants["disconnectWindowMs"] as? NSNumber)?.int64Value)
        XCTAssertEqual(OrbBackgroundSyncPolicy.disconnectBurstToPause, constants["disconnectBurstTrips"] as? Int)

        let normCases = try XCTUnwrap(root["normalization"] as? [[String: Any]])
        for c in normCases {
            let expected = try XCTUnwrap(c["expected"] as? String)
            let input: Any? = c["input"] is NSNull ? nil : c["input"]
            XCTAssertEqual(OrbBackgroundSyncPolicy.normalizeMode(input).rawValue, expected)
        }
    }

    func testSharedFixtureStateTransitions() throws {
        let root = try spec()
        let transitions = try XCTUnwrap(root["stateTransitions"] as? [[String: Any]])
        XCTAssertFalse(transitions.isEmpty)

        for tc in transitions {
            let name = try XCTUnwrap(tc["name"] as? String)
            let initialMode = OrbBackgroundSyncPolicy.normalizeMode(tc["mode"])
            var state = OrbBackgroundSyncPolicy.initialState(mode: initialMode, dataSaver: false)

            let events = try XCTUnwrap(tc["events"] as? [[String: Any]])
            for ev in events {
                let kind = try XCTUnwrap(ev["type"] as? String)
                switch kind {
                case "mode":
                    state = OrbBackgroundSyncPolicy.reduce(
                        state,
                        event: .setMode(OrbBackgroundSyncPolicy.normalizeMode(ev["mode"]))
                    )
                case "network":
                    let constrained = ((ev["dataSaver"] as? Bool) ?? false) || ((ev["slowLink"] as? Bool) ?? false)
                    state = OrbBackgroundSyncPolicy.reduce(
                        state,
                        event: .setDataSaver(constrained)
                    )
                case "pong":
                    state = OrbBackgroundSyncPolicy.reduce(
                        state,
                        event: .pingRtt(
                            rttMs: (ev["rttMs"] as? NSNumber)?.intValue ?? 0,
                            atMs: (ev["nowMs"] as? NSNumber)?.int64Value ?? 0
                        )
                    )
                case "lagged":
                    state = OrbBackgroundSyncPolicy.reduce(
                        state,
                        event: .streamLagged(atMs: (ev["nowMs"] as? NSNumber)?.int64Value ?? 0)
                    )
                case "disconnect":
                    state = OrbBackgroundSyncPolicy.reduce(
                        state,
                        event: .unexpectedDisconnect(atMs: (ev["nowMs"] as? NSNumber)?.int64Value ?? 0)
                    )
                default:
                    XCTFail("Unknown fixture event \(kind) in \(name)")
                }
            }

            let expected = try XCTUnwrap(tc["expected"] as? [String: Any])
            XCTAssertEqual(state.active, expected["active"] as? Bool, name)
            XCTAssertEqual(state.reason, expected["reason"] as? String, name)
        }
    }

    func testSharedFixtureWarmSelection() throws {
        let root = try spec()
        let cases = try XCTUnwrap(root["warmSelection"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)

        for wc in cases {
            let name = try XCTUnwrap(wc["name"] as? String)
            let selection = OrbBackgroundSyncPolicy.selectWarmMissionIds(
                backgroundActive: (wc["backgroundActive"] as? Bool) ?? false,
                maxWarm: (wc["maxWarm"] as? NSNumber)?.intValue ?? 12,
                focusedIds: (wc["focusedIds"] as? [String]) ?? [],
                recentIds: (wc["recentIds"] as? [String]) ?? [],
                knownBtwByParent: (wc["btwByParent"] as? [String: String]) ?? [:],
                focusedBtwParents: (wc["openBtwParentIds"] as? [String]) ?? []
            )
            XCTAssertEqual(selection.allStreamIds, wc["expectedMissionIds"] as? [String], name)
        }
    }

    func testLiveStreamFramesConvertDirectlyIntoStoredEventsWithoutHttpRefresh() {
        let mid = "m-live-reduce"
        let userEv = StoredEvent.fromStreamFrame(
            missionId: mid,
            type: "user_message",
            data: ["id": "u-1", "sequence": 1, "content": "Inspect build", "queued": false]
        )
        let callEv = StoredEvent.fromStreamFrame(
            missionId: mid,
            type: "tool_call",
            data: ["sequence": 2, "tool_call_id": "tc-1", "name": "bash", "args": ["command": "cargo check"]]
        )
        let bigOutput = String(repeating: "x", count: 8192)
        let resEv = StoredEvent.fromStreamFrame(
            missionId: mid,
            type: "tool_result",
            data: ["sequence": 3, "tool_call_id": "tc-1", "name": "bash", "result": bigOutput, "is_error": false]
        )
        let replyEv = StoredEvent.fromStreamFrame(
            missionId: mid,
            type: "assistant_message",
            data: ["id": "a-4", "sequence": 4, "content": "All green.", "success": true]
        )

        let events = [userEv, callEv, resEv, replyEv].compactMap { $0 }
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[2].content.utf8.count, StoredEvent.resultKeepUTF8)

        let work = OrbWorkModel.build(from: events, working: false)
        XCTAssertEqual(work.tools.count, 1)
        XCTAssertEqual(work.tools[0].status, .done)

        let history = OrbConversationHistory.visible(OrbConversationHistory.merge([], events: events))
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0]["content"].text, "Inspect build")
        XCTAssertEqual(history[1]["content"].text, "All green.")
    }
}
