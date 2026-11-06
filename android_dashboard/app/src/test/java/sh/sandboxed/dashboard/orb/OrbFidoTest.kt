package sh.sandboxed.dashboard.orb

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Before
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

class OrbFidoTest {
    private val event = """{"type":"fido_sign_request","request_id":"r1","key_type":"ed25519-sk","key_fingerprint":"SHA256:x","origin":"ssh:","hostname":"github.com","expires_at":"2026-10-19T12:01:00Z"}"""

    @Before
    fun setUp() {
        OrbLog.logcatEnabled = false
        OrbFido.clear()
    }

    @After
    fun tearDown() = OrbFido.clear()

    @Test
    fun parsesRequestFromNamedOrTypedEvent() {
        val a = OrbFido.parse("fido_sign_request", event)!!
        assertEquals("r1", a.requestId)
        assertEquals("github.com", a.hostname)
        assertNull(a.workspace)
        assertEquals(a, OrbFido.parse(null, event))
        assertEquals(a, OrbFido.parse("message", event))
    }

    @Test
    fun ignoresOtherEvents() {
        assertNull(OrbFido.parse("assistant_message", """{"request_id":"r1"}"""))
        assertNull(OrbFido.parse("fido_sign_request", """{"key_type":"x"}"""))
        assertNull(OrbFido.parse("fido_sign_request", "not json"))
    }

    @Test
    fun approveAndDenyMapToCoreRespondBody() {
        assertEquals("/api/fido/respond", OrbFido.RESPOND_PATH)
        assertEquals(mapOf("request_id" to "r1", "approved" to true), OrbFido.respondBody("r1", true))
        assertEquals(mapOf("request_id" to "r1", "approved" to false), OrbFido.respondBody("r1", false))
        assertEquals("""{"request_id":"r1","approved":false}""", OrbJSON.stringify(OrbFido.respondBody("r1", false)))
    }

    @Test
    fun queueDedupesResolvesAndExpires() {
        val r = OrbFido.parse(null, event)!!
        OrbFido.enqueue(r)
        OrbFido.enqueue(r)
        assertEquals(1, OrbFido.pending.value.size)
        OrbFido.dropExpired(nowMs = OrbJSON.dateEpochMs("2026-10-19T12:00:00Z")!!)
        assertEquals(1, OrbFido.pending.value.size)
        OrbFido.dropExpired(nowMs = OrbJSON.dateEpochMs("2026-10-19T12:02:00Z")!!)
        assertTrue(OrbFido.pending.value.isEmpty())
        OrbFido.enqueue(r)
        OrbFido.resolve("r1")
        assertTrue(OrbFido.pending.value.isEmpty())
    }

    @Test
    fun backoffIsCapped() {
        assertEquals(1_000L, OrbFido.backoffMs(0))
        assertEquals(4_000L, OrbFido.backoffMs(2))
        assertEquals(30_000L, OrbFido.backoffMs(10))
    }

    @Test
    fun streamIsFilteredToFido() = assertEquals("/api/control/stream?kinds=fido", OrbFido.STREAM_PATH)

    @Test
    fun parsesPendingList() {
        val body = OrbJSON.parse(
            """{"requests":[{"request_id":"p1","key_type":"ed25519-sk","key_fingerprint":"SHA256:x","origin":"ssh","hostname":null,"workspace":"w","expires_at":"2026-10-19T12:01:00Z"},{"key_type":"no id"}]}"""
        )
        val list = OrbFido.parsePending(body)
        assertEquals(listOf("p1"), list.map { it.requestId })
        assertEquals("w", list[0].workspace)
        assertTrue(OrbFido.parsePending(null).isEmpty())
        assertTrue(OrbFido.parsePending(OrbJSON.parse("""{"requests":[]}""")).isEmpty())
    }

    @Test
    fun respondResolvesOn200And404And410() = runBlocking {
        for (status in listOf(200, 404, 410)) {
            val r = OrbFido.parse(null, event)!!
            OrbFido.enqueue(r)
            val resolved = OrbFido.respond(
                OrbFido.Transport { path, body ->
                    assertEquals(OrbFido.RESPOND_PATH, path)
                    assertEquals(mapOf("request_id" to "r1", "approved" to true), body)
                    if (status == 200) emptyMap<String, Any?>() else throw OrbError("HTTP $status", status = status)
                },
                "r1",
                approved = true,
            )
            assertTrue(resolved)
            assertTrue(OrbFido.pending.value.isEmpty())
            assertNull(OrbFido.errors.value["r1"])
            assertTrue(OrbFido.inFlight.value.isEmpty())
        }
    }

    @Test
    fun respondResolvesOnlyExactStructuredAlreadyResolvedOn4xx() = runBlocking {
        val r = OrbFido.parse(null, event)!!
        OrbFido.enqueue(r)
        val nonTerminal5xx = OrbFido.respond(
            OrbFido.Transport { _, _ ->
                throw OrbError("already_resolved", status = 503, body = """{"error":"already_resolved"}""")
            },
            "r1",
            approved = true,
        )
        assertFalse(nonTerminal5xx)
        assertEquals(listOf("r1"), OrbFido.pending.value.map { it.requestId })
        assertEquals("already_resolved", OrbFido.errors.value["r1"])

        val nonTerminalPlain = OrbFido.respond(
            OrbFido.Transport { _, _ ->
                throw OrbError("already_resolved", status = 409, body = "request is already_resolved")
            },
            "r1",
            approved = true,
        )
        assertFalse(nonTerminalPlain)
        assertEquals(listOf("r1"), OrbFido.pending.value.map { it.requestId })

        val resolvedErrorField = OrbFido.respond(
            OrbFido.Transport { _, _ ->
                throw OrbError("already_resolved", status = 409, body = """{"error":"already_resolved"}""")
            },
            "r1",
            approved = true,
        )
        assertTrue(resolvedErrorField)
        assertTrue(OrbFido.pending.value.isEmpty())
        assertNull(OrbFido.errors.value["r1"])

        OrbFido.enqueue(r)
        val resolvedCodeField = OrbFido.respond(
            OrbFido.Transport { _, _ ->
                throw OrbError("conflict", status = 409, body = """{"code":"already_resolved"}""")
            },
            "r1",
            approved = false,
        )
        assertTrue(resolvedCodeField)
        assertTrue(OrbFido.pending.value.isEmpty())
    }

    @Test
    fun respondRetainsPendingOnIoExceptionAnd503ThenSucceedsOnRetry() = runBlocking {
        val r = OrbFido.parse(null, event)!!
        OrbFido.enqueue(r)
        var calls = 0
        val transport = OrbFido.Transport { _, _ ->
            when (++calls) {
                1 -> throw IOException("network unreachable")
                2 -> throw OrbError("Service Unavailable", status = 503, body = """{"error":"unavailable"}""")
                else -> emptyMap<String, Any?>()
            }
        }

        assertFalse(OrbFido.respond(transport, "r1", approved = true))
        assertEquals(listOf("r1"), OrbFido.pending.value.map { it.requestId })
        assertEquals("network unreachable", OrbFido.errors.value["r1"])

        assertFalse(OrbFido.respond(transport, "r1", approved = true))
        assertEquals(listOf("r1"), OrbFido.pending.value.map { it.requestId })
        assertEquals("Service Unavailable", OrbFido.errors.value["r1"])

        OrbFido.dropExpired(nowMs = OrbJSON.dateEpochMs("2026-10-19T12:02:00Z")!!)
        assertEquals(listOf("r1"), OrbFido.pending.value.map { it.requestId })

        assertTrue(OrbFido.respond(transport, "r1", approved = true))
        assertEquals(3, calls)
        assertTrue(OrbFido.pending.value.isEmpty())
        assertNull(OrbFido.errors.value["r1"])
    }

    @Test
    fun respondCancellationRetainsPendingAndClearsInFlight() = runBlocking {
        val r = OrbFido.parse(null, event)!!
        OrbFido.enqueue(r)
        val entered = CompletableDeferred<Unit>()
        val gate = CompletableDeferred<Unit>()
        val job = async {
            OrbFido.respond(
                OrbFido.Transport { _, _ ->
                    entered.complete(Unit)
                    gate.await()
                },
                "r1",
                approved = true,
            )
        }
        entered.await()
        assertTrue("r1" in OrbFido.inFlight.value)
        job.cancel()
        runCatching { job.await() }
        assertTrue(OrbFido.inFlight.value.isEmpty())
        assertEquals(listOf("r1"), OrbFido.pending.value.map { it.requestId })
        assertTrue(OrbFido.errors.value.containsKey("r1"))
    }

    @Test
    fun inFlightPreventsDuplicateRespondRequests() = runBlocking {
        val r = OrbFido.parse(null, event)!!
        OrbFido.enqueue(r)
        val entered = CompletableDeferred<Unit>()
        val gate = CompletableDeferred<Unit>()
        var calls = 0
        val transport = OrbFido.Transport { _, _ ->
            calls++
            entered.complete(Unit)
            gate.await()
            emptyMap<String, Any?>()
        }
        val first = async { OrbFido.respond(transport, "r1", approved = true) }
        entered.await()
        assertFalse(OrbFido.respond(transport, "r1", approved = true))
        assertEquals(1, calls)
        gate.complete(Unit)
        assertTrue(first.await())
        assertEquals(1, calls)
        assertTrue(OrbFido.pending.value.isEmpty())
    }
}
