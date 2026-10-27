package sh.sandboxed.dashboard.orb

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Instant
import java.util.UUID

/**
 * Opt-in Orb usage telemetry (docs/USAGE_TELEMETRY.md), same model as desktop
 * and iOS. Events are only queued while Core reports `active`; Core drops
 * any field outside shared/orb-spec/fixtures/usage-telemetry.json. Never put
 * prompt text, approval payloads, commands or secrets in an event.
 *
 * Approval method on Android: BiometricPrompt does not say whether a face or a
 * fingerprint matched, so a strong biometric is reported as "touch_id" (the
 * closest fixture value; "face_id" is never sent), the device PIN/pattern/
 * password as "passcode", and an unsigned approval (no enrolled key) as "none".
 */
object UsageTelemetry {
    enum class Action(val wire: String) {
        SidebarMove("sidebar_move"), Btw("btw"), Fork("fork"), Queue("queue"),
        FileViewerOpen("file_viewer_open"), InboxOpen("inbox_open"), InboxArchive("inbox_archive"),
        InboxSnooze("inbox_snooze"), InboxDone("inbox_done"), MessageEdit("message_edit"),
        MessageResend("message_resend"),
    }

    enum class ApprovalKind(val wire: String) { Tool("tool"), CommandClass("command_class"), Grant("grant"), Payment("payment") }
    enum class Decision(val wire: String) { Approved("approved"), Denied("denied"), Expired("expired"), Dismissed("dismissed") }
    enum class Method(val wire: String) { FaceId("face_id"), TouchId("touch_id"), Passcode("passcode"), DesktopClick("desktop_click"), None("none") }
    enum class Surface(val wire: String) { Screen("screen"), Sheet("sheet"), Pane("pane") }

    const val CLIENT = "android"
    const val FLUSH_INTERVAL_MS = 30_000L
    const val BATCH_SIZE = 50
    const val MAX_QUEUE = 500
    private val IDENT = Regex("^[A-Za-z0-9_.:/+@-]{1,120}$")

    fun isIdent(value: String?): Boolean = value != null && IDENT.matches(value)

    /** Network side, injectable for tests. */
    interface Transport {
        suspend fun status(): OrbDict
        /** Throws on failure; returns Core's `enabled`. */
        suspend fun send(events: List<OrbDict>): Boolean
    }

    /** Queue, batching and retry; pure enough to unit test with a fake transport. */
    class Queue(
        private val transport: Transport,
        private val appVersion: String,
        private val now: () -> Long = System::currentTimeMillis,
    ) {
        private val pending = ArrayDeque<OrbDict>()
        private val flushLock = Mutex()
        private val _status = MutableStateFlow<OrbDict>(emptyMap())
        val status: StateFlow<OrbDict> = _status.asStateFlow()
        val active: Boolean get() = _status.value["active"] == true
        val queued: Int get() = synchronized(pending) { pending.size }

        fun setStatus(status: OrbDict) {
            _status.value = status
            if (status["active"] != true) synchronized(pending) { pending.clear() }
        }

        suspend fun refresh() {
            runCatching { transport.status() }.onSuccess(::setStatus)
        }

        fun build(schema: String, fields: Map<String, Any?>): OrbDict {
            val event = linkedMapOf<String, Any?>(
                "schema" to schema,
                "event_id" to UUID.randomUUID().toString(),
                "ts" to Instant.ofEpochMilli(now()).toString(),
                "client" to CLIENT,
                "app_version" to appVersion,
            )
            for ((k, v) in fields) when (v) {
                null -> {}
                is String -> if (isIdent(v)) event[k] = v
                is Number -> event[k] = maxOf(0L, v.toLong())
                else -> event[k] = v
            }
            return event
        }

        /** Queues when active; returns true when a batch is full and should flush. */
        fun enqueue(event: OrbDict): Boolean {
            if (!active) return false
            return synchronized(pending) {
                pending.addLast(event)
                while (pending.size > MAX_QUEUE) pending.removeFirst()
                pending.size >= BATCH_SIZE
            }
        }

        /** Sends everything queued in batches; on failure the events stay for the next flush. */
        suspend fun flush(): Boolean = flushLock.withLock {
            var batch = synchronized(pending) { pending.take(BATCH_SIZE) }
            while (batch.isNotEmpty()) {
                val enabled = try {
                    transport.send(batch)
                } catch (e: Throwable) {
                    return@withLock false
                }
                // Drop exactly what was sent (the oldest), unless the cap already evicted them.
                synchronized(pending) {
                    var n = batch.size
                    while (n > 0 && pending.isNotEmpty() && batch.contains(pending.first())) { pending.removeFirst(); n-- }
                }
                if (!enabled) {
                    setStatus(_status.value + ("active" to false))
                    return@withLock true
                }
                batch = synchronized(pending) { pending.take(BATCH_SIZE) }
            }
            true
        }

        fun page(screen: String, surface: Surface, entryPoint: String?, dwellMs: Long) =
            build("orb.page.v1", mapOf("screen" to screen, "surface" to surface.wire, "entry_point" to entryPoint, "dwell_ms" to dwellMs))

        fun action(action: Action, surface: String?, count: Int = 1) =
            build("orb.action.v1", mapOf("action" to action.wire, "surface" to surface, "count" to count))

        fun approval(kind: ApprovalKind, decision: Decision, method: Method, waitMs: Long, toolName: String?, commandClass: String?) =
            build(
                "orb.approval.v1",
                mapOf(
                    "kind" to kind.wire, "decision" to decision.wire, "method" to method.wire,
                    "wait_ms" to waitMs, "tool_name" to toolName, "command_class" to commandClass,
                )
            )
    }

    class CoreTransport(private val core: OrbCore) : Transport {
        override suspend fun status(): OrbDict = core.fetchDict("/api/usage-telemetry")
        override suspend fun send(events: List<OrbDict>): Boolean =
            OrbJSON.dict(core.request("/api/usage-telemetry/events", "POST", body = mapOf("events" to events)))?.get("enabled") != false
    }

    @Volatile private var queue: Queue? = null
    private var core: OrbCore? = null
    private var loop: Job? = null
    private val emptyStatus = MutableStateFlow<OrbDict>(emptyMap())

    val status: StateFlow<OrbDict> get() = queue?.status ?: emptyStatus
    val queued: Int get() = queue?.queued ?: 0

    fun install(core: OrbCore, appVersion: String) {
        if (queue != null) return
        this.core = core
        queue = Queue(CoreTransport(core), appVersion)
    }

    /** App came to the foreground: refresh status and flush every 30 s. */
    fun onForeground() {
        val c = core ?: return
        val q = queue ?: return
        loop?.cancel()
        loop = c.scope.launch {
            q.refresh()
            while (isActive) {
                delay(FLUSH_INTERVAL_MS)
                if (q.queued > 0) q.flush()
            }
        }
    }

    /** App went to the background: stop the timer and flush now. */
    fun onBackground() {
        loop?.cancel()
        loop = null
        val c = core ?: return
        val q = queue ?: return
        if (q.queued > 0) c.scope.launch { q.flush() }
    }

    /** After a settings change: use the status Core returned. */
    fun applyStatus(status: OrbDict) {
        queue?.setStatus(status)
    }

    suspend fun refresh() {
        queue?.refresh()
    }

    private fun submit(build: Queue.() -> OrbDict) {
        val q = queue ?: return
        if (!q.active) return
        if (q.enqueue(q.build())) core?.scope?.launch { q.flush() }
    }

    class PageHandle internal constructor(
        private val screen: String,
        private val surface: Surface,
        private val entryPoint: String?,
    ) {
        private val opened = System.currentTimeMillis()
        private var closed = false
        fun close() {
            if (closed) return
            closed = true
            val dwell = System.currentTimeMillis() - opened
            submit { page(screen, surface, entryPoint, dwell) }
        }
    }

    fun trackPage(screen: String, surface: Surface, entryPoint: String? = null): PageHandle =
        PageHandle(screen, surface, entryPoint)

    fun trackAction(action: Action, surface: String? = null) = submit { action(action, surface) }

    fun trackApproval(
        kind: ApprovalKind,
        decision: Decision,
        method: Method,
        waitMs: Long,
        toolName: String? = null,
        commandClass: String? = null,
    ) = submit { approval(kind, decision, method, waitMs, toolName, commandClass) }

    /** What an approval decides, passed to the signing path that measures wait and method. */
    data class Approval(
        val kind: ApprovalKind,
        val decision: Decision,
        val toolName: String? = null,
        val commandClass: String? = null,
    )
}

/** Emits one orb.page.v1 with dwell_ms when this composable leaves (or its key changes). */
@Composable
fun TrackPage(screen: String, surface: UsageTelemetry.Surface, entryPoint: String? = null) {
    DisposableEffect(screen, surface) {
        val handle = UsageTelemetry.trackPage(screen, surface, entryPoint)
        onDispose { handle.close() }
    }
}
