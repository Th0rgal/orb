package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Test

class OrbAntigravityVerificationTest {
    @Test
    fun unverifiedAccountOpensGoogleVerification() {
        val refused: OrbDict = mapOf("status" to "needs_verification", "verification_url" to "https://accounts.google.com/signin/continue?sarp=1")
        assertEquals("https://accounts.google.com/signin/continue?sarp=1", antigravityVerificationUrl(refused, "new@gmail.com"))
        assertEquals(
            "https://accounts.google.com/AccountChooser?continue=https%3A%2F%2Fantigravity.google%2F&Email=new%40gmail.com",
            antigravityVerificationUrl(null, "new@gmail.com")
        )
        assertEquals("antigravity · Verification required", providerStatusSubtitle(OrbRow(mapOf("provider_type" to "antigravity", "status" to mapOf("type" to "connected"))), refused))
    }
}
