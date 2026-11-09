package sh.sandboxed.dashboard.orb

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

enum class OrbSettingsRoute {
    Root,
    Section,
    Fido,
    Backend,
    Users,
    FallbackChains,
    Providers,
    ProxyKeys,
    Skills,
    Assistant,
    Machines,
    Resources,
    Inbox,
    InboxSummaries,
    Secrets,
    Bitwarden,
    Dictation,
    SideQuestions,
    Usage,
    UsageTelemetry,
    DebugInfo
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrbSettingsSheet(
    core: OrbCore,
    initialRoute: OrbSettingsRoute = OrbSettingsRoute.Root,
    onDismiss: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var route by remember { mutableStateOf(initialRoute) }
    var section by remember { mutableStateOf(OrbSettingsSection.of(initialRoute)) }
    val currentUser by core.currentUserFlow.collectAsState()
    val coreAuthMode by core.authModeFlow.collectAsState()
    val isAdmin = OrbCore.computeIsAdmin(coreAuthMode, currentUser)
    fun visiblePages(sec: OrbSettingsSection): List<Triple<String, String, OrbSettingsRoute>> =
        if (isAdmin) sec.pages else sec.pages.filterNot { it.first == "users-settings" }
    val visibleSections = remember(isAdmin) {
        OrbSettingsSection.entries.filter { isAdmin || it != OrbSettingsSection.Security }
    }
    // A page returns to its section unless the section has only one page, which returns directly to Root.
    val back = {
        val sec = section
        if (route != OrbSettingsRoute.Section && sec != null && visiblePages(sec).size > 1) {
            route = OrbSettingsRoute.Section
        } else {
            section = null
            route = OrbSettingsRoute.Root
        }
    }
    val pendingSecrets by core.pendingSecretRequests.collectAsState()
    val settingsContext = LocalContext.current
    remember(settingsContext) { OrbBtwSettings.init(settingsContext); true }
    val baseURL by core.baseURLFlow.collectAsState()
    val providers by core.providers.collectAsState()
    val nodes by core.nodes.collectAsState()
    var bunkerActive by remember { mutableStateOf(false) }
    var deviceEnrolled by remember { mutableStateOf(true) }
    val attention = OrbSettingsSection.attention(
        if (isAdmin) bunkerActive else false,
        if (isAdmin) deviceEnrolled else true
    )
    LaunchedEffect(baseURL, isAdmin) {
        coroutineScope {
            val bunkerTask = if (isAdmin) async {
                runCatching { (OrbJSON.dict(core.request("/api/privilege-access"))?.get("bunker_state") as? Number)?.toInt() ?: 0 }
            } else null
            val devicesTask = if (isAdmin) async {
                runCatching {
                    val mine = OrbApprovalKey.publicKey()
                    val devices = OrbJSON.dictList(OrbJSON.dict(core.request("/api/approvals/devices"))?.get("devices"))
                    mine == null || devices.any { it["public_key"] == mine }
                }
            } else null
            if (bunkerTask != null) {
                bunkerTask.await()
                    .onFailure { if (it is CancellationException) throw it }
                    .onSuccess { bunkerActive = it > 0 }
            } else {
                bunkerActive = false
            }
            if (devicesTask != null) {
                devicesTask.await()
                    .onFailure { if (it is CancellationException) throw it }
                    .onSuccess { deviceEnrolled = it }
            } else {
                deviceEnrolled = true
            }
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = OrbStyle.background,
        contentColor = Color.White,
        dragHandle = null
    ) {
        val sheetView = LocalView.current
        BackHandler(enabled = route != OrbSettingsRoute.Root) {
            back()
        }
        SideEffect {
            (sheetView.parent as? DialogWindowProvider)?.window?.let { win ->
                WindowCompat.getInsetsController(win, sheetView).isAppearanceLightStatusBars = false
                WindowCompat.getInsetsController(win, sheetView).isAppearanceLightNavigationBars = false
            }
        }
        TrackPage("settings", UsageTelemetry.Surface.Sheet)
        TrackPage(
            "settings." + when (route) {
                OrbSettingsRoute.Root -> "root"
                OrbSettingsRoute.Section -> "section." + (section?.id ?: "none")
                else -> OrbSettingsSection.of(route)?.pages?.firstOrNull { it.third == route }?.first ?: route.name.lowercase()
            },
            UsageTelemetry.Surface.Pane
        )
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .fillMaxHeight(0.92f)
                .background(OrbStyle.background)
        ) {
            when (route) {
                OrbSettingsRoute.Root -> {
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .verticalScroll(androidx.compose.foundation.rememberScrollState())
                            .padding(horizontal = 20.dp, vertical = 16.dp),
                        verticalArrangement = Arrangement.spacedBy(20.dp)
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Spacer(modifier = Modifier.width(48.dp))
                            Text(
                                text = "Settings",
                                color = Color.White,
                                fontSize = 17.sp,
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier.weight(1f),
                                textAlign = androidx.compose.ui.text.style.TextAlign.Center
                            )
                            Text(
                                text = "Done",
                                color = Color.White,
                                fontSize = 15.sp,
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier
                                    .clip(CircleShape)
                                    .orbPressClickable { onDismiss() }
                                    .padding(horizontal = 10.dp, vertical = 6.dp)
                            )
                        }

                        OrbSettingsGroup {
                            visibleSections.forEachIndexed { i, sec ->
                                val secPages = visiblePages(sec)
                                if (i > 0) HorizontalDivider(color = OrbStyle.border, modifier = Modifier.padding(start = 52.dp))
                                OrbSettingsRow(
                                    icon = sectionIcon(sec),
                                    title = sec.label,
                                    subtitle = if (sec == OrbSettingsSection.Security && pendingSecrets > 0) {
                                        "$pendingSecrets access request${if (pendingSecrets == 1) "" else "s"} waiting"
                                    } else sec.mobileSummary,
                                    attention = sec in attention,
                                    onClick = {
                                        if (secPages.size == 1) {
                                            section = sec
                                            route = secPages[0].third
                                        } else {
                                            section = sec
                                            route = OrbSettingsRoute.Section
                                        }
                                    }
                                )
                            }
                        }
                    }
                }
                OrbSettingsRoute.Section -> {
                    val sec = section ?: OrbSettingsSection.Account
                    val secPages = visiblePages(sec)
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .verticalScroll(androidx.compose.foundation.rememberScrollState())
                            .padding(horizontal = 20.dp, vertical = 16.dp),
                        verticalArrangement = Arrangement.spacedBy(14.dp)
                    ) {
                        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            OrbCircle(
                                icon = Icons.AutoMirrored.Filled.ArrowBack,
                                size = 38.dp,
                                iconSize = 17.dp,
                                contentDescription = "Back",
                                modifier = Modifier.orbPressClickable { section = null; route = OrbSettingsRoute.Root }
                            )
                            Text(
                                text = sec.label,
                                color = Color.White,
                                fontSize = 17.sp,
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier.weight(1f),
                                textAlign = androidx.compose.ui.text.style.TextAlign.Center
                            )
                            Spacer(modifier = Modifier.width(38.dp))
                        }
                        OrbSettingsGroup {
                            secPages.forEachIndexed { i, (_, label, target) ->
                                if (i > 0) HorizontalDivider(color = OrbStyle.border, modifier = Modifier.padding(start = 52.dp))
                                OrbSettingsRow(
                                    icon = sectionIcon(sec),
                                    title = label,
                                    subtitle = pageSubtitle(target, baseURL, providers.size, nodes.count { isAdmin || !OrbManagedMachines.isAdminOnlyNode(it) }),
                                    onClick = { route = target }
                                )
                            }
                        }
                    }
                }
                OrbSettingsRoute.Backend -> {
                    OrbSetupView(
                        core = core,
                        title = "Account",
                        onBack = back,
                        onConnected = back
                    )
                }
                OrbSettingsRoute.Users -> {
                    OrbUsersSettingsPage(core = core, onBack = back)
                }
                OrbSettingsRoute.FallbackChains -> {
                    OrbRoutingSettingsPage(core = core, onBack = back)
                }
                OrbSettingsRoute.Providers -> {
                    OrbProvidersSettingsPage(
                        core = core,
                        onBack = back
                    )
                }
                OrbSettingsRoute.ProxyKeys -> {
                    OrbProxyKeysSettingsPage(core = core, onBack = back)
                }
                OrbSettingsRoute.Skills -> {
                    OrbSkillsSettingsPage(core = core, onBack = back)
                }
                OrbSettingsRoute.Assistant -> {
                    OrbHermesSettingsPage(core = core, onBack = back)
                }
                OrbSettingsRoute.Secrets -> {
                    OrbSecretsSettingsPage(
                        core = core,
                        onBack = back
                    )
                }
                OrbSettingsRoute.Machines -> {
                    OrbMachinesSettingsPage(
                        core = core,
                        onBack = back
                    )
                }
                OrbSettingsRoute.Resources -> {
                    OrbResourcesSettingsPage(
                        core = core,
                        onBack = back
                    )
                }
                OrbSettingsRoute.Inbox -> {
                    OrbInboxSettingsPage(
                        onBack = back,
                        onOpenSummaries = {
                            section = OrbSettingsSection.Agents
                            route = OrbSettingsRoute.InboxSummaries
                        }
                    )
                }
                OrbSettingsRoute.InboxSummaries -> {
                    OrbInboxSummariesSettingsPage(
                        onBack = back
                    )
                }
                OrbSettingsRoute.Bitwarden -> {
                    OrbBitwardenSettingsPage(
                        core = core,
                        onBack = back,
                        onOpenRequests = { route = OrbSettingsRoute.Secrets }
                    )
                }
                OrbSettingsRoute.Fido -> {
                    OrbFidoSettingsPage(onBack = back)
                }
                OrbSettingsRoute.Dictation -> {
                    OrbDictationSettingsPage(onBack = back)
                }
                OrbSettingsRoute.SideQuestions -> {
                    OrbBtwSettingsPage(onBack = back)
                }
                OrbSettingsRoute.Usage -> {
                    OrbUsageSettingsPage(core = core, onBack = back)
                }
                OrbSettingsRoute.UsageTelemetry -> {
                    OrbUsageTelemetrySettingsPage(core = core, onBack = back)
                }
                OrbSettingsRoute.DebugInfo -> {
                    OrbDebugInfoPage(core = core, onBack = back)
                }
            }
        }
    }
}

@Composable
private fun OrbSettingsGroup(content: @Composable () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
    ) { content() }
}

private fun sectionIcon(section: OrbSettingsSection): ImageVector = when (section) {
    OrbSettingsSection.Account -> Icons.Default.Person
    OrbSettingsSection.Models -> Icons.Default.Memory
    OrbSettingsSection.Agents -> Icons.Default.Psychology
    OrbSettingsSection.Security -> Icons.Default.Lock
    OrbSettingsSection.Notifications -> Icons.Default.Notifications
}

private fun pageSubtitle(route: OrbSettingsRoute, baseURL: String, providers: Int, nodes: Int): String = when (route) {
    OrbSettingsRoute.Backend -> baseURL.ifEmpty { "Not connected" }
    OrbSettingsRoute.Users -> "Accounts, Linux confinement & spend caps"
    OrbSettingsRoute.FallbackChains -> "Ordered fallback chains and provider health"
    OrbSettingsRoute.Providers -> "$providers configured"
    OrbSettingsRoute.ProxyKeys -> "OpenAI-compatible router keys"
    OrbSettingsRoute.Skills -> "Shared Library skills"
    OrbSettingsRoute.Assistant -> "Hermes coordinator model, memory & persona"
    OrbSettingsRoute.Machines -> "$nodes nodes"
    OrbSettingsRoute.Resources -> "Compute & inference flow, subagent Fast-DAG"
    OrbSettingsRoute.Inbox -> if (OrbNotifications.notificationsEnabled) "Alerts on" else "Alerts off"
    OrbSettingsRoute.InboxSummaries -> when {
        !OrbInboxSettings.inboxEnabled -> "Inbox off"
        !OrbInboxSettings.aiSummary -> "AI Overview off"
        else -> "${OrbInboxSettings.summaryMode.label} · ${OrbInboxSettings.model}"
    }
    OrbSettingsRoute.Secrets -> "Fleet Bunker Mode, devices, approvals & grants"
    OrbSettingsRoute.Bitwarden -> "Bitwarden Secrets Manager vault"
    OrbSettingsRoute.Fido -> "Biometric approvals · trust window ${OrbFidoSettings.trust.minutes.let { if (it <= 0) "off" else "$it min" }}"
    OrbSettingsRoute.Dictation -> OrbDictationSettings.stored.let {
        if (it.isEmpty()) "Device language (${OrbDictationSettings.name(OrbDictationSettings.deviceLanguage)})" else OrbDictationSettings.name(it)
    }
    OrbSettingsRoute.SideQuestions -> "${serviceName(OrbBtwSettings.harness)} · ${OrbBtwSettings.model}"
    OrbSettingsRoute.DebugInfo -> "Logs, version, endpoint, recent errors"
    OrbSettingsRoute.Usage -> "Spend over time and top missions"
    OrbSettingsRoute.UsageTelemetry -> if (UsageTelemetry.status.value["enabled"] == true) "On" else "Off"
    else -> ""
}

@Composable
private fun OrbSettingsRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    attention: Boolean = false,
    onClick: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .orbPressClickable { onClick() }
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = OrbStyle.icon,
            modifier = Modifier.size(18.dp)
        )
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp)
        ) {
            Text(
                text = title,
                color = Color.White,
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium
            )
            Text(
                text = subtitle,
                color = OrbStyle.textMuted,
                fontSize = 12.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
        if (attention) {
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(Color(0xFFE5484D))
                    .semantics { contentDescription = "Needs attention" }
            )
        }
        Icon(
            imageVector = Icons.Default.ChevronRight,
            contentDescription = null,
            tint = OrbStyle.textMuted,
            modifier = Modifier.size(14.dp)
        )
    }
}

@Composable
fun OrbSetupView(
    core: OrbCore,
    title: String = "Server",
    onBack: (() -> Unit)? = null,
    onConnected: () -> Unit,
    modifier: Modifier = Modifier
) {
    val scope = rememberCoroutineScope()
    val savedBase by core.baseURLFlow.collectAsState()
    var urlInput by remember(savedBase) {
        mutableStateOf(savedBase.ifEmpty { "https://agent-backend.thomas.md" })
    }
    var usernameInput by remember(savedBase) {
        mutableStateOf(core.savedUsername(savedBase))
    }
    var passwordInput by remember { mutableStateOf("") }
    var authMode by remember { mutableStateOf("single_tenant") }
    var showChangePassword by remember { mutableStateOf(false) }
    var noticeMessage by remember { mutableStateOf<String?>(null) }
    var isConnecting by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    val signedInToken by core.tokenFlow.collectAsState()
    val currentUser by core.currentUserFlow.collectAsState()
    val bgSyncState by OrbBackgroundSyncMonitor.stateFlow.collectAsState()
    val isConnectedSession = onBack != null && core.isConfigured && (!signedInToken.isNullOrEmpty() || authMode == "disabled")

    LaunchedEffect(urlInput) {
        val cleanBase = urlInput.trim().trimEnd('/')
        if (!cleanBase.startsWith("http://") && !cleanBase.startsWith("https://")) return@LaunchedEffect
        delay(250L)
        val detected = withContext(Dispatchers.IO) {
            runCatching {
                val req = okhttp3.Request.Builder().url("$cleanBase/api/health").get().build()
                core.httpClient.newCall(req).execute().use { resp ->
                    val body = resp.body?.string().orEmpty()
                    OrbJSON.dict(OrbJSON.parse(body))
                }
            }.getOrNull()
        } ?: return@LaunchedEffect
        authMode = OrbJSON.str(detected, "auth_mode")
            ?: if (OrbJSON.bool(detected, "auth_required") == true) "single_tenant" else "disabled"
    }

    val gitHubButton = remember {
        OrbGitHubSignInButton(OrbGitHubSignIn(OrbGitHubSignIn.prefsStore(context))) { base ->
            // The callback is only accepted for the endpoint the app is configured with.
            core.configureSession(base, core.token, null)
            sh.sandboxed.dashboard.util.GitHubAuth.launch(context, base)
        }
    }
    var gitHubState by remember { mutableStateOf<OrbGitHubSignInButton.State>(OrbGitHubSignInButton.State.Idle) }
    LaunchedEffect(gitHubState, signedInToken) {
        val pending = gitHubState as? OrbGitHubSignInButton.State.Pending ?: return@LaunchedEffect
        while (isActive) {
            delay(1_000)
            val next = gitHubButton.refresh(pending)
            if (next != pending) {
                gitHubState = next
                if (!core.token.isNullOrEmpty() && core.baseURL.trimEnd('/').equals(pending.endpoint, ignoreCase = true)) onConnected()
                break
            }
        }
    }

    fun connect() {
        val cleanBase = urlInput.trim().trimEnd('/')
        if (cleanBase.isEmpty()) return
        val trimmedUser = usernameInput.trim()
        if (authMode == "multi_user" && passwordInput.isNotEmpty() && trimmedUser.isEmpty()) {
            errorMessage = "Username is required for multi-user servers."
            return
        }
        isConnecting = true
        errorMessage = null
        noticeMessage = null
        scope.launch {
            try {
                if (passwordInput.isEmpty()) {
                    // Probe health or existing token
                    core.configureSession(cleanBase, core.token, null)
                    core.request("/api/health")
                    core.refreshAll()
                    onConnected()
                } else {
                    core.configureSession(cleanBase, null, passwordInput, trimmedUser)
                    val loginBody = LinkedHashMap<String, Any?>().apply {
                        put("password", passwordInput)
                        if (authMode == "multi_user" && trimmedUser.isNotEmpty()) {
                            put("username", trimmedUser)
                        }
                    }
                    val resp = core.request(
                        path = "/api/auth/login",
                        method = "POST",
                        body = loginBody,
                        allowAuthRetry = false
                    )
                    val dict = OrbJSON.dict(resp)
                    val newToken = OrbJSON.str(dict, "token")
                        ?: throw OrbError("Invalid login response")
                    core.configureSession(cleanBase, newToken, passwordInput, trimmedUser)
                    core.refreshAll()
                    onConnected()
                }
            } catch (e: Throwable) {
                errorMessage = e.message ?: "Connection failed"
            } finally {
                isConnecting = false
            }
        }
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(OrbStyle.background)
            .verticalScroll(androidx.compose.foundation.rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            if (onBack != null) {
                Box(
                    modifier = Modifier
                        .size(38.dp)
                        .clip(CircleShape)
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, CircleShape)
                        .orbPressClickable { onBack() },
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = "Back",
                        tint = Color.White,
                        modifier = Modifier.size(17.dp)
                    )
                }
            } else {
                Spacer(modifier = Modifier.width(38.dp))
            }
            Text(
                text = title,
                color = Color.White,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center
            )
            Spacer(modifier = Modifier.width(38.dp))
        }

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                text = "BACKEND URL",
                color = OrbStyle.textMuted,
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 0.6.sp
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(OrbStyle.surface)
                    .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
                    .padding(horizontal = 14.dp, vertical = 13.dp)
            ) {
                if (urlInput.isEmpty()) {
                    Text("https://agent-backend.thomas.md", color = OrbStyle.textMuted, fontSize = 15.sp)
                }
                BasicTextField(
                    value = urlInput,
                    onValueChange = { urlInput = it },
                    textStyle = TextStyle(color = Color.White, fontSize = 15.sp),
                    cursorBrush = SolidColor(Color.White),
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    modifier = Modifier.fillMaxWidth()
                )
            }
        }

        if (authMode == "multi_user") {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    text = "USERNAME",
                    color = OrbStyle.textMuted,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 0.6.sp
                )
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
                        .padding(horizontal = 14.dp, vertical = 13.dp)
                ) {
                    if (usernameInput.isEmpty()) {
                        Text("Account username", color = OrbStyle.textMuted, fontSize = 15.sp)
                    }
                    BasicTextField(
                        value = usernameInput,
                        onValueChange = { usernameInput = it },
                        textStyle = TextStyle(color = Color.White, fontSize = 15.sp),
                        cursorBrush = SolidColor(Color.White),
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                text = "PASSWORD",
                color = OrbStyle.textMuted,
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 0.6.sp
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(OrbStyle.surface)
                    .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
                    .padding(horizontal = 14.dp, vertical = 13.dp)
            ) {
                if (passwordInput.isEmpty()) {
                    Text("Optional if no auth or already signed in", color = OrbStyle.textMuted, fontSize = 15.sp)
                }
                BasicTextField(
                    value = passwordInput,
                    onValueChange = { passwordInput = it },
                    textStyle = TextStyle(color = Color.White, fontSize = 15.sp),
                    cursorBrush = SolidColor(Color.White),
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    modifier = Modifier.fillMaxWidth()
                )
            }
        }

        noticeMessage?.let { msg ->
            Text(text = msg, color = OrbStyle.success, fontSize = 13.sp)
        }

        errorMessage?.let { err ->
            OrbNotice(title = err, log = core.lastErrorLog.value)
        }

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .background(Color.White)
                .orbPressClickable(enabled = !isConnecting) { connect() }
                .padding(vertical = 14.dp),
            contentAlignment = Alignment.Center
        ) {
            if (isConnecting) {
                CircularProgressIndicator(
                    color = Color.Black,
                    strokeWidth = 2.dp,
                    modifier = Modifier.size(18.dp)
                )
            } else {
                Text(
                    text = "Connect",
                    color = Color.Black,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold
                )
            }
        }

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .background(OrbStyle.surface)
                .border(1.dp, OrbStyle.border, RoundedCornerShape(14.dp))
                .orbPressClickable(enabled = !isConnecting && gitHubState !is OrbGitHubSignInButton.State.Pending) {
                    errorMessage = null
                    gitHubState = gitHubButton.start(urlInput)
                }
                .padding(vertical = 14.dp)
                .semantics { contentDescription = "Sign in with GitHub" },
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = if (gitHubState is OrbGitHubSignInButton.State.Pending) "Waiting for GitHub…" else "Sign in with GitHub",
                color = Color.White,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold
            )
        }
        when (val state = gitHubState) {
            is OrbGitHubSignInButton.State.Pending -> Text(
                "Finish signing in in the browser. Orb accepts the sign-in for this server for 10 minutes.",
                color = OrbStyle.textMuted,
                fontSize = 13.sp
            )
            is OrbGitHubSignInButton.State.Failed -> OrbNotice(title = state.message, log = null)
            OrbGitHubSignInButton.State.Idle -> Unit
        }

        if (isConnectedSession) {
            currentUser?.let { u ->
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = "SIGNED IN AS",
                        color = OrbStyle.textMuted,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 0.6.sp
                    )
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(14.dp))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(14.dp))
                            .padding(horizontal = 14.dp, vertical = 12.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        Text(
                            text = "@${u.username} · ${if (u.role == "admin") "Admin" else "Member"}",
                            color = Color.White,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold
                        )
                        val meta = buildList {
                            if (!u.unixUsername.isNullOrEmpty()) add("/home/${u.unixUsername}")
                            add("${OrbUsersModel.formatUsdFromCents(u.spentTodayCents)} / ${OrbUsersModel.formatUsdFromCents(u.dailySpendCapCents)} today")
                        }.joinToString(" · ")
                        Text(
                            text = meta,
                            color = OrbStyle.textMuted,
                            fontSize = 12.sp
                        )
                    }
                }
            }

            if (authMode == "single_tenant" || authMode == "multi_user") {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = if (authMode == "multi_user") "ACCOUNT PASSWORD" else "SERVER PASSWORD",
                        color = OrbStyle.textMuted,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 0.6.sp
                    )
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(14.dp))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(14.dp))
                            .padding(horizontal = 14.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(
                                if (authMode == "multi_user") "Account password" else "Single-tenant password",
                                color = Color.White,
                                fontSize = 14.sp,
                                fontWeight = FontWeight.Medium
                            )
                            Text(
                                if (authMode == "multi_user") "Rotate your account password and sign-in sessions."
                                else "Rotate the password required to sign in to this server.",
                                color = OrbStyle.textMuted,
                                fontSize = 12.sp
                            )
                        }
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(10.dp))
                                .background(OrbStyle.card)
                                .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp))
                                .orbPressClickable { showChangePassword = true }
                                .padding(horizontal = 12.dp, vertical = 8.dp)
                        ) {
                            Text("Change…", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                        }
                    }
                }
            }

            OrbGitHubIntegrationCard(core = core)
        }

        if (onBack != null) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    text = "BACKGROUND SYNC",
                    color = OrbStyle.textMuted,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 0.6.sp
                )
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, RoundedCornerShape(14.dp))
                        .padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
                            .background(OrbStyle.background)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp))
                            .padding(3.dp),
                        horizontalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        OrbBackgroundSyncMode.entries.forEach { option ->
                            val selected = bgSyncState.mode == option
                            Box(
                                modifier = Modifier
                                    .weight(1f)
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(if (selected) OrbStyle.surface else Color.Transparent)
                                    .then(
                                        if (selected) Modifier.border(1.dp, OrbStyle.border, RoundedCornerShape(8.dp))
                                        else Modifier
                                    )
                                    .orbPressClickable { OrbBackgroundSyncMonitor.setMode(option) }
                                    .padding(vertical = 8.dp)
                                    .semantics { contentDescription = "Background sync ${option.label}" },
                                contentAlignment = Alignment.Center
                            ) {
                                Text(
                                    text = option.label,
                                    color = if (selected) Color.White else OrbStyle.textMuted,
                                    fontSize = 13.sp,
                                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium
                                )
                            }
                        }
                    }
                    Text(
                        text = OrbBackgroundSyncPolicy.statusText(bgSyncState),
                        color = OrbStyle.textMuted,
                        fontSize = 13.sp,
                        lineHeight = 18.sp
                    )
                }
            }
        }

        if (core.isConfigured) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .background(OrbStyle.surface)
                    .border(1.dp, OrbStyle.border, RoundedCornerShape(14.dp))
                    .orbPressClickable {
                        core.clearSession()
                    }
                    .padding(vertical = 13.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = "Sign out & clear cache",
                    color = OrbStyle.error,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium
                )
            }
        }
    }

    if (showChangePassword) {
        OrbChangePasswordDialog(
            core = core,
            onDismiss = { showChangePassword = false },
            onSaved = { msg ->
                showChangePassword = false
                noticeMessage = msg
            }
        )
    }
}
