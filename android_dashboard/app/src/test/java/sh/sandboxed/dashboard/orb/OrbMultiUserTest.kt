package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbMultiUserTest {
    @Test
    fun unixUsernameValidationAndDefaults() {
        assertEquals("orb-alice-dev", OrbUsersModel.defaultUnixUsernameFor("Alice.Dev"))
        assertTrue(OrbUsersModel.validUnixUsername("orb-alice-dev"))
        assertFalse(OrbUsersModel.validUnixUsername("root"))
        assertFalse(OrbUsersModel.validUnixUsername("sandboxed"))
        assertFalse(OrbUsersModel.validUnixUsername("orb-privd"))
        assertFalse(OrbUsersModel.validUnixUsername("Alice"))
        assertFalse(OrbUsersModel.validUnixUsername("-bad"))
        assertEquals("Unlimited", OrbUsersModel.formatUsdFromCents(null))
        assertEquals("$12.50", OrbUsersModel.formatUsdFromCents(1250))
        assertNull(OrbUsersModel.parseUsdToCents("").getOrThrow())
        assertEquals(2500, OrbUsersModel.parseUsdToCents("25").getOrThrow())
        assertEquals(1234, OrbUsersModel.parseUsdToCents("$12.34").getOrThrow())
        assertTrue(OrbUsersModel.parseUsdToCents("-5").isFailure)
    }

    @Test
    fun computeIsAdminFailsClosedInMultiUserMode() {
        val adminUser = OrbCore.CurrentUser(
            id = "u-admin",
            username = "thomas",
            role = "admin",
            unixUsername = "thomas",
            dailySpendCapCents = null,
            spentTodayCents = 0
        )
        val memberUser = adminUser.copy(id = "u-member", username = "alice", role = "member", unixUsername = "orb-alice")

        assertFalse(OrbCore.computeIsAdmin("multi_user", null))
        assertFalse(OrbCore.computeIsAdmin("multi_user", memberUser))
        assertTrue(OrbCore.computeIsAdmin("multi_user", adminUser))

        assertTrue(OrbCore.computeIsAdmin("single_tenant", null))
        assertTrue(OrbCore.computeIsAdmin("single_user", null))
        assertFalse(OrbCore.computeIsAdmin("single_tenant", memberUser))
    }

    @Test
    fun adminOnlyNodesAndNonAdminPlacement() {
        val coreNode: OrbDict = mapOf("id" to "core", "status" to "online")
        val sparkAdmin: OrbDict = mapOf(
            "id" to "dgx-spark-admin",
            "status" to "online",
            "mem_available_bytes" to 32L * 1024L * 1024L * 1024L,
            "disk_available_bytes" to 100L * 1024L * 1024L * 1024L
        )
        val sparkMember: OrbDict = mapOf(
            "id" to "dgx-spark",
            "status" to "online",
            "mem_available_bytes" to 32L * 1024L * 1024L * 1024L,
            "disk_available_bytes" to 100L * 1024L * 1024L * 1024L
        )
        val labeledAdmin: OrbDict = mapOf(
            "id" to "gpu-secret",
            "status" to "online",
            "labels" to listOf("gpu", "admin-only"),
            "mem_available_bytes" to 64L * 1024L * 1024L * 1024L,
            "disk_available_bytes" to 200L * 1024L * 1024L * 1024L
        )

        assertTrue(OrbManagedMachines.isAdminOnlyNode(coreNode))
        assertTrue(OrbManagedMachines.isAdminOnlyNode(sparkAdmin))
        assertTrue(OrbManagedMachines.isAdminOnlyNode(labeledAdmin))
        assertFalse(OrbManagedMachines.isAdminOnlyNode(sparkMember))

        val fleet = listOf(coreNode, sparkAdmin, sparkMember, labeledAdmin)
        val memberVisible = OrbComputePlacement.sortedComputeNodes(fleet, includeAdminNodes = false)
        assertEquals(listOf("dgx-spark"), memberVisible.map { OrbJSON.str(it, "id") })
        assertEquals("dgx-spark", OrbComputePlacement.firstAvailableNodeId(fleet, includeAdminNodes = false))
        assertNull(OrbComputePlacement.firstAvailableNodeId(listOf(coreNode, sparkAdmin, labeledAdmin), includeAdminNodes = false))

        val adminVisible = OrbComputePlacement.sortedComputeNodes(fleet, includeAdminNodes = true)
        assertFalse("dgx-spark" in adminVisible.map { OrbJSON.str(it, "id") })
        assertTrue("dgx-spark-admin" in adminVisible.map { OrbJSON.str(it, "id") })
    }

    @Test
    fun senderUsernamePreservedAcrossHistoryMergeAndTimeline() {
        val history = listOf(
            OrbRow(
                "m-1",
                mapOf(
                    "mission_id" to "m1",
                    "sequence" to 1,
                    "role" to "user",
                    "content" to "Owner prompt",
                    "sender_username" to "thomas"
                )
            )
        )
        val events = listOf(
            OrbRow(
                "e-2",
                mapOf(
                    "mission_id" to "m1",
                    "sequence" to 2,
                    "event_type" to "user_message",
                    "content" to "Participant follow-up",
                    "sender_username" to "alice"
                )
            )
        )
        val merged = OrbConversationHistory.merge(history, events)
        assertEquals(listOf("thomas", "alice"), merged.map { it.str("sender_username") })

        val turns = OrbTimelineBuilder.build(history, events, "", false, null)
            .filterIsInstance<OrbTurn.User>()
        assertEquals(listOf("thomas", "alice"), turns.map { it.senderUsername })
    }

    @Test
    fun effectiveProviderEnabledAndAdminUserPayload() {
        val bothOn = OrbRow("p1", mapOf("id" to "p1", "globally_enabled" to true, "user_enabled" to true))
        val userOff = OrbRow("p2", mapOf("id" to "p2", "globally_enabled" to true, "user_enabled" to false))
        val adminOff = OrbRow("p3", mapOf("id" to "p3", "globally_enabled" to false, "user_enabled" to true))
        val explicitOff = OrbRow("p4", mapOf("id" to "p4", "enabled" to true, "effective_enabled" to false))

        assertTrue(effectiveProviderEnabled(bothOn))
        assertFalse(effectiveProviderEnabled(userOff))
        assertFalse(effectiveProviderEnabled(adminOff))
        assertFalse(effectiveProviderEnabled(explicitOff))

        val managed = OrbManagedMachines.parseProvider(
            mapOf(
                "provider" to "hetzner",
                "configured" to true,
                "globally_enabled" to false,
                "user_enabled" to true,
                "effective_enabled" to false
            )
        )!!
        assertFalse(managed.globallyEnabled)
        assertFalse(OrbManagedMachines.isProviderEnabled(managed))
        assertTrue(OrbManagedMachines.providerStatusLine(managed).contains("Disabled by admin"))

        val missingBoat = OrbManagedMachines.parseProvider(mapOf("provider" to "boat", "configured" to true, "globally_enabled" to true))!!
        val missingHetzner = OrbManagedMachines.parseProvider(mapOf("provider" to "hetzner", "configured" to true, "globally_enabled" to true))!!
        val explicitHetzner = OrbManagedMachines.parseProvider(mapOf("provider" to "hetzner", "configured" to true, "globally_enabled" to true, "user_enabled" to true))!!
        assertTrue(missingBoat.userEnabled)
        assertTrue(OrbManagedMachines.isProviderEnabled(missingBoat))
        assertTrue(missingHetzner.globallyEnabled)
        assertFalse(missingHetzner.userEnabled)
        assertFalse(OrbManagedMachines.isProviderEnabled(missingHetzner))
        assertTrue(OrbManagedMachines.isProviderEnabled(explicitHetzner))
        for (provider in listOf("boat", "leanci", "hetzner", "vastai", "scaleway", "colab")) {
            val base = mapOf<String, Any>("provider" to provider, "configured" to true, "effective_enabled" to true)
            val missingPreference = OrbManagedMachines.parseProvider(base)!!
            assertEquals(provider == "boat", missingPreference.userEnabled)
            assertEquals(provider == "boat", missingPreference.effectiveEnabled)
            assertTrue(missingPreference.globallyEnabled)
            val optedIn = base + ("user_enabled" to true)
            assertTrue(OrbManagedMachines.parseProvider(optedIn)!!.effectiveEnabled)
            assertFalse(OrbManagedMachines.parseProvider(optedIn + ("globally_enabled" to false))!!.effectiveEnabled)
            assertFalse(OrbManagedMachines.parseProvider(optedIn + ("enabled" to false))!!.effectiveEnabled)
            assertFalse(OrbManagedMachines.parseProvider(optedIn + ("user_enabled" to false))!!.effectiveEnabled)
            assertFalse(OrbManagedMachines.parseProvider(optedIn + ("effective_enabled" to false))!!.effectiveEnabled)
            assertTrue(OrbManagedMachines.parseProvider(optedIn + mapOf("globally_enabled" to true, "enabled" to false))!!.effectiveEnabled)
        }

        val adminUser = OrbAdminUser.from(
            mapOf(
                "id" to "u1",
                "username" to "alice",
                "role" to "member",
                "unix_username" to "orb-alice",
                "disabled" to false,
                "daily_spend_cap_cents" to 500,
                "spent_today_cents" to 125
            )
        )!!
        assertEquals("alice", adminUser.username)
        assertEquals(500, adminUser.dailySpendCapCents)
        assertEquals(125, adminUser.spentTodayCents)

        val participantMission = OrbRow("m-shared", mapOf("id" to "m-shared", "viewer_role" to "participant", "owner_username" to "thomas"))
        assertTrue(participantMission.isParticipant)
        assertEquals("thomas", participantMission.ownerUsername)

        assertTrue(OrbUsersModel.isLegacySingleTenantFallback(404, "single_tenant"))
        assertTrue(OrbUsersModel.isLegacySingleTenantFallback(404, "disabled"))
        assertTrue(OrbUsersModel.isLegacySingleTenantFallback(404, null))
        assertFalse(OrbUsersModel.isLegacySingleTenantFallback(404, "multi_user"))
        assertFalse(OrbUsersModel.isLegacySingleTenantFallback(502, "single_tenant"))
        assertEquals("/api/admin/users/usr-1/reset-password", OrbUsersModel.resetPasswordPath("usr-1"))

        val synth = OrbAdminUser.singleTenantAdmin()
        assertEquals("admin", synth.id)
        assertEquals("admin", synth.username)
        assertEquals("admin", synth.role)
        assertFalse(synth.disabled)
    }

    @Test
    fun memberProviderPermissionsBaseUrlAndFriendlyWriteErrors() {
        val ownKey = OrbRow("p-own", mapOf("id" to "p-own", "provider_type" to "custom", "added_by_me" to true, "has_api_key" to true, "uses_oauth" to false))
        val sharedKey = OrbRow("p-shared", mapOf("id" to "p-shared", "provider_type" to "custom", "added_by_me" to false, "has_api_key" to true, "uses_oauth" to false))
        val ownProxyOauth = OrbRow("p-proxy", mapOf("id" to "p-proxy", "provider_type" to "anthropic", "added_by_me" to true, "uses_oauth" to true, "has_oauth" to true, "credential_owner" to "cli_proxy"))
        val sharedProxyOauth = OrbRow("p-proxy-shared", mapOf("id" to "p-proxy-shared", "provider_type" to "anthropic", "added_by_me" to false, "uses_oauth" to true, "has_oauth" to true, "credential_owner" to "cli_proxy"))
        val ownGoogleOauth = OrbRow("p-google", mapOf("id" to "p-google", "provider_type" to "google", "added_by_me" to true, "uses_oauth" to true, "has_oauth" to true))

        assertTrue(canManageProvider(ownKey, isAdmin = false))
        assertFalse(canManageProvider(sharedKey, isAdmin = false))
        assertTrue(canManageProvider(sharedKey, isAdmin = true))

        assertTrue(canEditProviderCredentials(ownKey, isAdmin = false))
        assertFalse(canEditProviderCredentials(sharedKey, isAdmin = false))
        assertTrue(canEditProviderCredentials(sharedKey, isAdmin = true))
        assertFalse(canEditProviderCredentials(ownProxyOauth, isAdmin = true))

        assertTrue(canEditProviderBaseUrl(null, "custom", isAdmin = false))
        assertTrue(canEditProviderBaseUrl(ownKey, "custom", isAdmin = false))
        assertFalse(canEditProviderBaseUrl(sharedKey, "custom", isAdmin = false))
        assertTrue(canEditProviderBaseUrl(sharedKey, "custom", isAdmin = true))
        assertFalse(canEditProviderBaseUrl(ownKey, "openai", isAdmin = true))

        assertTrue(canReconnectProviderOAuth(ownProxyOauth, isAdmin = false))
        assertFalse(canReconnectProviderOAuth(sharedProxyOauth, isAdmin = false))
        assertTrue(canReconnectProviderOAuth(sharedProxyOauth, isAdmin = true))
        assertFalse(canReconnectProviderOAuth(ownGoogleOauth, isAdmin = false))
        assertTrue(canReconnectProviderOAuth(ownGoogleOauth, isAdmin = true))

        assertEquals(setOf("anthropic", "openai", "xai", "kimi"), availableOAuthPresetTypes(isAdmin = false))
        assertEquals(setOf("anthropic", "openai", "google", "xai", "kimi"), availableOAuthPresetTypes(isAdmin = true))

        assertTrue(isMemberCustomBaseUrlAllowed("https://api.example.com/v1"))
        assertTrue(isMemberCustomBaseUrlAllowed("https://100.example.com/v1"))
        assertFalse(isMemberCustomBaseUrlAllowed("http://api.example.com/v1"))
        assertFalse(isMemberCustomBaseUrlAllowed("https://localhost:8080/v1"))
        assertFalse(isMemberCustomBaseUrlAllowed("https://api.localhost/v1"))
        assertFalse(isMemberCustomBaseUrlAllowed("https://svc.internal/v1"))
        assertFalse(isMemberCustomBaseUrlAllowed("https://host.local/v1"))
        assertFalse(isMemberCustomBaseUrlAllowed("https://127.0.0.1/v1"))
        assertFalse(isMemberCustomBaseUrlAllowed("https://10.0.0.1/v1"))
        assertFalse(isMemberCustomBaseUrlAllowed("https://192.168.1.1/v1"))
        assertFalse(isMemberCustomBaseUrlAllowed("https://169.254.169.254/v1"))
        assertFalse(isMemberCustomBaseUrlAllowed("https://172.16.0.1/v1"))
        assertFalse(isMemberCustomBaseUrlAllowed("https://172.31.255.1/v1"))
        assertTrue(isMemberCustomBaseUrlAllowed("https://172.32.0.1/v1"))
        assertFalse(isMemberCustomBaseUrlAllowed("https://100.64.0.1/v1"))
        assertFalse(isMemberCustomBaseUrlAllowed("https://[::1]/v1"))
        assertTrue(isCustomBaseUrlAllowed("http://localhost:8080/v1", isAdmin = true))
        assertFalse(isCustomBaseUrlAllowed("http://localhost:8080/v1", isAdmin = false))

        val ownerErr = OrbError(message = "HTTP 403", status = 403, body = """{"error":"not_account_owner"}""")
        val baseUrlErr = OrbError(message = "HTTP 403", status = 403, body = """{"error":"base_url_not_allowed"}""")
        val adminErr = OrbError(message = "HTTP 403", status = 403, body = """{"error":"admin_required"}""")
        val disabledErr = OrbError(message = "HTTP 403", status = 403, body = """{"error":"account_disabled"}""")
        val unknown403 = OrbError(message = "HTTP 403", status = 403, body = """{"error":"something_else"}""")

        assertEquals(
            "Only the person who added this account, or an admin, can change its credentials or remove it.",
            providerWriteError(ownerErr, "Fallback")
        )
        assertEquals(
            "Members can set a base URL only on custom accounts they added, and only to a public https:// address.",
            providerWriteError(baseUrlErr, "Fallback")
        )
        assertEquals("Only an admin can change this setting.", providerWriteError(adminErr, "Fallback"))
        assertEquals("Your account is disabled.", providerWriteError(disabledErr, "Fallback"))
        assertEquals("Fallback", providerWriteError(unknown403, "Fallback"))
        for (err in listOf(ownerErr, baseUrlErr, adminErr, disabledErr, unknown403)) {
            val msg = providerWriteError(err, "Fallback")
            assertFalse(msg.contains("{"))
            assertFalse(msg.contains("403"))
        }
    }
}
