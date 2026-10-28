package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Test

class OrbRichTextRoutingTest {
    @Test fun rendererRoutingMatchesSharedFixture() {
        val spec = OrbSpec.dict("fixtures/rich-text-routing.json")
        for (c in OrbJSON.dictList(spec["cases"])) {
            assertEquals(c["name"] as String, c["web"], needsWebRenderer(c["source"] as String))
        }
    }
}
