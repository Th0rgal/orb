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

internal fun providerQuotaWindows(detail: OrbDict?): List<Pair<String, Double>> {
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
    add("5h", "muse_5h_used_percent")
    add("Weekly", "muse_weekly_used_percent")
    add("Monthly", "mistral_monthly_used_percent")
    for (w in OrbJSON.dictList(detail["antigravity_windows"])) {
        val pct = OrbJSON.double(w, "used_percent") ?: continue
        if (pct.isFinite()) result.add((OrbJSON.str(w, "label") ?: "Window") to (pct / 100.0).coerceIn(0.0, 1.0))
    }
    return result
}

internal fun providerStatusSubtitle(provider: OrbRow, detail: OrbDict?): String {
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

    var showConnectSubscriptionMenu by remember { mutableStateOf(false) }
    var oauthProviderType by remember { mutableStateOf<String?>(null) }
    var oauthReauthProvider by remember { mutableStateOf<OrbRow?>(null) }
    var oauthAuthUrl by remember { mutableStateOf<String?>(null) }
    var oauthUserCode by remember { mutableStateOf<String?>(null) }
    var oauthVerificationUri by remember { mutableStateOf<String?>(null) }
    var oauthCallbackInput by remember { mutableStateOf("") }
    var oauthStatusMessage by remember { mutableStateOf<String?>(null) }
    var oauthLoading by remember { mutableStateOf(false) }
    var oauthSessionId by remember { mutableStateOf<String?>(null) }
    var oauthUsesProxy by remember { mutableStateOf(false) }

    val oauthPresets = remember {
        listOf(
            "anthropic" to "Anthropic (Claude Max / Pro)",
            "openai" to "OpenAI (ChatGPT Plus / Pro)",
            "google" to "Google (Gemini / Antigravity)",
            "xai" to "xAI (Grok)",
            "kimi" to "Kimi"
        )
    }

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
                val detail = orbTry(OrbLog.Category.Network, "/api/ai/providers") {
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

    // Mirrors iOS OrbProviderLoginView / Orb Providers.tsx: subscriptions other than
    // Google sign in through the CLIProxyAPI session flow; Google (and providers owned
    // by sandboxed.sh) use the native flow, where the server accepts the provider type
    // in place of a provider UUID.
    fun usesCliProxyLogin(providerType: String, existingProvider: OrbRow?): Boolean {
        if (providerType == "google") return false
        if (existingProvider == null) return true
        val owner = existingProvider.str("credential_owner") ?: ""
        return owner == "cli_proxy" || (owner.isEmpty() && providerType in OrbProviderLoginFlow.subscriptionTypes)
    }

    fun finishOauth(pType: String) {
        oauthProviderType = null
        oauthReauthProvider = null
        oauthSessionId = null
        statusBanner = "Connected $pType"
        scope.launch {
            loadProvidersAndUsage()
            core.refreshAll()
        }
    }

    fun applyProxyState(pType: String, dict: OrbDict?) {
        when (OrbJSON.str(dict, "status")) {
            "completed" -> finishOauth(pType)
            "failed" -> {
                oauthSessionId = null
                oauthStatusMessage = OrbJSON.str(dict, "message") ?: "Sign-in failed. Close and try again."
            }
            else -> OrbJSON.str(dict, "auth_url")?.let { oauthAuthUrl = it }
        }
    }

    fun cancelOauthFlow() {
        oauthSessionId?.let { sid ->
            scope.launch {
                orbTry(OrbLog.Category.Network, "/api/ai/providers/cli-proxy-login") {
                    core.request("/api/ai/providers/cli-proxy-login/${core.encodeComponent(sid)}", method = "DELETE")
                }
            }
        }
        oauthSessionId = null
        oauthProviderType = null
        oauthReauthProvider = null
    }

    fun startOauthFlow(providerType: String, existingProvider: OrbRow? = null) {
        oauthSessionId?.let { cancelOauthFlow() }
        oauthProviderType = providerType
        oauthReauthProvider = existingProvider
        oauthAuthUrl = null
        oauthUserCode = null
        oauthVerificationUri = null
        oauthCallbackInput = ""
        oauthStatusMessage = "Starting authentication…"
        oauthLoading = true
        val proxy = usesCliProxyLogin(providerType, existingProvider)
        oauthUsesProxy = proxy
        scope.launch {
            try {
                val resp = if (proxy) {
                    val body = mutableMapOf<String, Any?>("provider" to providerType)
                    existingProvider?.id?.let { body["provider_id"] = it }
                    val path = if (providerType == "mistral") "/api/ai/providers/mistral-login" else "/api/ai/providers/cli-proxy-login"
                    core.request(path = path, method = "POST", body = body)
                } else {
                    val idOrType = existingProvider?.id ?: providerType
                    core.request(
                        path = "/api/ai/providers/${core.encodeComponent(idOrType)}/oauth/authorize",
                        method = "POST",
                        body = mapOf("method_index" to 0)
                    )
                }
                val dict = OrbJSON.dict(resp)
                if (proxy) oauthSessionId = OrbJSON.str(dict, "session_id")
                val url = OrbJSON.str(dict, "auth_url", "url", "authorize_url")
                oauthAuthUrl = url
                oauthUserCode = OrbJSON.str(dict, "user_code")
                oauthVerificationUri = OrbJSON.str(dict, "verification_uri", "verification_uri_complete")
                oauthStatusMessage = OrbJSON.str(dict, "instructions", "message")
                    ?: "Open the sign-in page in your browser, then paste the callback URL or code if prompted."
                val targetOpenUrl = url ?: oauthVerificationUri
                if (!targetOpenUrl.isNullOrEmpty()) {
                    runCatching {
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(targetOpenUrl)))
                    }
                }
            } catch (e: Throwable) {
                oauthStatusMessage = e.message ?: "Failed to start OAuth flow"
            } finally {
                oauthLoading = false
            }
        }
    }

    // Poll the CLIProxyAPI login session every 2 s, like iOS and Orb.
    LaunchedEffect(oauthSessionId) {
        val sid = oauthSessionId ?: return@LaunchedEffect
        val pType = oauthProviderType ?: return@LaunchedEffect
        while (isActive && oauthSessionId == sid) {
            delay(2000)
            val state = orbTry(OrbLog.Category.Network, "/api/ai/providers/cli-proxy-login") {
                OrbJSON.dict(core.request("/api/ai/providers/cli-proxy-login/${core.encodeComponent(sid)}"))
            }.getOrNull() ?: continue
            if (oauthSessionId == sid) applyProxyState(pType, state)
        }
    }

    fun completeOauthCallback() {
        val pType = oauthProviderType ?: return
        val existing = oauthReauthProvider
        val trimmed = oauthCallbackInput.trim()
        val sid = oauthSessionId
        if (trimmed.isEmpty() && pType != "kimi") return
        oauthLoading = true
        scope.launch {
            try {
                if (oauthUsesProxy) {
                    if (sid == null) throw OrbError("The sign-in session expired. Start again.")
                    val state = core.request(
                        path = "/api/ai/providers/cli-proxy-login/${core.encodeComponent(sid)}/callback",
                        method = "POST",
                        body = mapOf("url" to trimmed)
                    )
                    applyProxyState(pType, OrbJSON.dict(state))
                } else {
                    val idOrType = existing?.id ?: pType
                    val body = mutableMapOf<String, Any?>("method_index" to 0)
                    if (trimmed.isNotEmpty()) body["code"] = trimmed
                    core.request(
                        path = "/api/ai/providers/${core.encodeComponent(idOrType)}/oauth/callback",
                        method = "POST",
                        body = body
                    )
                    finishOauth(pType)
                }
            } catch (e: Throwable) {
                oauthStatusMessage = e.message ?: "Callback failed"
            } finally {
                oauthLoading = false
            }
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
                    item { OrbNotice(title = err, log = core.lastErrorLog.collectAsState().value) }
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
                                val providerType = provider.str("provider_type", "type") ?: ""
                                val detail = usageEntries[pid]
                                val subtitle = providerStatusSubtitle(provider, detail)
                                val expanded = expandedIds.contains(pid)
                                val windows = providerQuotaWindows(detail)
                                val usesOauth = provider.bool("uses_oauth") == true
                                val canEditKey = provider.bool("has_api_key") == true || !usesOauth
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
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                                    ) {
                                        OrbProviderLogo(
                                            type = providerType,
                                            name = name,
                                            size = 18.dp
                                        )
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
                                                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                                                            verticalAlignment = Alignment.CenterVertically
                                                        ) {
                                                            Text(
                                                                text = wLabel,
                                                                color = Color.White,
                                                                fontSize = 13.sp,
                                                                maxLines = 1,
                                                                overflow = TextOverflow.Ellipsis,
                                                                modifier = Modifier.weight(1f)
                                                            )
                                                            Text(
                                                                text = "$pctInt% used",
                                                                color = OrbStyle.textSecondary,
                                                                fontSize = 13.sp,
                                                                maxLines = 1,
                                                                softWrap = false
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
                                                if (usesOauth) {
                                                    Box(
                                                        modifier = Modifier
                                                            .clip(CircleShape)
                                                            .background(OrbStyle.card)
                                                            .border(1.dp, OrbStyle.border, CircleShape)
                                                            .orbPressClickable {
                                                                startOauthFlow(providerType.ifEmpty { "openai" }, provider)
                                                            }
                                                            .padding(horizontal = 12.dp, vertical = 6.dp)
                                                    ) {
                                                        Text(
                                                            text = "Reconnect",
                                                            color = Color.White,
                                                            fontSize = 12.sp,
                                                            fontWeight = FontWeight.Medium,
                                                            maxLines = 1,
                                                            softWrap = false
                                                        )
                                                    }
                                                }
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
                                                            fontWeight = FontWeight.Medium,
                                                            maxLines = 1,
                                                            softWrap = false
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
                                                        fontWeight = FontWeight.Medium,
                                                        maxLines = 1,
                                                        softWrap = false
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
                                                        maxLines = 1,
                                                        softWrap = false,
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
                                        modifier = Modifier.padding(start = 58.dp)
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
                                val cloudProvider = account.str("provider") ?: ""
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
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                                    ) {
                                        OrbProviderLogo(
                                            type = cloudProvider,
                                            name = label,
                                            size = 18.dp
                                        )
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
                                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                                    verticalAlignment = Alignment.CenterVertically
                                                ) {
                                                    Text(
                                                        text = wLabel,
                                                        color = Color.White,
                                                        fontSize = 12.sp,
                                                        maxLines = 1,
                                                        overflow = TextOverflow.Ellipsis,
                                                        modifier = Modifier.weight(1f)
                                                    )
                                                    Text(
                                                        text = "${pct.roundToInt()}% used",
                                                        color = OrbStyle.textSecondary,
                                                        fontSize = 12.sp,
                                                        maxLines = 1,
                                                        softWrap = false
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
                                    modifier = Modifier.padding(start = 58.dp)
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

                // Bottom action section ("Connect subscription", "Add API key")
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
                                    showConnectSubscriptionMenu = !showConnectSubscriptionMenu
                                }
                                .padding(horizontal = 16.dp, vertical = 13.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Default.Person,
                                contentDescription = null,
                                tint = OrbStyle.inboxBlue,
                                modifier = Modifier.size(18.dp)
                            )
                            Text(
                                text = "Connect subscription",
                                color = OrbStyle.inboxBlue,
                                fontSize = 15.sp,
                                fontWeight = FontWeight.Medium
                            )
                        }

                        if (showConnectSubscriptionMenu) {
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 16.dp, vertical = 8.dp),
                                verticalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                oauthPresets.forEach { (pType, pTitle) ->
                                    Row(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .clip(RoundedCornerShape(10.dp))
                                            .background(OrbStyle.card)
                                            .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp))
                                            .orbPressClickable {
                                                showConnectSubscriptionMenu = false
                                                startOauthFlow(pType, null)
                                            }
                                            .padding(horizontal = 12.dp, vertical = 10.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                                    ) {
                                        OrbProviderLogo(type = pType, name = pTitle, size = 16.dp)
                                        Text(
                                            text = pTitle,
                                            color = Color.White,
                                            fontSize = 14.sp,
                                            fontWeight = FontWeight.Medium,
                                            modifier = Modifier.weight(1f)
                                        )
                                        Icon(
                                            imageVector = Icons.Default.ChevronRight,
                                            contentDescription = null,
                                            tint = OrbStyle.textMuted,
                                            modifier = Modifier.size(15.dp)
                                        )
                                    }
                                }
                            }
                        }

                        if (oauthProviderType != null) {
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 16.dp, vertical = 10.dp),
                                verticalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Text(
                                    text = "Connect ${oauthProviderType?.uppercase()}",
                                    color = Color.White,
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.SemiBold
                                )
                                oauthStatusMessage?.let { msg ->
                                    Text(text = msg, color = OrbStyle.textSecondary, fontSize = 12.sp)
                                }
                                oauthUserCode?.takeIf { it.isNotEmpty() }?.let { code ->
                                    Text(
                                        text = "Code: $code",
                                        color = Color.White,
                                        fontSize = 14.sp,
                                        fontFamily = FontFamily.Monospace,
                                        fontWeight = FontWeight.Bold
                                    )
                                }
                                val openUrl = oauthAuthUrl ?: oauthVerificationUri
                                if (!openUrl.isNullOrEmpty()) {
                                    Box(
                                        modifier = Modifier
                                            .clip(CircleShape)
                                            .background(OrbStyle.card)
                                            .border(1.dp, OrbStyle.border, CircleShape)
                                            .orbPressClickable {
                                                runCatching {
                                                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(openUrl)))
                                                }
                                            }
                                            .padding(horizontal = 12.dp, vertical = 6.dp)
                                    ) {
                                        Text("Open sign-in page in browser", color = OrbStyle.inboxBlue, fontSize = 12.sp)
                                    }
                                }
                                OrbMiniField("Paste callback URL or authorization code", oauthCallbackInput) {
                                    oauthCallbackInput = it
                                }
                                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Box(
                                        modifier = Modifier
                                            .clip(CircleShape)
                                            .background(Color.White)
                                            .orbPressClickable(enabled = !oauthLoading && (oauthCallbackInput.trim().isNotEmpty() || oauthProviderType == "kimi")) {
                                                completeOauthCallback()
                                            }
                                            .padding(horizontal = 14.dp, vertical = 7.dp)
                                    ) {
                                        Text(
                                            text = if (oauthLoading) "Connecting…" else "Complete sign-in",
                                            color = Color.Black,
                                            fontSize = 13.sp,
                                            fontWeight = FontWeight.SemiBold
                                        )
                                    }
                                    Box(
                                        modifier = Modifier
                                            .clip(CircleShape)
                                            .background(OrbStyle.card)
                                            .border(1.dp, OrbStyle.border, CircleShape)
                                            .orbPressClickable { cancelOauthFlow() }
                                            .padding(horizontal = 14.dp, vertical = 7.dp)
                                    ) {
                                        Text("Cancel", color = OrbStyle.textSecondary, fontSize = 13.sp)
                                    }
                                }
                            }
                        }

                        HorizontalDivider(color = OrbStyle.border, modifier = Modifier.padding(start = 16.dp))

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
                                            fontWeight = FontWeight.SemiBold,
                                            maxLines = 1,
                                            softWrap = false
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


object OrbProviderLoginFlow {
    /** Subscription types offered by iOS `OrbProvidersSettingsView.subscriptionTypes`. */
    val subscriptionTypes = setOf("anthropic", "openai", "google", "xai", "kimi")
}
