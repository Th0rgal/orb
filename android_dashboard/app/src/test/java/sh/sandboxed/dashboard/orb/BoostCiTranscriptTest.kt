package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class BoostCiTranscriptTest {
    @Test fun boostCiTranscriptReplaysNativelyWithUniqueKeysAndZeroWebRenderer() {
        val file = generateSequence(File(requireNotNull(System.getProperty("user.dir")))) { it.parentFile }
            .map { File(it, "shared/orb-spec/fixtures/transcripts/boost_ci.json") }
            .first { it.exists() }

        val fixture = requireNotNull(OrbJSON.dict(OrbJSON.parse(file.readText())))
        val rawEvents = fixture["events"] as List<*>
        assertEquals(481, rawEvents.size)

        val events = rawEvents.mapIndexed { idx, item ->
            val dict = requireNotNull(OrbJSON.dict(item))
            val id = dict["id"]?.toString() ?: "ev-$idx"
            OrbRow(id, dict)
        }

        val turns = OrbTimelineBuilder.build(
            messages = emptyList(),
            events = events,
            streamingText = "",
            isLive = true,
            startedAt = "2026-10-29T02:20:26Z"
        )
        assertTrue("Expected non-trivial boost_ci timeline, got ${turns.size}", turns.size >= 15)

        val keys = turns.map { it.id }
        assertEquals("Every LazyColumn turn key in boost_ci must be unique", keys.size, keys.toSet().size)

        var assistantCount = 0
        var richAssistantCount = 0
        for (turn in turns) {
            when (turn) {
                is OrbTurn.Assistant -> {
                    assistantCount++
                    assertFalse(needsWebRenderer(turn.text))
                    if (OrbMath.containsMathOrMedia(turn.text)) richAssistantCount++
                    val cleaned = cleanRichText(turn.text, streaming = turn.isStreaming)
                    val blocks = OrbMdCache.parse(cleaned)
                    assertTrue(blocks.isNotEmpty() || cleaned.isEmpty())
                    for (b in blocks) {
                        when (b) {
                            is OrbMdBlock.Paragraph -> parseInlineAnnotated(b.text, streaming = turn.isStreaming)
                            is OrbMdBlock.Heading -> parseInlineAnnotated(b.text, streaming = turn.isStreaming)
                            is OrbMdBlock.ListBlock -> b.items.forEach { parseInlineAnnotated(it, streaming = turn.isStreaming) }
                            is OrbMdBlock.Table -> {
                                b.headers.forEach { parseInlineAnnotated(it, streaming = turn.isStreaming) }
                                b.rows.flatten().forEach { parseInlineAnnotated(it, streaming = turn.isStreaming) }
                            }
                            is OrbMdBlock.MathBlock -> OrbMath.formatCached(b.latex, complete = b.complete, streaming = turn.isStreaming)
                            else -> Unit
                        }
                    }
                }
                is OrbTurn.User -> {
                    val cleaned = cleanRichText(turn.text, streaming = false)
                    OrbMdCache.parse(cleaned).forEach { b ->
                        if (b is OrbMdBlock.Paragraph) parseInlineAnnotated(b.text)
                    }
                }
                is OrbTurn.WorkFold -> {
                    for (n in turn.narration) {
                        val cleaned = cleanRichText(n, streaming = false)
                        OrbMdCache.parse(cleaned)
                    }
                }
                is OrbTurn.Wake -> parseInlineAnnotated(turn.text)
            }
        }
        assertTrue("Expected assistant turns in boost_ci", assistantCount >= 5)
        assertTrue("Expected math-containing turns in boost_ci", richAssistantCount >= 1)
    }
}
