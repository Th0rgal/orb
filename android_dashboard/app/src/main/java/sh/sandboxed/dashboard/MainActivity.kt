package sh.sandboxed.dashboard

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import sh.sandboxed.dashboard.orb.OrbAppRoot
import sh.sandboxed.dashboard.orb.OrbCore
import sh.sandboxed.dashboard.orb.OrbDeepLink
import sh.sandboxed.dashboard.orb.OrbGitHubSignIn
import sh.sandboxed.dashboard.orb.OrbLog
import sh.sandboxed.dashboard.orb.OrbMaterialTheme
import sh.sandboxed.dashboard.orb.OrbNotifications
import sh.sandboxed.dashboard.orb.UsageTelemetry

// FragmentActivity: BiometricPrompt (device approvals, FIDO signing) needs one.
class MainActivity : FragmentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val orbCore = OrbCore.getInstance(applicationContext)
        if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
        UsageTelemetry.install(orbCore, BuildConfig.VERSION_NAME)
        handleIncomingIntent(intent, orbCore)
        // Debug-only: render the first-run screen over an existing session so
        // device inset checks can screenshot it without clearing app data.
        val debugShowSetup = BuildConfig.DEBUG && intent?.getBooleanExtra("orb_debug_show_setup", false) == true
        setContent {
            OrbMaterialTheme {
                OrbAppRoot(core = orbCore, debugShowSetup = debugShowSetup)
            }
        }
    }

    override fun onStart() {
        super.onStart()
        UsageTelemetry.onForeground()
    }

    override fun onStop() {
        UsageTelemetry.onBackground()
        super.onStop()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIncomingIntent(intent, OrbCore.getInstance(applicationContext))
    }

    private fun handleIncomingIntent(intent: Intent?, orbCore: OrbCore) {
        if (intent == null) return

        // Launch extras for automated testing & quick setup
        val extraBase = intent.getStringExtra("orb_base_url")?.trim()
        val extraToken = intent.getStringExtra("orb_token")?.trim()
        if (!extraBase.isNullOrEmpty()) {
            orbCore.configureSession(extraBase, extraToken ?: orbCore.token, null)
            lifecycleScope.launch { orbCore.refreshAll() }
        }
        if (intent.getBooleanExtra("orb_open_inbox", false)) orbCore.requestInboxOpen()
        if (intent.getBooleanExtra("orb_open_settings", false)) orbCore.requestSettingsOpen()
        intent.getStringExtra("orb_open_project")?.trim()?.takeIf { it.isNotEmpty() }?.let(orbCore::requestProjectFocus)
        intent.getStringExtra("orb_open_mission")?.trim()?.takeIf { it.isNotEmpty() }?.let(orbCore::requestMissionFocus)
        intent.getStringExtra("orb_open_documents")?.trim()?.takeIf { it.isNotEmpty() }?.let(orbCore::requestDocumentsFocus)

        when (val link = OrbDeepLink.parse(intent.dataString)) {
            null -> Unit
            is OrbDeepLink.Inbox -> {
                orbCore.requestInboxOpen()
                link.missionId?.let { OrbNotifications.requestInboxFocus(it, link.expandPeek, link.openReply) }
            }
            OrbDeepLink.Settings -> orbCore.requestSettingsOpen()
            is OrbDeepLink.Project -> orbCore.requestProjectFocus(link.slug)
            is OrbDeepLink.Mission -> orbCore.requestMissionFocus(link.id)
            is OrbDeepLink.Documents -> orbCore.requestDocumentsFocus(link.slug)
            is OrbDeepLink.GitHubCallback -> acceptGitHubCallback(orbCore, link)
        }
    }

    private fun acceptGitHubCallback(orbCore: OrbCore, link: OrbDeepLink.GitHubCallback) = lifecycleScope.launch {
        val signIn = OrbGitHubSignIn(OrbGitHubSignIn.prefsStore(applicationContext))
        // A Core that echoes the client state must send it back; if /api/health cannot be read
        // and the callback carries no state, fail closed.
        val echoes = try {
            OrbGitHubSignIn.serverEchoesState(orbCore.request("/api/health", allowAuthRetry = false))
        } catch (c: kotlinx.coroutines.CancellationException) {
            throw c
        } catch (t: Throwable) {
            OrbLog.w(OrbLog.Category.Auth, "GitHub callback: /api/health unavailable", t)
            true
        }
        when (val decision = signIn.onCallback(orbCore.baseURL, link.token, link.error, link.state, echoes)) {
            is OrbGitHubSignIn.Decision.Reject ->
                OrbLog.w(OrbLog.Category.Auth, "GitHub callback ignored: ${decision.reason}")
            is OrbGitHubSignIn.Decision.Accept -> {
                // Save only a token Core itself accepts.
                val valid = try {
                    orbCore.request(
                        OrbGitHubSignIn.VALIDATE_PATH,
                        headers = mapOf("Authorization" to "Bearer ${decision.token}"),
                        allowAuthRetry = false
                    )
                    true
                } catch (c: kotlinx.coroutines.CancellationException) {
                    throw c
                } catch (t: Throwable) {
                    OrbLog.w(OrbLog.Category.Auth, "GitHub token rejected by Core", t)
                    false
                }
                if (valid && orbCore.baseURL.trim().trimEnd('/').lowercase() == decision.endpoint) {
                    orbCore.token = decision.token
                    orbCore.refreshAll()
                }
            }
        }
    }
}
