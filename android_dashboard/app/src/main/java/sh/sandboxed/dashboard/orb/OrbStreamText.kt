package sh.sandboxed.dashboard.orb

import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Streaming reply text, specified by lean/Orb/Stream.lean (checked against
 * shared/orb-spec/fixtures/stream-commit.json in OrbStreamTextTest). iOS: OrbStreamText.swift.
 *
 * A reply arrives as thousands of 4-character deltas. [OrbLiveText] turns them into one
 * state change per display frame; [OrbStreamCommit] finds the committed Markdown prefix so
 * [OrbStreamBlocks] only re-parses the open tail of a growing reply.
 */

/**
 * Pure reducer for the active turn's live intermediate text (`text_op` and `text_delta`),
 * shared with `OrbTurnText` in `OrbStreamText.swift` and desktop `TranscriptReducer`.
 */
class OrbTurnText {
    data class Bubble(
        val id: String,
        var text: String,
        var scalarCount: Int = text.codePointCount(0, text.length),
        var revision: Int = -1,
        var finalized: Boolean = false
    )

    data class StoredRow(
        val sequence: Long,
        val eventType: String,
        val content: String,
        val bubbleId: String?,
        val queued: Boolean,
        val success: Boolean,
        val partial: Boolean
    )

    val bubbles = mutableListOf<Bubble>()
    val storedCanonicalIds = mutableSetOf<String>()
    var lastUserSequence: Long = -1L
        private set
    var streamEpoch: Int = 0
        private set

    val renderedText: String
        get() = bubbles
            .filter { it.id !in storedCanonicalIds && it.text.isNotEmpty() }
            .joinToString("\n\n") { it.text }

    fun clear() {
        bubbles.clear()
        storedCanonicalIds.clear()
        lastUserSequence = -1L
    }

    fun resetTurn(userSequence: Long = -1L) {
        bubbles.clear()
        storedCanonicalIds.clear()
        if (userSequence >= 0L) lastUserSequence = userSequence
    }

    fun applyTextDelta(data: OrbDict) {
        streamEpoch++
        val bubbleId = nonEmptyString(data["bubble_id"]) ?: "text_delta_latest"
        val delta = data["delta"] as? String
        val mode = data["mode"] as? String
        val contentOrText = (data["content"] as? String) ?: (data["text"] as? String)
        when {
            delta != null -> appendBubble(bubbleId, delta)
            mode == "delta" && contentOrText != null -> appendBubble(bubbleId, contentOrText)
            contentOrText != null -> setBubble(bubbleId, contentOrText)
        }
    }

    fun applyTextOp(data: OrbDict) {
        streamEpoch++
        val bubbleId = nonEmptyString(data["bubble_id"]) ?: "text_delta_latest"
        if (bubbleId != "text_delta_latest" && bubbleId in storedCanonicalIds) return
        val ops = OrbJSON.dictList(data["ops"])
        if (ops.isNotEmpty()) {
            applyOps(bubbleId, ops)
            return
        }
        val op = data["op"] as? String
        if (op != null) {
            val content = data["content"] as? String ?: ""
            when (op) {
                "append" -> appendBubble(bubbleId, content)
                "replace" -> setBubble(bubbleId, content)
            }
        }
    }

    fun reconcileStored(rows: List<StoredRow>, working: Boolean, streamAdvanced: Boolean = false) {
        if (!working) {
            clear()
            return
        }
        val ordered = rows.sortedBy { it.sequence }
        val lastUserIdx = ordered.indexOfLast { it.eventType == "user_message" && !it.queued }
        val lastUserSeq = if (lastUserIdx >= 0) ordered[lastUserIdx].sequence else 0L
        if (lastUserSequence >= 0L && lastUserSeq > lastUserSequence) {
            bubbles.clear()
            storedCanonicalIds.clear()
        }
        if (lastUserSeq > 0L || lastUserSequence < 0L) {
            lastUserSequence = maxOf(lastUserSequence, lastUserSeq)
        }

        var turnEnded = false
        var storedDelta: String? = null
        val storedOpsOrder = mutableListOf<String>()
        val storedOpsByBubble = mutableMapOf<String, MutableList<OrbDict>>()
        val canonicalIds = mutableSetOf<String>()

        for (row in ordered.subList(lastUserIdx + 1, ordered.size)) {
            when (row.eventType) {
                "text_delta" -> {
                    storedDelta = row.content
                    turnEnded = false
                }
                "text_op" -> {
                    val bid = row.bubbleId ?: "text_delta_latest"
                    val ops = parseOpsJson(row.content)
                    if (ops.isNotEmpty()) {
                        if (bid !in storedOpsByBubble) storedOpsOrder.add(bid)
                        storedOpsByBubble.getOrPut(bid) { mutableListOf() }.addAll(ops)
                    }
                    turnEnded = false
                }
                "assistant_message_canonical" -> {
                    val bid = row.bubbleId ?: "text_delta_latest"
                    canonicalIds.add(bid)
                    storedOpsByBubble.remove(bid)
                }
                "assistant_message" -> {
                    if (!row.partial && row.success) {
                        storedDelta = null
                        storedOpsByBubble.clear()
                        storedOpsOrder.clear()
                        turnEnded = true
                    }
                }
            }
        }

        storedCanonicalIds.clear()
        storedCanonicalIds.addAll(canonicalIds)
        bubbles.removeAll { it.id in canonicalIds && it.id != "text_delta_latest" }
        if (turnEnded) {
            bubbles.clear()
            return
        }

        if (!storedDelta.isNullOrEmpty()) {
            val current = bubbles.firstOrNull { it.id == "text_delta_latest" }?.text ?: ""
            when {
                current.isEmpty() -> setBubble("text_delta_latest", storedDelta)
                current.startsWith(storedDelta) -> Unit // Live SSE stream is already ahead.
                storedDelta.startsWith(current) || !streamAdvanced -> setBubble("text_delta_latest", storedDelta)
            }
        }

        for (bid in storedOpsOrder) {
            if (bid !in canonicalIds && bubbles.none { it.id == bid }) {
                val ops = storedOpsByBubble[bid]
                if (!ops.isNullOrEmpty()) applyOps(bid, ops)
            }
        }
    }

    fun applyOps(bubbleId: String, ops: List<OrbDict>) {
        val existing = bubbles.firstOrNull { it.id == bubbleId }
        val bubble = existing?.copy() ?: Bubble(id = bubbleId, text = "")
        for (op in ops) {
            when (op["type"] as? String ?: "") {
                "snapshot" -> {
                    val rev = intValue(op["revision"]) ?: return
                    if (rev <= bubble.revision) return
                    bubble.revision = rev
                    val piece = op["text"] as? String ?: ""
                    bubble.text = piece
                    bubble.scalarCount = piece.codePointCount(0, piece.length)
                    bubble.finalized = false
                }
                "insert" -> {
                    val piece = op["text"] as? String ?: ""
                    val pos = intValue(op["pos"])
                    when {
                        bubbleId == "text_delta_latest" && pos == 0 -> {
                            bubble.text = piece
                            bubble.scalarCount = piece.codePointCount(0, piece.length)
                        }
                        pos == null || pos >= bubble.scalarCount -> {
                            bubble.text += piece
                            bubble.scalarCount += piece.codePointCount(0, piece.length)
                        }
                        else -> {
                            bubble.text = spliceScalars(bubble.text, pos, pos, piece)
                            bubble.scalarCount = bubble.text.codePointCount(0, bubble.text.length)
                        }
                    }
                    bubble.finalized = false
                }
                "replace" -> {
                    val piece = op["text"] as? String ?: ""
                    val range = intList(op["range"])
                    bubble.text = when {
                        bubbleId == "text_delta_latest" && (range?.firstOrNull() ?: 0) == 0 -> piece
                        range != null && range.size >= 2 -> spliceScalars(bubble.text, range[0], range[1], piece)
                        else -> piece
                    }
                    bubble.scalarCount = bubble.text.codePointCount(0, bubble.text.length)
                    bubble.finalized = false
                }
                "finalize" -> bubble.finalized = true
            }
        }
        upsertBubble(bubble)
    }

    private fun appendBubble(id: String, delta: String) {
        if (delta.isEmpty()) return
        val existing = bubbles.firstOrNull { it.id == id }
        val deltaScalars = delta.codePointCount(0, delta.length)
        val bubble = existing?.copy(
            text = existing.text + delta,
            scalarCount = existing.scalarCount + deltaScalars,
            finalized = false
        ) ?: Bubble(id = id, text = delta, scalarCount = deltaScalars)
        upsertBubble(bubble)
    }

    private fun setBubble(id: String, text: String) {
        val existing = bubbles.firstOrNull { it.id == id }
        val scalars = text.codePointCount(0, text.length)
        val bubble = existing?.copy(text = text, scalarCount = scalars, finalized = false)
            ?: Bubble(id = id, text = text, scalarCount = scalars)
        upsertBubble(bubble)
    }

    private fun upsertBubble(bubble: Bubble) {
        val idx = bubbles.indexOfFirst { it.id == bubble.id }
        if (idx >= 0) {
            if (bubble.text.isEmpty() && !bubble.finalized) bubbles.removeAt(idx)
            else bubbles[idx] = bubble
        } else if (bubble.text.isNotEmpty() || bubble.finalized) {
            bubbles.add(bubble)
        }
    }

    companion object {
        fun rows(events: List<OrbRow>): List<StoredRow> = events.mapIndexed { idx, ev ->
            val data = ev.dict("data") ?: ev.raw
            val meta = ev.dict("metadata") ?: OrbJSON.dict(data["metadata"]) ?: emptyMap()
            val bid = nonEmptyString(meta["bubble_id"])
                ?: nonEmptyString(data["bubble_id"])
                ?: nonEmptyString(ev.raw["event_id"])
                ?: nonEmptyString(data["event_id"])
            val seq = (ev.raw["sequence"] as? Number)?.toLong()
                ?: (ev.raw["seq"] as? Number)?.toLong()
                ?: ev.int("sequence", "seq")?.toLong()
                ?: idx.toLong()
            val type = (ev.str("event_type", "type", "kind") ?: "").lowercase()
            val content = (ev.raw["content"] as? String)
                ?: (data["content"] as? String)
                ?: (data["text"] as? String)
                ?: ""
            val queued = OrbJSON.bool(meta, "queued") == true
            val success = OrbJSON.bool(meta, "success") != false && OrbJSON.bool(data, "success") != false
            val partial = OrbJSON.bool(meta, "partial") == true || OrbJSON.str(meta, "turn_end") == "partial"
            StoredRow(seq, type, content, bid, queued, success, partial)
        }

        fun fromStoredEvents(events: List<OrbRow>, working: Boolean): String {
            val turn = OrbTurnText()
            turn.reconcileStored(rows(events), working = working)
            return turn.renderedText
        }

        fun spliceScalars(text: String, start: Int?, end: Int?, replacement: String): String {
            if (start == null) return text + replacement
            val targetEnd = end ?: start
            if (start >= text.length && targetEnd >= text.length) return text + replacement
            val cps = text.codePoints().toArray()
            val s = start.coerceIn(0, cps.size)
            val e = targetEnd.coerceIn(s, cps.size)
            if (s == cps.size && e == cps.size) return text + replacement
            val prefix = if (s > 0) String(cps, 0, s) else ""
            val suffix = if (e < cps.size) String(cps, e, cps.size - e) else ""
            return prefix + replacement + suffix
        }

        private fun nonEmptyString(raw: Any?): String? = (raw as? String)?.takeIf { it.isNotEmpty() }

        private fun intValue(raw: Any?): Int? = when (raw) {
            is Int -> raw
            is Long -> raw.toInt()
            is Double -> if (raw.isFinite()) raw.toInt() else null
            is Number -> raw.toInt()
            is String -> raw.trim().toIntOrNull()
            else -> null
        }

        private fun intList(raw: Any?): List<Int>? {
            val list = raw as? List<*> ?: return null
            val out = list.mapNotNull { intValue(it) }
            return if (out.size == list.size) out else null
        }

        private fun parseOpsJson(content: String): List<OrbDict> =
            if (content.isEmpty()) emptyList() else OrbJSON.dictList(OrbJSON.parse(content))
    }
}

/** `Orb.Stream.Coalescer`: deltas collect in `pending`; a frame moves them to [text]. */
class OrbLiveText(
    private val scope: CoroutineScope,
    private val frameMs: Long = 16,
    private val frameDispatcher: CoroutineDispatcher = Dispatchers.Main
) {
    /** What the streaming bubble shows. */
    var text by mutableStateOf("")
        private set

    /** Whether there is any text: read by the screen, changes on the first delta and on clear. */
    val hasText by derivedStateOf { text.isNotEmpty() }
    private val pending = StringBuilder()
    private var flushJob: Job? = null
    private val turn = OrbTurnText()

    /** Frames that changed [text] (the coalescer's render count). */
    var renders = 0
        private set

    /** Everything received, shown or not (the conservation law: `text + pending`). */
    val received: String
        get() = synchronized(pending) { text + pending.toString() }

    /** Monotonic counter incremented on every live SSE/WS delta or op. */
    val streamEpoch: Int get() = synchronized(pending) { turn.streamEpoch }

    /** Safe from any thread (the SSE reader): one Main dispatch per frame, not per delta. */
    fun append(delta: String) {
        if (delta.isEmpty()) return
        synchronized(pending) {
            turn.applyTextDelta(mapOf("delta" to delta))
            appendCoalescedLocked(delta)
        }
    }

    fun replace(content: String) {
        synchronized(pending) {
            if (content.isEmpty()) turn.clear()
            else turn.applyTextDelta(mapOf("content" to content))
            replaceImmediateLocked(content)
        }
    }

    fun resetTurn(userSequence: Long = -1L) {
        synchronized(pending) {
            turn.resetTurn(userSequence)
            replaceImmediateLocked("")
        }
    }

    fun applyTextDelta(data: OrbDict) {
        synchronized(pending) {
            turn.applyTextDelta(data)
            syncWithTurnLocked(immediate = false)
        }
    }

    fun applyTextOp(data: OrbDict) {
        synchronized(pending) {
            turn.applyTextOp(data)
            syncWithTurnLocked(immediate = false)
        }
    }

    fun reconcileStored(events: List<OrbRow>, working: Boolean, streamAdvanced: Boolean = false) {
        synchronized(pending) {
            val wasEmpty = text.isEmpty() && pending.isEmpty()
            turn.reconcileStored(OrbTurnText.rows(events), working = working, streamAdvanced = streamAdvanced)
            syncWithTurnLocked(immediate = wasEmpty)
        }
    }

    /** Moves pending text to [text] now (one render). */
    fun flush() {
        synchronized(pending) {
            flushJob?.cancel()
            flushJob = null
            if (pending.isEmpty()) return
            text += pending.toString()
            pending.setLength(0)
            renders++
        }
    }

    fun clear() {
        synchronized(pending) {
            turn.clear()
            replaceImmediateLocked("")
        }
    }

    private fun syncWithTurnLocked(immediate: Boolean) {
        val next = turn.renderedText
        val current = text + pending.toString()
        if (next == current) return
        if (next.isEmpty()) {
            replaceImmediateLocked("")
            return
        }
        if (!immediate && next.startsWith(current)) {
            appendCoalescedLocked(next.substring(current.length))
        } else {
            replaceImmediateLocked(next)
        }
    }

    private fun appendCoalescedLocked(delta: String) {
        if (delta.isEmpty()) return
        pending.append(delta)
        if (flushJob != null) return
        flushJob = scope.launch(frameDispatcher) {
            delay(frameMs)
            flush()
        }
    }

    private fun replaceImmediateLocked(content: String) {
        flushJob?.cancel()
        flushJob = null
        pending.setLength(0)
        if (text != content) {
            text = content
        }
    }
}

/**
 * `Orb.Stream.Scan`: the committed Markdown prefix ends after the last blank line outside
 * every code fence (the block parser's backtick toggle and the pipe-table fence marker).
 * [parseMdBlocks] starts fresh there, so blocks before it are final.
 */
data class OrbStreamCommit(val tick: Boolean = false, val fence: Marker? = null, val pos: Int = 0, val commit: Int = 0) {
    data class Line(val blank: Boolean, val tick: Boolean, val marker: Marker?)
    data class Marker(val backtick: Boolean, val count: Int)

    fun scan(line: Line): OrbStreamCommit {
        val openKind = fence?.let { if (it.backtick) 1 else 2 } ?: 0
        val openCount = fence?.count ?: 0
        val markerKind = line.marker?.let { if (it.backtick) 1 else 2 } ?: 0
        val markerCount = line.marker?.count ?: 0
        val res = OrbKernel.streamCommitStep(
            tick = tick,
            openKind = openKind,
            openCount = openCount,
            lineBlank = line.blank,
            lineTick = line.tick,
            markerKind = markerKind,
            markerCount = markerCount,
            pos = pos,
            commit = commit
        )
        val nextFence = if (res.openKind == 0) null else Marker(res.openKind == 1, res.openCount)
        return OrbStreamCommit(res.tick, nextFence, res.pos, res.commit)
    }

    companion object {
        fun classify(raw: String, inFence: Boolean = false): Line {
            val rest = raw.trimStart(' ', '\t')
            val c = rest.firstOrNull()
            val marker = if (c == '`' || c == '~') rest.takeWhile { it == c }.length.takeIf { it >= 3 }?.let { Marker(c == '`', it) } else null
            // The parser's own trimming decides blank and fence lines.
            val trimmed = raw.trim()
            if (!inFence && !trimmed.startsWith("```") && OrbCodeFences.splitGlued(raw) != null) {
                return Line(blank = false, tick = true, marker = Marker(backtick = true, count = 3))
            }
            return Line(trimmed.isEmpty(), trimmed.startsWith("```"), marker)
        }

        fun nextFence(open: Marker?, m: Marker?): Marker? {
            val openKind = open?.let { if (it.backtick) 1 else 2 } ?: 0
            val openCount = open?.count ?: 0
            val markerKind = m?.let { if (it.backtick) 1 else 2 } ?: 0
            val markerCount = m?.count ?: 0
            val (kind, count) = OrbKernel.streamFenceStep(openKind, openCount, markerKind, markerCount)
            return if (kind == 0) null else Marker(kind == 1, count)
        }

        /**
         * Length of the committed prefix of [text]: after the newline of the last committing
         * line. The last line is still growing, so only newline-terminated lines can commit.
         */
        fun committedLength(text: CharSequence): Int {
            var state = OrbStreamCommit()
            var committed = 0
            var start = 0
            while (true) {
                val end = text.indexOf('\n', start).takeIf { it >= 0 } ?: return committed
                val before = state.commit
                state = state.scan(classify(text.substring(start, end), inFence = state.tick))
                if (state.commit != before) committed = end + 1
                start = end + 1
            }
        }

        private fun CharSequence.indexOf(ch: Char, from: Int): Int {
            for (i in from until length) if (this[i] == ch) return i
            return -1
        }
    }
}

/** [parseMdBlocks] for text that grows by appending: the committed prefix is parsed once. */
internal class OrbStreamBlocks(
    val maxOpenTailBytes: Int = DEFAULT_MAX_OPEN_TAIL_BYTES
) {
    private val effectiveMaxOpenTailBytes = maxOpenTailBytes.coerceAtLeast(1)
    private var previous = ""
    private var prevUtf8 = 0
    private var commitOffset = 0
    private var commitUtf8 = 0
    private var scanCursor = 0
    private var scanUtf8 = 0
    private var checkpointUtf8 = 0
    private var scanState = OrbStreamCommit()
    private var prefixBlocks: List<OrbMdBlock> = emptyList()

    var openFenceCapped = false
        private set

    private var openFenceStart = -1
    private var openFenceBodyStart = 0
    private var openFenceBodyCursor = 0
    private var openFenceLang = ""
    private var openFencePrefixBlocks: List<OrbMdBlock>? = null
    private val openFenceAcc = StringBuilder()
    private var openFenceHasLines = false

    private var capCursorOffset = 0
    private var capCursorUtf8 = 0
    private var capInTildeFence = false
    private var capTildeCount = 0
    private var capPrefixBlocks: MutableList<OrbMdBlock>? = null
    private val capParaAcc = StringBuilder()
    private var capParaHasLines = false
    private var capOpenKind = CAP_OPEN_NONE
    private var capOpenCodeLang = ""
    private val capOpenCodeAcc = StringBuilder()
    private var capOpenCodeHasLines = false
    private var capOpenMathDelim = ""
    private val capOpenMathAcc = StringBuilder()
    private var capOpenMathHasLines = false
    private val capOpenQuoteAcc = StringBuilder()
    private val capOpenListItems = mutableListOf<String>()
    private val capOpenTableRows = mutableListOf<List<String>>()

    /** UTF-8 bytes scanned by the checkpointed commit scanner (`Orb.Stream.CheckpointedScan`). */
    var scannedBytes = 0
        private set

    /** UTF-8 bytes handed to [parseMdBlocks] so far (Lean `incCost`; checked against stream-cost.json). */
    var parsedBytes = 0
        private set

    private fun resetOpenFence() {
        openFenceStart = -1
        openFencePrefixBlocks = null
        openFenceAcc.setLength(0)
        openFenceHasLines = false
    }

    private fun clearCapOpenBlock() {
        capOpenKind = CAP_OPEN_NONE
        capOpenCodeLang = ""
        capOpenCodeAcc.setLength(0)
        capOpenCodeHasLines = false
        capOpenMathDelim = ""
        capOpenMathAcc.setLength(0)
        capOpenMathHasLines = false
        capOpenQuoteAcc.setLength(0)
        capOpenListItems.clear()
        capOpenTableRows.clear()
    }

    private fun resetCapState() {
        capCursorOffset = commitOffset
        capCursorUtf8 = commitUtf8
        capInTildeFence = false
        capTildeCount = 0
        capPrefixBlocks = null
        capParaAcc.setLength(0)
        capParaHasLines = false
        clearCapOpenBlock()
    }

    fun blocks(source: String): List<OrbMdBlock> {
        if (!source.startsWith(previous)) {
            prevUtf8 = 0
            commitOffset = 0
            commitUtf8 = 0
            scanCursor = 0
            scanUtf8 = 0
            checkpointUtf8 = 0
            openFenceCapped = false
            scanState = OrbStreamCommit()
            prefixBlocks = emptyList()
            resetOpenFence()
            resetCapState()
        }
        val priorLen = prevUtf8
        val priorCommit = commitUtf8
        val priorCheckpoint = checkpointUtf8.coerceIn(priorCommit, priorLen)
        previous = source

        var newCommitOffset = commitOffset
        var newCommitUtf8 = commitUtf8
        while (true) {
            val nl = source.indexOf('\n', scanCursor)
            if (nl == -1) break
            val line = source.substring(scanCursor, nl)
            val lineStart = scanCursor
            val lineBytes = utf8Length(line) + 1
            scanCursor = nl + 1
            scanUtf8 += lineBytes
            scannedBytes += lineBytes

            val wasTick = scanState.tick
            val glued = if (wasTick) null else OrbCodeFences.splitGlued(line)
            val beforeCommit = scanState.commit
            scanState = if (glued != null) {
                scanState.scan(OrbStreamCommit.Line(blank = false, tick = true, marker = OrbStreamCommit.Marker(backtick = true, count = 3)))
            } else {
                scanState.scan(OrbStreamCommit.classify(line, inFence = true))
            }
            if (scanState.commit != beforeCommit) {
                newCommitOffset = scanCursor
                newCommitUtf8 = scanUtf8
                resetOpenFence()
            } else if (!wasTick && scanState.tick) {
                if (glued != null) {
                    openFenceStart = lineStart + glued.offset
                    openFenceLang = glued.lang
                } else {
                    openFenceStart = lineStart
                    openFenceLang = line.trim().drop(3).trim()
                }
                openFenceBodyStart = scanCursor
                openFenceBodyCursor = scanCursor
                openFencePrefixBlocks = null
                openFenceAcc.setLength(0)
                openFenceHasLines = false
            } else if (wasTick && !scanState.tick) {
                resetOpenFence()
            }
        }

        val trailing = source.substring(scanCursor)
        val totalUtf8 = scanUtf8 + utf8Length(trailing)
        prevUtf8 = totalUtf8

        val openFenceActive = scanState.tick || scanState.fence != null
        val capVerdict = OrbKernel.streamOpenTailCapStep(
            prevLen = priorLen,
            prevCommit = priorCommit,
            prevCheckpoint = priorCheckpoint,
            newLen = totalUtf8,
            rawCommit = newCommitUtf8,
            maxOpenTailBytes = effectiveMaxOpenTailBytes,
            openFenceActive = openFenceActive
        )
        val boundedCheckpoint = if (capVerdict.admitted) {
            capVerdict.nextCheckpoint.coerceIn(newCommitUtf8.toLong(), totalUtf8.toLong()).toInt()
        } else {
            newCommitUtf8
        }
        checkpointUtf8 = boundedCheckpoint
        openFenceCapped = capVerdict.admitted && capVerdict.openFenceCapped

        val advanceChars = newCommitOffset - commitOffset
        val advanceUtf8 = newCommitUtf8 - commitUtf8
        if (advanceChars > 0) {
            val chunk = source.substring(commitOffset, newCommitOffset)
            prefixBlocks = prefixBlocks + parseMdBlocks(chunk)
            commitOffset = newCommitOffset
            commitUtf8 = newCommitUtf8
            resetCapState()
        }

        if (scanState.tick && openFenceStart >= commitOffset &&
            (scanCursor - openFenceBodyStart >= OPEN_FENCE_STREAM_THRESHOLD ||
                (capVerdict.admitted && capVerdict.checkpointForced))
        ) {
            if (!trailing.trim().startsWith("```")) {
                var deltaBytes = advanceUtf8
                var pre = openFencePrefixBlocks
                if (pre == null) {
                    if (capPrefixBlocks != null || capParaHasLines || capOpenKind != CAP_OPEN_NONE || capCursorOffset > commitOffset) {
                        val preBlocks = buildCapBlocksUpTo(source, openFenceStart) { deltaBytes += it }
                        pre = preBlocks
                        resetCapState()
                    } else {
                        val preSlice = source.substring(commitOffset, openFenceStart)
                        deltaBytes += utf8Length(preSlice)
                        pre = if (preSlice.isNotEmpty()) parseMdBlocks(preSlice) else emptyList()
                    }
                    openFencePrefixBlocks = pre
                }
                while (true) {
                    val nl = source.indexOf('\n', openFenceBodyCursor)
                    if (nl == -1) break
                    val rawLine = source.substring(openFenceBodyCursor, nl)
                    openFenceBodyCursor = nl + 1
                    deltaBytes += utf8Length(rawLine) + 1
                    if (openFenceHasLines) openFenceAcc.append('\n')
                    openFenceAcc.append(rawLine)
                    openFenceHasLines = true
                }
                val openCode = when {
                    openFenceBodyCursor == source.length && openFenceBodyCursor > openFenceBodyStart ->
                        openFenceAcc.toString() + "\n"
                    openFenceBodyCursor < source.length -> {
                        deltaBytes += utf8Length(trailing)
                        if (openFenceHasLines) openFenceAcc.toString() + "\n" + trailing else trailing
                    }
                    else -> ""
                }
                parsedBytes = OrbKernel.streamTokenCostStep(parsedBytes.toLong(), deltaBytes.toLong(), 0L).toInt()
                return prefixBlocks + pre + OrbMdBlock.CodeBlock(openFenceLang, openCode)
            }
        }

        if (!scanState.tick && capVerdict.admitted && capVerdict.checkpointForced) {
            var capDelta = 0
            fun ensureCapPrefix() {
                if (capPrefixBlocks != null) return
                val slice = source.substring(commitOffset, capCursorOffset)
                capDelta += utf8Length(slice)
                capPrefixBlocks = if (slice.isEmpty()) mutableListOf() else parseMdBlocks(slice).toMutableList()
                if (slice.isNotEmpty()) {
                    for (sLine in slice.split("\n")) {
                        updateTildeFence(sLine)
                    }
                }
            }
            fun flushCapPara() {
                if (!capParaHasLines) return
                ensureCapPrefix()
                capPrefixBlocks!!.add(OrbMdBlock.Paragraph(capParaAcc.toString()))
                capParaAcc.setLength(0)
                capParaHasLines = false
            }
            fun flushCapOpenBlock(mathClosed: Boolean = false) {
                when (capOpenKind) {
                    CAP_OPEN_CODE -> {
                        ensureCapPrefix()
                        capPrefixBlocks!!.add(OrbMdBlock.CodeBlock(capOpenCodeLang, capOpenCodeAcc.toString()))
                    }
                    CAP_OPEN_MATH -> {
                        ensureCapPrefix()
                        capPrefixBlocks!!.add(OrbMdBlock.MathBlock(capOpenMathAcc.toString().trim(), complete = mathClosed))
                    }
                    CAP_OPEN_QUOTE -> {
                        ensureCapPrefix()
                        capPrefixBlocks!!.add(OrbMdBlock.Quote(capOpenQuoteAcc.toString()))
                    }
                    CAP_OPEN_UNORDERED_LIST -> {
                        ensureCapPrefix()
                        capPrefixBlocks!!.add(OrbMdBlock.ListBlock(false, capOpenListItems.toList()))
                    }
                    CAP_OPEN_ORDERED_LIST -> {
                        ensureCapPrefix()
                        capPrefixBlocks!!.add(OrbMdBlock.ListBlock(true, capOpenListItems.toList()))
                    }
                    CAP_OPEN_TABLE -> {
                        ensureCapPrefix()
                        capPrefixBlocks!!.add(buildTableBlock(capOpenTableRows))
                    }
                }
                clearCapOpenBlock()
            }

            while (capCursorUtf8 < boundedCheckpoint) {
                val nl = source.indexOf('\n', capCursorOffset)
                if (nl == -1 || nl >= scanCursor) break
                val line = source.substring(capCursorOffset, nl)
                val lineBytes = utf8Length(line) + 1
                val trimmed = line.trim()

                if (capOpenKind != CAP_OPEN_NONE) {
                    when (capOpenKind) {
                        CAP_OPEN_CODE -> {
                            if (trimmed.startsWith("```")) {
                                flushCapOpenBlock()
                                capCursorOffset = nl + 1
                                capCursorUtf8 += lineBytes
                                continue
                            }
                            if (capOpenCodeHasLines) capOpenCodeAcc.append('\n')
                            capOpenCodeAcc.append(line)
                            capOpenCodeHasLines = true
                            capCursorOffset = nl + 1
                            capCursorUtf8 += lineBytes
                            continue
                        }
                        CAP_OPEN_MATH -> {
                            if (trimmed.isEmpty() || trimmed.startsWith("```")) {
                                flushCapOpenBlock(mathClosed = false)
                                continue
                            }
                            val gluedInMath = OrbCodeFences.splitGlued(line)
                            if (gluedInMath != null) {
                                val prose = line.substring(0, gluedInMath.offset)
                                val proseTrim = prose.trim()
                                val pClose = proseTrim.indexOf(capOpenMathDelim)
                                if (pClose >= 0) {
                                    val before = proseTrim.substring(0, pClose)
                                    if (before.isNotEmpty()) {
                                        if (capOpenMathHasLines) capOpenMathAcc.append('\n')
                                        capOpenMathAcc.append(before)
                                    }
                                    flushCapOpenBlock(mathClosed = true)
                                } else {
                                    if (capOpenMathHasLines) capOpenMathAcc.append('\n')
                                    capOpenMathAcc.append(prose)
                                    flushCapOpenBlock(mathClosed = false)
                                }
                                capOpenKind = CAP_OPEN_CODE
                                capOpenCodeLang = line.substring(gluedInMath.offset).trim().drop(3).trim()
                                capOpenCodeAcc.setLength(0)
                                capOpenCodeHasLines = false
                                capCursorOffset = nl + 1
                                capCursorUtf8 += lineBytes
                                continue
                            }
                            val closeIdx = trimmed.indexOf(capOpenMathDelim)
                            if (closeIdx >= 0) {
                                val before = trimmed.substring(0, closeIdx)
                                if (before.isNotEmpty()) {
                                    if (capOpenMathHasLines) capOpenMathAcc.append('\n')
                                    capOpenMathAcc.append(before)
                                    capOpenMathHasLines = true
                                }
                                flushCapOpenBlock(mathClosed = true)
                                capCursorOffset = nl + 1
                                capCursorUtf8 += lineBytes
                                continue
                            }
                            if (capOpenMathHasLines) capOpenMathAcc.append('\n')
                            capOpenMathAcc.append(line)
                            capOpenMathHasLines = true
                            capCursorOffset = nl + 1
                            capCursorUtf8 += lineBytes
                            continue
                        }
                        CAP_OPEN_QUOTE -> {
                            if (trimmed.startsWith("> ")) {
                                capOpenQuoteAcc.append('\n').append(trimmed.drop(2))
                                capCursorOffset = nl + 1
                                capCursorUtf8 += lineBytes
                                continue
                            }
                            if (trimmed == ">") {
                                capOpenQuoteAcc.append('\n')
                                capCursorOffset = nl + 1
                                capCursorUtf8 += lineBytes
                                continue
                            }
                            flushCapOpenBlock()
                            continue
                        }
                        CAP_OPEN_UNORDERED_LIST -> {
                            val gluedInList = OrbCodeFences.splitGlued(line)
                            if (gluedInList == null && (trimmed.startsWith("- ") || trimmed.startsWith("* "))) {
                                capOpenListItems.add(trimmed.drop(2))
                                capCursorOffset = nl + 1
                                capCursorUtf8 += lineBytes
                                continue
                            }
                            if (gluedInList != null) {
                                val prose = line.substring(0, gluedInList.offset)
                                val pt = prose.trim()
                                if (pt.startsWith("- ") || pt.startsWith("* ")) {
                                    capOpenListItems.add(pt.drop(2))
                                    flushCapOpenBlock()
                                    capOpenKind = CAP_OPEN_CODE
                                    capOpenCodeLang = line.substring(gluedInList.offset).trim().drop(3).trim()
                                    capOpenCodeAcc.setLength(0)
                                    capOpenCodeHasLines = false
                                    capCursorOffset = nl + 1
                                    capCursorUtf8 += lineBytes
                                    continue
                                }
                            }
                            flushCapOpenBlock()
                            continue
                        }
                        CAP_OPEN_ORDERED_LIST -> {
                            val gluedInOrd = OrbCodeFences.splitGlued(line)
                            if (gluedInOrd == null) {
                                val d = trimmed.indexOf(". ")
                                if (d in 1..3 && trimmed.substring(0, d).all { it.isDigit() }) {
                                    capOpenListItems.add(trimmed.substring(d + 2))
                                    capCursorOffset = nl + 1
                                    capCursorUtf8 += lineBytes
                                    continue
                                }
                            } else {
                                val pt = line.substring(0, gluedInOrd.offset).trim()
                                val d = pt.indexOf(". ")
                                if (d in 1..3 && pt.substring(0, d).all { it.isDigit() }) {
                                    capOpenListItems.add(pt.substring(d + 2))
                                    flushCapOpenBlock()
                                    capOpenKind = CAP_OPEN_CODE
                                    capOpenCodeLang = line.substring(gluedInOrd.offset).trim().drop(3).trim()
                                    capOpenCodeAcc.setLength(0)
                                    capOpenCodeHasLines = false
                                    capCursorOffset = nl + 1
                                    capCursorUtf8 += lineBytes
                                    continue
                                }
                            }
                            flushCapOpenBlock()
                            continue
                        }
                        CAP_OPEN_TABLE -> {
                            val gluedInTable = OrbCodeFences.splitGlued(line)
                            if (gluedInTable != null) {
                                val proseTrim = line.substring(0, gluedInTable.offset).trim()
                                if (isMdBlockTableRow(proseTrim)) {
                                    capOpenTableRows.add(parseCapTableCells(proseTrim))
                                    flushCapOpenBlock()
                                    capOpenKind = CAP_OPEN_CODE
                                    capOpenCodeLang = line.substring(gluedInTable.offset).trim().drop(3).trim()
                                    capOpenCodeAcc.setLength(0)
                                    capOpenCodeHasLines = false
                                    capCursorOffset = nl + 1
                                    capCursorUtf8 += lineBytes
                                    continue
                                }
                            } else if (isMdBlockTableRow(trimmed)) {
                                capOpenTableRows.add(parseCapTableCells(trimmed))
                                capCursorOffset = nl + 1
                                capCursorUtf8 += lineBytes
                                continue
                            }
                            flushCapOpenBlock()
                            continue
                        }
                    }
                }

                if (trimmed.isEmpty()) {
                    flushCapPara()
                    ensureCapPrefix()
                    capCursorOffset = nl + 1
                    capCursorUtf8 += lineBytes
                    continue
                }

                if (trimmed.startsWith("```")) {
                    flushCapPara()
                    ensureCapPrefix()
                    capOpenKind = CAP_OPEN_CODE
                    capOpenCodeLang = trimmed.drop(3).trim()
                    capOpenCodeAcc.setLength(0)
                    capOpenCodeHasLines = false
                    capCursorOffset = nl + 1
                    capCursorUtf8 += lineBytes
                    continue
                }

                val glued = OrbCodeFences.splitGlued(line)
                if (glued != null) {
                    val prose = line.substring(0, glued.offset)
                    val proseTrim = prose.trim()
                    val fenceLine = line.substring(glued.offset).trim()
                    ensureCapPrefix()
                    if (capParaHasLines && !breaksParagraph(proseTrim)) {
                        capParaAcc.append('\n').append(prose)
                        flushCapPara()
                    } else if (capParaHasLines && proseTrim.startsWith("#") && !isHeading(proseTrim)) {
                        flushCapPara()
                    } else {
                        flushCapPara()
                        capDelta += utf8Length(prose)
                        capPrefixBlocks!!.addAll(parseMdBlocks(prose))
                        updateTildeFence(prose)
                    }
                    capOpenKind = CAP_OPEN_CODE
                    capOpenCodeLang = fenceLine.drop(3).trim()
                    capOpenCodeAcc.setLength(0)
                    capOpenCodeHasLines = false
                    capCursorOffset = nl + 1
                    capCursorUtf8 += lineBytes
                    continue
                }

                if ((trimmed == "---" || trimmed == "***") && !capParaHasLines) {
                    ensureCapPrefix()
                    capPrefixBlocks!!.add(OrbMdBlock.Divider)
                    capCursorOffset = nl + 1
                    capCursorUtf8 += lineBytes
                    continue
                }

                if (trimmed.startsWith("#")) {
                    flushCapPara()
                    ensureCapPrefix()
                    if (isHeading(trimmed)) {
                        val hashes = trimmed.takeWhile { it == '#' }.length
                        capPrefixBlocks!!.add(OrbMdBlock.Heading(hashes, trimmed.drop(hashes + 1)))
                    }
                    capCursorOffset = nl + 1
                    capCursorUtf8 += lineBytes
                    continue
                }

                if (isMdBlockStandaloneImage(trimmed)) {
                    flushCapPara()
                    ensureCapPrefix()
                    capDelta += lineBytes
                    capPrefixBlocks!!.addAll(parseMdBlocks(line))
                    capCursorOffset = nl + 1
                    capCursorUtf8 += lineBytes
                    continue
                }

                if (isMdBlockDisplayMathStart(trimmed)) {
                    flushCapPara()
                    ensureCapPrefix()
                    val openDelim = if (trimmed.startsWith("$$")) "$$" else "\\["
                    val closeDelim = if (openDelim == "$$") "$$" else "\\]"
                    val afterOpen = trimmed.drop(openDelim.length)
                    if (afterOpen.contains(closeDelim)) {
                        capDelta += lineBytes
                        capPrefixBlocks!!.addAll(parseMdBlocks(line))
                        capCursorOffset = nl + 1
                        capCursorUtf8 += lineBytes
                        continue
                    }
                    capOpenKind = CAP_OPEN_MATH
                    capOpenMathDelim = closeDelim
                    capOpenMathAcc.setLength(0)
                    if (afterOpen.isNotEmpty()) {
                        capOpenMathAcc.append(afterOpen)
                        capOpenMathHasLines = true
                    } else {
                        capOpenMathHasLines = false
                    }
                    capCursorOffset = nl + 1
                    capCursorUtf8 += lineBytes
                    continue
                }

                if (isMdBlockTableRow(trimmed)) {
                    flushCapPara()
                    ensureCapPrefix()
                    capOpenKind = CAP_OPEN_TABLE
                    capOpenTableRows.clear()
                    capOpenTableRows.add(parseCapTableCells(trimmed))
                    capCursorOffset = nl + 1
                    capCursorUtf8 += lineBytes
                    continue
                }

                if (trimmed.startsWith("> ") || (trimmed == ">" && !capParaHasLines)) {
                    flushCapPara()
                    ensureCapPrefix()
                    capOpenKind = CAP_OPEN_QUOTE
                    capOpenQuoteAcc.setLength(0)
                    if (trimmed.startsWith("> ")) capOpenQuoteAcc.append(trimmed.drop(2))
                    capCursorOffset = nl + 1
                    capCursorUtf8 += lineBytes
                    continue
                }

                if (trimmed.startsWith("- ") || trimmed.startsWith("* ")) {
                    flushCapPara()
                    ensureCapPrefix()
                    capOpenKind = CAP_OPEN_UNORDERED_LIST
                    capOpenListItems.clear()
                    capOpenListItems.add(trimmed.drop(2))
                    capCursorOffset = nl + 1
                    capCursorUtf8 += lineBytes
                    continue
                }

                if (!capParaHasLines && isOrderedItem(trimmed)) {
                    ensureCapPrefix()
                    val dotIdx = trimmed.indexOf(". ")
                    capOpenKind = CAP_OPEN_ORDERED_LIST
                    capOpenListItems.clear()
                    capOpenListItems.add(trimmed.substring(dotIdx + 2))
                    capCursorOffset = nl + 1
                    capCursorUtf8 += lineBytes
                    continue
                }

                updateTildeFence(line)

                ensureCapPrefix()
                if (capParaHasLines) capParaAcc.append('\n')
                capParaAcc.append(line)
                capParaHasLines = true
                capCursorOffset = nl + 1
                capCursorUtf8 += lineBytes
            }

            if (capParaHasLines || capOpenKind != CAP_OPEN_NONE || capCursorOffset > commitOffset) {
                ensureCapPrefix()
                val remRaw = source.substring(capCursorOffset)
                val remBytes = utf8Length(remRaw)
                val mergedTail = mergeCapRemainder(remRaw)
                parsedBytes = OrbKernel.streamTokenCostStep(parsedBytes.toLong(), (advanceUtf8 + capDelta).toLong(), remBytes.toLong()).toInt()
                return prefixBlocks + (capPrefixBlocks ?: emptyList()) + mergedTail
            }
        } else if (scanState.tick && (capParaHasLines || capOpenKind != CAP_OPEN_NONE || capPrefixBlocks != null)) {
            resetCapState()
        }

        val tail = source.substring(commitOffset)
        parsedBytes = OrbKernel.streamTokenCostStep(parsedBytes.toLong(), advanceUtf8.toLong(), utf8Length(tail).toLong()).toInt()
        return prefixBlocks + parseMdBlocks(tail)
    }

    private fun buildCapBlocksUpTo(
        source: String,
        targetOffset: Int,
        onDeltaBytes: (Int) -> Unit
    ): List<OrbMdBlock> {
        if (capPrefixBlocks == null) {
            val slice = source.substring(commitOffset, capCursorOffset)
            onDeltaBytes(utf8Length(slice))
            capPrefixBlocks = if (slice.isEmpty()) mutableListOf() else parseMdBlocks(slice).toMutableList()
        }
        val remSlice = if (capCursorOffset < targetOffset) {
            var end = targetOffset
            if (end > capCursorOffset && source[end - 1] == '\n') end -= 1
            source.substring(capCursorOffset, end)
        } else ""
        onDeltaBytes(utf8Length(remSlice))
        val merged = mergeCapRemainder(remSlice)
        return (capPrefixBlocks ?: emptyList()) + merged
    }

    private fun mergeCapRemainder(remRaw: String): List<OrbMdBlock> {
        if (capParaHasLines) {
            if (remRaw.isEmpty()) return listOf(OrbMdBlock.Paragraph(capParaAcc.toString()))
            val normRem = OrbCodeFences.normalize(remRaw)
            val remLines = normRem.split("\n")
            val mergedPara = StringBuilder(capParaAcc)
            var idx = 0
            while (idx < remLines.size) {
                val l = remLines[idx]
                val t = l.trim()
                if (breaksParagraph(t)) {
                    if (t.startsWith("#") && !isHeading(t)) idx++
                    break
                }
                mergedPara.append('\n').append(l)
                idx++
            }
            val restStr = if (idx < remLines.size) remLines.subList(idx, remLines.size).joinToString("\n") else ""
            val restBlocks = if (restStr.isEmpty()) emptyList() else parseMdBlocks(restStr)
            return listOf(OrbMdBlock.Paragraph(mergedPara.toString())) + restBlocks
        }

        if (capOpenKind == CAP_OPEN_NONE) {
            return if (remRaw.isEmpty()) emptyList() else parseMdBlocks(remRaw)
        }

        if (remRaw.isEmpty()) {
            return listOf(materializeOpenBlock())
        }

        val normRem = if (capOpenKind == CAP_OPEN_CODE) remRaw else OrbCodeFences.normalize(remRaw)
        val remLines = normRem.split("\n")
        var idx = 0
        when (capOpenKind) {
            CAP_OPEN_CODE -> {
                val acc = StringBuilder(capOpenCodeAcc)
                var hasLines = capOpenCodeHasLines
                while (idx < remLines.size && !remLines[idx].trim().startsWith("```")) {
                    if (hasLines) acc.append('\n')
                    acc.append(remLines[idx])
                    hasLines = true
                    idx++
                }
                if (idx < remLines.size) idx++
                val block = OrbMdBlock.CodeBlock(capOpenCodeLang, acc.toString())
                val rest = if (idx < remLines.size) parseMdBlocks(remLines.subList(idx, remLines.size).joinToString("\n")) else emptyList()
                return listOf(block) + rest
            }
            CAP_OPEN_MATH -> {
                val acc = StringBuilder(capOpenMathAcc)
                var hasLines = capOpenMathHasLines
                var closed = false
                while (idx < remLines.size) {
                    val cur = remLines[idx]
                    val curTrim = cur.trim()
                    if (curTrim.isEmpty() || curTrim.startsWith("```")) break
                    val closeIdx = curTrim.indexOf(capOpenMathDelim)
                    if (closeIdx >= 0) {
                        val before = curTrim.substring(0, closeIdx)
                        if (before.isNotEmpty()) {
                            if (hasLines) acc.append('\n')
                            acc.append(before)
                        }
                        closed = true
                        idx++
                        break
                    }
                    if (hasLines) acc.append('\n')
                    acc.append(cur)
                    hasLines = true
                    idx++
                }
                val block = OrbMdBlock.MathBlock(acc.toString().trim(), complete = closed)
                val rest = if (idx < remLines.size) parseMdBlocks(remLines.subList(idx, remLines.size).joinToString("\n")) else emptyList()
                return listOf(block) + rest
            }
            CAP_OPEN_QUOTE -> {
                val acc = StringBuilder(capOpenQuoteAcc)
                while (idx < remLines.size) {
                    val t = remLines[idx].trim()
                    if (t.startsWith("> ")) {
                        acc.append('\n').append(t.drop(2))
                        idx++
                    } else if (t == ">") {
                        acc.append('\n')
                        idx++
                    } else break
                }
                val rest = if (idx < remLines.size) parseMdBlocks(remLines.subList(idx, remLines.size).joinToString("\n")) else emptyList()
                return listOf(OrbMdBlock.Quote(acc.toString())) + rest
            }
            CAP_OPEN_UNORDERED_LIST -> {
                val items = ArrayList<String>(capOpenListItems.size + 8)
                items.addAll(capOpenListItems)
                while (idx < remLines.size) {
                    val t = remLines[idx].trim()
                    if (t.startsWith("- ") || t.startsWith("* ")) {
                        items.add(t.drop(2))
                        idx++
                    } else break
                }
                val rest = if (idx < remLines.size) parseMdBlocks(remLines.subList(idx, remLines.size).joinToString("\n")) else emptyList()
                return listOf(OrbMdBlock.ListBlock(false, items)) + rest
            }
            CAP_OPEN_ORDERED_LIST -> {
                val items = ArrayList<String>(capOpenListItems.size + 8)
                items.addAll(capOpenListItems)
                while (idx < remLines.size) {
                    val t = remLines[idx].trim()
                    val d = t.indexOf(". ")
                    if (d in 1..3 && t.substring(0, d).all { it.isDigit() }) {
                        items.add(t.substring(d + 2))
                        idx++
                    } else break
                }
                val rest = if (idx < remLines.size) parseMdBlocks(remLines.subList(idx, remLines.size).joinToString("\n")) else emptyList()
                return listOf(OrbMdBlock.ListBlock(true, items)) + rest
            }
            CAP_OPEN_TABLE -> {
                val rows = ArrayList<List<String>>(capOpenTableRows.size + 8)
                rows.addAll(capOpenTableRows)
                while (idx < remLines.size) {
                    val t = remLines[idx].trim()
                    if (!isMdBlockTableRow(t)) break
                    rows.add(parseCapTableCells(t))
                    idx++
                }
                val rest = if (idx < remLines.size) parseMdBlocks(remLines.subList(idx, remLines.size).joinToString("\n")) else emptyList()
                return listOf(buildTableBlock(rows)) + rest
            }
            else -> return if (remRaw.isEmpty()) emptyList() else parseMdBlocks(remRaw)
        }
    }

    private fun materializeOpenBlock(): OrbMdBlock = when (capOpenKind) {
        CAP_OPEN_CODE -> OrbMdBlock.CodeBlock(capOpenCodeLang, if (capOpenCodeHasLines) capOpenCodeAcc.toString() + "\n" else "")
        CAP_OPEN_MATH -> OrbMdBlock.MathBlock(capOpenMathAcc.toString().trim(), complete = false)
        CAP_OPEN_QUOTE -> OrbMdBlock.Quote(capOpenQuoteAcc.toString())
        CAP_OPEN_UNORDERED_LIST -> OrbMdBlock.ListBlock(false, capOpenListItems.toList())
        CAP_OPEN_ORDERED_LIST -> OrbMdBlock.ListBlock(true, capOpenListItems.toList())
        CAP_OPEN_TABLE -> buildTableBlock(capOpenTableRows)
        else -> OrbMdBlock.Paragraph("")
    }

    private fun updateTildeFence(rawLine: String) {
        val tCount = tildeMarkerCount(rawLine) ?: return
        if (capInTildeFence && tCount >= capTildeCount) {
            capInTildeFence = false
            capTildeCount = 0
        } else if (!capInTildeFence) {
            capInTildeFence = true
            capTildeCount = tCount
        }
    }

    companion object {
        internal const val OPEN_FENCE_STREAM_THRESHOLD = 4096
        internal const val DEFAULT_MAX_OPEN_TAIL_BYTES = 16_384

        private fun tildeMarkerCount(raw: String): Int? {
            val rest = raw.trimStart(' ', '\t')
            if (!rest.startsWith("~")) return null
            val n = rest.takeWhile { it == '~' }.length
            return if (n >= 3) n else null
        }

        private const val CAP_OPEN_NONE = 0
        private const val CAP_OPEN_MATH = 1
        private const val CAP_OPEN_QUOTE = 2
        private const val CAP_OPEN_UNORDERED_LIST = 3
        private const val CAP_OPEN_ORDERED_LIST = 4
        private const val CAP_OPEN_TABLE = 5
        private const val CAP_OPEN_CODE = 6

        private fun parseCapTableCells(trimmed: String): List<String> {
            val inner = trimmed.substring(1, trimmed.length - 1)
            val cells = mutableListOf<String>()
            val cur = StringBuilder()
            var i = 0
            while (i < inner.length) {
                if (inner[i] == '\\' && i + 1 < inner.length && inner[i + 1] == '|') {
                    cur.append('|')
                    i += 2
                    continue
                }
                if (inner[i] == '|') {
                    cells.add(cur.toString().trim())
                    cur.setLength(0)
                    i++
                    continue
                }
                cur.append(inner[i])
                i++
            }
            cells.add(cur.toString().trim())
            return cells
        }

        private fun isCapTableSeparator(cells: List<String>): Boolean =
            cells.isNotEmpty() && cells.all { cell ->
                val stripped = cell.replace("-", "").replace(":", "").trim()
                stripped.isEmpty() && cell.contains("-")
            }

        private fun buildTableBlock(rawRows: List<List<String>>): OrbMdBlock.Table {
            if (rawRows.size >= 2 && isCapTableSeparator(rawRows[1])) {
                val right = rawRows[1].map { val c = it.trim(); c.endsWith(":") && !c.startsWith(":") }
                return OrbMdBlock.Table(rawRows[0], rawRows.drop(2), right)
            }
            return OrbMdBlock.Table(rawRows[0], rawRows.drop(1))
        }

        private fun isOrderedItem(trimmed: String): Boolean {
            val dotIdx = trimmed.indexOf(". ")
            return dotIdx in 1..3 && trimmed.substring(0, dotIdx).all { it.isDigit() }
        }

        private fun isHeading(trimmed: String): Boolean {
            if (!trimmed.startsWith("#")) return false
            val hashes = trimmed.takeWhile { it == '#' }.length
            return hashes in 1..4 && trimmed.length > hashes && trimmed[hashes] == ' '
        }

        private fun breaksParagraph(trimmed: String): Boolean =
            trimmed.isEmpty() ||
                trimmed.startsWith("```") ||
                trimmed.startsWith("#") ||
                trimmed.startsWith("- ") ||
                trimmed.startsWith("* ") ||
                trimmed.startsWith("> ") ||
                isMdBlockTableRow(trimmed) ||
                isMdBlockDisplayMathStart(trimmed) ||
                isMdBlockStandaloneImage(trimmed)
    }

    private fun utf8Length(s: CharSequence): Int {
        var n = 0
        var i = 0
        while (i < s.length) {
            val c = s[i]
            n += when {
                c.code < 0x80 -> 1
                c.code < 0x800 -> 2
                Character.isHighSurrogate(c) -> { i++; 4 }
                else -> 3
            }
            i++
        }
        return n
    }
}

/**
 * Orb.Stream §4: a cache keyed by the text itself, bounded, evicting only its least recently
 * used entry (never everything at once). A hit moves the key to the front. iOS: OrbTextCache.
 */
class OrbTextCache<V>(val capacity: Int) {
    private val entries = object : LinkedHashMap<String, V>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, V>?) = size > capacity
    }
    var hits = 0
        private set
    var misses = 0
        private set

    val size: Int get() = synchronized(entries) { entries.size }
    /** Keys, most recently used first (the Lean model's order). */
    val keys: List<String> get() = synchronized(entries) { entries.keys.reversed() }

    fun get(key: String): V? = synchronized(entries) {
        entries[key].also { if (it != null) hits++ else misses++ }
    }

    fun put(key: String, value: V) { synchronized(entries) { entries[key] = value } }
}

/** Parsed Markdown blocks of finished messages, shared by every row (items leave and re-enter the list). */
internal object OrbMdCache {
    val blocks = OrbTextCache<List<OrbMdBlock>>(256)
    fun parse(source: String): List<OrbMdBlock> = blocks.get(source) ?: parseMdBlocks(source).also { blocks.put(source, it) }
}

/** Counts recompositions in tests (which composables a stream recomposes). */
object OrbRenderProbe {
    val counts = java.util.concurrent.ConcurrentHashMap<String, Int>()
    fun hit(name: String) { counts.merge(name, 1, Int::plus) }
}

/**
 * The streaming bubble: the only composable that reads [OrbLiveText.text], so a frame of
 * deltas recomposes this item, not the conversation screen. Live text the stored answers
 * already hold is not shown twice.
 */
@Composable
fun OrbLiveReply(live: OrbLiveText, storedAnswers: List<String>, content: @Composable (String) -> Unit) {
    OrbRenderProbe.hit("liveReply")
    val text = OrbSendFlow.dedupeLiveText(live.text, storedAnswers)
    if (text.trim().isNotEmpty()) content(text)
}
