package sh.sandboxed.dashboard.orb

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
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
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

enum class OrbSettingsRoute {
    Root,
    Section,
    Fido,
    Backend,
    Providers,
    Machines,
    Inbox,
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
    // A page returns to its section; the section returns to the list.
    val back = { route = if (route != OrbSettingsRoute.Section && section != null) OrbSettingsRoute.Section else OrbSettingsRoute.Root }
    val pendingSecrets by core.pendingSecretRequests.collectAsState()
    val settingsContext = LocalContext.current
    remember(settingsContext) { OrbBtwSettings.init(settingsContext); true }
    val baseURL by core.baseURLFlow.collectAsState()
    val providers by core.providers.collectAsState()
    val nodes by core.nodes.collectAsState()
    var bunkerActive by remember { mutableStateOf(false) }
    var deviceEnrolled by remember { mutableStateOf(true) }
    var quotaExhausted by remember { mutableStateOf(false) }
    val attention = OrbSettingsSection.attention(bunkerActive, deviceEnrolled, quotaExhausted)
    LaunchedEffect(baseURL) {
        runCatching { (OrbJSON.dict(core.request("/api/privilege-access"))?.get("bunker_state") as? Number)?.toInt() ?: 0 }
            .onSuccess { bunkerActive = it > 0 }
        runCatching {
            val mine = OrbApprovalKey.publicKey()
            val devices = OrbJSON.dictList(OrbJSON.dict(core.request("/api/approvals/devices"))?.get("devices"))
            mine == null || devices.any { it["public_key"] == mine }
        }.onSuccess { deviceEnrolled = it }
        runCatching {
            val entries = OrbJSON.dict(core.fetchDict("/api/ai/providers/usage")["entries"]) ?: emptyMap()
            entries.values.any { v -> quotaStatus(providerQuotaWindows(OrbJSON.dict(v)))?.level == OrbQuotaLevel.Exhausted }
        }.onSuccess { quotaExhausted = it }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = OrbStyle.background,
        contentColor = Color.White,
        dragHandle = null
    ) {
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
                .height(680.dp)
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
                            OrbSettingsSection.entries.forEachIndexed { i, sec ->
                                if (i > 0) HorizontalDivider(color = OrbStyle.border, modifier = Modifier.padding(start = 52.dp))
                                OrbSettingsRow(
                                    icon = sectionIcon(sec),
                                    title = sec.label,
                                    subtitle = if (sec == OrbSettingsSection.Security && pendingSecrets > 0) {
                                        "$pendingSecrets access request${if (pendingSecrets == 1) "" else "s"} waiting"
                                    } else sec.subtitle,
                                    attention = sec in attention,
                                    onClick = { section = sec; route = OrbSettingsRoute.Section }
                                )
                            }
                        }
                    }
                }
                OrbSettingsRoute.Section -> {
                    val sec = section ?: OrbSettingsSection.Account
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .verticalScroll(androidx.compose.foundation.rememberScrollState())
                            .padding(horizontal = 20.dp, vertical = 16.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                                contentDescription = "Back",
                                tint = Color.White,
                                modifier = Modifier.clip(CircleShape).orbPressClickable { section = null; route = OrbSettingsRoute.Root }.padding(8.dp)
                            )
                            Text(
                                text = sec.label,
                                color = Color.White,
                                fontSize = 17.sp,
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier.weight(1f),
                                textAlign = androidx.compose.ui.text.style.TextAlign.Center
                            )
                            Spacer(modifier = Modifier.width(40.dp))
                        }
                        Text(text = sec.subtitle, color = OrbStyle.textMuted, fontSize = 13.sp)
                        OrbSettingsGroup {
                            sec.pages.forEachIndexed { i, (_, label, target) ->
                                if (i > 0) HorizontalDivider(color = OrbStyle.border, modifier = Modifier.padding(start = 52.dp))
                                OrbSettingsRow(
                                    icon = sectionIcon(sec),
                                    title = label,
                                    subtitle = pageSubtitle(target, baseURL, providers.size, nodes.size),
                                    onClick = { route = target }
                                )
                            }
                        }
                    }
                }
                OrbSettingsRoute.Backend -> {
                    OrbSetupView(
                        core = core,
                        title = "Backend",
                        onBack = back,
                        onConnected = back
                    )
                }
                OrbSettingsRoute.Providers -> {
                    OrbProvidersSettingsPage(
                        core = core,
                        onBack = back
                    )
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
                OrbSettingsRoute.Inbox -> {
                    OrbInboxSettingsPage(
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
    OrbSettingsSection.Account -> Icons.Default.Dns
    OrbSettingsSection.Models -> Icons.Default.Key
    OrbSettingsSection.Agents -> Icons.Default.Psychology
    OrbSettingsSection.Security -> Icons.Default.Lock
    OrbSettingsSection.Notifications -> Icons.Default.Terminal
}

private fun pageSubtitle(route: OrbSettingsRoute, baseURL: String, providers: Int, nodes: Int): String = when (route) {
    OrbSettingsRoute.Backend -> baseURL.ifEmpty { "Not connected" }
    OrbSettingsRoute.Providers -> "$providers configured"
    OrbSettingsRoute.Machines -> "$nodes nodes"
    OrbSettingsRoute.Inbox -> if (OrbInboxSettings.aiSummary) "AI Overview · ${OrbInboxSettings.model}" else "AI Overview off"
    OrbSettingsRoute.Secrets -> "Approval devices, Fleet Bunker Mode, privileged and mission access"
    OrbSettingsRoute.Bitwarden -> "Token, default project, secrets, default access"
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
    var passwordInput by remember { mutableStateOf("") }
    var isConnecting by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    val signedInToken by core.tokenFlow.collectAsState()
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
        isConnecting = true
        errorMessage = null
        scope.launch {
            try {
                if (passwordInput.isEmpty()) {
                    // Probe health or existing token
                    core.configureSession(cleanBase, core.token, null)
                    core.request("/api/health")
                    core.refreshAll()
                    onConnected()
                } else {
                    core.configureSession(cleanBase, null, passwordInput)
                    val resp = core.request(
                        path = "/api/auth/login",
                        method = "POST",
                        body = mapOf("password" to passwordInput),
                        allowAuthRetry = false
                    )
                    val dict = OrbJSON.dict(resp)
                    val newToken = OrbJSON.str(dict, "token")
                        ?: throw OrbError("Invalid login response")
                    core.configureSession(cleanBase, newToken, passwordInput)
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
}
