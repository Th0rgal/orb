import XCTest
@testable import sandboxed_sh

/// The approval queue labels, summarizes and signs exactly like desktop and
/// Android, via shared/orb-spec/fixtures/approvals.json.
@MainActor
final class OrbApprovalQueueTests: XCTestCase {
    private func json(_ any: Any) throws -> OrbJSON {
        try JSONDecoder().decode(OrbJSON.self, from: JSONSerialization.data(withJSONObject: any))
    }

    private func item(_ label: [String: Any], _ n: Int) throws -> OrbJSON {
        var i = try XCTUnwrap(label["item"] as? [String: Any])
        i["id"] = "i\(n)"
        i["digest"] = "d\(n)"
        return try json(i)
    }

    func testLabelsMatchSharedFixture() throws {
        let spec = try OrbSpec.json("fixtures/approvals.json")
        let labels = try XCTUnwrap(spec["labels"] as? [[String: Any]])
        XCTAssertFalse(labels.isEmpty)
        for (n, c) in labels.enumerated() {
            let i = try item(c, n)
            XCTAssertEqual(OrbApprovalQueue.title(i), c["title"] as? String)
            XCTAssertEqual(OrbApprovalQueue.requester(i), c["requester"] as? String)
            XCTAssertEqual(OrbApprovalQueue.detail(i), c["detail"] as? String)
        }
    }

    func testSummaryAndCriticalExclusionMatchSharedFixture() throws {
        let spec = try OrbSpec.json("fixtures/approvals.json")
        let labels = try XCTUnwrap(spec["labels"] as? [[String: Any]])
        let summaries = try XCTUnwrap(spec["summaries"] as? [[String: Any]])
        for s in summaries {
            let idx = try XCTUnwrap(s["items"] as? [Int])
            let items = try idx.enumerated().map { n, k in try item(labels[k], n) }
            let got = OrbApprovalQueue.summary(items)
            XCTAssertEqual(got.risks, s["risks"] as? String)
            XCTAssertEqual(got.missions, s["missions"] as? String)
            XCTAssertEqual(OrbApprovalQueue.normalBatch(items).count, s["without_critical"] as? Int)
            XCTAssertEqual(OrbApprovalQueue.allBatch(items).count, items.count)
        }
    }

    func testSignsKindIdAndDigestAndConfirmsCriticalOnlyWhenListed() throws {
        let labels = try XCTUnwrap(try OrbSpec.json("fixtures/approvals.json")["labels"] as? [[String: Any]])
        let deploy = try item(labels[0], 0), root = try item(labels[1], 1), read = try item(labels[2], 2)
        let body = OrbApprovalQueue.batchBody([deploy, read])
        XCTAssertEqual(body["confirm_critical"], .bool(false))
        XCTAssertEqual(body["items"], .array([
            .object(["kind": .string("privilege"), "id": .string("i0"), "digest": .string("d0")]),
            .object(["kind": .string("secret"), "id": .string("i2"), "digest": .string("d2")]),
        ]))
        XCTAssertEqual(OrbApprovalQueue.batchBody([root])["confirm_critical"], .bool(true))
        XCTAssertEqual(
            OrbApprovalQueue.signingReason([deploy, try item(labels[9], 9), read]),
            "Approve 3 requests (1 critical · 1 elevated · 1 routine): Move OLD_TOKEN; Service deploy on agent-core; Read OPENAI_API_KEY"
        )
    }

    func testNeverAsksCoreForMoreThanOneSignatureCanApprove() throws {
        let labels = try XCTUnwrap(try OrbSpec.json("fixtures/approvals.json")["labels"] as? [[String: Any]])
        let many = try (0..<(OrbApprovalQueue.maxBatch + 5)).map { try item(labels[2], $0) }
        XCTAssertEqual(OrbApprovalQueue.allBatch(many).count, OrbApprovalQueue.maxBatch)
        XCTAssertEqual(OrbApprovalQueue.normalBatch(many).count, OrbApprovalQueue.maxBatch)
    }

    func testDeniesThroughEachKindsRoute() throws {
        let labels = try XCTUnwrap(try OrbSpec.json("fixtures/approvals.json")["labels"] as? [[String: Any]])
        XCTAssertEqual(OrbApprovalQueue.denyPath(try item(labels[0], 0)), "/api/privilege-access/i0/deny")
        XCTAssertEqual(OrbApprovalQueue.denyPath(try item(labels[2], 2)), "/api/bitwarden/requests/i2/reject")
        XCTAssertEqual(OrbApprovalQueue.denyPath(try item(labels[7], 7)), "/api/mission-access/i7/deny")
    }

    func testRiskMatchesCoreRiskTable() throws {
        let risks = try XCTUnwrap(try OrbSpec.json("fixtures/approvals.json")["risk"] as? [[String: Any]])
        for c in risks {
            let request = try json(["all_projects": (c["all_projects"] as? Bool) ?? false])
            XCTAssertEqual(OrbApprovalQueue.riskOf(kind: c["kind"] as! String, tier: c["tier"] as! String, request: request), c["risk"] as? String, "\(c)")
        }
    }

    /// A Core without /api/approvals: the per-kind lists still produce cards,
    /// and a list that failed (nil) hides nothing else.
    func testLegacyListsBuildTheSameItems() throws {
        let privilege = try json(["requests": [
            ["id": "p1", "state": "pending", "scope": "service_deploy", "target_host": "agent-core", "requester_mission_id": "m1",
             "requester_title": "Ship usage fix", "reason": "deploy", "ttl_minutes": 240, "session_scoped": true, "created_at": "2026-10-27T10:00:00Z"],
            ["id": "p0", "state": "approved", "scope": "ops_read", "target_host": "ashur", "requester_mission_id": "m1", "created_at": "2026-10-27T08:00:00Z"],
        ]])
        let missions = try json(["requests": [
            ["id": "a1", "state": "pending", "requester_mission_id": "m2", "requester_title": "Fleet health", "target_mission_id": "t1",
             "target_title": "Disk cleanup", "reason": "r", "ttl_hours": 24, "created_at": "2026-10-27T09:00:00Z"],
        ]])
        let items = OrbApprovalQueue.legacyItems(privilege: privilege, secrets: nil, missions: missions)
        XCTAssertEqual(items.map { OrbApprovalQueue.title($0) }, ["Service deploy on agent-core", "Read Disk cleanup"])
        XCTAssertEqual(items.map { OrbApprovalQueue.requester($0) }, ["Ship usage fix", "Fleet health"])
        XCTAssertEqual(items.map { $0["risk"].text }, ["elevated", "elevated"])
        XCTAssertTrue(items.allSatisfy { $0["legacy"].flag })
        XCTAssertEqual(OrbApprovalQueue.detail(items[0]), "Allows restart and deploy services, including production · for this session (max 4 h)")
        let (path, body) = OrbApprovalQueue.legacyApprove(items[0])
        XCTAssertEqual(path, "/api/privilege-access/p1/approve")
        XCTAssertEqual(body, .object(["ttl_minutes": .number(240), "session_scoped": .bool(true)]))
        XCTAssertEqual(OrbApprovalQueue.legacyApprove(items[1]).0, "/api/mission-access/a1/approve")
        let secret = OrbApprovalQueue.legacyItem(kind: "secret", try json(["id": "s1", "status": "pending", "kind": "delete", "mission_id": "m3", "key": "OLD", "reason": "x"]))
        XCTAssertEqual(secret["risk"].text, "critical")
        XCTAssertEqual(OrbApprovalQueue.legacyApprove(secret).0, "/api/bitwarden/requests/s1/approve")
    }

    /// "Approve N" covers the normal items only; "Approve all" covers
    /// everything, critical first, and says how many are critical.
    func testTwoButtonsNormalOnlyAndAllWithCriticalFirst() throws {
        let root = OrbApprovalQueue.legacyItem(kind: "privilege", try json(["id": "p1", "state": "pending", "scope": "root_exec", "target_host": "self", "requester_mission_id": "m1"]))
        let read = OrbApprovalQueue.legacyItem(kind: "privilege", try json(["id": "p2", "state": "pending", "scope": "ops_read", "target_host": "ashur", "requester_mission_id": "m1"]))
        XCTAssertEqual(OrbApprovalQueue.normalBatch([read, root]).map { $0["id"].text }, ["p2"])
        XCTAssertEqual(OrbApprovalQueue.allBatch([read, root]).map { $0["id"].text }, ["p1", "p2"])
        XCTAssertEqual(OrbApprovalQueue.approveAllLabel([read, root]), "Approve all (2, incl. 1 critical)")
        XCTAssertEqual(OrbApprovalQueue.approveAllLabel([read]), "Approve all")
    }

    func testV1AndV2SubjectDigestsMatchSharedFixture() throws {
        let spec = try OrbSpec.json("fixtures/approvals.json")
        let digests = try XCTUnwrap(spec["digests"] as? [[String: Any]])
        XCTAssertFalse(digests.isEmpty)
        for v in digests {
            let subject = try json(try XCTUnwrap(v["subject"]))
            let fields = try XCTUnwrap(v["fields"] as? [String])
            XCTAssertEqual(OrbMissionAccessMonitor.canonicalSubjectId(subject), v["canonical_subject"] as? String)
            XCTAssertEqual(
                OrbMissionAccessMonitor.approvalDigest(
                    kind: try XCTUnwrap(v["kind"] as? String),
                    id: try XCTUnwrap(v["id"] as? String),
                    subject: subject,
                    fields: fields
                ),
                v["digest"] as? String
            )
        }
    }

    func testExternalSessionLegacyItemAndSubjectKeyPreserveIdentityWithNullMissionId() throws {
        let raw = try json([
            "id": "s9",
            "status": "pending",
            "kind": "read",
            "mission_id": NSNull(),
            "requester": [
                "kind": "external_session",
                "session_id": "c4d5e6f7-0000-4000-8000-000000000099",
                "client_kind": "local_mcp",
                "client_label": "claude-code",
                "host_hint": "macbook-air",
            ],
            "key": "OPENAI_API_KEY",
            "all_projects": false,
            "reason": "need key",
            "created_at": "2026-10-29T10:00:00Z",
        ])
        let ext = OrbApprovalQueue.legacyItem(kind: "secret", raw)
        XCTAssertEqual(ext["requester_mission_id"], .null)
        XCTAssertEqual(OrbApprovalQueue.requester(ext), "External · macbook-air (claude-code)")
        XCTAssertEqual(OrbApprovalQueue.signingReason([ext]), "Read OPENAI_API_KEY for External · macbook-air (claude-code)")
        XCTAssertEqual(OrbMissionAccessMonitor.subjectKey(raw), "session:c4d5e6f7-0000-4000-8000-000000000099")
    }

    func testControlMissionLegacyItemLabelsAndTier() throws {
        let raw = try json([
            "id": "a2",
            "state": "pending",
            "scope": "control",
            "requester_mission_id": "m2",
            "requester_title": "Fleet health",
            "target_mission_id": "t1",
            "target_title": "Disk cleanup",
            "reason": "queue follow-up",
            "ttl_hours": 12,
            "created_at": "2026-10-31T10:00:00Z",
        ])
        let ctrl = OrbApprovalQueue.legacyItem(kind: "mission_access", raw)
        XCTAssertEqual(ctrl["tier"].text, "control_mission")
        XCTAssertEqual(ctrl["risk"].text, "elevated")
        XCTAssertEqual(OrbApprovalQueue.title(ctrl), "Control Disk cleanup")
        XCTAssertEqual(OrbApprovalQueue.detail(ctrl), "Allows messages, answers, cancel and resume · 12 h")
    }
}
