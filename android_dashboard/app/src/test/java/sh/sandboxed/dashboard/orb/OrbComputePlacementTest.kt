package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Test

class OrbComputePlacementTest {
    @Test fun autoNodeSelectionMatchesSharedFixture() {
        val spec = OrbSpec.dict("fixtures/auto-node-selection.json")
        assertEquals((spec["minMemBytes"] as Number).toLong(), OrbComputePlacement.MIN_AUTO_NODE_MEM_BYTES)
        assertEquals((spec["minDiskBytes"] as Number).toLong(), OrbComputePlacement.MIN_AUTO_NODE_DISK_BYTES)
        for (c in OrbJSON.dictList(spec["cases"])) {
            val name = c["name"] as String
            val backend = c["backend"] as? String
            val nodes = OrbJSON.dictList(c["nodes"])
            val expected = c["expected"] as? String
            assertEquals(name, expected, OrbComputePlacement.firstAvailableNodeId(nodes, backend))
        }
    }
}
