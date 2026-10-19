package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbMissionStateSpecTest {
    private val spec = OrbSpec.dict("mission-states.json")
    private val states = OrbJSON.dict(spec["states"])!!

    @Test
    fun everySpecStateHasAMatchingEnumEntry() {
        assertEquals(states.keys, MissionState.entries.map { it.wire }.toSet())
    }

    @Test
    fun labelsCategoriesRanksAndFlagsMatchTheSpec() {
        for ((wire, raw) in states) {
            val row = OrbJSON.dict(raw)!!
            val flags = OrbJSON.dict(row["flags"])!!
            val state = MissionState.of(wire)!!
            assertEquals(wire, OrbJSON.str(row, "label"), state.label)
            assertEquals(wire, OrbJSON.str(row, "category"), state.category.wire)
            assertEquals(wire, OrbJSON.int(row, "sortRank"), state.sortRank)
            assertEquals("$wire.live", flags["live"], state.live)
            assertEquals("$wire.terminal", flags["terminal"], state.terminal)
            assertEquals("$wire.needsAttention", flags["needsAttention"], state.needsAttention)
            assertEquals("$wire.unreadResponse", flags["unreadResponse"], state.unreadResponse)
            assertEquals("$wire.canRetry", flags["canRetry"], state.canRetry)
        }
    }

    @Test
    fun categoriesListMatches() {
        val cats = (spec["categories"] as List<*>).map { it as String }
        assertEquals(cats, MissionCategory.entries.filter { it != MissionCategory.Unknown }.map { it.wire })
        assertEquals(OrbJSON.int(OrbJSON.dict(spec["unknown"]), "sortRank"), MissionCategory.Unknown.sortRank)
    }

    @Test
    fun statusLabelCoversPausedAndUnknownStates() {
        assertEquals("Paused", statusLabel("paused"))
        assertEquals("Paused", statusLabel("PAUSED"))
        assertEquals("some new state", statusLabel("some_new_state"))
        assertNull(MissionState.of("some_new_state"))
    }

    @Test
    fun attentionCountsErrorStatesLikeIos() {
        for (s in listOf("failed", "error", "errored", "blocked", "not_feasible", "timed_out")) {
            assertTrue(s, MissionState.of(s)!!.needsAttention)
        }
        for (s in listOf("running", "completed", "paused", "acknowledged")) {
            assertFalse(s, MissionState.of(s)!!.needsAttention)
        }
    }
}
