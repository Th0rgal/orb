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
                    bubble.text = op["text"] as? String ?: ""
                    bubble.finalized = false
                }
                "insert" -> {
                    val piece = op["text"] as? String ?: ""
                    val pos = intValue(op["pos"])
                    bubble.text = if (bubbleId == "text_delta_latest" && pos == 0) {
                        piece
                    } else {
                        spliceScalars(bubble.text, pos, pos, piece)
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
        val bubble = existing?.copy(text = existing.text + delta, finalized = false) ?: Bubble(id = id, text = delta)
        upsertBubble(bubble)
    }

    private fun setBubble(id: String, text: String) {
        val existing = bubbles.firstOrNull { it.id == id }
        val bubble = existing?.copy(text = text, finalized = false) ?: Bubble(id = id, text = text)
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

    private var pendingReplace: String? = null

    /** Frames that changed [text] (the coalescer's render count). */
    var renders = 0
        private set

    /** Everything received, shown or not (the conservation law: `text + pending`). */
    val received: String
        get() = synchronized(pending) {
            val base = pendingReplace ?: text
            base + pending.toString()
        }

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
            scheduleReplaceLocked(content, immediate = true)
        }
    }

    fun resetTurn(userSequence: Long = -1L) {
        synchronized(pending) {
            turn.resetTurn(userSequence)
            scheduleReplaceLocked("", immediate = true)
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
            val wasEmpty = (pendingReplace ?: text).isEmpty() && pending.isEmpty()
            turn.reconcileStored(OrbTurnText.rows(events), working = working, streamAdvanced = streamAdvanced)
            syncWithTurnLocked(immediate = wasEmpty)
        }
    }

    /** Moves pending text to [text] now (one render). */
    fun flush() {
        var replaceBase: String? = null
        var delta: String? = null
        synchronized(pending) {
            flushJob = null
            replaceBase = pendingReplace
            pendingReplace = null
            if (pending.isNotEmpty()) {
                delta = pending.toString()
                pending.setLength(0)
            }
        }
        val base = replaceBase
        val tail = delta
        if (base != null) {
            val next = if (tail != null) base + tail else base
            if (text != next) {
                text = next
                if (tail != null) renders++
            }
        } else if (tail != null) {
            text += tail
            renders++
        }
    }

    fun clear() {
        synchronized(pending) {
            turn.clear()
            flushJob?.cancel(); flushJob = null
            pendingReplace = null
            pending.setLength(0)
        }
        text = ""
    }

    private fun syncWithTurnLocked(immediate: Boolean) {
        val next = turn.renderedText
        val current = (pendingReplace ?: text) + pending.toString()
        if (next == current) return
        if (next.isEmpty()) {
            scheduleReplaceLocked("", immediate = true)
            return
        }
        if (!immediate && next.startsWith(current)) {
            appendCoalescedLocked(next.substring(current.length))
        } else {
            scheduleReplaceLocked(next, immediate = immediate)
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

    private fun scheduleReplaceLocked(content: String, immediate: Boolean) {
        flushJob?.cancel()
        flushJob = null
        pendingReplace = content
        pending.setLength(0)
        flushJob = scope.launch(frameDispatcher) {
            if (!immediate) delay(frameMs)
            flush()
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
        fun classify(raw: String): Line {
            val rest = raw.trimStart(' ', '\t')
            val c = rest.firstOrNull()
            val marker = if (c == '`' || c == '~') rest.takeWhile { it == c }.length.takeIf { it >= 3 }?.let { Marker(c == '`', it) } else null
            // The parser's own trimming decides blank and fence lines.
            val trimmed = raw.trim()
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
                state = state.scan(classify(text.substring(start, end)))
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
internal class OrbStreamBlocks {
    private var previous = ""
    private var commitOffset = 0
    private var scanCursor = 0
    private var scanState = OrbStreamCommit()
    private var prefixBlocks: List<OrbMdBlock> = emptyList()

    private var openFenceStart = -1
    private var openFenceBodyStart = 0
    private var openFenceBodyCursor = 0
    private var openFenceLang = ""
    private var openFencePrefixBlocks: List<OrbMdBlock>? = null
    private val openFenceAcc = StringBuilder()
    private var openFenceHasLines = false

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

    fun blocks(source: String): List<OrbMdBlock> {
        if (!source.startsWith(previous)) {
            commitOffset = 0
            scanCursor = 0
            scanState = OrbStreamCommit()
            prefixBlocks = emptyList()
            resetOpenFence()
        }
        previous = source

        var newCommitOffset = commitOffset
        while (true) {
            val nl = source.indexOf('\n', scanCursor)
            if (nl == -1) break
            val line = source.substring(scanCursor, nl)
            val lineStart = scanCursor
            scanCursor = nl + 1
            scannedBytes += utf8Length(line) + 1

            val wasTick = scanState.tick
            val beforeCommit = scanState.commit
            scanState = scanState.scan(OrbStreamCommit.classify(line))
            if (scanState.commit != beforeCommit) {
                newCommitOffset = scanCursor
                resetOpenFence()
            } else if (!wasTick && scanState.tick) {
                openFenceStart = lineStart
                openFenceBodyStart = scanCursor
                openFenceBodyCursor = scanCursor
                openFenceLang = line.trim().drop(3).trim()
                openFencePrefixBlocks = null
                openFenceAcc.setLength(0)
                openFenceHasLines = false
            } else if (wasTick && !scanState.tick) {
                resetOpenFence()
            }
        }

        val advanceChars = newCommitOffset - commitOffset
        val advanceUtf8 = if (advanceChars > 0) {
            val chunk = source.substring(commitOffset, newCommitOffset)
            prefixBlocks = prefixBlocks + parseMdBlocks(chunk)
            commitOffset = newCommitOffset
            utf8Length(chunk)
        } else {
            0
        }

        if (scanState.tick && openFenceStart >= commitOffset && scanCursor - openFenceBodyStart >= OPEN_FENCE_STREAM_THRESHOLD) {
            val trailing = source.substring(scanCursor)
            if (!trailing.trim().startsWith("```")) {
                var deltaBytes = advanceUtf8
                var pre = openFencePrefixBlocks
                if (pre == null) {
                    val preSlice = source.substring(commitOffset, openFenceStart)
                    deltaBytes += utf8Length(preSlice)
                    pre = if (preSlice.isNotEmpty()) parseMdBlocks(preSlice) else emptyList()
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

        val tail = source.substring(commitOffset)
        parsedBytes = OrbKernel.streamTokenCostStep(parsedBytes.toLong(), advanceUtf8.toLong(), utf8Length(tail).toLong()).toInt()
        return prefixBlocks + parseMdBlocks(tail)
    }

    companion object {
        internal const val OPEN_FENCE_STREAM_THRESHOLD = 4096
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
