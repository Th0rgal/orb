package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OrbParityTest {
    @Test fun presentationKeepsBothAnswerFormsAndExcludesQueuedPrompts() {
        for (type in listOf("assistant_message", "assistant_message_canonical")) {
            val rows = OrbPresentation.history(mapOf("events" to listOf(
                mapOf("event_type" to type, "content" to "Final answer", "sequence" to 1),
                mapOf("event_type" to "user_message", "content" to "Next", "metadata" to mapOf("queued" to true)),
                mapOf("event_type" to "tool_result", "content" to "Large output")
            )))
            assertEquals(1, rows.size)
            assertEquals("Final answer", rows.first().str("content"))
        }
    }

    @Test
    fun messageImagesStripOwnLineMarkers() {
        val parsed = OrbMessageImages.parse("Here is the chart:\n[Image #1] [Uploaded: /tmp/chart.png]\nDone.")
        assertEquals(listOf("/tmp/chart.png"), parsed.paths)
        assertEquals(listOf(1), parsed.references)
        assertEquals("Here is the chart:\n\nDone.", parsed.text)
    }

    @Test
    fun messageImagesKeepInlineReference() {
        val parsed = OrbMessageImages.parse("See [Image #2] [Uploaded: ./a.jpg] above")
        assertEquals("See [Image #2] above", parsed.text)
    }

    @Test
    fun messageImagesIgnoreNonImages() {
        val source = "Log at [Uploaded: /tmp/out.txt]"
        val parsed = OrbMessageImages.parse(source)
        assertEquals(source, parsed.text)
        assertEquals(emptyList<String>(), parsed.paths)
    }

    @Test
    fun missionCommandsParse() {
        assertEquals(OrbMissionCommand.Btw to "why?", OrbMissionCommand.parse("/btw why?"))
        assertEquals(OrbMissionCommand.Pause to "", OrbMissionCommand.parse("/pause"))
        assertNull(OrbMissionCommand.parse("/btwx hi"))
        assertNull(OrbMissionCommand.parse("/plan do it"))
    }

    @Test
    fun boundedReadRejectsOversizedStreams() {
        val data = ByteArray(100) { it.toByte() }
        assertEquals(100, OrbRemoteImageLoader.readBounded(data.inputStream(), 100)?.size)
        assertNull(OrbRemoteImageLoader.readBounded(data.inputStream(), 99))
    }
}
