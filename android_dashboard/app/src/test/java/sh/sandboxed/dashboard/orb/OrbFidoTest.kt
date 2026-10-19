package sh.sandboxed.dashboard.orb

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbFidoTest {
    private val event = """{"type":"fido_sign_request","request_id":"r1","key_type":"ed25519-sk","key_fingerprint":"SHA256:x","origin":"ssh:","hostname":"github.com","expires_at":"2026-10-19T12:01:00Z"}"""

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
}
