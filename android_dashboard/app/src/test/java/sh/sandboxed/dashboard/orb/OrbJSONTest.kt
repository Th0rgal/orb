package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OrbJSONTest {
    @Test
    fun parseMapsNumbersAndNulls() {
        val d = OrbJSON.dict(OrbJSON.parse("""{"i":1,"big":10000000000,"f":1.5,"b":true,"n":null,"s":"x","a":[1,"y"]}"""))!!
        assertEquals(1, d["i"])
        assertEquals(10000000000L, d["big"])
        assertEquals(1.5, d["f"])
        assertEquals(true, d["b"])
        assertNull(d["n"])
        assertEquals(listOf(1, "y"), d["a"])
    }

    @Test
    fun invalidJsonIsNull() {
        assertNull(OrbJSON.parse("{nope"))
    }

    @Test
    fun stringifyRoundTrips() {
        val v = mapOf("a" to listOf(1, 2), "b" to mapOf("c" to "d"), "e" to null)
        assertEquals(v, OrbJSON.parse(OrbJSON.stringify(v)))
    }

    @Test
    fun typedAccessorsCoerce() {
        val d: OrbDict = mapOf("s" to "  ", "s2" to " v ", "n" to 3.9, "si" to "7", "bs" to "yes", "bn" to 0)
        assertEquals("v", OrbJSON.str(d, "s", "s2"))
        assertEquals("3", OrbJSON.str(d, "n"))
        assertEquals(7, OrbJSON.int(d, "si"))
        assertEquals(3, OrbJSON.int(d, "n"))
        assertEquals(true, OrbJSON.bool(d, "bs"))
        assertEquals(false, OrbJSON.bool(d, "bn"))
        assertNull(OrbJSON.str(null, "x"))
    }

    @Test
    fun listsAndDates() {
        assertEquals(listOf("a", "b"), OrbJSON.strList(mapOf("t" to listOf(" a ", "", 3, "b")), "t"))
        assertEquals(2, OrbJSON.dictList(listOf(mapOf("x" to 1), "no", mapOf("y" to 2))).size)
        assertEquals(0L, OrbJSON.dateEpochMs("1970-01-01T00:00:00Z"))
        assertEquals(1000L, OrbJSON.dateEpochMs("1970-01-01T00:00:01+00:00"))
        assertNull(OrbJSON.dateEpochMs("garbage"))
    }
}
