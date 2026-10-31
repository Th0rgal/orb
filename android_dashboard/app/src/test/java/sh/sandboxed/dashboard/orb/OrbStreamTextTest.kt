package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Test

/** Streaming reply text (lean/Orb/Stream.lean); iOS runs the same fixture in OrbStreamTextTests. */
class OrbStreamTextTest {
    private val cases = OrbJSON.dictList(OrbSpec.dict("fixtures/stream-commit.json")["cases"])

    @Test
    fun commitPointsMatchLean() {
        check(cases.isNotEmpty())
        for (c in cases) {
            val doc = c["doc"] as String
            val expected = (c["commits"] as List<*>).map { (it as Number).toInt() }
            var state = OrbStreamCommit()
            val commits = mutableListOf(state.commit)
            for (line in doc.split("\n")) { state = state.scan(OrbStreamCommit.classify(line)); commits.add(state.commit) }
            assertEquals(doc, expected, commits)
        }
    }

    /** At every streamed prefix, the incremental blocks equal a full parse. */
    @Test
    fun incrementalBlocksEqualFullParse() {
        val docs = cases.map { it["doc"] as String } + longReply(6) +
            "Prix : 3 € | 4 €\n\n| a | b |\n|---|---|\n| é | 😀 |\n\n```\n\n```\n\ndone" +
            "text\n\n  \n   indented after a whitespace line\n\n> q\n\n---\n\n1. x\n\n"
        for (doc in docs) for (stride in listOf(1, 3, 7)) {
            val blocks = OrbStreamBlocks()
            var end = 0
            while (end < doc.length) {
                end = minOf(doc.length, end + stride)
                val shown = doc.substring(0, end)
                assertEquals("$stride: $shown", parseMdBlocks(shown), blocks.blocks(shown))
            }
        }
    }

    /** Cost of an 8 KB reply streamed as 2,000 four-character deltas: full vs incremental. */
    @Test
    fun streamingParseCost() {
        val doc = longReply(22)
        fun time(parse: (String) -> List<OrbMdBlock>): Long {
            val t0 = System.nanoTime()
            var end = 0
            while (end < doc.length) { end = minOf(doc.length, end + 4); parse(doc.substring(0, end)) }
            return (System.nanoTime() - t0) / 1_000_000
        }
        repeat(2) { time(::parseMdBlocks) } // warm up the JIT
        val full = time(::parseMdBlocks)
        val stream = OrbStreamBlocks()
        val incremental = time(stream::blocks)
        println("streamingParseCost full=${full}ms incremental=${incremental}ms")
        check(incremental < full) { "incremental $incremental ms vs full $full ms" }
    }

    /** Unclosed 256 KB code fence streamed in 1 KB frames scans & parses O(N) bytes and matches full parse. */
    @Test
    fun unclosedFenceStreamsInLinearCostAndMatchesFullParse() {
        val totalKb = 256
        val stream = OrbStreamBlocks()
        val acc = StringBuilder(totalKb * 1024 + 512)
        var lastBlocks: List<OrbMdBlock> = emptyList()
        for (k in 0 until totalKb) {
            val sb = StringBuilder()
            if (k == 0) sb.append("Here is the generated code:\n\n```rust\n")
            var li = 0
            while (sb.length < 1024) {
                sb.append("pub fn step_${k}_${li}(x: u64, y: u64) -> u64 { (x | y) ^ 0x55aa_${k} }\n")
                li++
            }
            acc.append(sb.substring(0, 1024))
            lastBlocks = stream.blocks(cleanRichText(acc.toString(), streaming = true))
        }
        val openBytes = acc.toString().toByteArray(Charsets.UTF_8).size
        check(stream.scannedBytes <= openBytes) { "scannedBytes=${stream.scannedBytes} > openBytes=$openBytes" }
        check(stream.parsedBytes <= openBytes * 2) { "parsedBytes=${stream.parsedBytes} is superlinear for $openBytes bytes" }
        assertEquals(parseMdBlocks(cleanRichText(acc.toString(), streaming = false)), lastBlocks)

        acc.append("\n```\n\nFinished.\n\n")
        val closedBlocks = stream.blocks(cleanRichText(acc.toString(), streaming = false))
        assertEquals(parseMdBlocks(cleanRichText(acc.toString(), streaming = false)), closedBlocks)
    }

    /** Shared cross-client intermediate live-turn text fixtures (`shared/orb-spec/fixtures/live-turn-text.json`). */
    @Test
    fun liveTurnTextSharedFixtures() {
        val fixture = OrbSpec.dict("fixtures/live-turn-text.json")
        val streamCases = OrbJSON.dictList(fixture["streamCases"])
        check(streamCases.isNotEmpty())
        for (c in streamCases) {
            val name = c["name"] as String
            val expected = c["expected"] as String
            val events = OrbJSON.dictList(c["events"])
            val turn = OrbTurnText()
            val live = OrbLiveText(
                scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined),
                frameMs = 3_600_000L,
                frameDispatcher = kotlinx.coroutines.Dispatchers.Unconfined
            )
            for (ev in events) {
                when (ev["type"] as? String) {
                    "text_op" -> {
                        turn.applyTextOp(ev)
                        live.applyTextOp(ev)
                    }
                    "text_delta" -> {
                        turn.applyTextDelta(ev)
                        live.applyTextDelta(ev)
                    }
                }
            }
            live.flush()
            assertEquals(name, expected, turn.renderedText)
            assertEquals("$name (OrbLiveText)", expected, live.text)
        }

        val storedCases = OrbJSON.dictList(fixture["storedCases"])
        check(storedCases.isNotEmpty())
        for (c in storedCases) {
            val name = c["name"] as String
            val working = c["working"] as Boolean
            val expected = c["expected"] as String
            val rawEvents = OrbJSON.dictList(c["events"]).mapIndexed { idx, item ->
                OrbRow("ev-$idx", item)
            }
            val live = OrbLiveText(
                scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined),
                frameMs = 3_600_000L,
                frameDispatcher = kotlinx.coroutines.Dispatchers.Unconfined
            )
            live.reconcileStored(rawEvents, working = working)
            live.flush()
            assertEquals(name, expected, live.text)
        }

        val dedupeCases = OrbJSON.dictList(fixture["dedupeCases"])
        check(dedupeCases.isNotEmpty())
        for (c in dedupeCases) {
            val name = c["name"] as String
            val expected = c["expected"] as String
            val liveText = c["live"] as String
            val narration = (c["narration"] as? List<*>)?.mapNotNull { it as? String }?.toSet() ?: emptySet()
            val history = OrbJSON.dictList(c["history"]).map { row ->
                (row["role"] as? String ?: "assistant") to (row["content"] as? String ?: "")
            }
            val storedAnswers = OrbSendFlow.currentTurnStoredAnswers(history, narration)
            assertEquals(name, expected, OrbSendFlow.dedupeLiveText(liveText, storedAnswers))
        }
    }

    @Test
    fun textOpCoalescesAndNeverRollsBackOnStalePoll() {
        val live = OrbLiveText(
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined),
            frameMs = 3_600_000L,
            frameDispatcher = kotlinx.coroutines.Dispatchers.Unconfined
        )
        val acc = StringBuilder()
        for (i in 0 until 50) {
            val prevLen = acc.toString().codePoints().count().toInt()
            acc.append("step $i\n")
            val text = acc.toString()
            if (prevLen == 0) {
                live.applyTextOp(mapOf("bubble_id" to "text_delta_latest", "ops" to listOf(mapOf("type" to "insert", "pos" to 0, "text" to text))))
            } else {
                live.applyTextOp(mapOf("bubble_id" to "text_delta_latest", "ops" to listOf(mapOf("type" to "replace", "range" to listOf(0, prevLen), "text" to text))))
            }
        }
        val full = acc.toString()
        assertEquals(full, live.received)
        live.flush()
        assertEquals(full, live.text)

        val stalePrefix = full.take(24)
        val staleEvents = listOf(
            OrbRow("1", mapOf("sequence" to 1, "event_type" to "user_message", "content" to "go")),
            OrbRow("2", mapOf("sequence" to 2, "event_type" to "text_delta", "event_id" to "text_delta_latest", "content" to stalePrefix))
        )
        live.reconcileStored(staleEvents, working = true, streamAdvanced = true)
        live.flush()
        assertEquals(full, live.text)
    }

    private fun longReply(sections: Int): String = buildString {
        append("STREAM_LONG_OK: here is the full report.")
        for (k in 0 until sections) {
            append("\n\n## Section $k\n\nThe pass rewrote `Module$k.lean`, kept every **invariant**, and re-ran the suite.\n\n")
            append("- step $k.1 checked\n- step $k.2 proved\n\n| Case | Before | After |\n| --- | ---: | ---: |\n| $k | ${k * 3} ms | $k ms |\n\n")
            append("```lean\ntheorem pass$k : $k + 0 = $k := by simp\n```")
        }
        append("\n\nSTREAM_LONG_END")
    }
}

/** Event memory is bounded: long tool output is cut (the timeline never shows it), short rows are untouched. */
class OrbEventCompactionTest {
    @Test
    fun longToolResultsAreCutShortRowsKept() {
        val big = "line of build output\n".repeat(5000)
        val rows = listOf(
            OrbRow("1", mapOf("event_type" to "tool_result", "content" to big, "tool_call_id" to "c1")),
            OrbRow("2", mapOf("event_type" to "assistant_message", "content" to big)),
            OrbRow("3", mapOf("event_type" to "tool_result", "content" to "ok"))
        )
        val kept = OrbReadCache.compactEvents(rows)
        assertEquals(OrbReadCache.RESULT_KEEP_CHARS, (kept[0].raw["content"] as String).length)
        assertEquals("c1", kept[0].raw["tool_call_id"])
        assertEquals(rows[1], kept[1])
        assertEquals(rows[2], kept[2])
        assertEquals(OrbTimelineBuilder.build(emptyList(), rows, "", false, null), OrbTimelineBuilder.build(emptyList(), kept, "", false, null))
    }
}
