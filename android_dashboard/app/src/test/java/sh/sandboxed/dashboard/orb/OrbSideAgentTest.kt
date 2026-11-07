package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbSideAgentTest {
    @Test
    fun mergeTurnsDeduplicatesCollidingIdsAndBoundsVisibleWindow() {
        val perThread = (0 until 25).map { threadIdx ->
            val count = if (threadIdx == 0) 11 else 10
            (0 until count).map { turnIdx ->
                val globalIdx = threadIdx * 10 + turnIdx
                val seq = if (threadIdx == 24 && turnIdx == 1) 0 else turnIdx
                val stamp = "2026-11-05T%02d:%02d:%02dZ".format((globalIdx / 60) % 24, globalIdx % 60, turnIdx % 60)
                OrbSideAgent.Turn(
                    id = "btw:t$threadIdx:$seq",
                    question = "Q$globalIdx?",
                    answer = "Checked `<file>` cleanly!```mermaid\nflowchart LR\n  A --> B\n```",
                    narration = listOf("Step $turnIdx"),
                    at = stamp
                )
            }
        }

        val merged = OrbSideAgent.mergeTurns(perThread)
        assertEquals(251, merged.size)
        assertEquals(251, merged.map { it.id }.toSet().size)
        assertTrue(merged.any { it.id == "btw:t24:0#1" })

        val visible0 = OrbTranscriptGates.visibleTurnCount(
            total = merged.size,
            baseLimit = OrbSideAgent.INITIAL_VISIBLE_TURNS,
            expandedSteps = 0,
            stepSize = OrbSideAgent.VISIBLE_TURNS_STEP
        )
        val hidden0 = OrbTranscriptGates.hiddenTurnCount(
            total = merged.size,
            baseLimit = OrbSideAgent.INITIAL_VISIBLE_TURNS,
            expandedSteps = 0,
            stepSize = OrbSideAgent.VISIBLE_TURNS_STEP
        )
        assertEquals(20, visible0)
        assertEquals(231, hidden0)
        assertEquals(
            60,
            OrbTranscriptGates.visibleTurnCount(
                total = merged.size,
                baseLimit = OrbSideAgent.INITIAL_VISIBLE_TURNS,
                expandedSteps = 2,
                stepSize = OrbSideAgent.VISIBLE_TURNS_STEP
            )
        )
    }

    @Test
    fun parseTurnsExtractsConversationalTurnsAndPreservesMaxSequence() {
        val events = listOf(
            OrbRow("e1", mapOf("sequence" to 10L, "event_type" to "user_message", "content" to "Ctx\n\nCurrent request:\nWhy did it fail?", "timestamp" to "2026-11-05T10:00:00Z", "client_message_id" to "c1")),
            OrbRow("e2", mapOf("sequence" to 42L, "event_type" to "assistant_message_canonical", "content" to "Inspecting logs.")),
            OrbRow("e3", mapOf("sequence" to 85L, "event_type" to "assistant_message", "content" to "The socket closed.")),
            OrbRow("e4", mapOf("sequence" to 90L, "event_type" to "user_message", "content" to "Queued?", "metadata" to mapOf("queued" to true)))
        )
        val parsed = OrbSideAgent.parseTurns(
            missionId = "m1",
            events = events,
            active = false
        )
        assertNull(parsed.open)
        assertEquals(1, parsed.turns.size)
        assertEquals("Why did it fail?", parsed.turns[0].question)
        assertEquals("The socket closed.", parsed.turns[0].answer)
        assertEquals(listOf("Inspecting logs."), parsed.turns[0].narration)
        assertTrue("c1" in parsed.deliveredIds)
        assertEquals(90L, parsed.maxSequence)
        assertEquals(
            listOf("user_message", "assistant_message", "assistant_message_canonical"),
            OrbSideAgent.transcriptEventTypes
        )
    }
}
