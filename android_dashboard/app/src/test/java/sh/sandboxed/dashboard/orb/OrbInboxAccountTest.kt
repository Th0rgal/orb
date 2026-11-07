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
            OrbInboxSettings.update(
                newInboxEnabled = false,
                newAiSummary = false,
                newSummaryMode = OrbInboxSummaryMode.Eco,
                newIncludeAutonomous = true,
                newModel = "builtin/fast",
            )
            OrbInboxSettings.bindAccount("test:alice")
            assertFalse(OrbInboxSettings.inboxEnabled)
            assertFalse(OrbInboxSettings.aiSummary)
            assertEquals(OrbInboxSummaryMode.Eco, OrbInboxSettings.summaryMode)
            assertTrue(OrbInboxSettings.includeAutonomous)
            assertEquals("builtin/fast", OrbInboxSettings.model)
            OrbInboxSettings.bindAccount("test:bob")
            assertTrue(OrbInboxSettings.inboxEnabled)
            assertTrue(OrbInboxSettings.aiSummary)
            assertEquals(OrbInboxSummaryMode.Standard, OrbInboxSettings.summaryMode)
            assertFalse(OrbInboxSettings.includeAutonomous)
            assertEquals(OrbInboxSettings.DEFAULT_MODEL, OrbInboxSettings.model)
        } finally { OrbSharedInboxState.applying = false }
    }

    @Test fun focusTargetQueuesAndConsumesCleanly() {
        OrbNotifications.consumeInboxFocus()
        assertNull(OrbNotifications.pendingInboxFocus)
        OrbNotifications.requestInboxFocus("m-hybrid-99", expandPeek = true, openReply = true)
        val pending = OrbNotifications.pendingInboxFocus
        assertNotNull(pending)
        assertEquals("m-hybrid-99", pending?.missionId)
        assertEquals(true, pending?.expandPeek)
        assertEquals(true, pending?.openReply)
        val consumed = OrbNotifications.consumeInboxFocus()
        assertEquals(pending, consumed)
        assertNull(OrbNotifications.pendingInboxFocus)
    }

    @Test fun outboxPersistenceCapAnd409ConflictRebaseMatchDesktopAndIos() {
        assertTrue(OrbSharedInboxState.shouldPersistEncodedOutbox("x".repeat(OrbSharedInboxState.MAX_PERSISTED_OUTBOX_BYTES)))
        assertFalse(OrbSharedInboxState.shouldPersistEncodedOutbox("x".repeat(OrbSharedInboxState.MAX_PERSISTED_OUTBOX_BYTES + 1)))

        val conflictPrefs = mapOf(
            "preferences" to mapOf("model" to "builtin/fast"),
            "_versions" to mapOf("preferences" to 4L, "seen:m-1" to 8L),
        )
        val prefsBody = mapOf(
            "model" to "builtin/smart",
            "clientId" to "client-1",
            "mutationSeq" to 2L,
            "expectedVersion" to 0L,
        )
        assertEquals(
            OrbSharedInboxState.ConflictResolution.Rebase(expectedVersion = 4L, mutationSeq = 6L),
            OrbSharedInboxState.resolveConflict(
                path = "preferences",
                currentBody = prefsBody,
                conflictState = conflictPrefs,
                alreadyRebased = false,
                currentRevision = 0L,
                storedSeq = 5L,
            )
        )
        assertEquals(
            OrbSharedInboxState.ConflictResolution.Retire,
            OrbSharedInboxState.resolveConflict(
                path = "preferences",
                currentBody = prefsBody,
                conflictState = conflictPrefs,
                alreadyRebased = true,
                currentRevision = 4L,
                storedSeq = 6L,
            )
        )

        val subsumedState = mapOf(
            "seen:m-1" to 500L,
            "_versions" to mapOf("seen:m-1" to 8L),
        )
        assertEquals(
            OrbSharedInboxState.ConflictResolution.Retire,
            OrbSharedInboxState.resolveConflict(
                path = "seen/m-1",
                currentBody = mapOf("stamp" to 300L, "mutationSeq" to 3L),
                conflictState = subsumedState,
                alreadyRebased = false,
                currentRevision = 0L,
                storedSeq = 3L,
            )
        )
        assertEquals(
            OrbSharedInboxState.ConflictResolution.Rebase(expectedVersion = 8L, mutationSeq = 4L),
            OrbSharedInboxState.resolveConflict(
                path = "seen/m-1",
                currentBody = mapOf("stamp" to -500L, "mutationSeq" to 3L),
                conflictState = subsumedState,
                alreadyRebased = false,
                currentRevision = 0L,
                storedSeq = 3L,
            )
        )
    }
}
