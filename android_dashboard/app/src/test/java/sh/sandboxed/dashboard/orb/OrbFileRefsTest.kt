package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Shared-file markup (shared/orb-spec/file-references.json, real prod samples; iOS runs the same spec). */
class OrbFileRefsTest {
    private val spec = OrbSpec.dict("file-references.json")

    @Test
    fun parsesProdMarkupSamples() {
        val cases = OrbJSON.dictList(spec["cases"])
        assertTrue(cases.size >= 10)
        for (entry in cases) {
            val name = entry["name"] as String
            val input = entry["input"] as String
            val expected = OrbJSON.dictList(entry["refs"])
            val refs = OrbFileRefs.refs(input)
            assertEquals(name, expected.size, refs.size)
            refs.zip(expected).forEach { (ref, want) ->
                assertEquals(name, want["type"], ref.type)
                assertEquals(name, want["path"], ref.path)
                assertEquals(name, want["label"], ref.label)
                assertEquals(name, want["mime"], ref.mime)
            }
            assertEquals(name, entry["text"], OrbFileRefs.plainText(input))
            assertFalse("$name: no raw tag reaches the Markdown renderer", OrbFileRefs.segments(input).any {
                it is OrbFileSegment.Text && it.text.contains("<file path") && !it.text.contains("```")
            })
        }
    }

    @Test
    fun fileKindsMatchSpec() {
        OrbJSON.dict(spec["kinds"])!!.forEach { (name, kind) -> assertEquals(name, kind, OrbFileKind.of(name).key) }
        assertEquals(OrbFileKind.Pdf, OrbFileKind.of("download", "application/pdf"))
    }

    @Test
    fun sharedFilesMetadataEnrichesTag() {
        val shared = OrbJSON.dict(spec["sharedFiles"])!!
        val files = OrbFileRefs.sharedFiles(mapOf("shared_files" to shared["metadata"]))
        assertEquals(1, files.size)
        val expect = OrbJSON.dict(shared["expect"])!!
        val enriched = OrbFileRefs.enrich(OrbFileRefs.refs(shared["content"] as String).first(), files)
        assertEquals(expect["path"], enriched.path)
        assertEquals((expect["size"] as Number).toLong(), enriched.size)
        assertNotNull(enriched.url)
        assertTrue(files[0].sourcePath!!.endsWith("/mission-abf62858/pr31-receipt-refresh2.patch"))
    }

    @Test
    fun collectIsNewestFirstAndDeduplicated() {
        val messages = listOf(
            OrbFileRefs.Message("<file path=\"./a.txt\" name=\"Old A\" />", emptyList(), "2026-10-01T10:00:00Z", 1),
            OrbFileRefs.Message("<image path=\"./chart.png\" alt=\"Chart\" />\n<file path=\"a.txt\" name=\"New A\" />", emptyList(), "2026-10-02T10:00:00Z", 5),
            OrbFileRefs.Message("No tag here.", listOf(OrbSharedFile("out.zip", 10, "/api/fs/download?path=%2Fw%2Fout.zip", null)), "2026-10-03T10:00:00Z", 9)
        )
        val files = OrbFileRefs.collect(messages)
        assertEquals(listOf("out.zip", "chart.png", "a.txt"), files.map { it.name })
        assertEquals("New A", files.last().label)
        assertEquals("/w/out.zip", files.first().path)
        assertEquals(10L, files.first().size)
    }

    @Test
    fun eventsReplyShapes() {
        val row = mapOf(
            "event_type" to "assistant_message", "content" to "<file path=\"x.pdf\" />", "timestamp" to "t", "sequence" to 3,
            "metadata" to mapOf("shared_files" to listOf(mapOf("name" to "x.pdf", "size_bytes" to 2048, "url" to "/api/fs/download?path=%2Fx.pdf")))
        )
        for (reply in listOf<Any>(listOf(row), mapOf("events" to listOf(row)))) {
            val files = OrbFileRefs.collect(OrbFileRefs.messages(reply))
            assertEquals(1, files.size)
            assertEquals(2048L, files.first().size)
        }
    }

    @Test
    fun streamingHidesUnfinishedTag() {
        assertEquals(listOf(OrbFileSegment.Text("Here it is:")), OrbFileRefs.segments("Here it is:\n\n<file path=\"./rep", streaming = true))
    }

    @Test
    fun errorsMapToActionableCauses() {
        assertEquals(OrbFileError.MachineOffline, OrbFileError.from(502, "Remote file source is unreachable", "a"))
        assertEquals(OrbFileError.MachineOffline, OrbFileError.from(409, "Remote file source is unavailable", "a"))
        assertTrue(OrbFileError.from(404, "", "a") is OrbFileError.NotFound)
        assertEquals(OrbFileError.Unauthorized, OrbFileError.from(401, "", "a"))
        assertEquals(OrbFileError.Offline, OrbFileError.from(java.net.UnknownHostException("x"), "a"))
    }

    @Test
    fun highlighterAndCsv() {
        assertEquals(
            listOf(OrbCodeHighlight.Token.Keyword, OrbCodeHighlight.Token.Str, OrbCodeHighlight.Token.Comment),
            OrbCodeHighlight.tokens("let x = \"hi\" // note\n", "swift").map { it.second }
        )
        assertEquals(listOf(OrbCodeHighlight.Token.Comment, OrbCodeHighlight.Token.Number), OrbCodeHighlight.tokens("# c\nx = 1", "py").map { it.second })
        assertEquals(listOf(OrbCodeHighlight.Token.Added, OrbCodeHighlight.Token.Removed), OrbCodeHighlight.tokens("+a\n-b\n", "diff").map { it.second })
        assertEquals(listOf(listOf("a", "b"), listOf("x, y", "say \"hi\"")), OrbCSV.parse("a,b\n\"x, y\",\"say \"\"hi\"\"\"\n"))
        assertEquals(listOf(listOf("a", "b"), listOf("1", "2")), OrbCSV.parse("a\tb\n1\t2", '\t'))
        assertEquals("972 bytes", OrbFileRefs.formatSize(972))
        assertEquals("3.1 MB", OrbFileRefs.formatSize(3_146_240))
    }
}
