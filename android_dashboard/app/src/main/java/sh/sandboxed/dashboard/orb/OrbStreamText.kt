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

    /** Frames that changed [text] (the coalescer's render count). */
    var renders = 0
        private set

    /** Everything received, shown or not (the conservation law: `text + pending`). */
    val received: String get() = synchronized(pending) { text + pending }

    /** Safe from any thread (the SSE reader): one Main dispatch per frame, not per delta. */
    fun append(delta: String) {
        if (delta.isEmpty()) return
        synchronized(pending) {
            pending.append(delta)
            if (flushJob != null) return
            flushJob = scope.launch(frameDispatcher) {
                delay(frameMs)
                flush()
            }
        }
    }

    /** Moves pending text to [text] now (one render). */
    fun flush() {
        val next = synchronized(pending) {
            flushJob = null
            if (pending.isEmpty()) return
            pending.toString().also { pending.setLength(0) }
        }
        text += next
        renders++
    }

    fun clear() {
        synchronized(pending) {
            flushJob?.cancel(); flushJob = null
            pending.setLength(0)
        }
        text = ""
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
