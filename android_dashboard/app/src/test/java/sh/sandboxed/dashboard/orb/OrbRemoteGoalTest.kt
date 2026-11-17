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
        assertEquals(1, (root["schema_version"] as Number).toInt())
        val cases = root["cases"] as List<*>
        assertFalse(cases.isEmpty())
        for (raw in cases) {
            val fixture = OrbJSON.dict(raw) ?: error("Invalid fixture case")
            val event = OrbJSON.dict(fixture["event"]) ?: error("Missing event")
            assertEquals(fixture["name"] as String, fixture["expected"], OrbRemoteGoal.event(event))
        }
    }
}
