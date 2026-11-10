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
}
