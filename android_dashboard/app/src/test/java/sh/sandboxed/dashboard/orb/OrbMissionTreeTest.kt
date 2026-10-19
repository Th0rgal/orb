package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbMissionTreeTest {
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
}
