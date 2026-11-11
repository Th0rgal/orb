package sh.sandboxed.dashboard.orb

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class OrbMissionTreeTest {
    @Before
    fun clearHierarchy() = OrbMissionTree.resetHierarchy()

    private fun m(id: String, vararg extra: Pair<String, Any?>) =
        OrbRow(mapOf("id" to id, "status" to "completed", "updated_at" to "2026-10-19T10:00:00Z") + extra)

    @Test
    fun nestsChildrenUnderParents() {
        val tree = OrbMissionTree.nest(listOf(
            m("root"),
            m("child", "parent_mission_id" to "root", "status" to "running"),
            m("grandchild", "tags" to listOf("parent:child")),
            m("orphan", "parent_mission_id" to "missing"),
        ))
        assertEquals(listOf("root", "orphan"), tree.map { it.id })
        val root = tree.first()
        assertEquals(listOf("child"), root.children.map { it.id })
        assertEquals(1, root.children[0].depth)
        assertEquals(listOf("grandchild"), root.children[0].children.map { it.id })
        assertEquals(2, root.childCount)
        assertEquals(1, root.runningChildCount)
    }

    @Test
    fun forksAreVersionsNotChildren() {
        val tree = OrbMissionTree.nest(listOf(
            m("orig", "updated_at" to "2026-10-19T09:00:00Z"),
            m("fork", "tags" to listOf("fork-of:orig"), "updated_at" to "2026-10-19T11:00:00Z"),
        ))
        assertEquals(1, tree.size)
        val leader = tree.first()
        assertEquals("fork", leader.id)
        assertEquals(1, leader.versionCount)
        assertEquals(0, leader.childCount)
        assertTrue(leader.children.single().version)
    }

    @Test
    fun parentCyclesDoNotRecurseForever() {
        val tree = OrbMissionTree.nest(listOf(
            m("a", "parent_mission_id" to "b"),
            m("b", "parent_mission_id" to "a"),
            m("self", "parent_mission_id" to "self"),
        ))
        fun all(nodes: List<OrbNestedMission>): List<String> =
            nodes.flatMap { listOf(it.id) + all(it.children) }
        // Matches desktop `orb/tests/mission-tree.test.ts` & iOS: a link that would close a loop stays at the top so no mission vanishes.
        assertEquals(listOf("a", "b", "self"), all(tree).sorted())
        assertTrue("self" in tree.map { it.id })
    }

    @Test
    fun flattenRespectsExpansion() {
        val tree = OrbMissionTree.nest(listOf(m("root"), m("kid", "parent_mission_id" to "root")))
        assertEquals(listOf("root"), OrbMissionTree.flatten(tree, emptySet()).map { it.id })
        assertEquals(listOf("root", "kid"), OrbMissionTree.flatten(tree, setOf("root")).map { it.id })
    }

    @Test
    fun liveUsesSharedStateTable() {
        assertTrue(OrbMissionTree.isLive(m("x", "status" to "waiting_background")))
        assertTrue(!OrbMissionTree.isLive(m("x", "status" to "paused")))
    }

    @Test
    fun clientPlacementHonorsCanonicalFieldWithLegacyFallback() {
        assertTrue(m("canonical", "placement_kind" to "client").isClientPlacement())
        assertTrue(m("scoped-client", "placement_kind" to "client:m2air").isClientPlacement())
        assertTrue(m("legacy-origin", "origin" to "orb-client").isClientPlacement())
        assertTrue(m("legacy-tag", "tags" to listOf("placement:client")).isClientPlacement())
        assertFalse(
            m(
                "adopted-server",
                "placement_kind" to "server",
                "origin" to "orb-client",
                "tags" to listOf("placement:client"),
            ).isClientPlacement()
        )
        assertFalse(m("remote", "placement_kind" to "remote_node:ashur", "origin" to "orb-client").isClientPlacement())
    }

    @Test
    fun parentLinkIsStickyAcrossPayloadsThatOmitIt() {
        OrbMissionTree.resetHierarchy()
        val full = m("sticky-c", "callback_parent_mission_id" to "sticky-p")
        assertEquals("sticky-p", OrbMissionTree.parentId(full))
        // A resume answer or a list served while Hermes restarts: no derived link.
        val partial = m("sticky-c", "status" to "running")
        assertEquals("sticky-p", OrbMissionTree.parentId(partial))
        assertEquals(listOf("sticky-p"), OrbMissionTree.nest(listOf(m("sticky-p"), partial)).map { it.id })
        OrbMissionTree.reparent("sticky-c", null)
        assertEquals(null, OrbMissionTree.parentId(partial))
        OrbMissionTree.resetHierarchy()
    }

    @Test
    fun forkLeaderPrefersUnretiredAndLiveAndNewlyCreatedForks() {
        val archivedRoot = m(
            "86d91cc3",
            "status" to "acknowledged",
            "created_at" to "2026-10-28T23:00:00Z",
            "updated_at" to "2026-10-29T05:50:00Z",
        )
        val worker = m("9bfbb6e4", "parent_mission_id" to "86d91cc3", "updated_at" to "2026-10-29T05:00:00Z")
        val completedSibling = m(
            "d65744b9",
            "status" to "completed",
            "tags" to listOf("fork-of:86d91cc3"),
            "created_at" to "2026-10-29T05:05:00Z",
            "updated_at" to "2026-10-29T05:49:00Z",
        )
        val activeFork = m(
            "65407660",
            "status" to "active",
            "tags" to listOf("fork-of:86d91cc3"),
            "created_at" to "2026-10-29T05:31:00Z",
            "updated_at" to "2026-10-29T05:31:00Z",
        )
        assertEquals(listOf("65407660"), OrbMissionTree.nest(listOf(archivedRoot, worker, completedSibling, activeFork)).map { it.id })

        val stalledRoot = m(
            "86d91cc3",
            "status" to "interrupted",
            "created_at" to "2026-10-28T23:00:00Z",
            "updated_at" to "2026-10-29T05:48:22Z",
        )
        assertEquals(listOf("65407660"), OrbMissionTree.nest(listOf(stalledRoot, worker, completedSibling, activeFork)).map { it.id })

        val stoppedFork = m(
            "65407660",
            "status" to "interrupted",
            "tags" to listOf("fork-of:86d91cc3"),
            "created_at" to "2026-10-29T05:31:00Z",
            "updated_at" to "2026-10-29T06:02:22Z",
        )
        assertEquals(listOf("65407660"), OrbMissionTree.nest(listOf(stalledRoot, worker, completedSibling, stoppedFork)).map { it.id })

        val codexSource = m(
            "codex-src",
            "status" to "interrupted",
            "created_at" to "2026-10-29T02:00:00Z",
            "updated_at" to "2026-10-29T02:25:17Z",
        )
        val opencodeFork = m(
            "opencode-fork",
            "status" to "interrupted",
            "tags" to listOf("fork-of:codex-src"),
            "created_at" to "2026-10-29T02:25:11Z",
            "updated_at" to "2026-10-29T02:25:11Z",
        )
        assertEquals(listOf("opencode-fork"), OrbMissionTree.nest(listOf(codexSource, opencodeFork)).map { it.id })
        assertEquals(listOf("opencode-fork"), OrbMissionTree.nest(listOf(opencodeFork, codexSource)).map { it.id })

        val resumedSource = m(
            "codex-src",
            "status" to "completed",
            "created_at" to "2026-10-29T02:00:00Z",
            "updated_at" to "2026-10-29T03:00:00Z",
        )
        assertEquals(listOf("codex-src"), OrbMissionTree.nest(listOf(resumedSource, opencodeFork)).map { it.id })
    }

    @Test
    fun excludesBtwSideSessionsAndDescendantWorkersInAnyOrder() {
        OrbMissionTree.resetHierarchy()
        val main = m("0c532a32", "title" to "evm.fast")
        val btw = m("23af9c91", "title" to "evm.fast · btw", "tags" to listOf("fork-workspace:52bbf658", "btw-parent:0c532a32"))
        val legacyWorker = m("6b1abe32", "title" to "Carbon 4 strategy consult", "parent_mission_id" to "23af9c91", "tags" to listOf("consult-model"))
        val grandchild = m("9911aa22", "title" to "Verifier check", "parent_mission_id" to "6b1abe32")
        val taggedSubagent = m("7788ccdd", "title" to "Tagged /btw subagent", "tags" to listOf("btw-subagent"))

        // Child-before-parent order (`updated_at DESC`):
        val filtered = OrbMissionTree.filterMobile(listOf(grandchild, legacyWorker, btw, taggedSubagent, main))
        assertEquals(listOf("0c532a32"), filtered.map { it.id })

        // Sticky memory: if a subsequent partial payload omits parent_mission_id and tags, worker stays excluded.
        val partialWorker = m("6b1abe32", "title" to "Carbon 4 strategy consult")
        assertTrue(OrbMissionTree.isBtwMission(partialWorker))
        OrbMissionTree.resetHierarchy()
    }

    @Test
    fun openBeyondPageWithAncestorsPlaceholdersAndSupersededParity() = runBlocking {
        OrbMissionTree.resetHierarchy()
        val nowMs = 1_793_451_600_000L // 2026-10-31T13:00:00Z

        // 1. M2 (`openBeyondPage`): live roots/children always kept; stopped roots kept < 7d; stale or unlisted-parent stopped children dropped.
        val page0 = listOf(
            m("listed-root", "title" to "Recent root", "status" to "completed", "updated_at" to "2026-10-31T12:55:00Z")
        )
        val openPool = listOf(
            m("9409f9a9", "title" to "evm.fast (claude takeover)", "status" to "active", "updated_at" to "2026-09-25T10:00:00Z"),
            m("recent-stopped", "title" to "Recent interrupted", "status" to "interrupted", "updated_at" to "2026-10-29T12:00:00Z"),
            m("stale-stopped", "title" to "Old interrupted", "status" to "interrupted", "updated_at" to "2026-10-01T12:00:00Z"),
            m("stale-child-unlisted", "title" to "Orphan interrupted worker", "status" to "interrupted", "parent_mission_id" to "completed-off-page", "updated_at" to "2026-10-30T12:00:00Z"),
            m("recent-child-listed", "title" to "Stopped worker of live root", "status" to "interrupted", "parent_mission_id" to "9409f9a9", "updated_at" to "2026-10-30T12:00:00Z"),
            m("live-child-unlisted", "title" to "Live worker of paged-out completed root", "status" to "waiting_background", "parent_mission_id" to "completed-off-page", "updated_at" to "2026-10-10T12:00:00Z"),
            m("btw-live", "title" to "evm.fast · btw", "status" to "active", "tags" to listOf("btw-parent:9409f9a9"), "updated_at" to "2026-10-31T12:59:00Z"),
        )
        val beyond = OrbMissionTree.openBeyondPage(page0, openPool, nowMs = nowMs)
        assertEquals(
            listOf("9409f9a9", "recent-stopped", "recent-child-listed", "live-child-unlisted"),
            beyond.map { it.id }
        )

        // 2. Multi-hop `withAncestors` + cross-project placeholder + cross-project `/btw` exclusion (Assistant incident replay).
        OrbMissionTree.resetHierarchy()
        val initialRows = listOf(
            m("gc-312-a", "title" to "Re-review PR #312 @1445a50 (P0-4)", "status" to "active", "project" to "assistant", "parent_mission_id" to "6ce45940", "updated_at" to "2026-10-31T12:58:00Z"),
            m("gc-312-b", "title" to "Re-review PR #312 @1445a50 (P0-4)", "status" to "active", "project" to "assistant", "parent_mission_id" to "75a05dbd", "updated_at" to "2026-10-31T12:57:00Z"),
            m("w-pr303", "title" to "PR #303 r2: drop worktree", "status" to "active", "project" to "assistant", "parent_mission_id" to "4c6242f6", "updated_at" to "2026-10-31T12:56:00Z"),
            m("cross-kid", "title" to "GuestInv spec review r5", "status" to "active", "project" to "assistant", "parent_mission_id" to "9409f9a9", "updated_at" to "2026-10-31T12:55:00Z"),
            m("btw-kid", "title" to "Unstamped /btw worker", "status" to "active", "project" to "assistant", "parent_mission_id" to "paged-btw", "updated_at" to "2026-10-31T12:54:00Z"),
        )
        val remoteAncestors = mapOf(
            "6ce45940" to m("6ce45940", "title" to "turbo-lean WS3", "status" to "completed", "project" to "assistant", "parent_mission_id" to "9f559751", "updated_at" to "2026-10-31T10:00:00Z"),
            "75a05dbd" to m("75a05dbd", "title" to "turbo-lean WS2", "status" to "completed", "project" to "assistant", "parent_mission_id" to "9f559751", "updated_at" to "2026-10-31T09:50:00Z"),
            "9f559751" to m("9f559751", "title" to "turbo-lean improvements", "status" to "completed", "project" to "assistant", "updated_at" to "2026-10-31T12:42:00Z"),
            "4c6242f6" to m("4c6242f6", "title" to "improve turbo-lean for clifv", "status" to "completed", "project" to "assistant", "updated_at" to "2026-10-31T08:00:00Z"),
            "9409f9a9" to m("9409f9a9", "title" to "evm.fast (claude takeover)", "status" to "active", "backend" to "claudecode", "project" to "verity-core", "updated_at" to "2026-10-30T08:00:00Z"),
            "paged-btw" to m("paged-btw", "title" to "evm.fast · btw", "status" to "active", "project" to "verity-core", "tags" to listOf("btw-parent:9409f9a9"), "updated_at" to "2026-10-31T12:50:00Z"),
        )
        val ownIds = initialRows.map { it.id }.toSet()
        val withAnc = OrbMissionTree.withAncestors(initialRows) { id -> remoteAncestors[id] }
        val scoped = withAnc.filter { it.id in ownIds || it.str("project") == "assistant" }
        val mobile = OrbMissionTree.filterMobile(scoped)
        assertFalse(mobile.any { it.id == "btw-kid" })
        val nested = OrbMissionTree.nest(mobile, placeholder = OrbMissionTree.placeholderParent("assistant"))
        assertEquals(listOf("9f559751", "4c6242f6", "9409f9a9"), nested.map { it.id })
        assertEquals(4, nested[0].childCount)
        assertEquals(2, nested[0].runningChildCount)
        assertEquals(listOf("6ce45940", "75a05dbd"), nested[0].children.map { it.id })
        assertEquals(listOf("gc-312-a"), nested[0].children[0].children.map { it.id })
        assertEquals(listOf("w-pr303"), nested[1].children.map { it.id })
        // Cross-project parent `9409f9a9` is rendered as a placeholder carrying seen title/backend/status/project.
        assertTrue(OrbMissionTree.isPlaceholder(nested[2].mission))
        assertEquals("evm.fast (claude takeover)", OrbInboxModel.missionHeadline(nested[2].mission))
        assertEquals("claudecode", nested[2].mission.str("backend"))
        assertEquals("active", nested[2].mission.str("status"))
        assertEquals("verity-core", nested[2].mission.str("project"))
        assertEquals(listOf("cross-kid"), nested[2].children.map { it.id })

        // 3. Transiently unfetched parent uses "Parent mission" placeholder; confirmed 404 (`markGone`) lets child stand at root.
        val transientOrphan = m("orphan-transient", "title" to "Worker waiting on slow parent", "status" to "active", "parent_mission_id" to "parent-slow")
        val held = OrbMissionTree.nest(listOf(transientOrphan), placeholder = OrbMissionTree.placeholderParent("assistant"))
        assertEquals(listOf("parent-slow"), held.map { it.id })
        assertTrue(OrbMissionTree.isPlaceholder(held[0].mission))
        assertEquals("Parent mission", OrbInboxModel.missionHeadline(held[0].mission))
        assertEquals(listOf("orphan-transient"), held[0].children.map { it.id })

        OrbMissionTree.markGone("parent-404")
        val confirmedOrphan = m("orphan-404", "title" to "Worker whose parent was deleted", "status" to "active", "parent_mission_id" to "parent-404")
        val released = OrbMissionTree.nest(listOf(confirmedOrphan), placeholder = OrbMissionTree.placeholderParent("assistant"))
        assertEquals(listOf("orphan-404"), released.map { it.id })
        assertFalse(OrbMissionTree.isPlaceholder(released[0].mission))

        // 4. `isSupersededInTree`: hides non-live superseded missions and descendants, never live missions.
        val supParent = m("sup-p", "status" to "completed", "superseded_by_mission_id" to "new-p", "tags" to listOf("superseded_by:new-p"))
        val supChild = m("sup-c", "status" to "completed", "parent_mission_id" to "sup-p")
        val liveSup = m("sup-live", "status" to "active", "superseded_by_mission_id" to "new-live", "tags" to listOf("superseded"))
        val legacyTagOnly = m("sup-legacy-tag-only", "status" to "completed", "tags" to listOf("superseded", "superseded_by:new-p"))
        val supMap = listOf(supParent, supChild, liveSup, legacyTagOnly).associateBy { it.id }
        assertTrue(OrbMissionTree.isSupersededInTree(supParent, supMap))
        assertTrue(OrbMissionTree.isSupersededInTree(supChild, supMap))
        assertFalse(OrbMissionTree.isSupersededInTree(liveSup, supMap))
        assertFalse(OrbMissionTree.isSupersededInTree(legacyTagOnly, supMap))
        OrbMissionTree.resetHierarchy()
    }

    @Test
    fun folderColumnNormalizesNestedPathsAndIgnoresLegacyTags() {
        OrbMissionTree.resetHierarchy()
        val root = m(
            "root-folder",
            "project" to "assistant",
            "folder" to " /Design // Images/ ",
            "placement_revision" to 1L,
            "tags" to listOf("orb-folder:Stale/Legacy")
        )
        assertEquals("Design/Images", OrbMissionTree.folderPath(root))

        val legacyOnly = m(
            "legacy-only",
            "project" to "assistant",
            "folder" to "",
            "tags" to listOf("orb-folder:Stale/Legacy")
        )
        assertEquals(null, OrbMissionTree.folderPath(legacyOnly))

        val child = m(
            "child-folder",
            "project" to "assistant",
            "parent_mission_id" to "root-folder",
            "folder" to "ShouldBeCleared",
            "placement_revision" to 2L
        )
        assertEquals(null, OrbMissionTree.folderPath(child))
        OrbMissionTree.resetHierarchy()
    }

    @Test
    fun placementMergeMonotoneReconcilerAndOptimisticRollback() {
        OrbMissionTree.resetHierarchy()
        // Replay `9f559751` ("turbo-lean improvements"): moved to `default` at rev 4 with worker `06203bdc`.
        val rootBefore = m("9f559751", "project" to "assistant", "folder" to "Research", "placement_revision" to 1L)
        val workerBefore = m("06203bdc", "project" to "assistant", "parent_mission_id" to "9f559751", "folder" to "", "placement_revision" to 1L)
        assertEquals("Research", OrbMissionTree.folderPath(rootBefore))
        assertEquals("assistant", OrbMissionTree.projectSlug(rootBefore))
        assertEquals("assistant", OrbMissionTree.projectSlug(workerBefore))

        // Stage optimistic cross-project move to `default` / `""`
        val opId = OrbMissionTree.allocateOpId()
        OrbMissionTree.stageOptimisticPlacement(listOf("9f559751", "06203bdc"), opId, "default", "")
        assertEquals("default", OrbMissionTree.projectSlug(rootBefore))
        assertEquals("default", OrbMissionTree.projectSlug(workerBefore))
        assertEquals(null, OrbMissionTree.folderPath(rootBefore))

        // Stale poll from `assistant` at rev 1 arrives while optimistic op is in flight -> rejected!
        OrbMissionTree.observe(rootBefore)
        OrbMissionTree.observe(workerBefore)
        assertEquals("default", OrbMissionTree.projectSlug(rootBefore))
        assertEquals("default", OrbMissionTree.projectSlug(workerBefore))

        // Commit authoritative move at rev 4
        val accepted = OrbMissionTree.commitAuthoritativePlacements(
            listOf(
                OrbPlacementCommitItem("9f559751", "default", "Benchmarks", 4L),
                OrbPlacementCommitItem("06203bdc", "default", "Benchmarks", 4L)
            ),
            ackOpId = opId
        )
        assertEquals(2, accepted.size)
        assertEquals("default", OrbMissionTree.projectSlug(rootBefore))
        assertEquals("Benchmarks", OrbMissionTree.folderPath(rootBefore))
        assertEquals(null, OrbMissionTree.folderPath(workerBefore))

        // Late stale poll at rev 3 from `assistant` MUST be rejected (zero reversion!)
        val stalePoll = m("9f559751", "project" to "assistant", "folder" to "Research", "placement_revision" to 3L)
        assertEquals("Benchmarks", OrbMissionTree.folderPath(stalePoll))
        assertEquals("default", OrbMissionTree.projectSlug(stalePoll))

        // Test 409 approval confirmation rollback — including rendering preview-patched rows (`isPreview = true`)
        val op2 = OrbMissionTree.allocateOpId()
        OrbMissionTree.stageOptimisticPlacement(listOf("9f559751", "06203bdc"), op2, "ethereum", "Audits")
        val previewPatched = OrbReadCache.patchRowPlacement(
            stalePoll,
            OrbPlacementCommitItem("9f559751", "ethereum", "Audits", 4L, explicitProject = true, isPreview = true)
        )
        assertEquals("ethereum", OrbMissionTree.projectSlug(previewPatched))
        assertEquals("Audits", OrbMissionTree.folderPath(previewPatched))
        assertEquals(op2, OrbMissionTree.placementOf("9f559751")?.pendingOpId)

        val reverted = OrbMissionTree.rollbackOptimisticPlacement(op2)
        assertEquals(2, reverted.size)
        assertEquals("default", OrbMissionTree.projectSlug(stalePoll))
        assertEquals("Benchmarks", OrbMissionTree.folderPath(stalePoll))

        // Snapshot with explicit `project: null` and `folder: ""` at higher revision clears cached project and folder
        val unassignedPoll = m("9f559751", "project" to null, "folder" to "", "placement_revision" to 5L)
        assertEquals(null, OrbMissionTree.projectSlug(unassignedPoll))
        assertEquals(null, OrbMissionTree.folderPath(unassignedPoll))

        // Incoming WS/SSE `mission_placement_changed` commits authoritative moves and handles explicit `project: null`
        val remoteMoveEvent = OrbJSON.parse(
            """{"type":"mission_placement_changed","moves":[{"mission_id":"9f559751","project":"ethereum","folder":" /Specs/Consensus/ ","placement_revision":6},{"mission_id":"06203bdc","project":"ethereum","folder":"Specs/Consensus","placement_revision":6}]}"""
        )
        val committedFromStream = OrbMissionTree.commitIncomingPlacementEvent(remoteMoveEvent)
        assertEquals(2, committedFromStream.size)
        assertEquals("ethereum", OrbMissionTree.projectSlug(stalePoll))
        assertEquals("Specs/Consensus", OrbMissionTree.folderPath(stalePoll))
        assertEquals("ethereum", OrbMissionTree.projectSlug(workerBefore))
        assertEquals(null, OrbMissionTree.folderPath(workerBefore))

        OrbMissionTree.storeAncestor(m("9f559751", "project" to "ethereum", "folder" to "Specs/Consensus", "placement_revision" to 6L))

        val remoteUnassignEvent = OrbJSON.parse(
            """{"type":"mission_placement_changed","moves":[{"mission_id":"9f559751","project":null,"folder":"","placement_revision":7}]}"""
        )
        val committedUnassign = OrbMissionTree.commitIncomingPlacementEvent(remoteUnassignEvent)
        assertEquals(1, committedUnassign.size)
        assertEquals(null, OrbMissionTree.projectSlug(unassignedPoll))
        assertEquals(null, OrbMissionTree.folderPath(unassignedPoll))
        // Stale row or cached ancestor carrying former `project: "ethereum"` MUST resolve to unassigned, never falling back!
        assertEquals(null, OrbMissionTree.projectSlug(stalePoll))
        assertEquals("", OrbMissionTree.effectiveProject(stalePoll, fallback = "ethereum"))
        assertTrue(OrbMissionTree.hasAuthoritativePlacement(stalePoll))
        assertEquals(null, OrbMissionTree.cachedAncestor("9f559751")?.str("project"))
        assertEquals(7L, (OrbMissionTree.cachedAncestor("9f559751")?.raw?.get("placement_revision") as? Number)?.toLong())

        val err = OrbError(
            message = "Secret approvals affected",
            status = 409,
            body = """{"code":"approval_transfer_confirmation_required","error":"Secret approvals affected","target_project":"ethereum","active_grants":[{"id":"g1","secret_name":"GITHUB_TOKEN","source_project":"default"}],"pending_requests":[{"id":"r1","secret_name":"NPM_TOKEN","operation":"get"}]}"""
        )
        val parsed = OrbApprovalTransferConfirmationException.parse(err)
        assertEquals("ethereum", parsed?.targetProject)
        assertEquals(1, parsed?.activeGrants?.size)
        assertEquals("GITHUB_TOKEN", parsed?.activeGrants?.first()?.secretName)
        assertEquals(1, parsed?.pendingRequests?.size)
        assertEquals("NPM_TOKEN", parsed?.pendingRequests?.first()?.secretName)

        // Leader-only fork expansion in `subtree`: selecting the leader moves the co-located fork group + workers,
        // whereas selecting an earlier version moves ONLY that version and its own workers (never the leader).
        OrbMissionTree.resetHierarchy()
        val olderVer = m("v1", "project" to "assistant", "status" to "completed", "updated_at" to "2026-10-28T00:00:00Z")
        val olderWorker = m("v1-worker", "project" to "assistant", "parent_mission_id" to "v1", "status" to "completed", "updated_at" to "2026-10-28T01:00:00Z")
        val leaderVer = m("v2", "project" to "assistant", "tags" to listOf("fork-of:v1"), "status" to "active", "updated_at" to "2026-10-30T00:00:00Z")
        val otherProjectFork = m("v3-other", "project" to "elsewhere", "tags" to listOf("fork-of:v1"), "status" to "completed", "updated_at" to "2026-10-29T00:00:00Z")
        val roster = listOf(olderVer, olderWorker, leaderVer, otherProjectFork)

        assertEquals(setOf("v2", "v1", "v1-worker"), OrbMissionTree.subtree(roster, listOf("v2")).map { it.id }.toSet())
        assertEquals(setOf("v1", "v1-worker"), OrbMissionTree.subtree(roster, listOf("v1")).map { it.id }.toSet())

        // Overlapping optimistic moves: an earlier ack (`opA < opB`) advances revision & rollback base
        // without clobbering `opB`'s optimistic preview or allowing a rev-1 poll to revert `FolderB`.
        OrbMissionTree.resetHierarchy()
        val rapid0 = m("rapid-kt", "project" to "assistant", "folder" to "", "placement_revision" to 0L)
        OrbMissionTree.observe(rapid0)
        val opA = OrbMissionTree.allocateOpId()
        OrbMissionTree.stageOptimisticPlacement(listOf("rapid-kt"), opA, "assistant", "FolderA")
        val opB = OrbMissionTree.allocateOpId()
        OrbMissionTree.stageOptimisticPlacement(listOf("rapid-kt"), opB, "assistant", "FolderB")

        val acceptedA = OrbMissionTree.commitAuthoritativePlacements(
            listOf(OrbPlacementCommitItem("rapid-kt", "assistant", "FolderA", 1L, explicitProject = true)),
            ackOpId = opA
        )
        assertEquals(0, acceptedA.size)
        assertEquals(opB, OrbMissionTree.placementOf("rapid-kt")?.pendingOpId)
        assertEquals("FolderB", OrbMissionTree.folderPath(rapid0))

        val pollAt1 = m("rapid-kt", "project" to "assistant", "folder" to "FolderA", "placement_revision" to 1L)
        assertEquals("FolderB", OrbMissionTree.folderPath(pollAt1))

        val revertedB = OrbMissionTree.rollbackOptimisticPlacement(opB)
        assertEquals(1, revertedB.size)
        assertEquals("FolderA", revertedB.first().folder)
        assertEquals(1L, revertedB.first().placementRevision)
        assertEquals("FolderA", OrbMissionTree.folderPath(pollAt1))

        // Poll-before-ack on overlapping moves (`opC -> FolderX`, `opD -> default/FolderY`, then rev-2 poll
        // for `FolderX` arrives before `opC`'s HTTP/SSE ack): preserves `default/FolderY` (`opD`) and records
        // `assistant/FolderX` at rev 2 as the confirmed rollback base.
        val opC = OrbMissionTree.allocateOpId()
        OrbMissionTree.stageOptimisticPlacement(listOf("rapid-kt"), opC, "assistant", "FolderX")
        val opD = OrbMissionTree.allocateOpId()
        OrbMissionTree.stageOptimisticPlacement(listOf("rapid-kt"), opD, "default", "FolderY")

        val pollBeforeAck = m("rapid-kt", "project" to "assistant", "folder" to "FolderX", "placement_revision" to 2L)
        assertEquals("default", OrbMissionTree.projectSlug(pollBeforeAck))
        assertEquals("FolderY", OrbMissionTree.folderPath(pollBeforeAck))
        assertEquals(opD, OrbMissionTree.placementOf("rapid-kt")?.pendingOpId)
        assertEquals(2L, OrbMissionTree.placementOf("rapid-kt")?.revision)
        assertEquals("assistant", OrbMissionTree.placementOf("rapid-kt")?.project)
        assertEquals("FolderX", OrbMissionTree.placementOf("rapid-kt")?.folder)
        assertEquals("default", OrbMissionTree.seen("rapid-kt")?.project)

        val lateAckC = OrbMissionTree.commitAuthoritativePlacements(
            listOf(OrbPlacementCommitItem("rapid-kt", "assistant", "FolderX", 2L, explicitProject = true)),
            ackOpId = opC
        )
        assertEquals(0, lateAckC.size)
        assertEquals(opD, OrbMissionTree.placementOf("rapid-kt")?.pendingOpId)

        val revertedD = OrbMissionTree.rollbackOptimisticPlacement(opD)
        assertEquals(1, revertedD.size)
        assertEquals("assistant", revertedD.first().project)
        assertEquals("FolderX", revertedD.first().folder)
        assertEquals(2L, revertedD.first().placementRevision)
        assertEquals("assistant", OrbMissionTree.projectSlug(pollBeforeAck))
        assertEquals("FolderX", OrbMissionTree.folderPath(pollBeforeAck))

        // Return-to-origin (`FolderX -> FolderY -> FolderX`): a delayed pre-move poll at rev 2 (`FolderX`)
        // MUST NOT clear `opF`, keeping Move 1 (`opE -> FolderY`) fenced when its rev-3 ack arrives.
        val opE = OrbMissionTree.allocateOpId()
        OrbMissionTree.stageOptimisticPlacement(listOf("rapid-kt"), opE, "assistant", "FolderY")
        val opF = OrbMissionTree.allocateOpId()
        OrbMissionTree.stageOptimisticPlacement(listOf("rapid-kt"), opF, "assistant", "FolderX")
        val originPoll = m("rapid-kt", "project" to "assistant", "folder" to "FolderX", "placement_revision" to 2L)
        assertEquals("FolderX", OrbMissionTree.folderPath(originPoll))
        assertEquals(opF, OrbMissionTree.placementOf("rapid-kt")?.pendingOpId)
        assertEquals(
            0,
            OrbMissionTree.commitAuthoritativePlacements(
                listOf(OrbPlacementCommitItem("rapid-kt", "assistant", "FolderY", 3L, explicitProject = true)),
                ackOpId = opE
            ).size
        )
        assertEquals("FolderX", OrbMissionTree.folderPath(originPoll))
        assertEquals(opF, OrbMissionTree.placementOf("rapid-kt")?.pendingOpId)
        val settledReturn = OrbMissionTree.commitAuthoritativePlacements(
            listOf(OrbPlacementCommitItem("rapid-kt", "assistant", "FolderX", 4L, explicitProject = true)),
            ackOpId = opF
        )
        assertEquals(1, settledReturn.size)
        assertEquals("FolderX", OrbMissionTree.folderPath(originPoll))
        assertEquals(0, OrbMissionTree.placementOf("rapid-kt")?.pendingOpId)

        // Repeated-destination (`FolderX -> FolderY -> FolderZ -> FolderY`): neither Move 1's older ack (`FolderY`, rev 5)
        // nor an intermediate poll clears Move 3 (`opI`), so Move 2's ack (`FolderZ`, rev 6) cannot overwrite `FolderY`.
        val opG = OrbMissionTree.allocateOpId()
        OrbMissionTree.stageOptimisticPlacement(listOf("rapid-kt"), opG, "assistant", "FolderY")
        val opH = OrbMissionTree.allocateOpId()
        OrbMissionTree.stageOptimisticPlacement(listOf("rapid-kt"), opH, "assistant", "FolderZ")
        val opI = OrbMissionTree.allocateOpId()
        OrbMissionTree.stageOptimisticPlacement(listOf("rapid-kt"), opI, "assistant", "FolderY")
        assertEquals(
            0,
            OrbMissionTree.commitAuthoritativePlacements(
                listOf(OrbPlacementCommitItem("rapid-kt", "assistant", "FolderY", 5L, explicitProject = true)),
                ackOpId = opG
            ).size
        )
        assertEquals(opI, OrbMissionTree.placementOf("rapid-kt")?.pendingOpId)
        assertEquals(
            0,
            OrbMissionTree.commitAuthoritativePlacements(
                listOf(OrbPlacementCommitItem("rapid-kt", "assistant", "FolderZ", 6L, explicitProject = true)),
                ackOpId = opH
            ).size
        )
        assertEquals("FolderY", OrbMissionTree.folderPath(originPoll))
        assertEquals(opI, OrbMissionTree.placementOf("rapid-kt")?.pendingOpId)
        val settledRepeat = OrbMissionTree.commitAuthoritativePlacements(
            listOf(OrbPlacementCommitItem("rapid-kt", "assistant", "FolderY", 7L, explicitProject = true)),
            ackOpId = opI
        )
        assertEquals(1, settledRepeat.size)
        assertEquals("FolderY", OrbMissionTree.folderPath(originPoll))
        assertEquals(0, OrbMissionTree.placementOf("rapid-kt")?.pendingOpId)
        OrbMissionTree.resetHierarchy()
    }

    @Test
    fun readCacheApplyPlacementCommitInsertsArrivingRowsInRecencyOrder() {
        OrbReadCache.clearMemory()
        val newer = m("m-new", "project" to "beta", "folder" to "", "updated_at" to "2026-11-06T01:30:00Z")
        val middle = m("m-mid", "project" to "beta", "folder" to "old", "updated_at" to "2026-11-06T01:20:00Z")
        val older = m("m-old", "project" to "beta", "folder" to "", "updated_at" to "2026-11-06T01:10:00Z")
        OrbReadCache.saveRowsMemoryOnly("project_missions_beta", listOf(newer, middle, older))

        val arrivingBetween = m("m-arrive", "project" to "alpha", "folder" to "", "updated_at" to "2026-11-06T01:15:00Z")
        val arrivingOldest = m("m-oldest", "project" to "alpha", "folder" to "", "updated_at" to "2026-11-06T01:00:00Z")
        OrbReadCache.applyPlacementCommit(
            accepted = listOf(
                OrbPlacementCommitItem("m-mid", "beta", "renamed", 2L, explicitProject = true),
                OrbPlacementCommitItem("m-oldest", "beta", "docs", 2L, explicitProject = true),
                OrbPlacementCommitItem("m-arrive", "beta", "docs", 2L, explicitProject = true),
            ),
            fallbackRows = mapOf("m-arrive" to arrivingBetween, "m-oldest" to arrivingOldest),
            persistToDisk = false,
        )

        val cached = OrbReadCache.readMemoryRows("project_missions_beta")
        assertEquals(listOf("m-new", "m-mid", "m-arrive", "m-old", "m-oldest"), cached.map { it.id })
        assertEquals("renamed", cached[1].raw["folder"])
        assertEquals("docs", cached[2].raw["folder"])
        OrbReadCache.clearMemory()
    }

    @Test
    fun projectScopeFilteringAndVirtualFolderMigrationPlan() {
        OrbMissionTree.resetHierarchy()
        val opMove = OrbMissionTree.allocateOpId()
        OrbMissionTree.stageOptimisticPlacement(listOf("moved-opt"), opMove, "beta", "docs")
        OrbMissionTree.commitAuthoritativePlacements(
            listOf(
                OrbPlacementCommitItem("moved-auth", "beta", "", 3L, explicitProject = true),
                OrbPlacementCommitItem("moved-unassigned", null, "", 2L, explicitProject = true),
            )
        )

        val staleOptRow = m("moved-opt", "project" to "alpha", "placement_revision" to 1, "status" to "active")
        val staleAuthRow = m("moved-auth", "project" to "alpha", "placement_revision" to 1, "status" to "completed")
        val staleUnassignedRow = m("moved-unassigned", "project" to "alpha", "placement_revision" to 1, "status" to "completed")
        val keptRow = m("still-alpha", "project" to "alpha", "placement_revision" to 1, "status" to "active")
        val legacyPartialRow = m("legacy-partial", "folder" to "sub", "status" to "completed")
        val crossAncestor = m("anc-beta", "project" to "beta", "placement_revision" to 1, "status" to "completed")

        val ownIds = setOf("moved-opt", "moved-auth", "moved-unassigned", "still-alpha", "legacy-partial")
        val scoped = OrbMissionTree.filterToProjectScope(
            listOf(staleOptRow, staleAuthRow, staleUnassignedRow, keptRow, legacyPartialRow, crossAncestor),
            projectSlug = "alpha",
            ownIds = ownIds,
        )
        assertEquals(listOf("still-alpha", "legacy-partial"), scoped.map { it.id })

        val forkLeader = m("fork-leader", "project" to "alpha", "folder" to "old", "tags" to listOf("fork-of:fork-v1"), "status" to "active")
        val forkOrigin = m("fork-v1", "project" to "alpha", "folder" to "old", "status" to "completed")
        val nestedFolderMission = m("sub-root", "project" to "alpha", "folder" to "old/deep", "status" to "completed")
        val childWorker = m("worker-child", "project" to "alpha", "folder" to "old", "parent_mission_id" to "fork-leader", "status" to "active")
        val batches = OrbMissionTree.planVirtualFolderMigration(
            missions = listOf(forkLeader, forkOrigin, nestedFolderMission, childWorker),
            oldFolder = "old",
            destination = "renamed",
        )
        assertEquals(
            listOf("renamed" to listOf("fork-leader", "fork-v1"), "renamed/deep" to listOf("sub-root")),
            batches,
        )
        OrbMissionTree.resetHierarchy()
    }

    @Test
    fun clientScopedPlacementAckAndMergePendingStagedRows() {
        OrbMissionTree.resetHierarchy()
        val rootRow = m(
            "stage-root",
            "title" to "Cross-project root",
            "project" to "alpha",
            "folder" to "old",
            "placement_revision" to 2L,
            "status" to "active",
            "updated_at" to "2026-11-06T01:20:00Z",
        )
        val betaNewer = m("beta-newer", "project" to "beta", "folder" to "", "placement_revision" to 1L, "updated_at" to "2026-11-06T01:30:00Z")
        val betaOlder = m("beta-older", "project" to "beta", "folder" to "", "placement_revision" to 1L, "updated_at" to "2026-11-06T01:10:00Z")
        OrbMissionTree.observe(rootRow)
        OrbMissionTree.retainStagedRows(listOf(rootRow))

        val op = OrbMissionTree.allocateOpId()
        OrbMissionTree.stageOptimisticPlacement(listOf("stage-root"), op, "beta", "docs")

        // 1. In-flight destination `projectMissions` load preserves the pending staged row in recency order.
        val merged = OrbMissionTree.mergePendingStagedRows(listOf(betaNewer, betaOlder), projectSlug = "beta")
        assertEquals(listOf("beta-newer", "stage-root", "beta-older"), merged.map { it.id })
        assertEquals("docs", merged[1].raw["folder"])

        // 2. Foreign placement event at `incRev > curRev` (`3 > 2`) with colliding `client_op_id` advances the confirmed
        //    rollback baseline without clearing `pendingOpId` or replacing the in-flight `beta/docs` preview!
        val foreignAccepted = OrbMissionTree.commitIncomingPlacementEvent(
            mapOf(
                "client_op_id" to op,
                "client_id" to "foreign-client-uuid",
                "moves" to listOf(
                    mapOf(
                        "mission_id" to "stage-root",
                        "project" to "gamma",
                        "folder" to "foreign",
                        "placement_revision" to 3L,
                    )
                ),
            )
        )
        assertTrue(foreignAccepted.isEmpty())
        assertEquals(op, OrbMissionTree.placementOf("stage-root")?.pendingOpId)
        assertEquals(3L, OrbMissionTree.placementOf("stage-root")?.revision)
        assertEquals("beta", OrbMissionTree.projectSlug(rootRow))

        // 3. Failed local move rolls back cleanly to the updated confirmed baseline (`gamma/foreign` at rev 3).
        val reverted = OrbMissionTree.rollbackOptimisticPlacement(op)
        assertEquals(1, reverted.size)
        assertEquals("gamma", reverted[0].project)
        assertEquals("foreign", reverted[0].folder)
        assertEquals(3L, reverted[0].placementRevision)

        // 4. Event carrying `localClientId` at `incRev == curRev` (`3`) acknowledges and clears `pendingOpId`.
        val op2 = OrbMissionTree.allocateOpId()
        OrbMissionTree.stageOptimisticPlacement(listOf("stage-root"), op2, "beta", "docs")
        val localAccepted = OrbMissionTree.commitIncomingPlacementEvent(
            mapOf(
                "client_op_id" to op2,
                "client_id" to OrbMissionTree.localClientId,
                "moves" to listOf(
                    mapOf(
                        "mission_id" to "stage-root",
                        "project" to "beta",
                        "folder" to "docs",
                        "placement_revision" to 3L,
                    )
                ),
            )
        )
        assertEquals(1, localAccepted.size)
        assertEquals(0, OrbMissionTree.placementOf("stage-root")?.pendingOpId)
        assertEquals(3L, OrbMissionTree.placementOf("stage-root")?.revision)
        OrbMissionTree.resetHierarchy()
    }
}
