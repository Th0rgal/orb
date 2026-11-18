package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import java.io.File

class OrbRemoteGoalTest {
    @Test
    fun matchesSharedEnvelopeFixtures() {
        val specDir = System.getProperty("orb.spec.dir")
        val candidates = listOfNotNull(
            specDir?.let { File(it, "fixtures/remote-goal.json") },
            File("../shared/orb-spec/fixtures/remote-goal.json"),
            File("../../shared/orb-spec/fixtures/remote-goal.json"),
            File("shared/orb-spec/fixtures/remote-goal.json"),
        )
        val file = candidates.firstOrNull { it.exists() }
            ?: error("Could not locate shared/orb-spec/fixtures/remote-goal.json")
        val root = OrbJSON.dict(OrbJSON.parse(file.readText()))
            ?: error("Invalid remote-goal fixture")
        assertEquals(2, (root["schema_version"] as Number).toInt())
        val cases = root["cases"] as List<*>
        assertFalse(cases.isEmpty())
        for (raw in cases) {
            val fixture = OrbJSON.dict(raw) ?: error("Invalid fixture case")
            val event = OrbJSON.dict(fixture["event"]) ?: error("Missing event")
            assertEquals(fixture["name"] as String, fixture["expected"], OrbRemoteGoal.event(event))
        }
    }

    @Test
    fun projectionStopsAfterTruthfulCompletion() {
        var projection = OrbRemoteGoal.Projection("active", "Ship it", 0)
        projection = OrbRemoteGoal.apply(projection, mapOf("type" to "goal_iteration", "data" to mapOf("status" to "active", "objective" to "Ship it", "iteration" to 2, "summary" to "Progress")))
        assertEquals(2, projection.iteration)
        projection = OrbRemoteGoal.apply(projection, mapOf("type" to "goal_status", "data" to mapOf("status" to "complete")))
        assertEquals("complete", projection.phase)
        projection = OrbRemoteGoal.apply(projection, mapOf("type" to "goal_status", "data" to mapOf("status" to "active")))
        assertEquals("complete", projection.phase)
    }
}
