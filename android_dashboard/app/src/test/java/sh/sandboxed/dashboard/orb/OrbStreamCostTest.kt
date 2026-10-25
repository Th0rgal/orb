package sh.sandboxed.dashboard.orb

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Text
import androidx.compose.ui.test.junit4.createComposeRule
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.coroutines.CoroutineContext

/**
 * Cost specs (shared/orb-spec/fixtures/stream-cost.json, from lean/Orb/Stream.lean §3-4):
 * bytes re-parsed, the text-keyed LRU, renders per frame, and which composables a stream
 * recomposes. iOS runs the same fixture in OrbStreamTextTests.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class OrbStreamCostTest {
    @get:Rule val rule = createComposeRule()
    private val spec = OrbSpec.dict("fixtures/stream-cost.json")

    /** Frames are driven by hand: this dispatcher never runs the timer. */
    private object NeverDispatcher : CoroutineDispatcher() {
        override fun dispatch(context: CoroutineContext, block: Runnable) {}
    }

    @Test
    fun reparsedBytesMatchLean() {
        val streams = OrbJSON.dictList(spec["streams"])
        check(streams.isNotEmpty())
        for (s in streams) {
            val doc = s["doc"] as String
            val stride = (s["stride"] as Number).toInt()
            val parser = OrbStreamBlocks()
            var end = 0
            var updates = 0
            while (end < doc.length) { end = minOf(doc.length, end + stride); updates++; parser.blocks(doc.substring(0, end)) }
            assertEquals((s["updates"] as Number).toInt(), updates)
            assertEquals("stride $stride: ${doc.take(30)}", (s["reparsedBytes"] as Number).toInt(), parser.parsedBytes)
            assertTrue(parser.parsedBytes <= (s["fullBytes"] as Number).toInt())
        }
    }

    @Test
    fun textCacheMatchesLean() {
        val c = OrbJSON.dict(spec["cache"])!!
        val cache = OrbTextCache<Int>((c["capacity"] as Number).toInt())
        val hits = mutableListOf<Boolean>()
        for (op in OrbJSON.dictList(c["ops"])) {
            val key = op["key"] as String
            if (op["op"] == "get") hits.add(cache.get(key) != null) else cache.put(key, 0)
            assertTrue(cache.size <= cache.capacity)
        }
        assertEquals(c["hits"], hits)
        assertEquals(c["keys"], cache.keys)
    }

    @Test
    fun rendersMatchLean() {
        val r = OrbJSON.dict(spec["renders"])!!
        val live = OrbLiveText(CoroutineScope(Job()), frameDispatcher = NeverDispatcher)
        for (ev in OrbJSON.dictList(r["events"])) {
            val d = ev["delta"] as? String
            if (d != null) live.append(d) else live.flush()
        }
        assertEquals((r["renders"] as Number).toInt(), live.renders)
        assertEquals(r["shown"], live.text)
        assertEquals(r["pending"], live.received.drop(live.text.length))
    }

    /** A screen that, like OrbConversation, reads only hasText recomposes on hasText changes; the bubble per frame. */
    @Test
    fun onlyTheBubbleRecomposesWhileStreaming() {
        val live = OrbLiveText(CoroutineScope(Job()), frameDispatcher = NeverDispatcher)
        OrbRenderProbe.counts.clear()
        rule.setContent {
            OrbRenderProbe.hit("probeScreen")
            Column {
                Text(if (live.hasText) "Writing…" else "Working…")
                if (live.hasText) OrbLiveReply(live, emptyList()) { Text(it) }
            }
        }
        rule.waitForIdle()
        val frames = 30
        repeat(frames) { i ->
            repeat(20) { live.append("w$i ") }
            rule.runOnIdle { live.flush() }
            rule.waitForIdle()
        }
        val screen = OrbRenderProbe.counts["probeScreen"] ?: 0
        val bubble = OrbRenderProbe.counts["liveReply"] ?: 0
        assertTrue("the bubble follows the stream ($bubble)", bubble >= frames / 2)
        assertTrue("at most one bubble recomposition per frame ($bubble)", bubble <= live.renders + 2)
        assertTrue("the screen recomposes on hasText changes only ($screen)", screen <= 3)
    }
}
