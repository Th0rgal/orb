package sh.sandboxed.dashboard

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Bundle
import android.util.Rational
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import sh.sandboxed.dashboard.data.AppContainer
import sh.sandboxed.dashboard.orb.OrbAppRoot
import sh.sandboxed.dashboard.orb.OrbCore
import sh.sandboxed.dashboard.ui.PipHost
import sh.sandboxed.dashboard.ui.theme.SandboxedTheme
import sh.sandboxed.dashboard.util.GitHubAuth
import kotlin.math.roundToInt

class MainActivity : FragmentActivity(), PipHost {
    private val _isInPipMode = MutableStateFlow(false)
    override val isInPipMode: StateFlow<Boolean> = _isInPipMode.asStateFlow()

    override val isPipSupported: Boolean by lazy {
        packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
    }

    private var pipActive = false
    private var pipAspect: Rational? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val container = (application as SandboxedDashboardApp).container
        val orbCore = OrbCore.getInstance(applicationContext)
        handleIncomingIntent(intent, container, orbCore)
        setContent {
            SandboxedTheme {
                OrbAppRoot(core = orbCore)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val container = (application as SandboxedDashboardApp).container
        val orbCore = OrbCore.getInstance(applicationContext)
        handleIncomingIntent(intent, container, orbCore)
    }

    override fun enterPip() {
        if (!isPipSupported) return
        runCatching { enterPictureInPictureMode(buildPipParams()) }
    }

    override fun setPipActive(active: Boolean, aspectWidth: Int, aspectHeight: Int) {
        if (!isPipSupported) return
        pipActive = active
        pipAspect = clampedAspect(aspectWidth, aspectHeight)
        runCatching { setPictureInPictureParams(buildPipParams()) }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        _isInPipMode.value = isInPictureInPictureMode
    }

    private fun buildPipParams(): PictureInPictureParams =
        PictureInPictureParams.Builder()
            .apply { pipAspect?.let { setAspectRatio(it) } }
            .setAutoEnterEnabled(pipActive)
            .setSeamlessResizeEnabled(true)
            .build()

    private fun clampedAspect(width: Int, height: Int): Rational? {
        if (width <= 0 || height <= 0) return null
        val ratio = (width.toDouble() / height.toDouble()).coerceIn(1.0 / 2.39, 2.39)
        return Rational((ratio * 1000).roundToInt(), 1000)
    }

    private fun handleIncomingIntent(intent: Intent?, container: AppContainer, orbCore: OrbCore) {
        if (intent == null) return

        // Handle launch extras for automated testing & quick setup
        val extraBase = intent.getStringExtra("orb_base_url")?.trim()
        val extraToken = intent.getStringExtra("orb_token")?.trim()
        if (!extraBase.isNullOrEmpty()) {
            orbCore.configureSession(extraBase, extraToken ?: orbCore.token, null)
            container.scope.launch { orbCore.refreshAll() }
        }
        if (intent.getBooleanExtra("orb_open_inbox", false)) {
            orbCore.requestInboxOpen()
        }
        if (intent.getBooleanExtra("orb_open_settings", false)) {
            orbCore.requestSettingsOpen()
        }
        intent.getStringExtra("orb_open_project")?.trim()?.takeIf { it.isNotEmpty() }?.let { slug ->
            orbCore.requestProjectFocus(slug)
        }
        intent.getStringExtra("orb_open_mission")?.trim()?.takeIf { it.isNotEmpty() }?.let { mid ->
            orbCore.requestMissionFocus(mid)
        }
        intent.getStringExtra("orb_open_documents")?.trim()?.takeIf { it.isNotEmpty() }?.let { slug ->
            orbCore.requestDocumentsFocus(slug)
        }

        val data = intent.data ?: return
        val scheme = data.scheme?.lowercase() ?: ""
        if (scheme == "orb" || scheme == "sandboxed") {
            val host = data.host?.lowercase() ?: ""
            val pathSegments = data.pathSegments.map { it.trim() }.filter { it.isNotEmpty() }
            if (host == "inbox") {
                orbCore.requestInboxOpen()
                return
            }
            if (host == "settings") {
                orbCore.requestSettingsOpen()
                return
            }
            if ((host == "project" || host == "projects") && pathSegments.isNotEmpty()) {
                orbCore.requestProjectFocus(pathSegments.first())
                return
            }
            if ((host == "mission" || host == "missions") && pathSegments.isNotEmpty()) {
                orbCore.requestMissionFocus(pathSegments.first())
                return
            }
            if ((host == "documents" || host == "context") && pathSegments.isNotEmpty()) {
                orbCore.requestDocumentsFocus(pathSegments.first())
                return
            }
        }
        if (!GitHubAuth.isCallback(data)) return
        val result = GitHubAuth.parse(data)
        val token = result.token ?: return
        orbCore.token = token
        container.scope.launch { container.settings.setToken(token) }
    }
}
