package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbGitHubSignInTest {
    private class MemStore : OrbGitHubSignIn.Store {
        var value: OrbGitHubSignIn.Pending? = null
        override fun load() = value
        override fun save(pending: OrbGitHubSignIn.Pending?) { value = pending }
    }

    private var now = 1_000_000L
    private val store = MemStore()
    private val signIn = OrbGitHubSignIn(store) { now }

    private fun reject(d: OrbGitHubSignIn.Decision) = assertTrue(d.toString(), d is OrbGitHubSignIn.Decision.Reject)

    @Test
    fun acceptsMatchingCallbackOnce() {
        signIn.begin("https://Core.example/")
        now += 60_000
        assertEquals(
            OrbGitHubSignIn.Decision.Accept("https://core.example", "jwt"),
            signIn.onCallback("https://core.example", " jwt ", null)
        )
        reject(signIn.onCallback("https://core.example", "jwt", null)) // single use
    }

    @Test
    fun rejectsUnsolicitedCallback() = reject(signIn.onCallback("https://core.example", "jwt", null))

    @Test
    fun rejectsExpiredSignIn() {
        signIn.begin("https://core.example")
        now += OrbGitHubSignIn.MAX_AGE_MS + 1
        reject(signIn.onCallback("https://core.example", "jwt", null))
    }

    @Test
    fun rejectsOtherEndpointErrorsAndMissingToken() {
        signIn.begin("https://core.example"); reject(signIn.onCallback("https://evil.example", "jwt", null))
        signIn.begin("https://core.example"); reject(signIn.onCallback("https://core.example", "jwt", "denied"))
        signIn.begin("https://core.example"); reject(signIn.onCallback("https://core.example", "  ", null))
        signIn.begin("https://core.example"); now -= 1; reject(signIn.onCallback("https://core.example", "jwt", null))
    }
}
