package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Conformance with `lean/Orb/Transcript.lean` (`shared/orb-spec/fixtures/transcript-gates.json`)
 * and 500-seed randomized property fuzzing across `OrbTimelineBuilder`, `OrbConversationHistory`,
 * `OrbMath`, `OrbPipeTables`, and `OrbTranscriptGates`.
 */
class OrbTranscriptFuzzTest {
    @Test
    fun matchesLeanTranscriptGatesFixture() {
        val cases = OrbJSON.dictList(OrbSpec.dict("fixtures/transcript-gates.json")["cases"])
        assertTrue(cases.size >= 60)
        for ((idx, item) in cases.withIndex()) {
            when (val op = OrbJSON.str(item, "op")) {
                "allocTurnKeys" -> {
                    val cands = OrbJSON.dictList(item["candidates"]).map {
                        OrbTranscriptGates.CandidateKey(
                            OrbJSON.int(it, "tag") ?: 0,
                            OrbJSON.int(it, "item") ?: 0
                        )
                    }
                    val expected = OrbJSON.dictList(item["expected"]).map {
                        OrbTranscriptGates.TurnKey(
                            OrbJSON.int(it, "tag") ?: 0,
                            OrbJSON.int(it, "item") ?: 0,
                            OrbJSON.int(it, "gen") ?: 0
                        )
                    }
                    val got = OrbTranscriptGates.allocTurnKeys(cands)
                    assertEquals("allocTurnKeys case $idx", expected, got)
                    assertEquals(got.size, got.toSet().size)
                }

                "latexSpanAdmitted" -> {
                    val label = OrbJSON.str(item, "name") ?: "case-$idx"
                    val got = OrbTranscriptGates.latexSpanAdmitted(
                        len = OrbJSON.int(item, "len") ?: 0,
                        prevBlocked = OrbJSON.bool(item, "prevBlocked") ?: false,
                        nextDigit = OrbJSON.bool(item, "nextDigit") ?: false,
                        leadSpace = OrbJSON.bool(item, "leadSpace") ?: false,
                        trailSpace = OrbJSON.bool(item, "trailSpace") ?: false,
                        hasNewline = OrbJSON.bool(item, "hasNewline") ?: false,
                        firstDigit = OrbJSON.bool(item, "firstDigit") ?: false,
                        internalSpace = OrbJSON.bool(item, "internalSpace") ?: false,
                        hasMathOp = OrbJSON.bool(item, "hasMathOp") ?: false
                    )
                    assertEquals(label, OrbJSON.bool(item, "expected") ?: false, got)
                }

                "windowBudget" -> {
                    val total = OrbJSON.int(item, "total") ?: 0
                    val base = OrbJSON.int(item, "baseLimit") ?: 24
                    val steps = OrbJSON.int(item, "expandedSteps") ?: 0
                    val stepSize = OrbJSON.int(item, "stepSize") ?: 24
                    assertEquals(
                        OrbJSON.int(item, "expectedVisible") ?: 0,
                        OrbTranscriptGates.visibleTurnCount(total, base, steps, stepSize)
                    )
                    assertEquals(
                        OrbJSON.int(item, "expectedHidden") ?: 0,
                        OrbTranscriptGates.hiddenTurnCount(total, base, steps, stepSize)
                    )
                }

                "admitMount" -> {
                    val decision = OrbTranscriptGates.admitMount(
                        OrbJSON.int(item, "active") ?: 0,
                        OrbJSON.int(item, "cap") ?: 0
                    )
                    assertEquals(OrbJSON.bool(item, "expectedAdmitted") ?: false, decision.admitted)
                    assertEquals(OrbJSON.int(item, "expectedNextActive") ?: 0, decision.nextActive)
                }

                else -> error("Unknown op: $op")
            }
        }
    }

    @Test
    fun randomizedTranscriptTimelineAndMarkdownFuzz500Seeds() {
        var rng = -7046029254386353131L // 0x9E3779B97F4A7C15
        fun nextInt(bound: Int): Int {
            rng = rng xor (rng ushr 12)
            rng = rng xor (rng shl 25)
            rng = rng xor (rng ushr 27)
            val mixed = rng * 2685821657736338717L
            return ((mixed ushr 1) % bound.toLong()).toInt()
        }

        val samplePayloads = listOf(
            "Plain update with 🔹 surrogate pair",
            "Currency \$15 and \$20 stays prose while \$x^2 + y_1\$ renders math",
            "$$\n\\frac{\\alpha + 1}{\\sqrt{2}\n", // intentionally unclosed brace + display math
            "colA | colB | colC\r\n🔹 | 12 | 3.5%\r\nDone.",
            "<fork_context>\n<turn role=\"user\">Prior prompt</turn>\n<turn role=\"assistant\">Prior answer</turn>\n</fork_context>\nFollow-up question",
            "[CONTROLLER_WAKE] scheduled tick",
            "```mermaid\nflowchart LR\n  A --> B",
            "![chart](https://example.com/chart.png) and [artifact](file:///workspace/out.txt)"
        )
        val duplicateIds = listOf("", "dup-id", "dup-id#1", "streaming-assistant", "work-fold-main")

        for (seed in 0 until 500) {
            val eventCount = 1 + nextInt(18)
            val historyRows = mutableListOf<OrbRow>()
            val rawEvents = mutableListOf<OrbRow>()

            for (i in 0 until eventCount) {
                val id = duplicateIds[nextInt(duplicateIds.size)]
                val text = samplePayloads[nextInt(samplePayloads.size)]
                val isUser = nextInt(3) == 0
                val isTool = !isUser && nextInt(4) == 0
                val seq = if (nextInt(5) == 0) 7 else i + 1 // inject sequence collisions

                if (isTool) {
                    rawEvents.add(
                        OrbRow(
                            id = id.ifEmpty { "ev-$i" },
                            raw = mapOf(
                                "id" to seq,
                                "mission_id" to "m-fuzz",
                                "sequence" to seq,
                                "event_type" to "tool_call",
                                "tool_name" to "bash",
                                "content" to text,
                                "metadata" to mapOf("command" to "echo $seed")
                            )
                        )
                    )
                } else {
                    val evType = when {
                        isUser -> "user_message"
                        nextInt(2) == 0 -> "assistant_message_canonical"
                        else -> "assistant_message"
                    }
                    rawEvents.add(
                        OrbRow(
                            id = id,
                            raw = mapOf(
                                "id" to seq,
                                "mission_id" to "m-fuzz",
                                "sequence" to seq,
                                "event_type" to evType,
                                "content" to text,
                                "metadata" to mapOf(
                                    "bubble_id" to if (nextInt(2) == 0) "antigravity:b1" else "text_delta_latest",
                                    "revision" to nextInt(4)
                                )
                            )
                        )
                    )
                    if (nextInt(2) == 0) {
                        historyRows.add(
                            OrbRow(
                                id = id,
                                raw = mapOf(
                                    "role" to if (isUser) "user" else "assistant",
                                    "content" to text,
                                    "sequence" to seq
                                )
                            )
                        )
                    }
                }
            }

            val merged = OrbConversationHistory.visible(OrbConversationHistory.merge(historyRows, rawEvents))
            val streaming = if (nextInt(2) == 0) samplePayloads[nextInt(samplePayloads.size)] else ""
            val isLive = nextInt(2) == 0

            val turns = OrbTimelineBuilder.build(
                messages = merged,
                events = rawEvents,
                streamingText = streaming,
                isLive = isLive,
                startedAt = "2026-10-31T00:00:00Z"
            )
            val turnIds = turns.map { it.id }
            assertEquals("Duplicate turn ID at seed $seed: $turnIds", turnIds.size, turnIds.toSet().size)
            assertTrue(turnIds.all { it.isNotEmpty() })

            for (turn in turns) {
                if (turn is OrbTurn.Assistant && turn.text.isNotEmpty()) {
                    val cleaned = cleanRichText(turn.text, turn.isStreaming)
                    assertFalse(OrbMath.usesWebRenderer(cleaned))
                    val blocks = parseMdBlocks(OrbPipeTables.normalize(cleaned))
                    assertTrue(cleaned.isBlank() || blocks.isNotEmpty())
                    for (b in blocks) {
                        if (b is OrbMdBlock.Paragraph) {
                            val tokens = OrbMath.tokenizeInline(b.text)
                            assertTrue(tokens.isNotEmpty() || b.text.isEmpty())
                        }
                    }
                }
            }
        }
    }
}
