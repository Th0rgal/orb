package sh.sandboxed.dashboard.orb

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
    val queueError: String? = null
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
    val delivered: Set<String> = emptySet()
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
    fun withServer(rows: List<OrbQueuedRow>): OrbFollowUpQueue {
        val listed = rows.map { it.id }.toSet()
        return copy(
            server = rows.map { it.copy(sending = false) },
            pending = pending.filterNot { it.id in listed },
            // A hidden id Core no longer lists is settled.
            hidden = hidden.filter { it in listed }.toSet()
        )
    }

    fun withDelivered(ids: Set<String>): OrbFollowUpQueue = copy(delivered = ids)

    /** Optimistic send while a turn runs: the row appears at once with a spinner. */
    fun enqueue(id: String, content: String): OrbFollowUpQueue =
        copy(pending = pending.filterNot { it.id == id } + OrbQueuedRow(id, content, sending = true))

    /** POST /api/control/message answered: queued (keep) or delivered (drop the row). */
    fun posted(id: String, queued: Boolean): OrbFollowUpQueue =
        if (queued) copy(pending = pending.map { if (it.id == id) it.copy(sending = false) else it })
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
        return when (OrbKernel.sendFlowStep(httpStatus = httpStatus).editOutcome) {
            1 -> OrbEditOutcome.Edited
            // Older Core without the PATCH route, or a row outside the durable inbox: replace instead.
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
            if (s == l || s.contains(l)) return ""
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
