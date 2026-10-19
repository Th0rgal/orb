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

// FragmentActivity: BiometricPrompt (device approvals, FIDO signing) needs one.
class MainActivity : FragmentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val orbCore = OrbCore.getInstance(applicationContext)
        if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
        handleIncomingIntent(intent, orbCore)
        setContent {
            OrbMaterialTheme {
                OrbAppRoot(core = orbCore)
            }
        }
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

    private fun acceptGitHubCallback(orbCore: OrbCore, link: OrbDeepLink.GitHubCallback) {
        val signIn = OrbGitHubSignIn(OrbGitHubSignIn.prefsStore(applicationContext))
        when (val decision = signIn.onCallback(orbCore.baseURL, link.token, link.error)) {
            is OrbGitHubSignIn.Decision.Reject ->
                OrbLog.w(OrbLog.Category.Auth, "GitHub callback ignored: ${decision.reason}")
            is OrbGitHubSignIn.Decision.Accept -> lifecycleScope.launch {
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
