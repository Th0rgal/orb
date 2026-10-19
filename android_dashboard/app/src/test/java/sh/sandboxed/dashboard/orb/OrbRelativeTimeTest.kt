package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.Instant

class OrbRelativeTimeTest {
    private val now = Instant.parse("2026-10-19T12:00:00Z").toEpochMilli()

    @Test
    fun matchesSharedFixture() {
        val cases = OrbJSON.dictList(OrbSpec.dict("fixtures/relative-time.json")["cases"])
        check(cases.isNotEmpty())
        for (c in cases) {
            val ago = (c["secondsAgo"] as Number).toLong()
            val raw = Instant.ofEpochMilli(now - ago * 1000).toString()
            assertEquals("secondsAgo=$ago", c["expected"], OrbJSON.relative(raw, nowMs = now))
        }
    }

    @Test
    fun neverShowsZeroMinutes() {
        for (s in 45L..59L) assertEquals("1m", OrbJSON.relativeSeconds(s))
    }

    @Test
    fun unparseableDateIsEmpty() {
        assertEquals("", OrbJSON.relative("yesterday", nowMs = now))
        assertEquals("", OrbJSON.relative(null, nowMs = now))
    }
}
