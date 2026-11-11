package sh.sandboxed.dashboard.orb

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
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
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
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
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.sse.EventSource
import okhttp3.sse.EventSourceListener
import okhttp3.sse.EventSources
import sh.sandboxed.dashboard.util.TokenCrypto
import java.io.File
import java.io.IOException
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

    fun relative(raw: String?, nowMs: Long = System.currentTimeMillis()): String {
        val epochMs = dateEpochMs(raw) ?: return ""
        return relativeSeconds(maxOf(0L, (nowMs - epochMs) / 1000L))
    }

    /** Elapsed seconds -> "now" / "Nm" (min 1) / "Nh" / "Nd" / "Nw"; see shared/orb-spec/fixtures/relative-time.json. */
    fun relativeSeconds(elapsed: Long): String =
        OrbKernel.relativeTimeString(elapsed.coerceIn(0L, Int.MAX_VALUE.toLong()))

    fun cleanTitle(raw: String?): String {
        val value = raw?.trim()?.takeIf { it.isNotEmpty() }?.let { OrbSkillSlash.skillPreview(it) } ?: return "Untitled"
        val firstLine = value.lineSequence()
            .map { it.trim() }
            .firstOrNull { it.isNotEmpty() } ?: "Untitled"
        val stripped = firstLine.replace(Regex("^[#*\\-`>\\s]+"), "")
        return if (stripped.isEmpty()) firstLine else stripped
    }
}

@Immutable
data class OrbRow(
    val id: String,
    val raw: OrbDict
) {
    constructor(raw: OrbDict, fallback: String = UUID.randomUUID().toString()) : this(
        id = OrbJSON.str(raw, "id", "slug", "session_id", "mission_id", "name", "key", "path") ?: fallback,
        raw = raw
    )

    // Precompute a compact revision stamp once per immutable row so Compose structural
    // equality checks stay O(1) instead of recursively walking nested JSON maps/lists.
    private val revisionStamp: Int = computeRevisionStamp(raw)

    fun str(vararg keys: String): String? = OrbJSON.str(raw, *keys)
    fun int(vararg keys: String): Int? = OrbJSON.int(raw, *keys)
    fun double(vararg keys: String): Double? = OrbJSON.double(raw, *keys)
    fun bool(vararg keys: String): Boolean? = OrbJSON.bool(raw, *keys)
    fun dict(key: String): OrbDict? = OrbJSON.dict(raw[key])
    fun rows(key: String): List<OrbRow> = OrbJSON.dictList(raw[key]).mapIndexed { idx, item ->
        OrbRow(item, "$id-$key-$idx")
    }

    val isParticipant: Boolean
        get() = str("viewer_role") == "participant"

    val ownerUsername: String?
        get() = str("owner_username")?.trim()?.takeIf { it.isNotEmpty() }

    fun isClientPlacement(): Boolean {
        val pk = str("placement_kind") ?: ""
        return pk == "client" || pk.startsWith("client:")
    }

    fun supersededSuccessorId(): String? =
        str("superseded_by_mission_id")?.trim()?.takeIf { it.isNotEmpty() }

    fun hasTypedSuperseded(): Boolean {
        val st = (str("status") ?: "").trim().lowercase()
        return st == "superseded" || supersededSuccessorId() != null
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is OrbRow) return false
        if (id != other.id || revisionStamp != other.revisionStamp || raw.size != other.raw.size) return false
        return raw === other.raw || raw == other.raw
    }

    override fun hashCode(): Int = 31 * id.hashCode() + revisionStamp

    companion object {
        private fun computeRevisionStamp(raw: OrbDict): Int {
            var h = raw.size
            h = 31 * h + (raw["updated_at"]?.hashCode() ?: 0)
            h = 31 * h + (raw["status"]?.hashCode() ?: raw["state"]?.hashCode() ?: 0)
            h = 31 * h + (raw["title"]?.hashCode() ?: raw["name"]?.hashCode() ?: 0)
            h = 31 * h + (raw["sequence"]?.hashCode() ?: 0)
            h = 31 * h + (raw["first_viewed_at"]?.hashCode() ?: 0)
            h = 31 * h + (raw["enabled"]?.hashCode() ?: 0)
            h = 31 * h + (raw["effective_enabled"]?.hashCode() ?: 0)
            h = 31 * h + (raw["viewer_role"]?.hashCode() ?: 0)
            h = 31 * h + (raw["project"]?.hashCode() ?: 0)
            h = 31 * h + (raw["folder"]?.hashCode() ?: 0)
            h = 31 * h + (raw["placement_revision"]?.hashCode() ?: 0)
            return h
        }
    }
}

data class OrbPlacementCommitItem(
    val missionId: String,
    val project: String?,
    val folder: String,
    val placementRevision: Long,
    val explicitProject: Boolean = false,
    val isPreview: Boolean = false
)

class OrbApprovalTransferConfirmationException(
    override val message: String,
    val targetProject: String,
    val activeGrants: List<ActiveGrant>,
    val pendingRequests: List<PendingRequest>
) : Exception(message) {
    data class ActiveGrant(val id: String, val secretName: String, val sourceProject: String?)
    data class PendingRequest(val id: String, val secretName: String, val operation: String)

    companion object {
        fun parse(error: Throwable): OrbApprovalTransferConfirmationException? {
            val http = error as? OrbError ?: return null
            if (http.status != 409 || http.body.isNullOrBlank()) return null
            val json = OrbJSON.dict(OrbJSON.parse(http.body)) ?: return null
            if (OrbJSON.str(json, "code") != "approval_transfer_confirmation_required") return null
            val grantsRaw = OrbJSON.dictList(json["active_grants"]).ifEmpty { OrbJSON.dictList(json["grants"]) }
            val grants = grantsRaw.map { g ->
                ActiveGrant(
                    id = OrbJSON.str(g, "id") ?: "",
                    secretName = OrbJSON.str(g, "secret_name") ?: "",
                    sourceProject = OrbJSON.str(g, "source_project")
                )
            }
            val pendingRaw = OrbJSON.dictList(json["pending_requests"]).ifEmpty { OrbJSON.dictList(json["pending"]) }
            val pending = pendingRaw.map { p ->
                PendingRequest(
                    id = OrbJSON.str(p, "id") ?: "",
                    secretName = OrbJSON.str(p, "secret_name") ?: "",
                    operation = OrbJSON.str(p, "operation") ?: ""
                )
            }
            val msg = OrbJSON.str(json, "error", "message")
                ?: "Secret approvals on this conversation will be affected by moving to another project."
            return OrbApprovalTransferConfirmationException(
                message = msg,
                targetProject = OrbJSON.str(json, "target_project") ?: "",
                activeGrants = grants,
                pendingRequests = pending
            )
        }
    }
}

data class OrbNestedMission(
    val mission: OrbRow,
    val children: List<OrbNestedMission>,
    val depth: Int,
    /** An earlier version (fork) of the conversation it is listed in. */
    val version: Boolean = false
) {
    val id: String get() = mission.id
    private val launched: List<OrbNestedMission> get() = children.filterNot { it.version }
    val childCount: Int get() = launched.size + launched.sumOf { it.childCount }
    val runningChildCount: Int
        get() = launched.count { OrbMissionTree.isLive(it.mission) } +
            launched.sumOf { it.runningChildCount }
    val versionCount: Int get() = children.count { it.version }
}

object OrbMissionTree {
    private const val LEGACY_FORK_SUFFIX = " · fork"

    /** The conversation this one was forked from (a `fork-of:` tag, or an older fork stored as a child). */
    fun forkSource(mission: OrbRow): String? {
        OrbJSON.strList(mission.raw, "tags").firstOrNull { it.startsWith("fork-of:") }?.let { return it.drop(8) }
        val parent = mission.str("parent_mission_id")
        return if (!parent.isNullOrEmpty() && (mission.str("title") ?: "").endsWith(LEGACY_FORK_SUFFIX)) parent else null
    }

    /** Forks share the conversation's name. */
    fun forkTitle(title: String): String = title.removeSuffix(LEGACY_FORK_SUFFIX)

    data class Seen(
        val title: String? = null,
        val project: String? = null,
        val status: String? = null,
        val backend: String? = null
    )

    private data class CachedAncestor(val row: OrbRow, val fetchedAtMs: Long)

    const val ANCESTOR_TTL_MS = 60_000L
    const val RECENT_OPEN_MS = 7L * 24 * 60 * 60 * 1000
    private val LIVE_OPEN_STATES = setOf(
        "active", "running", "pending", "queued", "awaiting_user", "resuming", "starting", "waiting_background"
    )
    private val RECENT_OPEN_STATES = setOf("interrupted", "failed", "paused", "blocked")

    /** Parent links and `/btw` subtree markers are sticky (docs/specs/sidebar-hierarchy.md):
     * a payload that omits the link never moves a known child to the root or leaks a `/btw` worker. */
    private val knownParents = java.util.concurrent.ConcurrentHashMap<String, String>()
    private val knownBtw = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    private val seenFacts = java.util.concurrent.ConcurrentHashMap<String, Seen>()
    private val ancestorCache = java.util.concurrent.ConcurrentHashMap<String, CachedAncestor>()
    private val goneIds = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    data class PlacementState(
        val project: String,
        val folder: String,
        val revision: Long,
        val pendingOpId: Int = 0,
        val optimisticProject: String? = null,
        val optimisticFolder: String? = null
    )

    val localClientId: String = java.util.UUID.randomUUID().toString()
    private val placements = java.util.concurrent.ConcurrentHashMap<String, PlacementState>()
    private val stagedRows = java.util.concurrent.ConcurrentHashMap<String, OrbRow>()
    private val nextPlacementOpId = java.util.concurrent.atomic.AtomicInteger(0)

    fun resolveLocalAckOpId(clientOpId: Int, clientId: String?): Int {
        if (clientOpId <= 0 || clientId.isNullOrEmpty()) return 0
        return if (clientId == localClientId) clientOpId else 0
    }

    fun retainStagedRows(rows: Collection<OrbRow>) {
        if (rows.isEmpty()) return
        if (stagedRows.size > 256) stagedRows.clear()
        for (row in rows) {
            if (row.id.isNotEmpty()) stagedRows[row.id] = row
        }
    }

    fun stagedRow(id: String): OrbRow? = if (id.isEmpty()) null else stagedRows[id]

    /** Merges any in-flight optimistic destination preview rows (`pendingOpId != 0`) into `rows`
     * so a concurrent destination `projectMissions()` load finishing before `POST /move` commits never drops the preview. */
    fun mergePendingStagedRows(rows: List<OrbRow>, projectSlug: String): List<OrbRow> {
        val target = projectSlug.trim()
        if (target.isEmpty()) return rows
        val existingIds = rows.mapTo(HashSet()) { it.id }
        val previews = ArrayList<OrbRow>()
        for ((mid, st) in placements) {
            if (st.pendingOpId == 0 || mid in existingIds) continue
            val effProj = st.optimisticProject ?: st.project
            if (!effProj.equals(target, ignoreCase = true)) continue
            val base = stagedRows[mid] ?: continue
            if (isBtwMission(base)) continue
            val isChild = parentId(base) != null
            val patched = OrbReadCache.patchRowPlacement(
                base,
                OrbPlacementCommitItem(
                    missionId = mid,
                    project = effProj,
                    folder = if (isChild) "" else (st.optimisticFolder ?: st.folder),
                    placementRevision = st.revision,
                    explicitProject = true,
                    isPreview = true
                )
            )
            previews.add(patched)
        }
        if (previews.isEmpty()) return rows
        val out = ArrayList<OrbRow>(rows.size + previews.size).apply { addAll(rows) }
        for (preview in previews) {
            OrbReadCache.insertRowByRecency(out, preview)
        }
        return out
    }

    fun normalizeFolder(raw: String?): String {
        if (raw.isNullOrBlank()) return ""
        return raw.trim().trim('/')
            .split('/')
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .joinToString("/")
    }

    fun allocateOpId(): Int {
        while (true) {
            val cur = nextPlacementOpId.get()
            val next = if (cur >= 65535) 1 else cur + 1
            if (nextPlacementOpId.compareAndSet(cur, next)) return next
        }
    }

    fun placementOf(id: String): PlacementState? = if (id.isEmpty()) null else placements[id]

    fun hasAuthoritativePlacement(mission: OrbRow): Boolean {
        val id = mission.str("id") ?: mission.id
        if (id.isEmpty()) return false
        val st = placements[id] ?: return false
        return st.revision > 0L || st.pendingOpId != 0
    }

    /** Filters a fetched project mission list (`ownIds` + `withAncestors`) by each row's reconciled
     * project so stale in-flight refreshes never reinsert conversations moved out optimistically or authoritatively. */
    fun filterToProjectScope(rows: List<OrbRow>, projectSlug: String, ownIds: Set<String>): List<OrbRow> {
        val target = projectSlug.trim()
        return rows.filter { m ->
            val effective = effectiveProject(m)
            if (effective.isNotEmpty()) {
                effective.equals(target, ignoreCase = true)
            } else if (hasAuthoritativePlacement(m)) {
                false
            } else {
                m.id in ownIds
            }
        }
    }

    /** Snapshots root missions under `oldFolder` before any async move runs and groups IDs by
     * destination folder so fork-family expansion on the leader never corrupts sibling suffixes. */
    fun planVirtualFolderMigration(
        missions: List<OrbRow>,
        oldFolder: String,
        destination: String
    ): List<Pair<String, List<String>>> {
        val normOld = normalizeFolder(oldFolder)
        val normDest = normalizeFolder(destination)
        if (normOld.isEmpty() || normOld == normDest) return emptyList()
        val byTarget = LinkedHashMap<String, MutableList<String>>()
        val seenIds = HashSet<String>()
        for (m in missions) {
            if (m.id.isEmpty() || parentId(m) != null || !seenIds.add(m.id)) continue
            val f = folderPath(m) ?: ""
            if (f == normOld || f.startsWith("$normOld/")) {
                val suffix = f.removePrefix(normOld)
                val targetFolder = normalizeFolder(normDest + suffix)
                byTarget.getOrPut(targetFolder) { mutableListOf() }.add(m.id)
            }
        }
        return byTarget.entries
            .filter { it.value.isNotEmpty() }
            .map { it.key to it.value.toList() }
    }

    fun projectSlug(mission: OrbRow): String? {
        observe(mission)
        val id = mission.str("id") ?: mission.id
        placements[id]?.let { state ->
            val effective = state.optimisticProject ?: state.project
            return effective.takeIf { it.isNotEmpty() }
        }
        val pName = (mission.str("project", "project_slug", "project_id", "project_name") ?: "").trim()
        if (pName.isNotEmpty()) return pName
        return seenFacts[id]?.project?.takeIf { it.isNotEmpty() }
    }

    /** Resolves the mission's effective project slug, honoring an authoritative unassigned (`""`) placement over stale row fields. */
    fun effectiveProject(mission: OrbRow, fallback: String? = null): String {
        val slug = projectSlug(mission)
        if (slug != null) return slug
        val id = mission.str("id") ?: mission.id
        if (id.isNotEmpty() && placements.containsKey(id)) return ""
        val pName = (mission.str("project", "project_slug", "project_id", "project_name") ?: "").trim()
        if (pName.isNotEmpty()) return pName
        return fallback?.trim() ?: ""
    }

    fun stageOptimisticPlacement(
        missionIds: Collection<String>,
        opId: Int,
        targetProject: String?,
        targetFolder: String
    ) {
        val cleanFolder = normalizeFolder(targetFolder)
        val cleanProject = targetProject?.trim()
        for (id in missionIds) {
            if (id.isEmpty()) continue
            val isChild = knownParents.containsKey(id)
            val effFolder = if (isChild) "" else cleanFolder
            placements.compute(id) { _, prev ->
                val curRev = prev?.revision ?: 0L
                val verdict = OrbKernel.placementMergeStep(
                    curRev = curRev,
                    incRev = curRev,
                    pendingOpId = prev?.pendingOpId ?: 0,
                    ackOpId = opId,
                    sourceKind = 2,
                    hasPlacement = true
                )
                if (!verdict.admitted) {
                    prev
                } else {
                    val curProj = cleanProject ?: prev?.project ?: seenFacts[id]?.project ?: ""
                    PlacementState(
                        project = prev?.project ?: curProj,
                        folder = prev?.folder ?: effFolder,
                        revision = curRev,
                        pendingOpId = opId,
                        optimisticProject = curProj,
                        optimisticFolder = effFolder
                    )
                }
            }
        }
    }

    fun rollbackOptimisticPlacement(opId: Int): List<OrbPlacementCommitItem> {
        if (opId <= 0) return emptyList()
        val reverted = mutableListOf<OrbPlacementCommitItem>()
        for (id in placements.keys.toList()) {
            placements.computeIfPresent(id) { _, cur ->
                val verdict = OrbKernel.placementMergeStep(
                    curRev = cur.revision,
                    incRev = cur.revision,
                    pendingOpId = cur.pendingOpId,
                    ackOpId = opId,
                    sourceKind = 3,
                    hasPlacement = false
                )
                if (!verdict.admitted) {
                    cur
                } else {
                    reverted.add(
                        OrbPlacementCommitItem(
                            missionId = id,
                            project = cur.project.takeIf { it.isNotEmpty() },
                            folder = if (knownParents.containsKey(id)) "" else cur.folder,
                            placementRevision = cur.revision
                        )
                    )
                    cur.copy(pendingOpId = 0, optimisticProject = null, optimisticFolder = null)
                }
            }
        }
        return reverted
    }

    fun commitAuthoritativePlacements(
        items: List<OrbPlacementCommitItem>,
        ackOpId: Int = 0
    ): List<OrbPlacementCommitItem> {
        val accepted = mutableListOf<OrbPlacementCommitItem>()
        for (item in items) {
            if (item.missionId.isEmpty()) continue
            val isChild = knownParents.containsKey(item.missionId)
            val incFolder = if (isChild) "" else normalizeFolder(item.folder)
            val incProj = item.project?.trim() ?: ""
            var committedItem: OrbPlacementCommitItem? = null
            placements.compute(item.missionId) { _, prev ->
                val curRev = prev?.revision ?: 0L
                val pendingOp = prev?.pendingOpId ?: 0
                val verdict = OrbKernel.placementMergeStep(
                    curRev = curRev,
                    incRev = item.placementRevision,
                    pendingOpId = pendingOp,
                    ackOpId = ackOpId,
                    sourceKind = 1,
                    hasPlacement = true
                )
                if (!verdict.admitted) {
                    if (ackOpId != 0 && prev != null && pendingOp == ackOpId && item.placementRevision < curRev) {
                        val rbVerdict = OrbKernel.placementMergeStep(
                            curRev = curRev,
                            incRev = curRev,
                            pendingOpId = pendingOp,
                            ackOpId = ackOpId,
                            sourceKind = 3,
                            hasPlacement = false
                        )
                        if (rbVerdict.admitted) {
                            val settledFolder = if (isChild) "" else prev.folder
                            val resolved = OrbPlacementCommitItem(
                                missionId = item.missionId,
                                project = prev.project.takeIf { it.isNotEmpty() },
                                folder = settledFolder,
                                placementRevision = curRev,
                                explicitProject = true
                            )
                            committedItem = resolved
                            accepted.add(resolved)
                            prev.copy(
                                folder = settledFolder,
                                pendingOpId = 0,
                                optimisticProject = null,
                                optimisticFolder = null
                            )
                        } else {
                            prev
                        }
                    } else {
                        prev
                    }
                } else {
                    val effProj = if (item.explicitProject) incProj else incProj.ifEmpty { prev?.project ?: seenFacts[item.missionId]?.project ?: "" }
                    val nextRev = maxOf(curRev, item.placementRevision, verdict.nextRev32)
                    val nextPending = if (verdict.clearPending) 0 else pendingOp
                    if (verdict.clearPending || nextPending == 0) {
                        val resolved = OrbPlacementCommitItem(
                            missionId = item.missionId,
                            project = effProj.takeIf { it.isNotEmpty() },
                            folder = incFolder,
                            placementRevision = nextRev,
                            explicitProject = item.explicitProject || effProj.isNotEmpty()
                        )
                        committedItem = resolved
                        accepted.add(resolved)
                    }
                    PlacementState(
                        project = effProj,
                        folder = incFolder,
                        revision = nextRev,
                        pendingOpId = nextPending,
                        optimisticProject = if (verdict.clearPending) null else prev?.optimisticProject,
                        optimisticFolder = if (verdict.clearPending) null else prev?.optimisticFolder
                    )
                }
            }
            committedItem?.let { committed ->
                ancestorCache.computeIfPresent(item.missionId) { _, entry ->
                    entry.copy(row = OrbReadCache.patchRowPlacement(entry.row, committed))
                }
                if (incProj.isNotEmpty()) {
                    seenFacts.compute(item.missionId) { _, cur ->
                        (cur ?: Seen()).copy(project = incProj)
                    }
                } else if (item.explicitProject) {
                    seenFacts.compute(item.missionId) { _, cur ->
                        cur?.copy(project = null)
                    }
                }
            }
        }
        return accepted
    }

    /** Parses an incoming `mission_placement_changed` WS/SSE payload and commits authoritative revisions. */
    fun commitIncomingPlacementEvent(rawEvent: Any?): List<OrbPlacementCommitItem> {
        val root = OrbJSON.dict(rawEvent) ?: return emptyList()
        val rawMoves = OrbJSON.dictList(root["moves"]).ifEmpty { OrbJSON.dictList(root["moved"]) }
        if (rawMoves.isEmpty()) return emptyList()
        val rawOpId = maxOf(0, (root["client_op_id"] as? Number)?.toInt() ?: 0)
        val ackOpId = resolveLocalAckOpId(rawOpId, root["client_id"] as? String)
        val items = rawMoves.mapNotNull { m ->
            val mid = OrbJSON.str(m, "mission_id", "id") ?: return@mapNotNull null
            val hasProjectKey = m.containsKey("project") && (m["project"] == null || m["project"] is String)
            val proj = if (hasProjectKey) {
                (m["project"] as? String)?.trim()?.takeIf { it.isNotEmpty() }
            } else {
                OrbJSON.str(m, "project")?.takeIf { it.isNotEmpty() }
            }
            val fld = normalizeFolder(m["folder"] as? String)
            val rev = maxOf(0L, (m["placement_revision"] as? Number)?.toLong() ?: 0L)
            OrbPlacementCommitItem(
                missionId = mid,
                project = proj,
                folder = fld,
                placementRevision = rev,
                explicitProject = hasProjectKey
            )
        }
        if (items.isEmpty()) return emptyList()
        return commitAuthoritativePlacements(items, ackOpId = ackOpId)
    }

    /** Full moving family closure (co-located fork siblings when moving a group leader + launched descendants at any depth) for optimistic staging. */
    fun subtree(missions: List<OrbRow>, rootIds: Collection<String>): List<OrbRow> {
        if (rootIds.isEmpty()) return emptyList()
        for (m in missions) observe(m)
        val byId = LinkedHashMap<String, OrbRow>(missions.size)
        for (m in missions) byId.putIfAbsent(m.id, m)
        val buckets = LinkedHashMap<String, MutableList<OrbRow>>()
        for (m in byId.values) {
            val bucket = effectiveProject(m).ifEmpty { "default" }
            buckets.getOrPut(bucket) { mutableListOf() }.add(m)
        }
        val leadersByBucket = buckets.mapValues { (_, list) -> forkLeaders(list) }
        val childrenByParent = HashMap<String, MutableList<String>>()
        for (m in byId.values) {
            parentId(m)?.let { p -> childrenByParent.getOrPut(p) { mutableListOf() }.add(m.id) }
        }
        val visited = LinkedHashSet<String>()
        val queue = ArrayDeque<String>()
        for (rid in rootIds) {
            if (rid.isEmpty()) continue
            if (visited.add(rid)) queue.add(rid)
            val target = byId[rid] ?: continue
            val bucket = effectiveProject(target).ifEmpty { "default" }
            val leaders = leadersByBucket[bucket]
            if (leaders?.get(rid)?.id == rid) {
                for (sibling in buckets[bucket].orEmpty()) {
                    if (leaders[sibling.id]?.id == rid && visited.add(sibling.id)) {
                        queue.add(sibling.id)
                    }
                }
            }
        }
        while (queue.isNotEmpty()) {
            val cur = queue.removeFirst()
            for (kid in childrenByParent[cur].orEmpty()) {
                if (visited.add(kid)) queue.add(kid)
            }
        }
        return visited.mapNotNull { byId[it] }
    }

    /** Explicit re-parent (null detaches): the only way a remembered parent changes. */
    fun reparent(id: String, parent: String?) {
        if (parent.isNullOrEmpty()) {
            knownParents.remove(id)
        } else {
            knownParents[id] = parent
            placements.computeIfPresent(id) { _, cur ->
                cur.copy(folder = "", optimisticFolder = cur.optimisticFolder?.let { "" })
            }
        }
    }

    /** Forget every remembered link (connection switch, tests). */
    fun resetHierarchy() {
        knownParents.clear()
        knownBtw.clear()
        seenFacts.clear()
        ancestorCache.clear()
        goneIds.clear()
        placements.clear()
        stagedRows.clear()
        nextPlacementOpId.set(0)
    }

    private fun hasDirectBtwTag(mission: OrbRow): Boolean =
        OrbJSON.strList(mission.raw, "tags").any { it.startsWith("btw-parent:") || it == "btw-subagent" }

    fun isPlaceholder(mission: OrbRow): Boolean = mission.bool("orb_placeholder") == true

    fun observe(mission: OrbRow) {
        if (isPlaceholder(mission)) return
        val id = mission.str("id") ?: mission.id
        if (id.isEmpty()) return
        goneIds.remove(id)
        val payloadParent = payloadParentId(mission)
        if (payloadParent != null) knownParents[id] = payloadParent
        val isChild = payloadParent != null || knownParents.containsKey(id)
        if (hasDirectBtwTag(mission)) knownBtw.add(id)
        val rawTitle = mission.str("title")
        val hasProjectKey = mission.raw.containsKey("project") && (mission.raw["project"] == null || mission.raw["project"] is String)
        val rawProject = if (hasProjectKey) ((mission.raw["project"] as? String)?.trim() ?: "") else null
        val hasFolderKey = mission.raw.containsKey("folder") && mission.raw["folder"] is String
        val rawFolder = if (isChild) "" else if (hasFolderKey) normalizeFolder(mission.raw["folder"] as String) else null
        val incRev = maxOf(0L, (mission.raw["placement_revision"] as? Number)?.toLong() ?: 0L)
        val isProjectedPreview = mission.bool("orb_projected_move") == true
        val hasPlacementPayload = !isProjectedPreview && (hasProjectKey || hasFolderKey || mission.raw.containsKey("placement_revision"))
        var resolvedProject = if (isProjectedPreview) null else rawProject?.takeIf { it.isNotEmpty() }
        var clearSeenProject = !isProjectedPreview && hasProjectKey && resolvedProject == null
        if (hasPlacementPayload) {
            placements.compute(id) { _, prev ->
                val curRev = prev?.revision ?: 0L
                val pendingOp = prev?.pendingOpId ?: 0
                val candProj = if (hasProjectKey) (rawProject ?: "") else (prev?.project ?: seenFacts[id]?.project ?: "")
                val candFolder = if (isChild) "" else (rawFolder ?: prev?.folder ?: "")
                if (prev == null) {
                    PlacementState(project = candProj, folder = candFolder, revision = incRev)
                } else {
                    val verdict = OrbKernel.placementMergeStep(
                        curRev = curRev,
                        incRev = incRev,
                        pendingOpId = pendingOp,
                        ackOpId = 0,
                        sourceKind = 0,
                        hasPlacement = true
                    )
                    if (!verdict.admitted) {
                        resolvedProject = (prev.optimisticProject ?: prev.project).takeIf { it.isNotEmpty() }
                        clearSeenProject = false
                        prev
                    } else {
                        val nextRev = maxOf(curRev, incRev, verdict.nextRev32)
                        val nextPending = if (verdict.clearPending) 0 else pendingOp
                        val nextOptProj = if (verdict.clearPending) null else prev.optimisticProject
                        val nextOptFolder = if (verdict.clearPending) null else prev.optimisticFolder
                        val effSeenProj = nextOptProj ?: candProj
                        resolvedProject = effSeenProj.takeIf { it.isNotEmpty() }
                        clearSeenProject = (nextOptProj != null && nextOptProj.isEmpty()) ||
                            (nextOptProj == null && hasProjectKey && resolvedProject == null)
                        PlacementState(
                            project = candProj,
                            folder = candFolder,
                            revision = nextRev,
                            pendingOpId = nextPending,
                            optimisticProject = nextOptProj,
                            optimisticFolder = nextOptFolder
                        )
                    }
                }
            }
        } else if (isChild) {
            placements.computeIfPresent(id) { _, cur ->
                cur.copy(folder = "", optimisticFolder = cur.optimisticFolder?.let { "" })
            }
        }
        val rawStatus = mission.str("status", "state")?.takeIf { it != "unknown" }
        val rawBackend = mission.str("backend")
        seenFacts.compute(id) { _, prev ->
            val cur = prev ?: Seen()
            Seen(
                title = rawTitle ?: cur.title,
                project = if (clearSeenProject) null else (resolvedProject ?: cur.project),
                status = rawStatus ?: cur.status,
                backend = rawBackend ?: cur.backend
            )
        }
    }

    fun seen(id: String): Seen? = seenFacts[id]

    fun cachedAncestor(id: String, nowMs: Long = System.currentTimeMillis(), allowStale: Boolean = false): OrbRow? {
        val entry = ancestorCache[id] ?: return null
        return if (allowStale || nowMs - entry.fetchedAtMs < ANCESTOR_TTL_MS) entry.row else null
    }

    fun storeAncestor(row: OrbRow, nowMs: Long = System.currentTimeMillis()) {
        if (row.id.isEmpty()) return
        observe(row)
        ancestorCache[row.id] = CachedAncestor(row, nowMs)
        goneIds.remove(row.id)
    }

    fun markGone(id: String) {
        if (id.isEmpty()) return
        ancestorCache.remove(id)
        goneIds.add(id)
    }

    fun isGone(id: String): Boolean {
        if (id.isEmpty()) return false
        if (isBtwMission(OrbRow(id, mapOf("id" to id)))) return true
        return goneIds.contains(id)
    }

    /** True for `/btw` side-question forks (`btw-parent:*`), `btw-subagent` workers, and every descendant in their subtrees. */
    fun isBtwMission(mission: OrbRow, byId: Map<String, OrbRow>? = null): Boolean {
        val id = mission.str("id") ?: mission.id
        if (hasDirectBtwTag(mission)) {
            if (id.isNotEmpty()) knownBtw.add(id)
            return true
        }
        if (id.isNotEmpty() && knownBtw.contains(id)) return true
        val seen = mutableSetOf<String>()
        if (id.isNotEmpty()) seen.add(id)
        var cursor = payloadParentId(mission) ?: (if (id.isNotEmpty()) knownParents[id] else null)
        while (cursor != null && seen.size < 16 && seen.add(cursor)) {
            if (knownBtw.contains(cursor)) return true
            val anc = byId?.get(cursor)
            if (anc != null && hasDirectBtwTag(anc)) {
                knownBtw.add(cursor)
                return true
            }
            cursor = (if (anc != null) payloadParentId(anc) else null) ?: knownParents[cursor]
        }
        return false
    }

    /** Observe hierarchy links across the batch first, then exclude `/btw` missions and their descendants. */
    fun filterMobile(missions: List<OrbRow>): List<OrbRow> {
        for (m in missions) observe(m)
        val byId = missions.associateBy { it.id }
        return missions.filterNot { isBtwMission(it, byId) }
    }

    /** The mission that launched this one. A fork is another version, never launched work. */
    fun parentId(mission: OrbRow): String? {
        val id = mission.str("id")
        val found = payloadParentId(mission)
        if (id.isNullOrEmpty()) return found
        if (found != null) { knownParents[id] = found; return found }
        return knownParents[id]
    }

    private fun payloadParentId(mission: OrbRow): String? {
        mission.str("parent_mission_id")?.takeIf { it.isNotEmpty() && it != forkSource(mission) }?.let { return it }
        mission.str(
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
        return MissionState.of(mission)?.live == true
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
        observe(mission)
        if (parentId(mission) != null) return null
        val id = mission.str("id") ?: mission.id
        placements[id]?.let { state ->
            val effective = state.optimisticFolder ?: state.folder
            return effective.takeIf { it.isNotEmpty() }
        }
        return normalizeFolder(mission.str("folder")).takeIf { it.isNotEmpty() }
    }

    private fun reaches(byId: Map<String, OrbRow>, from: OrbRow, target: String): Boolean {
        val seen = mutableSetOf<String>()
        var current: OrbRow? = from
        while (current != null && seen.add(current.id)) {
            if (current.id == target) return true
            current = parentId(current)?.let { byId[it] }
        }
        return false
    }

    /** Keep archived/completed parents as context for visible child workers without restoring all archived missions. */
    fun treeRows(missions: List<OrbRow>, visible: (OrbRow) -> Boolean): List<OrbRow> {
        val byId = LinkedHashMap<String, OrbRow>(missions.size)
        for (m in missions) byId.putIfAbsent(m.id, m)
        val retained = missions.filter(visible).mapTo(mutableSetOf()) { it.id }
        for (m in missions) {
            if (!visible(m)) continue
            val seen = mutableSetOf(m.id)
            var parent = parentId(m)
            while (parent != null && seen.add(parent)) {
                val row = byId[parent] ?: break
                retained.add(parent)
                parent = parentId(row)
            }
        }
        return missions.filter { it.id in retained }
    }

    fun isSuperseded(mission: OrbRow): Boolean {
        if (isLive(mission)) return false
        return mission.hasTypedSuperseded()
    }

    /** True when a mission or any of its ancestors is superseded and this mission is not actively running. */
    fun isSupersededInTree(mission: OrbRow, byId: Map<String, OrbRow>): Boolean {
        if (isLive(mission)) return false
        if (isSuperseded(mission)) return true
        val seen = mutableSetOf(mission.id)
        var parent = parentId(mission)
        while (parent != null && seen.add(parent)) {
            val row = byId[parent] ?: break
            if (isSuperseded(row)) return true
            parent = parentId(row)
        }
        return false
    }

    /** Open missions older than the history page (`sidebar-hierarchy.md` M2):
     * live ones always; stopped ones within 7 days; children only when live or their parent is listed. */
    fun openBeyondPage(history: List<OrbRow>, extra: List<OrbRow>, nowMs: Long = System.currentTimeMillis()): List<OrbRow> {
        for (m in history) observe(m)
        for (m in extra) observe(m)
        val byId = LinkedHashMap<String, OrbRow>(history.size + extra.size)
        for (m in history) byId.putIfAbsent(m.id, m)
        for (m in extra) byId.putIfAbsent(m.id, m)
        val listed = history.mapTo(mutableSetOf()) { it.id }
        val wanted = extra.filter { m ->
            if (m.id in listed || isBtwMission(m, byId)) return@filter false
            val status = (m.str("status", "state") ?: "").lowercase()
            if (status in LIVE_OPEN_STATES) return@filter true
            if (status in RECENT_OPEN_STATES) {
                val ts = activityMs(m)
                return@filter ts > 0L && nowMs - ts <= RECENT_OPEN_MS
            }
            false
        }
        val ids = HashSet<String>(listed.size + wanted.size).apply {
            addAll(listed)
            for (m in wanted) add(m.id)
        }
        return wanted.filter { m ->
            val p = parentId(m) ?: return@filter true
            val status = (m.str("status", "state") ?: "").lowercase()
            status in LIVE_OPEN_STATES || p in ids
        }
    }

    /** Parents referenced by loaded rows that the rows do not contain. */
    fun missingParentIds(rows: List<OrbRow>): List<String> {
        val ids = rows.mapTo(mutableSetOf()) { it.id }
        val missing = LinkedHashSet<String>()
        for (row in rows) {
            val p = parentId(row)
            if (p != null && p !in ids) missing.add(p)
        }
        return missing.toList()
    }

    /** Fetch missing ancestors up to [maxDepth] and place each fetched ancestor right before its first descendant. */
    suspend fun withAncestors(
        rows: List<OrbRow>,
        maxDepth: Int = 8,
        fetchById: suspend (String) -> OrbRow?
    ): List<OrbRow> {
        val known = LinkedHashMap<String, OrbRow>(rows.size)
        for (row in rows) {
            observe(row)
            known.putIfAbsent(row.id, row)
        }
        val fetched = LinkedHashMap<String, OrbRow>()
        val tried = mutableSetOf<String>()
        for (depth in 0 until maxDepth) {
            val wanted = missingParentIds(known.values.toList()).filter { it !in tried }
            if (wanted.isEmpty()) break
            tried.addAll(wanted)
            val results = coroutineScope {
                wanted.map { id ->
                    async {
                        try {
                            fetchById(id)
                        } catch (e: CancellationException) {
                            throw e
                        } catch (_: Throwable) {
                            null
                        }
                    }
                }.awaitAll()
            }
            for (row in results) {
                if (row != null) {
                    observe(row)
                    if (!known.containsKey(row.id)) {
                        known[row.id] = row
                        fetched[row.id] = row
                    }
                }
            }
        }
        if (fetched.isEmpty()) return rows
        val out = ArrayList<OrbRow>(rows.size + fetched.size)
        val placed = mutableSetOf<String>()
        fun place(row: OrbRow, seen: MutableSet<String>) {
            val parent = parentId(row)
            val anc = if (parent != null) fetched[parent] else null
            if (parent != null && anc != null && parent !in placed && seen.add(parent)) {
                place(anc, seen)
            }
            if (placed.add(row.id)) {
                out.add(row)
            }
        }
        for (row in rows) {
            place(row, mutableSetOf(row.id))
        }
        return out
    }

    /** Stand-in row for a parent that is not in the loaded rows (cross-project, or transient fetch error).
     * Returns null only when Core confirmed the parent is gone (404) or in a `/btw` subtree. */
    fun placeholderParent(projectSlug: String): (String, OrbRow) -> OrbRow? = { parentId, child ->
        if (isGone(parentId)) {
            null
        } else {
            val known = seen(parentId)
            val knownPlacement = placementOf(parentId)
            val resolvedProject = if (knownPlacement != null) {
                (knownPlacement.optimisticProject ?: knownPlacement.project).ifEmpty { projectSlug }
            } else {
                known?.project ?: projectSlug
            }
            val resolvedFolder = knownPlacement?.let { it.optimisticFolder ?: it.folder } ?: ""
            val dict = LinkedHashMap<String, Any?>().apply {
                put("id", parentId)
                put("title", known?.title)
                put("status", known?.status ?: "unknown")
                put("project", resolvedProject)
                put("folder", resolvedFolder)
                put("placement_revision", knownPlacement?.revision ?: 0L)
                put("tags", emptyList<String>())
                put("history", emptyList<OrbDict>())
                put("created_at", child.str("created_at"))
                put("updated_at", activity(child))
                put("orb_placeholder", true)
                if (!known?.backend.isNullOrEmpty()) {
                    put("backend", known?.backend)
                }
            }
            OrbRow(parentId, dict)
        }
    }

    fun nest(
        missions: List<OrbRow>,
        placeholder: ((String, OrbRow) -> OrbRow?)? = null
    ): List<OrbNestedMission> {
        val deduped = OrbContinuation.collapse(missions)
        val byId = deduped.associateBy { it.id }
        val childrenByParent = mutableMapOf<String, MutableList<OrbRow>>()
        val placeholders = mutableMapOf<String, OrbRow>()
        val roots = mutableListOf<OrbRow>()
        val leaders = forkLeaders(deduped)
        val versionsByLeader = mutableMapOf<String, MutableList<OrbRow>>()

        for (mission in deduped) {
            val leader = leaders[mission.id]
            if (leader != null && leader.id != mission.id) {
                versionsByLeader.getOrPut(leader.id) { mutableListOf() }.add(mission)
                continue
            }
            // A leading fork takes the place of the conversation it continues.
            val place = leader?.let { l -> deduped.firstOrNull { leaders[it.id]?.id == l.id && forkSource(it) == null } } ?: mission
            val parent = parentId(place)
            val parentRow = if (parent != null) byId[parent] else null
            if (parent != null && parentRow != null && parent != mission.id && !reaches(byId, parentRow, mission.id)) {
                childrenByParent.getOrPut(parent) { mutableListOf() }.add(mission)
            } else if (parent != null && parent != mission.id && parentRow == null && placeholder != null) {
                val existing = placeholders[parent]
                if (existing != null) {
                    childrenByParent.getOrPut(existing.id) { mutableListOf() }.add(mission)
                } else {
                    val standIn = placeholder(parent, place)
                    if (standIn != null) {
                        placeholders[parent] = standIn
                        roots.add(standIn)
                        childrenByParent.getOrPut(standIn.id) { mutableListOf() }.add(mission)
                    } else {
                        roots.add(mission)
                    }
                }
            } else {
                roots.add(mission)
            }
        }

        fun build(row: OrbRow, depth: Int, visited: Set<String>): OrbNestedMission {
            if (visited.contains(row.id)) return OrbNestedMission(row, emptyList(), depth)
            val nextVisited = visited + row.id
            val kids = (childrenByParent[row.id] ?: emptyList())
                .filterNot { it.id in nextVisited }
                .map { build(it, depth + 1, nextVisited) }
            val versions = (versionsByLeader[row.id] ?: emptyList())
                .sortedByDescending { activity(it) }
                .map { build(it, depth + 1, nextVisited).copy(version = true) }
            return OrbNestedMission(row, kids + versions, depth)
        }

        return roots.map { build(it, 0, emptySet()) }
    }

    private const val FORK_SETTLE_MS = 15_000L

    private fun activity(mission: OrbRow): String = mission.str("updated_at", "created_at") ?: ""
    private fun activityMs(mission: OrbRow): Long = OrbJSON.dateEpochMs(mission.str("updated_at", "created_at")) ?: 0L
    private fun createdAtMs(mission: OrbRow): Long = OrbJSON.dateEpochMs(mission.str("created_at")) ?: 0L

    private fun isRetiredVersion(mission: OrbRow): Boolean = isArchived(mission) || mission.hasTypedSuperseded()

    /** Maps each listed fork to its conversation's leader using the normative
     * `(unretired, live, effectiveActivity, forkDepth)` rank (`docs/specs/sidebar-hierarchy.md` F1). */
    fun forkLeaders(missions: List<OrbRow>): Map<String, OrbRow> {
        val byId = LinkedHashMap<String, OrbRow>(missions.size)
        for (mission in missions) byId.putIfAbsent(mission.id, mission)
        data class Lineage(val rootId: String, val depth: Int, val ancestors: List<String>)
        fun lineage(mission: OrbRow): Lineage {
            var current = mission
            val seen = mutableSetOf<String>()
            val ancestors = mutableListOf<String>()
            while (true) {
                val source = forkSource(current) ?: break
                val next = byId[source] ?: break
                if (seen.contains(source) || !seen.add(current.id)) break
                current = next
                ancestors.add(current.id)
            }
            return Lineage(current.id, ancestors.size, ancestors)
        }
        val info = missions.associate { it.id to lineage(it) }
        val leaders = mutableMapOf<String, OrbRow>()
        for (group in missions.groupBy { info.getValue(it.id).rootId }.values) {
            if (group.size < 2) continue
            val effective = HashMap<String, Long>(group.size)
            for (m in group) effective[m.id] = activityMs(m)
            for (m in group) {
                val created = createdAtMs(m)
                if (created <= 0L) continue
                for (ancId in info.getValue(m.id).ancestors) {
                    val ancAct = effective[ancId]
                    if (ancAct != null && ancAct <= created + FORK_SETTLE_MS) {
                        effective[ancId] = minOf(ancAct, created)
                    }
                }
            }
            fun beats(a: OrbRow, b: OrbRow): Boolean {
                val ua = if (isRetiredVersion(a)) 0 else 1
                val ub = if (isRetiredVersion(b)) 0 else 1
                if (ua != ub) return ua > ub
                val la = if (isLive(a)) 1 else 0
                val lb = if (isLive(b)) 1 else 0
                if (la != lb) return la > lb
                val ea = effective[a.id] ?: 0L
                val eb = effective[b.id] ?: 0L
                if (ea != eb) return ea > eb
                return info.getValue(a.id).depth > info.getValue(b.id).depth
            }
            var leader = group.first()
            for (m in group.drop(1)) {
                if (beats(m, leader)) leader = m
            }
            for (mission in group) leaders[mission.id] = leader
        }
        return leaders
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
        val material = "$trimmedBase|$trimmedToken"
        val digest = MessageDigest.getInstance("SHA-256").digest(material.toByteArray())
        accountScope = digest.take(10).joinToString("") { "%02x".format(it) }
    }

    @Synchronized
    internal fun currentScope(): String = accountScope

    private fun rootDir(): File {
        val ctx = appContext
        val dir = if (ctx != null) File(ctx.filesDir, "Orb") else File(System.getProperty("java.io.tmpdir"), "Orb")
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
        } catch (t: Throwable) {
            OrbLog.w(OrbLog.Category.Cache, "disk read $key failed", t)
            null
        }
    }

    private val writesSincePrune = java.util.concurrent.atomic.AtomicInteger(0)

    /** Only per-entity read-cache records rebuildable from Core are eligible for
     * bounded disk eviction; user-owned state (`draft_*`, `pending_*`, `document_*`)
     * and account bootstrap singletons (`missions`, `projects`, `workspaces`, etc.) are never evicted. */
    internal fun isPrunableReadCacheKey(key: String): Boolean =
        key.startsWith("mission_events_") ||
        key.startsWith("mission_msgs_") ||
        key.startsWith("mission_") ||
        key.startsWith("cloud_") ||
        key.startsWith("project_missions_") ||
        key.startsWith("presentation_") ||
        key.startsWith("btw_turns_")

    internal fun isPrunableReadCacheFileName(name: String): Boolean {
        if (!name.endsWith(".json")) return false
        val keyPart = name.removeSuffix(".json").substringAfter('_', "")
        return isPrunableReadCacheKey(keyPart)
    }

    fun write(key: String, value: Any?) {
        try {
            val f = file(key)
            val tmp = File(f.parentFile, "${f.name}.tmp.${System.nanoTime()}")
            tmp.writeText(OrbJSON.stringify(value))
            if (!tmp.renameTo(f)) {
                tmp.copyTo(f, overwrite = true)
                tmp.delete()
            }
            if (isPrunableReadCacheKey(key) && (writesSincePrune.incrementAndGet() and 63) == 0) {
                pruneReadCacheFiles(maxFiles = 550)
            }
        } catch (t: Throwable) {
            OrbLog.w(OrbLog.Category.Cache, "disk write $key failed", t)
        }
    }

    internal fun pruneReadCacheFiles(maxFiles: Int, scopeFilter: String? = null) {
        try {
            val scopePrefix = scopeFilter?.let { "${it}_" }
            val cacheFiles = rootDir().listFiles { f ->
                f.isFile &&
                    isPrunableReadCacheFileName(f.name) &&
                    (scopePrefix == null || f.name.startsWith(scopePrefix))
            } ?: return
            if (cacheFiles.size <= maxFiles) return
            val sorted = cacheFiles.sortedBy { it.lastModified() }
            val excess = sorted.size - maxFiles
            for (i in 0 until excess) {
                sorted[i].delete()
            }
        } catch (t: Throwable) {
            OrbLog.w(OrbLog.Category.Cache, "pruning disk cache failed", t)
        }
    }

    fun clearCurrentScope() {
        try {
            val prefix = "${currentScope()}_"
            rootDir().listFiles()?.forEach { f ->
                if (f.name.startsWith(prefix)) f.delete()
            }
        } catch (t: Throwable) {
            OrbLog.w(OrbLog.Category.Cache, "clearing disk cache failed", t)
        }
    }
}

object OrbReadCache {
    /** Missions' rows kept in memory, least recently used dropped first (disk keeps them). */
    const val MAX_ROW_KEYS = 64
    /** Tool output kept per event, as on iOS (`StoredEvent.resultKeepUTF8`); the timeline never shows it. */
    const val RESULT_KEEP_CHARS = 4096

    private val rowsByKey = object : LinkedHashMap<String, List<OrbRow>>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, List<OrbRow>>?) = size > MAX_ROW_KEYS
    }
    private val dictByKey = ConcurrentHashMap<String, OrbDict>()
    private val cachedProjectSlugs = ConcurrentHashMap.newKeySet<String>()
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val writeJobs = ConcurrentHashMap<String, Job>()
    private val pendingRowPayloads = ConcurrentHashMap<String, Pair<String, List<OrbRow>>>()
    private val writeLocks = ConcurrentHashMap<String, Any>()

    private fun trackProjectKey(key: String) {
        if (key.startsWith("project_missions_")) {
            val slug = key.removePrefix("project_missions_")
            if (slug.isNotEmpty()) cachedProjectSlugs.add(slug)
        }
    }

    fun clearMemory() {
        OrbWarmSyncCoordinator.resetCaches()
        synchronized(rowsByKey) { rowsByKey.clear() }
        dictByKey.clear()
        cachedProjectSlugs.clear()
        pendingRowPayloads.clear()
        writeJobs.values.forEach { it.cancel() }
        writeJobs.clear()
    }

    fun flushPendingWrites() {
        val entries = ArrayList(pendingRowPayloads.entries.map { it.key to it.value })
        if (entries.isEmpty()) return
        for ((key, pair) in entries) {
            pendingRowPayloads.remove(key)
            writeJobs.remove(key)?.cancel()
            val (account, kept) = pair
            writeJobs[key] = ioScope.launch {
                if (account != OrbDisk.currentScope()) return@launch
                val raw = kept.map { it.raw }
                val lock = writeLocks.getOrPut(key) { Any() }
                synchronized(lock) {
                    if (account == OrbDisk.currentScope()) {
                        OrbDisk.write(key, raw)
                    }
                }
            }
        }
    }

    /** Event rows as the client keeps them: long tool results cut to their head. */
    fun compactEvents(rows: List<OrbRow>): List<OrbRow> = rows.map { row ->
        val content = row.raw["content"] as? String
        if (row.raw["event_type"] != "tool_result" || content == null || content.length <= RESULT_KEEP_CHARS) row
        else row.copy(raw = row.raw + ("content" to content.take(RESULT_KEEP_CHARS)))
    }

    private fun bounded(key: String, rows: List<OrbRow>) = if (key.startsWith("mission_events_")) compactEvents(rows) else rows

    fun loadRows(key: String): List<OrbRow> {
        trackProjectKey(key)
        val account = OrbDisk.currentScope()
        synchronized(rowsByKey) { rowsByKey[key] }?.let { return it }
        val raw = OrbDisk.read(key)
        val rows = bounded(key, OrbJSON.dictList(raw).map { OrbRow(it) })
        return synchronized(rowsByKey) {
            if (account != OrbDisk.currentScope()) return@synchronized emptyList()
            rowsByKey[key]?.let { return@synchronized it }
            if (rows.isNotEmpty()) rowsByKey[key] = rows
            rows
        }
    }

    /** Safe for composition: never performs disk I/O or JSON decoding. */
    fun readMemoryRows(key: String): List<OrbRow> {
        trackProjectKey(key)
        return synchronized(rowsByKey) { rowsByKey[key] } ?: emptyList()
    }

    suspend fun loadRowsAsync(key: String): List<OrbRow> {
        val account = OrbDisk.currentScope()
        val rows = withContext(Dispatchers.IO) { loadRows(key) }
        if (account != OrbDisk.currentScope()) throw CancellationException("Cache account changed")
        return rows
    }

    /** A bounded global roster cannot replace a project's more complete cached list. */
    fun seedProjectRows(project: String, rows: List<OrbRow>, fresh: Boolean = false) {
        val key = "project_missions_$project"
        val cached = loadRows(key)
        if (cached.isEmpty()) saveRowsMemoryOnly(key, rows)
        else if (fresh) {
            val incoming = rows.associateBy { it.id }
            val known = cached.mapTo(mutableSetOf()) { it.id }
            saveRowsMemoryOnly(key, cached.map { incoming[it.id] ?: it } + rows.filter { it.id !in known })
        }
    }

    fun hasRowsInMemory(key: String): Boolean = synchronized(rowsByKey) { rowsByKey.containsKey(key) }

    fun saveRowsMemoryOnly(key: String, rows: List<OrbRow>) {
        trackProjectKey(key)
        synchronized(rowsByKey) { rowsByKey[key] = bounded(key, rows) }
    }

    fun saveRows(key: String, rows: List<OrbRow>, debounceMs: Long = 0L) {
        trackProjectKey(key)
        val kept = bounded(key, rows)
        synchronized(rowsByKey) { rowsByKey[key] = kept }
        val account = OrbDisk.currentScope()
        writeJobs.remove(key)?.cancel()
        if (debounceMs > 0L) {
            pendingRowPayloads[key] = account to kept
        } else {
            pendingRowPayloads.remove(key)
        }
        writeJobs[key] = ioScope.launch {
            if (debounceMs > 0L) delay(debounceMs)
            pendingRowPayloads.remove(key)
            if (account != OrbDisk.currentScope()) return@launch
            val raw = kept.map { it.raw }
            val lock = writeLocks.getOrPut(key) { Any() }
            synchronized(lock) {
                if (account == OrbDisk.currentScope()) {
                    OrbDisk.write(key, raw)
                }
            }
        }
    }

    fun prewarmRecentConversations(rows: List<OrbRow>, maxCount: Int = 8) {
        val ids = rows.take(maxCount).map { it.id }.filter { it.isNotEmpty() }
        if (ids.isEmpty()) return
        ioScope.launch {
            for (id in ids) {
                loadRows("mission_msgs_$id")
                loadRows("mission_events_$id")
            }
        }
    }

    /** Safe for composition: never performs disk I/O or JSON decoding. */
    fun readMemoryDict(key: String): OrbDict? = dictByKey[key]

    fun loadDict(key: String): OrbDict? {
        dictByKey[key]?.let { return it }
        val dict = OrbJSON.dict(OrbDisk.read(key))
        if (dict != null) {
            dictByKey[key] = dict
        }
        return dict
    }

    suspend fun loadDictAsync(key: String): OrbDict? {
        val account = OrbDisk.currentScope()
        val dict = withContext(Dispatchers.IO) { loadDict(key) }
        if (account != OrbDisk.currentScope()) throw CancellationException("Cache account changed")
        return dict
    }

    fun saveDict(key: String, dict: OrbDict) {
        dictByKey[key] = dict
        val account = OrbDisk.currentScope()
        writeJobs.remove(key)?.cancel()
        writeJobs[key] = ioScope.launch {
            if (account != OrbDisk.currentScope()) return@launch
            val lock = writeLocks.getOrPut(key) { Any() }
            synchronized(lock) {
                if (account == OrbDisk.currentScope()) {
                    OrbDisk.write(key, dict)
                }
            }
        }
    }

    /** Reconciles cached per-project mission rosters immediately on optimistic or authoritative placement commits. */
    fun applyPlacementCommit(
        accepted: List<OrbPlacementCommitItem>,
        fallbackRows: Map<String, OrbRow> = emptyMap(),
        persistToDisk: Boolean = true
    ) {
        if (accepted.isEmpty()) return
        val byId = accepted.associateBy { it.missionId }
        val touchedProjects = LinkedHashSet<String>(cachedProjectSlugs)
        for (item in accepted) {
            item.project?.trim()?.takeIf { it.isNotEmpty() }?.let { touchedProjects.add(it) }
        }
        val memoryKeys = synchronized(rowsByKey) { rowsByKey.keys.toList() }
        for (k in memoryKeys) {
            if (k.startsWith("project_missions_")) {
                val slug = k.removePrefix("project_missions_")
                if (slug.isNotEmpty()) touchedProjects.add(slug)
            }
        }
        for (slug in touchedProjects) {
            val key = "project_missions_$slug"
            val hadInMemory = hasRowsInMemory(key)
            val existing = if (hadInMemory) readMemoryRows(key) else loadRows(key)
            var changed = false
            val updated = ArrayList<OrbRow>(existing.size + accepted.size)
            val presentIds = HashSet<String>(existing.size)
            for (row in existing) {
                val item = byId[row.id]
                if (item == null) {
                    presentIds.add(row.id)
                    updated.add(row)
                    continue
                }
                val targetProj = item.project?.trim()?.takeIf { it.isNotEmpty() }
                if ((targetProj == null && item.explicitProject) || (targetProj != null && !targetProj.equals(slug, ignoreCase = true))) {
                    changed = true
                    continue
                }
                changed = true
                presentIds.add(row.id)
                updated.add(patchRowPlacement(row, item))
            }
            for (item in accepted) {
                val targetProj = item.project?.trim()?.takeIf { it.isNotEmpty() } ?: continue
                if (targetProj.equals(slug, ignoreCase = true) && item.missionId !in presentIds) {
                    val base = fallbackRows[item.missionId] ?: OrbMissionTree.stagedRow(item.missionId)
                    if (base != null && !OrbMissionTree.isBtwMission(base)) {
                        changed = true
                        presentIds.add(item.missionId)
                        insertRowByRecency(updated, patchRowPlacement(base, item))
                    }
                }
            }
            if (changed) {
                if (persistToDisk) {
                    saveRows(key, updated)
                } else {
                    saveRowsMemoryOnly(key, updated)
                }
            }
        }
    }

    private fun rowRecencyEpochMs(row: OrbRow): Long =
        OrbJSON.dateEpochMs(row.str("updated_at", "created_at")) ?: 0L

    internal fun insertRowByRecency(rows: MutableList<OrbRow>, candidate: OrbRow) {
        val ts = rowRecencyEpochMs(candidate)
        if (ts <= 0L) {
            rows.add(0, candidate)
            return
        }
        val insertIdx = rows.indexOfFirst { rowRecencyEpochMs(it) < ts }
        if (insertIdx < 0) rows.add(candidate) else rows.add(insertIdx, candidate)
    }

    fun patchRowPlacement(row: OrbRow, item: OrbPlacementCommitItem): OrbRow {
        val next = LinkedHashMap<String, Any?>(row.raw)
        if (!item.project.isNullOrBlank()) {
            next["project"] = item.project
        } else if (item.explicitProject) {
            next["project"] = null
        }
        next["folder"] = if (OrbMissionTree.parentId(row) != null) "" else OrbMissionTree.normalizeFolder(item.folder)
        next["placement_revision"] = item.placementRevision
        if (item.isPreview) {
            next["orb_projected_move"] = true
        } else {
            next.remove("orb_projected_move")
        }
        return OrbRow(row.id, next)
    }
}

class OrbError(
    override val message: String,
    val status: Int? = null,
    /** Raw response body, so callers can read structured `{error, message}` errors. */
    val body: String? = null
) : Exception(message)

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
    data class CurrentUser(
        val id: String,
        val username: String,
        val role: String,
        val unixUsername: String?,
        val dailySpendCapCents: Int?,
        val spentTodayCents: Int,
    )

    data class AuthCapabilities(
        val canManageUsers: Boolean,
        val canUseCoreTarget: Boolean,
        val canManageGlobalProviders: Boolean,
    )

    companion object {
        private const val KEYCHAIN_SERVICE = "md.thomas.orb.core"
        private const val CREDENTIALS_SERVICE = "md.thomas.orb.credentials"
        private const val PREFS_NAME = "orb_core_prefs"
        private const val BASE_URL_KEY = "orb.baseURL"
        private const val TOKEN_FALLBACK_KEY = "orb.tokenFallback"

        fun computeIsAdmin(authMode: String, user: CurrentUser?): Boolean =
            if (authMode == "multi_user") user?.role == "admin"
            else (user == null || user.role == "admin")

        @Volatile
        private var instance: OrbCore? = null

        fun getInstance(context: Context): OrbCore {
            return instance ?: synchronized(this) {
                instance ?: OrbCore(context.applicationContext).also { instance = it }
            }
        }

        val shared: OrbCore
            get() = checkNotNull(instance) { "OrbCore.getInstance(context) must be called first" }

        internal fun drainSyncSubscribersOnHubClose(
            closingHub: Any?,
            toNotify: List<SyncStreamSub>,
        ) {
            for (sub in toNotify) {
                if (sub.currentHub === closingHub) sub.currentHub = null
                sub.reprobeJob?.cancel()
                sub.reprobeJob = null
                sub.delegateSource?.cancel()
                if (!sub.cancelled) {
                    runCatching { sub.onClosed(null) }
                }
            }
        }
    }

    private val prefs: SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    val httpClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(45, TimeUnit.SECONDS)
        .writeTimeout(45, TimeUnit.SECONDS)
        .pingInterval(15, TimeUnit.SECONDS)
        .build()

    val sseHttpClient: OkHttpClient = httpClient.newBuilder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .pingInterval(15, TimeUnit.SECONDS)
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

    private val _placementVersion = MutableStateFlow(0L)
    val placementVersion: StateFlow<Long> = _placementVersion.asStateFlow()

    private val _hermesSessions = MutableStateFlow<List<OrbRow>>(emptyList())
    val hermesSessions: StateFlow<List<OrbRow>> = _hermesSessions.asStateFlow()

    private val _workspaces = MutableStateFlow<List<OrbRow>>(emptyList())
    val workspaces: StateFlow<List<OrbRow>> = _workspaces.asStateFlow()

    private val _backends = MutableStateFlow<List<OrbRow>>(emptyList())
    val backends: StateFlow<List<OrbRow>> = _backends.asStateFlow()

    private val _backendModels = MutableStateFlow<OrbDict>(emptyMap())
    val backendModels: StateFlow<OrbDict> = _backendModels.asStateFlow()

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

    private val _pendingSecretRequests = MutableStateFlow(0)
    /** Pending Bitwarden broker requests; a mission is blocked until one is answered. */
    val pendingSecretRequests: StateFlow<Int> = _pendingSecretRequests.asStateFlow()

    fun updatePendingSecretRequests(count: Int) {
        _pendingSecretRequests.value = count
    }

    suspend fun refreshSecretRequests() {
        if (!isConfigured) return
        runCatching { OrbBitwardenApi.pending(OrbBitwardenApi.broker(this)).size }
            .onSuccess { _pendingSecretRequests.value = it }
    }

    private val _assistantStatus = MutableStateFlow<OrbDict>(emptyMap())
    val assistantStatus: StateFlow<OrbDict> = _assistantStatus.asStateFlow()

    private val _authModeFlow = MutableStateFlow("single_tenant")
    val authModeFlow: StateFlow<String> = _authModeFlow.asStateFlow()

    private val _currentUserFlow = MutableStateFlow<CurrentUser?>(null)
    val currentUserFlow: StateFlow<CurrentUser?> = _currentUserFlow.asStateFlow()

    private val _authCapabilitiesFlow = MutableStateFlow<AuthCapabilities?>(null)
    val authCapabilitiesFlow: StateFlow<AuthCapabilities?> = _authCapabilitiesFlow.asStateFlow()

    val isAdminUser: Boolean
        get() = computeIsAdmin(_authModeFlow.value, _currentUserFlow.value)

    suspend fun refreshCurrentUser() {
        if (!isConfigured) return
        try {
            val res = OrbJSON.dict(request("/api/auth/me")) ?: return
            OrbJSON.str(res, "auth_mode")?.trim()?.takeIf { it.isNotEmpty() }?.let {
                _authModeFlow.value = it
            }
            val u = OrbJSON.dict(res["user"])
            if (u != null) {
                val id = OrbJSON.str(u, "id")?.trim().orEmpty()
                val username = OrbJSON.str(u, "username")?.trim().orEmpty()
                if (id.isNotEmpty() && username.isNotEmpty()) {
                    val role = if (OrbJSON.str(u, "role") == "admin") "admin" else "member"
                    val unix = OrbJSON.str(u, "unix_username")?.trim()?.takeIf { it.isNotEmpty() }
                    val cap = OrbJSON.double(u, "daily_spend_cap_cents")?.let { kotlin.math.round(it).toInt() }
                    val spent = OrbJSON.double(u, "spent_today_cents")?.let { maxOf(0, kotlin.math.round(it).toInt()) } ?: 0
                    _currentUserFlow.value = CurrentUser(
                        id = id,
                        username = username,
                        role = role,
                        unixUsername = unix,
                        dailySpendCapCents = cap,
                        spentTodayCents = spent,
                    )
                } else {
                    _currentUserFlow.value = null
                }
            } else {
                _currentUserFlow.value = null
            }
            val caps = OrbJSON.dict(res["capabilities"])
            _authCapabilitiesFlow.value = if (caps != null) {
                AuthCapabilities(
                    canManageUsers = OrbJSON.bool(caps, "can_manage_users") == true,
                    canUseCoreTarget = OrbJSON.bool(caps, "can_use_core_target") == true,
                    canManageGlobalProviders = OrbJSON.bool(caps, "can_manage_global_providers") == true,
                )
            } else {
                null
            }
        } catch (ce: CancellationException) {
            throw ce
        } catch (err: OrbError) {
            if (err.status == 404) {
                runCatching {
                    val st = OrbJSON.dict(request("/api/auth/status"))
                    if (st != null) {
                        _authModeFlow.value = OrbJSON.str(st, "auth_mode")?.trim()?.takeIf { it.isNotEmpty() } ?: "single_tenant"
                        _currentUserFlow.value = null
                        _authCapabilitiesFlow.value = null
                    }
                }
            }
        } catch (_: Throwable) {
            // Keep prior cached identity across transient network blips.
        }
    }


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

    /** Log attached to the current error notice. Every value set here also lands in [OrbLog.ring]. */
    private val _lastErrorLog = MutableStateFlow<String?>(null)
    val lastErrorLog: StateFlow<String?> = _lastErrorLog.asStateFlow()

    /** Set when the server cannot be reached at all; the home screen shows an actionable card. */
    private val _connectionIssue = MutableStateFlow<OrbConnectionIssue?>(null)
    val connectionIssue: StateFlow<OrbConnectionIssue?> = _connectionIssue.asStateFlow()

    /** Last successful [refreshAll], epoch ms (shown on Debug info). */
    private val _lastRefreshAtMs = MutableStateFlow<Long?>(null)
    val lastRefreshAtMs: StateFlow<Long?> = _lastRefreshAtMs.asStateFlow()

    private fun recordErrorLog(log: String?, message: String? = null) {
        _lastErrorLog.value = log
        if (log != null || message != null) {
            OrbLog.e(OrbLog.Category.Network, message ?: log!!.lineSequence().first(), detail = log)
        }
    }

    init {
        OrbDisk.init(context)
        OrbCrashBreadcrumbs.install(context)
        OrbSharedInboxState.init(context)
        OrbKeychain.init(context)
        OrbBackgroundSyncMonitor.init(context)
        OrbWarmSyncCoordinator.bindCore(this)
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
        if (cleanBase.isNotEmpty() && !loadedToken.isNullOrEmpty()) {
            _isLoading.value = true
        }
        OrbDisk.setAccountScope(cleanBase, loadedToken)
        scope.launch(Dispatchers.IO) {
            loadCachedSnapshots()
        }
        startLiveRefreshLoop()
    }

    fun configureSession(baseURL: String, token: String?, password: String? = null, username: String? = null) {
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
        if (previousBase != cleanBase) {
            transportEpoch.applyEndpoint(cleanBase, System.currentTimeMillis())
            transportBuildEpoch.incrementAndGet()
        }
        _baseURL.value = cleanBase
        _token.value = cleanToken
        if (!password.isNullOrEmpty() && cleanBase.isNotEmpty()) {
            OrbKeychain.write(CREDENTIALS_SERVICE, cleanBase, password)
            val cleanUser = username?.trim()?.takeIf { it.isNotEmpty() }
            prefs.edit().apply {
                if (cleanUser != null) putString("orb.username.$cleanBase", cleanUser)
                else remove("orb.username.$cleanBase")
            }.apply()
        }
        persistSession()
    }

    fun savedUsername(baseURL: String = _baseURL.value): String =
        prefs.getString("orb.username.${baseURL.trim().trimEnd('/')}", null).orEmpty()

    fun clearSession() {
        val cleanBase = _baseURL.value.trim().trimEnd('/')
        if (cleanBase.isNotEmpty()) {
            OrbKeychain.write(KEYCHAIN_SERVICE, cleanBase, null)
            OrbKeychain.write(CREDENTIALS_SERVICE, cleanBase, null)
            prefs.edit().remove("$TOKEN_FALLBACK_KEY.$cleanBase").remove("orb.username.$cleanBase").apply()
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

    private fun resetInMemoryAccountState() {
        OrbMissionTree.resetHierarchy()
        _projects.value = emptyList()
        _missions.value = emptyList()
        _hermesSessions.value = emptyList()
        _workspaces.value = emptyList()
        _backends.value = emptyList()
        _backendModels.value = emptyMap()
        _repositories.value = emptyList()
        _providers.value = emptyList()
        _providerPortfolio.value = emptyMap()
        _nodes.value = emptyList()
        _fleetSummary.value = emptyMap()
        _assistantStatus.value = emptyMap()
        _authModeFlow.value = "single_tenant"
        _currentUserFlow.value = null
        _authCapabilitiesFlow.value = null
        _pendingSecretRequests.value = 0
        _hasLoadedSuccessfully.value = false
        _lastError.value = null
        _lastErrorLog.value = null
        _connectionIssue.value = null
        endpointCooldownUntilMs.clear()
        resetMissionDeltaState()
    }

    /** Fresh rows update known missions without removing older rows absent from the global page. */
    private fun seedMissionAndProjectCaches(missionsList: List<OrbRow>, fresh: Boolean = false) {
        val byProject = mutableMapOf<String, MutableList<OrbRow>>()
        for (m in OrbMissionTree.filterMobile(missionsList)) {
            val tags = OrbJSON.strList(m.raw, "tags")
            val hist = m.rows("history")
            if (hist.isNotEmpty()) {
                OrbReadCache.saveRowsMemoryOnly("mission_msgs_${m.id}", hist)
            }
            val projTag = tags.firstOrNull { it.startsWith("project:") }?.removePrefix("project:")
            val proj = OrbMissionTree.effectiveProject(m, fallback = projTag).lowercase().trim()
            if (proj.isNotEmpty()) {
                byProject.getOrPut(proj) { mutableListOf() }.add(m)
            }
        }
        for ((proj, rows) in byProject) {
            OrbReadCache.seedProjectRows(proj, rows, fresh)
        }
    }

    private fun loadCachedSnapshots() {
        val p = OrbJSON.dictList(OrbDisk.read("projects")).map { OrbRow(it) }
        val m = OrbMissionTree.filterMobile(OrbJSON.dictList(OrbDisk.read("missions")).map { OrbRow(it) })
        val h = OrbJSON.dictList(OrbDisk.read("hermes_sessions")).map { OrbRow(it) }
        val w = OrbJSON.dictList(OrbDisk.read("workspaces")).map { OrbRow(it) }
        val b = OrbJSON.dictList(OrbDisk.read("backends")).map { OrbRow(it) }
        val bm = OrbJSON.dict(OrbDisk.read("backend_models")) ?: emptyMap()
        val r = OrbJSON.dictList(OrbDisk.read("repositories")).map { OrbRow(it) }
        val pr = OrbJSON.dictList(OrbDisk.read("providers")).map { OrbRow(it) }
        val n = OrbJSON.dictList(OrbDisk.read("nodes")).map { OrbRow(it) }
        seedMissionAndProjectCaches(m)
        _projects.value = p
        _missions.value = m
        _hermesSessions.value = h
        _workspaces.value = w
        _backends.value = b
        _backendModels.value = bm
        _repositories.value = r
        _providers.value = pr
        _nodes.value = n
        if (p.isNotEmpty() || m.isNotEmpty() || h.isNotEmpty()) {
            _hasLoadedSuccessfully.value = true
            _isLoading.value = false
        }
        OrbReadCache.prewarmRecentConversations(m)
    }

    /** "host:port" of the HTTP proxy the system routes [base] through, or null for direct. */
    private fun systemProxyFor(base: String): String? = try {
        java.net.ProxySelector.getDefault()?.select(java.net.URI(base))
            ?.firstOrNull { it.type() != java.net.Proxy.Type.DIRECT }
            ?.address()?.let { it as? java.net.InetSocketAddress }
            ?.let { "${it.hostString}:${it.port}" }
    } catch (_: Exception) {
        null
    }

    /** GET /api/health on the default server without credentials; true when it answers. */
    private fun probeDefaultServer(): Boolean = try {
        val req = okhttp3.Request.Builder().url("${OrbConnection.DEFAULT_BASE_URL}/api/health").get().build()
        httpClient.newCall(req).execute().use { it.code in 200..499 }
    } catch (t: Throwable) {
        OrbLog.w(OrbLog.Category.Network, "default server probe failed", t)
        false
    }

    /** Switch to [OrbConnection.DEFAULT_BASE_URL], reusing a token saved for it, then refresh. */
    suspend fun useDefaultServer() {
        val base = OrbConnection.DEFAULT_BASE_URL
        val saved = OrbKeychain.read(KEYCHAIN_SERVICE, base) ?: prefs.getString("$TOKEN_FALLBACK_KEY.$base", null)
        configureSession(base, saved, null)
        refreshAll()
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

    private val _isForeground = MutableStateFlow(false)
    val isForeground: StateFlow<Boolean> = _isForeground.asStateFlow()

    private val quietRefreshMutex = Mutex()
    @Volatile private var lastMissionsDiskWriteAtMs: Long = 0L
    @Volatile private var dirtyMissionsSnapshot: Pair<List<OrbRow>, List<OrbRow>>? = null
    @Volatile private var missionDeltaScope: String = ""
    @Volatile private var missionDeltaCursor: String? = null
    @Volatile private var missionDeltaPolls: Int = 0
    @Volatile private var missionDeltaLastFullAtMs: Long = 0L
    @Volatile private var missionDeltaCache: List<OrbRow> = emptyList()

    private fun resetMissionDeltaState() {
        missionDeltaScope = ""
        missionDeltaCursor = null
        missionDeltaPolls = 0
        missionDeltaLastFullAtMs = 0L
        missionDeltaCache = emptyList()
        closeSyncHub()
    }

    private fun advanceMissionDeltaCursor(rows: List<OrbRow>) {
        var maxEpoch = OrbJSON.dateEpochMs(missionDeltaCursor) ?: 0L
        for (row in rows) {
            val epoch = OrbJSON.dateEpochMs(row.str("updated_at", "created_at")) ?: 0L
            if (epoch > maxEpoch) maxEpoch = epoch
            val metaEpoch = OrbJSON.dateEpochMs(row.str("metadata_updated_at")) ?: 0L
            if (metaEpoch > maxEpoch) maxEpoch = metaEpoch
        }
        if (maxEpoch > 0L) {
            missionDeltaCursor = Instant.ofEpochMilli(maxOf(0L, maxEpoch - 2_000L)).toString()
        }
    }

    private suspend fun syncRecentMissions(limit: Int = 100, forceFull: Boolean = false): List<OrbRow> {
        val currentScope = "${_baseURL.value.trim()}|${_token.value.orEmpty()}|$limit"
        val now = System.currentTimeMillis()
        val needFull = forceFull ||
            missionDeltaScope != currentScope ||
            missionDeltaCursor == null ||
            missionDeltaCache.isEmpty() ||
            missionDeltaPolls >= 20 ||
            (now - missionDeltaLastFullAtMs) >= 600_000L

        if (needFull) {
            val full = fetchRows("/api/control/missions?limit=$limit&all=true", null)
            missionDeltaScope = currentScope
            missionDeltaCache = full
            missionDeltaPolls = 0
            missionDeltaLastFullAtMs = now
            missionDeltaCursor = null
            advanceMissionDeltaCursor(full)
            return full
        }

        val cursor = missionDeltaCursor.orEmpty()
        val delta = fetchRows("/api/control/missions?all=true&updated_since=${encodeComponent(cursor)}", null)
        missionDeltaPolls += 1
        if (delta.isNotEmpty()) {
            val byId = LinkedHashMap<String, OrbRow>()
            for (existing in missionDeltaCache) byId[existing.id] = existing
            for (updated in delta) {
                OrbMissionTree.observe(updated)
                byId[updated.id] = updated
            }
            val merged = byId.values.sortedByDescending {
                OrbJSON.dateEpochMs(it.str("updated_at", "created_at")) ?: 0L
            }.take(limit)
            missionDeltaCache = merged
            advanceMissionDeltaCursor(delta)
        }
        return missionDeltaCache
    }

    fun onForeground() {
        val wasBackground = !_isForeground.value
        _isForeground.value = true
        if (wasBackground && isConfigured && !_isLoading.value) {
            scope.launch { refreshMissionsQuietly() }
        }
    }

    /** Reconciles an authoritative single-mission update into in-memory and project caches immediately. */
    fun upsertMissionInMemory(updated: OrbRow) {
        if (updated.id.isEmpty()) return
        val current = _missions.value
        if (current.any { it.id == updated.id }) {
            _missions.value = current.map { if (it.id == updated.id) updated else it }
        }
        val delta = missionDeltaCache
        if (delta.any { it.id == updated.id }) {
            missionDeltaCache = delta.map { if (it.id == updated.id) updated else it }
        }
        val proj = updated.str("project", "project_id")
        if (!proj.isNullOrEmpty()) {
            OrbReadCache.seedProjectRows(proj, listOf(updated), fresh = true)
        }
    }

    /** Removes a mission from in-memory and delta caches (e.g. after leaving a shared mission). */
    fun removeMissionInMemory(missionId: String) {
        if (missionId.isEmpty()) return
        _missions.value = _missions.value.filterNot { it.id == missionId }
        missionDeltaCache = missionDeltaCache.filterNot { it.id == missionId }
    }

    fun onBackground() {
        _isForeground.value = false
        val snapshot = dirtyMissionsSnapshot
        if (snapshot != null) {
            dirtyMissionsSnapshot = null
            lastMissionsDiskWriteAtMs = System.currentTimeMillis()
            val account = OrbDisk.currentScope()
            scope.launch(Dispatchers.IO) {
                if (account == OrbDisk.currentScope()) {
                    OrbDisk.write("missions", snapshot.first.map { it.raw })
                    OrbDisk.write("projects", snapshot.second.map { it.raw })
                }
            }
        }
    }

    private fun startLiveRefreshLoop() {
        scope.launch {
            while (isActive) {
                val intervalMs = if (OrbPresentation.isConnected) 30_000L else 8_000L
                delay(intervalMs)
                if (!_isForeground.value || !isConfigured || _isLoading.value) continue
                refreshMissionsQuietly()
            }
        }
    }

    suspend fun refreshMissionsQuietly(forceDiskFlush: Boolean = false, forceFull: Boolean = false) {
        if (!quietRefreshMutex.tryLock()) return
        var liveRows: List<OrbRow> = emptyList()
        var prefetchTargets: List<OrbRow> = emptyList()
        try {
            coroutineScope {
                val mDeferred = async { syncRecentMissions(limit = 100, forceFull = forceFull) }
                val pDeferred = async { fetchRows("/api/projects", "projects") }
                val m = OrbMissionTree.filterMobile(mDeferred.await())
                val p = pDeferred.await()
                _missions.value = m
                _projects.value = p
                _hasLoadedSuccessfully.value = true
                val now = System.currentTimeMillis()
                val shouldWriteDisk = forceDiskFlush || !_isForeground.value || (now - lastMissionsDiskWriteAtMs >= 30_000L)
                if (shouldWriteDisk) {
                    dirtyMissionsSnapshot = null
                    lastMissionsDiskWriteAtMs = now
                } else {
                    dirtyMissionsSnapshot = m to p
                }
                withContext(Dispatchers.IO) {
                    seedMissionAndProjectCaches(m, fresh = true)
                    if (shouldWriteDisk) {
                        OrbDisk.write("missions", m.map { it.raw })
                        OrbDisk.write("projects", p.map { it.raw })
                    }
                }
                liveRows = m.filter { OrbMissionTree.isLive(it) && it.str("backend")?.startsWith("cloud_") != true }.take(8)
                prefetchTargets = (liveRows + m.take(5)).distinctBy { it.id }.filter { it.id.isNotEmpty() && it.str("backend")?.startsWith("cloud_") != true }
            }
        } catch (t: Throwable) {
            if (t !is CancellationException) OrbLog.w(OrbLog.Category.Network, "quiet missions refresh failed", t)
            return
        } finally {
            quietRefreshMutex.unlock()
        }

        // Run background warm sync & P2-bounded event prefetches outside `quietRefreshMutex`
        // so foreground/periodic mission refreshes never stall behind speculative event downloads.
        withContext(Dispatchers.IO) {
            OrbWarmSyncCoordinator.noteLiveMissionIds(this@OrbCore, liveRows.map { it.id })
            val p2Cap = OrbBackgroundSyncMonitor.linkBudget.p2Cap
            if (p2Cap > 0 && prefetchTargets.isNotEmpty()) {
                val prefetchSem = kotlinx.coroutines.sync.Semaphore(minOf(3, p2Cap))
                coroutineScope {
                    prefetchTargets.map { row ->
                        async {
                            if (OrbBackgroundSyncMonitor.linkBudget.p2Cap <= 0) return@async
                            val evKey = "mission_events_${row.id}"
                            if (OrbReadCache.loadRows(evKey).isEmpty()) {
                                prefetchSem.acquire()
                                val evs = try {
                                    if (OrbBackgroundSyncMonitor.linkBudget.p2Cap <= 0) emptyList()
                                    else orbTry(OrbLog.Category.Network, "/api/control/missions") {
                                        fetchRows("/api/control/missions/${encodeComponent(row.id)}/events?limit=150&max_payload=${OrbReadCache.RESULT_KEEP_CHARS}", "events")
                                    }.onFailure { if (it is CancellationException) throw it }.getOrDefault(emptyList())
                                } finally {
                                    prefetchSem.release()
                                }
                                if (evs.isNotEmpty()) {
                                    OrbReadCache.saveRows(evKey, evs)
                                }
                            }
                        }
                    }.awaitAll()
                }
            }
        }
    }

    suspend fun refreshAll() {
        if (!isConfigured) return
        _isLoading.value = true
        _lastError.value = null
        _lastErrorLog.value = null

        coroutineScope {
            val meTask = async { runCatching { refreshCurrentUser() } }
            val pTask = async { orbTry(OrbLog.Category.Network, "/api/projects") { fetchRows("/api/projects", "projects") } }
            val mTask = async { orbTry(OrbLog.Category.Network, "/api/control/missions") { syncRecentMissions(limit = 100, forceFull = true) } }
            val wTask = async { orbTry(OrbLog.Category.Network, "/api/workspaces") { fetchRows("/api/workspaces", null) } }
            val bTask = async { orbTry(OrbLog.Category.Network, "/api/backends") { fetchRows("/api/backends", null) } }
            val bmTask = async { orbTry(OrbLog.Category.Network, "/api/providers/backend-models") { fetchDict("/api/providers/backend-models") } }
            val prTask = async { orbTry(OrbLog.Category.Network, "/api/ai/providers") { fetchRows("/api/ai/providers", "providers") } }
            val nTask = async { orbTry(OrbLog.Category.Network, "/api/remote-nodes") { fetchDict("/api/remote-nodes") } }
            val aTask = async { orbTry(OrbLog.Category.Network, "/api/system/hermes-assistant/status") { fetchDict("/api/system/hermes-assistant/status") } }

            meTask.await()
            val pResult = pTask.await()
            val mResult = mTask.await()
            var anyCoreSuccess = false

            pResult.onSuccess { p ->
                _projects.value = p
                anyCoreSuccess = true
                launch(Dispatchers.IO) { OrbDisk.write("projects", p.map { it.raw }) }
            }
            mResult.onSuccess { rawM ->
                val m = OrbMissionTree.filterMobile(rawM)
                _missions.value = m
                anyCoreSuccess = true
                launch(Dispatchers.IO) {
                    seedMissionAndProjectCaches(m, fresh = true)
                    OrbDisk.write("missions", m.map { it.raw })
                    val liveRows = m.filter { OrbMissionTree.isLive(it) && it.str("backend")?.startsWith("cloud_") != true }.take(8)
                    val prefetchTargets = (liveRows + m.take(5)).distinctBy { it.id }.filter { it.id.isNotEmpty() && it.str("backend")?.startsWith("cloud_") != true }
                    coroutineScope {
                        prefetchTargets.map { row ->
                            async {
                                val evKey = "mission_events_${row.id}"
                                if (OrbReadCache.loadRows(evKey).isEmpty()) {
                                    val evs = orbTry(OrbLog.Category.Network, "/api/control/missions") {
                                        fetchRows("/api/control/missions/${encodeComponent(row.id)}/events?limit=150&max_payload=${OrbReadCache.RESULT_KEEP_CHARS}", "events")
                                    }.onFailure { if (it is CancellationException) throw it }.getOrDefault(emptyList())
                                    if (evs.isNotEmpty()) {
                                        OrbReadCache.saveRows(evKey, evs)
                                    }
                                }
                            }
                        }.awaitAll()
                    }
                    OrbWarmSyncCoordinator.noteLiveMissionIds(this@OrbCore, liveRows.map { it.id })
                }
            }
            wTask.await().onSuccess { w ->
                _workspaces.value = w
                launch(Dispatchers.IO) { OrbDisk.write("workspaces", w.map { it.raw }) }
            }
            bTask.await().onSuccess { b ->
                _backends.value = b
                launch(Dispatchers.IO) { OrbDisk.write("backends", b.map { it.raw }) }
            }
            bmTask.await().onSuccess { bm ->
                val map = OrbJSON.dict(bm["backends"]) ?: bm
                _backendModels.value = map
                launch(Dispatchers.IO) { OrbDisk.write("backend_models", map) }
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

            val projectsFailedWhileEmpty = pResult.isFailure && _projects.value.isEmpty()
            if (anyCoreSuccess && !projectsFailedWhileEmpty) {
                _lastRefreshAtMs.value = System.currentTimeMillis()
                _hasLoadedSuccessfully.value = true
                _lastError.value = null
                _lastErrorLog.value = null
                _connectionIssue.value = null
            } else {
                val err = pResult.exceptionOrNull() ?: mResult.exceptionOrNull()
                if (err != null) {
                    _lastError.value = err.message ?: "Request failed"
                    recordErrorLog("baseURL=${_baseURL.value}\nerror=${err.message}", "refresh failed: ${err.message}")
                    if (!anyCoreSuccess) {
                        val failedBase = _baseURL.value
                        val proxy = systemProxyFor(failedBase)
                        _connectionIssue.value = OrbConnection.issue(failedBase, err.message, defaultReachable = null, proxy = proxy)
                        if (OrbConnection.shouldProbeDefault(failedBase, err.message)) {
                            launch(Dispatchers.IO) {
                                val reachable = probeDefaultServer()
                                if (_baseURL.value == failedBase && _connectionIssue.value != null) {
                                    _connectionIssue.value = OrbConnection.issue(failedBase, err.message, reachable, proxy)
                                }
                            }
                        }
                    } else {
                        _connectionIssue.value = null
                    }
                }
            }
        }
        _isLoading.value = false
    }

    private val endpointCooldownUntilMs = ConcurrentHashMap<String, Long>()
    private val openBundleUnsupportedScopes = ConcurrentHashMap.newKeySet<String>()
    private val inFlightSinglePrefetches = ConcurrentHashMap.newKeySet<String>()
    private val prefetchScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    suspend fun fetchMissionOpenBundle(
        id: String,
        sinceSeq: Long? = null,
        limit: Int = 150,
        maxPayload: Int = OrbReadCache.RESULT_KEEP_CHARS,
        spineLimit: Int = 400
    ): OrbDict? {
        val base = _baseURL.value.trim().trimEnd('/')
        if (base.isEmpty()) return null
        val scopeKey = "$base|${transportEpoch.serverBuild.orEmpty()}"
        if (openBundleUnsupportedScopes.contains(scopeKey)) return null
        val sinceParam = if (sinceSeq != null && sinceSeq > 0L) "&since_seq=$sinceSeq" else ""
        val path = "/api/control/missions/${encodeComponent(id)}/open?limit=$limit&max_payload=$maxPayload&spine_limit=$spineLimit$sinceParam"
        return try {
            val raw = request(path)
            val dict = OrbJSON.dict(raw) ?: return null
            val proto = (dict["protocol"] as? Number)?.toInt()
            if (proto != 1) {
                openBundleUnsupportedScopes.add(scopeKey)
                null
            } else {
                dict
            }
        } catch (err: OrbError) {
            if (err.status == 404 || err.status == 405 || err.status == 501) {
                openBundleUnsupportedScopes.add(scopeKey)
            }
            null
        } catch (ce: CancellationException) {
            throw ce
        } catch (_: Throwable) {
            null
        }
    }

    fun prefetchMissionSingle(missionId: String, isCloud: Boolean = false) {
        if (missionId.isEmpty() || isCloud) return
        if (OrbBackgroundSyncMonitor.linkBudget.p2Cap <= 0) return
        if (OrbReadCache.hasRowsInMemory("mission_events_$missionId")) return
        val account = OrbDisk.currentScope()
        val inflightKey = "$account|$missionId"
        if (!inFlightSinglePrefetches.add(inflightKey)) return
        prefetchScope.launch {
            try {
                if (account != OrbDisk.currentScope()) return@launch
                if (OrbReadCache.loadRows("mission_events_$missionId").isNotEmpty()) return@launch
                val bundle = fetchMissionOpenBundle(missionId) ?: return@launch
                if (account != OrbDisk.currentScope()) return@launch
                val spineRows = OrbJSON.dictList(bundle["spine"]).map { OrbRow(it) }
                val tailRows = OrbJSON.dictList(bundle["events"]).map { OrbRow(it) }
                val spineHasMore = bundle["spine_has_more"] as? Boolean
                val isColdSpineTruncated =
                    OrbJSON.bool(bundle, "has_more") == true &&
                        (spineHasMore == true || (spineHasMore == null && spineRows.size >= 80))
                val combined = OrbLiveEventReducer.mergeMissionEvents(emptyList(), spineRows + tailRows)
                if (combined.isNotEmpty()) {
                    OrbReadCache.saveRows("mission_events_$missionId", combined)
                }
                val histCandidates = (spineRows + tailRows).filter {
                    (it.str("event_type", "type") ?: "") in OrbConversationHistory.eventTypes
                }
                if (!isColdSpineTruncated && histCandidates.isNotEmpty()) {
                    val mergedHist = OrbConversationHistory.merge(emptyList(), histCandidates)
                    if (mergedHist.isNotEmpty()) {
                        OrbReadCache.saveRows("mission_msgs_$missionId", mergedHist)
                    }
                }
                OrbJSON.dict(bundle["mission"])?.let { detail ->
                    withContext(Dispatchers.Main) {
                        if (account == OrbDisk.currentScope()) {
                            upsertMissionInMemory(OrbRow(missionId, detail))
                        }
                    }
                }
            } finally {
                inFlightSinglePrefetches.remove(inflightKey)
            }
        }
    }

    private fun orderedCandidateEndpoints(primary: String): List<String> {
        val candidates = OrbConnection.candidateEndpoints(primary)
        if (candidates.size <= 1) return candidates
        val now = System.currentTimeMillis()
        val healthy = mutableListOf<String>()
        val cooling = mutableListOf<String>()
        for (url in candidates) {
            if ((endpointCooldownUntilMs[url] ?: 0L) > now) cooling.add(url) else healthy.add(url)
        }
        return healthy + cooling
    }

    fun makeURL(path: String, explicitBase: String? = null): String {
        val base = (explicitBase ?: _baseURL.value).trim().trimEnd('/')
        if (base.isEmpty()) throw OrbError("No server URL configured")
        val normalized = if (path.startsWith("/")) path else "/$path"
        return "$base$normalized"
    }

    suspend fun request(
        path: String,
        method: String = "GET",
        body: Any? = null,
        headers: Map<String, String> = emptyMap(),
        allowAuthRetry: Boolean = true,
        /** Exact JSON text to send (device-signed requests hash these bytes). */
        rawBody: String? = null,
        explicitBaseURL: String? = null,
        explicitToken: String? = null
    ): Any? = withContext(Dispatchers.IO) {
        val upperMethod = method.uppercase()
        val effectiveHeaders = LinkedHashMap<String, String>(headers)
        if (effectiveHeaders.keys.none { it.equals("Idempotency-Key", ignoreCase = true) } &&
            OrbConnection.shouldAttachIdempotencyKey(upperMethod, path)
        ) {
            effectiveHeaders["Idempotency-Key"] = UUID.randomUUID().toString()
        }
        val hasIdemKey = effectiveHeaders.entries.any {
            it.key.equals("Idempotency-Key", ignoreCase = true) && it.value.isNotBlank()
        }
        val idempotent = upperMethod == "GET" || upperMethod == "HEAD" || hasIdemKey
        val primaryBase = (explicitBaseURL ?: _baseURL.value).trim().trimEnd('/')
        if (primaryBase.isEmpty()) throw OrbError("No server URL configured")
        val candidates = if (idempotent) orderedCandidateEndpoints(primaryBase) else listOf(primaryBase)

        val cleanToken = (explicitToken ?: _token.value)?.trim()?.takeIf { it.isNotEmpty() }
        val requestBody = when {
            rawBody != null -> rawBody.toRequestBody("application/json; charset=utf-8".toMediaType())
            body != null -> {
                val jsonText = OrbJSON.stringify(body)
                jsonText.toRequestBody("application/json; charset=utf-8".toMediaType())
            }
            upperMethod in setOf("POST", "PUT", "PATCH") -> {
                "".toRequestBody("application/json; charset=utf-8".toMediaType())
            }
            else -> null
        }

        var code = 599
        var bytes = ByteArray(0)
        var lastIoError: IOException? = null
        outer@ for ((idx, base) in candidates.withIndex()) {
            val isLastCandidate = idx + 1 == candidates.size
            val maxAttempts = if (idempotent) 2 else 1
            for (attempt in 0 until maxAttempts) {
                val url = makeURL(path, explicitBase = base)
                val reqBuilder = Request.Builder().url(url).header("Accept", "application/json")
                if (cleanToken != null) {
                    reqBuilder.header("Authorization", "Bearer $cleanToken")
                }
                for ((k, v) in effectiveHeaders) {
                    reqBuilder.header(k, v)
                }
                reqBuilder.method(upperMethod, requestBody)
                val startedNs = System.nanoTime()
                try {
                    val response = httpClient.newCall(reqBuilder.build()).execute()
                    code = response.code
                    bytes = response.body?.bytes() ?: ByteArray(0)
                    response.close()
                    val elapsedMs = (System.nanoTime() - startedNs) / 1_000_000L
                    if (elapsedMs >= 1_500L) {
                        OrbPerfMonitor.recordSlowRequest(upperMethod, path, elapsedMs, bytes.size)
                    }
                    lastIoError = null
                    if (idempotent && OrbConnection.isFastRetryableStatus(code)) {
                        if (attempt + 1 < maxAttempts) {
                            delay(250L)
                            continue
                        }
                        if (!isLastCandidate) {
                            endpointCooldownUntilMs[base] = System.currentTimeMillis() + 20_000L
                            continue@outer
                        }
                    }
                    if (code < 500) endpointCooldownUntilMs.remove(base)
                    break@outer
                } catch (io: IOException) {
                    lastIoError = io
                    if (!idempotent) throw io
                    if (attempt + 1 < maxAttempts) {
                        delay(250L)
                        continue
                    }
                    if (!isLastCandidate) {
                        endpointCooldownUntilMs[base] = System.currentTimeMillis() + 20_000L
                    }
                }
            }
        }
        if (lastIoError != null) throw lastIoError

        val sameConnectionForRetry =
            (explicitBaseURL == null || _baseURL.value.trim().trimEnd('/') == primaryBase) &&
                (explicitToken == null || _token.value == explicitToken)
        if (code == 401 && allowAuthRetry && sameConnectionForRetry && path != "/api/auth/login" && path != "/api/auth/change-password") {
            if (renewSessionFromSavedCredentials()) {
                return@withContext request(
                    path = path,
                    method = method,
                    body = body,
                    headers = effectiveHeaders,
                    allowAuthRetry = false,
                    rawBody = rawBody,
                    explicitBaseURL = explicitBaseURL
                )
            }
        }

        if (code !in 200..299) {
            val raw = bytes.decodeToString()
            val parsed = OrbJSON.dict(OrbJSON.parse(bytes))
            val message = OrbJSON.str(parsed, "error", "message", "detail")
                ?: if (raw.isEmpty()) "HTTP $code" else raw.take(240)
            recordErrorLog("$method $path -> HTTP $code\n${raw.take(2000)}", "$method $path -> HTTP $code")
            throw OrbError(message, status = code, body = raw)
        }
        if (path.substringBefore('?') == "/api/health") {
            val parsed = OrbJSON.dict(OrbJSON.parse(bytes))
            val prevMode = transportEpoch.mode
            val prevSticky = transportEpoch.stickyUnsupported
            transportEpoch.noteServerBuild(OrbJSON.str(parsed, "version"), System.currentTimeMillis())
            if (transportEpoch.mode != prevMode || transportEpoch.stickyUnsupported != prevSticky) {
                transportBuildEpoch.incrementAndGet()
            }
        }
        if (bytes.isEmpty()) return@withContext emptyMap<String, Any?>()
        OrbJSON.parse(bytes) ?: emptyMap<String, Any?>()
    }

    private suspend fun renewSessionFromSavedCredentials(): Boolean = withContext(Dispatchers.IO) {
        val cleanBase = _baseURL.value.trim().trimEnd('/')
        if (cleanBase.isEmpty()) return@withContext false
        val password = OrbKeychain.read(CREDENTIALS_SERVICE, cleanBase)?.trim()?.takeIf { it.isNotEmpty() }
            ?: return@withContext false
        val savedUser = prefs.getString("orb.username.$cleanBase", null)?.trim()?.takeIf { it.isNotEmpty() }
        try {
            val url = makeURL("/api/auth/login")
            val loginMap = LinkedHashMap<String, Any?>().apply {
                put("password", password)
                if (savedUser != null) put("username", savedUser)
            }
            val body = OrbJSON.stringify(loginMap)
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
        } catch (t: Throwable) {
            if (t !is CancellationException) OrbLog.w(OrbLog.Category.Auth, "session renewal failed", t)
            false
        }
    }

    suspend fun requestBytes(
        path: String,
        method: String = "GET",
        headers: Map<String, String> = emptyMap(),
        rawBytes: ByteArray? = null,
        contentType: String? = null,
        allowAuthRetry: Boolean = true,
        explicitBaseURL: String? = null,
        explicitToken: String? = null
    ): ByteArray = withContext(Dispatchers.IO) {
        val upperMethod = method.uppercase()
        val targetBase = (explicitBaseURL ?: _baseURL.value).trim().trimEnd('/')
        val url = makeURL(path, explicitBase = targetBase)
        val cleanToken = (explicitToken ?: _token.value)?.trim()?.takeIf { it.isNotEmpty() }
        val reqBody = rawBytes?.toRequestBody((contentType ?: "application/octet-stream").toMediaType())
        val reqBuilder = Request.Builder().url(url)
        if (cleanToken != null) {
            reqBuilder.header("Authorization", "Bearer $cleanToken")
        }
        for ((k, v) in headers) {
            reqBuilder.header(k, v)
        }
        reqBuilder.method(upperMethod, reqBody)
        val resp = httpClient.newCall(reqBuilder.build()).execute()
        val code = resp.code
        val bytes = resp.body?.bytes() ?: ByteArray(0)
        resp.close()
        val sameConnectionForRetry =
            (explicitBaseURL == null || _baseURL.value.trim().trimEnd('/') == targetBase) &&
                (explicitToken == null || _token.value == explicitToken)
        if (code == 401 && allowAuthRetry && sameConnectionForRetry && renewSessionFromSavedCredentials()) {
            return@withContext requestBytes(
                path = path,
                method = method,
                headers = headers,
                rawBytes = rawBytes,
                contentType = contentType,
                allowAuthRetry = false,
                explicitBaseURL = explicitBaseURL
            )
        }
        if (code !in 200..299) {
            val raw = bytes.decodeToString()
            val parsed = OrbJSON.dict(OrbJSON.parse(bytes))
            val message = OrbJSON.str(parsed, "error", "message", "detail")
                ?: if (raw.isEmpty()) "HTTP $code" else raw.take(240)
            recordErrorLog("$method $path -> HTTP $code\n${raw.take(2000)}", "$method $path -> HTTP $code")
            throw OrbError(message, status = code, body = raw.take(2000))
        }
        bytes
    }

    suspend fun fetchDict(path: String): OrbDict {
        val res = request(path)
        return OrbJSON.dict(res) ?: emptyMap()
    }

    private suspend fun fetchAncestor(id: String): OrbRow? {
        OrbMissionTree.cachedAncestor(id)?.let { return it }
        return try {
            val raw = fetchDict("/api/control/missions/${encodeComponent(id)}?include_history=false")
            if (raw.isEmpty()) return null
            val row = OrbRow(raw, id)
            val hist = row.rows("history")
            if (hist.isNotEmpty()) {
                OrbReadCache.saveRowsMemoryOnly("mission_msgs_${row.id}", hist)
            }
            OrbMissionTree.storeAncestor(row)
            row
        } catch (e: CancellationException) {
            throw e
        } catch (e: OrbError) {
            if (e.status == 404) {
                OrbMissionTree.markGone(id)
                null
            } else {
                OrbMissionTree.cachedAncestor(id, allowStale = true)
            }
        } catch (_: Throwable) {
            OrbMissionTree.cachedAncestor(id, allowStale = true)
        }
    }

    /** A project's recent history plus open missions beyond the page (`openBeyondPage`, M2)
     * and any paged-out ancestors (`withAncestors`), matching desktop `listProjectMissions` and iOS `missions`. */
    suspend fun projectMissions(projectSlug: String, includeArchived: Boolean = false): List<OrbRow> = coroutineScope {
        val encoded = encodeComponent(projectSlug)
        val history = ArrayList<OrbRow>()
        val liveRows = ArrayList<OrbRow>()
        if (includeArchived) {
            var offset = 0
            while (true) {
                val page = fetchRows("/api/control/missions?project=$encoded&all=true&limit=100&offset=$offset", null)
                val existingIds = history.mapTo(mutableSetOf()) { it.id }
                val fresh = page.filter { it.id !in existingIds }
                history.addAll(fresh)
                if (page.size < 100 || fresh.isEmpty()) break
                offset += page.size
            }
        } else {
            val historyDeferred = async { fetchRows("/api/control/missions?project=$encoded&all=true&limit=100&offset=0", null) }
            val firstLiveDeferred = async { fetchRows("/api/control/missions?project=$encoded&limit=200", null) }
            history.addAll(historyDeferred.await())
            val livePages = mutableListOf(firstLiveDeferred.await())
            var offset = 200
            while (livePages.last().size == 200 && offset < 1000) {
                livePages.add(fetchRows("/api/control/missions?project=$encoded&limit=200&offset=$offset", null))
                offset += 200
            }
            for (page in livePages) liveRows.addAll(page)
        }

        val byId = LinkedHashMap<String, OrbRow>()
        val beyond = if (includeArchived) emptyList() else OrbMissionTree.openBeyondPage(history, liveRows)
        for (row in history + beyond) byId.putIfAbsent(row.id, row)
        val merged = byId.values.sortedByDescending {
            OrbJSON.dateEpochMs(it.str("updated_at", "created_at")) ?: 0L
        }
        val ownIds = merged.mapTo(mutableSetOf()) { it.id }
        val withParents = OrbMissionTree.withAncestors(merged) { fetchAncestor(it) }
        val scoped = OrbMissionTree.filterToProjectScope(withParents, projectSlug = projectSlug, ownIds = ownIds)
        OrbMissionTree.mergePendingStagedRows(OrbMissionTree.filterMobile(scoped), projectSlug = projectSlug)
    }

    /** Reconciles in-memory mission lists, delta cache, and per-project read caches after optimistic or authoritative placement changes. */
    fun applyPlacementCommit(
        accepted: List<OrbPlacementCommitItem>,
        extraRows: Collection<OrbRow> = emptyList()
    ) {
        if (accepted.isEmpty()) return
        val byId = accepted.associateBy { it.missionId }
        val fallbackRows = LinkedHashMap<String, OrbRow>()
        for (r in extraRows) fallbackRows[r.id] = r
        for (r in _missions.value) fallbackRows.putIfAbsent(r.id, r)
        for (r in missionDeltaCache) fallbackRows.putIfAbsent(r.id, r)

        if (_missions.value.any { it.id in byId }) {
            _missions.value = _missions.value.map { row ->
                val item = byId[row.id] ?: return@map row
                OrbReadCache.patchRowPlacement(row, item)
            }
        }
        if (missionDeltaCache.any { it.id in byId }) {
            missionDeltaCache = missionDeltaCache.map { row ->
                val item = byId[row.id] ?: return@map row
                OrbReadCache.patchRowPlacement(row, item)
            }
        }
        val persistToDisk = accepted.none { it.isPreview }
        OrbReadCache.applyPlacementCommit(accepted, fallbackRows, persistToDisk = persistToDisk)
        _placementVersion.value = _placementVersion.value + 1L
    }

    /** Batch-moves root missions (and their full family subtrees on Core) atomically via `POST /api/control/missions/move`. */
    suspend fun moveMissions(
        ids: List<String>,
        project: String?,
        folder: String = "",
        approvalPolicy: String = "check",
        clientOpId: Int = 0
    ): List<OrbPlacementCommitItem> {
        val cleanFolder = OrbMissionTree.normalizeFolder(folder)
        val body = LinkedHashMap<String, Any?>().apply {
            put("mission_ids", ids)
            put("folder", cleanFolder)
            put("approval_policy", approvalPolicy)
            if (!project.isNullOrBlank()) put("project", project.trim())
            if (clientOpId > 0) {
                put("client_op_id", clientOpId)
                put("client_id", OrbMissionTree.localClientId)
            }
        }
        val response = try {
            request("/api/control/missions/move", method = "POST", body = body)
        } catch (t: Throwable) {
            OrbApprovalTransferConfirmationException.parse(t)?.let { throw it }
            throw t
        }
        val root = OrbJSON.dict(response)
        val rawMoves = OrbJSON.dictList(root?.get("moved")).ifEmpty { OrbJSON.dictList(root?.get("moves")) }
        val rawRespOpId = (root?.get("client_op_id") as? Number)?.toInt() ?: clientOpId
        val respClientId = (root?.get("client_id") as? String)?.takeIf { it.isNotEmpty() } ?: OrbMissionTree.localClientId
        val respOpId = OrbMissionTree.resolveLocalAckOpId(rawRespOpId, respClientId)
        val items = rawMoves.mapNotNull { m ->
            val mid = OrbJSON.str(m, "mission_id", "id") ?: return@mapNotNull null
            val proj = OrbJSON.str(m, "project")?.takeIf { it.isNotEmpty() } ?: project?.trim()?.takeIf { it.isNotEmpty() }
            val fld = OrbMissionTree.normalizeFolder((m["folder"] as? String) ?: cleanFolder)
            val rev = maxOf(0L, (m["placement_revision"] as? Number)?.toLong() ?: 1L)
            OrbPlacementCommitItem(missionId = mid, project = proj, folder = fld, placementRevision = rev)
        }
        val accepted = OrbMissionTree.commitAuthoritativePlacements(items, ackOpId = respOpId)
        applyPlacementCommit(accepted)
        return accepted
    }

    /** Reconciles `moved_missions` returned by `POST /api/projects/:slug/file/transfer` folder rename/move cascades. */
    fun applyTransferMovedMissions(response: Any?, fallbackProject: String) {
        val root = OrbJSON.dict(response) ?: return
        val rawMoved = OrbJSON.dictList(root["moved_missions"])
        if (rawMoved.isEmpty()) return
        val items = rawMoved.mapNotNull { m ->
            val mid = OrbJSON.str(m, "mission_id", "id") ?: return@mapNotNull null
            val proj = OrbJSON.str(m, "project")?.takeIf { it.isNotEmpty() } ?: fallbackProject
            val fld = OrbMissionTree.normalizeFolder(m["folder"] as? String)
            val rev = maxOf(0L, (m["placement_revision"] as? Number)?.toLong() ?: 1L)
            OrbPlacementCommitItem(missionId = mid, project = proj, folder = fld, placementRevision = rev)
        }
        val accepted = OrbMissionTree.commitAuthoritativePlacements(items, ackOpId = 0)
        applyPlacementCommit(accepted)
    }

    /** Commits incoming `mission_placement_changed` WS/SSE payloads into `OrbMissionTree`, caches, and UI state. */
    fun applyIncomingPlacementEvent(rawEvent: Any?): List<OrbPlacementCommitItem> {
        val accepted = OrbMissionTree.commitIncomingPlacementEvent(rawEvent)
        if (accepted.isNotEmpty()) {
            applyPlacementCommit(accepted)
        }
        return accepted
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

    internal data class SyncStreamSub(
        val id: String,
        val missionId: String?,
        val kindFilter: String?,
        @Volatile var sinceSeq: Long?,
        val request: Request,
        val onEvent: (eventType: String?, data: String) -> Unit,
        val onClosed: (Throwable?) -> Unit,
        val fallbackFactory: (Long?) -> Unit,
        val onWsReady: () -> Unit = {},
        @Volatile var delegateSource: EventSource? = null,
        @Volatile var reprobeJob: Job? = null,
        @Volatile var currentHub: ControlSyncHub? = null,
        @Volatile var cancelled: Boolean = false
    )

    internal class TransportEpochState(
        var failThreshold: Int = DEFAULT_FAIL_THRESHOLD,
        var cooldownDurationMs: Long = DEFAULT_COOLDOWN_MS
    ) {
        data class ConnectEval(val allowWebSocket: Boolean, val sinceSeq: Long?)
        data class FailureEval(val fallbackToSse: Boolean, val sinceSeq: Long?)

        private val lock = Any()
        var mode: Int = MODE_WS_ACTIVE
            private set
        var everReady: Boolean = false
            private set
        var stickyUnsupported: Boolean = false
            private set
        var endpointClass: Int = 3
            private set
        var normalizedBaseURL: String = ""
            private set
        var serverBuild: String? = null
            private set
        var failureStreak: Int = 0
            private set
        var cooldownUntilMs: Long = 0L
            private set

        fun applyEndpoint(url: String, nowMs: Long, sinceSeq: Long? = null): Long? = synchronized(lock) {
            val clean = OrbConnection.normalize(url)
            val newClass = classifyEndpoint(clean)
            if (normalizedBaseURL.isEmpty()) {
                normalizedBaseURL = clean
                endpointClass = newClass
                return sinceSeq
            }
            if (clean == normalizedBaseURL) return sinceSeq
            val prevClass = endpointClass
            normalizedBaseURL = clean
            endpointClass = newClass
            serverBuild = null
            val event = if (newClass != prevClass) EVENT_COOLDOWN_CHECK else EVENT_SERVER_BUILD_CHANGED
            val (hasSeq, seq32) = packSinceSeq(sinceSeq)
            val verdict = OrbKernel.transportEpochStep(
                mode = mode,
                eventKind = event,
                everReady = everReady,
                stickyUnsupported = stickyUnsupported,
                endpointClass = newClass,
                prevEndpointClass = prevClass,
                hasSinceSeq = hasSeq,
                failureStreak = failureStreak,
                failThreshold = failThreshold,
                httpStatus = 0,
                sinceSeq32 = seq32,
                nowMs = nowMs.coerceAtLeast(0L),
                cooldownUntilMs = cooldownUntilMs
            )
            applyVerdictLocked(verdict)
            cooldownUntilMs = 0L
            everReady = false
            return unpackSinceSeq(verdict, sinceSeq)
        }

        fun noteServerBuild(build: String?, nowMs: Long, sinceSeq: Long? = null): Long? = synchronized(lock) {
            val clean = build?.trim()?.takeIf { it.isNotEmpty() } ?: return sinceSeq
            if (serverBuild == null) {
                serverBuild = clean
                return sinceSeq
            }
            if (serverBuild == clean) return sinceSeq
            serverBuild = clean
            val (hasSeq, seq32) = packSinceSeq(sinceSeq)
            val verdict = OrbKernel.transportEpochStep(
                mode = mode,
                eventKind = EVENT_SERVER_BUILD_CHANGED,
                everReady = everReady,
                stickyUnsupported = stickyUnsupported,
                endpointClass = endpointClass,
                prevEndpointClass = endpointClass,
                hasSinceSeq = hasSeq,
                failureStreak = failureStreak,
                failThreshold = failThreshold,
                httpStatus = 0,
                sinceSeq32 = seq32,
                nowMs = nowMs.coerceAtLeast(0L),
                cooldownUntilMs = cooldownUntilMs
            )
            applyVerdictLocked(verdict)
            cooldownUntilMs = 0L
            return unpackSinceSeq(verdict, sinceSeq)
        }

        fun noteWsReady(nowMs: Long) = synchronized(lock) {
            val verdict = OrbKernel.transportEpochStep(
                mode = mode,
                eventKind = EVENT_WS_READY,
                everReady = true,
                stickyUnsupported = stickyUnsupported,
                endpointClass = endpointClass,
                prevEndpointClass = endpointClass,
                hasSinceSeq = false,
                failureStreak = failureStreak,
                failThreshold = failThreshold,
                httpStatus = 0,
                sinceSeq32 = 0,
                nowMs = nowMs.coerceAtLeast(0L),
                cooldownUntilMs = cooldownUntilMs
            )
            everReady = true
            applyVerdictLocked(verdict)
            cooldownUntilMs = 0L
        }

        fun noteWsFailure(httpStatus: Int?, nowMs: Long, sinceSeq: Long? = null): FailureEval = synchronized(lock) {
            val safeNow = nowMs.coerceAtLeast(0L)
            val (hasSeq, seq32) = packSinceSeq(sinceSeq)
            val event = if (httpStatus != null) EVENT_HTTP_STATUS_FAILURE else EVENT_TRANSIENT_WS_FAILURE
            val normalizedStatus = if (isPermanentUnsupportedHttpStatus(httpStatus)) 404 else (httpStatus ?: 0).coerceAtLeast(0)
            val verdict = OrbKernel.transportEpochStep(
                mode = mode,
                eventKind = event,
                everReady = everReady,
                stickyUnsupported = stickyUnsupported,
                endpointClass = endpointClass,
                prevEndpointClass = endpointClass,
                hasSinceSeq = hasSeq,
                failureStreak = failureStreak,
                failThreshold = failThreshold,
                httpStatus = normalizedStatus,
                sinceSeq32 = seq32,
                nowMs = safeNow,
                cooldownUntilMs = cooldownUntilMs
            )
            applyVerdictLocked(verdict)
            if (verdict.fallbackActiveNext && !verdict.stickyUnsupportedNext) {
                cooldownUntilMs = safeNow + cooldownDurationMs
            } else if (verdict.stickyUnsupportedNext) {
                cooldownUntilMs = Long.MAX_VALUE
            }
            FailureEval(verdict.fallbackActiveNext, unpackSinceSeq(verdict, sinceSeq))
        }

        fun reprobeDelayMs(nowMs: Long): Long? = synchronized(lock) {
            if (mode != MODE_SSE_FALLBACK || stickyUnsupported) return null
            val safeNow = nowMs.coerceAtLeast(0L)
            if (cooldownUntilMs > safeNow) cooldownUntilMs - safeNow else 0L
        }

        fun evaluateForConnect(url: String, nowMs: Long, sinceSeq: Long? = null): ConnectEval = synchronized(lock) {
            val syncedSeq = applyEndpoint(url, nowMs, sinceSeq)
            if (mode != MODE_SSE_FALLBACK) {
                return ConnectEval(allowWebSocket = true, sinceSeq = syncedSeq)
            }
            val (hasSeq, seq32) = packSinceSeq(syncedSeq)
            val verdict = OrbKernel.transportEpochStep(
                mode = mode,
                eventKind = EVENT_COOLDOWN_CHECK,
                everReady = everReady,
                stickyUnsupported = stickyUnsupported,
                endpointClass = endpointClass,
                prevEndpointClass = endpointClass,
                hasSinceSeq = hasSeq,
                failureStreak = failureStreak,
                failThreshold = failThreshold,
                httpStatus = 0,
                sinceSeq32 = seq32,
                nowMs = nowMs.coerceAtLeast(0L),
                cooldownUntilMs = cooldownUntilMs
            )
            applyVerdictLocked(verdict)
            ConnectEval(allowWebSocket = !verdict.fallbackActiveNext, sinceSeq = unpackSinceSeq(verdict, syncedSeq))
        }

        private fun applyVerdictLocked(verdict: OrbKernel.TransportEpochVerdict) {
            if (!verdict.admitted) return
            mode = verdict.nextMode
            stickyUnsupported = verdict.stickyUnsupportedNext
            failureStreak = verdict.nextFailureStreak
        }

        companion object {
            const val MODE_WS_ACTIVE = 0
            const val MODE_SSE_FALLBACK = 1
            const val MODE_WS_REPROBE = 2

            const val EVENT_WS_READY = 0
            const val EVENT_TRANSIENT_WS_FAILURE = 1
            const val EVENT_HTTP_STATUS_FAILURE = 2
            const val EVENT_COOLDOWN_CHECK = 3
            const val EVENT_SERVER_BUILD_CHANGED = 4

            const val DEFAULT_FAIL_THRESHOLD = 3
            const val DEFAULT_COOLDOWN_MS = 30_000L

            fun isPermanentUnsupportedHttpStatus(status: Int?): Boolean =
                status == 404 || status == 405 || status == 501 || status == 426

            fun classifyEndpoint(url: String): Int {
                val lower = OrbConnection.normalize(url).lowercase()
                return when (lower) {
                    OrbConnection.DEFAULT_BASE_URL -> 0
                    OrbConnection.ORBCORE_BASE_URL -> 1
                    OrbConnection.KNOWN_DIRECT_BASE_URL -> 2
                    else -> 3
                }
            }

            private fun packSinceSeq(sinceSeq: Long?): Pair<Boolean, Int> {
                if (sinceSeq == null || sinceSeq < 0L) return false to 0
                val clamped = if (sinceSeq > 0xFFFF_FFFFL) 0xFFFF_FFFFL else sinceSeq
                return true to clamped.toInt()
            }

            private fun unpackSinceSeq(verdict: OrbKernel.TransportEpochVerdict, original: Long?): Long? {
                if (!verdict.hasPreservedSinceSeq) return null
                if (original != null && original > 0xFFFF_FFFFL) return original
                return verdict.preservedSinceSeq32
            }
        }
    }

    internal inner class ControlSyncHub(
        val hubScope: String,
        private val candidates: List<String>,
        private val token: String
    ) {
        private val lock = Any()
        private val subs = LinkedHashMap<String, SyncStreamSub>()
        private val subscribedMissions = HashSet<String>()
        private var presentationSent: Boolean? = null
        @Volatile var opened = false
        @Volatile var closed = false
        private var candidateIndex = 0
        private var ws: WebSocket? = null
        private var pingJob: Job? = null

        init {
            connectCandidate()
        }

        private fun toWsUrl(base: String): String {
            val trimmed = base.trim().trimEnd('/')
            return when {
                trimmed.startsWith("https://", ignoreCase = true) -> "wss://${trimmed.substring(8)}/api/control/sync"
                trimmed.startsWith("http://", ignoreCase = true) -> "ws://${trimmed.substring(7)}/api/control/sync"
                else -> "$trimmed/api/control/sync"
            }
        }

        private fun connectCandidate() {
            if (closed || candidates.isEmpty()) {
                fallbackOrCloseAll(IOException("No sync candidates"), null)
                return
            }
            val base = candidates[candidateIndex % candidates.size]
            val budget = OrbBackgroundSyncMonitor.linkBudget
            val connectClient = sseHttpClient.newBuilder()
                .connectTimeout(maxOf(6_000L, budget.connectDeadlineMs.toLong()), java.util.concurrent.TimeUnit.MILLISECONDS)
                .build()
            val req = Request.Builder()
                .url(toWsUrl(base))
                .header("Authorization", "Bearer $token")
                .build()
            synchronized(lock) {
                subscribedMissions.clear()
                presentationSent = null
            }
            var awaitingPongSinceMs: Long? = null
            ws = connectClient.newWebSocket(req, object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    if (closed) {
                        webSocket.close(1000, null)
                        return
                    }
                    opened = true
                    transportEpoch.noteWsReady(System.currentTimeMillis())
                    val readySnapshot = synchronized(lock) { subs.values.toList() }
                    for (sub in readySnapshot) {
                        sub.onWsReady()
                    }
                    syncSubscriptions()
                    webSocket.send(OrbJSON.stringify(mapOf("op" to "ping", "ts" to System.currentTimeMillis())))
                    pingJob?.cancel()
                    pingJob = scope.launch(Dispatchers.IO) {
                        while (isActive && !closed) {
                            delay(10_000L)
                            if (!closed && opened) {
                                val nowMs = System.currentTimeMillis()
                                val pongDeadlineMs = OrbBackgroundSyncMonitor.linkBudget.pongDeadlineMs.toLong()
                                val waitingSince = awaitingPongSinceMs
                                if (waitingSince != null && nowMs - waitingSince >= pongDeadlineMs) {
                                    webSocket.cancel()
                                    break
                                }
                                if (waitingSince == null) {
                                    awaitingPongSinceMs = nowMs
                                }
                                webSocket.send(OrbJSON.stringify(mapOf("op" to "ping", "ts" to nowMs)))
                            }
                        }
                    }
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    if (closed || text.isEmpty()) return
                    awaitingPongSinceMs = null
                    val parsed = OrbJSON.dict(OrbJSON.parse(text)) ?: return
                    val eventType = OrbJSON.str(parsed, "type") ?: return
                    if (eventType == "pong") {
                        val ts = (parsed["ts"] as? Number)?.toLong()
                        if (ts != null) {
                            val rtt = (System.currentTimeMillis() - ts).toInt()
                            if (rtt in 0..120_000) {
                                OrbBackgroundSyncMonitor.notePingRtt(rtt)
                            }
                        }
                        return
                    }
                    if (eventType in setOf("sync_ready", "heartbeat", "subscribed", "unsubscribed")) return
                    if (eventType == "stream_lagged") {
                        val targetMid = OrbJSON.str(parsed, "mission_id")?.trim()
                        if (targetMid.isNullOrEmpty()) {
                            OrbBackgroundSyncMonitor.noteStreamLagged()
                        }
                    }
                    val snapshot = synchronized(lock) { subs.values.toList() }
                    if (eventType == "mission_presentation") {
                        for (sub in snapshot) {
                            if (sub.kindFilter == "presentation") sub.onEvent(eventType, text)
                        }
                        return
                    }
                    if (eventType == "inbox_answer_push") {
                        OrbWarmSyncCoordinator.ingestInboxAnswerPush(this@OrbCore, parsed)
                        return
                    }
                    if (eventType == "mission_placement_changed") {
                        applyIncomingPlacementEvent(parsed)
                        for (sub in snapshot) {
                            if (sub.kindFilter == "presentation" || sub.missionId != null || sub.kindFilter == null) {
                                sub.onEvent(eventType, text)
                            }
                        }
                        return
                    }
                    if (eventType == "fido_sign_request") {
                        for (sub in snapshot) {
                            if (sub.kindFilter == "fido" || sub.missionId != null) sub.onEvent(eventType, text)
                        }
                        return
                    }
                    val targetMid = OrbJSON.str(parsed, "mission_id")
                    val obsSeq = ((parsed["sequence"] as? Number)?.toLong()?.takeIf { it >= 0L })
                        ?: ((parsed["cursor"] as? Number)?.toLong()?.takeIf { it > 0L })
                    for (sub in snapshot) {
                        if (sub.missionId != null) {
                            if (targetMid == null || targetMid == sub.missionId) {
                                if (obsSeq != null) {
                                    val curSeq = sub.sinceSeq
                                    if (curSeq == null || obsSeq > curSeq) sub.sinceSeq = obsSeq
                                }
                                sub.onEvent(eventType, text)
                            }
                        } else if (sub.kindFilter == null) {
                            if (obsSeq != null) {
                                val curSeq = sub.sinceSeq
                                if (curSeq == null || obsSeq > curSeq) sub.sinceSeq = obsSeq
                            }
                            sub.onEvent(eventType, text)
                        }
                    }
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    handleDisconnect(null, null)
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    handleDisconnect(t, response?.code)
                }
            })
        }

        private fun handleDisconnect(err: Throwable?, httpStatus: Int?) {
            pingJob?.cancel()
            pingJob = null
            if (closed) return
            val permHttpStatus = TransportEpochState.isPermanentUnsupportedHttpStatus(httpStatus)
            if (!opened && !permHttpStatus && candidateIndex + 1 < candidates.size) {
                candidateIndex += 1
                connectCandidate()
                return
            }
            fallbackOrCloseAll(err, httpStatus)
        }

        private fun fallbackOrCloseAll(err: Throwable?, httpStatus: Int?) {
            val wasOpened = opened
            val remaining: List<SyncStreamSub>
            synchronized(lock) {
                if (closed) return
                closed = true
                remaining = subs.values.toList()
                subs.clear()
            }
            ws?.cancel()
            ws = null
            if (activeSyncHub === this) activeSyncHub = null
            val failureEval = transportEpoch.noteWsFailure(httpStatus, System.currentTimeMillis())
            if (wasOpened) {
                OrbBackgroundSyncMonitor.noteUnexpectedDisconnect()
            }
            if (failureEval.fallbackToSse) {
                for (sub in remaining) {
                    if (sub.currentHub === this) sub.currentHub = null
                    val curSeq = sub.sinceSeq
                    val preserved = transportEpoch.evaluateForConnect(
                        _baseURL.value,
                        System.currentTimeMillis(),
                        curSeq
                    ).sinceSeq ?: curSeq
                    sub.fallbackFactory(preserved)
                }
            } else {
                for (sub in remaining) {
                    if (sub.currentHub === this) sub.currentHub = null
                    sub.reprobeJob?.cancel()
                    sub.reprobeJob = null
                    val oldDelegate = sub.delegateSource
                    sub.delegateSource = null
                    oldDelegate?.cancel()
                    sub.onClosed(err ?: IOException("Control sync WebSocket disconnected"))
                }
            }
        }

        private fun sendJson(payload: Map<String, Any?>) {
            val socket = ws ?: return
            if (!opened || closed) return
            socket.send(OrbJSON.stringify(payload))
        }

        private fun syncSubscriptions() {
            if (!opened || closed) return
            val commands = mutableListOf<Map<String, Any?>>()
            synchronized(lock) {
                val wantPres = subs.values.any { it.kindFilter == "presentation" }
                if (presentationSent != wantPres) {
                    presentationSent = wantPres
                    commands.add(mapOf("op" to "set_presentation", "enabled" to wantPres))
                }
                val wantedMissions = LinkedHashMap<String, Long?>()
                for (sub in subs.values) {
                    val mid = sub.missionId ?: continue
                    val seq = sub.sinceSeq
                    if (!wantedMissions.containsKey(mid)) {
                        wantedMissions[mid] = seq
                    } else {
                        val prev = wantedMissions[mid]
                        wantedMissions[mid] = if (prev != null && seq != null) minOf(prev, seq) else null
                    }
                }
                val toRemove = subscribedMissions.filter { it !in wantedMissions }
                for (mid in toRemove) {
                    subscribedMissions.remove(mid)
                    commands.add(mapOf("op" to "unsubscribe", "mission_id" to mid))
                }
                for ((mid, seq) in wantedMissions) {
                    if (subscribedMissions.add(mid)) {
                        val cmd = LinkedHashMap<String, Any?>()
                        cmd["op"] = "subscribe"
                        cmd["mission_id"] = mid
                        cmd["max_payload"] = OrbReadCache.RESULT_KEEP_CHARS
                        if (seq != null) cmd["since_seq"] = seq
                        commands.add(cmd)
                    }
                }
            }
            for (cmd in commands) sendJson(cmd)
        }

        fun register(sub: SyncStreamSub) {
            var alreadyOpened = false
            val useFallback = synchronized(lock) {
                if (closed || sub.cancelled) true else {
                    sub.currentHub = this
                    subs[sub.id] = sub
                    alreadyOpened = opened
                    false
                }
            }
            if (sub.cancelled) return
            if (useFallback) {
                sub.fallbackFactory(sub.sinceSeq)
                return
            }
            if (alreadyOpened) {
                sub.onWsReady()
            }
            syncSubscriptions()
        }

        fun unregister(id: String) {
            val removed: SyncStreamSub?
            val emptyNow: Boolean
            synchronized(lock) {
                removed = subs.remove(id)
                if (removed?.currentHub === this) removed.currentHub = null
                emptyNow = subs.isEmpty()
            }
            removed?.reprobeJob?.cancel()
            removed?.reprobeJob = null
            removed?.delegateSource?.cancel()
            if (emptyNow) {
                close()
            } else {
                syncSubscriptions()
            }
        }

        fun close() {
            val toNotify: List<SyncStreamSub>
            synchronized(lock) {
                if (closed) return
                closed = true
                toNotify = subs.values.toList()
                subs.clear()
            }
            pingJob?.cancel()
            pingJob = null
            ws?.close(1000, null)
            ws = null
            if (activeSyncHub === this) activeSyncHub = null
            drainSyncSubscribersOnHubClose(this, toNotify)
        }
    }

    @Volatile private var activeSyncHub: ControlSyncHub? = null
    internal val transportEpoch = TransportEpochState()
    private val transportBuildEpoch = java.util.concurrent.atomic.AtomicLong(0L)

    val canUseMultiplexSync: Boolean
        get() {
            val cleanToken = _token.value?.trim()
            val primaryBase = _baseURL.value.trim()
            if (cleanToken.isNullOrEmpty() || primaryBase.isEmpty()) return false
            return transportEpoch.evaluateForConnect(primaryBase, System.currentTimeMillis()).allowWebSocket
        }

    val isMultiplexSyncHealthy: Boolean
        get() {
            val cleanToken = _token.value?.trim()?.takeIf { it.isNotEmpty() } ?: return false
            val primaryBase = _baseURL.value.trim().trimEnd('/').takeIf { it.isNotEmpty() } ?: return false
            val hub = activeSyncHub ?: return false
            return !hub.closed && hub.opened && hub.hubScope == "$primaryBase|$cleanToken"
        }

    private fun closeSyncHub() {
        activeSyncHub?.close()
        activeSyncHub = null
    }

    private fun parseControlStreamQuery(path: String): Triple<String?, String?, Long?>? {
        if (!path.startsWith("/api/control/stream")) return null
        val qIdx = path.indexOf('?')
        if (qIdx < 0) return Triple(null, null, null)
        var missionId: String? = null
        var profile: String? = null
        var kinds: String? = null
        var sinceSeq: Long? = null
        for (part in path.substring(qIdx + 1).split('&')) {
            val eq = part.indexOf('=')
            if (eq <= 0) continue
            val k = part.substring(0, eq)
            val v = java.net.URLDecoder.decode(part.substring(eq + 1), Charsets.UTF_8.name())
            when (k) {
                "mission" -> missionId = v.takeIf { it.isNotEmpty() }
                "profile" -> profile = v
                "kinds" -> kinds = v
                "since_seq" -> sinceSeq = v.toLongOrNull()
            }
        }
        val kindFilter = when {
            missionId != null -> null
            profile == "presentation" || kinds == "mission_presentation" -> "presentation"
            kinds == "fido" -> "fido"
            else -> return null
        }
        return Triple(missionId, kindFilter, sinceSeq)
    }

    private fun rewriteControlStreamSinceSeq(path: String, sinceSeq: Long?): String {
        if (sinceSeq == null || !path.startsWith("/api/control/stream")) return path
        val qIdx = path.indexOf('?')
        if (qIdx < 0) return "$path?since_seq=$sinceSeq"
        val base = path.substring(0, qIdx)
        val kept = path.substring(qIdx + 1)
            .split('&')
            .filter { it.isNotEmpty() && !it.startsWith("since_seq=") }
            .toMutableList()
        kept.add("since_seq=$sinceSeq")
        return "$base?${kept.joinToString("&")}"
    }

    fun openSSE(
        path: String,
        onEvent: (eventType: String?, data: String) -> Unit,
        onClosed: (Throwable?) -> Unit = {}
    ): EventSource {
        val cleanToken = _token.value?.trim()?.takeIf { it.isNotEmpty() }
        val primaryBase = _baseURL.value.trim().trimEnd('/')
        val queryInfo = if (cleanToken != null && primaryBase.isNotEmpty()) {
            parseControlStreamQuery(path)
        } else {
            null
        }
        val connectEval = if (queryInfo != null && cleanToken != null) {
            transportEpoch.evaluateForConnect(primaryBase, System.currentTimeMillis(), queryInfo.third)
        } else {
            null
        }
        if (queryInfo != null && cleanToken != null && connectEval != null) {
            val (missionId, kindFilter, _) = queryInfo
            val effectiveSinceSeq = connectEval.sinceSeq
            val scopeKey = "$primaryBase|$cleanToken"
            val subId = UUID.randomUUID().toString()
            val placeholderReq = Request.Builder().url(makeURL(rewriteControlStreamSinceSeq(path, effectiveSinceSeq))).build()

            fun getOrCreateSyncHub(): ControlSyncHub = synchronized(this) {
                val cur = activeSyncHub
                if (cur != null && !cur.closed && cur.hubScope == scopeKey) {
                    cur
                } else {
                    cur?.close()
                    ControlSyncHub(scopeKey, orderedCandidateEndpoints(primaryBase), cleanToken).also {
                        activeSyncHub = it
                    }
                }
            }

            lateinit var sub: SyncStreamSub
            val observedOnEvent: (String?, String) -> Unit = { type, data ->
                if (!sub.cancelled) {
                    val parsed = OrbJSON.dict(OrbJSON.parse(data))
                    if (parsed != null) {
                        val obsSeq = ((parsed["sequence"] as? Number)?.toLong()?.takeIf { it >= 0L })
                            ?: ((parsed["cursor"] as? Number)?.toLong()?.takeIf { it > 0L })
                        if (obsSeq != null) {
                            val curSeq = sub.sinceSeq
                            if (curSeq == null || obsSeq > curSeq) sub.sinceSeq = obsSeq
                        }
                    }
                    onEvent(type, data)
                }
            }

            fun scheduleSubReprobe() {
                sub.reprobeJob?.cancel()
                sub.reprobeJob = null
                if (sub.cancelled) return
                val startBuildEpoch = transportBuildEpoch.get()
                sub.reprobeJob = scope.launch(Dispatchers.IO) {
                    while (isActive && !sub.cancelled) {
                        val curToken = _token.value?.trim()?.takeIf { it.isNotEmpty() }
                        val curBase = _baseURL.value.trim().trimEnd('/')
                        if (curToken == null || curBase.isEmpty() || "$curBase|$curToken" != scopeKey) return@launch
                        val delayMs = transportEpoch.reprobeDelayMs(System.currentTimeMillis())
                        if (delayMs != null) {
                            if (delayMs > 0L) delay(delayMs)
                        } else {
                            delay(500L)
                            if (transportBuildEpoch.get() == startBuildEpoch || transportEpoch.stickyUnsupported) {
                                continue
                            }
                        }
                        if (!isActive || sub.cancelled) return@launch
                        val curSeq = sub.sinceSeq
                        val eval = transportEpoch.evaluateForConnect(curBase, System.currentTimeMillis(), curSeq)
                        if (eval.sinceSeq != null) sub.sinceSeq = eval.sinceSeq
                        if (eval.allowWebSocket && !sub.cancelled) {
                            sub.reprobeJob = null
                            getOrCreateSyncHub().register(sub)
                            return@launch
                        }
                    }
                }
            }

            fun attachSseFallback(preservedSeq: Long?) {
                if (sub.cancelled) return
                if (preservedSeq != null) {
                    val curSeq = sub.sinceSeq
                    if (curSeq == null || preservedSeq > curSeq) sub.sinceSeq = preservedSeq
                }
                if (sub.delegateSource == null) {
                    lateinit var rawSource: EventSource
                    rawSource = openRawSSE(
                        rewriteControlStreamSinceSeq(path, sub.sinceSeq),
                        observedOnEvent,
                        onClosed = { t ->
                            if (sub.delegateSource === rawSource && !sub.cancelled) {
                                sub.delegateSource = null
                                sub.reprobeJob?.cancel()
                                sub.reprobeJob = null
                                sub.currentHub?.unregister(subId)
                                onClosed(t)
                            }
                        }
                    )
                    if (sub.cancelled) {
                        rawSource.cancel()
                        return
                    }
                    sub.delegateSource = rawSource
                }
                scheduleSubReprobe()
            }

            sub = SyncStreamSub(
                id = subId,
                missionId = missionId,
                kindFilter = kindFilter,
                sinceSeq = effectiveSinceSeq,
                request = placeholderReq,
                onEvent = observedOnEvent,
                onClosed = onClosed,
                fallbackFactory = { preservedSeq ->
                    attachSseFallback(preservedSeq)
                },
                onWsReady = {
                    sub.reprobeJob?.cancel()
                    sub.reprobeJob = null
                    val oldDelegate = sub.delegateSource
                    sub.delegateSource = null
                    oldDelegate?.cancel()
                }
            )

            if (connectEval.allowWebSocket) {
                getOrCreateSyncHub().register(sub)
            } else {
                attachSseFallback(effectiveSinceSeq)
            }

            return object : EventSource {
                override fun request(): Request = sub.delegateSource?.request() ?: placeholderReq
                override fun cancel() {
                    sub.cancelled = true
                    sub.reprobeJob?.cancel()
                    sub.reprobeJob = null
                    val oldDelegate = sub.delegateSource
                    sub.delegateSource = null
                    oldDelegate?.cancel()
                    sub.currentHub?.unregister(subId)
                    sub.currentHub = null
                }
            }
        }
        val ssePath = if (connectEval != null) rewriteControlStreamSinceSeq(path, connectEval.sinceSeq) else path
        return openRawSSE(ssePath, onEvent, onClosed)
    }

    private fun openRawSSE(
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
                    if (type == "mission_placement_changed") {
                        applyIncomingPlacementEvent(OrbJSON.parse(data))
                    }
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

/** Compact snapshots never own the full transcript or its pagination cursor. */
object OrbPresentation {
    private val recent = LinkedHashSet<String>()
    private val pending = LinkedHashSet<String>()
    @Volatile private var listChanged = false
    @Volatile var isConnected: Boolean = false
        private set
    private val revisions = LinkedHashMap<String, Long>()
    private val labels = LinkedHashMap<String, String>()
    @Synchronized fun activity(id: String): String? = labels["${OrbDisk.currentScope()}|$id"]
    private var rememberedScope = ""
    @Synchronized private fun ensureScope() {
        val current = OrbDisk.currentScope()
        if (current == rememberedScope) return
        rememberedScope = current
        recent.clear(); pending.clear(); labels.clear(); revisions.clear(); listChanged = false
    }
    @Synchronized fun remember(id: String) {
        ensureScope()
        recent.remove(id); recent.add(id)
        while (recent.size > 12) recent.remove(recent.first())
    }
    @Synchronized private fun changed(id: String?) {
        if (id == null) pending.addAll(recent) else if (id in recent) pending.add(id)
    }
    @Synchronized private fun batch(): List<String> = pending.take(3).also { pending.removeAll(it.toSet()) }
    fun history(snapshot: Map<String, Any?>): List<OrbRow> {
        return OrbJSON.dictList(snapshot["events"]).mapNotNull { event ->
            val type = OrbJSON.str(event, "event_type")
            if ((OrbJSON.dict(event["metadata"])?.get("queued") as? Boolean) == true || (type != "assistant_message" && type != "assistant_message_canonical" && type != "user_message")) null
            else OrbRow("presentation:${event["sequence"] ?: event["id"]}", mapOf("role" to if (type == "user_message") "user" else "assistant", "content" to event["content"]))
        }
    }
    suspend fun load(id: String, core: OrbCore): List<OrbRow> {
        val account = OrbDisk.currentScope()
        val snapshot = core.fetchDict("/api/control/missions/${core.encodeComponent(id)}/snapshot?profile=presentation")
        if (account != OrbDisk.currentScope() || OrbJSON.str(snapshot, "profile") != "presentation") return emptyList()
        val rows = history(snapshot)
        synchronized(this) {
            if (account != OrbDisk.currentScope()) return emptyList()
            val key = "$account|$id"
            val revision = (snapshot["revision"] as? Number)?.toLong() ?: 0
            if ((revisions[key] ?: -1) >= revision) return OrbReadCache.readMemoryRows("presentation_$id")
            if (revisions.size >= 256) { revisions.clear(); labels.clear() }
            revisions[key] = revision
            labels[key] = OrbJSON.str(snapshot, "activity") ?: ""
            OrbReadCache.saveRows("presentation_$id", rows)
        }
        return rows
    }
    suspend fun monitor(core: OrbCore) {
        if (!core.isConfigured) return
        while (kotlinx.coroutines.currentCoroutineContext().isActive) {
            ensureScope()
            val account = OrbDisk.currentScope()
            val closed = java.util.concurrent.atomic.AtomicBoolean(false)
            val stream = core.openSSE("/api/control/stream?profile=presentation&kinds=mission_presentation", onEvent = { type, data ->
                isConnected = true
                if (type == "status" || type == "stream_lagged") {
                    changed(null)
                    OrbWarmSyncCoordinator.notePresentationStreamDisrupted(core)
                }
                if (type == "mission_placement_changed") {
                    listChanged = true
                    return@openSSE
                }
                if (type == "mission_presentation") {
                    val hint = OrbJSON.dict(OrbJSON.parse(data))
                    val id = OrbJSON.str(hint, "mission_id")
                    val kind = OrbJSON.str(hint, "kind")
                    if (!id.isNullOrEmpty()) {
                        OrbWarmSyncCoordinator.notePresentationHint(
                            core = core,
                            missionId = id,
                            kind = kind,
                            btwParentId = OrbJSON.str(hint, "btw_parent_id"),
                        )
                    }
                    if (kind == "mission_activity") {
                        synchronized(this) {
                            if (id in recent && account == OrbDisk.currentScope()) labels["$account|$id"] = OrbJSON.str(hint, "label")?.take(160) ?: ""
                        }
                    } else {
                        synchronized(this) { labels.remove("$account|$id") }
                        listChanged = true
                        if (id == null || !OrbWarmSyncCoordinator.isMissionWarmLive(core, id)) {
                            changed(id)
                        }
                    }
                }
            }, onClosed = {
                isConnected = false
                closed.set(true)
            })
            isConnected = true
            changed(null)
            try {
                while (kotlinx.coroutines.currentCoroutineContext().isActive && account == OrbDisk.currentScope() && !closed.get()) {
                    if (listChanged) { listChanged = false; core.refreshMissionsQuietly() }
                    for (id in batch()) {
                        try { load(id, core) } catch (e: Exception) { if (e is CancellationException) throw e }
                    }
                    delay(1000)
                }
            } finally {
                isConnected = false
                stream.cancel()
            }
            delay(2000)
        }
    }
}
