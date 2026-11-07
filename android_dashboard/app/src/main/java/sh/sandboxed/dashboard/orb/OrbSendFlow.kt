package sh.sandboxed.dashboard.orb

enum class OrbCyberMode(val wire: String, val label: String) {
    Automatic("automatic", "Automatic"), Standard("standard", "Standard"), Daybreak("daybreak", "Daybreak")
}

data class OrbCyberSelection(val mode: OrbCyberMode, val status: String?, val revision: String?, val confirmedProgram: String?) {
    val summary: String get() = if (status == "confirmed" && !confirmedProgram.isNullOrBlank())
        "${mode.label} · confirmed: $confirmedProgram" else "${mode.label} · requested"

    companion object {
        fun parse(value: OrbDict): OrbCyberSelection = OrbCyberSelection(
            OrbCyberMode.entries.firstOrNull { it.wire == OrbJSON.str(value, "mode") }
                ?: throw OrbError("Cyber selection unavailable. Update or reconnect before changing this option."),
            OrbJSON.str(value, "status"), OrbJSON.str(value, "revision"), OrbJSON.str(value, "confirmed_program")
        )
    }
}

object OrbCyberAccess {
    fun nativeCodex(backend: String?, cloud: OrbDict? = null): Boolean = backend == "codex" &&
        OrbJSON.str(cloud, "provider").isNullOrBlank()

    const val EMPTY_GOAL = "Add an objective after /goal, for example “/goal Make the test suite pass”. Your draft is kept."

    suspend fun requireFollowUp(core: OrbCore, missionId: String, content: String) =
        requireFollowUp(missionId, content, core::encodeComponent) { path -> OrbJSON.dict(core.request(path)) ?: emptyMap() }

    suspend fun requireFollowUp(missionId: String, content: String, encode: (String) -> String = { it },
        get: suspend (String) -> OrbDict) {
        val base = "/api/control/missions/${encode(missionId)}"
        val value = get("$base?include_history=false")
        val mission = OrbRow(OrbJSON.dict(value["mission"]) ?: value)
        val backend = mission.str("backend") ?: throw OrbError("Mission settings unavailable. Your draft is kept.")
        if (!nativeCodex(backend, mission.dict("cloud"))) return
        val goal = nativeGoal(backend, content)
        if (goal && content.trim().equals("/goal", ignoreCase = true))
            throw OrbError(EMPTY_GOAL)
        val cyber = OrbCyberSelection.parse(get("$base/cyber"))
        requireSupport(mission.str("model_override") ?: "", cyber.mode, remote(mission), goal, get)
    }

    suspend fun requireInherited(core: OrbCore, sourceId: String, backend: String, model: String, content: String) {
        if (!nativeCodex(backend)) return
        val base = "/api/control/missions/${core.encodeComponent(sourceId)}"
        val value = OrbJSON.dict(core.request("$base?include_history=false")) ?: throw OrbError("Mission settings unavailable. Your draft is kept.")
        val source = OrbRow(OrbJSON.dict(value["mission"]) ?: value)
        val cyber = OrbCyberSelection.parse(OrbJSON.dict(core.request("$base/cyber")) ?: emptyMap())
        if (content.trim().equals("/goal", ignoreCase = true)) throw OrbError(EMPTY_GOAL)
        requireSupport(model, cyber.mode, remote(source), nativeGoal(backend, content)) { path ->
            OrbJSON.dict(core.request(path)) ?: emptyMap()
        }
    }

    fun nativeGoal(backend: String, prompt: String): Boolean = backend == "codex" &&
        Regex("^/goal(?:\\s|$)", RegexOption.IGNORE_CASE).containsMatchIn(prompt.trimStart())

    fun remote(mission: OrbRow): Boolean {
        mission.dict("machine_transfer")?.let { transfer ->
            OrbJSON.dict(transfer["destination"])?.let { return OrbJSON.str(it, "kind") == "node" }
        }
        val tags = mission.raw["tags"] as? List<*>
        return tags?.contains("placement:client") != true && mission.bool("local_run_active") != true &&
            (!mission.str("remote_node_id").isNullOrBlank() || !OrbJSON.str(mission.dict("remote_job"), "node_id").isNullOrBlank())
    }

    fun compatibility(mode: OrbCyberMode, model: String): String? {
        val id = model.substringAfterLast('/')
        if (id == "gpt-daybreak-blue-latest" || id == "gpt-daybreak-red-latest")
            return "OpenAI retired the $id alias on 2026-10-28. Choose a specific model ID such as ${if (id.contains("red")) "gpt-5.6-cyber" else "gpt-6.1-sol"}."
        if (mode == OrbCyberMode.Standard && (id.startsWith("gpt-daybreak-") || id == "gpt-5.6-cyber"))
            return "This model requires Daybreak. Choose Daybreak or Automatic, or change the model."
        if (mode == OrbCyberMode.Daybreak && id !in setOf("gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-5.6-sol", "gpt-5.6-cyber"))
            return "Daybreak support has not been established for this model."
        return null
    }

    fun error(error: Throwable): String {
        val text = error.message ?: "Cyber request failed"
        return when {
            "access_program_not_enabled" in text -> "Daybreak is not enabled for this account and model. Check the account’s approved access, or explicitly select Standard. The model was not changed."
            "unsupported_access_program" in text -> "This connection cannot apply the requested cyber program. Choose another supported connection, or explicitly select Automatic. $text"
            "invalid_access_program" in text -> "The selected cyber program is incompatible with this model. Choose another program or model."
            "cyberPolicy" in text || "cyber_policy" in text -> "OpenAI rejected this request under its cyber policy. This can also happen with Daybreak enabled. $text"
            else -> text
        }
    }

    suspend fun requireSupport(model: String, mode: OrbCyberMode, remote: Boolean, goal: Boolean,
        get: suspend (String) -> OrbDict) {
        if (!remote || model.isNotBlank()) compatibility(mode, model)?.let { throw OrbError(it) }
        val query = (if (model.isNotBlank()) "model=${java.net.URLEncoder.encode(model, "UTF-8")}&" else "") +
            "mode=${mode.wire}&remote=$remote"
        val value = try { get("/api/control/cyber-capabilities?$query") } catch (e: Exception) {
            throw OrbError("Update or reconnect to a backend supporting cyber selection before launching. Your draft is kept; the requested program was not silently omitted.")
        }
        if ((value["version"] as? Number)?.toInt() != 2)
            throw OrbError("Update or reconnect to a backend supporting cyber selection before launching. Your draft is kept.")
        if (goal && mode != OrbCyberMode.Automatic && value["native_goals_explicit"] != true)
            throw OrbError("This connection cannot confirm an explicit Cyber program for native goals. Choose Automatic explicitly. Your draft is kept.")
        if (remote && mode != OrbCyberMode.Automatic && value["route_supported"] != true)
            throw OrbError(OrbJSON.str(value, "refusal") ?: "This backend cannot confirm the selected Cyber route. Choose Automatic explicitly. Your draft is kept.")
    }
}

/**
 * Smooth sending on mobile, mirroring the desktop work in PR #1174
 * (orb/src/RemoteQueue.tsx, orb/src/mission/handoff.ts, orb/src/missionStatus.ts).
 * Pure state, no Compose or network, so every rule is unit tested
 * (OrbSendFlowTest). The conversation screen owns one [OrbFollowUpQueue] and
 * one [OrbHandoff] per mission and drives the HTTP calls around them.
 */

/** One follow-up shown in the compact queue above the composer. */
data class OrbQueuedRow(
    val id: String,
    val content: String,
    /** Optimistic: posted, Core has not listed it yet. Not actionable. */
    val sending: Boolean = false,
    /** Core could not deliver it yet (shown under the row). */
    val queueError: String? = null,
    val postedAtMs: Long? = null
)

data class OrbDeliveredMessage(
    val id: String?,
    val content: String,
    val sequence: Long
)

/**
 * The follow-up queue as the user sees it: Core's durable inbox
 * (`GET /api/control/queue?mission_id=`) merged with optimistic sends,
 * optimistic in-place edits and optimistic removals / send-nows.
 */
data class OrbFollowUpQueue(
    val server: List<OrbQueuedRow> = emptyList(),
    val pending: List<OrbQueuedRow> = emptyList(),
    val edits: Map<String, String> = emptyMap(),
    /** Removed or sent now locally; hidden even if a stale poll still lists them. */
    val hidden: Set<String> = emptySet(),
    /** Ids already shown as delivered in the transcript. */
    val delivered: Set<String> = emptySet(),
    val seenAfter: Map<String, Long> = emptyMap(),
    val consumedSequences: Set<Long> = emptySet()
) {
    /** Rows in Core's FIFO order, then optimistic ones; edits applied. */
    val rows: List<OrbQueuedRow>
        get() {
            val seen = mutableSetOf<String>()
            val out = mutableListOf<OrbQueuedRow>()
            for (row in server + pending) {
                if (row.id in hidden || row.id in delivered || !seen.add(row.id)) continue
                out += edits[row.id]?.let { row.copy(content = it) } ?: row
            }
            return out
        }

    val count: Int get() = rows.size

    /** A fresh poll: Core is authoritative for what it lists; optimistic rows it now lists stop being "sending". */
    fun withServer(
        rows: List<OrbQueuedRow>,
        fetchedAtMs: Long = Long.MIN_VALUE,
        lastSequence: Long? = null
    ): OrbFollowUpQueue {
        val listed = rows.map { it.id }.toSet()
        val remaining = pending.filterNot { row ->
            row.id in listed || (!row.sending && row.postedAtMs?.let { it < fetchedAtMs } == true)
        }
        val baselines = seenAfter.toMutableMap()
        if (lastSequence != null) {
            for (row in rows) baselines.putIfAbsent(row.id, lastSequence)
        }
        val live = listed + remaining.map { it.id }
        return copy(
            server = rows.map { it.copy(sending = false) },
            pending = remaining,
            hidden = hidden.filter { it in listed }.toSet(),
            seenAfter = baselines.filterKeys { it in live }
        )
    }

    fun withDelivered(ids: Set<String>): OrbFollowUpQueue = copy(delivered = delivered + ids)

    fun reconciled(messages: List<OrbDeliveredMessage>): OrbFollowUpQueue {
        if (messages.isEmpty()) return this
        val ids = messages.mapNotNull { it.id }.toSet()
        val nextDelivered = delivered.toMutableSet()
        for (row in rows) {
            if (row.id in ids) {
                nextDelivered.add(row.id)
            }
        }
        val used = consumedSequences.toMutableSet()
        for (message in messages) {
            if (message.id != null && message.id in nextDelivered) {
                used.add(message.sequence)
            }
        }
        val known = (server + pending).map { it.id }.toSet()
        for (row in rows) {
            if (row.id in nextDelivered) continue
            val after = seenAfter[row.id] ?: continue
            val message = messages.firstOrNull {
                it.sequence !in used && it.sequence > after && it.id !in known &&
                    it.content.trim() == row.content.trim()
            }
            if (message != null) {
                used.add(message.sequence)
                nextDelivered.add(row.id)
            }
        }
        return copy(delivered = nextDelivered, consumedSequences = used)
    }

    /** Optimistic send while a turn runs: the row appears at once with a spinner. */
    fun enqueue(id: String, content: String, lastSequence: Long? = null): OrbFollowUpQueue = copy(
        pending = pending.filterNot { it.id == id } + OrbQueuedRow(id, content, sending = true),
        seenAfter = if (lastSequence != null) seenAfter + (id to lastSequence) else seenAfter - id
    )

    /** POST /api/control/message answered: queued (keep) or delivered (drop the row). */
    fun posted(id: String, queued: Boolean, atMs: Long = System.currentTimeMillis()): OrbFollowUpQueue =
        if (queued) copy(pending = pending.map { if (it.id == id) it.copy(sending = false, postedAtMs = atMs) else it })
        else copy(pending = pending.filterNot { it.id == id })

    fun postFailed(id: String): OrbFollowUpQueue = copy(pending = pending.filterNot { it.id == id })

    /** Edit in place: same id, same position, text changes now. */
    fun edit(id: String, content: String): OrbFollowUpQueue = copy(edits = edits + (id to content))

    /** PATCH confirmed: the server copy takes the new text. */
    fun editConfirmed(id: String, content: String): OrbFollowUpQueue = copy(
        server = server.map { if (it.id == id) it.copy(content = content) else it },
        pending = pending.map { if (it.id == id) it.copy(content = content) else it },
        edits = edits - id
    )

    fun editReverted(id: String): OrbFollowUpQueue = copy(edits = edits - id)

    /** Remove or Send now: the row leaves at once. */
    fun hide(id: String): OrbFollowUpQueue = copy(hidden = hidden + id)

    fun unhide(id: String): OrbFollowUpQueue = copy(hidden = hidden - id)

    fun row(id: String): OrbQueuedRow? = rows.firstOrNull { it.id == id }

    companion object {
        /** Rows from `GET /api/control/queue` for [missionId] that belong in the follow-up queue. */
        fun parse(items: List<OrbDict>, missionId: String): List<OrbQueuedRow> = items.mapNotNull { item ->
            val id = OrbJSON.str(item, "id") ?: return@mapNotNull null
            val content = OrbJSON.rawStr(item, "content") ?: return@mapNotNull null
            if (OrbJSON.str(item, "mission_id") != missionId) return@mapNotNull null
            if (item["inflight"] == true) return@mapNotNull null
            val source = OrbJSON.str(item, "source")
            if (source != null && source != "remote-queue" && !source.startsWith("host-queue:api:")) return@mapNotNull null
            OrbQueuedRow(id, content, queueError = OrbJSON.str(item, "queue_error"))
        }
    }
}

/** What to do after `PATCH /api/control/queue/:id`. */
enum class OrbEditOutcome { Edited, Unsupported, AlreadySent, Failed }

object OrbSendFlow {
    /** How long a sent row takes to collapse out of the queue (desktop LEAVE_MS). */
    const val LEAVE_MS = 160

    fun editOutcome(httpStatus: Int?): OrbEditOutcome {
        if (httpStatus == null) return OrbEditOutcome.Failed
        if (httpStatus == 404) return OrbEditOutcome.AlreadySent
        return when (OrbKernel.sendFlowStep(httpStatus = httpStatus).editOutcome) {
            1 -> OrbEditOutcome.Edited
            2 -> OrbEditOutcome.Unsupported
            3 -> OrbEditOutcome.AlreadySent
            else -> OrbEditOutcome.Failed
        }
    }

    enum class SendNow { Live, Promoted, Fallback }

    /**
     * Reading of `POST /api/control/queue/:id/send-now?interrupt=true`.
     * Only an explicit answer without delivery/promotion means "stop then send" (older Core).
     */
    fun sendNowOutcome(response: OrbDict?): SendNow = when {
        response?.get("delivered") == true -> SendNow.Live
        response?.get("promoted") == true -> SendNow.Promoted
        else -> SendNow.Fallback
    }

    /**
     * Current turn's stored assistant messages (excluding narration already moved into the work fold),
     * so previous turns' replies never suppress live streaming text on a follow-up turn.
     */
    fun currentTurnStoredAnswers(messages: List<Pair<String, String>>, narration: Set<String> = emptySet()): List<String> {
        val lastUserIdx = messages.indexOfLast { it.first == "user" }
        return messages.subList(lastUserIdx + 1, messages.size)
            .mapNotNull { (role, content) ->
                if (role != "assistant") return@mapNotNull null
                val trimmed = content.trim()
                if (trimmed.isEmpty() || trimmed in narration) null else content
            }
            .takeLast(3)
    }

    /**
     * Live streamed text that the stored history already contains is dropped,
     * so a reload never shows the assistant's words twice. When the stored text
     * is a prefix of what streamed, only the unseen tail stays live.
     */
    fun dedupeLiveText(live: String, storedAssistantTexts: List<String>): String {
        val l = live.trim()
        if (l.isEmpty()) return ""
        for (stored in storedAssistantTexts.asReversed().take(3)) {
            val s = stored.trim()
            if (s.isEmpty()) continue
            if (s == l || s.startsWith(l)) return ""
            if (l.startsWith(s)) return l.removePrefix(s).trimStart()
        }
        return live
    }
}

/**
 * Send now = stop the turn, then a new turn with the promoted message. In
 * between, Core briefly reports `interrupted` (or idle) and the old job ends.
 * While a handoff is pending the screen keeps one continuous
 * "Sending…" → "Working…" state, keeps Stop, and shows no "interrupted"
 * error. It ends once the mission was seen stopped and running again, a new
 * remote job runs, a failure shows, or [TIMEOUT_MS] passes.
 */
data class OrbHandoff(val id: String, val atMs: Long) {
    companion object {
        const val TIMEOUT_MS = 30_000L
        private val HANDOFF_STATUSES = setOf(
            "interrupted", "cancelled", "paused", "awaiting_user", "waiting_user", "waiting_for_user",
            "completed", "idle", ""
        )

        /** True while the handoff masks the in-between status. Failures are never masked. */
        fun pending(status: String?, handoff: OrbHandoff?, nowMs: Long): Boolean {
            if (handoff == null) return false
            if (nowMs - handoff.atMs >= TIMEOUT_MS || nowMs < handoff.atMs - 1000) return false
            val s = status?.trim()?.lowercase() ?: ""
            return s in HANDOFF_STATUSES || MissionState.of(s)?.live == true
        }
    }
}

/** handoff.ts: feed mission snapshots; [observe] returns true when the handoff is over. */
class OrbHandoffTracker {
    private var current: String? = null
    private var stopSeen = false
    private var oldJob: String? = null
    private var oldJobKnown = false

    fun reset() {
        current = null; stopSeen = false; oldJob = null; oldJobKnown = false
    }

    fun observe(handoff: OrbHandoff, status: String?, jobId: String?, jobEnded: Boolean): Boolean {
        if (current != handoff.id) {
            current = handoff.id
            stopSeen = false
            oldJob = if (jobId != null && !jobEnded) jobId else null
            oldJobKnown = true
        }
        val state = MissionState.of(status)
        if (state?.category == MissionCategory.Failed) return true
        val running = state?.live == true && !jobEnded
        if (!running) {
            stopSeen = true
            return false
        }
        val newJob = jobId != null && oldJobKnown && oldJob != null && jobId != oldJob
        return stopSeen || newJob
    }
}
