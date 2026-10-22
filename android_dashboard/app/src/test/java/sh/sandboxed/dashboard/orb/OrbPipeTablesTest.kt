package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Replays shared/orb-spec/fixtures/loose-pipe-tables.json (desktop: orb/tests/pipe-tables.test.tsx). */
class OrbPipeTablesTest {
    private val cases = OrbJSON.dictList(OrbSpec.dict("fixtures/loose-pipe-tables.json")["cases"])
    private fun input(prefix: String) = cases.first { (it["name"] as String).startsWith(prefix) }["input"] as String

    @Test
    fun matchesSharedFixture() {
        check(cases.isNotEmpty())
        for (c in cases) {
            val output = c["output"] as String
            assertEquals(c["name"] as String, output, OrbPipeTables.normalize(c["input"] as String))
            assertEquals("${c["name"]} idempotent", output, OrbPipeTables.normalize(output))
        }
    }

    @Test
    fun prodUsageReplyParsesAsRightAlignedTable() {
        val blocks = parseMdBlocks(OrbPipeTables.normalize(input("prod 55518e2b")))
        assertEquals(2, blocks.size)
        val t = blocks[1] as OrbMdBlock.Table
        assertEquals(listOf("modèle", "input", "output", "cache read", "cache write", "USD", "appels"), t.headers)
        assertEquals(4, t.rows.size)
        assertEquals("3 915 038 024", t.rows[0][1])
        assertEquals(listOf(false, true, true, true, true, true, true), t.rightAligned)
    }

    @Test
    fun headerlessAndUntouchedCases() {
        val t = parseMdBlocks(OrbPipeTables.normalize(input("headerless")))[1] as OrbMdBlock.Table
        assertTrue(t.headers.all { it.isEmpty() })
        assertEquals(2, t.rows.size)
        for (name in listOf("mixed column", "single line", "pipes inside code fences", "GFM table is unchanged")) {
            assertEquals(name, input(name), OrbPipeTables.normalize(input(name)))
        }
    }

    @Test
    fun streamingNeverDropsATableOnceShown() {
        val text = input("prod 55518e2b")
        var seen = false
        for (n in 1..text.length) {
            val tables = parseMdBlocks(OrbPipeTables.normalize(text.substring(0, n))).count { it is OrbMdBlock.Table }
            if (seen) assertEquals("prefix $n", 1, tables)
            if (tables > 0) seen = true
        }
        assertTrue(seen)
    }
}
