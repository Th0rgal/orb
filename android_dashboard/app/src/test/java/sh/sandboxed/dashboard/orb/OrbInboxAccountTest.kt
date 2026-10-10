package sh.sandboxed.dashboard.orb

import org.junit.Assert.*
import org.junit.Test
import java.util.Base64

class OrbInboxAccountTest {
    private fun token(subject: String, expiry: Int): String = "header." + Base64.getUrlEncoder().withoutPadding().encodeToString("{\"sub\":\"$subject\",\"exp\":$expiry}".toByteArray()) + ".signature"
    @Test fun renewalPreservesIdentityAndAccountsRemainIsolated() {
        val alice = inboxAccountScope("https://core.test/", token("alice", 1))
        assertEquals(alice, inboxAccountScope("https://core.test", token("alice", 2)))
        assertNotEquals(alice, inboxAccountScope("https://core.test", token("bob", 2)))
        assertNotEquals(alice, inboxAccountScope("https://other.test", token("alice", 2)))
        assertNotEquals(inboxAccountScope("https://core.test", "opaque-a"), inboxAccountScope("https://core.test", "opaque-b"))
    }
    @Test fun legacyPreferencesBelongOnlyToTheirFirstAccount() {
        OrbSharedInboxState.applying = true
        try {
            OrbInboxSettings.update(newAiSummary = false, newIncludeAutonomous = true, newModel = "builtin/fast")
            OrbInboxSettings.bindAccount("test:alice")
            assertFalse(OrbInboxSettings.aiSummary)
            assertTrue(OrbInboxSettings.includeAutonomous)
            assertEquals("builtin/fast", OrbInboxSettings.model)
            OrbInboxSettings.bindAccount("test:bob")
            assertTrue(OrbInboxSettings.aiSummary)
            assertFalse(OrbInboxSettings.includeAutonomous)
            assertEquals(OrbInboxSettings.DEFAULT_MODEL, OrbInboxSettings.model)
        } finally { OrbSharedInboxState.applying = false }
    }

}
