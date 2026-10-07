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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Memory
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
    Backend,
    Providers,
    Machines
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrbSettingsSheet(
    core: OrbCore,
    onDismiss: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var route by remember { mutableStateOf(OrbSettingsRoute.Root) }
    val baseURL by core.baseURLFlow.collectAsState()
    val providers by core.providers.collectAsState()
    val nodes by core.nodes.collectAsState()
    val remoteTargets by core.remoteTargets.collectAsState()

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = OrbStyle.background,
        contentColor = Color.White,
        dragHandle = null
    ) {
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

                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(16.dp))
                                .background(OrbStyle.surface)
                                .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                        ) {
                            OrbSettingsRow(
                                icon = Icons.Default.Dns,
                                title = "Backend",
                                subtitle = baseURL.ifEmpty { "Not connected" },
                                onClick = { route = OrbSettingsRoute.Backend }
                            )
                            HorizontalDivider(
                                color = OrbStyle.border,
                                modifier = Modifier.padding(start = 52.dp)
                            )
                            OrbSettingsRow(
                                icon = Icons.Default.Key,
                                title = "Providers",
                                subtitle = "${providers.size} configured",
                                onClick = { route = OrbSettingsRoute.Providers }
                            )
                            HorizontalDivider(
                                color = OrbStyle.border,
                                modifier = Modifier.padding(start = 52.dp)
                            )
                            OrbSettingsRow(
                                icon = Icons.Default.Memory,
                                title = "Machines",
                                subtitle = "${nodes.size} nodes · ${remoteTargets.size} SSH",
                                onClick = { route = OrbSettingsRoute.Machines }
                            )
                        }
                    }
                }
                OrbSettingsRoute.Backend -> {
                    OrbSetupView(
                        core = core,
                        title = "Backend",
                        onBack = { route = OrbSettingsRoute.Root },
                        onConnected = { route = OrbSettingsRoute.Root }
                    )
                }
                OrbSettingsRoute.Providers -> {
                    OrbProvidersSettingsPage(
                        core = core,
                        onBack = { route = OrbSettingsRoute.Root }
                    )
                }
                OrbSettingsRoute.Machines -> {
                    OrbMachinesSettingsPage(
                        core = core,
                        onBack = { route = OrbSettingsRoute.Root }
                    )
                }
            }
        }
    }
}

@Composable
private fun OrbSettingsRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
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

private fun providerQuotaWindows(detail: OrbDict?): List<Pair<String, Double>> {
    if (detail == null) return emptyList()
    val result = mutableListOf<Pair<String, Double>>()
    fun add(label: String, key: String, scale: Double = 100.0, remaining: Boolean = false) {
        val raw = OrbJSON.double(detail, key) ?: return
        if (!raw.isFinite()) return
        val ratio = if (remaining) 1.0 - (raw / scale) else raw / scale
        result.add(label to ratio.coerceIn(0.0, 1.0))
    }
    add("5h", "unified_5h_utilization", scale = 1.0)
    add("Weekly", "unified_7d_utilization", scale = 1.0)
    if ((OrbJSON.double(detail, "codex_primary_window_minutes") ?: 0.0) != 0.0) {
        add("Primary", "codex_primary_used_percent")
    }
    if ((OrbJSON.double(detail, "codex_secondary_window_minutes") ?: 0.0) != 0.0) {
        add("Secondary", "codex_secondary_used_percent")
    }
    add("Credits", "xai_credit_used_percent")
    val kimiWindows = OrbJSON.dictList(detail["kimi_windows"])
    if (kimiWindows.isEmpty()) {
        add("5h", "kimi_5h_used_percent")
        add("Weekly", "kimi_weekly_used_percent")
    } else {
        for (w in kimiWindows) {
            val pct = OrbJSON.double(w, "used_percent") ?: continue
            if (pct.isFinite()) {
                val lbl = OrbJSON.str(w, "label") ?: "Window"
                result.add(lbl to (pct / 100.0).coerceIn(0.0, 1.0))
            }
        }
    }
    add("5h", "minimax_interval_remaining_percent", remaining = true)
    add("Weekly", "minimax_weekly_remaining_percent", remaining = true)
    add("5h", "zai_5h_used_percent")
    add("Weekly", "zai_weekly_used_percent")
    if (detail["zai_5h_used_percent"] == null && detail["zai_weekly_used_percent"] == null) {
        add("Tokens", "zai_tokens_percentage")
    }
    return result
}

private fun providerStatusSubtitle(provider: OrbRow, detail: OrbDict?): String {
    val providerType = provider.str("provider_type", "type") ?: ""
    val statusObj = provider.dict("status")
    val statusType = OrbJSON.str(statusObj, "type") ?: provider.str("status", "state") ?: "ready"
    val detailStatus = OrbJSON.str(detail, "status") ?: ""
    val detailError = OrbJSON.str(detail, "error") ?: ""
    val state = when {
        provider.bool("enabled") == false -> "Disabled"
        statusType == "needs_reauth" || detailStatus == "needs_reauth" -> "Reconnect"
        detailError.isNotEmpty() -> "Usage unavailable"
        providerQuotaWindows(detail).any { it.second >= 1.0 } -> "Quota exhausted"
        else -> statusType.replace("_", " ")
    }
    return if (providerType.isNotEmpty()) "$providerType · $state" else state
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrbProvidersSettingsPage(
    core: OrbCore,
    onBack: () -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val cachedProviders by core.providers.collectAsState()
    var providers by remember(cachedProviders) { mutableStateOf(cachedProviders) }
    var usageEntries by remember { mutableStateOf<Map<String, OrbDict>>(emptyMap()) }
    var cloudAccounts by remember { mutableStateOf<List<OrbRow>>(emptyList()) }
    var cloudUsage by remember { mutableStateOf<Map<String, OrbDict>>(emptyMap()) }
    var expandedIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var expandedCloudIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var isRefreshing by remember { mutableStateOf(false) }
    var editingProvider by remember { mutableStateOf<OrbRow?>(null) }
    var showAddKeyModal by remember { mutableStateOf(false) }
    var addKeyProviderType by remember { mutableStateOf("openai") }
    var nameDraft by remember { mutableStateOf("") }
    var apiKeyDraft by remember { mutableStateOf("") }
    var savingKey by remember { mutableStateOf(false) }
    var statusBanner by remember { mutableStateOf<String?>(null) }
    var errorBanner by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }

    suspend fun loadProvidersAndUsage() {
        try {
            val loaded = core.fetchRows("/api/ai/providers", "providers")
            providers = loaded
            errorBanner = null
        } catch (e: Throwable) {
            errorBanner = e.message
        }
        try {
            val usageResp = core.fetchDict("/api/ai/providers/usage")
            val entriesDict = OrbJSON.dict(usageResp["entries"]) ?: emptyMap()
            val mutableEntries = mutableMapOf<String, OrbDict>()
            for ((k, v) in entriesDict) {
                OrbJSON.dict(v)?.let { mutableEntries[k] = it }
            }
            val targets = providers.filter { p ->
                val pType = p.str("provider_type") ?: ""
                pType in setOf("kimi", "minimax", "zai") || p.bool("uses_oauth") == true
            }
            for (target in targets) {
                val id = target.id
                val detail = runCatching {
                    core.fetchDict("/api/ai/providers/${core.encodeComponent(id)}/usage")
                }.getOrNull()
                if (detail != null && detail.isNotEmpty()) {
                    mutableEntries[id] = detail
                }
            }
            usageEntries = mutableEntries
        } catch (_: Throwable) {
        }
        try {
            cloudAccounts = core.fetchRows("/api/cloud/accounts", "items")
        } catch (_: Throwable) {
        }
        try {
            val cUsage = core.fetchDict("/api/cloud/usage")
            val accountsDict = OrbJSON.dict(cUsage["accounts"]) ?: emptyMap()
            val mapped = mutableMapOf<String, OrbDict>()
            for ((k, v) in accountsDict) {
                OrbJSON.dict(v)?.let { mapped[k] = it }
            }
            cloudUsage = mapped
        } catch (_: Throwable) {
        }
    }

    LaunchedEffect(Unit) {
        isRefreshing = true
        loadProvidersAndUsage()
        isRefreshing = false
    }

    fun toggleProvider(provider: OrbRow) {
        if (busy) return
        busy = true
        val currentlyEnabled = provider.bool("enabled") != false
        scope.launch {
            try {
                core.request(
                    path = "/api/ai/providers/${core.encodeComponent(provider.id)}",
                    method = "PUT",
                    body = mapOf("enabled" to !currentlyEnabled)
                )
                loadProvidersAndUsage()
                core.refreshAll()
            } catch (e: Throwable) {
                errorBanner = e.message
            } finally {
                busy = false
            }
        }
    }

    fun saveApiKey(provider: OrbRow?) {
        val pid = provider?.id
        savingKey = true
        scope.launch {
            try {
                val body = mutableMapOf<String, Any?>(
                    "name" to nameDraft.trim().ifEmpty { provider?.str("name") ?: addKeyProviderType },
                    "api_key" to apiKeyDraft.trim()
                )
                if (pid == null) {
                    body["provider_type"] = addKeyProviderType
                }
                core.request(
                    path = if (pid == null) "/api/ai/providers" else "/api/ai/providers/${core.encodeComponent(pid)}",
                    method = if (pid == null) "POST" else "PUT",
                    body = body
                )
                editingProvider = null
                showAddKeyModal = false
                apiKeyDraft = ""
                nameDraft = ""
                statusBanner = "Saved API key"
                loadProvidersAndUsage()
                core.refreshAll()
            } catch (e: Throwable) {
                errorBanner = e.message
            } finally {
                savingKey = false
            }
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(OrbStyle.background)
    ) {
        // Header matching iOS NavigationStack inline bar
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
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
            Text(
                text = "Providers",
                color = Color.White,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center
            )
            Box(
                modifier = Modifier
                    .size(38.dp)
                    .clip(CircleShape)
                    .background(OrbStyle.surface)
                    .border(1.dp, OrbStyle.border, CircleShape)
                    .orbPressClickable {
                        scope.launch {
                            isRefreshing = true
                            loadProvidersAndUsage()
                            core.refreshAll()
                            isRefreshing = false
                        }
                    },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Default.Refresh,
                    contentDescription = "Refresh",
                    tint = Color.White,
                    modifier = Modifier.size(16.dp)
                )
            }
        }

        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = {
                scope.launch {
                    isRefreshing = true
                    loadProvidersAndUsage()
                    core.refreshAll()
                    isRefreshing = false
                }
            },
            modifier = Modifier.fillMaxSize()
        ) {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = 20.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                errorBanner?.let { err ->
                    item { OrbNotice(title = err, log = core.lastErrorLog.value) }
                }
                statusBanner?.let { msg ->
                    item {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(12.dp))
                                .background(OrbStyle.surface)
                                .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
                                .padding(12.dp)
                        ) {
                            Text(text = msg, color = OrbStyle.success, fontSize = 13.sp)
                        }
                    }
                }

                // Section("Accounts")
                item {
                    Text(
                        text = "ACCOUNTS",
                        color = OrbStyle.textMuted,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 0.7.sp
                    )
                }

                if (providers.isEmpty() && !isRefreshing) {
                    item {
                        Text(
                            text = "No providers configured.",
                            color = OrbStyle.textMuted,
                            fontSize = 14.sp
                        )
                    }
                } else {
                    item {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(16.dp))
                                .background(OrbStyle.surface)
                                .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                        ) {
                            providers.forEachIndexed { idx, provider ->
                                val pid = provider.id
                                val name = provider.str("name", "label", "id") ?: pid
                                val detail = usageEntries[pid]
                                val subtitle = providerStatusSubtitle(provider, detail)
                                val expanded = expandedIds.contains(pid)
                                val windows = providerQuotaWindows(detail)
                                val canEditKey = provider.bool("has_api_key") == true || provider.bool("uses_oauth") != true
                                val enabled = provider.bool("enabled") != false

                                Column(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .orbPressClickable {
                                            expandedIds = if (expanded) expandedIds - pid else expandedIds + pid
                                        }
                                        .padding(horizontal = 16.dp, vertical = 13.dp),
                                    verticalArrangement = Arrangement.spacedBy(10.dp)
                                ) {
                                    Row(
                                        modifier = Modifier.fillMaxWidth(),
                                        verticalAlignment = Alignment.CenterVertically
                                    ) {
                                        Column(
                                            modifier = Modifier.weight(1f),
                                            verticalArrangement = Arrangement.spacedBy(3.dp)
                                        ) {
                                            Text(
                                                text = name,
                                                color = Color.White,
                                                fontSize = 15.sp,
                                                fontWeight = FontWeight.Medium
                                            )
                                            Text(
                                                text = subtitle,
                                                color = OrbStyle.textSecondary,
                                                fontSize = 12.sp
                                            )
                                        }
                                        Icon(
                                            imageVector = Icons.Default.ChevronRight,
                                            contentDescription = null,
                                            tint = OrbStyle.textMuted,
                                            modifier = Modifier.size(16.dp)
                                        )
                                    }

                                    if (expanded) {
                                        Column(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .padding(top = 4.dp),
                                            verticalArrangement = Arrangement.spacedBy(10.dp)
                                        ) {
                                            if (windows.isEmpty()) {
                                                Text(
                                                    text = "No quota information available.",
                                                    color = OrbStyle.textMuted,
                                                    fontSize = 12.sp
                                                )
                                            } else {
                                                windows.forEach { (wLabel, ratio) ->
                                                    val pctInt = (ratio * 100.0).roundToInt()
                                                    Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                                                        Row(
                                                            modifier = Modifier.fillMaxWidth(),
                                                            horizontalArrangement = Arrangement.SpaceBetween
                                                        ) {
                                                            Text(
                                                                text = wLabel,
                                                                color = Color.White,
                                                                fontSize = 13.sp
                                                            )
                                                            Text(
                                                                text = "$pctInt% used",
                                                                color = OrbStyle.textSecondary,
                                                                fontSize = 13.sp
                                                            )
                                                        }
                                                        Box(
                                                            modifier = Modifier
                                                                .fillMaxWidth()
                                                                .height(4.dp)
                                                                .clip(CircleShape)
                                                                .background(OrbStyle.card)
                                                        ) {
                                                            Box(
                                                                modifier = Modifier
                                                                    .fillMaxWidth(ratio.toFloat().coerceIn(0f, 1f))
                                                                    .height(4.dp)
                                                                    .clip(CircleShape)
                                                                    .background(
                                                                        if (ratio >= 0.9) OrbStyle.warning else OrbStyle.inboxBlue
                                                                    )
                                                            )
                                                        }
                                                    }
                                                }
                                            }

                                            OrbJSON.str(detail, "error")?.takeIf { it.isNotEmpty() }?.let { errText ->
                                                Text(text = errText, color = OrbStyle.warning, fontSize = 12.sp)
                                            }
                                            OrbJSON.str(detail, "usage_note")?.takeIf { it.isNotEmpty() }?.let { noteText ->
                                                Text(text = noteText, color = OrbStyle.textMuted, fontSize = 12.sp)
                                            }

                                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                                if (canEditKey) {
                                                    Box(
                                                        modifier = Modifier
                                                            .clip(CircleShape)
                                                            .background(OrbStyle.card)
                                                            .border(1.dp, OrbStyle.border, CircleShape)
                                                            .orbPressClickable {
                                                                if (editingProvider?.id == pid) {
                                                                    editingProvider = null
                                                                } else {
                                                                    editingProvider = provider
                                                                    nameDraft = name
                                                                    apiKeyDraft = ""
                                                                }
                                                            }
                                                            .padding(horizontal = 12.dp, vertical = 6.dp)
                                                    ) {
                                                        Text(
                                                            text = "Edit API key",
                                                            color = Color.White,
                                                            fontSize = 12.sp,
                                                            fontWeight = FontWeight.Medium
                                                        )
                                                    }
                                                }
                                                Box(
                                                    modifier = Modifier
                                                        .clip(CircleShape)
                                                        .background(OrbStyle.card)
                                                        .border(1.dp, OrbStyle.border, CircleShape)
                                                        .orbPressClickable { toggleProvider(provider) }
                                                        .padding(horizontal = 12.dp, vertical = 6.dp)
                                                ) {
                                                    Text(
                                                        text = if (enabled) "Disable" else "Enable",
                                                        color = if (enabled) OrbStyle.textSecondary else OrbStyle.success,
                                                        fontSize = 12.sp,
                                                        fontWeight = FontWeight.Medium
                                                    )
                                                }
                                            }

                                            if (editingProvider?.id == pid) {
                                                Row(
                                                    modifier = Modifier
                                                        .fillMaxWidth()
                                                        .clip(RoundedCornerShape(10.dp))
                                                        .background(OrbStyle.card)
                                                        .border(1.dp, OrbStyle.borderStrong, RoundedCornerShape(10.dp))
                                                        .padding(horizontal = 10.dp, vertical = 8.dp),
                                                    verticalAlignment = Alignment.CenterVertically,
                                                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                                                ) {
                                                    Box(modifier = Modifier.weight(1f)) {
                                                        if (apiKeyDraft.isEmpty()) {
                                                            Text("Paste API key…", color = OrbStyle.textMuted, fontSize = 13.sp)
                                                        }
                                                        BasicTextField(
                                                            value = apiKeyDraft,
                                                            onValueChange = { apiKeyDraft = it },
                                                            textStyle = TextStyle(
                                                                color = Color.White,
                                                                fontSize = 13.sp,
                                                                fontFamily = FontFamily.Monospace
                                                            ),
                                                            cursorBrush = SolidColor(Color.White),
                                                            singleLine = true,
                                                            modifier = Modifier.fillMaxWidth()
                                                        )
                                                    }
                                                    Text(
                                                        text = if (savingKey) "…" else "Save",
                                                        color = Color.Black,
                                                        fontSize = 12.sp,
                                                        fontWeight = FontWeight.SemiBold,
                                                        modifier = Modifier
                                                            .clip(CircleShape)
                                                            .background(Color.White)
                                                            .orbPressClickable(enabled = !savingKey && apiKeyDraft.trim().isNotEmpty()) {
                                                                saveApiKey(provider)
                                                            }
                                                            .padding(horizontal = 10.dp, vertical = 5.dp)
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }

                                if (idx < providers.lastIndex) {
                                    HorizontalDivider(
                                        color = OrbStyle.border,
                                        modifier = Modifier.padding(start = 16.dp)
                                    )
                                }
                            }
                        }
                    }
                }

                // Section("Cloud agents") matching OrbCloudAccountsSettings
                item {
                    Text(
                        text = "CLOUD AGENTS",
                        color = OrbStyle.textMuted,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 0.7.sp
                    )
                }

                item {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(16.dp))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                    ) {
                        if (cloudAccounts.isEmpty()) {
                            Text(
                                text = "No cloud accounts configured.",
                                color = OrbStyle.textMuted,
                                fontSize = 14.sp,
                                modifier = Modifier.padding(16.dp)
                            )
                        } else {
                            cloudAccounts.forEachIndexed { idx, account ->
                                val cid = account.id
                                val label = account.str("label", "name", "provider", "id") ?: cid
                                val available = account.bool("available") == true
                                val expanded = expandedCloudIds.contains(cid)
                                val reason = account.str("reason") ?: ""
                                val windows = OrbJSON.dictList(cloudUsage[cid]?.get("windows"))

                                Column(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .orbPressClickable {
                                            expandedCloudIds = if (expanded) expandedCloudIds - cid else expandedCloudIds + cid
                                        }
                                        .padding(horizontal = 16.dp, vertical = 13.dp),
                                    verticalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    Row(
                                        modifier = Modifier.fillMaxWidth(),
                                        verticalAlignment = Alignment.CenterVertically
                                    ) {
                                        Column(
                                            modifier = Modifier.weight(1f),
                                            verticalArrangement = Arrangement.spacedBy(2.dp)
                                        ) {
                                            Text(
                                                text = label,
                                                color = Color.White,
                                                fontSize = 15.sp,
                                                fontWeight = FontWeight.Medium
                                            )
                                            Text(
                                                text = if (available) "Available" else "Unavailable",
                                                color = OrbStyle.textSecondary,
                                                fontSize = 12.sp
                                            )
                                        }
                                        Icon(
                                            imageVector = Icons.Default.ChevronRight,
                                            contentDescription = null,
                                            tint = OrbStyle.textMuted,
                                            modifier = Modifier.size(16.dp)
                                        )
                                    }

                                    if (expanded) {
                                        if (reason.isNotEmpty()) {
                                            Text(text = reason, color = OrbStyle.textSecondary, fontSize = 12.sp)
                                        }
                                        windows.forEach { w ->
                                            val wLabel = OrbJSON.str(w, "label") ?: "Usage"
                                            val pct = OrbJSON.double(w, "used_percent") ?: 0.0
                                            val ratio = (pct / 100.0).coerceIn(0.0, 1.0)
                                            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                                Row(
                                                    modifier = Modifier.fillMaxWidth(),
                                                    horizontalArrangement = Arrangement.SpaceBetween
                                                ) {
                                                    Text(text = wLabel, color = Color.White, fontSize = 12.sp)
                                                    Text(text = "${pct.roundToInt()}% used", color = OrbStyle.textSecondary, fontSize = 12.sp)
                                                }
                                                Box(
                                                    modifier = Modifier
                                                        .fillMaxWidth()
                                                        .height(4.dp)
                                                        .clip(CircleShape)
                                                        .background(OrbStyle.card)
                                                ) {
                                                    Box(
                                                        modifier = Modifier
                                                            .fillMaxWidth(ratio.toFloat())
                                                            .height(4.dp)
                                                            .clip(CircleShape)
                                                            .background(OrbStyle.inboxBlue)
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }
                                HorizontalDivider(
                                    color = OrbStyle.border,
                                    modifier = Modifier.padding(start = 16.dp)
                                )
                            }
                        }

                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .orbPressClickable {
                                    scope.launch {
                                        isRefreshing = true
                                        loadProvidersAndUsage()
                                        isRefreshing = false
                                    }
                                }
                                .padding(horizontal = 16.dp, vertical = 13.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = "Refresh cloud accounts",
                                color = OrbStyle.inboxBlue,
                                fontSize = 15.sp,
                                fontWeight = FontWeight.Medium
                            )
                        }
                    }
                }

                // Bottom action section ("Add API key", "Connect subscription")
                item {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(16.dp))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                    ) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .orbPressClickable {
                                    showAddKeyModal = !showAddKeyModal
                                    nameDraft = ""
                                    apiKeyDraft = ""
                                }
                                .padding(horizontal = 16.dp, vertical = 13.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Default.Add,
                                contentDescription = null,
                                tint = OrbStyle.inboxBlue,
                                modifier = Modifier.size(18.dp)
                            )
                            Text(
                                text = "Add API key",
                                color = OrbStyle.inboxBlue,
                                fontSize = 15.sp,
                                fontWeight = FontWeight.Medium
                            )
                        }

                        if (showAddKeyModal) {
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 16.dp, vertical = 10.dp),
                                verticalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                OrbMiniField("Provider type (openai, anthropic, google, xai…)", addKeyProviderType) {
                                    addKeyProviderType = it
                                }
                                OrbMiniField("Name", nameDraft) { nameDraft = it }
                                OrbMiniField("API key", apiKeyDraft) { apiKeyDraft = it }
                                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Box(
                                        modifier = Modifier
                                            .clip(CircleShape)
                                            .background(Color.White)
                                            .orbPressClickable(enabled = !savingKey && apiKeyDraft.trim().isNotEmpty()) {
                                                saveApiKey(null)
                                            }
                                            .padding(horizontal = 14.dp, vertical = 7.dp)
                                    ) {
                                        Text(
                                            text = if (savingKey) "Saving…" else "Save",
                                            color = Color.Black,
                                            fontSize = 13.sp,
                                            fontWeight = FontWeight.SemiBold
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrbMachinesSettingsPage(
    core: OrbCore,
    onBack: () -> Unit
) {
    val scope = rememberCoroutineScope()
    val cachedNodes by core.nodes.collectAsState()
    val cachedTargets by core.remoteTargets.collectAsState()
    var nodes by remember(cachedNodes) { mutableStateOf(cachedNodes) }
    var sshHosts by remember(cachedTargets) { mutableStateOf(cachedTargets) }
    var expandedNodeIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var isRefreshing by remember { mutableStateOf(false) }
    var showTargetEditor by remember { mutableStateOf(false) }
    var editingTarget by remember { mutableStateOf<OrbRow?>(null) }

    var nameField by remember { mutableStateOf("") }
    var hostField by remember { mutableStateOf("") }
    var portField by remember { mutableStateOf("22") }
    var userField by remember { mutableStateOf("ubuntu") }
    var noteField by remember { mutableStateOf("") }
    var errorBanner by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }

    suspend fun loadMachines() {
        try {
            val remoteObj = core.fetchDict("/api/remote-nodes")
            nodes = OrbJSON.dictList(remoteObj["nodes"]).map { OrbRow(it) }
            errorBanner = null
        } catch (e: Throwable) {
            errorBanner = "Fleet unavailable. ${e.message ?: ""}"
        }
        try {
            sshHosts = core.fetchRows("/api/settings/ssh-hosts", null)
        } catch (_: Throwable) {
        }
    }

    LaunchedEffect(Unit) {
        isRefreshing = true
        loadMachines()
        isRefreshing = false
    }

    fun openEditor(target: OrbRow?) {
        editingTarget = target
        nameField = target?.str("name", "label") ?: ""
        hostField = target?.str("host", "hostname") ?: ""
        portField = (target?.int("port") ?: 22).toString()
        userField = target?.str("user", "username") ?: "ubuntu"
        noteField = target?.str("note") ?: ""
        showTargetEditor = true
    }

    fun saveSshHost(delete: Boolean = false) {
        if (busy) return
        busy = true
        val existing = editingTarget
        val base = "/api/settings/ssh-hosts"
        val id = existing?.id?.takeIf { it.isNotEmpty() }
        val revision = existing?.int("revision") ?: 0
        val path = if (id == null) base else "$base/${core.encodeComponent(id)}"
        scope.launch {
            try {
                if (delete && id != null) {
                    core.request(
                        path = "$path?revision=$revision",
                        method = "DELETE"
                    )
                } else {
                    val body = mapOf(
                        "name" to nameField.trim(),
                        "host" to hostField.trim(),
                        "user" to userField.trim().ifEmpty { "ubuntu" },
                        "port" to (portField.toIntOrNull() ?: 22),
                        "note" to noteField.trim(),
                        "revision" to revision
                    )
                    core.request(
                        path = path,
                        method = if (id == null) "POST" else "PUT",
                        body = body
                    )
                }
                showTargetEditor = false
                editingTarget = null
                loadMachines()
                core.refreshAll()
            } catch (e: Throwable) {
                errorBanner = e.message
            } finally {
                busy = false
            }
        }
    }

    fun toggleCordon(node: OrbRow) {
        if (busy) return
        busy = true
        val nodeId = node.str("id", "name") ?: node.id
        val cordoned = node.bool("cordoned", "paused") == true
        val action = if (cordoned) "uncordon" else "cordon"
        scope.launch {
            try {
                core.request("/api/nodes/${core.encodeComponent(nodeId)}/$action", method = "POST")
                loadMachines()
                core.refreshAll()
            } catch (e: Throwable) {
                errorBanner = e.message
            } finally {
                busy = false
            }
        }
    }

    fun formatBytesGiB(totalBytes: Double?, availBytes: Double?): String {
        if (totalBytes == null || availBytes == null || totalBytes <= 0.0) return "Unavailable"
        val usedGiB = (totalBytes - availBytes) / 1073741824.0
        val totalGiB = totalBytes / 1073741824.0
        return String.format("%.1f / %.1f GiB", usedGiB, totalGiB)
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(OrbStyle.background)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
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
            Text(
                text = "Machines",
                color = Color.White,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center
            )
            Box(
                modifier = Modifier
                    .size(38.dp)
                    .clip(CircleShape)
                    .background(OrbStyle.surface)
                    .border(1.dp, OrbStyle.border, CircleShape)
                    .orbPressClickable {
                        scope.launch {
                            isRefreshing = true
                            loadMachines()
                            core.refreshAll()
                            isRefreshing = false
                        }
                    },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Default.Refresh,
                    contentDescription = "Refresh",
                    tint = Color.White,
                    modifier = Modifier.size(16.dp)
                )
            }
        }

        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = {
                scope.launch {
                    isRefreshing = true
                    loadMachines()
                    core.refreshAll()
                    isRefreshing = false
                }
            },
            modifier = Modifier.fillMaxSize()
        ) {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = 20.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                errorBanner?.let { err ->
                    item { OrbNotice(title = err, log = core.lastErrorLog.value) }
                }

                // Section("Fleet") matching OrbMachinesSettings.swift
                item {
                    Text(
                        text = "FLEET",
                        color = OrbStyle.textMuted,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 0.7.sp
                    )
                }

                if (nodes.isEmpty() && !isRefreshing) {
                    item {
                        Text(
                            text = "No remote nodes registered.",
                            color = OrbStyle.textMuted,
                            fontSize = 14.sp
                        )
                    }
                } else {
                    item {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(16.dp))
                                .background(OrbStyle.surface)
                                .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                        ) {
                            nodes.forEachIndexed { idx, node ->
                                val nodeId = node.str("id", "name") ?: node.id
                                val statusText = node.str("status", "state") ?: "online"
                                val cordoned = node.bool("cordoned", "paused") == true
                                val subtitle = statusText + if (cordoned) " · New jobs paused" else ""
                                val expanded = expandedNodeIds.contains(nodeId)

                                Column(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .orbPressClickable {
                                            expandedNodeIds = if (expanded) expandedNodeIds - nodeId else expandedNodeIds + nodeId
                                        }
                                        .padding(horizontal = 16.dp, vertical = 13.dp),
                                    verticalArrangement = Arrangement.spacedBy(10.dp)
                                ) {
                                    Row(
                                        modifier = Modifier.fillMaxWidth(),
                                        verticalAlignment = Alignment.CenterVertically
                                    ) {
                                        Column(
                                            modifier = Modifier.weight(1f),
                                            verticalArrangement = Arrangement.spacedBy(2.dp)
                                        ) {
                                            Text(
                                                text = nodeId,
                                                color = Color.White,
                                                fontSize = 15.sp,
                                                fontWeight = FontWeight.Medium
                                            )
                                            Text(
                                                text = subtitle,
                                                color = OrbStyle.textSecondary,
                                                fontSize = 12.sp
                                            )
                                        }
                                        Icon(
                                            imageVector = Icons.Default.ChevronRight,
                                            contentDescription = null,
                                            tint = OrbStyle.textMuted,
                                            modifier = Modifier.size(16.dp)
                                        )
                                    }

                                    if (expanded) {
                                        val activeJobs = node.int("active_jobs")?.toString() ?: "Unavailable"
                                        val memStr = formatBytesGiB(
                                            node.double("mem_total_bytes"),
                                            node.double("mem_available_bytes")
                                        )
                                        val diskStr = formatBytesGiB(
                                            node.double("disk_total_bytes"),
                                            node.double("disk_available_bytes")
                                        )
                                        val history = node.rows("resource_history")
                                        val lastSample = history.lastOrNull()
                                        val cpuVal = lastSample?.double("cpu")?.let { "${it.roundToInt()}%" }
                                            ?: node.double("cpu_total")?.let { "${it.roundToInt()} cores" }
                                        val gpuVal = lastSample?.double("gpu")?.let { "${it.roundToInt()}%" }

                                        Column(
                                            modifier = Modifier.fillMaxWidth(),
                                            verticalArrangement = Arrangement.spacedBy(6.dp)
                                        ) {
                                            OrbKeyValueLine("Status", statusText)
                                            OrbKeyValueLine("Active jobs", activeJobs)
                                            OrbKeyValueLine("Memory", memStr)
                                            OrbKeyValueLine("Disk", diskStr)
                                            if (cpuVal != null) {
                                                OrbKeyValueLine("CPU", cpuVal)
                                            }
                                            if (gpuVal != null) {
                                                OrbKeyValueLine("GPU", gpuVal)
                                            }
                                            Spacer(modifier = Modifier.height(4.dp))
                                            Box(
                                                modifier = Modifier
                                                    .clip(CircleShape)
                                                    .background(OrbStyle.card)
                                                    .border(1.dp, OrbStyle.border, CircleShape)
                                                    .orbPressClickable { toggleCordon(node) }
                                                    .padding(horizontal = 12.dp, vertical = 6.dp)
                                            ) {
                                                Text(
                                                    text = if (cordoned) "Allow new jobs" else "Pause new jobs",
                                                    color = OrbStyle.inboxBlue,
                                                    fontSize = 13.sp,
                                                    fontWeight = FontWeight.Medium
                                                )
                                            }
                                        }
                                    }
                                }

                                if (idx < nodes.lastIndex) {
                                    HorizontalDivider(
                                        color = OrbStyle.border,
                                        modifier = Modifier.padding(start = 16.dp)
                                    )
                                }
                            }
                        }
                    }
                }

                // Section("SSH address book") matching OrbMachinesSettings.swift
                item {
                    Text(
                        text = "SSH ADDRESS BOOK",
                        color = OrbStyle.textMuted,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 0.7.sp
                    )
                }

                item {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(16.dp))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                    ) {
                        if (sshHosts.isEmpty()) {
                            Text(
                                text = "No SSH addresses yet.",
                                color = OrbStyle.textMuted,
                                fontSize = 14.sp,
                                modifier = Modifier.padding(16.dp)
                            )
                            HorizontalDivider(color = OrbStyle.border, modifier = Modifier.padding(start = 16.dp))
                        } else {
                            sshHosts.forEach { target ->
                                val name = target.str("name", "label", "id") ?: target.id
                                val host = target.str("host", "hostname") ?: ""
                                val user = target.str("user", "username") ?: "ubuntu"
                                val port = target.int("port") ?: 22
                                val note = target.str("note") ?: ""

                                Column(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .orbPressClickable { openEditor(target) }
                                        .padding(horizontal = 16.dp, vertical = 13.dp),
                                    verticalArrangement = Arrangement.spacedBy(3.dp)
                                ) {
                                    Text(
                                        text = name,
                                        color = Color.White,
                                        fontSize = 15.sp,
                                        fontWeight = FontWeight.Medium
                                    )
                                    Text(
                                        text = "$user@$host:$port",
                                        color = OrbStyle.textSecondary,
                                        fontSize = 12.sp
                                    )
                                    if (note.isNotEmpty()) {
                                        Text(
                                            text = note,
                                            color = OrbStyle.textMuted,
                                            fontSize = 12.sp
                                        )
                                    }
                                }
                                HorizontalDivider(
                                    color = OrbStyle.border,
                                    modifier = Modifier.padding(start = 16.dp)
                                )
                            }
                        }

                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .orbPressClickable { openEditor(null) }
                                .padding(horizontal = 16.dp, vertical = 13.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Default.Add,
                                contentDescription = null,
                                tint = OrbStyle.inboxBlue,
                                modifier = Modifier.size(18.dp)
                            )
                            Text(
                                text = "Add SSH address",
                                color = OrbStyle.inboxBlue,
                                fontSize = 15.sp,
                                fontWeight = FontWeight.Medium
                            )
                        }
                    }
                }

                item {
                    Text(
                        text = "Shared with Orb desktop through this backend. An address does not register an execution node.",
                        color = OrbStyle.textMuted,
                        fontSize = 12.sp
                    )
                }

                if (showTargetEditor) {
                    item {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(16.dp))
                                .background(OrbStyle.surface)
                                .border(1.dp, OrbStyle.borderStrong, RoundedCornerShape(16.dp))
                                .padding(14.dp),
                            verticalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            Text(
                                text = if (editingTarget == null) "Add SSH address" else "SSH address",
                                color = Color.White,
                                fontSize = 15.sp,
                                fontWeight = FontWeight.SemiBold
                            )
                            OrbMiniField("Name", nameField) { nameField = it }
                            OrbMiniField("Host", hostField) { hostField = it }
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Box(modifier = Modifier.weight(1f)) {
                                    OrbMiniField("User", userField) { userField = it }
                                }
                                Box(modifier = Modifier.width(90.dp)) {
                                    OrbMiniField("Port", portField) { portField = it }
                                }
                            }
                            OrbMiniField("Note", noteField) { noteField = it }

                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                Box(
                                    modifier = Modifier
                                        .clip(CircleShape)
                                        .background(OrbStyle.card)
                                        .orbPressClickable { showTargetEditor = false }
                                        .padding(horizontal = 14.dp, vertical = 8.dp)
                                ) {
                                    Text("Cancel", color = OrbStyle.textSecondary, fontSize = 13.sp)
                                }
                                Box(
                                    modifier = Modifier
                                        .clip(CircleShape)
                                        .background(Color.White)
                                        .orbPressClickable(enabled = !busy && nameField.trim().isNotEmpty() && hostField.trim().isNotEmpty()) {
                                            saveSshHost(delete = false)
                                        }
                                        .padding(horizontal = 14.dp, vertical = 8.dp)
                                ) {
                                    Text("Save", color = Color.Black, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                                }
                                if (editingTarget != null) {
                                    Box(
                                        modifier = Modifier
                                            .clip(CircleShape)
                                            .background(OrbStyle.card)
                                            .orbPressClickable(enabled = !busy) {
                                                saveSshHost(delete = true)
                                            }
                                            .padding(horizontal = 14.dp, vertical = 8.dp)
                                    ) {
                                        Text("Delete", color = OrbStyle.error, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun OrbKeyValueLine(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(text = label, color = Color.White, fontSize = 13.sp)
        Text(text = value, color = OrbStyle.textSecondary, fontSize = 13.sp)
    }
}

@Composable
private fun OrbMiniField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(text = label, color = OrbStyle.textMuted, fontSize = 11.sp, fontWeight = FontWeight.Medium)
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(OrbStyle.card)
                .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp))
                .padding(horizontal = 10.dp, vertical = 9.dp)
        ) {
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                textStyle = TextStyle(color = Color.White, fontSize = 13.sp),
                cursorBrush = SolidColor(Color.White),
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}
