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

    suspend fun requireFollowUp(core: OrbCore, missionId: String, content: String): OrbCyberSelection? =
        requireFollowUp(missionId, content, core::encodeComponent) { path -> OrbJSON.dict(core.request(path)) ?: emptyMap() }

    suspend fun requireFollowUp(missionId: String, content: String, encode: (String) -> String = { it },
        get: suspend (String) -> OrbDict): OrbCyberSelection? {
        val base = "/api/control/missions/${encode(missionId)}"
        val value = get("$base?include_history=false")
        val mission = OrbRow(OrbJSON.dict(value["mission"]) ?: value)
        val backend = mission.str("backend") ?: throw OrbError("Mission settings unavailable. Your draft is kept.")
        if (!nativeCodex(backend, mission.dict("cloud"))) return null
        val goal = nativeGoal(backend, content)
        if (goal && content.trim().equals("/goal", ignoreCase = true))
            throw OrbError(EMPTY_GOAL)
        val cyber = OrbCyberSelection.parse(get("$base/cyber"))
        requireSupport(mission.str("model_override") ?: "", cyber.mode, remote(mission), goal, get)
        return cyber
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
        return !mission.isClientPlacement() && mission.bool("local_run_active") != true &&
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
    val postedAtMs: Long? = null,
    val revision: Long? = null
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
    val consumedSequences: Set<Long> = emptySet(),
    val serverRev: Long = 1L,
    val hasServerRevision: Boolean = false
) {
    fun expectedRevision(id: String): Long? {
        if (hasServerRevision) return serverRev
        val rowRev = server.firstOrNull { it.id == id }?.revision
        return if (rowRev != null && rowRev > 0L) rowRev else null
    }
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
        lastSequence: Long? = null,
        incomingServerRev: Long? = null,
        turnSeq: Long? = null
    ): OrbFollowUpQueue {
        val normalizedIncoming = incomingServerRev?.takeIf { it > 0L }?.coerceAtMost(0xFFFF_FFFFL)
        val effectiveRev = normalizedIncoming ?: serverRev
        val gate = OrbKernel.followupQueueStep(
            op = 0,
            serverRev = serverRev.toInt(),
            incomingServerRev = effectiveRev.toInt(),
            expectedServerRev = 0,
            clientMsgId = 0L,
            trackedMsgId = 0L,
            deliveredMsgId = 0L,
            postedAfterSeq = 0L,
            turnSeq = 0L,
            optimisticSending = false,
            serverListed = false,
            contentMatched = false,
            alreadyDelivered = false
        )
        if (!gate.admitted) return this

        val listed = rows.map { it.id }.toSet()
        val nextDelivered = delivered.toMutableSet()
        val remaining = pending.filterNot { row ->
            val rowHash = hashMessageId(row.id)
            val isDelivered = row.id in delivered
            val isListed = row.id in listed
            val postedBeforeFetch = !row.sending && row.postedAtMs?.let { it < fetchedAtMs } == true
            val afterSeq = seenAfter[row.id]
            val pollTurnSeq = when {
                turnSeq != null && turnSeq >= 0L -> turnSeq
                postedBeforeFetch -> {
                    val base = seqWord(afterSeq)
                    if (base != Long.MAX_VALUE) base + 1 else base
                }
                else -> 0L
            }
            val postedWord = if (turnSeq != null && afterSeq == null) Long.MAX_VALUE else seqWord(afterSeq)
            val verdict = OrbKernel.followupQueueStep(
                op = 0,
                serverRev = serverRev.toInt(),
                incomingServerRev = effectiveRev.toInt(),
                expectedServerRev = 0,
                clientMsgId = rowHash,
                trackedMsgId = rowHash,
                deliveredMsgId = 0L,
                postedAfterSeq = postedWord,
                turnSeq = pollTurnSeq,
                optimisticSending = row.sending,
                serverListed = isListed,
                contentMatched = false,
                alreadyDelivered = isDelivered
            )
            if (verdict.retiredNow && turnSeq != null) {
                nextDelivered.add(row.id)
            }
            isListed || postedBeforeFetch || !verdict.optimisticLiveNext
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
            seenAfter = baselines.filterKeys { it in live },
            delivered = nextDelivered,
            serverRev = gate.nextServerRev.toLong() and 0xFFFF_FFFFL,
            hasServerRevision = hasServerRevision || normalizedIncoming != null
        )
    }

    fun withDelivered(ids: Set<String>): OrbFollowUpQueue = copy(delivered = delivered + ids)

    fun reconciled(messages: List<OrbDeliveredMessage>): OrbFollowUpQueue {
        if (messages.isEmpty()) return this
        val nextDelivered = delivered.toMutableSet()
        val used = consumedSequences.toMutableSet()
        val known = (server + pending).map { it.id }.toSet() + delivered
        val currentRows = rows
        for (row in currentRows) {
            val rowHash = hashMessageId(row.id)
            for (message in messages) {
                if (message.id != row.id) continue
                val verdict = OrbKernel.followupQueueStep(
                    op = 3,
                    serverRev = serverRev.toInt(),
                    incomingServerRev = 0,
                    expectedServerRev = 0,
                    clientMsgId = rowHash,
                    trackedMsgId = rowHash,
                    deliveredMsgId = rowHash,
                    postedAfterSeq = seqWord(seenAfter[row.id]),
                    turnSeq = seqWord(message.sequence),
                    optimisticSending = row.sending,
                    serverListed = server.any { it.id == row.id },
                    contentMatched = false,
                    alreadyDelivered = row.id in nextDelivered
                )
                if (verdict.retiredNow) {
                    nextDelivered.add(row.id)
                }
            }
        }
        for (message in messages) {
            if (message.id != null && message.id in nextDelivered) {
                used.add(message.sequence)
            }
        }
        for (row in currentRows) {
            if (row.id in nextDelivered) continue
            val after = seenAfter[row.id] ?: continue
            val rowHash = hashMessageId(row.id)
            val rowTrimmed = row.content.trim()
            for (m in messages) {
                if (m.sequence in used || m.sequence < 0L || after < 0L) continue
                val delivHash = if (m.id != null && m.id in known) hashMessageId(m.id) else 0L
                val matched = m.content.trim() == rowTrimmed
                val verdict = OrbKernel.followupQueueStep(
                    op = 3,
                    serverRev = serverRev.toInt(),
                    incomingServerRev = 0,
                    expectedServerRev = 0,
                    clientMsgId = rowHash,
                    trackedMsgId = rowHash,
                    deliveredMsgId = delivHash,
                    postedAfterSeq = after,
                    turnSeq = m.sequence,
                    optimisticSending = row.sending,
                    serverListed = server.any { it.id == row.id },
                    contentMatched = matched,
                    alreadyDelivered = row.id in nextDelivered
                )
                if (verdict.retiredNow) {
                    used.add(m.sequence)
                    nextDelivered.add(row.id)
                    break
                }
            }
        }
        return copy(delivered = nextDelivered, consumedSequences = used)
    }

    /** Optimistic send while a turn runs: the row appears at once with a spinner. */
    fun enqueue(id: String, content: String, lastSequence: Long? = null): OrbFollowUpQueue {
        val rowHash = hashMessageId(id)
        val trackedHash = if (pending.any { it.id == id } || server.any { it.id == id }) rowHash else 0L
        val verdict = OrbKernel.followupQueueStep(
            op = 2,
            serverRev = serverRev.toInt(),
            incomingServerRev = 0,
            expectedServerRev = 0,
            clientMsgId = rowHash,
            trackedMsgId = trackedHash,
            deliveredMsgId = 0L,
            postedAfterSeq = seqWord(lastSequence),
            turnSeq = 0L,
            optimisticSending = true,
            serverListed = server.any { it.id == id },
            contentMatched = false,
            alreadyDelivered = id in delivered
        )
        if (!verdict.admitted) return this
        return copy(
            serverRev = verdict.nextServerRev.toLong() and 0xFFFF_FFFFL,
            pending = pending.filterNot { it.id == id } + OrbQueuedRow(id, content, sending = true),
            seenAfter = if (lastSequence != null) seenAfter + (id to lastSequence) else seenAfter - id
        )
    }

    /** POST /api/control/message answered: queued (keep) or delivered (drop the row). */
    fun posted(id: String, queued: Boolean, atMs: Long = System.currentTimeMillis()): OrbFollowUpQueue =
        if (queued) copy(pending = pending.map { if (it.id == id) it.copy(sending = false, postedAtMs = atMs) else it })
        else copy(pending = pending.filterNot { it.id == id })

    fun postFailed(id: String): OrbFollowUpQueue = copy(pending = pending.filterNot { it.id == id })

    /** Edit in place: same id, same position, text changes now. */
    fun edit(id: String, content: String, expectedServerRev: Long? = null): OrbFollowUpQueue {
        if (id in delivered) return this
        val expected = (expectedServerRev ?: serverRev).coerceAtMost(0xFFFF_FFFFL)
        val rowHash = hashMessageId(id)
        val verdict = OrbKernel.followupQueueStep(
            op = 1,
            serverRev = serverRev.toInt(),
            incomingServerRev = 0,
            expectedServerRev = expected.toInt(),
            clientMsgId = rowHash,
            trackedMsgId = rowHash,
            deliveredMsgId = 0L,
            postedAfterSeq = 0L,
            turnSeq = 0L,
            optimisticSending = false,
            serverListed = server.any { it.id == id },
            contentMatched = false,
            alreadyDelivered = false
        )
        if (!verdict.admitted) return this
        return copy(edits = edits + (id to content))
    }

    /** PATCH confirmed: the server copy takes the new text. */
    fun editConfirmed(
        id: String,
        content: String,
        expectedServerRev: Long? = null,
        confirmedServerRev: Long? = null
    ): OrbFollowUpQueue {
        if (id in delivered) return this
        val expected = (expectedServerRev ?: serverRev).coerceAtMost(0xFFFF_FFFFL)
        val rowHash = hashMessageId(id)
        val verdict = OrbKernel.followupQueueStep(
            op = 1,
            serverRev = serverRev.toInt(),
            incomingServerRev = 0,
            expectedServerRev = expected.toInt(),
            clientMsgId = rowHash,
            trackedMsgId = rowHash,
            deliveredMsgId = 0L,
            postedAfterSeq = 0L,
            turnSeq = 0L,
            optimisticSending = false,
            serverListed = server.any { it.id == id },
            contentMatched = false,
            alreadyDelivered = false
        )
        if (!verdict.admitted) return this
        val steppedRev = verdict.nextServerRev.toLong() and 0xFFFF_FFFFL
        val normalizedConfirmed = confirmedServerRev?.takeIf { it > 0L }?.coerceAtMost(0xFFFF_FFFFL)
        val trackedRevision = hasServerRevision || expectedServerRev != null || normalizedConfirmed != null
        val appliedRevision = when {
            normalizedConfirmed != null -> maxOf(steppedRev, normalizedConfirmed)
            trackedRevision -> steppedRev
            else -> null
        }
        return copy(
            serverRev = appliedRevision ?: serverRev,
            hasServerRevision = hasServerRevision || appliedRevision != null,
            server = server.map {
                if (it.id == id) {
                    it.copy(content = content, revision = appliedRevision ?: it.revision)
                } else {
                    it
                }
            },
            pending = pending.map { if (it.id == id) it.copy(content = content) else it },
            edits = edits - id
        )
    }

    fun editReverted(id: String): OrbFollowUpQueue = copy(edits = edits - id)

    /** Remove or Send now: the row leaves at once. */
    fun hide(id: String): OrbFollowUpQueue = copy(hidden = hidden + id)

    fun unhide(id: String): OrbFollowUpQueue = copy(hidden = hidden - id)

    fun row(id: String): OrbQueuedRow? = rows.firstOrNull { it.id == id }

    data class ParsedQueueResponse(val rows: List<OrbQueuedRow>, val revision: Long?)

    companion object {
        fun hashMessageId(id: String?): Long {
            if (id.isNullOrEmpty()) return 0L
            var hash = -3750763034362895579L
            for (byte in id.encodeToByteArray()) {
                hash = (hash xor (byte.toLong() and 0xFFL)) * 1099511628211L
            }
            return if (hash == 0L) 1L else hash
        }

        private fun seqWord(value: Long?): Long = if (value == null || value < 0L) 0L else value

        private fun parseUInt32Revision(value: Any?): Long? {
            val num = when (value) {
                is Number -> value.toDouble()
                is String -> value.trim().toDoubleOrNull()
                else -> null
            } ?: return null
            if (!num.isFinite()) return null
            val truncated = num.toLong()
            if (truncated <= 0L) return null
            return truncated.coerceAtMost(0xFFFF_FFFFL)
        }

        /** Rows from `GET /api/control/queue` for [missionId] that belong in the follow-up queue. */
        fun parse(items: List<OrbDict>, missionId: String): List<OrbQueuedRow> = items.mapNotNull { item ->
            val id = OrbJSON.str(item, "id") ?: return@mapNotNull null
            val content = OrbJSON.rawStr(item, "content") ?: return@mapNotNull null
            if (OrbJSON.str(item, "mission_id") != missionId) return@mapNotNull null
            if (item["inflight"] == true) return@mapNotNull null
            val source = OrbJSON.str(item, "source")
            if (source != null && source != "remote-queue" && !source.startsWith("host-queue:api:")) return@mapNotNull null
            OrbQueuedRow(
                id = id,
                content = content,
                queueError = OrbJSON.str(item, "queue_error"),
                revision = parseUInt32Revision(item["revision"])
            )
        }

        /** Parses either a raw `[...]` queue list or `{ items: [...], revision: N }` envelope. */
        fun parseResponse(raw: Any?, missionId: String, missionScoped: Boolean = true): ParsedQueueResponse {
            val items: List<OrbDict>
            val envelopeRev: Long?
            when (raw) {
                is List<*> -> {
                    items = OrbJSON.dictList(raw)
                    envelopeRev = null
                }
                else -> {
                    val dict = OrbJSON.dict(raw) ?: return ParsedQueueResponse(emptyList(), null)
                    items = OrbJSON.dictList(dict["items"])
                    envelopeRev = if (missionScoped) parseUInt32Revision(dict["revision"]) else null
                }
            }
            var maxRev = envelopeRev
            for (item in items) {
                if (OrbJSON.str(item, "mission_id") == missionId) {
                    val r = parseUInt32Revision(item["revision"])
                    if (r != null && (maxRev == null || r > maxRev)) {
                        maxRev = r
                    }
                }
            }
            return ParsedQueueResponse(parse(items, missionId), maxRev)
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

data class OrbSkillChoice(
    val name: String,
    val description: String? = null
)

data class OrbSkillToken(
    val name: String,
    val start: Int,
    val end: Int
)

data class OrbSkillQuery(
    val open: Boolean,
    val query: String,
    val start: Int
)

/** `/skill:<name>` composer contract (`orb/src/skillSlash.ts`). Admission goes through `OrbKernel.skillSlashStep`. */
object OrbSkillSlash {
    const val MAX_SKILL_NAME = 64
    const val MAX_SELECTED_SKILLS = 8
    private val TOKEN = Regex("(^|[\\s])/skill:([^\\s]*)")
    private val QUERY = Regex("(^|[\\s])/([^\\s]*)$")
    private val COLLAPSE_SPACES = Regex("[^\\S\\n]{2,}")
    private val TRIM_LINE_SPACES = Regex("^[^\\S\\n]+|[^\\S\\n]+$")

    fun skillToken(name: String): String = "/skill:$name"

    fun isValidSkillIdentifier(name: String): Boolean {
        if (name.isEmpty() || name.contains("..")) return false
        for (ch in name) {
            val c = ch.code
            val ok = (c in 48..57) || (c in 65..90) || (c in 97..122) || c == 45 || c == 95 || c == 46
            if (!ok) return false
        }
        return true
    }

    fun skillTokens(text: String): List<OrbSkillToken> =
        TOKEN.findAll(text).map { match ->
            val leadLen = match.groups[1]?.value?.length ?: 0
            val start = match.range.first + leadLen
            val name = match.groups[2]?.value.orEmpty()
            OrbSkillToken(name = name, start = start, end = match.range.last + 1)
        }.toList()

    fun skillQuery(text: String, caret: Int): OrbSkillQuery {
        val end = caret.coerceIn(0, text.length)
        val before = text.substring(0, end)
        val match = QUERY.find(before) ?: return OrbSkillQuery(open = false, query = "", start = -1)
        val raw = match.groups[2]?.value.orEmpty()
        if (raw.contains("/") || raw.startsWith("skill:")) return OrbSkillQuery(open = false, query = "", start = -1)
        val start = before.length - raw.length - 1
        return OrbSkillQuery(open = true, query = raw.lowercase(), start = start)
    }

    fun filterSkills(skills: List<OrbSkillChoice>, query: String, selected: List<String>): List<OrbSkillChoice> {
        val used = selected.toHashSet()
        return skills.filter { skill ->
            skill.name !in used &&
                (query.isEmpty() ||
                    skill.name.lowercase().contains(query) ||
                    (skill.description ?: "").lowercase().contains(query))
        }.take(50)
    }

    fun insertSkill(text: String, caret: Int, name: String): Pair<String, Int> {
        val clamped = caret.coerceIn(0, text.length)
        val query = skillQuery(text, clamped)
        val start = if (query.open && query.start >= 0) query.start else clamped
        val token = "${skillToken(name)} "
        return "${text.substring(0, start)}$token${text.substring(clamped)}" to (start + token.length)
    }

    fun removeSkill(text: String, name: String): String {
        val token = skillTokens(text).firstOrNull { it.name == name } ?: return text
        val next = "${text.substring(0, token.start)}${text.substring(token.end)}"
        return next.replace(COLLAPSE_SPACES, " ").replace(TRIM_LINE_SPACES, "")
    }

    fun selectedSkillNames(text: String, available: Set<String>): List<String> {
        val names = ArrayList<String>()
        for (token in skillTokens(text)) {
            if (token.name in available && token.name !in names) names.add(token.name)
        }
        return names
    }

    fun harnessKind(harness: String?): Int = when (harness) {
        "opencode" -> 1
        "claudecode" -> 2
        else -> 0
    }

    fun validateSkillSelection(text: String, harness: String?, available: Set<String>): String? {
        val kind = harnessKind(harness)
        val selected = ArrayList<String>()
        for (token in skillTokens(text)) {
            if (token.name in selected) continue
            val verdict = OrbKernel.skillSlashStep(
                harnessKind = kind,
                isDelivered = token.name in available,
                alreadySelected = false,
                nameCharsValid = isValidSkillIdentifier(token.name),
                nameLen = token.name.length,
                maxNameLen = MAX_SKILL_NAME,
                selectedCount = selected.size,
                maxSelected = MAX_SELECTED_SKILLS
            )
            if (!verdict.admitted) {
                if (verdict.rejectCode == 1 || verdict.rejectCode == 2) {
                    return "Invalid /skill: identifier (use at most 64 ASCII letters, numbers, '.', '_' or '-', without '..')"
                }
                if (verdict.rejectCode == 3) {
                    return "Selected skill is not delivered to this mission: ${token.name}"
                }
                if (verdict.rejectCode == 5) {
                    return "Select at most 8 distinct skills"
                }
                return "Skill selection rejected"
            }
            selected.add(token.name)
        }
        return null
    }

    fun skillDisplayText(text: String, available: Set<String>): String {
        var current = text
        for (token in skillTokens(text).asReversed()) {
            if (token.name in available && token.end <= current.length) {
                current = "${current.substring(0, token.start)}/${token.name}${current.substring(token.end)}"
            }
        }
        return current
    }

    fun skillPreview(text: String): String =
        skillDisplayText(text, skillTokens(text).mapTo(LinkedHashSet()) { it.name })

    suspend fun loadDelivery(core: OrbCore, project: String, workspaceId: String? = null): Pair<List<OrbSkillChoice>, String?> {
        val parts = ArrayList<String>(2)
        if (!workspaceId.isNullOrBlank()) parts.add("workspace_id=${core.encodeComponent(workspaceId)}")
        if (project.isNotBlank()) parts.add("project=${core.encodeComponent(project)}")
        if (parts.isEmpty()) return emptyList<OrbSkillChoice>() to null
        return try {
            val raw = core.fetchDict("/api/library/skill-delivery?${parts.joinToString("&")}")
            val skills = OrbJSON.dictList(raw["skills"]).mapNotNull { row ->
                val name = OrbJSON.str(row, "name")?.trim()?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                val desc = OrbJSON.str(row, "description")?.trim()?.takeIf { it.isNotEmpty() }
                OrbSkillChoice(name = name, description = desc)
            }
            skills to null
        } catch (e: OrbError) {
            if (e.status == 404) emptyList<OrbSkillChoice>() to null
            else emptyList<OrbSkillChoice>() to e.message
        } catch (e: Throwable) {
            emptyList<OrbSkillChoice>() to (e.message ?: "Couldn't load delivered skills")
        }
    }
}
