package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
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
}
