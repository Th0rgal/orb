package sh.sandboxed.dashboard.orb

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
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
class OrbLiveText(private val scope: CoroutineScope, private val frameMs: Long = 16) {
    /** What the streaming bubble shows. */
    var text by mutableStateOf("")
        private set
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
            flushJob = scope.launch(Dispatchers.Main) {
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
        val nextTick = if (line.tick) !tick else tick
        val nextFence = nextFence(fence, line.marker)
        val commits = line.blank && !nextTick && nextFence == null
        return OrbStreamCommit(nextTick, nextFence, pos + 1, if (commits) pos + 1 else commit)
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
            if (open == null) return m
            return if (m != null && m.backtick == open.backtick && open.count <= m.count) null else open
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
    private var prefix = ""
    private var prefixBlocks: List<OrbMdBlock> = emptyList()

    fun blocks(source: String): List<OrbMdBlock> {
        if (!source.startsWith(prefix)) { prefix = ""; prefixBlocks = emptyList() }
        val rest = source.substring(prefix.length)
        val advance = OrbStreamCommit.committedLength(rest)
        if (advance > 0) {
            val chunk = rest.substring(0, advance)
            prefixBlocks = prefixBlocks + parseMdBlocks(chunk)
            prefix += chunk
            return prefixBlocks + parseMdBlocks(rest.substring(advance))
        }
        return prefixBlocks + parseMdBlocks(rest)
    }
}
