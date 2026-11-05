package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Replays `shared/orb-spec/fixtures/background-sync-policy.json` and verifies direct
 * in-memory reduction of live `/api/control/sync` WebSocket frames into `OrbRow` events.
 */
class OrbBackgroundSyncTest {
    private fun loadFixture(): OrbDict {
        val specDir = System.getProperty("orb.spec.dir")
        val candidates = listOfNotNull(
            specDir?.let { File(it, "fixtures/background-sync-policy.json") },
            File("../shared/orb-spec/fixtures/background-sync-policy.json"),
            File("../../shared/orb-spec/fixtures/background-sync-policy.json"),
            File("shared/orb-spec/fixtures/background-sync-policy.json"),
        )
        val file = candidates.firstOrNull { it.exists() }
            ?: error("Could not locate shared/orb-spec/fixtures/background-sync-policy.json")
        return OrbJSON.dict(OrbJSON.parse(file.readText()))
            ?: error("Invalid JSON in background-sync-policy.json")
    }

    @Test
    fun matchesSharedConstantsAndNormalization() {
        val root = loadFixture()
        val constants = OrbJSON.dict(root["constants"])!!
        assertEquals((constants["maxWarmMissions"] as Number).toInt(), OrbBackgroundSyncPolicy.MAX_WARM_MISSIONS)
        assertEquals((constants["maxPayloadBytes"] as Number).toInt(), OrbReadCache.RESULT_KEEP_CHARS)
        assertEquals((constants["highRttThresholdMs"] as Number).toInt(), OrbBackgroundSyncPolicy.RTT_SLOW_THRESHOLD_MS)
        assertEquals((constants["highRttConsecutiveTrips"] as Number).toInt(), OrbBackgroundSyncPolicy.RTT_SLOW_STREAK_TO_PAUSE)
        assertEquals((constants["lowRttThresholdMs"] as Number).toInt(), OrbBackgroundSyncPolicy.RTT_FAST_THRESHOLD_MS)
        assertEquals((constants["lowRttConsecutiveRecover"] as Number).toInt(), OrbBackgroundSyncPolicy.RTT_FAST_STREAK_TO_RESUME)
        assertEquals((constants["recoveryCooldownMs"] as Number).toLong(), OrbBackgroundSyncPolicy.RESUME_COOLDOWN_MS)
        assertEquals((constants["disconnectWindowMs"] as Number).toLong(), OrbBackgroundSyncPolicy.DISCONNECT_WINDOW_MS)
        assertEquals((constants["disconnectBurstTrips"] as Number).toInt(), OrbBackgroundSyncPolicy.DISCONNECT_BURST_TO_PAUSE)

        val normCases = OrbJSON.dictList(root["normalization"])
        assertTrue(normCases.isNotEmpty())
        for (c in normCases) {
            val expected = OrbJSON.str(c, "expected")!!
            assertEquals(expected, OrbBackgroundSyncPolicy.normalizeMode(c["input"]).wireValue)
        }
    }

    @Test
    fun replaysSharedStateTransitions() {
        val root = loadFixture()
        val transitions = OrbJSON.dictList(root["stateTransitions"])
        assertFalse(transitions.isEmpty())

        for (tc in transitions) {
            val name = OrbJSON.str(tc, "name")!!
            var state = OrbBackgroundSyncPolicy.initialState(
                mode = OrbBackgroundSyncPolicy.normalizeMode(tc["mode"]),
                dataSaver = false,
            )
            for (ev in OrbJSON.dictList(tc["events"])) {
                state = when (val kind = OrbJSON.str(ev, "type")) {
                    "mode" -> OrbBackgroundSyncPolicy.reduce(
                        state,
                        OrbBackgroundSyncEvent.SetMode(OrbBackgroundSyncPolicy.normalizeMode(ev["mode"]))
                    )
                    "network" -> OrbBackgroundSyncPolicy.reduce(
                        state,
                        OrbBackgroundSyncEvent.SetDataSaver(
                            OrbJSON.bool(ev, "dataSaver") == true || OrbJSON.bool(ev, "slowLink") == true
                        )
                    )
                    "pong" -> OrbBackgroundSyncPolicy.reduce(
                        state,
                        OrbBackgroundSyncEvent.PingRtt(
                            rttMs = (ev["rttMs"] as Number).toInt(),
                            atMs = (ev["nowMs"] as Number).toLong(),
                        )
                    )
                    "lagged" -> OrbBackgroundSyncPolicy.reduce(
                        state,
                        OrbBackgroundSyncEvent.StreamLagged((ev["nowMs"] as Number).toLong())
                    )
                    "disconnect" -> OrbBackgroundSyncPolicy.reduce(
                        state,
                        OrbBackgroundSyncEvent.UnexpectedDisconnect((ev["nowMs"] as Number).toLong())
                    )
                    else -> error("Unknown fixture event $kind in $name")
                }
            }
            val expected = OrbJSON.dict(tc["expected"])!!
            assertEquals(name, OrbJSON.bool(expected, "active"), state.active)
            assertEquals(name, OrbJSON.str(expected, "reason"), state.reason)
        }
    }

    @Test
    fun replaysSharedWarmSelectionCases() {
        val root = loadFixture()
        val cases = OrbJSON.dictList(root["warmSelection"])
        assertFalse(cases.isEmpty())

        for (wc in cases) {
            val name = OrbJSON.str(wc, "name")!!
            val knownBtwMap = LinkedHashMap<String, String>()
            OrbJSON.dict(wc["btwByParent"])?.forEach { (k, v) ->
                if (v is String) knownBtwMap[k] = v
            }
            val selection = OrbBackgroundSyncPolicy.selectWarmMissionIds(
                backgroundActive = OrbJSON.bool(wc, "backgroundActive") == true,
                maxWarm = (wc["maxWarm"] as Number).toInt(),
                focusedIds = OrbJSON.strList(wc, "focusedIds"),
                recentIds = OrbJSON.strList(wc, "recentIds"),
                knownBtwByParent = knownBtwMap,
                focusedBtwParents = OrbJSON.strList(wc, "openBtwParentIds"),
            )
            assertEquals(name, OrbJSON.strList(wc, "expectedMissionIds"), selection.allStreamIds)
        }
    }

    @Test
    fun reducesLiveStreamFramesDirectlyWithoutHttpReload() {
        val mid = "m-android-live"
        val u1 = OrbLiveEventReducer.streamFrameToStoredRow(
            mid,
            "user_message",
            mapOf("id" to "u-1", "sequence" to 1L, "content" to "Run gradle test", "queued" to false)
        )
        val tc = OrbLiveEventReducer.streamFrameToStoredRow(
            mid,
            "tool_call",
            mapOf("sequence" to 2L, "tool_call_id" to "tc-1", "name" to "bash", "args" to mapOf("command" to "./gradlew test"))
        )
        val oversized = "z".repeat(8192)
        val tr = OrbLiveEventReducer.streamFrameToStoredRow(
            mid,
            "tool_result",
            mapOf("sequence" to 3L, "tool_call_id" to "tc-1", "name" to "bash", "result" to oversized, "is_error" to false)
        )
        val a4 = OrbLiveEventReducer.streamFrameToStoredRow(
            mid,
            "assistant_message",
            mapOf("id" to "a-4", "sequence" to 4L, "content" to "All unit tests passed.", "success" to true)
        )
        assertNotNull(u1)
        assertNotNull(tc)
        assertNotNull(tr)
        assertNotNull(a4)
        assertEquals(OrbReadCache.RESULT_KEEP_CHARS, tr!!.str("content")!!.length)

        val mergedEvents = OrbLiveEventReducer.mergeMissionEvents(emptyList(), listOf(u1!!, tc!!, tr, a4!!))
        assertEquals(4, mergedEvents.size)

        val history = OrbConversationHistory.visible(OrbConversationHistory.merge(emptyList(), mergedEvents))
        assertEquals(2, history.size)
        assertEquals("Run gradle test", history[0].str("content"))
        assertEquals("All unit tests passed.", history[1].str("content"))
    }

    @Test
    fun disambiguatesDuplicateBtwQuestionsAcrossReconciles() {
        val firstTurn = OrbSideAgent.Turn(
            id = "btw:3d7b16e7:83",
            question = "and now?",
            answer = "First status.",
            at = "2026-11-04T19:21:00Z"
        )
        val secondAskedAtMs = OrbJSON.dateEpochMs("2026-11-04T20:07:00Z")
        assertNotNull(secondAskedAtMs)
        assertFalse(
            OrbSideAgent.doesTurnAnswerPending(
                question = "and now?",
                localAskedAtMs = secondAskedAtMs,
                reconciledTurns = listOf(firstTurn),
                priorTurns = listOf(firstTurn)
            )
        )
        assertFalse(
            OrbSideAgent.doesTurnAnswerPending(
                question = "and now?",
                localAskedAtMs = secondAskedAtMs,
                reconciledTurns = listOf(firstTurn),
                priorTurns = emptyList()
            )
        )
        val secondTurn = OrbSideAgent.Turn(
            id = "btw:3d7b16e7:98",
            question = "and now?",
            answer = "Second status.",
            at = "2026-11-04T20:07:30Z"
        )
        assertTrue(
            OrbSideAgent.doesTurnAnswerPending(
                question = "and now?",
                localAskedAtMs = secondAskedAtMs,
                reconciledTurns = listOf(firstTurn, secondTurn),
                priorTurns = listOf(firstTurn)
            )
        )
    }
}
