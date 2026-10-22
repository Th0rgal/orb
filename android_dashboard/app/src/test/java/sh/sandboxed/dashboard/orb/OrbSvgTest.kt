package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Agent SVGs (shared/orb-spec/svg-images.json; iOS runs the same spec in OrbSvgTests). */
class OrbSvgTest {
    private val spec = OrbSpec.dict("svg-images.json")

    @Test
    fun aspectRatioMatchesSharedSpec() {
        assertEquals(OrbSvg.limit, (spec["limit_bytes"] as Number).toInt())
        val cases = OrbJSON.dictList(spec["aspect"])
        assertTrue(cases.isNotEmpty())
        for (entry in cases) {
            val name = entry["name"] as String
            val ratio = OrbSvg.aspectRatio(entry["svg"] as String)
            val want = entry["ratio"] as? Number
            if (want == null) assertNull(name, ratio) else assertEquals(name, want.toDouble(), ratio!!, 0.0001)
        }
    }

    @Test
    fun hostileSvgIsOnlyEverAnInlineImage() {
        val hostile = """<svg xmlns="http://www.w3.org/2000/svg" onload="fetch('https://evil.test')"><script>alert(1)</script><image href="https://evil.test/x.png"/></svg>""".toByteArray()
        val html = OrbSvg.html(hostile)
        assertTrue(html.contains("default-src 'none'; img-src data:"))
        assertTrue(html.contains("<img alt=\"\" src=\"data:image/svg+xml;base64,${java.util.Base64.getEncoder().encodeToString(hostile)}\">"))
        assertFalse(html.contains("<script"))
        assertFalse(html.contains("evil.test"))
    }

    @Test
    fun readRefusesOversizedOrBinaryFiles() {
        val small = File.createTempFile("orb-svg", ".svg").apply { writeText("<svg/>") }
        val big = File.createTempFile("orb-svg", ".svg").apply { writeBytes(ByteArray(OrbSvg.limit + 1)) }
        val binary = File.createTempFile("orb-svg", ".svg").apply { writeBytes(byteArrayOf(0xFF.toByte(), 0xFE.toByte(), 0, 0xC3.toByte())) }
        try {
            assertEquals("<svg/>", OrbSvg.read(small)?.toString(Charsets.UTF_8))
            assertNull(OrbSvg.read(big))
            assertNull(OrbSvg.read(binary))
            assertEquals(OrbFileKind.Svg, OrbFileKind.of("logos/svg/maxwell.svg"))
        } finally { listOf(small, big, binary).forEach { it.delete() } }
    }
}
