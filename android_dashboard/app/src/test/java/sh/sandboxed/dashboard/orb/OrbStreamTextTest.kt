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
