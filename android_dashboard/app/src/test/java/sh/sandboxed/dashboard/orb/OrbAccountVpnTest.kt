package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbAccountVpnTest {
    private val spec = OrbSpec.dict("fixtures/account-vpn.json")

    @Test fun accountConnectionMatchesSharedFixture() {
        val routes = OrbJSON.dictList(spec["routes"])
        assertTrue(routes.isNotEmpty())
        for (case in routes) {
            val name = case["name"] as String
            val route = OrbAccountVpn.route(case["payload"])
            assertNotNull(name, route)
            val expected = OrbJSON.dict(case["view"])!!
            assertEquals(name, OrbAccountVpn.View(
                selected = expected["selected"] as String,
                countries = (expected["countries"] as List<*>).map { it as String },
                editable = expected["editable"] as Boolean,
                confirmDirect = expected["confirm_direct"] as Boolean,
                notice = expected["notice"] as String,
                status = expected["status"] as String,
                retry = expected["retry"] as Boolean,
                poll = expected["poll"] as Boolean,
            ), OrbAccountVpn.view(route!!, case["native"] as Boolean))
        }
        val invalid = spec["invalid_routes"] as List<*>
        assertTrue(invalid.isNotEmpty())
        for (payload in invalid) assertNull("$payload", OrbAccountVpn.route(payload))
        for (case in OrbJSON.dictList(spec["writes"])) {
            assertEquals(case["body"], OrbAccountVpn.write(case["country"] as String))
        }
    }

    @Test fun accountSettingReadErrorsAndRouterAccessMatchSharedFixture() {
        val update = OrbJSON.dict(spec["labels"])!!["vpn_update"] as String
        val errors = OrbJSON.dictList(spec["read_errors"])
        assertTrue(errors.isNotEmpty())
        for (case in errors) {
            val name = case["name"] as String
            val status = case["status"] as Int
            val body = case["body"] as String
            val path = case["path"] as String
            val missing = case["missing_endpoint"] as Boolean
            assertEquals(name, missing, OrbAccountVpn.missingSetting(status, body, path))
            assertEquals(name, if (missing) update else "unavailable",
                OrbAccountVpn.readError(OrbError("HTTP $status", status = status, body = body), path, update, "unavailable"))
        }
        assertEquals("unavailable",
            OrbAccountVpn.readError(java.io.IOException("timeout"), "/api/ai/providers/a/vpn", update, "unavailable"))
        val access = OrbJSON.dictList(spec["router_access"])
        assertTrue(access.isNotEmpty())
        for (case in access) assertEquals("$case", case["allowed"], OrbAccountVpn.routerAccess(case["payload"]))
    }
}
