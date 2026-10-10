package sh.sandboxed.dashboard.orb

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Reply
import androidx.compose.material.icons.filled.ArrowForward
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CheckCircleOutline
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.time.Instant
import java.util.UUID

data class OrbInboxModelPreset(
    val id: String,
    val label: String,
    val subtitle: String
)

object OrbSharedInboxState {
    private var mutation = 0
    private var pending = 0
    private var tail: kotlinx.coroutines.Job? = null
    private var scope = ""
    private val outbox = mutableMapOf<String, Any>()
    private val seen = mutableMapOf<String, Long>()
    var applying = false
    private fun account() = inboxAccountScope(OrbCore.shared.baseURL, OrbCore.shared.token)
    private var persistence: SharedPreferences? = null
    fun init(context: Context) { persistence = context.applicationContext.getSharedPreferences("orb_inbox_outbox", Context.MODE_PRIVATE) }
    private fun diskKey() = java.security.MessageDigest.getInstance("SHA-256").digest(scope.toByteArray()).joinToString("") { "%02x".format(it) }
    private fun persistOutbox() { persistence?.edit()?.putString(diskKey(), OrbJSON.stringify(outbox))?.commit() }
    private fun ensureScope() {
        val current = account()
        if (scope == current) return
        scope = current; seen.clear(); outbox.clear()
        OrbInboxSettings.bindAccount(current)
        OrbJSON.dict(OrbJSON.parse(persistence?.getString(diskKey(), null) ?: "{}"))?.forEach { (path, body) -> if (body != null) outbox[path] = body }
        for ((path, body) in outbox) if (path.startsWith("seen/")) {
            val stamp = (body as? Map<*, *>)?.get("stamp") as? Number
            if (stamp != null) seen[java.net.URLDecoder.decode(path.removePrefix("seen/"), "UTF-8")] = stamp.toLong()
        }
    }
    fun write(path: String, input: Any) {
        if (applying) return
        val body = if (input is Map<*, *> && !input.containsKey("mutationAt")) input + ("mutationAt" to System.currentTimeMillis()) else input
        val core = OrbCore.shared
        val expected = account()
        ensureScope()
        outbox[path] = body
        persistOutbox()
        mutation++; pending++
        val previous = tail
        tail = core.scope.launch {
            previous?.join()
            if (expected == account()) runCatching {
                core.request("/api/control/inbox-state/$path", method = "PUT", body = body)
                if (expected == account() && outbox[path] == body) { outbox.remove(path); persistOutbox() }
            }.onFailure { error ->
                if ((error as? OrbError)?.status == 404 && path.startsWith("seen/") && expected == account() && outbox[path] == body) { outbox.remove(path); persistOutbox() }
            }
            pending--
        }
    }
    fun writeSeen(id: String, stamp: Long) {
        ensureScope()
        seen[id] = stamp
        write("seen/" + OrbCore.shared.encodeComponent(id), mapOf("stamp" to stamp))
    }
    fun writePreferences() {
        if (applying) return
        OrbInboxSettings.bindAccount(account())
        write("preferences", mapOf("aiSummary" to OrbInboxSettings.aiSummary, "includeAutonomous" to OrbInboxSettings.includeAutonomous, "model" to OrbInboxSettings.model))
    }
    fun unread(mission: OrbRow): Boolean? {
        ensureScope()
        if (scope != account()) return null
        val stamp = seen[mission.id] ?: return null
        val turn = runCatching { Instant.parse(mission.str("updated_at", "created_at") ?: "").toEpochMilli() }.getOrDefault(0)
        return if (stamp < 0) { if (turn <= kotlin.math.abs(stamp) + 2000) true else null } else { if (turn <= stamp + 2000) false else null }
    }
    suspend fun refresh() {
        if (pending > 0) return
        ensureScope()
        if (outbox.isNotEmpty()) { for ((path, body) in outbox.toMap()) write(path, body); return }
        val expected = account(); val serial = mutation
        val raw = runCatching { OrbCore.shared.request("/api/control/inbox-state") as? Map<*, *> }.getOrNull() ?: return
        if (expected != account() || serial != mutation) return
        val changedAccount = scope != expected
        if (changedAccount) { scope = expected; seen.clear() }
        for ((key, value) in raw) if (key is String && key.startsWith("seen:") && value is Number) seen[key.removePrefix("seen:")] = value.toLong()
        val prefs = raw["preferences"] as? Map<*, *>
        OrbInboxSettings.bindAccount(expected)
        applying = true
        if (prefs != null && prefs["model"] is String) OrbInboxSettings.update(newAiSummary = prefs["aiSummary"] == true, newIncludeAutonomous = prefs["includeAutonomous"] == true, newModel = prefs["model"] as String)
        applying = false
        // Missing Core preferences seed from the existing device settings.
        if (prefs?.get("model") !is String) writePreferences()
        OrbMissionUnreadStore.sharedStateChanged()
    }
}

object OrbInboxSettings {
    private const val PREFS_KEY = "orb.inbox.settings.v1"
    private const val KEY_AI_SUMMARY = "ai_summary"
    private const val KEY_MODEL = "model"
    var includeAutonomous by mutableStateOf(false)
        private set

    const val DEFAULT_MODEL = "builtin/smart"

    val modelPresets: List<OrbInboxModelPreset> = listOf(
        OrbInboxModelPreset("builtin/smart", "Smart Router (builtin/smart)", "Default router for crisp 2-3 sentence AI Overviews"),
        OrbInboxModelPreset("builtin/fast", "Fast Router (builtin/fast)", "Lowest latency router"),
        OrbInboxModelPreset("builtin/reasoning", "Reasoning Router (builtin/reasoning)", "Deeper technical synthesis")
    )

    private var prefs: SharedPreferences? = null
    private var owner: String? = null
    fun bindAccount(account: String) {
        if (owner == account) return
        val previous = OrbSharedInboxState.applying
        OrbSharedInboxState.applying = true
        if (owner != null) update(newAiSummary = true, newIncludeAutonomous = false, newModel = DEFAULT_MODEL)
        owner = account
        prefs?.edit()?.putString("preferences_owner", account)?.commit()
        OrbSharedInboxState.applying = previous
    }
    var aiSummary by mutableStateOf(true)
        private set
    var model by mutableStateOf(DEFAULT_MODEL)
        private set
    var revision by mutableIntStateOf(0)
        private set

    fun init(context: Context) {
        if (prefs == null) {
            val p = context.applicationContext.getSharedPreferences(PREFS_KEY, Context.MODE_PRIVATE)
            prefs = p
            owner = p.getString("preferences_owner", null)
            aiSummary = p.getBoolean(KEY_AI_SUMMARY, true)
            includeAutonomous = p.getBoolean("include_autonomous", false)
            model = p.getString(KEY_MODEL, DEFAULT_MODEL)?.trim()?.takeIf { it.isNotEmpty() } ?: DEFAULT_MODEL
        }
    }

    fun update(newAiSummary: Boolean = aiSummary, newModel: String = model, newIncludeAutonomous: Boolean = includeAutonomous) {
        val cleanModel = newModel.trim().ifEmpty { DEFAULT_MODEL }
        aiSummary = newAiSummary
        includeAutonomous = newIncludeAutonomous
        model = cleanModel
        revision += 1
        OrbSharedInboxState.writePreferences()
        prefs?.edit()
            ?.putBoolean(KEY_AI_SUMMARY, newAiSummary)
            ?.putBoolean("include_autonomous", newIncludeAutonomous)
            ?.putString(KEY_MODEL, cleanModel)
            ?.apply()
    }
}

data class OrbInboxDigest(
    val task: String,
    val outcome: String,
    val verdict: String,
    val model: String,
    val updatedAt: String,
    val context: String = "",
    val contextDetails: String = "",
    val unresolved: String = "",
    val decision: String = "",
    val suggestions: List<String> = emptyList(),
    val sources: List<String> = emptyList(),
    val sourceUpdatedAt: String = "",
    val sourceRevision: String = ""
)

object OrbInboxDigestStore {
    private const val PREFS_KEY = "orb.inbox.digests.v7"
    private const val MAX_CONCURRENT = 3
    private var prefs: SharedPreferences? = null
    private val cache = mutableStateMapOf<String, OrbInboxDigest>()
    private val inFlight = mutableSetOf<String>()
    private val failedAtMs = mutableMapOf<String, Long>()
    private val queueMutex = Mutex()
    private var activeCount = 0
    private val queue = mutableListOf<Pair<Int, suspend () -> Unit>>()
    var revision by mutableIntStateOf(0)
        private set

    fun init(context: Context) {
        if (prefs == null) {
            val p = context.applicationContext.getSharedPreferences(PREFS_KEY, Context.MODE_PRIVATE)
            prefs = p
            for ((k, v) in p.all) {
                val raw = v as? String ?: continue
                val dict = OrbJSON.dict(OrbJSON.parse(raw)) ?: continue
                parseDigest(raw, OrbJSON.str(dict, "updatedAt") ?: "", OrbJSON.str(dict, "model") ?: OrbInboxSettings.DEFAULT_MODEL)?.let { cache[k] = it }
            }
        }
    }

    private fun accountScope(): String = java.security.MessageDigest.getInstance("SHA-256").digest(inboxAccountScope(OrbCore.shared.baseURL, OrbCore.shared.token).toByteArray()).joinToString("") { "%02x".format(it) }
    private fun cacheKey(missionId: String, updatedAt: String, model: String): String =
        "${accountScope()}|$missionId|$updatedAt|$model"

    fun get(mission: OrbRow): OrbInboxDigest? {
        val _rev = revision
        if (!OrbInboxSettings.aiSummary) return null
        val updated = mission.str("updated_at", "completed_at", "started_at", "created_at") ?: ""
        val model = OrbInboxSettings.model
        cache[cacheKey(mission.id, updated, model)]?.let { return it }
        val prefix = "${accountScope()}|${mission.id}|"
        return cache.entries.filter { it.key.startsWith(prefix) && it.key.endsWith("|$model") }.maxByOrNull { it.value.updatedAt }?.value
    }

    fun request(core: OrbCore, mission: OrbRow, events: List<OrbRow>, priority: Int = 10) {
        if (!OrbInboxSettings.aiSummary || !core.isConfigured) return
        val status = (mission.str("status", "state") ?: "").lowercase()
        if (status in setOf("active", "running", "starting", "pending", "queued", "resuming", "waiting_background")) {
            return
        }
        val updated = mission.str("updated_at", "completed_at", "started_at", "created_at") ?: ""
        val model = OrbInboxSettings.model
        val key = cacheKey(mission.id, updated, model)
        if (cache.containsKey(key) || inFlight.contains(key)) return
        val lastFail = failedAtMs[key]
        if (lastFail != null && System.currentTimeMillis() - lastFail < 45_000L) return

        val endpoint = core.baseURL
        val account = inboxAccountScope(core.baseURL, core.token)

        inFlight.add(key)
        revision += 1
        core.scope.launch {
            enqueue(priority) {
                try {
                    if (core.baseURL != endpoint || inboxAccountScope(core.baseURL, core.token) != account) return@enqueue
                    val answer = fetchShared(core, mission.id, model)
                    if (core.baseURL != endpoint || inboxAccountScope(core.baseURL, core.token) != account) return@enqueue
                    val parsed = parseDigest(answer, updated, model)
                    if (parsed != null) {
                        failedAtMs.remove(key)
                        cache[key] = parsed
                        revision += 1
                        val persisted = OrbJSON.dict(OrbJSON.parse(answer))?.toMutableMap() ?: mutableMapOf()
                        persisted["updatedAt"] = updated
                        prefs?.edit()?.putString(key, OrbJSON.stringify(persisted))?.apply()
                    } else {
                        failedAtMs[key] = System.currentTimeMillis()
                    }
                } catch (_: Throwable) {
                    failedAtMs[key] = System.currentTimeMillis()
                } finally {
                    inFlight.remove(key)
                    revision += 1
                }
            }
        }
    }

    private suspend fun enqueue(priority: Int, block: suspend () -> Unit) {
        queueMutex.withLock {
            queue.add(priority to block)
            queue.sortBy { it.first }
        }
        pump()
    }

    private fun pump() {
        val core = runCatching { OrbCore.shared }.getOrNull() ?: return
        core.scope.launch {
            val next: (suspend () -> Unit)? = queueMutex.withLock {
                if (activeCount >= MAX_CONCURRENT || queue.isEmpty()) {
                    null
                } else {
                    activeCount += 1
                    queue.removeAt(0).second
                }
            }
            if (next != null) {
                try {
                    next()
                } finally {
                    queueMutex.withLock { activeCount -= 1 }
                    pump()
                }
            }
        }
    }

    fun summaryState(mission: OrbRow): String? {
        if (!OrbInboxSettings.aiSummary) return null
        val updated = mission.str("updated_at", "completed_at", "started_at", "created_at") ?: ""
        val key = cacheKey(mission.id, updated, OrbInboxSettings.model)
        return when { inFlight.contains(key) -> "Generating summary…"; failedAtMs.containsKey(key) -> "Summary unavailable"; else -> null }
    }

    private suspend fun fetchShared(core: OrbCore, missionId: String, model: String): String = withContext(Dispatchers.IO) {
        val request = Request.Builder().url(core.makeURL("/api/control/missions/${core.encodeComponent(missionId)}/inbox-digest"))
            .post(OrbJSON.stringify(mapOf("model" to model)).toRequestBody("application/json; charset=utf-8".toMediaType()))
            .header("Authorization", "Bearer ${core.token ?: ""}").build()
        core.httpClient.newBuilder().callTimeout(100, java.util.concurrent.TimeUnit.SECONDS).readTimeout(100, java.util.concurrent.TimeUnit.SECONDS).build().newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw java.io.IOException("Inbox summary HTTP ${response.code}")
            response.body?.string() ?: throw java.io.IOException("Empty Inbox summary")
        }
    }

    private fun parseDigest(raw: String, updatedAt: String, model: String): OrbInboxDigest? {
        val trimmed = raw.trim()
        val start = trimmed.indexOf('{')
        val end = trimmed.lastIndexOf('}')
        if (start < 0 || end <= start) return null
        val dict = OrbJSON.dict(OrbJSON.parse(trimmed.substring(start, end + 1))) ?: return null
        if ((dict["schemaVersion"] as? Number)?.toInt() != 7) return null
        val outcome = OrbJSON.str(dict, "outcome") ?: return null
        val sources = (dict["sources"] as? List<*>)?.mapNotNull { OrbJSON.dict(it)?.let { source -> OrbJSON.str(source, "quote") } } ?: emptyList()
        val sourceRevision = OrbJSON.str(dict, "sourceRevision") ?: ""
        if (outcome.isEmpty() || sources.isEmpty() || sourceRevision.isEmpty()) return null
        val sourceTime = runCatching { Instant.parse(OrbJSON.str(dict, "sourceUpdatedAt") ?: "").toEpochMilli() }.getOrNull() ?: return null
        val clientTime = runCatching { Instant.parse(updatedAt).toEpochMilli() }.getOrDefault(0)
        if (sourceTime + 2000 < clientTime) return null
        return OrbInboxDigest(task = "", outcome = outcome, verdict = "waiting", model = OrbJSON.str(dict, "model") ?: model, updatedAt = updatedAt,
            context = OrbJSON.str(dict, "context") ?: "", contextDetails = OrbJSON.str(dict, "contextDetails") ?: "",
            unresolved = OrbJSON.str(dict, "unresolved") ?: "", decision = OrbJSON.str(dict, "decision") ?: "",
            suggestions = OrbJSON.strList(dict, "suggestions"), sources = sources, sourceUpdatedAt = OrbJSON.str(dict, "sourceUpdatedAt") ?: "", sourceRevision = sourceRevision)

    }
}

object OrbMissionUnreadStore {
    private const val PREFS_KEY = "orb.missionSeenAt.v2"
    private var prefs: SharedPreferences? = null
    private val seenMap = mutableStateMapOf<String, String>()
    private val manuallyUnreadIds = mutableSetOf<String>()
    var revision by mutableIntStateOf(0)
        private set

    private val unreadResponseStates = setOf(
        "awaiting_user", "waiting_user", "completed", "succeeded",
        "failed", "blocked", "not_feasible", "paused", "interrupted"
    )

    fun init(context: Context) {
        if (prefs == null) {
            val p = context.applicationContext.getSharedPreferences(PREFS_KEY, Context.MODE_PRIVATE)
            prefs = p
            for ((k, v) in p.all) {
                if (v is String) {
                    seenMap[k] = v
                }
            }
        }
    }

    fun sharedStateChanged() { revision += 1 }

    fun isUnread(mission: OrbRow, hasInteraction: Boolean = false): Boolean {
        val _rev = revision
        val state = (mission.str("status", "state") ?: "").lowercase()
        if (!hasInteraction && state !in unreadResponseStates) return false
        OrbSharedInboxState.unread(mission)?.let { return it }
        if (manuallyUnreadIds.contains(mission.id)) return true
        val updated = mission.str("updated_at", "completed_at", "started_at", "created_at") ?: ""
        val firstViewed = mission.str("first_viewed_at") ?: ""
        if (firstViewed.isNotEmpty()) {
            if (updated.isEmpty() || firstViewed >= updated) return false
        }
        val seen = seenMap[mission.id]
        if (seen != null) {
            if (updated.isEmpty() || seen >= updated) return false
        }
        return true
    }

    fun markSeen(mission: OrbRow, syncBackend: Boolean = true) {
        val updated = mission.str("updated_at", "completed_at", "started_at", "created_at") ?: ""
        val nowIso = Instant.now().toString()
        val stamp = maxOf(updated, nowIso)
        manuallyUnreadIds.remove(mission.id)
        if (seenMap[mission.id] != stamp) {
            seenMap[mission.id] = stamp
            revision += 1
            prefs?.edit()?.putString(mission.id, stamp)?.apply()
        }
        if (syncBackend) {
            OrbSharedInboxState.writeSeen(mission.id, maxOf(System.currentTimeMillis(), runCatching { Instant.parse(updated).toEpochMilli() }.getOrDefault(0)))
            runCatching {
                val core = OrbCore.shared
                core.scope.launch {
                    runCatching {
                        core.request("/api/control/missions/${core.encodeComponent(mission.id)}/opened", method = "POST")
                    }
                }
            }
        }
    }

    fun markSeen(missionId: String, missions: List<OrbRow>) {
        val row = missions.firstOrNull { it.id == missionId } ?: return
        markSeen(row)
    }

    fun toggleUnread(mission: OrbRow) {
        if (isUnread(mission)) {
            markSeen(mission)
        } else {
            OrbSharedInboxState.writeSeen(mission.id, -maxOf(System.currentTimeMillis(), runCatching { Instant.parse(mission.str("updated_at") ?: "").toEpochMilli() }.getOrDefault(0)))
            revision += 1
        }
    }

    fun markAllSeen(missions: List<OrbRow>) {
        val editor = prefs?.edit()
        val nowIso = Instant.now().toString()
        var changed = false
        val core = runCatching { OrbCore.shared }.getOrNull()
        for (m in missions) {
            manuallyUnreadIds.remove(m.id)
            val updated = m.str("updated_at", "completed_at", "started_at", "created_at") ?: ""
            val stamp = maxOf(updated, nowIso)
            if (seenMap[m.id] != stamp) {
                seenMap[m.id] = stamp
                editor?.putString(m.id, stamp)
                changed = true
            }
            if (core != null) {
                OrbSharedInboxState.writeSeen(m.id, maxOf(System.currentTimeMillis(), runCatching { Instant.parse(updated).toEpochMilli() }.getOrDefault(0)))
                val id = m.id
                core.scope.launch {
                    runCatching {
                        core.request("/api/control/missions/${core.encodeComponent(id)}/opened", method = "POST")
                    }
                }
            }
        }
        if (changed) {
            revision += 1
            editor?.apply()
        }
    }
}

enum class OrbInboxKind {
    NeedsInput,
    Finished
}

enum class OrbInboxTone {
    Amber,
    Red,
    Blue,
    Green,
    Muted;

    val foreground: Color
        get() = when (this) {
            Amber -> OrbStyle.warning
            Red -> OrbStyle.error
            Blue -> OrbStyle.inboxBlue
            Green -> OrbStyle.success
            Muted -> OrbStyle.textSecondary
        }

    val background: Color
        get() = when (this) {
            Amber -> OrbStyle.warning.copy(alpha = 0.14f)
            Red -> OrbStyle.error.copy(alpha = 0.14f)
            Blue -> OrbStyle.inboxBlue.copy(alpha = 0.14f)
            Green -> OrbStyle.success.copy(alpha = 0.14f)
            Muted -> Color.White.copy(alpha = 0.06f)
        }
}

data class OrbInboxChildFailure(
    val id: String,
    val title: String,
    val row: OrbRow
)

data class OrbInboxPeekTurn(
    val id: String,
    val role: String,
    val text: String,
    val workReceipt: String? = null
)

data class OrbInboxInteractionOption(
    val label: String,
    val isPrimary: Boolean,
    val payload: OrbDict
)

data class OrbInboxPendingInteraction(
    val callId: String,
    val toolName: String,
    val kind: String,
    val prompt: String,
    val commandPreview: String?,
    val options: List<OrbInboxInteractionOption>
)

data class OrbInboxItem(
    val id: String,
    val mission: OrbRow,
    val project: OrbRow,
    val kind: OrbInboxKind,
    val tone: OrbInboxTone,
    val badge: String,
    val headline: String,
    val summary: String,
    val lastRequest: String?,
    val workReceipt: String?,
    val aiOverview: OrbInboxDigest?,
    val commandPreview: String?,
    val quickOptions: List<String>,
    val pendingInteraction: OrbInboxPendingInteraction?,
    val updatedAt: String?,
    val isUnread: Boolean,
    val isAttention: Boolean,
    val canRetry: Boolean,
    val isGoal: Boolean,
    val childCount: Int,
    val completedChildCount: Int,
    val runningChildCount: Int,
    val failedChildCount: Int,
    val failedChildren: List<OrbInboxChildFailure>
)

object OrbInboxModel {
    private const val PREFS_KEY = "orb.inbox.dismissed"
    const val MAX_SUMMARY_CHARS = 320

    private var prefs: SharedPreferences? = null
    private val dismissedMap = mutableStateMapOf<String, String>()
    var revision by mutableIntStateOf(0)
        private set

    private val workingStatuses = setOf(
        "active", "running", "starting", "pending", "queued", "resuming", "waiting_background"
    )
    private val hiddenStatuses = setOf(
        "acknowledged", "archived", "deleted", "cancelled"
    )
    private val interactiveTools = setOf(
        "ui_native_request", "AskUserQuestion", "question"
    )

    fun init(context: Context) {
        if (prefs == null) {
            val p = context.applicationContext.getSharedPreferences(PREFS_KEY, Context.MODE_PRIVATE)
            prefs = p
            for ((k, v) in p.all) {
                if (v is String) {
                    dismissedMap[k] = v
                }
            }
        }
    }

    fun dismiss(item: OrbInboxItem, syncBackend: Boolean = true) {
        val sig = signature(item.mission)
        dismissedMap[item.id] = sig
        revision += 1
        prefs?.edit()?.putString(item.id, sig)?.apply()
        OrbMissionUnreadStore.markSeen(item.mission, syncBackend = syncBackend)
        if (syncBackend) {
            runCatching {
                val core = OrbCore.shared
                core.scope.launch {
                    runCatching {
                        core.request(
                            path = "/api/control/missions/${core.encodeComponent(item.id)}/status",
                            method = "POST",
                            body = mapOf("status" to "acknowledged")
                        )
                    }
                }
            }
        }
    }

    fun dismissAll(items: List<OrbInboxItem>) {
        val editor = prefs?.edit()
        val core = runCatching { OrbCore.shared }.getOrNull()
        for (item in items) {
            val sig = signature(item.mission)
            dismissedMap[item.id] = sig
            editor?.putString(item.id, sig)
            if (core != null) {
                val id = item.id
                core.scope.launch {
                    runCatching {
                        core.request(
                            path = "/api/control/missions/${core.encodeComponent(id)}/status",
                            method = "POST",
                            body = mapOf("status" to "acknowledged")
                        )
                    }
                }
            }
        }
        revision += 1
        editor?.apply()
        OrbMissionUnreadStore.markAllSeen(items.map { it.mission })
    }

    fun restore(item: OrbInboxItem) {
        dismissedMap.remove(item.id)
        revision += 1
        prefs?.edit()?.remove(item.id)?.apply()
        runCatching {
            val core = OrbCore.shared
            core.scope.launch {
                runCatching {
                    core.request(
                        path = "/api/control/missions/${core.encodeComponent(item.id)}/status",
                        method = "POST",
                        body = mapOf("status" to "paused")
                    )
                    core.refreshMissionsQuietly()
                }
            }
        }
    }

    private fun isDismissed(mission: OrbRow): Boolean {
        val _rev = revision
        val seen = dismissedMap[mission.id] ?: return false
        return seen == signature(mission)
    }

    private fun signature(mission: OrbRow): String {
        val updated = mission.str("updated_at", "completed_at", "started_at", "created_at") ?: ""
        val status = (mission.str("status", "state") ?: "").lowercase()
        val reason = (mission.str("terminal_reason", "reason", "error") ?: "").lowercase()
        return "$status|$reason|$updated"
    }

    fun isSyntheticUserMessage(raw: String): Boolean {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return true
        return Regex("^\\[SYSTEM:\\s*AUTOMATIC[\\s_]+RESUME", RegexOption.IGNORE_CASE).containsMatchIn(trimmed) ||
            Regex("^\\[SYSTEM:\\s*BACKGROUND", RegexOption.IGNORE_CASE).containsMatchIn(trimmed) ||
            Regex("^Continue from where you left off\\.?$", RegexOption.IGNORE_CASE).matches(trimmed) ||
            Regex("^Continue and resolve the blocker/error\\.?$", RegexOption.IGNORE_CASE).matches(trimmed)
    }

    fun cleanChildTrackLabel(raw: String): String {
        val cleaned = displayTitle(raw).replace(Regex("\\s*·\\s*fork\\s*$", RegexOption.IGNORE_CASE), "").trim()
        if (cleaned.isEmpty()) return "Worker track"
        if (Regex("^(i['’]ll|i will|let me|now i['’]ll|first,? i['’]ll)\\b", RegexOption.IGNORE_CASE).containsMatchIn(cleaned) ||
            cleaned.length > 68
        ) {
            return clipToSentence(cleaned, 48).ifEmpty { "Worker track" }
        }
        return cleaned
    }

    fun isSubagent(mission: OrbRow): Boolean {
        val tags = OrbJSON.strList(mission.raw, "tags")
        if (tags.any { it == "superseded" || it.startsWith("superseded-by:") }) return true
        if (OrbInboxSettings.includeAutonomous) return false
        if (!mission.str("parent_mission_id").isNullOrEmpty() || !mission.str("callback_parent_mission_id").isNullOrEmpty()) return true
        if (mission.str("origin") == "hermes" || tags.any { it.startsWith("worker-dispatch:") || it == "origin:hermes" || it == "origin:hermes-assistant" }) return true
        return Regex("^you are a sub-?agent\\b", RegexOption.IGNORE_CASE).containsMatchIn((mission.str("title", "name") ?: "").trim())
    }

    private fun isMobile(mission: OrbRow): Boolean {
        val tags = OrbJSON.strList(mission.raw, "tags")
        return tags.none { it.startsWith("btw-parent:") }
    }

    fun build(projects: List<OrbRow>, missions: List<OrbRow>, answeredCallIds: Set<String> = emptySet()): List<OrbInboxItem> {
        val _rev1 = revision
        val _rev2 = OrbMissionUnreadStore.revision
        val _rev3 = OrbInboxDigestStore.revision
        val _rev4 = OrbInboxSettings.revision

        val activeProjects = projects.filterNot { p ->
            val st = (p.str("status", "state") ?: "").lowercase()
            st == "archived" || st == "deleted" || p.bool("archived") == true
        }
        val projectsBySlug = mutableMapOf<String, OrbRow>()
        val defaultProj = activeProjects.firstOrNull { (it.str("slug", "id") ?: "").lowercase() == "default" }
            ?: OrbRow("default", mapOf("id" to "default", "slug" to "default", "title" to "Default"))
        projectsBySlug["default"] = defaultProj
        for (p in activeProjects) {
            val s = (p.str("slug", "id") ?: p.id).trim().lowercase()
            if (s.isNotEmpty()) projectsBySlug[s] = p
        }

        val mobileMissions = missions.filter { isMobile(it) }

        val childrenByParent = mutableMapOf<String, MutableList<OrbRow>>()
        val seenChildren = mutableSetOf<String>()
        for (child in mobileMissions) {
            if (!seenChildren.add(child.id)) continue
            val parentId = child.str("parent_mission_id", "callback_parent_mission_id") ?: ""
            val state = (child.str("status", "state") ?: "").lowercase()
            if (parentId.isNotEmpty() && state !in hiddenStatuses) {
                childrenByParent.getOrPut(parentId) { mutableListOf() }.add(child)
            }
        }

        val items = mutableListOf<OrbInboxItem>()
        val seen = mutableSetOf<String>()

        for (mission in mobileMissions) {
            if (!seen.add(mission.id)) continue
            val state = (mission.str("status", "state") ?: "").lowercase()
            if (state in hiddenStatuses || OrbMissionTree.isArchived(mission)) continue
            if (isDismissed(mission)) continue
            if (isSubagent(mission)) continue
            if (state in workingStatuses) continue

            val rawSlug = (mission.str("project", "project_slug") ?: "").trim().lowercase()
            val tags = OrbJSON.strList(mission.raw, "tags")
            val isClient = tags.contains("placement:client")
            if (activeProjects.isNotEmpty()) {
                if (rawSlug.isEmpty() && !isClient) continue
                val slug = if (rawSlug.isEmpty()) "default" else rawSlug
                if (!projectsBySlug.containsKey(slug)) continue
            }

            val cachedEvents = OrbReadCache.loadRows("mission_events_${mission.id}")
            val classified = classify(mission, cachedEvents, answeredCallIds) ?: continue
            val resolvedSlug = if (rawSlug.isEmpty()) "default" else rawSlug
            val project = projectsBySlug[resolvedSlug] ?: resolveProject(mission, activeProjects)

            val children = childrenByParent[mission.id] ?: emptyList()
            var completedKids = 0
            var runningKids = 0
            var failedKids = 0
            val failedList = mutableListOf<OrbInboxChildFailure>()
            var hasUnreadFailure = false

            for (child in children) {
                val cst = (child.str("status", "state") ?: "").lowercase()
                when {
                    cst in setOf("completed", "succeeded") -> completedKids += 1
                    cst in workingStatuses -> runningKids += 1
                    cst in setOf("failed", "not_feasible", "blocked") -> {
                        failedKids += 1
                        val cTitle = cleanChildTrackLabel(child.str("title", "name") ?: "")
                        failedList.add(
                            OrbInboxChildFailure(
                                id = child.id,
                                title = cTitle,
                                row = child
                            )
                        )
                        if (OrbMissionUnreadStore.isUnread(child)) {
                            hasUnreadFailure = true
                        }
                    }
                }
            }

            val headline = missionHeadline(mission)
            val digest = OrbInboxDigestStore.get(mission)
            val summaryText = if (classified.pendingInteraction == null && !digest?.outcome.isNullOrEmpty()) {
                digest!!.outcome
            } else {
                classified.summary
            }
            val lastReq = if (!digest?.task.isNullOrEmpty()) {
                digest!!.task.takeIf { !it.equals(headline, ignoreCase = true) }
            } else {
                extractLastRequest(mission, cachedEvents, headline)
            }
            val workReceipt = extractWorkReceipt(cachedEvents)

            val unread = OrbMissionUnreadStore.isUnread(mission, hasInteraction = classified.pendingInteraction != null) || hasUnreadFailure
            val attention = classified.quickOptions.isNotEmpty() ||
                state in setOf("blocked", "failed", "not_feasible") ||
                hasUnreadFailure
            val canRetry = state in setOf("failed", "not_feasible", "interrupted", "blocked")

            items.add(
                OrbInboxItem(
                    id = mission.id,
                    mission = mission,
                    project = project,
                    kind = classified.kind,
                    tone = classified.tone,
                    badge = classified.badge,
                    headline = headline,
                    summary = summaryText,
                    lastRequest = lastReq,
                    workReceipt = workReceipt,
                    aiOverview = digest,
                    commandPreview = classified.commandPreview,
                    quickOptions = classified.quickOptions,
                    pendingInteraction = classified.pendingInteraction,
                    updatedAt = mission.str("updated_at", "completed_at", "started_at", "created_at"),
                    isUnread = unread,
                    isAttention = attention,
                    canRetry = canRetry,
                    isGoal = OrbMissionTree.isGoal(mission) || mission.bool("goal_mode") == true ||
                        (mission.str("title", "name") ?: "").trim().startsWith("/goal"),
                    childCount = children.size,
                    completedChildCount = completedKids,
                    runningChildCount = runningKids,
                    failedChildCount = failedKids,
                    failedChildren = failedList
                )
            )
        }

        return items.sortedWith { a, b ->
            if (a.kind != b.kind) {
                return@sortedWith if (a.kind == OrbInboxKind.NeedsInput) -1 else 1
            }
            if (a.kind == OrbInboxKind.NeedsInput) {
                val ua = urgencyRank(a)
                val ub = urgencyRank(b)
                if (ua != ub) return@sortedWith ua.compareTo(ub)
            }
            val ua = a.updatedAt ?: ""
            val ub = b.updatedAt ?: ""
            ub.compareTo(ua)
        }
    }

    fun workingMissions(projects: List<OrbRow>, missions: List<OrbRow>): List<OrbRow> {
        val activeProjects = projects.filterNot { p ->
            val st = (p.str("status", "state") ?: "").lowercase()
            st == "archived" || st == "deleted" || p.bool("archived") == true
        }
        val validSlugs = mutableSetOf("default")
        for (p in activeProjects) {
            val s = (p.str("slug", "id") ?: p.id).trim().lowercase()
            if (s.isNotEmpty()) validSlugs.add(s)
        }
        val seen = mutableSetOf<String>()
        return missions.filter { m ->
            if (!seen.add(m.id)) return@filter false
            if (!isMobile(m)) return@filter false
            val st = (m.str("status", "state") ?: "").lowercase()
            if (st !in workingStatuses || isSubagent(m) || OrbMissionTree.isArchived(m)) return@filter false
            val rawSlug = (m.str("project", "project_slug") ?: "").trim().lowercase()
            val tags = OrbJSON.strList(m.raw, "tags")
            val isClient = tags.contains("placement:client")
            if (activeProjects.isNotEmpty()) {
                if (rawSlug.isEmpty() && !isClient) return@filter false
                val slug = if (rawSlug.isEmpty()) "default" else rawSlug
                if (slug !in validSlugs) return@filter false
            }
            true
        }
    }

    fun actionableCount(projects: List<OrbRow>, missions: List<OrbRow>): Int {
        val all = build(projects, missions)
        return all.count { it.isUnread }
    }

    private fun urgencyRank(item: OrbInboxItem): Int {
        if (item.quickOptions.isNotEmpty()) return 0
        return when ((item.mission.str("status", "state") ?: "").lowercase()) {
            "blocked" -> 1
            "awaiting_user", "waiting_user" -> 2
            "failed", "not_feasible" -> 3
            else -> 4
        }
    }

    private data class Classification(
        val kind: OrbInboxKind,
        val tone: OrbInboxTone,
        val badge: String,
        val summary: String,
        val commandPreview: String?,
        val quickOptions: List<String>,
        val pendingInteraction: OrbInboxPendingInteraction?
    )

    fun extractPendingInteraction(
        events: List<OrbRow>,
        status: String,
        answeredCallIds: Set<String> = emptySet()
    ): OrbInboxPendingInteraction? {
        if (status in hiddenStatuses || status in setOf("completed", "succeeded", "failed", "not_feasible")) {
            return null
        }
        val resolvedCalls = events.mapNotNull { ev ->
            val evType = (ev.str("event_type", "type") ?: "").lowercase()
            if (evType == "tool_result") ev.str("tool_call_id", "call_id") else null
        }.toSet()

        val callEvent = events.asReversed().firstOrNull { ev ->
            val evType = (ev.str("event_type", "type") ?: "").lowercase()
            val toolName = ev.str("tool_name", "name") ?: ""
            val callId = ev.str("tool_call_id", "call_id") ?: ""
            evType == "tool_call" && toolName in interactiveTools && callId.isNotEmpty() &&
                callId !in resolvedCalls && callId !in answeredCallIds
        } ?: return null

        val callId = callEvent.str("tool_call_id", "call_id") ?: return null
        val toolName = callEvent.str("tool_name", "name") ?: "ui_native_request"
        val requestDict = OrbJSON.dict(OrbJSON.parse(callEvent.str("content", "arguments") ?: ""))
            ?: callEvent.dict("data")
            ?: return null

        val method = OrbJSON.str(requestDict, "method")
            ?: if (toolName == "AskUserQuestion") "claude_questions" else "question"
        val params = OrbJSON.dict(requestDict["params"]) ?: requestDict

        if (method == "permission") {
            val input = OrbJSON.dict(params["input"])
            val desc = OrbJSON.str(input, "description", "command", "file_path")
                ?: OrbJSON.str(params, "tool")
                ?: "Allow this tool action?"
            val cmd = OrbJSON.str(input, "command")
            return OrbInboxPendingInteraction(
                callId = callId,
                toolName = toolName,
                kind = "permission",
                prompt = clipToSentence(desc),
                commandPreview = cmd,
                options = listOf(
                    OrbInboxInteractionOption("Approve", true, mapOf("action" to "accept")),
                    OrbInboxInteractionOption("Decline", false, mapOf("action" to "revise"))
                )
            )
        }

        if (method == "plan") {
            val planText = OrbJSON.str(params, "plan") ?: "Review the proposed implementation plan."
            return OrbInboxPendingInteraction(
                callId = callId,
                toolName = toolName,
                kind = "plan",
                prompt = clipToSentence(planText),
                commandPreview = null,
                options = listOf(
                    OrbInboxInteractionOption("Approve plan", true, mapOf("action" to "accept")),
                    OrbInboxInteractionOption("Revise", false, mapOf("action" to "revise"))
                )
            )
        }

        val questions = OrbJSON.dictList(params["questions"])
        val firstQ = questions.firstOrNull() ?: emptyMap()
        val qPrompt = OrbJSON.str(firstQ, "question") ?: "Waiting for your answer."
        val canQuickPick = questions.size == 1 && OrbJSON.bool(firstQ, "multiSelect") != true
        val claudeFormat = method == "claude_questions" || toolName == "AskUserQuestion"
        val qKey = OrbJSON.str(firstQ, "id") ?: "0"
        val opts = mutableListOf<OrbInboxInteractionOption>()
        if (canQuickPick) {
            OrbJSON.dictList(firstQ["options"]).take(3).forEachIndexed { idx, optDict ->
                val label = (OrbJSON.str(optDict, "label") ?: "").trim()
                if (label.isNotEmpty()) {
                    val mapped: OrbDict = if (claudeFormat) {
                        mapOf(qPrompt to label)
                    } else {
                        mapOf(qKey to mapOf("answers" to listOf(label)))
                    }
                    opts.add(OrbInboxInteractionOption(label, idx == 0, mapOf("answers" to mapped)))
                }
            }
        }
        return OrbInboxPendingInteraction(
            callId = callId,
            toolName = toolName,
            kind = "question",
            prompt = clipToSentence(qPrompt),
            commandPreview = null,
            options = opts
        )
    }

    private fun classify(
        mission: OrbRow,
        cachedEvents: List<OrbRow>,
        answeredCallIds: Set<String>
    ): Classification? {
        val status = (mission.str("status", "state") ?: "").lowercase()
        val summaryText = extractSummary(mission, cachedEvents)
        val cachedMessages = OrbReadCache.loadRows("mission_msgs_${mission.id}")

        val pending = extractPendingInteraction(cachedEvents, status, answeredCallIds)
        if (pending != null) {
            val badge = when (pending.kind) {
                "permission" -> "Approval"
                "plan" -> "Plan review"
                else -> "Question"
            }
            return Classification(
                kind = OrbInboxKind.NeedsInput,
                tone = OrbInboxTone.Amber,
                badge = badge,
                summary = pending.prompt,
                commandPreview = pending.commandPreview,
                quickOptions = pending.options.map { it.label },
                pendingInteraction = pending
            )
        }

        val q = OrbQuestionExtractor.extract(cachedEvents, cachedMessages, status)
        if (q != null && status !in setOf("completed", "succeeded", "failed", "not_feasible")) {
            val badge = when (q.kind) {
                OrbQuestion.Kind.Permission -> "Approval"
                OrbQuestion.Kind.Plan -> "Plan review"
                OrbQuestion.Kind.Question -> "Question"
            }
            return Classification(
                kind = OrbInboxKind.NeedsInput,
                tone = OrbInboxTone.Amber,
                badge = badge,
                summary = clipToSentence(q.prompt),
                commandPreview = null,
                quickOptions = q.options.take(3),
                pendingInteraction = null
            )
        }

        return when (status) {
            "blocked" -> Classification(
                kind = OrbInboxKind.NeedsInput,
                tone = OrbInboxTone.Amber,
                badge = "Blocked",
                summary = summaryText,
                commandPreview = null,
                quickOptions = emptyList(),
                pendingInteraction = null
            )
            "failed" -> Classification(
                kind = OrbInboxKind.NeedsInput,
                tone = OrbInboxTone.Red,
                badge = "Failed",
                summary = summaryText,
                commandPreview = null,
                quickOptions = emptyList(),
                pendingInteraction = null
            )
            "not_feasible" -> Classification(
                kind = OrbInboxKind.NeedsInput,
                tone = OrbInboxTone.Red,
                badge = "Not feasible",
                summary = summaryText,
                commandPreview = null,
                quickOptions = emptyList(),
                pendingInteraction = null
            )
            "awaiting_user", "waiting_user" -> Classification(
                kind = OrbInboxKind.NeedsInput,
                tone = OrbInboxTone.Blue,
                badge = if (summaryText.trim().endsWith("?")) "Question" else "Waiting",
                summary = summaryText,
                commandPreview = null,
                quickOptions = emptyList(),
                pendingInteraction = null
            )
            "completed", "succeeded" -> Classification(
                kind = OrbInboxKind.Finished,
                tone = OrbInboxTone.Green,
                badge = "Completed",
                summary = summaryText,
                commandPreview = null,
                quickOptions = emptyList(),
                pendingInteraction = null
            )
            "paused", "interrupted" -> Classification(
                kind = OrbInboxKind.Finished,
                tone = OrbInboxTone.Muted,
                badge = "Paused",
                summary = summaryText,
                commandPreview = null,
                quickOptions = emptyList(),
                pendingInteraction = null
            )
            else -> null
        }
    }

    fun missionHeadline(mission: OrbRow): String {
        val rawTitle = displayTitle(mission.str("title", "name") ?: "")
        if (rawTitle.isNotEmpty()) return rawTitle
        val history = OrbJSON.dictList(mission.raw["history"])
        val firstUser = history.firstOrNull { OrbJSON.str(it, "role") == "user" }
            ?.let { OrbJSON.str(it, "content") } ?: ""
        if (firstUser.isNotEmpty()) return clipToSentence(firstUser, 54)
        return "Untitled conversation"
    }

    private fun displayTitle(raw: String): String {
        val trimmed = raw.trim()
        if (trimmed.startsWith("/goal")) {
            val rest = trimmed.drop(5).trim()
            if (rest.isNotEmpty()) return rest.lineSequence().first().trim()
        }
        if (trimmed.startsWith("/plan")) {
            val rest = trimmed.drop(5).trim()
            if (rest.isNotEmpty()) return rest.lineSequence().first().trim()
        }
        return trimmed.lineSequence().firstOrNull()?.trim() ?: ""
    }

    fun extractLastRequest(mission: OrbRow, events: List<OrbRow>, headline: String): String? {
        for (ev in events.asReversed()) {
            val evType = (ev.str("event_type", "type") ?: "").lowercase()
            if (evType == "user_message") {
                val text = (ev.str("content", "text", "message") ?: "").trim()
                if (text.isNotEmpty() && !isSyntheticUserMessage(text)) {
                    val clipped = clipToSentence(text, 96)
                    if (!clipped.equals(headline, ignoreCase = true)) return clipped
                    return null
                }
            }
        }
        val history = OrbJSON.dictList(mission.raw["history"])
        if (history.size > 1) {
            for (entry in history.asReversed()) {
                if (OrbJSON.str(entry, "role") == "user") {
                    val text = (OrbJSON.str(entry, "content") ?: "").trim()
                    if (text.isNotEmpty() && !isSyntheticUserMessage(text)) {
                        val clipped = clipToSentence(text, 96)
                        if (!clipped.equals(headline, ignoreCase = true)) return clipped
                        return null
                    }
                }
            }
        }
        return null
    }

    fun extractWorkReceipt(events: List<OrbRow>): String? {
        if (events.isEmpty()) return null
        var commands = 0
        var edits = 0
        var reads = 0
        for (ev in events) {
            val evType = (ev.str("event_type", "type") ?: "").lowercase()
            if (evType != "tool_call") continue
            val name = (ev.str("tool_name", "name") ?: "").lowercase()
            when {
                name in setOf("bash", "run_command", "shell", "terminal", "exec_command") -> commands += 1
                name.contains("edit") || name.contains("write") || name.contains("patch") || name.contains("replace") -> edits += 1
                name.contains("read") || name.contains("view") || name.contains("grep") || name.contains("glob") -> reads += 1
            }
        }
        val parts = mutableListOf<String>()
        if (commands > 0) parts.add("$commands ${if (commands == 1) "command" else "commands"}")
        if (edits > 0) parts.add("Edited $edits ${if (edits == 1) "file" else "files"}")
        if (parts.isEmpty() && reads > 0) parts.add("Read $reads ${if (reads == 1) "file" else "files"}")
        return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
    }

    fun extractPeekTurns(mission: OrbRow, events: List<OrbRow>, summaryFallback: String): List<OrbInboxPeekTurn> {
        val turns = mutableListOf<OrbInboxPeekTurn>()
        var pendingTools = mutableListOf<OrbRow>()

        for ((idx, ev) in events.withIndex()) {
            val evType = (ev.str("event_type", "type") ?: "").lowercase()
            when (evType) {
                "tool_call" -> pendingTools.add(ev)
                "user_message" -> {
                    val raw = ev.str("content", "text", "message") ?: ""
                    if (!isSyntheticUserMessage(raw)) {
                        val clean = stripMarkdownToProse(raw).take(600)
                        if (clean.isNotEmpty()) {
                            turns.add(OrbInboxPeekTurn("ev-$idx", "user", clean))
                            pendingTools = mutableListOf()
                        }
                    }
                }
                "assistant_message", "assistant_message_canonical" -> {
                    val clean = humanizeStatusText(ev.str("content", "text", "message") ?: "").take(800)
                    if (clean.isNotEmpty()) {
                        val receipt = extractWorkReceipt(pendingTools)
                        pendingTools = mutableListOf()
                        val last = turns.lastOrNull()
                        if (last != null && last.role == "assistant") {
                            turns[turns.lastIndex] = OrbInboxPeekTurn(
                                id = last.id,
                                role = "assistant",
                                text = clean,
                                workReceipt = receipt ?: last.workReceipt
                            )
                        } else {
                            turns.add(OrbInboxPeekTurn("ev-$idx", "assistant", clean, receipt))
                        }
                    }
                }
                "error" -> {
                    val clean = humanizeStatusText(ev.str("content", "message", "error") ?: "").take(800)
                    if (clean.isNotEmpty()) {
                        val isProse = clean.length >= 220 && !Regex("^(error|failed|exception|panic):", RegexOption.IGNORE_CASE).containsMatchIn(clean)
                        val role = if (isProse) "assistant" else "error"
                        val last = turns.lastOrNull()
                        if (role == "assistant" && last != null && last.role == "assistant") {
                            turns[turns.lastIndex] = last.copy(text = clean)
                        } else {
                            turns.add(OrbInboxPeekTurn("ev-$idx", role, clean))
                        }
                    }
                }
            }
        }

        if (turns.none { it.role == "user" }) {
            val promptFallback = displayTitle(mission.str("goal_objective", "title", "name") ?: "")
            if (promptFallback.isNotEmpty() && turns.isNotEmpty()) {
                turns.add(0, OrbInboxPeekTurn("init-user", "user", promptFallback))
            }
        }

        if (turns.isEmpty()) {
            val history = OrbJSON.dictList(mission.raw["history"])
            for ((idx, entry) in history.withIndex()) {
                val role = if (OrbJSON.str(entry, "role") == "user") "user" else "assistant"
                val content = OrbJSON.str(entry, "content") ?: ""
                if (role == "user" && isSyntheticUserMessage(content)) continue
                val clean = humanizeStatusText(content).take(800)
                if (clean.isNotEmpty()) {
                    turns.add(OrbInboxPeekTurn("hist-$idx", role, clean))
                }
            }
        }

        if (turns.isEmpty()) {
            val st = (mission.str("status", "state") ?: "").lowercase()
            val role = if (st in setOf("failed", "not_feasible")) "error" else "assistant"
            turns.add(OrbInboxPeekTurn("fallback", role, summaryFallback, extractWorkReceipt(events)))
        }

        return turns.takeLast(6)
    }

    private fun extractSummary(mission: OrbRow, cachedEvents: List<OrbRow>): String {
        for (ev in cachedEvents.asReversed()) {
            val evType = (ev.str("event_type", "type") ?: "").lowercase()
            if (evType == "error") {
                val clean = humanizeStatusText(ev.str("content", "message", "error") ?: "")
                if (clean.isNotEmpty()) return clipToSentence(clean)
            }
            if (evType == "assistant_message" || evType == "assistant_message_canonical") {
                val clean = humanizeStatusText(ev.str("content", "text", "message") ?: "")
                if (clean.isNotEmpty()) return clipToSentence(clean)
            }
        }
        val history = OrbJSON.dictList(mission.raw["history"])
        for (entry in history.asReversed()) {
            if (OrbJSON.str(entry, "role") == "assistant") {
                val clean = humanizeStatusText(OrbJSON.str(entry, "content") ?: "")
                if (clean.isNotEmpty()) return clipToSentence(clean)
            }
        }
        val remoteJob = mission.dict("remote_job")
        val remoteErr = humanizeStatusText(OrbJSON.str(remoteJob, "error") ?: "")
        if (remoteErr.isNotEmpty()) return clipToSentence(remoteErr)

        val statusMsg = humanizeStatusText(mission.str("status_message", "last_assistant_message", "summary") ?: "")
        if (statusMsg.isNotEmpty()) return clipToSentence(statusMsg)

        val termReason = humanizeStatusText(mission.str("terminal_reason") ?: "")
        if (termReason.isNotEmpty()) return clipToSentence(termReason)

        return when ((mission.str("status", "state") ?: "").lowercase()) {
            "completed", "succeeded" -> "Finished the task and is ready for your review."
            "awaiting_user", "waiting_user" -> "Finished the turn and is waiting for your follow-up."
            "blocked" -> "Blocked and needs your input to continue."
            "failed", "not_feasible" -> "Stopped with an error — open to inspect or resume."
            else -> "Ready for your review."
        }
    }

    fun humanizeStatusText(raw: String): String {
        var trimmed = raw.trim()
        if (trimmed.isEmpty()) return ""
        if (Regex("^[a-z0-9_]+$").matches(trimmed)) return ""
        trimmed = trimmed.replace(Regex("(?i);\\s*error:\\s*command exited with (?:Some\\()?(-?\\d+)\\)?"), "")
        trimmed = trimmed.replace(Regex("\\(exit Some\\((-?\\d+)\\)\\)"), "(exit $1)")
        trimmed = trimmed.replace(Regex("\\bSome\\((-?\\d+)\\)"), "$1")
        trimmed = trimmed.replace(Regex("(?i)finished with state 'failed'\\s*"), "failed ")
        trimmed = trimmed.replace(Regex("(?i)^Remote\\s+(\\S+)\\s+job\\s+[0-9a-f-]{36}\\s+on\\s+node\\s+'([^']+)'\\s+"), "Remote $1 run on $2 ")
        trimmed = trimmed.replace(Regex("(?i)^Job\\s+[0-9a-f-]{36}\\s+on\\s+node\\s+'([^']+)'\\s+"), "Remote run on $1 ")
        return trimmed
    }

    fun cleanMarkdownPreview(raw: String): String = clipToSentence(raw)

    fun stripMarkdownToProse(raw: String): String {
        if (raw.isEmpty()) return ""
        var s = raw
        s = s.replace(Regex("```[\\s\\S]*?```"), " ")
        s = s.replace(Regex("(?m)^\\s{0,3}#{1,6}\\s+[^\\n]*$"), " ")
        s = s.replace(Regex("(?m)^\\s{0,3}>\\s*"), "")
        s = s.replace(Regex("(?m)^\\s*(?:[-*+]|\\d+\\.)\\s+"), "")
        s = s.replace(Regex("\\[([^\\]]+)\\]\\([^)]+\\)"), "$1")
        s = s.replace(Regex("`([^`]+)`"), "$1")
        s = s.replace(Regex("\\*\\*(.*?)\\*\\*"), "$1")
        s = s.replace(Regex("\\s+"), " ")
        return s.trim()
    }

    fun clipToSentence(raw: String, maxChars: Int = MAX_SUMMARY_CHARS): String {
        val prose = stripMarkdownToProse(raw)
        if (prose.isEmpty()) return ""
        if (prose.length <= maxChars) return prose
        var cutIdx = -1
        for (i in prose.indices) {
            if (i >= maxChars) break
            val ch = prose[i]
            if (ch == '.' || ch == '?' || ch == '!') {
                val nextIdx = i + 1
                val isEnd = nextIdx == prose.length || prose[nextIdx].isWhitespace()
                if (isEnd && nextIdx >= 24) {
                    cutIdx = nextIdx
                }
            }
        }
        if (cutIdx > 0) return prose.substring(0, cutIdx).trim()
        val prefix = prose.take(maxOf(1, maxChars - 1))
        val lastSpace = prefix.lastIndexOf(' ')
        if (lastSpace >= maxChars / 2) {
            return prefix.substring(0, lastSpace).trim() + "…"
        }
        return prefix.trim() + "…"
    }

    fun resolveProject(mission: OrbRow, projects: List<OrbRow>): OrbRow {
        val pName = (mission.str("project", "project_slug", "project_id", "project_name") ?: "").lowercase()
        val mSession = mission.str("origin_session_id", "session_id", "bound_session_id")
        val tags = OrbJSON.strList(mission.raw, "tags").map { it.lowercase() }

        for (project in projects) {
            val slug = (project.str("slug", "id") ?: "").lowercase()
            val name = (project.str("title", "name") ?: "").lowercase()
            val bound = project.str("bound_session_id", "conversation_id", "session_id")
            if (slug.isNotEmpty() && (pName == slug || tags.contains("project:$slug") || tags.contains(slug))) {
                return project
            }
            if (name.isNotEmpty() && pName == name) {
                return project
            }
            if (!bound.isNullOrEmpty() && mSession == bound) {
                return project
            }
        }
        val workspaceId = mission.str("workspace_id", "workspaceId")
        val fallbackSlug = if (pName.isEmpty()) "default" else pName
        val fallbackName = if (pName.isEmpty() || pName == "default") {
            "Default"
        } else {
            pName.replace("-", " ").replace("_", " ").split(" ")
                .joinToString(" ") { it.replaceFirstChar { c -> c.uppercase() } }
        }
        return OrbRow(
            fallbackSlug,
            mapOf(
                "id" to fallbackSlug,
                "slug" to fallbackSlug,
                "title" to fallbackName,
                "name" to fallbackName,
                "workspace_id" to (workspaceId ?: "")
            )
        )
    }
}

enum class OrbInboxFilterMode(val title: String) {
    Unread("Unread"),
    Attention("Attention"),
    All("All")
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrbInboxView(
    core: OrbCore,
    onSelectMission: (mission: OrbRow, project: OrbRow) -> Unit,
    onSelectProject: (OrbRow) -> Unit,
    modifier: Modifier = Modifier
) {
    val projects by core.projects.collectAsState()
    val missions by core.missions.collectAsState()
    val scope = rememberCoroutineScope()

    var filterMode by remember { mutableStateOf(OrbInboxFilterMode.Unread) }
    var selectedProjectSlug by remember { mutableStateOf<String?>(null) }
    var replyingItemId by remember { mutableStateOf<String?>(null) }
    var replyDraft by remember { mutableStateOf("") }
    var sendingItemId by remember { mutableStateOf<String?>(null) }
    var showRunningSection by remember { mutableStateOf(false) }
    var lastDismissedItem by remember { mutableStateOf<OrbInboxItem?>(null) }
    var peekedItemId by remember { mutableStateOf<String?>(null) }
    val peekTurnsByItem = remember { mutableStateMapOf<String, List<OrbInboxPeekTurn>>() }
    var loadingPeekId by remember { mutableStateOf<String?>(null) }
    var isRefreshing by remember { mutableStateOf(false) }
    val answeredCallIds = remember { mutableStateMapOf<String, Boolean>() }

    var eventsVersion by remember { mutableIntStateOf(0) }
    LaunchedEffect(core.baseURL, core.token) {
        while (true) { OrbSharedInboxState.refresh(); delay(10_000L) }
    }
    LaunchedEffect(missions, filterMode, OrbInboxSettings.aiSummary, OrbInboxSettings.model, OrbInboxSettings.includeAutonomous) {
        val candidates = missions.filter { m ->
            val st = (m.str("status", "state") ?: "").lowercase()
            st in setOf(
                "awaiting_user", "waiting_user", "blocked", "failed", "not_feasible",
                "completed", "succeeded", "paused", "interrupted"
            ) && !OrbInboxModel.isSubagent(m)
        }.sortedByDescending { it.str("updated_at", "completed_at", "started_at", "created_at") ?: "" }
            .take(18)

        var anyLoaded = false
        for ((idx, row) in candidates.withIndex()) {
            var evs = OrbReadCache.loadRows("mission_events_${row.id}")
            if (evs.isEmpty() && idx < 12) {
                evs = runCatching {
                    core.fetchRows("/api/control/missions/${core.encodeComponent(row.id)}/events?limit=120", "events")
                }.getOrDefault(emptyList())
                if (evs.isNotEmpty()) {
                    OrbReadCache.saveRows("mission_events_${row.id}", evs)
                    anyLoaded = true
                }
            }
            val priority = if (OrbMissionUnreadStore.isUnread(row)) idx else idx + 20
            OrbInboxDigestStore.request(core, row, evs, priority = priority)
        }
        if (anyLoaded) {
            eventsVersion += 1
        }
    }

    val allItems = remember(
        projects,
        missions,
        OrbInboxModel.revision,
        OrbMissionUnreadStore.revision,
        OrbInboxDigestStore.revision,
        OrbInboxSettings.revision,
        eventsVersion,
        answeredCallIds.size
    ) {
        OrbInboxModel.build(projects, missions, answeredCallIds.keys)
    }

    val workingMissions = remember(projects, missions, OrbInboxSettings.includeAutonomous) {
        OrbInboxModel.workingMissions(projects, missions)
    }

    val unreadCount = remember(allItems) { allItems.count { it.isUnread } }
    val attentionCount = remember(allItems) { allItems.count { it.isAttention } }
    val totalActionableCount = allItems.size

    val modeFilteredItems = remember(allItems, filterMode) {
        when (filterMode) {
            OrbInboxFilterMode.Unread -> allItems.filter { it.isUnread }
            OrbInboxFilterMode.Attention -> allItems.filter { it.isAttention }
            OrbInboxFilterMode.All -> allItems
        }
    }

    val visibleItems = remember(modeFilteredItems, selectedProjectSlug) {
        val slug = selectedProjectSlug ?: return@remember modeFilteredItems
        modeFilteredItems.filter { OrbProjectAppearance.slug(it.project) == slug }
    }

    val needsInputItems = remember(visibleItems) { visibleItems.filter { it.kind == OrbInboxKind.NeedsInput } }
    val finishedItems = remember(visibleItems) { visibleItems.filter { it.kind == OrbInboxKind.Finished } }

    data class ProjectFilterEntry(val slug: String, val name: String, val project: OrbRow, val count: Int)
    val projectFilterChips = remember(modeFilteredItems) {
        val counts = mutableMapOf<String, Int>()
        val rowsBySlug = mutableMapOf<String, OrbRow>()
        for (item in modeFilteredItems) {
            val slug = OrbProjectAppearance.slug(item.project)
            counts[slug] = (counts[slug] ?: 0) + 1
            rowsBySlug[slug] = item.project
        }
        counts.mapNotNull { (slug, count) ->
            val p = rowsBySlug[slug] ?: return@mapNotNull null
            val name = p.str("title", "name", "slug") ?: "Project"
            ProjectFilterEntry(slug, name, p, count)
        }.sortedWith { a, b ->
            if (a.count != b.count) b.count.compareTo(a.count)
            else a.name.compareTo(b.name, ignoreCase = true)
        }
    }

    fun markItemAndChildrenRead(item: OrbInboxItem) {
        OrbMissionUnreadStore.markSeen(item.mission)
        item.failedChildren.forEach { OrbMissionUnreadStore.markSeen(it.row) }
    }

    fun togglePeek(item: OrbInboxItem) {
        if (peekedItemId == item.id) {
            peekedItemId = null
            return
        }
        peekedItemId = item.id
        val cached = OrbReadCache.loadRows("mission_events_${item.id}")
        if (cached.isNotEmpty()) {
            peekTurnsByItem[item.id] = OrbInboxModel.extractPeekTurns(item.mission, cached, item.summary)
        }
        loadingPeekId = item.id
        scope.launch {
            val rows = runCatching {
                core.fetchRows("/api/control/missions/${core.encodeComponent(item.id)}/events?limit=120", "events")
            }.getOrDefault(emptyList())
            if (rows.isNotEmpty()) {
                OrbReadCache.saveRows("mission_events_${item.id}", rows)
                peekTurnsByItem[item.id] = OrbInboxModel.extractPeekTurns(item.mission, rows, item.summary)
                eventsVersion += 1
            } else if (peekTurnsByItem[item.id].isNullOrEmpty()) {
                peekTurnsByItem[item.id] = OrbInboxModel.extractPeekTurns(item.mission, emptyList(), item.summary)
            }
            if (loadingPeekId == item.id) {
                loadingPeekId = null
            }
        }
    }

    fun dismissWithUndo(item: OrbInboxItem) {
        markItemAndChildrenRead(item)
        OrbInboxModel.dismiss(item)
        lastDismissedItem = item
        val dismissedId = item.id
        scope.launch {
            delay(4500L)
            if (lastDismissedItem?.id == dismissedId) {
                lastDismissedItem = null
            }
        }
    }

    fun sendQuickReply(text: String, item: OrbInboxItem) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        sendingItemId = item.id
        scope.launch {
            try {
                val pending = item.pendingInteraction
                val matchedOption = pending?.options?.firstOrNull { it.label.equals(trimmed, ignoreCase = true) }
                if (pending != null && matchedOption != null) {
                    core.request(
                        path = "/api/control/tool_result",
                        method = "POST",
                        body = mapOf(
                            "tool_call_id" to pending.callId,
                            "name" to pending.toolName,
                            "result" to matchedOption.payload
                        )
                    )
                    answeredCallIds[pending.callId] = true
                } else {
                    core.request(
                        path = "/api/control/message",
                        method = "POST",
                        body = mapOf(
                            "mission_id" to item.id,
                            "content" to trimmed,
                            "queue_followup" to true,
                            "client_message_id" to UUID.randomUUID().toString()
                        )
                    )
                }
                markItemAndChildrenRead(item)
                replyingItemId = null
                replyDraft = ""
                core.refreshMissionsQuietly()
            } catch (msgErr: Throwable) {
                core.requestInboxOpen()
            } finally {
                sendingItemId = null
            }
        }
    }

    Box(modifier = modifier.fillMaxSize()) {
        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = {
                scope.launch {
                    isRefreshing = true
                    core.refreshAll()
                    isRefreshing = false
                }
            },
            modifier = Modifier.fillMaxSize()
        ) {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(
                    start = 16.dp,
                    end = 16.dp,
                    top = 8.dp,
                    bottom = if (lastDismissedItem != null) 76.dp else 28.dp
                ),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                item(key = "header") {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("Include autonomous agents", fontSize = 12.sp, color = OrbStyle.textSecondary, modifier = Modifier.weight(1f))
                            androidx.compose.material3.Switch(checked = OrbInboxSettings.includeAutonomous, onCheckedChange = { OrbInboxSettings.update(newIncludeAutonomous = it) }, modifier = Modifier.testTag("inbox.includeAutonomous"))
                        }
                        // Minimalist filter bar + inline working pill + Read all
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .horizontalScroll(rememberScrollState()),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Row(
                                modifier = Modifier
                                    .clip(RoundedCornerShape(OrbStyle.controlRadius))
                                    .padding(bottom = 1.dp),
                                horizontalArrangement = Arrangement.spacedBy(2.dp)
                            ) {
                                OrbInboxFilterMode.entries.forEach { mode ->
                                    val active = filterMode == mode
                                    val count = when (mode) {
                                        OrbInboxFilterMode.Unread -> unreadCount
                                        OrbInboxFilterMode.Attention -> attentionCount
                                        OrbInboxFilterMode.All -> totalActionableCount
                                    }
                                    Row(
                                        modifier = Modifier
                                            .clip(RoundedCornerShape(OrbStyle.controlRadius))
                                            .drawBehind {
                                                if (active) drawLine(OrbStyle.textSecondary, Offset(0f, size.height), Offset(size.width, size.height), 2.dp.toPx())
                                            }
                                            .semantics { selected = active; role = Role.Tab }
                                            .orbPressClickable { filterMode = mode }
                                            .heightIn(min = 48.dp).padding(horizontal = 8.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(4.dp)
                                    ) {
                                        if (mode == OrbInboxFilterMode.Unread) {
                                            Box(
                                                modifier = Modifier
                                                    .size(6.dp)
                                                    .clip(RoundedCornerShape(OrbStyle.controlRadius))
                                                    .background(Color(0xFF0A84FF))
                                            )
                                        }
                                        Text(
                                            text = mode.title,
                                            color = if (active) Color.White else OrbStyle.textSecondary,
                                            fontSize = 12.sp,
                                            fontWeight = FontWeight.Medium,
                                            maxLines = 1,
                                            softWrap = false
                                        )
                                        Text(
                                            text = "$count",
                                            color = OrbStyle.textMuted,
                                            fontSize = 11.sp,
                                            fontFamily = FontFamily.Monospace,
                                            maxLines = 1,
                                            softWrap = false
                                        )
                                    }
                                }
                            }

                            if (workingMissions.isNotEmpty()) {
                                val compactWorking = unreadCount > 0
                                Row(
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(OrbStyle.controlRadius))
                                        .background(if (showRunningSection) OrbStyle.elevated else Color.Transparent)
                                        .border(
                                            1.dp,
                                            if (showRunningSection) OrbStyle.borderStrong else OrbStyle.border,
                                            CircleShape
                                        )
                                        .orbPressClickable { showRunningSection = !showRunningSection }
                                        .padding(horizontal = 9.dp, vertical = 6.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(5.dp)
                                ) {
                                    OrbRunningDots(color = Color.White, dotSize = 2.1.dp, spacing = 1.9.dp)
                                    Text(
                                        text = if (compactWorking) "${workingMissions.size}" else "${workingMissions.size} working",
                                        color = Color.White,
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.Medium,
                                        fontFamily = FontFamily.Monospace,
                                        maxLines = 1,
                                        softWrap = false
                                    )
                                }
                            }

                            if (unreadCount > 0) {
                                Row(
                                    modifier = Modifier
                                        .clip(CircleShape)
                                        .background(OrbStyle.surface)
                                        .border(1.dp, OrbStyle.border, CircleShape)
                                        .orbPressClickable {
                                            allItems.filter { it.isUnread }.forEach { markItemAndChildrenRead(it) }
                                        }
                                        .padding(horizontal = 9.dp, vertical = 6.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                                ) {
                                    Icon(
                                        imageVector = Icons.Default.Check,
                                        contentDescription = null,
                                        tint = OrbStyle.textSecondary,
                                        modifier = Modifier.size(11.dp)
                                    )
                                    Text(
                                        text = "Read all",
                                        color = OrbStyle.textSecondary,
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.Medium,
                                        maxLines = 1,
                                        softWrap = false
                                    )
                                }
                            }
                        }

                        // Project filter chips
                        if (projectFilterChips.size > 1) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .horizontalScroll(rememberScrollState()),
                                horizontalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                Row(
                                    modifier = Modifier
                                        .clip(CircleShape)
                                        .background(if (selectedProjectSlug == null) OrbStyle.elevated else OrbStyle.surface)
                                        .border(
                                            1.dp,
                                            if (selectedProjectSlug == null) OrbStyle.borderStrong else OrbStyle.border,
                                            CircleShape
                                        )
                                        .orbPressClickable { selectedProjectSlug = null }
                                        .padding(horizontal = 11.dp, vertical = 6.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Text(
                                        text = "All projects",
                                        color = if (selectedProjectSlug == null) Color.White else OrbStyle.textSecondary,
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.Medium,
                                        maxLines = 1,
                                        softWrap = false
                                    )
                                }

                                projectFilterChips.forEach { chip ->
                                    val selected = selectedProjectSlug == chip.slug
                                    Row(
                                        modifier = Modifier
                                            .clip(CircleShape)
                                            .background(if (selected) OrbStyle.elevated else OrbStyle.surface)
                                            .border(
                                                1.dp,
                                                if (selected) OrbStyle.borderStrong else OrbStyle.border,
                                                CircleShape
                                            )
                                            .orbPressClickable {
                                                selectedProjectSlug = if (selected) null else chip.slug
                                            }
                                            .padding(horizontal = 10.dp, vertical = 6.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                                    ) {
                                        Box(
                                            modifier = Modifier
                                                .size(6.dp)
                                                .clip(CircleShape)
                                                .background(OrbProjectAppearance.color(chip.project))
                                        )
                                        Text(
                                            text = chip.name,
                                            color = if (selected) Color.White else OrbStyle.textSecondary,
                                            fontSize = 12.sp,
                                            fontWeight = FontWeight.Medium,
                                            maxLines = 1,
                                            softWrap = false,
                                            overflow = TextOverflow.Ellipsis,
                                            modifier = Modifier.widthIn(max = 160.dp)
                                        )
                                        Text(
                                            text = "${chip.count}",
                                            color = OrbStyle.textMuted,
                                            fontSize = 11.sp,
                                            fontFamily = FontFamily.Monospace,
                                            maxLines = 1,
                                            softWrap = false
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                if (showRunningSection && workingMissions.isNotEmpty()) {
                    item(key = "working_section") {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            OrbInboxSectionHeader(
                                title = "Working in background",
                                count = workingMissions.size
                            )
                            workingMissions.forEach { mission ->
                                val project = OrbInboxModel.resolveProject(mission, projects)
                                val pName = project.str("title", "name", "slug") ?: "Project"
                                val updated = mission.str("updated_at", "started_at", "created_at")
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .drawBehind { drawLine(OrbStyle.border, Offset.Zero, Offset(size.width, 0f), 1.dp.toPx()) }
                                        .heightIn(min = 48.dp)
                                        .orbPressClickable { onSelectMission(mission, project) }
                                        .padding(horizontal = 12.dp, vertical = 10.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                                ) {
                                    OrbRunningDots(color = Color.White, dotSize = 2.1.dp, spacing = 1.9.dp)
                                    Box(
                                        modifier = Modifier
                                            .size(6.dp)
                                            .clip(CircleShape)
                                            .background(OrbProjectAppearance.color(project))
                                    )
                                    Text(
                                        text = pName,
                                        color = OrbStyle.textSecondary,
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.Medium,
                                        maxLines = 1,
                                        softWrap = false,
                                        overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.widthIn(max = 110.dp)
                                    )
                                    Text(
                                        text = "·",
                                        color = OrbStyle.textMuted,
                                        fontSize = 12.sp,
                                        maxLines = 1,
                                        softWrap = false
                                    )
                                    Text(
                                        text = OrbInboxModel.missionHeadline(mission),
                                        color = Color.White,
                                        fontSize = 13.sp,
                                        fontWeight = FontWeight.Medium,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.weight(1f)
                                    )
                                    Text(
                                        text = OrbJSON.relative(updated),
                                        color = OrbStyle.textMuted,
                                        fontSize = 11.sp,
                                        fontFamily = FontFamily.Monospace,
                                        maxLines = 1,
                                        softWrap = false
                                    )
                                }
                            }
                        }
                    }
                }

                if (visibleItems.isEmpty()) {
                    item(key = "empty") {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 24.dp, vertical = 56.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(12.dp)
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(56.dp)
                                    .clip(CircleShape)
                                    .background(OrbStyle.surface)
                                    .border(1.dp, OrbStyle.border, CircleShape),
                                contentAlignment = Alignment.Center
                            ) {
                                Icon(
                                    imageVector = Icons.Default.CheckCircleOutline,
                                    contentDescription = null,
                                    tint = OrbStyle.textSecondary,
                                    modifier = Modifier.size(22.dp)
                                )
                            }
                            Text(
                                text = when (filterMode) {
                                    OrbInboxFilterMode.Unread -> "No unread updates"
                                    OrbInboxFilterMode.Attention -> "Nothing waiting on you"
                                    OrbInboxFilterMode.All -> "Inbox is clear"
                                },
                                color = Color.White,
                                fontSize = 17.sp,
                                fontWeight = FontWeight.SemiBold
                            )
                            Text(
                                text = if (workingMissions.isEmpty()) {
                                    "Finished runs, approvals, and blocked missions across all projects will appear here."
                                } else {
                                    "${workingMissions.size} ${if (workingMissions.size == 1) "agent is" else "agents are"} currently working in the background."
                                },
                                color = OrbStyle.textSecondary,
                                fontSize = 13.sp
                            )
                            if (filterMode != OrbInboxFilterMode.All && allItems.isNotEmpty()) {
                                Box(
                                    modifier = Modifier
                                        .padding(top = 4.dp)
                                        .clip(CircleShape)
                                        .background(OrbStyle.surface)
                                        .border(1.dp, OrbStyle.border, CircleShape)
                                        .orbPressClickable { filterMode = OrbInboxFilterMode.All }
                                        .padding(horizontal = 14.dp, vertical = 8.dp)
                                ) {
                                    Text(
                                        text = "Show all ${allItems.size} items",
                                        color = Color.White,
                                        fontSize = 13.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        maxLines = 1,
                                        softWrap = false
                                    )
                                }
                            }
                        }
                    }
                } else {
                    if (needsInputItems.isNotEmpty()) {
                        item(key = "needs_you_header") {
                            OrbInboxSectionHeader(
                                title = "Needs you",
                                count = needsInputItems.size
                            )
                        }

                        items(needsInputItems, key = { "needs-${it.id}" }) { item ->
                            OrbSwipeableInboxCard(
                                item = item,
                                onSwipeDone = { dismissWithUndo(item) },
                                onSwipeReply = {
                                    replyingItemId = item.id
                                    replyDraft = ""
                                }
                            ) {
                                OrbInboxCard(
                                    item = item,
                                    isReplying = replyingItemId == item.id,
                                    replyDraft = if (replyingItemId == item.id) replyDraft else "",
                                    onReplyDraftChange = { replyDraft = it },
                                    isSending = sendingItemId == item.id,
                                    isPeeked = peekedItemId == item.id,
                                    peekTurns = peekTurnsByItem[item.id] ?: emptyList(),
                                    isLoadingPeek = loadingPeekId == item.id,
                                    onSelectMission = {
                                        markItemAndChildrenRead(item)
                                        onSelectMission(item.mission, item.project)
                                    },
                                    onSelectFailedChild = { failedChild ->
                                        markItemAndChildrenRead(item)
                                        onSelectMission(failedChild, item.project)
                                    },
                                    onTogglePeek = { togglePeek(item) },
                                    onToggleRead = { OrbMissionUnreadStore.toggleUnread(item.mission) },
                                    onToggleReply = {
                                        if (replyingItemId == item.id) {
                                            replyingItemId = null
                                            replyDraft = ""
                                        } else {
                                            replyingItemId = item.id
                                            replyDraft = ""
                                        }
                                    },
                                    onSendQuickReply = { sendQuickReply(it, item) },
                                    onDismiss = { dismissWithUndo(item) }
                                )
                            }
                        }
                    }

                    if (finishedItems.isNotEmpty()) {
                        item(key = "finished_header") {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                OrbInboxSectionHeader(
                                    title = "Ready for review",
                                    count = finishedItems.size
                                )
                                Spacer(modifier = Modifier.weight(1f))
                                Text(
                                    text = "Mark all done",
                                    color = OrbStyle.textSecondary,
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.Medium,
                                    maxLines = 1,
                                    softWrap = false,
                                    modifier = Modifier.orbPressClickable {
                                        OrbInboxModel.dismissAll(finishedItems)
                                    }
                                )
                            }
                        }

                        items(finishedItems, key = { "done-${it.id}" }) { item ->
                            OrbSwipeableInboxCard(
                                item = item,
                                onSwipeDone = { dismissWithUndo(item) },
                                onSwipeReply = {
                                    replyingItemId = item.id
                                    replyDraft = ""
                                }
                            ) {
                                OrbInboxCard(
                                    item = item,
                                    isReplying = replyingItemId == item.id,
                                    replyDraft = if (replyingItemId == item.id) replyDraft else "",
                                    onReplyDraftChange = { replyDraft = it },
                                    isSending = sendingItemId == item.id,
                                    isPeeked = peekedItemId == item.id,
                                    peekTurns = peekTurnsByItem[item.id] ?: emptyList(),
                                    isLoadingPeek = loadingPeekId == item.id,
                                    onSelectMission = {
                                        markItemAndChildrenRead(item)
                                        onSelectMission(item.mission, item.project)
                                    },
                                    onSelectFailedChild = { failedChild ->
                                        markItemAndChildrenRead(item)
                                        onSelectMission(failedChild, item.project)
                                    },
                                    onTogglePeek = { togglePeek(item) },
                                    onToggleRead = { OrbMissionUnreadStore.toggleUnread(item.mission) },
                                    onToggleReply = {
                                        if (replyingItemId == item.id) {
                                            replyingItemId = null
                                            replyDraft = ""
                                        } else {
                                            replyingItemId = item.id
                                            replyDraft = ""
                                        }
                                    },
                                    onSendQuickReply = { sendQuickReply(it, item) },
                                    onDismiss = { dismissWithUndo(item) }
                                )
                            }
                        }
                    }
                }
            }
        }

        val dismissed = lastDismissedItem
        if (dismissed != null) {
            Row(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(horizontal = 18.dp, vertical = 14.dp)
                    .clip(CircleShape)
                    .background(OrbStyle.elevated)
                    .border(1.dp, OrbStyle.borderStrong, CircleShape)
                    .padding(horizontal = 15.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Icon(
                    imageVector = Icons.Default.CheckCircle,
                    contentDescription = null,
                    tint = OrbStyle.success,
                    modifier = Modifier.size(14.dp)
                )
                Text(
                    text = "Marked done",
                    color = Color.White,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    softWrap = false
                )
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    text = "Undo",
                    color = OrbStyle.inboxBlue,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    maxLines = 1,
                    softWrap = false,
                    modifier = Modifier.orbPressClickable {
                        OrbInboxModel.restore(dismissed)
                        lastDismissedItem = null
                    }
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun OrbSwipeableInboxCard(
    item: OrbInboxItem,
    onSwipeDone: () -> Unit,
    onSwipeReply: () -> Unit,
    content: @Composable () -> Unit
) {
    val dismissState = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            when (value) {
                SwipeToDismissBoxValue.EndToStart -> {
                    onSwipeDone()
                    true
                }
                SwipeToDismissBoxValue.StartToEnd -> {
                    onSwipeReply()
                    false
                }
                SwipeToDismissBoxValue.Settled -> false
            }
        }
    )

    SwipeToDismissBox(
        state = dismissState,
        backgroundContent = {
            val direction = dismissState.dismissDirection
            val bgColor = when (direction) {
                SwipeToDismissBoxValue.EndToStart -> OrbStyle.success.copy(alpha = 0.22f)
                SwipeToDismissBoxValue.StartToEnd -> OrbStyle.inboxBlue.copy(alpha = 0.22f)
                else -> Color.Transparent
            }
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(bgColor)
                    .padding(horizontal = 18.dp),
                contentAlignment = when (direction) {
                    SwipeToDismissBoxValue.EndToStart -> Alignment.CenterEnd
                    else -> Alignment.CenterStart
                }
            ) {
                if (direction == SwipeToDismissBoxValue.EndToStart) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Default.Check,
                            contentDescription = "Done",
                            tint = OrbStyle.success,
                            modifier = Modifier.size(16.dp)
                        )
                        Text("Done", color = OrbStyle.success, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, softWrap = false)
                    }
                } else if (direction == SwipeToDismissBoxValue.StartToEnd) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.Reply,
                            contentDescription = "Reply",
                            tint = OrbStyle.inboxBlue,
                            modifier = Modifier.size(16.dp)
                        )
                        Text("Reply", color = OrbStyle.inboxBlue, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, softWrap = false)
                    }
                }
            }
        },
        content = { content() }
    )
}

@Composable
private fun OrbInboxSectionHeader(title: String, count: Int) {
    Row(
        modifier = Modifier.padding(top = 16.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        Text(
            text = title,
            color = OrbStyle.textMuted,
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            maxLines = 1,
            softWrap = false
        )
        Text(
            text = "$count",
            color = OrbStyle.textMuted,
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            fontFamily = FontFamily.Monospace,
            maxLines = 1,
            softWrap = false
        )
    }
}

@Composable
private fun OrbInboxCard(
    item: OrbInboxItem,
    isReplying: Boolean,
    replyDraft: String,
    onReplyDraftChange: (String) -> Unit,
    isSending: Boolean,
    isPeeked: Boolean,
    peekTurns: List<OrbInboxPeekTurn>,
    isLoadingPeek: Boolean,
    onSelectMission: () -> Unit,
    onSelectFailedChild: (OrbRow) -> Unit,
    onTogglePeek: () -> Unit,
    onToggleRead: () -> Unit,
    onToggleReply: () -> Unit,
    onSendQuickReply: (String) -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier
) {
    val pName = item.project.str("title", "name", "slug") ?: "Project"
    val pColor = OrbProjectAppearance.color(item.project)
    val showBadge = !(item.kind == OrbInboxKind.Finished && item.badge == "Completed")

    Column(
        modifier = modifier
            .testTag("inbox.row.${item.id}")
            .fillMaxWidth()
            .clip(RoundedCornerShape(OrbStyle.panelRadius))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(OrbStyle.panelRadius))
            .semantics {
                stateDescription = if (item.isUnread) "Unread" else "Read"
                customActions = listOf(CustomAccessibilityAction(if (item.isUnread) "Mark read" else "Mark unread") {
                    onToggleRead(); true
                })
            }
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .orbPressClickable { onTogglePeek() },
            verticalArrangement = Arrangement.spacedBy(5.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Box(Modifier.size(5.dp).clip(CircleShape).background(pColor))
                Text(pName, color = OrbStyle.textSecondary, fontSize = 12.sp,
                    maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                if (showBadge) {
                    Text(item.badge, color = item.tone.foreground, fontSize = 11.sp, maxLines = 1)
                }
                Text(OrbJSON.relative(item.updatedAt), color = OrbStyle.textMuted, fontSize = 11.sp, maxLines = 1)
            }
            Text(
                item.headline, color = OrbStyle.textPrimary, fontSize = 15.sp,
                fontWeight = if (item.isUnread) FontWeight.Medium else FontWeight.Normal,
                maxLines = 2, overflow = TextOverflow.Ellipsis
            )

            // Follow-up request line ("Asked: ...") when distinct from mission headline
            if ((isPeeked || isReplying) && !item.lastRequest.isNullOrEmpty()) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(5.dp)
                ) {
                    Text(
                        text = "Asked:",
                        color = OrbStyle.textMuted,
                        fontSize = 11.5.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        softWrap = false
                    )
                    Text(
                        text = item.lastRequest,
                        color = OrbStyle.textSecondary,
                        fontSize = 12.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f)
                    )
                }
            }

            // Keep the collapsed summary short; the complete response is available in Peek.
            if (item.summary.isNotEmpty()) {
                Text(
                    text = item.summary,
                    color = OrbStyle.textSecondary,
                    fontSize = 13.sp,
                    lineHeight = 18.sp,
                    maxLines = if (isPeeked) Int.MAX_VALUE else 3,
                    overflow = TextOverflow.Ellipsis
                )
            }

            // Work receipt chip
            if (isPeeked && !item.workReceipt.isNullOrEmpty()) {
                Text(
                    text = item.workReceipt,
                    color = OrbStyle.textMuted,
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }

            if (!item.commandPreview.isNullOrEmpty()) {
                Text(
                    text = item.commandPreview,
                    color = OrbStyle.textSecondary,
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(7.dp))
                        .background(Color.Black.copy(alpha = 0.28f))
                        .padding(horizontal = 8.dp, vertical = 5.dp)
                )
            }
        }

        OrbInboxDigestStore.summaryState(item.mission)?.let { state ->
            Text(state, color = OrbStyle.textMuted, fontSize = 11.sp)
        }
        item.aiOverview?.let { digest ->
            Text("AI summary · ${digest.model}", color = OrbStyle.textMuted, fontSize = 11.sp)
            val current = digest.updatedAt == item.updatedAt && runCatching { Instant.parse(digest.sourceUpdatedAt).toEpochMilli() + 2000 >= Instant.parse(item.updatedAt).toEpochMilli() }.getOrDefault(false)
            if (!current) Text("Summary is out of date", color = OrbStyle.textMuted, fontSize = 11.sp)
            if (isPeeked && current) {
                Column(modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(OrbStyle.controlRadius)).background(OrbStyle.elevated).padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    listOf("Context" to digest.context, "Scope" to digest.contextDetails, "Unresolved" to digest.unresolved, "To decide" to digest.decision).filter { it.second.isNotBlank() }.forEach { (label, value) ->
                        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(label, fontSize = 11.sp, color = OrbStyle.textMuted, fontWeight = FontWeight.Medium)
                            androidx.compose.foundation.text.selection.SelectionContainer { Text(value, fontSize = 13.sp, color = OrbStyle.textSecondary, lineHeight = 18.sp) }
                        }
                    }
                    var sourcesOpen by remember(item.id) { mutableStateOf(false) }
                    Text(if (sourcesOpen) "Sources ▴" else "Sources ▾", fontSize = 12.sp, color = OrbStyle.textSecondary, modifier = Modifier.fillMaxWidth().orbPressClickable { sourcesOpen = !sourcesOpen }.padding(vertical = 12.dp))
                    if (sourcesOpen) digest.sources.forEach { quote ->
                        Text(quote, fontSize = 12.sp, color = OrbStyle.textSecondary, modifier = Modifier.fillMaxWidth().orbPressClickable { onSelectMission() }.padding(vertical = 8.dp))
                    }
                }
            }
            if (isReplying && current && item.pendingInteraction == null) digest.suggestions.forEach { suggestion ->
                Text(suggestion, fontSize = 12.sp, color = OrbStyle.textSecondary, modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(OrbStyle.controlRadius)).background(OrbStyle.elevated)
                    .orbPressClickable(enabled = !isSending && replyDraft.isBlank()) { onReplyDraftChange(suggestion) }.padding(12.dp))
            }
        }

        // Actionable child tracks only (failed or running)
        if (item.failedChildren.isNotEmpty() || item.runningChildCount > 0) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                val firstFailed = item.failedChildren.firstOrNull()
                if (firstFailed != null) {
                    Row(
                        modifier = Modifier
                            .weight(1f, fill = false)
                            .clip(RoundedCornerShape(6.dp))
                            .background(OrbStyle.error.copy(alpha = 0.12f))
                            .border(1.dp, OrbStyle.error.copy(alpha = 0.28f), RoundedCornerShape(6.dp))
                            .orbPressClickable { onSelectFailedChild(firstFailed.row) }
                            .padding(horizontal = 8.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Box(
                            modifier = Modifier
                                .size(6.dp)
                                .clip(CircleShape)
                                .background(OrbStyle.error)
                        )
                        Text(
                            text = "${item.failedChildCount} ${if (item.failedChildCount == 1) "track" else "tracks"} failed: ${firstFailed.title}",
                            color = OrbStyle.error,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Medium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false)
                        )
                        Icon(
                            imageVector = Icons.Default.ArrowForward,
                            contentDescription = null,
                            tint = OrbStyle.error,
                            modifier = Modifier.size(11.dp)
                        )
                    }
                }
                if (item.runningChildCount > 0) {
                    Text(
                        text = "${item.runningChildCount} ${if (item.runningChildCount == 1) "track" else "tracks"} running",
                        color = OrbStyle.inboxBlue,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                        softWrap = false,
                        modifier = Modifier
                            .clip(RoundedCornerShape(6.dp))
                            .background(OrbStyle.inboxBlue.copy(alpha = 0.12f))
                            .padding(horizontal = 8.dp, vertical = 3.5.dp)
                    )
                }
            }
        }

        // Quick-pick interaction options in their own scrollable row so they never crush Peek/Reply/Done
        if (item.quickOptions.isNotEmpty()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState()),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                item.quickOptions.take(3).forEachIndexed { idx, opt ->
                    val primary = idx == 0
                    Box(
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(if (primary) Color.White else Color.White.copy(alpha = 0.06f))
                            .border(1.dp, if (primary) Color.Transparent else OrbStyle.border, CircleShape)
                            .orbPressClickable(enabled = !isSending) { onSendQuickReply(opt) }
                            .padding(horizontal = 11.dp, vertical = 5.5.dp)
                    ) {
                        Text(
                            text = opt,
                            color = if (primary) OrbStyle.background else Color.White,
                            fontSize = 12.sp,
                            fontWeight = if (primary) FontWeight.SemiBold else FontWeight.Medium,
                            maxLines = 1,
                            softWrap = false,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.widthIn(max = 220.dp)
                        )
                    }
                }
            }
        }

        // Minimalist quick action bar: Retry / Peek / Reply / Done
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            if (item.canRetry) {
                Row(
                    modifier = Modifier
                        .clip(RoundedCornerShape(OrbStyle.controlRadius))
                        .background(Color.Transparent)

                        .orbPressClickable(enabled = !isSending) {
                            onSendQuickReply("Continue from where you left off.")
                        }
                        .heightIn(min = 48.dp).padding(horizontal = 9.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.Refresh,
                        contentDescription = null,
                        tint = OrbStyle.textSecondary,
                        modifier = Modifier.size(11.dp)
                    )
                    Text(
                        text = "Retry",
                        color = OrbStyle.textSecondary,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                        softWrap = false
                    )
                }
            }

            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(OrbStyle.controlRadius))
                    .background(if (isPeeked) OrbStyle.elevated else Color.Transparent)

                    .orbPressClickable { onTogglePeek() }
                    .heightIn(min = 48.dp).padding(horizontal = 9.dp)
            ) {
                Text(
                    text = "Peek",
                    color = if (isPeeked) Color.White else OrbStyle.textSecondary,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    softWrap = false
                )
            }

            Spacer(modifier = Modifier.weight(1f))

            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(OrbStyle.controlRadius))
                    .background(if (isReplying) OrbStyle.elevated else Color.Transparent)

                    .orbPressClickable { onToggleReply() }
                    .heightIn(min = 48.dp).padding(horizontal = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.Reply,
                    contentDescription = null,
                    tint = if (isReplying) Color.White else OrbStyle.textSecondary,
                    modifier = Modifier.size(11.dp)
                )
                Text(
                    text = "Reply",
                    color = if (isReplying) Color.White else OrbStyle.textSecondary,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    softWrap = false
                )
            }

            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(OrbStyle.controlRadius))
                    .background(Color.Transparent)

                    .orbPressClickable { onDismiss() }
                    .heightIn(min = 48.dp).padding(horizontal = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Icon(
                    imageVector = Icons.Default.Check,
                    contentDescription = null,
                    tint = OrbStyle.textSecondary,
                    modifier = Modifier.size(11.dp)
                )
                Text(
                    text = "Done",
                    color = OrbStyle.textSecondary,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    softWrap = false
                )
            }
        }

        if (isPeeked) {
            Column(
                modifier = Modifier.padding(top = 16.dp, bottom = 8.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                if (isLoadingPeek && peekTurns.isEmpty()) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        CircularProgressIndicator(
                            color = OrbStyle.textSecondary,
                            strokeWidth = 2.dp,
                            modifier = Modifier.size(14.dp)
                        )
                        Text(
                            text = "Loading conversation…",
                            color = OrbStyle.textSecondary,
                            fontSize = 12.sp
                        )
                    }
                } else {
                    val turnsToShow = peekTurns.ifEmpty {
                        listOf(
                            OrbInboxPeekTurn(
                                id = "fallback",
                                role = "assistant",
                                text = item.summary,
                                workReceipt = item.workReceipt
                            )
                        )
                    }
                    turnsToShow.forEach { turn ->
                        val isUser = turn.role == "user"
                        val isError = turn.role == "error"
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(8.dp))
                                .background(
                                    if (isError) OrbStyle.error.copy(alpha = 0.08f)
                                    else Color.Black.copy(alpha = 0.24f)
                                )
                                .padding(horizontal = 9.dp, vertical = 7.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Row(
                                verticalAlignment = Alignment.Top,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Text(
                                    text = when {
                                        isUser -> "YOU"
                                        isError -> "ERROR"
                                        else -> "AGENT"
                                    },
                                    color = when {
                                        isError -> OrbStyle.error
                                        isUser -> OrbStyle.textSecondary
                                        else -> OrbStyle.inboxBlue
                                    },
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    maxLines = 1,
                                    softWrap = false,
                                    modifier = Modifier.width(42.dp)
                                )
                                Text(
                                    text = turn.text,
                                    color = OrbStyle.textSecondary,
                                    fontSize = 12.sp,
                                    lineHeight = 17.sp,
                                    modifier = Modifier.weight(1f)
                                )
                            }
                            if (!turn.workReceipt.isNullOrEmpty()) {
                                Text(
                                    text = turn.workReceipt,
                                    color = OrbStyle.textMuted,
                                    fontSize = 10.5.sp,
                                    fontFamily = FontFamily.Monospace,
                                    modifier = Modifier.padding(start = 50.dp)
                                )
                            }
                        }
                    }
                }
            }
        }

        if (isReplying) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(OrbStyle.controlRadius))
                        .background(Color.Black.copy(alpha = 0.28f))
                        .border(1.dp, OrbStyle.borderStrong, RoundedCornerShape(OrbStyle.controlRadius))
                        .padding(horizontal = 11.dp, vertical = 8.dp)
                ) {
                    if (replyDraft.isEmpty()) {
                        Text(
                            text = "Send follow-up…",
                            color = OrbStyle.textMuted,
                            fontSize = 13.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    BasicTextField(
                        value = replyDraft,
                        onValueChange = onReplyDraftChange,
                        textStyle = TextStyle(color = Color.White, fontSize = 13.sp),
                        cursorBrush = SolidColor(Color.White),
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth().heightIn(min = 32.dp)
                    )
                }
                val canSend = replyDraft.trim().isNotEmpty() && !isSending
                Box(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(if (canSend) Color.White else Color.White.copy(alpha = 0.08f))
                        .orbPressClickable(enabled = canSend) { onSendQuickReply(replyDraft) }
                        .heightIn(min = 48.dp)
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = if (isSending) "…" else "Send",
                        color = if (canSend) OrbStyle.background else OrbStyle.textMuted,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        softWrap = false
                    )
                }
            }
        }
    }
}
