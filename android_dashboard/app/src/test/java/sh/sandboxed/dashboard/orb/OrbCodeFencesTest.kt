package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Replays shared/orb-spec/fixtures/glued-code-fences.json (desktop: orb/tests/code-fences.test.tsx). */
class OrbCodeFencesTest {
    private val cases = OrbJSON.dictList(OrbSpec.dict("fixtures/glued-code-fences.json")["cases"])
    private fun input(prefix: String) = cases.first { (it["name"] as String).startsWith(prefix) }["input"] as String

    @Test
    fun matchesSharedFixture() {
        check(cases.isNotEmpty())
        for (c in cases) {
            val name = c["name"] as String
            val output = c["output"] as String
            assertEquals(name, output, OrbCodeFences.normalize(c["input"] as String))
            assertEquals("$name idempotent", output, OrbCodeFences.normalize(output))
        }
    }

    @Test
    fun prodBtwReplySplitsMermaidAndPreservesTrailingSummary() {
        val blocks = parseMdBlocks(cleanRichText(input("prod c7a89ff3 seq 219"), streaming = false))
        val suffix = blocks.takeLast(4)
        assertEquals(4, suffix.size)

        val intro = suffix[0] as OrbMdBlock.Paragraph
        assertTrue(intro.text.endsWith("Let's present the updated diagram cleanly!"))
        assertFalse(intro.text.contains("```mermaid"))

        val diagram = suffix[1] as OrbMdBlock.CodeBlock
        assertEquals("mermaid", diagram.language)
        assertTrue(diagram.code.contains("flowchart TD"))
        assertTrue(diagram.code.contains("Z[\"Final certificate\"]"))

        val summary = suffix[2] as OrbMdBlock.Paragraph
        assertEquals("Changes at `HEAD` (`fc02f3ccc`):", summary.text)

        val bullets = suffix[3] as OrbMdBlock.ListBlock
        assertFalse(bullets.ordered)
        assertEquals(3, bullets.items.size)
    }

    @Test
    fun incrementalStreamingMatchesFullParseOnAllGluedCases() {
        for (c in cases) {
            val doc = c["input"] as String
            val name = c["name"] as String
            for (stride in listOf(1, 3, 7)) {
                val stream = OrbStreamBlocks()
                var end = 0
                while (end < doc.length) {
                    end = minOf(doc.length, end + stride)
                    val shown = doc.substring(0, end)
                    assertEquals("$name stride $stride: $shown", parseMdBlocks(shown), stream.blocks(shown))
                }
            }
        }
    }

    @Test
    fun largeGluedFenceStreamsInLinearCostAndMatchesFullParse() {
        val stream = OrbStreamBlocks()
        val acc = StringBuilder(64 * 1024 + 512)
        var lastBlocks: List<OrbMdBlock> = emptyList()
        for (k in 0 until 64) {
            val sb = StringBuilder()
            if (k == 0) sb.append("Updated diagram cleanly!```mermaid\nflowchart TD\n")
            var li = 0
            while (sb.length < 1024) {
                sb.append("  N${k}_${li} --> M${k}_${li}\n")
                li++
            }
            acc.append(sb.substring(0, 1024))
            lastBlocks = stream.blocks(cleanRichText(acc.toString(), streaming = true))
        }
        val openBytes = acc.toString().toByteArray(Charsets.UTF_8).size
        check(stream.scannedBytes <= openBytes) { "scannedBytes=${stream.scannedBytes} > openBytes=$openBytes" }
        check(stream.parsedBytes <= openBytes * 2) { "parsedBytes=${stream.parsedBytes} is superlinear for $openBytes bytes" }
        assertEquals(parseMdBlocks(cleanRichText(acc.toString(), streaming = false)), lastBlocks)

        acc.append("\n```\n\nChanges at HEAD:\n- Done\n\n")
        val closedBlocks = stream.blocks(cleanRichText(acc.toString(), streaming = false))
        assertEquals(parseMdBlocks(cleanRichText(acc.toString(), streaming = false)), closedBlocks)
    }

    @Test
    fun pipesInsideGluedFenceAreNotRewrittenAsLooseTable() {
        val raw = input("pipes inside a glued code fence")
        val blocks = parseMdBlocks(cleanRichText(raw, streaming = false))
        assertEquals(
            listOf(
                OrbMdBlock.Paragraph("Raw log:"),
                OrbMdBlock.CodeBlock("text", "a | b | c\nd | e | f"),
                OrbMdBlock.Paragraph("Summary."),
            ),
            blocks
        )
    }

    @Test
    fun inlinePreviewCutsBeforeGluedFence() {
        val src = "Let's present the updated diagram cleanly!```mermaid\nflowchart TD\n  A --> B\n  B --> C\n```\n"
        assertEquals("Let's present the updated diagram cleanly!", inlinePreview(src, limit = 65))
    }
}
