package sh.sandboxed.dashboard.orb

import android.content.Context

/**
 * Guards the `sandboxed://auth/callback?token=` deep link. Any app or web page can open that
 * link, so a token is only considered when this app started a GitHub sign-in itself, for the
 * same endpoint, within [MAX_AGE_MS]; the pending sign-in is single use. The caller must then
 * validate the token against an authenticated Core endpoint before saving it.
 *
 * Core does not round-trip a client nonce through /api/auth/github/start (its redirect
 * allowlist is an exact match), so the time window + server validation is the best the
 * client can do today; see the PR notes for the Core follow-up.
 */
class OrbGitHubSignIn(private val store: Store, private val clock: () -> Long = System::currentTimeMillis) {
    interface Store {
        fun load(): Pending?
        fun save(pending: Pending?)
    }

    data class Pending(val endpoint: String, val startedAtMs: Long)

    sealed class Decision {
        data class Accept(val endpoint: String, val token: String) : Decision()
        data class Reject(val reason: String) : Decision()
    }

    fun begin(endpoint: String) {
        store.save(Pending(normalize(endpoint), clock()))
    }

    /** True while a sign-in for [endpoint] was started and its callback has not arrived or expired. */
    fun isPending(endpoint: String): Boolean {
        val pending = store.load() ?: return false
        val age = clock() - pending.startedAtMs
        return age in 0..MAX_AGE_MS && pending.endpoint == normalize(endpoint)
    }

    /** Consumes the pending sign-in (whatever the outcome) and says whether to try [token]. */
    fun onCallback(currentEndpoint: String, token: String?, error: String?): Decision {
        val pending = store.load()
        store.save(null)
        if (pending == null) return Decision.Reject("no sign-in in progress")
        val age = clock() - pending.startedAtMs
        if (age < 0 || age > MAX_AGE_MS) return Decision.Reject("sign-in expired")
        if (pending.endpoint != normalize(currentEndpoint)) return Decision.Reject("endpoint changed")
        if (!error.isNullOrBlank()) return Decision.Reject("server error: $error")
        val clean = token?.trim()?.takeIf { it.isNotEmpty() } ?: return Decision.Reject("missing token")
        return Decision.Accept(pending.endpoint, clean)
    }

    companion object {
        const val MAX_AGE_MS = 10 * 60 * 1000L
        const val VALIDATE_PATH = "/api/auth/status"

        private fun normalize(endpoint: String) = endpoint.trim().trimEnd('/').lowercase()

        fun prefsStore(context: Context): Store = object : Store {
            private val prefs = context.applicationContext.getSharedPreferences("orb_github_signin", Context.MODE_PRIVATE)
            override fun load(): Pending? {
                val ep = prefs.getString("endpoint", null) ?: return null
                return Pending(ep, prefs.getLong("started", 0L))
            }
            override fun save(pending: Pending?) {
                prefs.edit().apply {
                    if (pending == null) clear() else putString("endpoint", pending.endpoint).putLong("started", pending.startedAtMs)
                }.apply()
            }
        }
    }
}

/**
 * The "Sign in with GitHub" button on the server screen: validates the URL, opens the browser
 * through [launch] (which records the pending sign-in via [OrbGitHubSignIn.begin]) and reports
 * the pending state until the secured callback in MainActivity consumes it.
 */
class OrbGitHubSignInButton(private val signIn: OrbGitHubSignIn, private val launch: (String) -> Boolean) {
    sealed class State {
        object Idle : State()
        data class Pending(val endpoint: String) : State()
        data class Failed(val message: String) : State()
    }

    fun start(urlInput: String): State {
        val clean = urlInput.trim().trimEnd('/')
        val uri = runCatching { java.net.URI(clean) }.getOrNull()
        if (clean.isEmpty() || uri?.scheme?.lowercase() !in setOf("http", "https") || uri?.host.isNullOrEmpty()) {
            return State.Failed("Enter the backend URL first.")
        }
        if (!launch(clean)) return State.Failed("Could not open a browser for GitHub sign-in.")
        return State.Pending(clean)
    }

    /** Re-reads the stored sign-in, e.g. when the screen resumes after the browser. */
    fun refresh(state: State): State =
        if (state is State.Pending && !signIn.isPending(state.endpoint)) State.Idle else state
}
