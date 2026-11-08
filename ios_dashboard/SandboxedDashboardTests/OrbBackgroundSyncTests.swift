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
                liveIds: (wc["liveIds"] as? [String]) ?? [],
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

    func testBtwDirtyInvalidationAndDuplicateQuestionDisambiguation() throws {
        let parentId = "06203bdc-3543-483e-a8c5-3bf20eb5c34a"
        OrbWarmSyncCoordinator.shared.markBtwClean(parentId: parentId)
        OrbWarmSyncCoordinator.shared.markBtwDirty(parentId: parentId)
        XCTAssertFalse(OrbWarmSyncCoordinator.shared.canSkipBtwServerCrawl(parentId: parentId))

        let firstTurn = OrbBtwThreads.Turn(
            id: "btw:3d7b16e7:83",
            question: "and now?",
            answer: "First status.",
            at: "2026-11-04T19:21:00Z"
        )
        let secondAskedAt = try XCTUnwrap(OrbTurnSummary.parseDate("2026-11-04T20:07:00Z"))
        // Earlier identical "and now?" turn must NOT satisfy the second "and now?" pending turn:
        XCTAssertFalse(
            OrbBtwThreads.doesTurnAnswerPending(
                question: "and now?",
                askedAt: secondAskedAt,
                reconciledTurns: [firstTurn],
                priorTurns: [firstTurn]
            )
        )
        XCTAssertFalse(
            OrbBtwThreads.doesTurnAnswerPending(
                question: "and now?",
                askedAt: secondAskedAt,
                reconciledTurns: [firstTurn],
                priorTurns: []
            )
        )
        let secondTurn = OrbBtwThreads.Turn(
            id: "btw:3d7b16e7:98",
            question: "and now?",
            answer: "Second status.",
            at: "2026-11-04T20:07:30Z"
        )
        XCTAssertTrue(
            OrbBtwThreads.doesTurnAnswerPending(
                question: "and now?",
                askedAt: secondAskedAt,
                reconciledTurns: [firstTurn, secondTurn],
                priorTurns: [firstTurn]
            )
        )
    }

    func testNoteExternalSessionHintRebindsAlreadyBoundStore() {
        let parentId = "parent-rebind-\(UUID().uuidString)"
        let sessionKey = OrbBtwConfig.sessionKey(parentId)
        defer { UserDefaults.standard.removeObject(forKey: sessionKey) }

        let store = OrbBtwStore.shared(parentId)
        store.sent(to: "btw-old")
        XCTAssertEqual(store.boundID, "btw-old")

        store.noteExternalSessionHint(missionId: "btw-new")
        XCTAssertEqual(store.boundID, "btw-new")
        XCTAssertEqual(UserDefaults.standard.string(forKey: sessionKey), "btw-new")
        XCTAssertEqual(OrbBtwStore.knownBoundIdsByParent(candidates: [parentId])[parentId], "btw-new")
    }

    func testSharedClientLinkGovernorFixtures() throws {
        let root = try OrbSpec.json("fixtures/client-link-governor.json")
        let ewmaCases = try XCTUnwrap(root["rtt_ewma_cases"] as? [[String: Any]])
        XCTAssertFalse(ewmaCases.isEmpty)
        for c in ewmaCases {
            let name = try XCTUnwrap(c["name"] as? String)
            let expected = try XCTUnwrap(c["expected"] as? [String: Any])
            let res = OrbKernel.rttEwmaStep(
                srttMs: (c["srtt_ms"] as? NSNumber)?.intValue ?? 0,
                rttVarMs: (c["rtt_var_ms"] as? NSNumber)?.intValue ?? 0,
                sampleMs: (c["sample_ms"] as? NSNumber)?.intValue ?? 0
            )
            XCTAssertEqual(res.srttMs, (expected["next_srtt_ms"] as? NSNumber)?.intValue, name)
            XCTAssertEqual(res.rttVarMs, (expected["next_rtt_var_ms"] as? NSNumber)?.intValue, name)
        }

        let budgetCases = try XCTUnwrap(root["link_budget_cases"] as? [[String: Any]])
        XCTAssertFalse(budgetCases.isEmpty)
        for c in budgetCases {
            let name = try XCTUnwrap(c["name"] as? String)
            let expected = try XCTUnwrap(c["expected"] as? [String: Any])
            let res = OrbKernel.clientLinkBudgetStep(
                srttMs: (c["srtt_ms"] as? NSNumber)?.intValue ?? 0,
                rttVarMs: (c["rtt_var_ms"] as? NSNumber)?.intValue ?? 0,
                consecutiveFailures: (c["consecutive_failures"] as? NSNumber)?.intValue ?? 0,
                isConstrained: ((c["is_constrained"] as? NSNumber)?.intValue ?? 0) != 0,
                p0InFlight: (c["p0_in_flight"] as? NSNumber)?.intValue ?? 0
            )
            XCTAssertEqual(res.p1Cap, (expected["p1_cap"] as? NSNumber)?.intValue, name)
            XCTAssertEqual(res.p2Cap, (expected["p2_cap"] as? NSNumber)?.intValue, name)
            XCTAssertEqual(res.connectDeadlineMs, (expected["connect_deadline_ms"] as? NSNumber)?.intValue, name)
            XCTAssertEqual(res.pongDeadlineMs, (expected["pong_deadline_ms"] as? NSNumber)?.intValue, name)
            XCTAssertEqual(res.wakePongDeadlineMs, (expected["wake_pong_deadline_ms"] as? NSNumber)?.intValue, name)
        }

        let originCases = try XCTUnwrap(root["candidate_origin_cases"] as? [[String: Any]])
        for c in originCases {
            let name = try XCTUnwrap(c["name"] as? String)
            let configured = try XCTUnwrap(c["configured_url"] as? String)
            let expected = try XCTUnwrap(c["expected"] as? [String])
            XCTAssertEqual(OrbConnection.candidateEndpoints(for: configured), expected, name)
        }
    }
}
