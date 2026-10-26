package sh.sandboxed.dashboard.orb

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Android event builder and queue against shared/orb-spec/fixtures/usage-telemetry.json. */
class UsageTelemetryTest {
    private val spec = OrbSpec.dict("fixtures/usage-telemetry.json")
    private val schemas = OrbJSON.dict(spec["schemas"])!!
    private val ident = Regex(spec["ident_pattern"] as String)

    private fun list(schema: String, key: String) = (OrbJSON.dict(schemas[schema])!![key] as List<*>).map { it as String }

    private class FakeTransport(var fail: Boolean = false, var active: Boolean = true) : UsageTelemetry.Transport {
        val sent = mutableListOf<List<OrbDict>>()
        override suspend fun status(): OrbDict = mapOf("enabled" to active, "active" to active)
        override suspend fun send(events: List<OrbDict>): Boolean {
            if (fail) error("offline")
            sent += events
            return true
        }
    }

    @Test
    fun enumWireNamesMatchFixture() {
        assertEquals(list("orb.action.v1", "action"), UsageTelemetry.Action.entries.map { it.wire })
        assertEquals(list("orb.approval.v1", "kind"), UsageTelemetry.ApprovalKind.entries.map { it.wire })
        assertEquals(list("orb.approval.v1", "decision"), UsageTelemetry.Decision.entries.map { it.wire })
        assertEquals(list("orb.approval.v1", "method"), UsageTelemetry.Method.entries.map { it.wire })
        assertEquals(list("orb.page.v1", "surface"), UsageTelemetry.Surface.entries.map { it.wire })
        assertTrue(UsageTelemetry.CLIENT in (spec["clients"] as List<*>))
    }

    @Test
    fun builtEventsUseOnlyAllowlistedKeys() {
        val q = UsageTelemetry.Queue(FakeTransport(), "1.15.0-dev")
        val common = OrbJSON.dict(spec["common"])!!.keys
        val events = listOf(
            q.page("settings.telemetry", UsageTelemetry.Surface.Sheet, "command palette", 1500),
            q.action(UsageTelemetry.Action.Fork, "composer"),
            q.approval(UsageTelemetry.ApprovalKind.Grant, UsageTelemetry.Decision.Approved, UsageTelemetry.Method.TouchId, 4200, "ssh_sign", null),
        )
        for (e in events) {
            val schema = e["schema"] as String
            assertTrue(schema in (spec["client_schemas"] as List<*>))
            val allowed = common + OrbJSON.dict(schemas[schema])!!.keys
            assertTrue("$schema: ${e.keys - allowed}", allowed.containsAll(e.keys))
            assertEquals("android", e["client"])
            assertFalse(e.containsKey("quick_close"))
            for (k in listOf("event_id", "ts", "app_version", "screen", "entry_point", "surface", "tool_name", "command_class")) {
                (e[k] as? String)?.let { assertTrue("$k=$it", ident.matches(it)) }
            }
            val fields = OrbJSON.dict(schemas[schema])!!
            for ((k, v) in fields) when (v) {
                "uint" -> (e[k] as? Number)?.let { assertTrue(it.toLong() >= 0) }
                is List<*> -> e[k]?.let { assertTrue("$k=$it", it in v) }
            }
        }
        assertFalse("free text entry point is dropped", events[0].containsKey("entry_point"))
        assertEquals(1500L, events[0]["dwell_ms"])
    }

    @Test
    fun nothingQueuedWhileInactive() = runBlocking {
        val t = FakeTransport(active = false)
        val q = UsageTelemetry.Queue(t, "1")
        assertFalse(q.enqueue(q.action(UsageTelemetry.Action.Btw, null)))
        assertEquals(0, q.queued)
        q.refresh()
        assertFalse(q.active)
        q.enqueue(q.action(UsageTelemetry.Action.Btw, null))
        assertEquals(0, q.queued)
        q.flush()
        assertTrue(t.sent.isEmpty())
    }

    @Test
    fun failedFlushKeepsEventsAndRetries() = runBlocking {
        val t = FakeTransport(fail = true)
        val q = UsageTelemetry.Queue(t, "1")
        q.refresh()
        repeat(3) { q.enqueue(q.action(UsageTelemetry.Action.Queue, "composer")) }
        assertFalse(q.flush())
        assertEquals(3, q.queued)
        t.fail = false
        assertTrue(q.flush())
        assertEquals(0, q.queued)
        assertEquals(3, t.sent.flatten().size)
    }

    @Test
    fun batchesAndCapsQueue() = runBlocking {
        val t = FakeTransport(fail = true)
        val q = UsageTelemetry.Queue(t, "1")
        q.refresh()
        var full = false
        repeat(UsageTelemetry.BATCH_SIZE) { full = q.enqueue(q.action(UsageTelemetry.Action.Fork, null)) }
        assertTrue(full)
        repeat(UsageTelemetry.MAX_QUEUE) { q.enqueue(q.action(UsageTelemetry.Action.Fork, null)) }
        assertEquals(UsageTelemetry.MAX_QUEUE, q.queued)
        t.fail = false
        q.flush()
        assertEquals(listOf(50, 50, 50, 50, 50, 50, 50, 50, 50, 50), t.sent.map { it.size })
    }
}
