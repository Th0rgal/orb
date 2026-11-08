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
            "text\n\n  \n   indented after a whitespace line\n\n> q\n\n---\n\n1. x\n\n" +
            "Intro\n\n\$\$\n\\frac{a}{b}\n\$\$\n\nAfter \$\$x^2\$\$\n\n"
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

        val liveSuffix = OrbLiveText(
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined),
            frameMs = 3_600_000L,
            frameDispatcher = kotlinx.coroutines.Dispatchers.Unconfined
        )
        val suffixAcc = StringBuilder()
        var prevScalars = 0
        for (i in 0 until 50) {
            val chunk = "step 😀 $i\n"
            suffixAcc.append(chunk)
            val piece = if (prevScalars == 0) suffixAcc.toString() else chunk
            liveSuffix.applyTextOp(mapOf("bubble_id" to "text_delta_latest", "ops" to listOf(mapOf("type" to "insert", "pos" to prevScalars, "text" to piece))))
            prevScalars += chunk.codePointCount(0, chunk.length)
        }
        assertEquals(suffixAcc.toString(), liveSuffix.received)
        liveSuffix.flush()
        assertEquals(suffixAcc.toString(), liveSuffix.text)
    }

    @Test
    fun openTailCapBoundsUnclosedFenceReparseBytesAndSingleBufferLiveText() {
        val capBytes = 2048
        val parser = OrbStreamBlocks(maxOpenTailBytes = capBytes)
        val acc = StringBuilder("Intro paragraph.\n\n~~~rust\n")
        var prevParsed = 0
        var lastBlocks: List<OrbMdBlock> = emptyList()
        for (frame in 0 until 64) {
            repeat(24) { acc.append("val v_$frame = \"é😀 | a | b\"\n") }
            lastBlocks = parser.blocks(acc.toString())
            val frameParsed = parser.parsedBytes - prevParsed
            prevParsed = parser.parsedBytes
            if (frame > 0) {
                check(frameParsed <= capBytes) { "frame $frame parsed $frameParsed > cap $capBytes" }
            }
        }
        check(parser.openFenceCapped) { "expected openFenceCapped once open tail exceeds $capBytes bytes" }
        check(acc.toString().toByteArray(Charsets.UTF_8).size > 20_480)
        check(parser.parsedBytes <= 64 * capBytes + 256) { "parsedBytes=${parser.parsedBytes} exceeded linear bound" }
        assertEquals(parseMdBlocks(acc.toString()), lastBlocks)

        acc.append("~~~\n")
        assertEquals(parseMdBlocks(acc.toString()), parser.blocks(acc.toString()))
        acc.append("\nTrailing summary.")
        assertEquals(parseMdBlocks(acc.toString()), parser.blocks(acc.toString()))

        val backtickParser = OrbStreamBlocks(maxOpenTailBytes = capBytes)
        val tickAcc = StringBuilder("Header.\n\n```rust\n")
        for (frame in 0 until 32) {
            repeat(24) { tickAcc.append("pub fn f_$frame() -> usize { $frame }\n") }
            val snap = tickAcc.toString()
            assertEquals(parseMdBlocks(snap), backtickParser.blocks(snap))
        }
        check(tickAcc.toString().toByteArray(Charsets.UTF_8).size > 20_480)
        tickAcc.append("```")
        assertEquals(parseMdBlocks(tickAcc.toString()), backtickParser.blocks(tickAcc.toString()))
        tickAcc.append("\nNext line without blank separator")
        assertEquals(parseMdBlocks(tickAcc.toString()), backtickParser.blocks(tickAcc.toString()))

        val live = OrbLiveText(
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined),
            frameMs = 3_600_000L,
            frameDispatcher = kotlinx.coroutines.Dispatchers.Unconfined
        )
        live.append("hello ")
        live.append("world")
        assertEquals("", live.text)
        assertEquals("hello world", live.received)
        assertEquals(0, live.renders)
        live.flush()
        assertEquals("hello world", live.text)
        assertEquals(1, live.renders)

        live.append(" stale-tail")
        live.replace("fresh")
        assertEquals("fresh", live.text)
        assertEquals("fresh", live.received)
        assertEquals(1, live.renders)

        live.resetTurn(5L)
        assertEquals("", live.text)
        assertEquals("", live.received)
        assertEquals(1, live.renders)
    }

    @Test
    fun openTailCapPreservesParagraphContinuationAndBlockParityAcrossStrides() {
        val pad = "Paragraph prefix padding to exceed the 128-byte open tail cap cleanly without any blank line before the tricky continuation token arrives in the stream."
        val docs = listOf(
            "$pad\n---\n1. continued item\n>\nstill same paragraph\n##### ignored h5\n#alsoIgnored\n#\nafter non-heading hash",
            "$pad\n---",
            "$pad\n1. item that continues paragraph",
            "$pad\n>",
            "$pad\n~~~\ncol1 | col2 | col3\nval1 | val2 | val3\n~~~\n\ncol1 | col2 | col3\n10 | 20 | 30\n",
            "$pad\nprose before glued fence```kotlin\nval x = 1\n```\n##### skipped\nnext paragraph\nprose```mermaid\ngraph TD\nA-->B\n"
        )
        for (stride in listOf(1, 5, 19)) {
            for ((idx, doc) in docs.withIndex()) {
                val parser = OrbStreamBlocks(maxOpenTailBytes = 128)
                val cleanParser = OrbStreamBlocks(maxOpenTailBytes = 128)
                var end = 0
                while (end < doc.length) {
                    end = minOf(doc.length, end + stride)
                    val prefix = doc.substring(0, end)
                    assertEquals("doc $idx stride $stride end $end", parseMdBlocks(prefix), parser.blocks(prefix))
                    val cleaned = cleanRichText(prefix, streaming = true)
                    assertEquals("clean doc $idx stride $stride end $end", parseMdBlocks(cleaned), cleanParser.blocks(cleaned))
                }
                val finalClean = cleanRichText(doc, streaming = false)
                assertEquals("final clean doc $idx stride $stride", parseMdBlocks(finalClean), cleanParser.blocks(finalClean))
            }
        }
    }

    @Test
    fun openTailCapBoundsUnclosedNonFenceBlocksToO1PerFrame() {
        val capBytes = 256
        data class UnclosedCase(
            val name: String,
            val header: String,
            val lineFn: (Int) -> String,
            val closeSuffix: String
        )
        val cases = listOf(
            UnclosedCase(
                name = "math",
                header = "Intro.\n\n$$\n",
                lineFn = { i -> "x_{$i} + y_{$i} = z_{$i} + \\alpha_{$i} + \\beta_{$i} + \\gamma_{$i}\n" },
                closeSuffix = "$$\n\nDone."
            ),
            UnclosedCase(
                name = "quote",
                header = "Intro.\n\n",
                lineFn = { i -> if (i % 7 == 4) ">\n" else "> quoted streaming line number $i with extra words for payload\n" },
                closeSuffix = "\nDone."
            ),
            UnclosedCase(
                name = "unorderedList",
                header = "Intro.\n\n",
                lineFn = { i -> "- unordered streaming item $i with enough text to cross cap quickly\n" },
                closeSuffix = "\nDone."
            ),
            UnclosedCase(
                name = "orderedList",
                header = "Intro.\n\n",
                lineFn = { i -> "${(i % 99) + 1}. ordered streaming item $i with enough text to cross cap quickly\n" },
                closeSuffix = "\nDone."
            ),
            UnclosedCase(
                name = "table",
                header = "Intro.\n\n| Metric | Value | Delta |\n| --- | ---: | ---: |\n",
                lineFn = { i -> "| streaming_metric_row_$i | ${i * 10} milliseconds | +$i ms |\n" },
                closeSuffix = "\nDone."
            ),
            UnclosedCase(
                name = "loosePipeTable",
                header = "Intro.\n\nMetric | Value | Delta\n",
                lineFn = { i -> "streaming_metric_row_$i | ${i * 10} milliseconds | +$i ms\n" },
                closeSuffix = "\nDone."
            )
        )

        for (c in cases) {
            val parser = OrbStreamBlocks(maxOpenTailBytes = capBytes)
            val acc = StringBuilder(c.header)
            var prevParsed = 0
            for (i in 0 until 90) {
                acc.append(c.lineFn(i))
                val rawSnap = acc.toString()
                val snap = if (c.name == "loosePipeTable") cleanRichText(rawSnap, streaming = true) else rawSnap
                val blocks = parser.blocks(snap)
                val delta = parser.parsedBytes - prevParsed
                prevParsed = parser.parsedBytes
                if (i > 4) {
                    check(delta <= capBytes * 2) { "${c.name} frame $i parsed delta $delta > ${capBytes * 2}" }
                }
                assertEquals("${c.name} frame $i", parseMdBlocks(snap), blocks)
            }
            val totalUtf8 = acc.toString().toByteArray(Charsets.UTF_8).size
            check(totalUtf8 > 3_500) { "${c.name} expected > 3.5 KB, got $totalUtf8" }
            check(parser.parsedBytes <= 90 * capBytes + 512) {
                "${c.name} parsedBytes=${parser.parsedBytes} exceeded linear bound"
            }
            acc.append(c.closeSuffix)
            val rawClosed = acc.toString()
            val closedSnap = if (c.name == "loosePipeTable") cleanRichText(rawClosed, streaming = false) else rawClosed
            assertEquals("${c.name} after close", parseMdBlocks(closedSnap), parser.blocks(closedSnap))
        }
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
