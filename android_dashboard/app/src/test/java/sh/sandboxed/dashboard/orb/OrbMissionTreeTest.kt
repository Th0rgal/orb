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
        ))
        assertEquals(0, tree.size) // both have a listed parent, so neither is a root
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
        val supParent = m("sup-p", "status" to "completed", "tags" to listOf("superseded_by:new-p"))
        val supChild = m("sup-c", "status" to "completed", "parent_mission_id" to "sup-p")
        val liveSup = m("sup-live", "status" to "active", "tags" to listOf("superseded"))
        val supMap = listOf(supParent, supChild, liveSup).associateBy { it.id }
        assertTrue(OrbMissionTree.isSupersededInTree(supParent, supMap))
        assertTrue(OrbMissionTree.isSupersededInTree(supChild, supMap))
        assertFalse(OrbMissionTree.isSupersededInTree(liveSup, supMap))
        OrbMissionTree.resetHierarchy()
    }
}
