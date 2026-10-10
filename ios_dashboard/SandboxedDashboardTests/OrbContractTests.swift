import XCTest
@testable import sandboxed_sh

final class OrbContractTests: XCTestCase {
    func testInboxAccountSurvivesTokenRenewalAndSeparatesUsers() {
        func token(_ subject: String, _ expiry: Int) -> String {
            let data = Data("{\"sub\":\"\(subject)\",\"exp\":\(expiry)}".utf8)
            return "header." + data.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
        }
        let a = OrbInboxAccount.scope(endpoint: "https://core.test/", token: token("alice", 1))
        XCTAssertEqual(a, OrbInboxAccount.scope(endpoint: "https://core.test", token: token("alice", 2)))
        XCTAssertNotEqual(a, OrbInboxAccount.scope(endpoint: "https://core.test", token: token("bob", 2)))
        XCTAssertNotEqual(a, OrbInboxAccount.scope(endpoint: "https://other.test", token: token("alice", 2)))
        XCTAssertNotEqual(OrbInboxAccount.scope(endpoint: "https://core.test", token: "opaque-a"), OrbInboxAccount.scope(endpoint: "https://core.test", token: "opaque-b"))
    }

    @MainActor func testManualUnreadReceiptIsVisibleImmediatelyWithoutNetwork() {
        let id = UUID().uuidString
        let row = OrbRow(.object(["id": .string(id), "status": .string("completed"), "updated_at": .string("2026-10-09T10:00:00Z")]))
        let store = OrbMissionUnreadStore.shared
        store.markRead(row, syncBackend: false)
        XCTAssertFalse(store.isUnread(row: row))
        let before = store.version
        store.markUnread(id: id, syncBackend: false)
        XCTAssertGreaterThan(store.version, before)
        XCTAssertTrue(store.isUnread(row: row))
        store.markRead(row, syncBackend: false)
        XCTAssertFalse(store.isUnread(row: row))
    }
    func testInboxAutonomousScopeIsOptIn() {
        let child = OrbRow(.object(["id": .string("child"), "status": .string("failed"), "parent_mission_id": .string("parent")]))
        let controller = OrbRow(.object(["id": .string("cron"), "status": .string("completed"), "tags": .array([.string("origin:hermes")])]))
        let human = OrbRow(.object(["id": .string("human"), "status": .string("completed")]))
        XCTAssertTrue(OrbInboxModel.isSubagent(row: child))
        XCTAssertTrue(OrbInboxModel.isSubagent(row: controller))
        XCTAssertFalse(OrbInboxModel.isSubagent(row: human))
        XCTAssertFalse(OrbInboxModel.isSubagent(row: child, includeAutonomous: true))
        XCTAssertEqual(OrbInboxModel.classify(row: child, interaction: nil), .hidden)
    }
    @MainActor func testReadCacheCoalescesAndInvalidates() async throws {
        let key = "test-cache:" + UUID().uuidString
        defer { OrbDisk.remove(key) }
        var requests = 0
        let fetch: @MainActor () async throws -> OrbJSON = {
            requests += 1
            try await Task.sleep(for: .milliseconds(30))
            return .string("loaded")
        }
        async let first = OrbReadCache.load(key, fetch: fetch)
        async let second = OrbReadCache.load(key, fetch: fetch)
        let results = try await [first, second]
        XCTAssertEqual(results, [.string("loaded"), .string("loaded")])
        XCTAssertEqual(requests, 1)
        _ = try await OrbReadCache.load(key, fetch: fetch)
        XCTAssertEqual(requests, 1)
        OrbReadCache.invalidate(key)
        XCTAssertEqual(OrbReadCache.read(key), .string("loaded"))
        _ = try await OrbReadCache.load(key, fetch: fetch)
        XCTAssertEqual(requests, 2)
    }
    func testClientMissionsAreVisibleAndSideMissionsAreExcluded() throws {
        let client = OrbRow(.object(["id": .string("local"), "tags": .array([.string("placement:client")])]))
        XCTAssertTrue(client.mobile)
        let btw = OrbRow(.object(["id": .string("side"), "tags": .array([.string("btw-parent:123")])]))
        XCTAssertFalse(btw.mobile)
        let cloud = OrbRow(.object(["id": .string("cloud"), "backend": .string("cloud_chatgpt")]))
        XCTAssertTrue(cloud.mobile)
        XCTAssertTrue(cloud.cloud)
    }
    func testMissionTreeNestingAndParentRetention() {
        let parent = OrbRow(.object(["id": .string("parent"), "title": .string("Parent"), "status": .string("acknowledged")]))
        let child1 = OrbRow(.object(["id": .string("child-1"), "title": .string("Subagent 1"), "status": .string("active"), "parent_mission_id": .string("parent")]))
        let child2 = OrbRow(.object(["id": .string("child-2"), "title": .string("Subagent 2"), "status": .string("completed"), "callback_parent_mission_id": .string("parent")]))
        let standalone = OrbRow(.object(["id": .string("standalone"), "title": .string("Standalone"), "status": .string("acknowledged")]))

        let retained = OrbMissionTree.treeRows([parent, child1, child2, standalone]) { $0.state != "acknowledged" }
        XCTAssertEqual(retained.map(\.id), ["parent", "child-1", "child-2"])

        let roots = OrbMissionTree.nest(retained)
        XCTAssertEqual(roots.map(\.id), ["parent"])
        XCTAssertEqual(roots[0].children.map(\.id), ["child-1", "child-2"])
        XCTAssertEqual(OrbMissionTree.countNested(roots[0]), 2)
        XCTAssertEqual(OrbMissionTree.countNested(roots[0], matches: \.active), 1)
    }
    func testRemoteFollowupOmitsLocalIdentityAcrossPlacementFormats() {
        let local: [String: OrbJSON] = ["project": .string("default"), "track": .string("mission-123"), "github_pr": .null]
        XCTAssertEqual(OrbContinuation.identity(for: .object(local)), .object(local))
        for placement: [String: OrbJSON] in [
            ["remote_node_id": .string("babylon")],
            ["remote_job": .object(["node_id": .string("babylon")])],
            ["execution": .object(["scope_unit": .string("remote-node:babylon")])]
        ] {
            XCTAssertNil(OrbContinuation.identity(for: .object(local.merging(placement) { _, new in new })))
        }
        XCTAssertNil(OrbContinuation.identity(for: .object([:])))
    }

    func testFolderTagKeepsNestedPath() {
        let row = OrbRow(.object(["id": .string("a"), "tags": .array([.string("orb-folder:Design/Images")])]))
        XCTAssertEqual(row.folder, "Design/Images")
    }
    func testWireRoundTripPreservesProviderParameters() throws {
        let value = OrbJSON.object(["params": .array([.object(["id": .string("effort"), "value": .string("high")])]), "available": .bool(true)])
        XCTAssertEqual(try JSONDecoder().decode(OrbJSON.self, from: JSONEncoder().encode(value)), value)
    }
    func testCreationRequiresDestinationAccountAndRepository() {
        var selection = OrbSelection()
        XCTAssertThrowsError(try selection.validate())
        selection.provider = "cursor_cloud"; selection.account = "test"
        XCTAssertThrowsError(try selection.validate())
        selection.repository = "https://github.com/example/test"
        XCTAssertThrowsError(try selection.validate())
        selection.gitRef = "main"
        XCTAssertNoThrow(try selection.validate())
    }
    func testFirstAvailableNodeSelectsLeastLoadedOnlineNode() {
        let gib = 1024.0 * 1024.0 * 1024.0
        let nodes: [OrbJSON] = [
            .object(["id": .string("ashur"), "status": .string("online"), "cordoned": .bool(false), "active_jobs": .number(0), "mem_available_bytes": .number(30 * gib)]),
            .object(["id": .string("babylon"), "status": .string("online"), "cordoned": .bool(false), "active_jobs": .number(0), "mem_available_bytes": .number(60 * gib)]),
            .object(["id": .string("nippur"), "status": .string("online"), "cordoned": .bool(false), "active_jobs": .number(1), "mem_available_bytes": .number(100 * gib)]),
            .object(["id": .string("dgx-spark-admin"), "status": .string("online"), "cordoned": .bool(false), "labels": .array([.string("manual-only")]), "active_jobs": .number(0), "mem_available_bytes": .number(120 * gib)]),
            .object(["id": .string("sepolia"), "status": .string("offline"), "cordoned": .bool(false), "active_jobs": .number(0), "mem_available_bytes": .number(128 * gib)])
        ]
        let sorted = OrbSelection.sortedComputeNodes(nodes)
        XCTAssertEqual(sorted.map { $0["id"].text }, ["babylon", "ashur", "nippur", "dgx-spark-admin", "sepolia"])
        XCTAssertEqual(OrbSelection.firstAvailableNodeID(nodes), "babylon")
    }
}
