package sh.sandboxed.dashboard.orb

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import androidx.compose.ui.graphics.Color
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.sse.EventSource
import okhttp3.sse.EventSourceListener
import okhttp3.sse.EventSources
import sh.sandboxed.dashboard.util.TokenCrypto
import java.io.File
import java.net.URLEncoder
import java.security.MessageDigest
import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

typealias OrbDict = Map<String, Any?>

object OrbJSON {
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
    }

    fun parse(bytes: ByteArray): Any? = try {
        parse(bytes.decodeToString())
    } catch (_: Throwable) {
        null
    }

    fun parse(text: String): Any? = try {
        val elem = json.parseToJsonElement(text)
        fromJsonElement(elem)
    } catch (_: Throwable) {
        null
    }

    private fun fromJsonElement(elem: JsonElement): Any? = when (elem) {
        is JsonNull -> null
        is JsonPrimitive -> {
            if (elem.isString) {
                elem.content
            } else {
                elem.booleanOrNull
                    ?: elem.longOrNull?.let { l ->
                        if (l in Int.MIN_VALUE..Int.MAX_VALUE) l.toInt() else l
                    }
                    ?: elem.doubleOrNull
                    ?: elem.contentOrNull
            }
        }
        is JsonArray -> elem.map { fromJsonElement(it) }
        is JsonObject -> elem.entries.associate { (k, v) -> k to fromJsonElement(v) }
    }

    fun toJsonElement(value: Any?): JsonElement = when (value) {
        null -> JsonNull
        is JsonElement -> value
        is Boolean -> JsonPrimitive(value)
        is Number -> JsonPrimitive(value)
        is String -> JsonPrimitive(value)
        is Map<*, *> -> JsonObject(
            value.entries.mapNotNull { (k, v) ->
                (k as? String)?.let { key -> key to toJsonElement(v) }
            }.toMap()
        )
        is Iterable<*> -> JsonArray(value.map { toJsonElement(it) })
        is Array<*> -> JsonArray(value.map { toJsonElement(it) })
        else -> JsonPrimitive(value.toString())
    }

    fun stringify(value: Any?): String = try {
        json.encodeToString(JsonElement.serializer(), toJsonElement(value))
    } catch (_: Throwable) {
        "{}"
    }

    @Suppress("UNCHECKED_CAST")
    fun dict(value: Any?): OrbDict? = value as? OrbDict

    @Suppress("UNCHECKED_CAST")
    fun dictList(value: Any?): List<OrbDict> = when (value) {
        is List<*> -> value.mapNotNull { it as? OrbDict }
        else -> emptyList()
    }

    fun str(dict: OrbDict?, vararg keys: String): String? {
        if (dict == null) return null
        for (key in keys) {
            when (val raw = dict[key]) {
                is String -> {
                    val trimmed = raw.trim()
                    if (trimmed.isNotEmpty()) return trimmed
                }
                is Int -> return raw.toString()
                is Long -> return raw.toString()
                is Double -> return raw.toLong().toString()
            }
        }
        return null
    }

    fun rawStr(dict: OrbDict?, vararg keys: String): String? {
        if (dict == null) return null
        for (key in keys) {
            val raw = dict[key] as? String
            if (!raw.isNullOrEmpty()) return raw
        }
        return null
    }

    fun int(dict: OrbDict?, vararg keys: String): Int? {
        if (dict == null) return null
        for (key in keys) {
            when (val raw = dict[key]) {
                is Int -> return raw
                is Long -> return raw.toInt()
                is Double -> return raw.toInt()
                is Number -> return raw.toInt()
                is String -> raw.trim().toIntOrNull()?.let { return it }
            }
        }
        return null
    }

    fun double(dict: OrbDict?, vararg keys: String): Double? {
        if (dict == null) return null
        for (key in keys) {
            when (val raw = dict[key]) {
                is Double -> return raw
                is Float -> return raw.toDouble()
                is Int -> return raw.toDouble()
                is Long -> return raw.toDouble()
                is Number -> return raw.toDouble()
                is String -> raw.trim().toDoubleOrNull()?.let { return it }
            }
        }
        return null
    }

    fun bool(dict: OrbDict?, vararg keys: String): Boolean? {
        if (dict == null) return null
        for (key in keys) {
            when (val raw = dict[key]) {
                is Boolean -> return raw
                is Number -> return raw.toInt() != 0
                is String -> when (raw.trim().lowercase()) {
                    "true", "1", "yes" -> return true
                    "false", "0", "no" -> return false
                }
            }
        }
        return null
    }

    fun strList(dict: OrbDict?, vararg keys: String): List<String> {
        if (dict == null) return emptyList()
        for (key in keys) {
            val list = dict[key] as? List<*> ?: continue
            val strings = list.mapNotNull { (it as? String)?.trim()?.takeIf { s -> s.isNotEmpty() } }
            if (strings.isNotEmpty()) return strings
        }
        return emptyList()
    }

    fun dateEpochMs(raw: String?): Long? {
        val text = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        return try {
            Instant.parse(text).toEpochMilli()
        } catch (_: Throwable) {
            try {
                OffsetDateTime.parse(text, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant().toEpochMilli()
            } catch (_: Throwable) {
                null
            }
        }
    }

    fun relative(raw: String?): String {
        val epochMs = dateEpochMs(raw) ?: return ""
        val seconds = maxOf(0L, (System.currentTimeMillis() - epochMs) / 1000L).toInt()
        if (seconds < 45) return "now"
        val minutes = maxOf(1, seconds / 60)
        if (seconds < 3600) return "${minutes}m"
        val hours = seconds / 3600
        if (seconds < 86_400) return "${hours}h"
        val days = seconds / 86_400
        if (seconds < 604_800) return "${days}d"
        return "${seconds / 604_800}w"
    }

    fun cleanTitle(raw: String?): String {
        val value = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return "Untitled"
        val firstLine = value.lineSequence()
            .map { it.trim() }
            .firstOrNull { it.isNotEmpty() } ?: "Untitled"
        val stripped = firstLine.replace(Regex("^[#*\\-`>\\s]+"), "")
        return if (stripped.isEmpty()) firstLine else stripped
    }
}

data class OrbRow(
    val id: String,
    val raw: OrbDict
) {
    constructor(raw: OrbDict, fallback: String = UUID.randomUUID().toString()) : this(
        id = OrbJSON.str(raw, "id", "slug", "session_id", "mission_id", "name", "key", "path") ?: fallback,
        raw = raw
    )

    fun str(vararg keys: String): String? = OrbJSON.str(raw, *keys)
    fun int(vararg keys: String): Int? = OrbJSON.int(raw, *keys)
    fun double(vararg keys: String): Double? = OrbJSON.double(raw, *keys)
    fun bool(vararg keys: String): Boolean? = OrbJSON.bool(raw, *keys)
    fun dict(key: String): OrbDict? = OrbJSON.dict(raw[key])
    fun rows(key: String): List<OrbRow> = OrbJSON.dictList(raw[key]).mapIndexed { idx, item ->
        OrbRow(item, "$id-$key-$idx")
    }

    override fun equals(other: Any?): Boolean =
        other is OrbRow && id == other.id && raw == other.raw

    override fun hashCode(): Int = 31 * id.hashCode() + raw.hashCode()
}

data class OrbNestedMission(
    val mission: OrbRow,
    val children: List<OrbNestedMission>,
    val depth: Int
) {
    val id: String get() = mission.id
    val childCount: Int get() = children.size + children.sumOf { it.childCount }
    val runningChildCount: Int
        get() = children.count { OrbMissionTree.isLive(it.mission) } +
            children.sumOf { it.runningChildCount }
}

object OrbMissionTree {
    fun parentId(mission: OrbRow): String? {
        mission.str(
            "parent_mission_id",
            "callback_parent_mission_id",
            "parentMissionId",
            "parent_id",
            "parentId"
        )?.let { return it }
        for (tag in OrbJSON.strList(mission.raw, "tags")) {
            val lower = tag.lowercase()
            for (prefix in listOf("parent:", "parent_mission:", "parent-mission:", "spawned_by:", "spawned-by:")) {
                if (lower.startsWith(prefix)) {
                    val value = tag.drop(prefix.length).trim()
                    if (value.isNotEmpty()) return value
                }
            }
        }
        return null
    }

    fun isLive(mission: OrbRow): Boolean {
        val status = (mission.str("status", "state") ?: "").lowercase()
        return status in setOf("active", "running", "working", "queued", "pending", "starting", "in_progress", "processing", "streaming")
    }

    fun isGoal(mission: OrbRow): Boolean {
        if (mission.bool("goal_mode") == true) return true
        val title = mission.str("title", "name", "headline", "summary") ?: ""
        if (title.trimStart().startsWith("/goal ") || title.trim() == "/goal") return true
        val tags = OrbJSON.strList(mission.raw, "tags").map { it.lowercase() }
        if (tags.contains("orb-mode:goal") || tags.contains("mode:goal") || tags.contains("goal")) return true
        val mode = (mission.str("mode", "execution_mode", "run_mode") ?: "").lowercase()
        return mode == "goal"
    }

    fun isArchived(mission: OrbRow): Boolean {
        val status = (mission.str("status", "state") ?: "").lowercase()
        if (status == "acknowledged" || status == "archived") return true
        if (mission.bool("archived") == true) return true
        return OrbJSON.strList(mission.raw, "tags").any { it.lowercase() == "orb-archived" }
    }

    fun folderPath(mission: OrbRow): String? {
        for (tag in OrbJSON.strList(mission.raw, "tags")) {
            if (tag.lowercase().startsWith("orb-folder:")) {
                val raw = tag.drop("orb-folder:".length).trim().trim('/')
                if (raw.isNotEmpty()) return raw
            }
        }
        return null
    }

    fun nest(missions: List<OrbRow>): List<OrbNestedMission> {
        val deduped = OrbContinuation.collapse(missions)
        val byId = deduped.associateBy { it.id }
        val childrenByParent = mutableMapOf<String, MutableList<OrbRow>>()
        val roots = mutableListOf<OrbRow>()

        for (mission in deduped) {
            val parent = parentId(mission)
            if (parent != null && parent != mission.id && byId.containsKey(parent)) {
                childrenByParent.getOrPut(parent) { mutableListOf() }.add(mission)
            } else {
                roots.add(mission)
            }
        }

        fun build(row: OrbRow, depth: Int, visited: Set<String>): OrbNestedMission {
            if (visited.contains(row.id)) return OrbNestedMission(row, emptyList(), depth)
            val nextVisited = visited + row.id
            val kids = (childrenByParent[row.id] ?: emptyList()).map { build(it, depth + 1, nextVisited) }
            return OrbNestedMission(row, kids, depth)
        }

        return roots.map { build(it, 0, emptySet()) }
    }

    fun flatten(nodes: List<OrbNestedMission>, expandedIds: Set<String>): List<OrbNestedMission> {
        val out = mutableListOf<OrbNestedMission>()
        fun visit(node: OrbNestedMission) {
            out.add(node)
            if (expandedIds.contains(node.id)) {
                node.children.forEach { visit(it) }
            }
        }
        nodes.forEach { visit(it) }
        return out
    }
}

object OrbContinuation {
    fun parentSessionId(row: OrbRow): String? =
        row.str("parent_session_id", "parentSessionId", "continued_from_session_id", "continuedFromSessionId")

    fun chainIds(forId: String, rows: List<OrbRow>): List<String> {
        if (rows.isEmpty()) return listOf(forId)
        val parentById = mutableMapOf<String, String>()
        val childrenByParent = mutableMapOf<String, MutableList<String>>()
        for (row in rows) {
            val parent = parentSessionId(row)
            if (!parent.isNullOrEmpty() && parent != row.id) {
                parentById[row.id] = parent
                childrenByParent.getOrPut(parent) { mutableListOf() }.add(row.id)
            }
        }
        var root = forId
        var seen = setOf(root)
        while (true) {
            val next = parentById[root] ?: break
            if (seen.contains(next)) break
            seen = seen + next
            root = next
        }
        val ordered = mutableListOf<String>()
        var visited = emptySet<String>()
        fun walk(id: String) {
            if (visited.contains(id)) return
            visited = visited + id
            ordered.add(id)
            for (child in childrenByParent[id] ?: emptyList()) {
                walk(child)
            }
        }
        walk(root)
        return if (ordered.contains(forId)) ordered else listOf(forId)
    }

    fun collapse(rows: List<OrbRow>): List<OrbRow> {
        val byId = rows.associateBy { it.id }
        val superseded = mutableSetOf<String>()
        val rootStartedAt = mutableMapOf<String, String>()

        for (row in rows) {
            val parent = parentSessionId(row)
            if (!parent.isNullOrEmpty() && parent != row.id && byId.containsKey(parent)) {
                superseded.add(parent)
            }
        }

        for (row in rows) {
            val chain = chainIds(row.id, rows)
            val firstId = chain.firstOrNull()
            val firstRow = firstId?.let { byId[it] }
            val start = firstRow?.str("started_at", "created_at")
            if (start != null) {
                rootStartedAt[row.id] = start
            }
        }

        return rows.mapNotNull { row ->
            if (superseded.contains(row.id)) return@mapNotNull null
            val chain = chainIds(row.id, rows)
            if (chain.size <= 1) return@mapNotNull row
            val raw = row.raw.toMutableMap()
            raw["_continuation_chain_ids"] = chain
            raw["_continuation_count"] = chain.size
            rootStartedAt[row.id]?.let { raw.putIfAbsent("root_started_at", it) }
            OrbRow(row.id, raw)
        }
    }
}

object OrbDisk {
    private var appContext: Context? = null
    private var accountScope: String = "anonymous"

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    @Synchronized
    fun setAccountScope(baseURL: String, token: String?) {
        val trimmedBase = baseURL.trim().lowercase()
        val trimmedToken = (token ?: "").trim()
        if (trimmedBase.isEmpty() && trimmedToken.isEmpty()) {
            accountScope = "anonymous"
            return
        }
        val material = "$trimmedBase|${trimmedToken.take(24)}|${trimmedToken.takeLast(16)}"
        val digest = MessageDigest.getInstance("SHA-256").digest(material.toByteArray())
        accountScope = digest.take(10).joinToString("") { "%02x".format(it) }
    }

    @Synchronized
    private fun currentScope(): String = accountScope

    private fun rootDir(): File {
        val ctx = appContext ?: return File(System.getProperty("java.io.tmpdir"), "Orb")
        val dir = File(ctx.filesDir, "Orb")
        if (!dir.exists()) dir.mkdirs()
        return dir
    }

    private fun file(key: String): File {
        val scope = currentScope()
        val safe = "${scope}_$key".replace(Regex("[^a-zA-Z0-9._-]"), "_")
        return File(rootDir(), "$safe.json")
    }

    fun read(key: String): Any? {
        return try {
            val f = file(key)
            if (!f.exists()) return null
            OrbJSON.parse(f.readBytes())
        } catch (_: Throwable) {
            null
        }
    }

    fun write(key: String, value: Any?) {
        try {
            val f = file(key)
            f.writeText(OrbJSON.stringify(value))
        } catch (_: Throwable) {
        }
    }

    fun clearCurrentScope() {
        try {
            val prefix = "${currentScope()}_"
            rootDir().listFiles()?.forEach { f ->
                if (f.name.startsWith(prefix)) f.delete()
            }
        } catch (_: Throwable) {
        }
    }
}

object OrbReadCache {
    private val rowsByKey = ConcurrentHashMap<String, List<OrbRow>>()
    private val dictByKey = ConcurrentHashMap<String, OrbDict>()

    fun clearMemory() {
        rowsByKey.clear()
        dictByKey.clear()
    }

    fun loadRows(key: String): List<OrbRow> {
        rowsByKey[key]?.let { return it }
        val raw = OrbDisk.read(key)
        val rows = OrbJSON.dictList(raw).map { OrbRow(it) }
        if (rows.isNotEmpty()) {
            rowsByKey[key] = rows
        }
        return rows
    }

    fun hasRowsInMemory(key: String): Boolean = rowsByKey.containsKey(key)

    fun saveRowsMemoryOnly(key: String, rows: List<OrbRow>) {
        rowsByKey[key] = rows
    }

    fun saveRows(key: String, rows: List<OrbRow>) {
        rowsByKey[key] = rows
        val raw = rows.map { it.raw }
        CoroutineScope(Dispatchers.IO).launch {
            OrbDisk.write(key, raw)
        }
    }

    fun loadDict(key: String): OrbDict? {
        dictByKey[key]?.let { return it }
        val dict = OrbJSON.dict(OrbDisk.read(key))
        if (dict != null) {
            dictByKey[key] = dict
        }
        return dict
    }

    fun saveDict(key: String, dict: OrbDict) {
        dictByKey[key] = dict
        CoroutineScope(Dispatchers.IO).launch {
            OrbDisk.write(key, dict)
        }
    }
}

class OrbError(override val message: String, val status: Int? = null) : Exception(message)

object OrbKeychain {
    private const val PREFS_NAME = "orb_secure_store"
    private var prefs: SharedPreferences? = null

    fun init(context: Context) {
        if (prefs == null) {
            prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        }
    }

    fun read(service: String, account: String): String? {
        val p = prefs ?: return null
        val key = "$service|$account"
        val stored = p.getString(key, null) ?: return null
        return TokenCrypto.decrypt(stored) ?: stored.takeIf { !it.startsWith("v1:") }
    }

    fun write(service: String, account: String, value: String?) {
        val p = prefs ?: return
        val key = "$service|$account"
        if (value.isNullOrEmpty()) {
            p.edit().remove(key).apply()
        } else {
            val encrypted = TokenCrypto.encrypt(value) ?: value
            p.edit().putString(key, encrypted).apply()
        }
    }
}

class OrbCore private constructor(context: Context) {
    companion object {
        private const val KEYCHAIN_SERVICE = "md.thomas.orb.core"
        private const val CREDENTIALS_SERVICE = "md.thomas.orb.credentials"
        private const val PREFS_NAME = "orb_core_prefs"
        private const val BASE_URL_KEY = "orb.baseURL"
        private const val TOKEN_FALLBACK_KEY = "orb.tokenFallback"

        @Volatile
        private var instance: OrbCore? = null

        fun getInstance(context: Context): OrbCore {
            return instance ?: synchronized(this) {
                instance ?: OrbCore(context.applicationContext).also { instance = it }
            }
        }

        val shared: OrbCore
            get() = checkNotNull(instance) { "OrbCore.getInstance(context) must be called first" }
    }

    private val prefs: SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    val httpClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(45, TimeUnit.SECONDS)
        .writeTimeout(45, TimeUnit.SECONDS)
        .build()

    val sseHttpClient: OkHttpClient = httpClient.newBuilder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .retryOnConnectionFailure(true)
        .build()

    private val _baseURL = MutableStateFlow("")
    val baseURLFlow: StateFlow<String> = _baseURL.asStateFlow()
    var baseURL: String
        get() = _baseURL.value
        set(value) {
            _baseURL.value = value
            persistSession()
        }

    private val _token = MutableStateFlow<String?>(null)
    val tokenFlow: StateFlow<String?> = _token.asStateFlow()
    var token: String?
        get() = _token.value
        set(value) {
            _token.value = value
            persistSession()
        }

    private val _projects = MutableStateFlow<List<OrbRow>>(emptyList())
    val projects: StateFlow<List<OrbRow>> = _projects.asStateFlow()

    private val _missions = MutableStateFlow<List<OrbRow>>(emptyList())
    val missions: StateFlow<List<OrbRow>> = _missions.asStateFlow()

    private val _hermesSessions = MutableStateFlow<List<OrbRow>>(emptyList())
    val hermesSessions: StateFlow<List<OrbRow>> = _hermesSessions.asStateFlow()

    private val _workspaces = MutableStateFlow<List<OrbRow>>(emptyList())
    val workspaces: StateFlow<List<OrbRow>> = _workspaces.asStateFlow()

    private val _backends = MutableStateFlow<List<OrbRow>>(emptyList())
    val backends: StateFlow<List<OrbRow>> = _backends.asStateFlow()

    private val _repositories = MutableStateFlow<List<OrbRow>>(emptyList())
    val repositories: StateFlow<List<OrbRow>> = _repositories.asStateFlow()

    private val _providers = MutableStateFlow<List<OrbRow>>(emptyList())
    val providers: StateFlow<List<OrbRow>> = _providers.asStateFlow()

    private val _providerPortfolio = MutableStateFlow<OrbDict>(emptyMap())
    val providerPortfolio: StateFlow<OrbDict> = _providerPortfolio.asStateFlow()

    private val _nodes = MutableStateFlow<List<OrbRow>>(emptyList())
    val nodes: StateFlow<List<OrbRow>> = _nodes.asStateFlow()

    private val _fleetSummary = MutableStateFlow<OrbDict>(emptyMap())
    val fleetSummary: StateFlow<OrbDict> = _fleetSummary.asStateFlow()

    private val _assistantStatus = MutableStateFlow<OrbDict>(emptyMap())
    val assistantStatus: StateFlow<OrbDict> = _assistantStatus.asStateFlow()

    private val _remoteTargets = MutableStateFlow<List<OrbRow>>(emptyList())
    val remoteTargets: StateFlow<List<OrbRow>> = _remoteTargets.asStateFlow()

    private val _pendingProjectFocus = MutableStateFlow<String?>(null)
    val pendingProjectFocus: StateFlow<String?> = _pendingProjectFocus.asStateFlow()

    private val _pendingMissionFocus = MutableStateFlow<String?>(null)
    val pendingMissionFocus: StateFlow<String?> = _pendingMissionFocus.asStateFlow()

    private val _pendingDocumentsFocus = MutableStateFlow<String?>(null)
    val pendingDocumentsFocus: StateFlow<String?> = _pendingDocumentsFocus.asStateFlow()

    private val _pendingInboxOpen = MutableStateFlow(false)
    val pendingInboxOpen: StateFlow<Boolean> = _pendingInboxOpen.asStateFlow()

    private val _pendingSettingsOpen = MutableStateFlow(false)
    val pendingSettingsOpen: StateFlow<Boolean> = _pendingSettingsOpen.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _hasLoadedSuccessfully = MutableStateFlow(false)
    val hasLoadedSuccessfully: StateFlow<Boolean> = _hasLoadedSuccessfully.asStateFlow()

    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    private val _lastErrorLog = MutableStateFlow<String?>(null)
    val lastErrorLog: StateFlow<String?> = _lastErrorLog.asStateFlow()

    init {
        OrbDisk.init(context)
        OrbSharedInboxState.init(context)
        OrbKeychain.init(context)
        val savedBase = prefs.getString(BASE_URL_KEY, null) ?: ""
        val cleanBase = savedBase.trim().trimEnd('/')
        _baseURL.value = cleanBase
        val loadedToken = if (cleanBase.isEmpty()) {
            null
        } else {
            OrbKeychain.read(KEYCHAIN_SERVICE, cleanBase)
                ?: prefs.getString("$TOKEN_FALLBACK_KEY.$cleanBase", null)
        }
        _token.value = loadedToken
        OrbDisk.setAccountScope(cleanBase, loadedToken)
        scope.launch(Dispatchers.IO) {
            loadCachedSnapshots()
        }
        startLiveRefreshLoop()
    }

    fun configureSession(baseURL: String, token: String?, password: String? = null) {
        val cleanBase = baseURL.trim().trimEnd('/')
        val cleanToken = token?.trim()?.takeIf { it.isNotEmpty() }
        val previousBase = _baseURL.value.trim().trimEnd('/')
        val previousToken = _token.value?.trim()
        val accountChanged = previousBase != cleanBase || previousToken != cleanToken

        OrbDisk.setAccountScope(cleanBase, cleanToken)
        if (accountChanged) {
            OrbReadCache.clearMemory()
            resetInMemoryAccountState()
            scope.launch(Dispatchers.IO) {
                loadCachedSnapshots()
            }
        }
        _baseURL.value = cleanBase
        _token.value = cleanToken
        if (!password.isNullOrEmpty() && cleanBase.isNotEmpty()) {
            OrbKeychain.write(CREDENTIALS_SERVICE, cleanBase, password)
        }
        persistSession()
    }

    fun clearSession() {
        val cleanBase = _baseURL.value.trim().trimEnd('/')
        if (cleanBase.isNotEmpty()) {
            OrbKeychain.write(KEYCHAIN_SERVICE, cleanBase, null)
            OrbKeychain.write(CREDENTIALS_SERVICE, cleanBase, null)
            prefs.edit().remove("$TOKEN_FALLBACK_KEY.$cleanBase").apply()
        }
        OrbDisk.clearCurrentScope()
        OrbReadCache.clearMemory()
        _token.value = null
        OrbDisk.setAccountScope(cleanBase, null)
        resetInMemoryAccountState()
        persistSession()
    }

    fun requestProjectFocus(slugOrName: String) {
        val trimmed = slugOrName.trim()
        if (trimmed.isNotEmpty()) {
            _pendingProjectFocus.value = trimmed
        }
    }

    fun consumeProjectFocus(): String? {
        val v = _pendingProjectFocus.value
        _pendingProjectFocus.value = null
        return v
    }

    fun requestInboxOpen() {
        _pendingInboxOpen.value = true
    }

    fun consumeInboxOpen(): Boolean {
        val v = _pendingInboxOpen.value
        _pendingInboxOpen.value = false
        return v
    }

    fun requestMissionFocus(missionId: String) {
        val trimmed = missionId.trim()
        if (trimmed.isNotEmpty()) {
            _pendingMissionFocus.value = trimmed
        }
    }

    fun consumeMissionFocus(): String? {
        val v = _pendingMissionFocus.value
        _pendingMissionFocus.value = null
        return v
    }

    fun requestDocumentsFocus(projectSlug: String) {
        val trimmed = projectSlug.trim()
        if (trimmed.isNotEmpty()) {
            _pendingDocumentsFocus.value = trimmed
        }
    }

    fun consumeDocumentsFocus(): String? {
        val v = _pendingDocumentsFocus.value
        _pendingDocumentsFocus.value = null
        return v
    }

    fun requestSettingsOpen() {
        _pendingSettingsOpen.value = true
    }

    fun consumeSettingsOpen(): Boolean {
        val v = _pendingSettingsOpen.value
        _pendingSettingsOpen.value = false
        return v
    }

    fun setError(message: String?, log: String? = null) {
        _lastError.value = message
        _lastErrorLog.value = log
    }

    private fun resetInMemoryAccountState() {
        _projects.value = emptyList()
        _missions.value = emptyList()
        _hermesSessions.value = emptyList()
        _workspaces.value = emptyList()
        _backends.value = emptyList()
        _repositories.value = emptyList()
        _providers.value = emptyList()
        _providerPortfolio.value = emptyMap()
        _nodes.value = emptyList()
        _fleetSummary.value = emptyMap()
        _assistantStatus.value = emptyMap()
        _remoteTargets.value = emptyList()
        _hasLoadedSuccessfully.value = false
        _lastError.value = null
        _lastErrorLog.value = null
    }

    private fun seedMissionAndProjectCaches(missionsList: List<OrbRow>) {
        val byProject = mutableMapOf<String, MutableList<OrbRow>>()
        for (m in missionsList) {
            val tags = OrbJSON.strList(m.raw, "tags")
            if (tags.any { it.startsWith("btw-parent:") }) continue
            val hist = m.rows("history")
            if (hist.isNotEmpty()) {
                OrbReadCache.saveRowsMemoryOnly("mission_msgs_${m.id}", hist)
            }
            val projTag = tags.firstOrNull { it.startsWith("project:") }?.removePrefix("project:")
            val proj = (m.str("project", "project_slug") ?: projTag)?.lowercase()?.trim()
            if (!proj.isNullOrEmpty()) {
                byProject.getOrPut(proj) { mutableListOf() }.add(m)
            }
        }
        for ((proj, rows) in byProject) {
            if (!OrbReadCache.hasRowsInMemory("project_missions_$proj")) {
                OrbReadCache.saveRowsMemoryOnly("project_missions_$proj", rows)
            }
        }
    }

    private fun loadCachedSnapshots() {
        val p = OrbJSON.dictList(OrbDisk.read("projects")).map { OrbRow(it) }
        val m = OrbJSON.dictList(OrbDisk.read("missions")).map { OrbRow(it) }
        val h = OrbJSON.dictList(OrbDisk.read("hermes_sessions")).map { OrbRow(it) }
        val w = OrbJSON.dictList(OrbDisk.read("workspaces")).map { OrbRow(it) }
        val b = OrbJSON.dictList(OrbDisk.read("backends")).map { OrbRow(it) }
        val r = OrbJSON.dictList(OrbDisk.read("repositories")).map { OrbRow(it) }
        val pr = OrbJSON.dictList(OrbDisk.read("providers")).map { OrbRow(it) }
        val n = OrbJSON.dictList(OrbDisk.read("nodes")).map { OrbRow(it) }
        val rt = OrbJSON.dictList(OrbDisk.read("remote_targets")).map { OrbRow(it) }
        seedMissionAndProjectCaches(m)
        _projects.value = p
        _missions.value = m
        _hermesSessions.value = h
        _workspaces.value = w
        _backends.value = b
        _repositories.value = r
        _providers.value = pr
        _nodes.value = n
        _remoteTargets.value = rt
        if (p.isNotEmpty() || m.isNotEmpty() || h.isNotEmpty()) {
            _hasLoadedSuccessfully.value = true
        }
    }

    private fun persistSession() {
        val cleanBase = _baseURL.value.trim().trimEnd('/')
        val cleanToken = _token.value?.trim()?.takeIf { it.isNotEmpty() }
        OrbDisk.setAccountScope(cleanBase, cleanToken)
        prefs.edit().putString(BASE_URL_KEY, cleanBase).apply()
        if (cleanBase.isNotEmpty()) {
            OrbKeychain.write(KEYCHAIN_SERVICE, cleanBase, cleanToken)
            if (cleanToken == null) {
                prefs.edit().remove("$TOKEN_FALLBACK_KEY.$cleanBase").apply()
            } else {
                prefs.edit().putString("$TOKEN_FALLBACK_KEY.$cleanBase", cleanToken).apply()
            }
        }
    }

    val isConfigured: Boolean
        get() = _baseURL.value.trim().isNotEmpty()

    private fun startLiveRefreshLoop() {
        scope.launch {
            while (isActive) {
                delay(6_000L)
                if (!isConfigured || _isLoading.value) continue
                refreshMissionsQuietly()
            }
        }
    }

    suspend fun refreshMissionsQuietly() {
        try {
            coroutineScope {
                val mDeferred = async { fetchRows("/api/control/missions?limit=100&all=true", null) }
                val pDeferred = async { fetchRows("/api/projects", "projects") }
                val m = mDeferred.await()
                val p = pDeferred.await()
                _missions.value = m
                _projects.value = p
                _hasLoadedSuccessfully.value = true
                withContext(Dispatchers.IO) {
                    seedMissionAndProjectCaches(m)
                    OrbDisk.write("missions", m.map { it.raw })
                    OrbDisk.write("projects", p.map { it.raw })
                }
            }
        } catch (_: Throwable) {
        }
    }

    suspend fun refreshAll() {
        if (!isConfigured) return
        _isLoading.value = true
        _lastError.value = null
        _lastErrorLog.value = null

        coroutineScope {
            val pTask = async { runCatching { fetchRows("/api/projects", "projects") } }
            val mTask = async { runCatching { fetchRows("/api/control/missions?limit=100&all=true", null) } }
            val hTask = async { runCatching { fetchRows("/api/assistant/hermes/sessions?limit=100", "sessions") } }
            val wTask = async { runCatching { fetchRows("/api/workspaces", null) } }
            val bTask = async { runCatching { fetchRows("/api/backends", null) } }
            val rTask = async { runCatching { fetchRows("/api/repos", null) } }
            val prTask = async { runCatching { fetchRows("/api/ai/providers", "providers") } }
            val nTask = async { runCatching { fetchDict("/api/remote-nodes") } }
            val aTask = async { runCatching { fetchDict("/api/assistant/status") } }
            val rtTask = async { runCatching { fetchRows("/api/settings/ssh-hosts", null) } }

            val pResult = pTask.await()
            val mResult = mTask.await()
            var anyCoreSuccess = false

            pResult.onSuccess { p ->
                _projects.value = p
                anyCoreSuccess = true
                launch(Dispatchers.IO) { OrbDisk.write("projects", p.map { it.raw }) }
            }
            mResult.onSuccess { m ->
                _missions.value = m
                anyCoreSuccess = true
                launch(Dispatchers.IO) {
                    seedMissionAndProjectCaches(m)
                    OrbDisk.write("missions", m.map { it.raw })
                    for (row in m.take(5)) {
                        val evKey = "mission_events_${row.id}"
                        if (OrbReadCache.loadRows(evKey).isEmpty()) {
                            val evs = runCatching {
                                fetchRows("/api/control/missions/${encodeComponent(row.id)}/events?limit=150", "events")
                            }.getOrDefault(emptyList())
                            if (evs.isNotEmpty()) {
                                OrbReadCache.saveRows(evKey, evs)
                            }
                        }
                    }
                }
            }
            hTask.await().onSuccess { h ->
                _hermesSessions.value = h
                anyCoreSuccess = true
                launch(Dispatchers.IO) { OrbDisk.write("hermes_sessions", h.map { it.raw }) }
            }
            wTask.await().onSuccess { w ->
                _workspaces.value = w
                launch(Dispatchers.IO) { OrbDisk.write("workspaces", w.map { it.raw }) }
            }
            bTask.await().onSuccess { b ->
                _backends.value = b
                launch(Dispatchers.IO) { OrbDisk.write("backends", b.map { it.raw }) }
            }
            rTask.await().onSuccess { r ->
                _repositories.value = r
                launch(Dispatchers.IO) { OrbDisk.write("repositories", r.map { it.raw }) }
            }
            prTask.await().onSuccess { rows ->
                _providers.value = rows
                launch(Dispatchers.IO) { OrbDisk.write("providers", rows.map { it.raw }) }
            }
            nTask.await().onSuccess { nodesObj ->
                OrbJSON.dict(nodesObj["summary"])?.let { _fleetSummary.value = it }
                val rows = OrbJSON.dictList(nodesObj["nodes"]).map { OrbRow(it) }
                _nodes.value = rows
                launch(Dispatchers.IO) { OrbDisk.write("nodes", rows.map { it.raw }) }
            }
            aTask.await().onSuccess { status ->
                _assistantStatus.value = status
            }
            rtTask.await().onSuccess { rows ->
                _remoteTargets.value = rows
                launch(Dispatchers.IO) { OrbDisk.write("remote_targets", rows.map { it.raw }) }
            }

            if (anyCoreSuccess) {
                _hasLoadedSuccessfully.value = true
                _lastError.value = null
                _lastErrorLog.value = null
            } else {
                val err = pResult.exceptionOrNull() ?: mResult.exceptionOrNull()
                if (err != null) {
                    _lastError.value = err.message ?: "Request failed"
                    _lastErrorLog.value = "baseURL=${_baseURL.value}\nerror=${err.message}"
                }
            }
        }
        _isLoading.value = false
    }

    fun makeURL(path: String): String {
        val base = _baseURL.value.trim().trimEnd('/')
        if (base.isEmpty()) throw OrbError("No server URL configured")
        val normalized = if (path.startsWith("/")) path else "/$path"
        return "$base$normalized"
    }

    suspend fun request(
        path: String,
        method: String = "GET",
        body: Any? = null,
        headers: Map<String, String> = emptyMap(),
        allowAuthRetry: Boolean = true
    ): Any? = withContext(Dispatchers.IO) {
        val url = makeURL(path)
        val reqBuilder = Request.Builder().url(url)
        reqBuilder.header("Accept", "application/json")
        val cleanToken = _token.value?.trim()?.takeIf { it.isNotEmpty() }
        if (cleanToken != null) {
            reqBuilder.header("Authorization", "Bearer $cleanToken")
        }
        for ((k, v) in headers) {
            reqBuilder.header(k, v)
        }
        val requestBody = when {
            body != null -> {
                val jsonText = OrbJSON.stringify(body)
                jsonText.toRequestBody("application/json; charset=utf-8".toMediaType())
            }
            method.uppercase() in setOf("POST", "PUT", "PATCH") -> {
                "".toRequestBody("application/json; charset=utf-8".toMediaType())
            }
            else -> null
        }
        reqBuilder.method(method.uppercase(), requestBody)

        val response = httpClient.newCall(reqBuilder.build()).execute()
        val code = response.code
        val bytes = response.body?.bytes() ?: ByteArray(0)
        response.close()

        if (code == 401 && allowAuthRetry && path != "/api/auth/login") {
            if (renewSessionFromSavedCredentials()) {
                return@withContext request(
                    path = path,
                    method = method,
                    body = body,
                    headers = headers,
                    allowAuthRetry = false
                )
            }
        }

        if (code !in 200..299) {
            val raw = bytes.decodeToString()
            val parsed = OrbJSON.dict(OrbJSON.parse(bytes))
            val message = OrbJSON.str(parsed, "error", "message", "detail")
                ?: if (raw.isEmpty()) "HTTP $code" else raw.take(240)
            _lastErrorLog.value = "$method $path -> HTTP $code\n$raw"
            throw OrbError(message, status = code)
        }
        if (bytes.isEmpty()) return@withContext emptyMap<String, Any?>()
        OrbJSON.parse(bytes) ?: emptyMap<String, Any?>()
    }

    private suspend fun renewSessionFromSavedCredentials(): Boolean = withContext(Dispatchers.IO) {
        val cleanBase = _baseURL.value.trim().trimEnd('/')
        if (cleanBase.isEmpty()) return@withContext false
        val password = OrbKeychain.read(CREDENTIALS_SERVICE, cleanBase)?.trim()?.takeIf { it.isNotEmpty() }
            ?: return@withContext false
        try {
            val url = makeURL("/api/auth/login")
            val body = OrbJSON.stringify(mapOf("password" to password))
                .toRequestBody("application/json; charset=utf-8".toMediaType())
            val req = Request.Builder()
                .url(url)
                .post(body)
                .header("Accept", "application/json")
                .build()
            val resp = httpClient.newCall(req).execute()
            val code = resp.code
            val bytes = resp.body?.bytes() ?: ByteArray(0)
            resp.close()
            if (code !in 200..299) return@withContext false
            val dict = OrbJSON.dict(OrbJSON.parse(bytes))
            val newToken = OrbJSON.str(dict, "token")?.trim()?.takeIf { it.isNotEmpty() }
                ?: return@withContext false
            withContext(Dispatchers.Main) {
                _token.value = newToken
                persistSession()
            }
            true
        } catch (_: Throwable) {
            false
        }
    }

    suspend fun fetchDict(path: String): OrbDict {
        val res = request(path)
        return OrbJSON.dict(res) ?: emptyMap()
    }

    suspend fun fetchRows(path: String, key: String?): List<OrbRow> {
        val value = request(path)
        if (key != null) {
            val dict = OrbJSON.dict(value)
            if (dict != null) {
                return OrbJSON.dictList(dict[key]).map { OrbRow(it) }
            }
        }
        val list = OrbJSON.dictList(value)
        if (list.isNotEmpty()) {
            return list.map { OrbRow(it) }
        }
        val dict = OrbJSON.dict(value)
        if (dict != null) {
            for (candidate in listOf("items", "missions", "projects", "sessions", "workspaces", "backends", "repos", "nodes", "events", "messages", "files", "entries")) {
                val items = OrbJSON.dictList(dict[candidate])
                if (items.isNotEmpty()) {
                    return items.map { OrbRow(it) }
                }
            }
        }
        return emptyList()
    }

    fun openSSE(
        path: String,
        onEvent: (eventType: String?, data: String) -> Unit,
        onClosed: (Throwable?) -> Unit = {}
    ): EventSource {
        val url = makeURL(path)
        val reqBuilder = Request.Builder()
            .url(url)
            .header("Accept", "text/event-stream")
            .header("Cache-Control", "no-cache")
        _token.value?.trim()?.takeIf { it.isNotEmpty() }?.let { t ->
            reqBuilder.header("Authorization", "Bearer $t")
        }
        return EventSources.createFactory(sseHttpClient).newEventSource(
            reqBuilder.build(),
            object : EventSourceListener() {
                override fun onEvent(
                    eventSource: EventSource,
                    id: String?,
                    type: String?,
                    data: String
                ) {
                    onEvent(type, data)
                }

                override fun onClosed(eventSource: EventSource) {
                    onClosed(null)
                }

                override fun onFailure(
                    eventSource: EventSource,
                    t: Throwable?,
                    response: Response?
                ) {
                    onClosed(t)
                }
            }
        )
    }

    fun encodeComponent(value: String): String =
        URLEncoder.encode(value, Charsets.UTF_8.name()).replace("+", "%20")
}
