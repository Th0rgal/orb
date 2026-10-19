package sh.sandboxed.dashboard.orb

import android.content.Context

/**
 * Guards the `sandboxed://auth/callback?token=` deep link. Any app or web page can open that
 * link, so a token is only considered when this app started a GitHub sign-in itself, for the
 * same endpoint, within [MAX_AGE_MS]; the pending sign-in is single use. The caller must then
 * validate the token against an authenticated Core endpoint before saving it.
 *
 * [begin] also generates a random `state` that is sent to /api/auth/github/start. Cores that
 * advertise `github_oauth_client_state` on /api/health echo it back on the callback; against
 * those the callback is rejected unless it carries the same state. Older Cores (no echo) fall
 * back to the time window + server validation.
 */
class OrbGitHubSignIn(private val store: Store, private val clock: () -> Long = System::currentTimeMillis) {
    interface Store {
        fun load(): Pending?
        fun save(pending: Pending?)
    }

    data class Pending(val endpoint: String, val startedAtMs: Long, val state: String? = null)

    sealed class Decision {
        data class Accept(val endpoint: String, val token: String) : Decision()
        data class Reject(val reason: String) : Decision()
    }

    /** Records a sign-in for [endpoint] and returns the `state` to send to Core. */
    fun begin(endpoint: String, state: String = newState()): String {
        store.save(Pending(normalize(endpoint), clock(), state))
        return state
    }

    /** True while a sign-in for [endpoint] was started and its callback has not arrived or expired. */
    fun isPending(endpoint: String): Boolean {
        val pending = store.load() ?: return false
        val age = clock() - pending.startedAtMs
        return age in 0..MAX_AGE_MS && pending.endpoint == normalize(endpoint)
    }

    /** Consumes the pending sign-in (whatever the outcome) and says whether to try [token]. */
    /**
     * [serverEchoesState] is Core's `github_oauth_client_state` health flag: when true the
     * callback must carry the state this app generated.
     */
    fun onCallback(
        currentEndpoint: String,
        token: String?,
        error: String?,
        state: String? = null,
        serverEchoesState: Boolean = false
    ): Decision {
        val pending = store.load()
        store.save(null)
        if (pending == null) return Decision.Reject("no sign-in in progress")
        val age = clock() - pending.startedAtMs
        if (age < 0 || age > MAX_AGE_MS) return Decision.Reject("sign-in expired")
        if (pending.endpoint != normalize(currentEndpoint)) return Decision.Reject("endpoint changed")
        val got = state?.takeIf { it.isNotEmpty() }
        if (got != null || serverEchoesState) {
            val expected = pending.state ?: return Decision.Reject("state not recorded")
            if (got == null) return Decision.Reject("missing state")
            if (!java.security.MessageDigest.isEqual(expected.toByteArray(), got.toByteArray())) {
                return Decision.Reject("state mismatch")
            }
        }
        if (!error.isNullOrBlank()) return Decision.Reject("server error: $error")
        val clean = token?.trim()?.takeIf { it.isNotEmpty() } ?: return Decision.Reject("missing token")
        return Decision.Accept(pending.endpoint, clean)
    }

    companion object {
        const val MAX_AGE_MS = 10 * 60 * 1000L
        const val VALIDATE_PATH = "/api/auth/status"

        private fun normalize(endpoint: String) = endpoint.trim().trimEnd('/').lowercase()

        /** 32 random bytes as URL-safe base64 (43 chars, within Core's 16..128 limit). */
        fun newState(): String {
            val bytes = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
            return java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
        }

        /** Core's `/api/health` flag saying it echoes the client state. */
        fun serverEchoesState(health: Any?): Boolean =
            OrbJSON.bool(OrbJSON.dict(health), "github_oauth_client_state") == true

        fun prefsStore(context: Context): Store = object : Store {
            private val prefs = context.applicationContext.getSharedPreferences("orb_github_signin", Context.MODE_PRIVATE)
            override fun load(): Pending? {
                val ep = prefs.getString("endpoint", null) ?: return null
                return Pending(ep, prefs.getLong("started", 0L), prefs.getString("state", null))
            }
            override fun save(pending: Pending?) {
                prefs.edit().apply {
                    if (pending == null) clear() else putString("endpoint", pending.endpoint).putLong("started", pending.startedAtMs).putString("state", pending.state)
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
