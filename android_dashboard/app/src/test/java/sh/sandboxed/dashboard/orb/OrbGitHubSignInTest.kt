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

    @Test
    fun buttonOpensBrowserAndStaysPendingUntilCallback() {
        val launched = mutableListOf<String>()
        val button = OrbGitHubSignInButton(signIn) { base -> launched += base; signIn.begin(base); true }
        val state = button.start(" https://core.example/ ")
        assertEquals(OrbGitHubSignInButton.State.Pending("https://core.example"), state)
        assertEquals(listOf("https://core.example"), launched)
        assertTrue(signIn.isPending("https://core.example"))
        assertEquals(state, button.refresh(state))
        // The secured callback consumes the pending sign-in; the button returns to idle.
        assertEquals(OrbGitHubSignIn.Decision.Accept("https://core.example", "jwt"), signIn.onCallback("https://core.example", "jwt", null))
        assertEquals(OrbGitHubSignInButton.State.Idle, button.refresh(state))
    }

    @Test
    fun buttonPendingExpiresWithTheSignInWindow() {
        val button = OrbGitHubSignInButton(signIn) { base -> signIn.begin(base); true }
        val state = button.start("https://core.example")
        now += OrbGitHubSignIn.MAX_AGE_MS + 1
        assertEquals(OrbGitHubSignInButton.State.Idle, button.refresh(state))
    }

    @Test
    fun buttonRejectsMissingUrlAndBrowserFailure() {
        var calls = 0
        val noBrowser = OrbGitHubSignInButton(signIn) { calls++; false }
        assertTrue(noBrowser.start("") is OrbGitHubSignInButton.State.Failed)
        assertTrue(noBrowser.start("core.example") is OrbGitHubSignInButton.State.Failed)
        assertEquals(0, calls)
        assertTrue(noBrowser.start("https://core.example") is OrbGitHubSignInButton.State.Failed)
        assertEquals(1, calls)
    }
}
