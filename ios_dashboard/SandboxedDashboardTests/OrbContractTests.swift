import XCTest
@testable import sandboxed_sh

final class OrbContractTests: XCTestCase {
    @MainActor func testCrashBreadcrumbsAreStructuralAndErrorRingIsBounded() {
        ErrorRing.shared.clear()
        OrbCrashBreadcrumbs.enterConversation(missionId: "mission-structural-id", turnCount: 2)
        OrbCrashBreadcrumbs.recordCrash(reason: "NilMemoryCrash", topFrame: nil, memoryMB: nil)
        OrbCrashBreadcrumbs.drainPendingIntoErrorRing()
        XCTAssertTrue(ErrorRing.shared.entries.last?.message.contains("reason=NilMemoryCrash") == true)
        OrbCrashBreadcrumbs.recordCrash(reason: "TestCrash", topFrame: "Frame", memoryMB: 12)
        OrbCrashBreadcrumbs.drainPendingIntoErrorRing()
        XCTAssertTrue(ErrorRing.shared.entries.last?.message.contains("missionId=mission-structural-id") == true)
        XCTAssertFalse(ErrorRing.shared.entries.last?.message.contains("prompt") == true)
        for n in 0...ErrorRing.capacity { ErrorRing.shared.record(category: .crash, path: "crash", status: nil, message: "structural-\(n)") }
        XCTAssertEqual(ErrorRing.shared.entries.count, ErrorRing.capacity)
    }

    @MainActor func testPresentationKeepsAnswerAndExcludesQueuedPromptsAndTools() {
        for type in ["assistant_message", "assistant_message_canonical"] {
            let value: OrbJSON = .object(["events": .array([
                .object(["event_type": .string(type), "content": .string("Final answer")]),
                .object(["event_type": .string("user_message"), "content": .string("Next"), "metadata": .object(["queued": .bool(true)])]),
                .object(["event_type": .string("tool_result"), "content": .string("Large output")])
            ])])
            let history = OrbPresentation.history(value)
            XCTAssertEqual(history.count, 1)
            XCTAssertEqual(history.first?["content"].text, "Final answer")
            XCTAssertEqual(history.first?["role"].text, "assistant")
        }
    }

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
    @MainActor func testUnreadReceiptSurvivesRestartAndClockSkew() throws {
        let id = UUID().uuidString
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let row = OrbRow(.object(["id": .string(id), "status": .string("completed"), "updated_at": .string(future)]))
        let store = OrbMissionUnreadStore.shared
        store.markRead(row, syncBackend: false)
        store.markUnread(id: id, updatedAt: future, syncBackend: false)
        XCTAssertTrue(store.isUnread(row: row))
        store.markAllRead([row], syncBackend: false)
        XCTAssertFalse(store.isUnread(row: row))
        let key = OrbSharedInboxState.outboxKey(OrbInboxAccount.current)
        let previous = UserDefaults.standard.data(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        let pending = ["seen/" + id: OrbJSON.object(["stamp": .number(-Date().addingTimeInterval(7200).timeIntervalSince1970 * 1000)])]
        UserDefaults.standard.set(try JSONEncoder().encode(pending), forKey: key)
        XCTAssertEqual(OrbSharedInboxState().unread(row), true)
    }
    @MainActor func testLegacyInboxPreferencesClaimOnlyTheirFirstAccount() {
        let p = OrbInboxSettings.shared
        let savedOwner = UserDefaults.standard.string(forKey: OrbInboxSettings.ownerKey)
        let original = (p.inboxEnabled, p.aiSummary, p.summaryMode, p.includeAutonomous, p.model)
        let previous = OrbSharedInboxState.shared.applying
        OrbSharedInboxState.shared.applying = true
        defer {
            p.inboxEnabled = original.0; p.aiSummary = original.1; p.summaryMode = original.2; p.includeAutonomous = original.3; p.model = original.4
            UserDefaults.standard.set(savedOwner, forKey: OrbInboxSettings.ownerKey)
            OrbSharedInboxState.shared.applying = previous
        }
        UserDefaults.standard.removeObject(forKey: OrbInboxSettings.ownerKey)
        p.inboxEnabled = false; p.aiSummary = false; p.summaryMode = .eco; p.includeAutonomous = true; p.model = "builtin/fast"
        p.bindAccount("test:alice")
        XCTAssertFalse(p.inboxEnabled); XCTAssertFalse(p.aiSummary); XCTAssertEqual(p.summaryMode, .eco); XCTAssertTrue(p.includeAutonomous); XCTAssertEqual(p.model, "builtin/fast")
        p.bindAccount("test:bob")
        XCTAssertTrue(p.inboxEnabled); XCTAssertTrue(p.aiSummary); XCTAssertEqual(p.summaryMode, .standard); XCTAssertFalse(p.includeAutonomous); XCTAssertEqual(p.model, OrbInboxSettings.defaultModel)
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
    @MainActor func testListSummaryCannotMaskDiskConversationAfterMemoryTrim() async throws {
        let key = "mission:" + UUID().uuidString
        defer { OrbDisk.remove(key) }
        let full: OrbJSON = .object(["history": .array([
            .object(["role": .string("assistant"), "content": .string("Saved answer")])
        ])])
        try OrbDisk.save(full, key: key)
        OrbReadCache.trimMemory()
        OrbReadCache.seedMemory(key, value: .object(["history": .array([])]))
        let reopened = await OrbReadCache.readAsync(key)
        XCTAssertEqual(reopened, full, "Reopening must show saved history before any network request")
        OrbReadCache.seed(key, value: .object(["history": .array([])]))
        XCTAssertEqual(OrbReadCache.read(key), full)
        XCTAssertEqual(OrbDisk.read(key, as: OrbJSON.self), full)
    }

    @MainActor func testAsyncCacheReadKeepsFreshNetworkValue() async throws {
        let key = "test-cache:" + UUID().uuidString
        defer { OrbDisk.remove(key) }
        try OrbDisk.save(OrbJSON.string("old"), key: key)
        _ = try await OrbReadCache.load(key, force: true) { .string("fresh") }
        let reopened = await OrbReadCache.readAsync(key)
        XCTAssertEqual(reopened, .string("fresh"))
    }

    @MainActor func testLargeHistoryRestoreKeepsMainActorAvailable() async throws {
        let key = "mission:" + UUID().uuidString
        defer { OrbDisk.remove(key) }
        let history: OrbJSON = .object(["history": .array((0..<200).map { index in
            .object(["role": .string("assistant"), "content": .string("\(index):" + String(repeating: "a", count: 16_384))])
        })])
        try OrbDisk.save(history, key: key)
        let start = ContinuousClock.now
        let baseline = OrbDisk.read(key, as: OrbJSON.self)
        let synchronousTime = start.duration(to: .now)
        XCTAssertEqual(baseline, history)

        var mainActorTicks = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                mainActorTicks += 1
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        let asyncStart = ContinuousClock.now
        let restored = await OrbReadCache.readAsync(key)
        let asynchronousTime = asyncStart.duration(to: .now)
        heartbeat.cancel()
        XCTAssertEqual(restored, history)
        XCTAssertGreaterThan(mainActorTicks, 0, "Disk restoration must yield the main actor")
        print("CACHE_RESTORE 200x16KiB synchronous-main=\(synchronousTime) async-wall=\(asynchronousTime) main-actor-ticks=\(mainActorTicks)")
    }
    /// A send invalidates the conversation while a streamed event's refresh is loading it.
    /// Both the owner and a joined waiter get the answer (no CancellationError, which showed
    /// "Connection unavailable … cancelled" after every send), it is not cached, and the
    /// next load fetches again.
    @MainActor func testReadCacheInvalidateDuringLoadDoesNotFailWaiters() async throws {
        let key = "test-cache:" + UUID().uuidString
        defer { OrbDisk.remove(key) }
        var requests = 0
        let fetch: @MainActor () async throws -> OrbJSON = {
            requests += 1
            try await Task.sleep(for: .milliseconds(80))
            return .string("v\(requests)")
        }
        async let owner = OrbReadCache.load(key, force: true, fetch: fetch)
        async let waiter = OrbReadCache.load(key, force: true, fetch: fetch)
        try await Task.sleep(for: .milliseconds(20))
        OrbReadCache.invalidate(key)
        let results = try await [owner, waiter]
        XCTAssertEqual(results, [.string("v1"), .string("v1")])
        XCTAssertNil(OrbReadCache.read(key), "a superseded answer is not cached")
        let fresh = try await OrbReadCache.load(key, fetch: fetch)
        XCTAssertEqual(fresh, .string("v2"))
    }
    func testClientMissionsAreVisibleAndSideMissionsAreExcluded() throws {
        let client = OrbRow(.object(["id": .string("local"), "tags": .array([.string("placement:client")])]))
        XCTAssertTrue(client.mobile)
        let btw = OrbRow(.object(["id": .string("side"), "tags": .array([.string("btw-parent:123")])]))
        XCTAssertFalse(btw.mobile)
        let cloud = OrbRow(.object(["id": .string("cloud"), "backend": .string("cloud_grok_bot")]))
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
        // Offline and manual-only nodes are both ineligible. Within that
        // group the same load/RAM ordering applies; neither may be auto-picked.
        XCTAssertEqual(sorted.map { $0["id"].text }, ["babylon", "ashur", "nippur", "sepolia", "dgx-spark-admin"])
        XCTAssertNil(OrbSelection.firstAvailableNodeID(Array(nodes.suffix(2))))
        XCTAssertEqual(OrbSelection.firstAvailableNodeID(nodes), "babylon")
    }

    func testLatestForkLeadsAndEarlierVersionsFoldInside() {
        let original = OrbRow(.object(["id": .string("ev"), "title": .string("EV Bench"), "backend": .string("claudecode"), "updated_at": .string("2026-10-14T10:00:00Z")]))
        let fork = OrbRow(.object(["id": .string("ev-fork"), "title": .string("EV Bench · fork"), "parent_mission_id": .string("ev"), "backend": .string("codex"), "updated_at": .string("2026-10-14T12:00:00Z")]))
        let roots = OrbMissionTree.nest([original, fork])
        XCTAssertEqual(roots.map(\.id), ["ev-fork"])
        XCTAssertEqual(roots.first?.mission.name, "EV Bench")
        XCTAssertEqual(roots.first?.children.map(\.id), ["ev"])
        XCTAssertEqual(roots.first?.children.first?.version, true)
        XCTAssertEqual(OrbMissionTree.countNested(roots[0]), 0)
        XCTAssertNil(fork.parentMissionID)
        XCTAssertFalse(OrbInboxModel.isSubagent(row: fork))
    }

    func testParentLinkIsStickyAcrossPayloadsThatOmitIt() {
        OrbHierarchy.reset()
        let parent = OrbRow(.object(["id": .string("sticky-p"), "title": .string("Boss"), "updated_at": .string("2026-10-14T10:00:00Z")]))
        let full = OrbRow(.object(["id": .string("sticky-c"), "title": .string("Worker"), "callback_parent_mission_id": .string("sticky-p"), "updated_at": .string("2026-10-14T11:00:00Z")]))
        XCTAssertEqual(full.parentMissionID, "sticky-p")
        // A resume answer or a list served while Hermes restarts: no derived link.
        let partial = OrbRow(.object(["id": .string("sticky-c"), "title": .string("Worker"), "status": .string("running"), "updated_at": .string("2026-10-14T12:00:00Z")]))
        XCTAssertEqual(partial.parentMissionID, "sticky-p")
        XCTAssertEqual(OrbMissionTree.nest([parent, partial]).map(\.id), ["sticky-p"])
        OrbHierarchy.reparent("sticky-c", parent: nil)
        XCTAssertNil(partial.parentMissionID)
        OrbHierarchy.reset()
    }

    func testForkLeaderPrefersUnretiredAndLiveAndNewlyCreatedForks() {
        // Production incident replay (`86d91cc3` -> `65407660` / `d65744b9`):
        // an archived or interrupted ancestor with a newer timestamp never demotes a live fork.
        let archivedRoot = OrbRow(.object([
            "id": .string("86d91cc3"),
            "title": .string("Orb: leaninification"),
            "status": .string("acknowledged"),
            "created_at": .string("2026-10-28T23:00:00Z"),
            "updated_at": .string("2026-10-29T05:50:00Z")
        ]))
        let worker = OrbRow(.object([
            "id": .string("9bfbb6e4"),
            "title": .string("Audit spec worker"),
            "status": .string("completed"),
            "parent_mission_id": .string("86d91cc3"),
            "updated_at": .string("2026-10-29T05:00:00Z")
        ]))
        let completedSibling = OrbRow(.object([
            "id": .string("d65744b9"),
            "title": .string("Orb: leaninification"),
            "status": .string("completed"),
            "tags": .array([.string("fork-of:86d91cc3")]),
            "created_at": .string("2026-10-29T05:05:00Z"),
            "updated_at": .string("2026-10-29T05:49:00Z")
        ]))
        let activeFork = OrbRow(.object([
            "id": .string("65407660"),
            "title": .string("Orb: leaninification"),
            "status": .string("active"),
            "tags": .array([.string("fork-of:86d91cc3")]),
            "created_at": .string("2026-10-29T05:31:00Z"),
            "updated_at": .string("2026-10-29T05:31:00Z")
        ]))
        let retained = OrbMissionTree.treeRows([archivedRoot, worker, completedSibling, activeFork]) { $0.state != "acknowledged" }
        let nestedActive = OrbMissionTree.nest(retained)
        XCTAssertEqual(nestedActive.map(\.id), ["65407660"])

        // Even if the ancestor was spuriously resurrected and stalled into `interrupted` at 05:48:22Z,
        // the live fork (`65407660`) still leads, and after `65407660` stops at 06:02:22Z it stays on top.
        let stalledRoot = OrbRow(.object([
            "id": .string("86d91cc3"),
            "title": .string("Orb: leaninification"),
            "status": .string("interrupted"),
            "created_at": .string("2026-10-28T23:00:00Z"),
            "updated_at": .string("2026-10-29T05:48:22Z")
        ]))
        XCTAssertEqual(OrbMissionTree.nest([stalledRoot, worker, completedSibling, activeFork]).map(\.id), ["65407660"])
        let stoppedFork = OrbRow(.object([
            "id": .string("65407660"),
            "title": .string("Orb: leaninification"),
            "status": .string("interrupted"),
            "tags": .array([.string("fork-of:86d91cc3")]),
            "created_at": .string("2026-10-29T05:31:00Z"),
            "updated_at": .string("2026-10-29T06:02:22Z")
        ]))
        XCTAssertEqual(OrbMissionTree.nest([stalledRoot, worker, completedSibling, stoppedFork]).map(\.id), ["65407660"])

        // Harness conversion settle window: source stopped 6s after fork creation (or tied timestamp)
        // never steals leadership from the newly created fork, regardless of array order.
        let codexSource = OrbRow(.object([
            "id": .string("codex-src"),
            "title": .string("Convert me"),
            "status": .string("interrupted"),
            "backend": .string("codex"),
            "created_at": .string("2026-10-29T02:00:00Z"),
            "updated_at": .string("2026-10-29T02:25:17Z")
        ]))
        let opencodeFork = OrbRow(.object([
            "id": .string("opencode-fork"),
            "title": .string("Convert me"),
            "status": .string("interrupted"),
            "backend": .string("opencode"),
            "tags": .array([.string("fork-of:codex-src")]),
            "created_at": .string("2026-10-29T02:25:11Z"),
            "updated_at": .string("2026-10-29T02:25:11Z")
        ]))
        XCTAssertEqual(OrbMissionTree.nest([codexSource, opencodeFork]).map(\.id), ["opencode-fork"])
        XCTAssertEqual(OrbMissionTree.nest([opencodeFork, codexSource]).map(\.id), ["opencode-fork"])

        // Returning to the original well after the settle window makes the original lead again.
        let resumedSource = OrbRow(.object([
            "id": .string("codex-src"),
            "title": .string("Convert me"),
            "status": .string("completed"),
            "backend": .string("codex"),
            "created_at": .string("2026-10-29T02:00:00Z"),
            "updated_at": .string("2026-10-29T03:00:00Z")
        ]))
        XCTAssertEqual(OrbMissionTree.nest([resumedSource, opencodeFork]).map(\.id), ["codex-src"])
    }

    func testBtwSideSessionAndDescendantSubtreeAreExcludedInAnyOrder() {
        OrbHierarchy.reset()
        // Production incident replay (`0c532a32` -> `23af9c91` -> `6b1abe32`):
        // a worker launched by a `/btw` side session lacks `btw-parent:*` and must
        // still be excluded even when listed before its `/btw` parent.
        let mainJSON: OrbJSON = .object([
            "id": .string("0c532a32"),
            "title": .string("evm.fast"),
            "status": .string("active"),
            "updated_at": .string("2026-10-30T02:20:00Z")
        ])
        let btwJSON: OrbJSON = .object([
            "id": .string("23af9c91"),
            "title": .string("evm.fast · btw"),
            "status": .string("active"),
            "tags": .array([.string("fork-workspace:52bbf658"), .string("btw-parent:0c532a32")]),
            "updated_at": .string("2026-10-30T02:13:00Z")
        ])
        let legacyWorkerJSON: OrbJSON = .object([
            "id": .string("6b1abe32"),
            "title": .string("Carbon 4 strategy consult"),
            "status": .string("completed"),
            "parent_mission_id": .string("23af9c91"),
            "tags": .array([.string("consult-model"), .string("origin:mission")]),
            "updated_at": .string("2026-10-30T02:15:00Z")
        ])
        let grandchildJSON: OrbJSON = .object([
            "id": .string("9911aa22"),
            "title": .string("Verifier check"),
            "status": .string("completed"),
            "parent_mission_id": .string("6b1abe32"),
            "updated_at": .string("2026-10-30T02:16:00Z")
        ])
        let taggedSubagentJSON: OrbJSON = .object([
            "id": .string("7788ccdd"),
            "title": .string("Tagged /btw subagent"),
            "status": .string("completed"),
            "tags": .array([.string("btw-subagent")]),
            "updated_at": .string("2026-10-30T02:17:00Z")
        ])

        // Child-before-parent order (`updated_at DESC`):
        OrbHierarchy.reset()
        let childFirst = [grandchildJSON, legacyWorkerJSON, btwJSON, taggedSubagentJSON, mainJSON].map { OrbRow($0) }.filter(\.mobile)
        XCTAssertEqual(childFirst.map(\.id), ["0c532a32"])

        // Sticky memory: if a later page omits `btwJSON` and `parent_mission_id`, `6b1abe32` stays hidden.
        let partialWorker = OrbRow(.object([
            "id": .string("6b1abe32"),
            "title": .string("Carbon 4 strategy consult"),
            "status": .string("completed")
        ]))
        XCTAssertFalse(partialWorker.mobile)
        XCTAssertEqual(OrbInboxModel.classify(row: partialWorker, interaction: nil, includeAutonomous: true), .hidden)
        OrbHierarchy.reset()
    }

    func testOpenBeyondPageWithAncestorsPlaceholdersAndSupersededParity() async {
        OrbHierarchy.reset()
        let now = Date(timeIntervalSince1970: 1_793_451_600) // 2026-10-31T13:00:00Z

        // 1. M2 (`openBeyondPage`): live roots/children always kept; stopped roots kept < 7d; stale or unlisted-parent stopped children dropped.
        let page0 = [
            OrbRow(.object([
                "id": .string("listed-root"),
                "title": .string("Recent root"),
                "status": .string("completed"),
                "updated_at": .string("2026-10-31T12:55:00Z")
            ]))
        ]
        let openPool = [
            OrbRow(.object([
                "id": .string("9409f9a9"),
                "title": .string("evm.fast (claude takeover)"),
                "status": .string("active"),
                "updated_at": .string("2026-09-25T10:00:00Z") // > 30d old, still live -> kept
            ])),
            OrbRow(.object([
                "id": .string("recent-stopped"),
                "title": .string("Recent interrupted"),
                "status": .string("interrupted"),
                "updated_at": .string("2026-10-29T12:00:00Z") // 2d old -> kept
            ])),
            OrbRow(.object([
                "id": .string("stale-stopped"),
                "title": .string("Old interrupted"),
                "status": .string("interrupted"),
                "updated_at": .string("2026-10-01T12:00:00Z") // 30d old -> dropped
            ])),
            OrbRow(.object([
                "id": .string("stale-child-unlisted"),
                "title": .string("Orphan interrupted worker"),
                "status": .string("interrupted"),
                "parent_mission_id": .string("completed-off-page"),
                "updated_at": .string("2026-10-30T12:00:00Z") // parent not listed & child not live -> dropped
            ])),
            OrbRow(.object([
                "id": .string("recent-child-listed"),
                "title": .string("Stopped worker of live root"),
                "status": .string("interrupted"),
                "parent_mission_id": .string("9409f9a9"),
                "updated_at": .string("2026-10-30T12:00:00Z") // parent 9409f9a9 is kept -> kept
            ])),
            OrbRow(.object([
                "id": .string("live-child-unlisted"),
                "title": .string("Live worker of paged-out completed root"),
                "status": .string("waiting_background"),
                "parent_mission_id": .string("completed-off-page"),
                "updated_at": .string("2026-10-10T12:00:00Z") // child is live -> kept so withAncestors fetches parent
            ])),
            OrbRow(.object([
                "id": .string("btw-live"),
                "title": .string("evm.fast · btw"),
                "status": .string("active"),
                "tags": .array([.string("btw-parent:9409f9a9")]),
                "updated_at": .string("2026-10-31T12:59:00Z") // /btw -> dropped
            ]))
        ]
        let beyond = OrbMissionTree.openBeyondPage(page0, extra: openPool, now: now)
        XCTAssertEqual(beyond.map(\.id), ["9409f9a9", "recent-stopped", "recent-child-listed", "live-child-unlisted"])

        // 2. Multi-hop `withAncestors` + cross-project placeholder + cross-project `/btw` exclusion (Assistant incident replay).
        OrbHierarchy.reset()
        let initialRows = [
            OrbRow(.object([
                "id": .string("gc-312-a"),
                "title": .string("Re-review PR #312 @1445a50 (P0-4)"),
                "status": .string("active"),
                "project": .string("assistant"),
                "parent_mission_id": .string("6ce45940"),
                "updated_at": .string("2026-10-31T12:58:00Z")
            ])),
            OrbRow(.object([
                "id": .string("gc-312-b"),
                "title": .string("Re-review PR #312 @1445a50 (P0-4)"),
                "status": .string("active"),
                "project": .string("assistant"),
                "parent_mission_id": .string("75a05dbd"),
                "updated_at": .string("2026-10-31T12:57:00Z")
            ])),
            OrbRow(.object([
                "id": .string("w-pr303"),
                "title": .string("PR #303 r2: drop worktree"),
                "status": .string("active"),
                "project": .string("assistant"),
                "parent_mission_id": .string("4c6242f6"),
                "updated_at": .string("2026-10-31T12:56:00Z")
            ])),
            OrbRow(.object([
                "id": .string("cross-kid"),
                "title": .string("GuestInv spec review r5"),
                "status": .string("active"),
                "project": .string("assistant"),
                "parent_mission_id": .string("9409f9a9"),
                "updated_at": .string("2026-10-31T12:55:00Z")
            ])),
            OrbRow(.object([
                "id": .string("btw-kid"),
                "title": .string("Unstamped /btw worker"),
                "status": .string("active"),
                "project": .string("assistant"),
                "parent_mission_id": .string("paged-btw"),
                "updated_at": .string("2026-10-31T12:54:00Z")
            ]))
        ]
        let remoteAncestors: [String: OrbJSON] = [
            "6ce45940": .object([
                "id": .string("6ce45940"),
                "title": .string("turbo-lean WS3"),
                "status": .string("completed"),
                "project": .string("assistant"),
                "parent_mission_id": .string("9f559751"),
                "updated_at": .string("2026-10-31T10:00:00Z")
            ]),
            "75a05dbd": .object([
                "id": .string("75a05dbd"),
                "title": .string("turbo-lean WS2"),
                "status": .string("completed"),
                "project": .string("assistant"),
                "parent_mission_id": .string("9f559751"),
                "updated_at": .string("2026-10-31T09:50:00Z")
            ]),
            "9f559751": .object([
                "id": .string("9f559751"),
                "title": .string("turbo-lean improvements"),
                "status": .string("completed"),
                "project": .string("assistant"),
                "updated_at": .string("2026-10-31T12:42:00Z")
            ]),
            "4c6242f6": .object([
                "id": .string("4c6242f6"),
                "title": .string("improve turbo-lean for clifv"),
                "status": .string("completed"),
                "project": .string("assistant"),
                "updated_at": .string("2026-10-31T08:00:00Z")
            ]),
            "9409f9a9": .object([
                "id": .string("9409f9a9"),
                "title": .string("evm.fast (claude takeover)"),
                "status": .string("active"),
                "backend": .string("claudecode"),
                "project": .string("verity-core"),
                "updated_at": .string("2026-10-30T08:00:00Z")
            ]),
            "paged-btw": .object([
                "id": .string("paged-btw"),
                "title": .string("evm.fast · btw"),
                "status": .string("active"),
                "project": .string("verity-core"),
                "tags": .array([.string("btw-parent:9409f9a9")]),
                "updated_at": .string("2026-10-31T12:50:00Z")
            ])
        ]
        let ownIDs = Set(initialRows.map(\.id))
        let withAnc = await OrbMissionTree.withAncestors(initialRows) { id in
            remoteAncestors[id].map { OrbRow($0) }
        }
        let scoped = withAnc.filter { ownIDs.contains($0.id) || $0.raw["project"].text == "assistant" }
        let mobile = OrbMissionTree.filterMobile(scoped)
        XCTAssertFalse(mobile.contains { $0.id == "btw-kid" })
        let nested = OrbMissionTree.nest(mobile, placeholder: OrbMissionTree.placeholderParent("assistant"))
        XCTAssertEqual(nested.map(\.id), ["9f559751", "4c6242f6", "9409f9a9"])
        XCTAssertEqual(OrbMissionTree.countNested(nested[0]), 4)
        XCTAssertEqual(OrbMissionTree.countNested(nested[0], matches: \.active), 2)
        XCTAssertEqual(nested[0].children.map(\.id), ["6ce45940", "75a05dbd"])
        XCTAssertEqual(nested[0].children[0].children.map(\.id), ["gc-312-a"])
        XCTAssertEqual(nested[1].children.map(\.id), ["w-pr303"])
        // Cross-project parent `9409f9a9` is rendered as a placeholder carrying seen title/backend/status/project.
        XCTAssertTrue(nested[2].mission.isPlaceholder)
        XCTAssertEqual(nested[2].mission.title, "evm.fast (claude takeover)")
        XCTAssertEqual(nested[2].mission.backend, "claudecode")
        XCTAssertEqual(nested[2].mission.state, "active")
        XCTAssertEqual(nested[2].mission.raw["project"].text, "verity-core")
        XCTAssertEqual(nested[2].children.map(\.id), ["cross-kid"])

        // 3. Transiently unfetched parent uses "Parent mission" placeholder; confirmed 404 (`markGone`) lets child stand at root.
        let transientOrphan = OrbRow(.object([
            "id": .string("orphan-transient"),
            "title": .string("Worker waiting on slow parent"),
            "status": .string("active"),
            "parent_mission_id": .string("parent-slow"),
            "updated_at": .string("2026-10-31T12:59:00Z")
        ]))
        let held = OrbMissionTree.nest([transientOrphan], placeholder: OrbMissionTree.placeholderParent("assistant"))
        XCTAssertEqual(held.map(\.id), ["parent-slow"])
        XCTAssertTrue(held[0].mission.isPlaceholder)
        XCTAssertEqual(held[0].mission.title, "Parent mission")
        XCTAssertEqual(held[0].children.map(\.id), ["orphan-transient"])

        OrbHierarchy.markGone("parent-404")
        let confirmedOrphan = OrbRow(.object([
            "id": .string("orphan-404"),
            "title": .string("Worker whose parent was deleted"),
            "status": .string("active"),
            "parent_mission_id": .string("parent-404"),
            "updated_at": .string("2026-10-31T12:59:00Z")
        ]))
        let released = OrbMissionTree.nest([confirmedOrphan], placeholder: OrbMissionTree.placeholderParent("assistant"))
        XCTAssertEqual(released.map(\.id), ["orphan-404"])
        XCTAssertFalse(released[0].mission.isPlaceholder)

        // 4. `isSupersededInTree`: hides non-live superseded missions and descendants, never live missions.
        let supParent = OrbRow(.object([
            "id": .string("sup-p"),
            "status": .string("completed"),
            "tags": .array([.string("superseded_by:new-p")])
        ]))
        let supChild = OrbRow(.object([
            "id": .string("sup-c"),
            "status": .string("completed"),
            "parent_mission_id": .string("sup-p")
        ]))
        let liveSup = OrbRow(.object([
            "id": .string("sup-live"),
            "status": .string("active"),
            "tags": .array([.string("superseded")])
        ]))
        let supMap = [supParent.id: supParent, supChild.id: supChild, liveSup.id: liveSup]
        XCTAssertTrue(OrbMissionTree.isSupersededInTree(supParent, byID: supMap))
        XCTAssertTrue(OrbMissionTree.isSupersededInTree(supChild, byID: supMap))
        XCTAssertFalse(OrbMissionTree.isSupersededInTree(liveSup, byID: supMap))
        OrbHierarchy.reset()
    }
}
