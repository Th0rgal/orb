package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbRichTextRoutingTest {
    @Test fun rendererRoutingMatchesSharedFixture() {
        val spec = OrbSpec.dict("fixtures/rich-text-routing.json")
        for (c in OrbJSON.dictList(spec["cases"])) {
            val name = c["name"] as String
            val source = c["source"] as String
            assertEquals(name, c["web"], needsWebRenderer(source))
            if (c.containsKey("rich")) {
                assertEquals("$name (rich)", c["rich"], OrbMath.containsMathOrMedia(source))
            }
        }
    }

    @Test fun mathInlineDisplayCurrencyAndEscapedTableCells() {
        val source = """
            # Annual return
            The formula is \(r=(V_f/V_i)^{1/n}-1\), also ${'$'}x^2+y^2=z^2${'$'}.
            Prices are ${'$'}15 and ${'$'}20; VM cost is ${'$'}0.072/hr and cap is ${'$'}50.

            ${'$'}${'$'}
            \begin{aligned} r &= \frac{V_f}{V_i} \\ s &= \sqrt{2} \end{aligned}
            ${'$'}${'$'}

            \[
            \int_0^1 x^2\,dx=\frac{1}{3}
            \]

            | Name | Value | Empty |
            | --- | ---: | --- |
            | a\|b | `x` | |
        """.trimIndent()

        val blocks = parseMdBlocks(cleanRichText(source))
        val mathBlocks = blocks.filterIsInstance<OrbMdBlock.MathBlock>()
        assertEquals(2, mathBlocks.size)
        assertTrue(mathBlocks.all { it.complete })

        val aligned = OrbMath.formatLatex(mathBlocks[0].latex, complete = true)
        assertTrue(aligned.valid)
        assertTrue(aligned.text.contains("√2"))

        val integral = OrbMath.formatLatex(mathBlocks[1].latex, complete = true)
        assertTrue(integral.valid)
        assertTrue(integral.text.contains("∫"))
        assertTrue(integral.text.contains("1/3"))

        val paraPlain = blocks.filterIsInstance<OrbMdBlock.Paragraph>()
            .joinToString("\n") { parseInlineAnnotated(it.text).text }
        assertTrue(paraPlain.contains("${'$'}15 and ${'$'}20"))
        assertTrue(paraPlain.contains("${'$'}0.072/hr and cap is ${'$'}50"))
        assertTrue(paraPlain.contains("x²+y²=z²"))

        val table = blocks.filterIsInstance<OrbMdBlock.Table>().single()
        assertEquals(listOf("Name", "Value", "Empty"), table.headers)
        assertEquals(listOf("a|b", "`x`", ""), table.rows.first())
        assertEquals(listOf(false, true, false), table.rightAligned)
    }

    @Test fun unsafeLinksAndMalformedOrBoundedMathDegradeCleanly() {
        val unsafeTokens = OrbMath.tokenizeInline("[bad](javascript:alert(1)) and [data](data:text/html,x)")
        val links = unsafeTokens.filterIsInstance<OrbInlineToken.Link>()
        assertEquals(2, links.size)
        assertTrue(links.none { it.isSafe })

        val hrefMath = OrbMath.formatLatex("""\href{javascript:alert(1)}{unsafe}""", complete = true)
        assertEquals("unsafe", hrefMath.text)

        val incomplete = OrbMath.formatLatex("""\frac{""", complete = false)
        assertFalse(incomplete.valid)
        assertTrue(incomplete.text.isNotEmpty())

        val deep = "{".repeat(40) + "x" + "}".repeat(40)
        val deepRes = OrbMath.formatLatex(deep, complete = true)
        assertFalse(deepRes.valid)
        assertTrue(deepRes.text.isNotEmpty())

        val huge = "x + ".repeat(3000)
        val hugeRes = OrbMath.formatLatex(huge, complete = true)
        assertFalse(hugeRes.valid)
        assertTrue(hugeRes.text.length <= 260)

        // Streaming math prefixes must not evict settled math cache entries.
        OrbMath.formatCached("E = mc^2", complete = true, streaming = false)
        assertTrue(OrbMath.cache.get("1:E = mc^2") != null)
        for (i in 0 until 600) {
            OrbMath.formatCached("x_$i + \\frac{1}{${i + 1}}", complete = false, streaming = true)
            OrbMath.formatCached("x_$i + \\frac{1}{${i + 1}}", complete = true, streaming = true)
        }
        assertTrue(OrbMath.cache.get("1:E = mc^2") != null)
    }
}
