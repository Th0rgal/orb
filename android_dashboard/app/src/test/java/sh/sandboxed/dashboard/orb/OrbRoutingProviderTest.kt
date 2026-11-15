package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Test

class OrbRoutingProviderTest {
    @Test fun aliasesMatchSharedFixture() {
        val spec = OrbSpec.dict("fixtures/routing-provider.json")
        val catalog = OrbJSON.dictList(spec["catalog"]).map { OrbRow(it) }
        for (case in OrbJSON.dictList(spec["cases"])) {
            val id = case["id"] as String
            assertEquals(case["canonical"], OrbRoutingProvider.find(catalog, id)?.id)
            assertEquals(case["label"], OrbRoutingProvider.label(catalog, id))
        }
    }
}
