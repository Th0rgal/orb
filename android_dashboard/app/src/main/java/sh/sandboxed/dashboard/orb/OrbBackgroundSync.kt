package sh.sandboxed.dashboard.orb

import android.app.Activity
import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Bundle
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import okhttp3.sse.EventSource
import java.time.Instant
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

enum class OrbBackgroundSyncMode(val wireValue: String, val label: String) {
    Auto("auto", "Auto"),
    On("on", "On"),
    Off("off", "Off");
}

enum class OrbBackgroundSyncPauseReason(val wireValue: String) {
    DataSaver("data_saver"),
    SlowRtt("slow_rtt"),
    StreamLagged("lagged"),
    UnstableLink("unstable");
}

data class OrbBackgroundSyncState(
    val mode: OrbBackgroundSyncMode,
    val dataSaver: Boolean,
    val slowRttStreak: Int,
    val fastRttStreak: Int,
    val pausedByLink: Boolean,
    val linkPauseReason: OrbBackgroundSyncPauseReason?,
    val cooldownUntilMs: Long,
    val recentDisconnectsMs: List<Long>,
    val lastRttMs: Int?,
) {
    val pauseReason: OrbBackgroundSyncPauseReason?
        get() = when (mode) {
            OrbBackgroundSyncMode.On, OrbBackgroundSyncMode.Off -> null
            OrbBackgroundSyncMode.Auto -> when {
                dataSaver -> OrbBackgroundSyncPauseReason.DataSaver
                pausedByLink -> linkPauseReason ?: OrbBackgroundSyncPauseReason.SlowRtt
                else -> null
            }
        }

    val reason: String
        get() = when (mode) {
            OrbBackgroundSyncMode.On -> "forced_on"
            OrbBackgroundSyncMode.Off -> "forced_off"
            OrbBackgroundSyncMode.Auto -> pauseReason?.wireValue ?: "healthy"
        }

    val active: Boolean
        get() = when (mode) {
            OrbBackgroundSyncMode.On -> true
            OrbBackgroundSyncMode.Off -> false
            OrbBackgroundSyncMode.Auto -> !dataSaver && !pausedByLink
        }
}

sealed interface OrbBackgroundSyncEvent {
    data class SetMode(val mode: OrbBackgroundSyncMode) : OrbBackgroundSyncEvent
    data class SetDataSaver(val enabled: Boolean) : OrbBackgroundSyncEvent
    data class PingRtt(val rttMs: Int, val atMs: Long) : OrbBackgroundSyncEvent
    data class StreamLagged(val atMs: Long) : OrbBackgroundSyncEvent
    data class UnexpectedDisconnect(val atMs: Long) : OrbBackgroundSyncEvent
}

data class OrbWarmSelection(
    val missionIds: List<String>,
    val btwParentIds: List<String>,
    val allStreamIds: List<String>,
)

/**
 * Pure, deterministic state machine shared with desktop (`orb/src/backgroundSync.ts`)
 * and iOS (`OrbBackgroundSync.swift`), verified against `shared/orb-spec/fixtures/background-sync-policy.json`.
 */
object OrbBackgroundSyncPolicy {
    const val MAX_WARM_MISSIONS = 12
    const val RTT_SLOW_THRESHOLD_MS = 750
    const val RTT_SLOW_STREAK_TO_PAUSE = 2
    const val RTT_FAST_THRESHOLD_MS = 350
    const val RTT_FAST_STREAK_TO_RESUME = 3
    const val RESUME_COOLDOWN_MS = 30_000L
    const val DISCONNECT_WINDOW_MS = 60_000L
    const val DISCONNECT_BURST_TO_PAUSE = 2

    fun normalizeMode(raw: Any?): OrbBackgroundSyncMode {
        val text = (raw as? String)?.trim()?.lowercase() ?: return OrbBackgroundSyncMode.Auto
        return when (text) {
            "on" -> OrbBackgroundSyncMode.On
            "off" -> OrbBackgroundSyncMode.Off
            else -> OrbBackgroundSyncMode.Auto
        }
    }

    fun initialState(
        mode: OrbBackgroundSyncMode = OrbBackgroundSyncMode.Auto,
        dataSaver: Boolean = false,
    ): OrbBackgroundSyncState = OrbBackgroundSyncState(
        mode = mode,
        dataSaver = dataSaver,
        slowRttStreak = 0,
        fastRttStreak = 0,
        pausedByLink = false,
        linkPauseReason = null,
        cooldownUntilMs = 0L,
        recentDisconnectsMs = emptyList(),
        lastRttMs = null,
    )

    fun reduce(
        state: OrbBackgroundSyncState,
        event: OrbBackgroundSyncEvent,
    ): OrbBackgroundSyncState = when (event) {
        is OrbBackgroundSyncEvent.SetMode -> state.copy(mode = event.mode)
        is OrbBackgroundSyncEvent.SetDataSaver -> state.copy(
            dataSaver = event.enabled,
            fastRttStreak = if (event.enabled) 0 else state.fastRttStreak,
        )
        is OrbBackgroundSyncEvent.PingRtt -> {
            val rtt = event.rttMs.coerceAtLeast(0)
            if (rtt > RTT_SLOW_THRESHOLD_MS) {
                val slowStreak = state.slowRttStreak + 1
                if (slowStreak >= RTT_SLOW_STREAK_TO_PAUSE) {
                    state.copy(
                        lastRttMs = rtt,
                        slowRttStreak = slowStreak,
                        fastRttStreak = 0,
                        pausedByLink = true,
                        linkPauseReason = OrbBackgroundSyncPauseReason.SlowRtt,
                        cooldownUntilMs = maxOf(state.cooldownUntilMs, event.atMs + RESUME_COOLDOWN_MS),
                    )
                } else {
                    state.copy(
                        lastRttMs = rtt,
                        slowRttStreak = slowStreak,
                        fastRttStreak = 0,
                    )
                }
            } else if (rtt < RTT_FAST_THRESHOLD_MS) {
                val fastStreak = state.fastRttStreak + 1
                val canResume = !state.dataSaver &&
                    state.pausedByLink &&
                    fastStreak >= RTT_FAST_STREAK_TO_RESUME &&
                    event.atMs >= state.cooldownUntilMs
                if (canResume) {
                    state.copy(
                        lastRttMs = rtt,
                        slowRttStreak = 0,
                        fastRttStreak = fastStreak,
                        pausedByLink = false,
                        linkPauseReason = null,
                        recentDisconnectsMs = emptyList(),
                    )
                } else {
                    state.copy(
                        lastRttMs = rtt,
                        slowRttStreak = 0,
                        fastRttStreak = fastStreak,
                    )
                }
            } else {
                state.copy(
                    lastRttMs = rtt,
                    slowRttStreak = 0,
                    fastRttStreak = 0,
                )
            }
        }
        is OrbBackgroundSyncEvent.StreamLagged -> state.copy(
            pausedByLink = true,
            linkPauseReason = OrbBackgroundSyncPauseReason.StreamLagged,
            fastRttStreak = 0,
            cooldownUntilMs = maxOf(state.cooldownUntilMs, event.atMs + RESUME_COOLDOWN_MS),
        )
        is OrbBackgroundSyncEvent.UnexpectedDisconnect -> {
            val cutoff = event.atMs - DISCONNECT_WINDOW_MS
            val recent = state.recentDisconnectsMs.filter { it >= cutoff } + event.atMs
            if (recent.size >= DISCONNECT_BURST_TO_PAUSE) {
                state.copy(
                    recentDisconnectsMs = recent,
                    fastRttStreak = 0,
                    pausedByLink = true,
                    linkPauseReason = OrbBackgroundSyncPauseReason.UnstableLink,
                    cooldownUntilMs = maxOf(state.cooldownUntilMs, event.atMs + RESUME_COOLDOWN_MS),
                )
            } else {
                state.copy(
                    recentDisconnectsMs = recent,
                    fastRttStreak = 0,
                )
            }
        }
    }

    fun selectWarmMissionIds(
        backgroundActive: Boolean,
        maxWarm: Int = MAX_WARM_MISSIONS,
        focusedIds: List<String>,
        recentIds: List<String>,
        knownBtwByParent: Map<String, String> = emptyMap(),
        focusedBtwParents: List<String> = emptyList(),
    ): OrbWarmSelection {
        val cap = maxWarm.coerceAtLeast(1)
        val missionSet = LinkedHashSet<String>()
        for (id in focusedIds) {
            if (id.isNotEmpty()) missionSet.add(id)
        }
        if (backgroundActive) {
            for (id in recentIds.asReversed()) {
                if (missionSet.size >= cap) break
                if (id.isNotEmpty()) missionSet.add(id)
            }
        }
        val missionIds = missionSet.toList()
        val btwSet = LinkedHashSet<String>()
        if (backgroundActive) {
            for (mid in missionIds) {
                if (knownBtwByParent.containsKey(mid)) {
                    btwSet.add(mid)
                }
            }
        } else {
            val openSet = focusedBtwParents.toSet()
            for (mid in missionIds) {
                if (openSet.contains(mid) && knownBtwByParent.containsKey(mid)) {
                    btwSet.add(mid)
                }
            }
        }
        for (parent in focusedBtwParents) {
            if (parent.isNotEmpty() && knownBtwByParent.containsKey(parent)) {
                btwSet.add(parent)
            }
        }
        val allStreamSet = LinkedHashSet(missionIds)
        for (parent in btwSet) {
            val btwId = knownBtwByParent[parent]
            if (!btwId.isNullOrEmpty()) {
                allStreamSet.add(btwId)
            }
        }
        return OrbWarmSelection(
            missionIds = missionIds,
            btwParentIds = btwSet.toList(),
            allStreamIds = allStreamSet.toList(),
        )
    }

    fun statusText(state: OrbBackgroundSyncState): String {
        val rttLabel = state.lastRttMs?.let { " ($it ms)" } ?: ""
        return when (state.mode) {
            OrbBackgroundSyncMode.On ->
                "Active — keeps up to 12 recently opened conversations and their /btw tabs live in the background."
            OrbBackgroundSyncMode.Off ->
                "Off — only the open conversation subscribes live; returning uses lightweight catch-up."
            OrbBackgroundSyncMode.Auto -> {
                if (state.active) {
                    "Active$rttLabel — pauses automatically on Data Saver or slow connections."
                } else {
                    when (state.pauseReason) {
                        OrbBackgroundSyncPauseReason.DataSaver ->
                            "Paused — Data Saver or constrained network is enabled on this device."
                        OrbBackgroundSyncPauseReason.SlowRtt ->
                            "Paused — high connection latency$rttLabel; resumes automatically when fast again."
                        OrbBackgroundSyncPauseReason.StreamLagged ->
                            "Paused — stream fell behind; resumes automatically once stable."
                        OrbBackgroundSyncPauseReason.UnstableLink ->
                            "Paused — connection dropped repeatedly; resumes automatically once stable."
                        null ->
                            "Paused — waiting for a fast, stable connection."
                    }
                }
            }
        }
    }
}

object OrbBackgroundSyncMonitor {
    private const val PREFS_NAME = "orb_settings"
    private const val MODE_KEY = "orb.backgroundSyncMode"

    private var prefs: SharedPreferences? = null
    @Volatile private var initialized = false
    private val lock = Any()
    private val _state = MutableStateFlow(OrbBackgroundSyncPolicy.initialState())
    val stateFlow: StateFlow<OrbBackgroundSyncState> = _state.asStateFlow()

    val state: OrbBackgroundSyncState
        get() = _state.value

    val active: Boolean
        get() = _state.value.active

    fun init(context: Context) {
        if (initialized) return
        val appCtx = context.applicationContext
        synchronized(lock) {
            if (initialized) return
            initialized = true
            val p = appCtx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs = p
            val mode = OrbBackgroundSyncPolicy.normalizeMode(p.getString(MODE_KEY, null))
            val cm = appCtx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            val dataSaver = readConstrainedLink(cm)
            _state.value = OrbBackgroundSyncPolicy.initialState(mode = mode, dataSaver = dataSaver)
            registerConnectivityCallbacks(appCtx, cm)
            registerAppLifecycle(appCtx as? Application)
        }
    }

    private fun readConstrainedLink(cm: ConnectivityManager?): Boolean {
        if (cm == null) return false
        if (cm.restrictBackgroundStatus == ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED) {
            return true
        }
        val caps = runCatching { cm.getNetworkCapabilities(cm.activeNetwork) }.getOrNull() ?: return false
        val downKbps = caps.linkDownstreamBandwidthKbps
        return downKbps in 1..999
    }

    private fun registerConnectivityCallbacks(context: Context, cm: ConnectivityManager?) {
        if (cm == null) return
        runCatching {
            cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
                    apply(OrbBackgroundSyncEvent.SetDataSaver(readConstrainedLink(cm)))
                }

                override fun onAvailable(network: Network) {
                    apply(OrbBackgroundSyncEvent.SetDataSaver(readConstrainedLink(cm)))
                }
            })
        }
        runCatching {
            context.registerReceiver(
                object : BroadcastReceiver() {
                    override fun onReceive(ctx: Context?, intent: Intent?) {
                        apply(OrbBackgroundSyncEvent.SetDataSaver(readConstrainedLink(cm)))
                    }
                },
                IntentFilter(ConnectivityManager.ACTION_RESTRICT_BACKGROUND_CHANGED)
            )
        }
    }

    private fun registerAppLifecycle(app: Application?) {
        if (app == null) return
        var startedCount = 1
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityStarted(activity: Activity) {
                val becameForeground = startedCount == 0
                startedCount += 1
                if (becameForeground) {
                    OrbWarmSyncCoordinator.setAppForegrounded(true)
                }
            }

            override fun onActivityStopped(activity: Activity) {
                startedCount = (startedCount - 1).coerceAtLeast(0)
                if (startedCount == 0 && !activity.isChangingConfigurations) {
                    OrbWarmSyncCoordinator.setAppForegrounded(false)
                }
            }

            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
            override fun onActivityResumed(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        })
    }

    fun setMode(mode: OrbBackgroundSyncMode) {
        prefs?.edit()?.putString(MODE_KEY, mode.wireValue)?.apply()
        apply(OrbBackgroundSyncEvent.SetMode(mode))
    }

    fun notePingRtt(rttMs: Int, atMs: Long = System.currentTimeMillis()) {
        apply(OrbBackgroundSyncEvent.PingRtt(rttMs = rttMs, atMs = atMs))
    }

    fun noteStreamLagged(atMs: Long = System.currentTimeMillis()) {
        apply(OrbBackgroundSyncEvent.StreamLagged(atMs = atMs))
    }

    fun noteUnexpectedDisconnect(atMs: Long = System.currentTimeMillis()) {
        apply(OrbBackgroundSyncEvent.UnexpectedDisconnect(atMs = atMs))
    }

    private fun apply(event: OrbBackgroundSyncEvent) {
        val changedActive: Boolean
        synchronized(lock) {
            val prev = _state.value
            val next = OrbBackgroundSyncPolicy.reduce(prev, event)
            _state.value = next
            changedActive = prev.active != next.active
        }
        if (changedActive) {
            OrbWarmSyncCoordinator.reconcileIfReady()
        }
    }
}

object OrbLiveEventReducer {
    /**
     * Converts a sequenced `/api/control/sync` WebSocket frame directly into an `OrbRow`
     * matching `/api/control/missions/:id/events` rows so cached conversations and `/btw`
     * threads advance in memory with zero HTTP round-trips.
     */
    fun streamFrameToStoredRow(
        missionId: String,
        type: String,
        parsed: OrbDict,
    ): OrbRow? {
        val seq = (parsed["sequence"] as? Number)?.toLong()?.takeIf { it > 0L } ?: return null
        val timestamp = OrbJSON.str(parsed, "timestamp", "at") ?: Instant.now().toString()
        val normalizedType = type.lowercase()
        return when (normalizedType) {
            "user_message" -> {
                val content = OrbJSON.str(parsed, "content") ?: ""
                val eventId = OrbJSON.str(parsed, "id")
                val meta = LinkedHashMap<String, Any?>()
                if (OrbJSON.bool(parsed, "queued") == true) meta["queued"] = true
                if (!eventId.isNullOrEmpty()) meta["client_message_id"] = eventId
                OrbRow(
                    eventId ?: "seq-$seq",
                    mapOf(
                        "id" to seq,
                        "mission_id" to missionId,
                        "sequence" to seq,
                        "event_type" to "user_message",
                        "timestamp" to timestamp,
                        "event_id" to eventId,
                        "content" to content,
                        "metadata" to meta,
                    )
                )
            }
            "assistant_message", "assistant_message_canonical" -> {
                val content = OrbJSON.str(parsed, "content") ?: ""
                val eventId = OrbJSON.str(parsed, "id", "bubble_id")
                val meta = LinkedHashMap<String, Any?>()
                OrbJSON.bool(parsed, "success")?.let { meta["success"] = it }
                OrbJSON.str(parsed, "bubble_id")?.let { meta["bubble_id"] = it }
                (parsed["revision"] as? Number)?.toInt()?.let { meta["revision"] = it }
                parsed["shared_files"]?.let { meta["shared_files"] = it }
                parsed["cost_cents"]?.let { meta["cost_cents"] = it }
                OrbJSON.str(parsed, "model")?.let { meta["model"] = it }
                OrbRow(
                    eventId ?: "seq-$seq",
                    mapOf(
                        "id" to seq,
                        "mission_id" to missionId,
                        "sequence" to seq,
                        "event_type" to normalizedType,
                        "timestamp" to timestamp,
                        "event_id" to eventId,
                        "content" to content,
                        "metadata" to meta,
                    )
                )
            }
            "tool_call" -> {
                val callId = OrbJSON.str(parsed, "tool_call_id")
                val toolName = OrbJSON.str(parsed, "name")
                val argsRaw = parsed["args"]
                val argsText = when (argsRaw) {
                    is String -> argsRaw
                    null -> "{}"
                    else -> OrbJSON.stringify(argsRaw)
                }
                OrbRow(
                    callId ?: "seq-$seq",
                    mapOf(
                        "id" to seq,
                        "mission_id" to missionId,
                        "sequence" to seq,
                        "event_type" to "tool_call",
                        "timestamp" to timestamp,
                        "tool_call_id" to callId,
                        "tool_name" to toolName,
                        "content" to argsText,
                        "metadata" to emptyMap<String, Any?>(),
                    )
                )
            }
            "tool_result" -> {
                val callId = OrbJSON.str(parsed, "tool_call_id")
                val toolName = OrbJSON.str(parsed, "name")
                val resultRaw = parsed["result"]
                val fullText = when (resultRaw) {
                    is String -> resultRaw
                    null -> ""
                    else -> OrbJSON.stringify(resultRaw)
                }
                val keptText = if (fullText.length > OrbReadCache.RESULT_KEEP_CHARS) {
                    fullText.take(OrbReadCache.RESULT_KEEP_CHARS)
                } else {
                    fullText
                }
                val meta = if (OrbJSON.bool(parsed, "is_error") == true) {
                    mapOf<String, Any?>("is_error" to true)
                } else {
                    emptyMap()
                }
                OrbRow(
                    "res-${callId ?: seq}",
                    mapOf(
                        "id" to seq,
                        "mission_id" to missionId,
                        "sequence" to seq,
                        "event_type" to "tool_result",
                        "timestamp" to timestamp,
                        "tool_call_id" to callId,
                        "tool_name" to toolName,
                        "content" to keptText,
                        "metadata" to meta,
                    )
                )
            }
            "thinking" -> {
                if (OrbJSON.bool(parsed, "done") == false) return null
                val content = OrbJSON.str(parsed, "content") ?: ""
                if (content.isBlank()) return null
                val eventId = OrbJSON.str(parsed, "event_id")
                OrbRow(
                    eventId ?: "thought-$seq",
                    mapOf(
                        "id" to seq,
                        "mission_id" to missionId,
                        "sequence" to seq,
                        "event_type" to "thinking",
                        "timestamp" to timestamp,
                        "event_id" to eventId,
                        "content" to content,
                        "metadata" to mapOf("done" to true),
                    )
                )
            }
            "goal_status", "goal_iteration" -> {
                val content = OrbJSON.str(parsed, "summary", "content") ?: ""
                if (content.isBlank()) return null
                OrbRow(
                    "goal-$seq",
                    mapOf(
                        "id" to seq,
                        "mission_id" to missionId,
                        "sequence" to seq,
                        "event_type" to normalizedType,
                        "timestamp" to timestamp,
                        "content" to content,
                        "metadata" to emptyMap<String, Any?>(),
                    )
                )
            }
            else -> null
        }
    }

    fun mergeMissionEvents(existing: List<OrbRow>, incoming: List<OrbRow>): List<OrbRow> {
        if (incoming.isEmpty()) return existing
        val byKey = LinkedHashMap<Any, OrbRow>(existing.size + incoming.size)
        for (row in existing + incoming) {
            val key: Any = row.int("sequence", "seq") ?: row.id
            byKey[key] = row
        }
        var sorted = byKey.values.sortedWith(compareBy { it.int("sequence", "seq") ?: Int.MAX_VALUE })
        val latestDeltaSeq = sorted.lastOrNull { ev ->
            val t = (ev.str("event_type", "type") ?: "").lowercase()
            val eid = ev.str("event_id")
            t == "text_delta" && (eid == null || eid == "text_delta_latest")
        }?.int("sequence", "seq")
        if (latestDeltaSeq != null) {
            sorted = sorted.filterNot { ev ->
                val t = (ev.str("event_type", "type") ?: "").lowercase()
                val eid = ev.str("event_id")
                val seq = ev.int("sequence", "seq") ?: Int.MAX_VALUE
                t == "text_delta" && (eid == null || eid == "text_delta_latest") && seq < latestDeltaSeq
            }
        }
        if (sorted.size > 600) {
            val tailStartSeq = sorted[sorted.size - 400].int("sequence", "seq") ?: 0
            val lastUserSeq = sorted.lastOrNull { ev ->
                (ev.str("event_type", "type") ?: "").lowercase() == "user_message" &&
                    OrbJSON.bool(ev.dict("metadata"), "queued") != true
            }?.int("sequence", "seq") ?: 0
            sorted = sorted.filter { ev ->
                val seq = ev.int("sequence", "seq") ?: Int.MAX_VALUE
                val t = (ev.str("event_type", "type") ?: "").lowercase()
                val tool = (ev.str("tool_name", "name", "tool") ?: "").lowercase()
                seq >= tailStartSeq || (seq >= lastUserSeq && (t == "user_message" || tool in setOf("todowrite", "todo_write", "update_plan")))
            }
        }
        return OrbReadCache.compactEvents(sorted)
    }
}

data class OrbWarmBtwSnapshot(
    val boundMission: OrbRow? = null,
    val turns: List<OrbSideAgent.Turn> = emptyList(),
    val openTurn: OrbSideAgent.OpenTurn? = null,
    val cachedThreads: Map<String, Pair<String, OrbSideAgent.ParsedThread>> = emptyMap(),
    val cachedEventsByThread: Map<String, List<OrbRow>> = emptyMap(),
)

typealias OrbMissionViewListener = (eventType: String, parsed: OrbDict, storedRow: OrbRow?) -> Unit
typealias OrbBtwViewListener = (OrbWarmBtwSnapshot) -> Unit

/**
 * Coordinates warm multiplexed WebSocket subscriptions for up to `12` recently opened
 * conversations and their `/btw` companion sessions while Orb is foregrounded, plus
 * dirty-flag tracking so returning to a clean conversation in `Off` mode skips redundant HTTP fetches.
 */
object OrbWarmSyncCoordinator {
    private class WarmMissionSub(
        val missionId: String,
        @Volatile var cursor: Long?,
    ) {
        @Volatile var healthy: Boolean = false
        @Volatile var caughtUp: Boolean = false
        @Volatile var job: Job? = null
        val listeners = ConcurrentHashMap<String, OrbMissionViewListener>()

        val isCaughtUpHealthy: Boolean
            get() = healthy && caughtUp

        fun cancel() {
            job?.cancel()
            job = null
            healthy = false
            caughtUp = false
        }
    }

    private class WarmBtwSub(
        val parentId: String,
        @Volatile var missionId: String,
    ) {
        @Volatile var caughtUp: Boolean = false
        @Volatile var job: Job? = null

        fun cancel() {
            job?.cancel()
            job = null
            caughtUp = false
        }
    }

    private val lock = Any()
    private val coordinatorScope by lazy { CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate) }
    @Volatile private var activeCore: OrbCore? = null
    @Volatile private var activeScopeKey: String = ""
    @Volatile private var appForegrounded: Boolean = true

    private val focusedCounts = LinkedHashMap<String, Int>()
    private val recentlyOpened = LinkedHashSet<String>()
    private val focusedBtwParents = LinkedHashSet<String>()
    private val warmSubs = LinkedHashMap<String, WarmMissionSub>()
    private val warmBtwSubs = LinkedHashMap<String, WarmBtwSub>()
    private val btwSnapshots = ConcurrentHashMap<String, OrbWarmBtwSnapshot>()
    private val btwListeners = ConcurrentHashMap<String, ConcurrentHashMap<String, OrbBtwViewListener>>()
    private val dirtyMissions = LinkedHashSet<String>()
    private val dirtyBtwParents = LinkedHashSet<String>()
    private val checkedCleanBtwParents = LinkedHashSet<String>()

    fun bindCore(core: OrbCore) {
        activeCore = core
    }

    fun setAppForegrounded(foregrounded: Boolean) {
        appForegrounded = foregrounded
        reconcileIfReady()
    }

    fun resetCaches() {
        synchronized(lock) {
            val iter = warmSubs.entries.iterator()
            while (iter.hasNext()) {
                val entry = iter.next()
                if (entry.value.listeners.isEmpty()) {
                    entry.value.cancel()
                    iter.remove()
                }
            }
            for (sub in warmBtwSubs.values) sub.cancel()
            warmBtwSubs.clear()
            recentlyOpened.clear()
            btwSnapshots.clear()
            dirtyMissions.clear()
            dirtyBtwParents.clear()
            checkedCleanBtwParents.clear()
        }
    }

    private fun ensureScopeLocked(core: OrbCore) {
        activeCore = core
        val scopeKey = "${core.baseURL.trim().trimEnd('/')}|${core.token.orEmpty()}"
        if (activeScopeKey == scopeKey) return
        activeScopeKey = scopeKey
        for (sub in warmSubs.values) sub.cancel()
        warmSubs.clear()
        for (sub in warmBtwSubs.values) sub.cancel()
        warmBtwSubs.clear()
        focusedCounts.clear()
        recentlyOpened.clear()
        focusedBtwParents.clear()
        btwSnapshots.clear()
        dirtyMissions.clear()
        dirtyBtwParents.clear()
        checkedCleanBtwParents.clear()
    }

    fun noteOpened(core: OrbCore, missionId: String) {
        if (missionId.isEmpty()) return
        synchronized(lock) {
            ensureScopeLocked(core)
            recentlyOpened.remove(missionId)
            recentlyOpened.add(missionId)
            while (recentlyOpened.size > OrbBackgroundSyncPolicy.MAX_WARM_MISSIONS) {
                recentlyOpened.remove(recentlyOpened.first())
            }
            focusedCounts[missionId] = (focusedCounts[missionId] ?: 0) + 1
        }
        reconcile(core)
    }

    fun noteClosed(core: OrbCore, missionId: String) {
        if (missionId.isEmpty()) return
        synchronized(lock) {
            ensureScopeLocked(core)
            val next = (focusedCounts[missionId] ?: 0) - 1
            if (next <= 0) focusedCounts.remove(missionId) else focusedCounts[missionId] = next
        }
        reconcile(core)
    }

    fun attachMissionListener(
        core: OrbCore,
        missionId: String,
        sinceSeq: Long?,
        listener: OrbMissionViewListener,
    ): String {
        val token = UUID.randomUUID().toString()
        val sub = synchronized(lock) {
            ensureScopeLocked(core)
            ensureMissionSubLocked(core, missionId, sinceSeq).also {
                it.listeners[token] = listener
            }
        }
        if (sub.isCaughtUpHealthy) {
            coordinatorScope.launch {
                if (sub.isCaughtUpHealthy && sub.listeners.containsKey(token)) {
                    listener(
                        "sync_caught_up",
                        mapOf("type" to "sync_caught_up", "mission_id" to missionId, "replayed" to 0, "cursor" to sub.cursor),
                        null
                    )
                }
            }
        }
        return token
    }

    fun detachMissionListener(core: OrbCore, missionId: String, token: String) {
        synchronized(lock) {
            warmSubs[missionId]?.listeners?.remove(token)
        }
        reconcile(core)
    }

    fun markMissionSynced(core: OrbCore, missionId: String, lastSeq: Long?) {
        synchronized(lock) {
            ensureScopeLocked(core)
            dirtyMissions.remove(missionId)
            if (lastSeq != null) {
                warmSubs[missionId]?.let { sub ->
                    val prev = sub.cursor
                    sub.cursor = if (prev != null) maxOf(prev, lastSeq) else lastSeq
                }
            }
        }
        reconcile(core)
    }

    fun isMissionWarmLive(core: OrbCore, missionId: String): Boolean = synchronized(lock) {
        ensureScopeLocked(core)
        val sub = warmSubs[missionId] ?: return@synchronized false
        sub.isCaughtUpHealthy &&
            !dirtyMissions.contains(missionId) &&
            OrbReadCache.readMemoryRows("mission_events_$missionId").isNotEmpty()
    }

    fun canSkipFullRefreshOnReopen(core: OrbCore, missionId: String): Boolean = synchronized(lock) {
        ensureScopeLocked(core)
        val hasCached = OrbReadCache.readMemoryRows("mission_events_$missionId").isNotEmpty() ||
            OrbReadCache.readMemoryRows("mission_msgs_$missionId").isNotEmpty()
        if (!hasCached) return@synchronized false
        val sub = warmSubs[missionId]
        if (sub != null && sub.isCaughtUpHealthy && !dirtyMissions.contains(missionId)) {
            return@synchronized true
        }
        !dirtyMissions.contains(missionId) && core.isMultiplexSyncHealthy
    }

    // MARK: - /btw state & warm subscriptions

    fun peekBtwSnapshot(core: OrbCore, parentId: String): OrbWarmBtwSnapshot? {
        synchronized(lock) { ensureScopeLocked(core) }
        return btwSnapshots[parentId]
    }

    fun saveBtwSnapshot(core: OrbCore, parentId: String, snapshot: OrbWarmBtwSnapshot, markClean: Boolean = true) {
        synchronized(lock) {
            ensureScopeLocked(core)
            btwSnapshots[parentId] = snapshot
            if (markClean) {
                dirtyBtwParents.remove(parentId)
                checkedCleanBtwParents.add(parentId)
            } else {
                dirtyBtwParents.add(parentId)
                checkedCleanBtwParents.remove(parentId)
            }
        }
        reconcile(core)
    }

    fun markBtwDirty(core: OrbCore, parentId: String) {
        if (parentId.isEmpty()) return
        synchronized(lock) {
            ensureScopeLocked(core)
            dirtyBtwParents.add(parentId)
            checkedCleanBtwParents.remove(parentId)
        }
    }

    fun canSkipBtwServerCrawl(core: OrbCore, parentId: String): Boolean = synchronized(lock) {
        ensureScopeLocked(core)
        if (!core.isMultiplexSyncHealthy || dirtyBtwParents.contains(parentId)) return@synchronized false
        val snap = btwSnapshots[parentId] ?: return@synchronized false
        val running = snap.boundMission?.str("status")?.lowercase() in OrbSideAgent.liveStatuses
        if (running && warmBtwSubs[parentId]?.caughtUp != true) return@synchronized false
        warmBtwSubs[parentId]?.caughtUp == true || checkedCleanBtwParents.contains(parentId)
    }

    fun isBtwStreamCaughtUp(parentId: String): Boolean = synchronized(lock) {
        warmBtwSubs[parentId]?.caughtUp == true
    }

    fun attachBtwSheet(core: OrbCore, parentId: String, listener: OrbBtwViewListener): String {
        val token = UUID.randomUUID().toString()
        synchronized(lock) {
            ensureScopeLocked(core)
            focusedBtwParents.add(parentId)
            btwListeners.getOrPut(parentId) { ConcurrentHashMap() }[token] = listener
        }
        reconcile(core)
        return token
    }

    fun detachBtwSheet(core: OrbCore, parentId: String, token: String) {
        synchronized(lock) {
            ensureScopeLocked(core)
            btwListeners[parentId]?.remove(token)
            if (btwListeners[parentId]?.isEmpty() == true) {
                focusedBtwParents.remove(parentId)
            }
        }
        reconcile(core)
    }

    fun notePresentationHint(core: OrbCore, missionId: String, kind: String?, btwParentId: String?) {
        var shouldReconcile = false
        synchronized(lock) {
            ensureScopeLocked(core)
            if (!btwParentId.isNullOrEmpty()) {
                if (missionId.isNotEmpty()) {
                    val curSnap = btwSnapshots[btwParentId]
                    if (curSnap?.boundMission?.id != missionId) {
                        val seededBound = OrbRow(missionId, mapOf("id" to missionId, "status" to "running"))
                        btwSnapshots[btwParentId] = (curSnap ?: OrbWarmBtwSnapshot()).copy(
                            boundMission = seededBound,
                            openTurn = null,
                        )
                        dirtyBtwParents.add(btwParentId)
                        checkedCleanBtwParents.remove(btwParentId)
                        shouldReconcile = true
                    }
                }
                if (warmBtwSubs[btwParentId]?.caughtUp != true) {
                    dirtyBtwParents.add(btwParentId)
                    checkedCleanBtwParents.remove(btwParentId)
                }
            }
            val sub = warmSubs[missionId]
            if (sub == null || !sub.isCaughtUpHealthy) {
                if (kind != "mission_activity") {
                    dirtyMissions.add(missionId)
                }
            }
        }
        if (shouldReconcile) reconcile(core)
    }

    fun notePresentationStreamDisrupted(core: OrbCore) {
        synchronized(lock) {
            ensureScopeLocked(core)
            for (mid in recentlyOpened) {
                if (warmSubs[mid]?.isCaughtUpHealthy != true) {
                    dirtyMissions.add(mid)
                }
            }
            checkedCleanBtwParents.clear()
        }
    }

    fun reconcileIfReady() {
        val core = activeCore ?: return
        reconcile(core)
    }

    fun reconcile(core: OrbCore) {
        synchronized(lock) {
            ensureScopeLocked(core)
            if (!appForegrounded) {
                for ((mid, sub) in warmSubs) {
                    if (!sub.isCaughtUpHealthy) dirtyMissions.add(mid)
                    sub.cancel()
                }
                warmSubs.clear()
                for (sub in warmBtwSubs.values) sub.cancel()
                warmBtwSubs.clear()
                return
            }

            val bgActive = OrbBackgroundSyncMonitor.active && core.canUseMultiplexSync
            val focusedIds = focusedCounts.keys.toList()
            val recentReady = recentlyOpened.filter { mid ->
                OrbReadCache.readMemoryRows("mission_events_$mid").isNotEmpty() ||
                    OrbReadCache.loadRows("mission_events_$mid").isNotEmpty()
            }
            val knownBtw = LinkedHashMap<String, String>()
            for ((parent, snap) in btwSnapshots) {
                val bid = snap.boundMission?.id
                if (!bid.isNullOrEmpty()) knownBtw[parent] = bid
            }
            val selection = OrbBackgroundSyncPolicy.selectWarmMissionIds(
                backgroundActive = bgActive,
                maxWarm = OrbBackgroundSyncPolicy.MAX_WARM_MISSIONS,
                focusedIds = focusedIds,
                recentIds = recentReady,
                knownBtwByParent = knownBtw,
                focusedBtwParents = focusedBtwParents.toList(),
            )
            val wantedMissions = selection.missionIds.toSet()
            val subIter = warmSubs.entries.iterator()
            while (subIter.hasNext()) {
                val (mid, sub) = subIter.next()
                if (sub.listeners.isEmpty() && mid !in wantedMissions) {
                    if (!sub.isCaughtUpHealthy) dirtyMissions.add(mid)
                    sub.cancel()
                    subIter.remove()
                }
            }
            if (bgActive) {
                for (mid in selection.missionIds) {
                    if (!warmSubs.containsKey(mid)) {
                        val cached = OrbReadCache.loadRows("mission_events_$mid")
                        if (cached.isNotEmpty()) {
                            val lastSeq = cached.lastOrNull()?.int("sequence", "seq")?.toLong()
                            ensureMissionSubLocked(core, mid, lastSeq)
                        }
                    }
                }
            }

            val wantedBtwParents = selection.btwParentIds.toSet()
            val btwIter = warmBtwSubs.entries.iterator()
            while (btwIter.hasNext()) {
                val (parent, sub) = btwIter.next()
                val currentBid = knownBtw[parent]
                if (parent !in wantedBtwParents || currentBid == null || sub.missionId != currentBid) {
                    sub.cancel()
                    btwIter.remove()
                }
            }
            for (parent in wantedBtwParents) {
                val bid = knownBtw[parent] ?: continue
                if (!warmBtwSubs.containsKey(parent)) {
                    ensureBtwSubLocked(core, parent, bid)
                }
            }
        }
    }

    private fun ensureMissionSubLocked(core: OrbCore, missionId: String, sinceSeq: Long?): WarmMissionSub {
        warmSubs[missionId]?.let { existing ->
            if (existing.job == null) startMissionSubJob(core, existing)
            return existing
        }
        val initialSeq = sinceSeq
            ?: OrbReadCache.readMemoryRows("mission_events_$missionId").lastOrNull()?.int("sequence", "seq")?.toLong()
        val created = WarmMissionSub(missionId = missionId, cursor = initialSeq)
        warmSubs[missionId] = created
        startMissionSubJob(core, created)
        return created
    }

    private fun startMissionSubJob(core: OrbCore, sub: WarmMissionSub) {
        val scopeSnapshot = activeScopeKey
        val missionId = sub.missionId
        sub.job?.cancel()
        sub.job = coordinatorScope.launch {
            while (isActive) {
                val stillActive = synchronized(lock) { activeScopeKey == scopeSnapshot && warmSubs[missionId] === sub }
                if (!stillActive) return@launch
                val closed = kotlinx.coroutines.CompletableDeferred<Unit>()
                val sinceSuffix = sub.cursor?.let { "&since_seq=$it" } ?: ""
                var source: EventSource? = null
                try {
                    source = core.openSSE(
                        path = "/api/control/stream?mission=${core.encodeComponent(missionId)}$sinceSuffix",
                        onEvent = { type, data ->
                            val parsed = OrbJSON.dict(OrbJSON.parse(data)) ?: return@openSSE
                            val evMission = OrbJSON.str(parsed, "mission_id")
                            if (evMission != null && evMission != missionId) return@openSSE
                            val evType = (type ?: OrbJSON.str(parsed, "type", "event_type") ?: "").lowercase()
                            handleMissionEvent(core, scopeSnapshot, sub, evType, parsed)
                        },
                        onClosed = {
                            closed.complete(Unit)
                        }
                    )
                    sub.healthy = true
                    closed.await()
                } catch (_: Throwable) {
                } finally {
                    source?.cancel()
                    sub.healthy = false
                    sub.caughtUp = false
                }
                val keepGoing = synchronized(lock) {
                    val keep = activeScopeKey == scopeSnapshot && warmSubs[missionId] === sub
                    if (keep && (focusedCounts[missionId] ?: 0) == 0) {
                        dirtyMissions.add(missionId)
                    }
                    keep
                }
                if (!keepGoing) return@launch
                for (listener in sub.listeners.values) {
                    listener("disconnected", mapOf("type" to "disconnected"), null)
                }
                delay(2_000L)
            }
        }
    }

    private fun handleMissionEvent(
        core: OrbCore,
        scopeSnapshot: String,
        sub: WarmMissionSub,
        evType: String,
        parsed: OrbDict,
    ) {
        val missionId = sub.missionId
        synchronized(lock) {
            if (activeScopeKey != scopeSnapshot || warmSubs[missionId] !== sub) return
            if (evType == "sync_caught_up") {
                sub.healthy = true
                sub.caughtUp = true
                val cur = (parsed["cursor"] as? Number)?.toLong()?.takeIf { it > 0L }
                if (cur != null) sub.cursor = maxOf(sub.cursor ?: cur, cur)
                dirtyMissions.remove(missionId)
            } else if (evType == "stream_lagged" || evType == "error") {
                sub.healthy = false
                sub.caughtUp = false
                dirtyMissions.add(missionId)
            } else {
                val seq = (parsed["sequence"] as? Number)?.toLong()?.takeIf { it > 0L }
                if (seq != null) sub.cursor = maxOf(sub.cursor ?: seq, seq)
            }
        }

        if (evType == "sync_caught_up" || evType == "stream_lagged" || evType == "error") {
            coordinatorScope.launch {
                for (listener in sub.listeners.values) {
                    listener(evType, parsed, null)
                }
            }
            return
        }

        val storedRow = OrbLiveEventReducer.streamFrameToStoredRow(missionId, evType, parsed)
        if (storedRow != null) {
            val evKey = "mission_events_$missionId"
            val existingEvs = OrbReadCache.readMemoryRows(evKey).ifEmpty { OrbReadCache.loadRows(evKey) }
            val mergedEvs = OrbLiveEventReducer.mergeMissionEvents(existingEvs, listOf(storedRow))
            OrbReadCache.saveRows(evKey, mergedEvs)
            val storedType = storedRow.str("event_type", "type") ?: ""
            if (storedType in OrbConversationHistory.eventTypes) {
                val msgKey = "mission_msgs_$missionId"
                val existingMsgs = OrbReadCache.readMemoryRows(msgKey).ifEmpty { OrbReadCache.loadRows(msgKey) }
                val mergedMsgs = OrbConversationHistory.merge(existingMsgs, listOf(storedRow))
                if (mergedMsgs.isNotEmpty()) {
                    OrbReadCache.saveRows(msgKey, mergedMsgs)
                }
            }
        }
        if (evType == "mission_status_changed" || evType == "mission_settings_updated") {
            coordinatorScope.launch {
                core.refreshMissionsQuietly()
            }
        }

        coordinatorScope.launch {
            for (listener in sub.listeners.values) {
                listener(evType, parsed, storedRow)
            }
        }
    }

    private fun ensureBtwSubLocked(core: OrbCore, parentId: String, missionId: String) {
        val scopeSnapshot = activeScopeKey
        val sub = WarmBtwSub(parentId = parentId, missionId = missionId)
        warmBtwSubs[parentId] = sub
        sub.job = coordinatorScope.launch {
            while (isActive) {
                val stillActive = synchronized(lock) { activeScopeKey == scopeSnapshot && warmBtwSubs[parentId] === sub }
                if (!stillActive) return@launch
                val closed = kotlinx.coroutines.CompletableDeferred<Unit>()
                val existingEvs = btwSnapshots[parentId]?.cachedEventsByThread?.get(missionId).orEmpty()
                val sinceSeq = OrbSideAgent.maxEventSeq(existingEvs).takeIf { it > 0L }
                val sinceSuffix = sinceSeq?.let { "&since_seq=$it" } ?: ""
                var source: EventSource? = null
                try {
                    source = core.openSSE(
                        path = "/api/control/stream?mission=${core.encodeComponent(missionId)}$sinceSuffix",
                        onEvent = { type, data ->
                            val parsed = OrbJSON.dict(OrbJSON.parse(data)) ?: return@openSSE
                            val evMission = OrbJSON.str(parsed, "mission_id")
                            if (evMission != null && evMission != missionId) return@openSSE
                            val evType = (type ?: OrbJSON.str(parsed, "type", "event_type") ?: "").lowercase()
                            handleBtwEvent(scopeSnapshot, sub, evType, parsed)
                        },
                        onClosed = {
                            closed.complete(Unit)
                        }
                    )
                    closed.await()
                } catch (_: Throwable) {
                } finally {
                    source?.cancel()
                    sub.caughtUp = false
                }
                val keepGoing = synchronized(lock) { activeScopeKey == scopeSnapshot && warmBtwSubs[parentId] === sub }
                if (!keepGoing) return@launch
                delay(2_000L)
            }
        }
    }

    private fun handleBtwEvent(
        scopeSnapshot: String,
        sub: WarmBtwSub,
        evType: String,
        parsed: OrbDict,
    ) {
        val parentId = sub.parentId
        val missionId = sub.missionId
        var notifySnapshot: OrbWarmBtwSnapshot? = null
        synchronized(lock) {
            if (activeScopeKey != scopeSnapshot || warmBtwSubs[parentId] !== sub) return
            if (evType == "sync_caught_up") {
                sub.caughtUp = true
                dirtyBtwParents.remove(parentId)
                checkedCleanBtwParents.add(parentId)
                return
            }
            if (evType == "stream_lagged" || evType == "error") {
                sub.caughtUp = false
                dirtyBtwParents.add(parentId)
                checkedCleanBtwParents.remove(parentId)
                return
            }
            val currentSnap = btwSnapshots[parentId] ?: OrbWarmBtwSnapshot()
            val curBound = currentSnap.boundMission
            var nextBound = curBound
            var nextEvents = currentSnap.cachedEventsByThread[missionId].orEmpty()

            if (evType == "mission_status_changed") {
                val newStatus = OrbJSON.str(parsed, "status")
                if (!newStatus.isNullOrEmpty()) {
                    nextBound = if (curBound != null && curBound.id == missionId) {
                        OrbRow(missionId, curBound.raw + ("status" to newStatus))
                    } else {
                        OrbRow(missionId, mapOf("id" to missionId, "status" to newStatus))
                    }
                }
            } else if (evType == "text_delta" || evType == "delta") {
                val delta = OrbJSON.str(parsed, "content") ?: ""
                if (delta.isNotEmpty()) {
                    val seq = (parsed["sequence"] as? Number)?.toLong() ?: (OrbSideAgent.maxEventSeq(nextEvents) + 1L)
                    val prevDelta = nextEvents.lastOrNull { (it.str("event_type", "type") ?: "") == "text_delta" }?.str("content").orEmpty()
                    val deltaRow = OrbRow(
                        "text_delta_latest",
                        mapOf(
                            "id" to seq,
                            "mission_id" to missionId,
                            "sequence" to seq,
                            "event_type" to "text_delta",
                            "event_id" to "text_delta_latest",
                            "content" to (prevDelta + delta),
                        )
                    )
                    nextEvents = OrbLiveEventReducer.mergeMissionEvents(nextEvents, listOf(deltaRow))
                    if (nextBound == null || nextBound.str("status")?.lowercase() !in OrbSideAgent.liveStatuses) {
                        nextBound = OrbRow(missionId, (nextBound?.raw ?: mapOf("id" to missionId)) + ("status" to "running"))
                    }
                }
            } else {
                val stored = OrbLiveEventReducer.streamFrameToStoredRow(missionId, evType, parsed) ?: return
                nextEvents = OrbLiveEventReducer.mergeMissionEvents(nextEvents, listOf(stored))
                val sType = stored.str("event_type", "type") ?: ""
                if (sType == "user_message" || sType == "assistant_message") {
                    nextEvents = nextEvents.filterNot { (it.str("event_type", "type") ?: "") == "text_delta" }
                }
                if (sType == "user_message" && OrbJSON.bool(stored.dict("metadata"), "queued") != true) {
                    nextBound = OrbRow(missionId, (nextBound?.raw ?: mapOf("id" to missionId)) + ("status" to "running"))
                }
            }

            val active = (nextBound?.str("status")?.lowercase() ?: "") in OrbSideAgent.liveStatuses
            val prevParsed = currentSnap.cachedThreads[missionId]?.second
            val nextParsed = OrbSideAgent.parseTurns(
                missionId = missionId,
                events = nextEvents,
                active = active,
                history = nextBound?.rows("history").orEmpty(),
                previous = prevParsed,
            )
            val otherTurns = currentSnap.turns.filterNot { it.id.startsWith("btw:$missionId:") }
            val mergedTurns = OrbSideAgent.mergeTurns(listOf(otherTurns, nextParsed.turns))
            val updatedEventsMap = LinkedHashMap(currentSnap.cachedEventsByThread).apply { put(missionId, nextEvents) }
            val updatedThreadsMap = LinkedHashMap(currentSnap.cachedThreads).apply { put(missionId, "" to nextParsed) }
            val updatedSnap = OrbWarmBtwSnapshot(
                boundMission = nextBound,
                turns = mergedTurns,
                openTurn = nextParsed.open,
                cachedThreads = updatedThreadsMap,
                cachedEventsByThread = updatedEventsMap,
            )
            btwSnapshots[parentId] = updatedSnap
            notifySnapshot = updatedSnap
        }

        val snap = notifySnapshot ?: return
        coordinatorScope.launch {
            btwListeners[parentId]?.values?.forEach { it(snap) }
        }
    }
}
