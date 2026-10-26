package sh.sandboxed.dashboard.orb

/**
 * Rewrites loose `a | b | c` pipe rows into GFM tables before Markdown parsing.
 * Desktop parity: orb/src/pipeTables.ts (rules documented there); iOS:
 * OrbPipeTables.swift; cases in shared/orb-spec/fixtures/loose-pipe-tables.json.
 */
object OrbPipeTables {
    private val numeric = Regex("^[+\\-−]?[$€£]?[0-9][0-9   ,.']*%?$")
    private val blockStart = Regex("^(#|>|[-*+]\\s|[0-9]+[.)]\\s)")
    private val separator = Regex("^:?-+:?$")

    fun isNumericCell(cell: String): Boolean {
        val t = cell.trim()
        val matches = numeric.matches(t)
        val hasDigit = t.any { it in '0'..'9' }
        return OrbKernel.numericCellAdmitted(
            nonEmpty = t.isNotEmpty(),
            hasLeadingDigitOrSign = matches,
            hasDigit = hasDigit,
            allAllowedChars = matches
        )
    }

    private fun isSpace(c: Char?) = c == ' ' || c == '\t'

    /** The cells of a loose row, or null when the line is not one. */
    fun cells(line: String): List<String>? {
        if (line.startsWith("    ") || line.startsWith("\t")) return null
        val t = line.trim()
        if (!t.contains('|') || t.startsWith("|") || blockStart.containsMatchIn(t)) return null
        var inCode = false
        var start = 0
        val out = mutableListOf<String>()
        for (i in t.indices) {
            val c = t[i]
            if (c == '`') inCode = !inCode
            else if (c == '|') {
                if (inCode) return null
                if (!isSpace(t.getOrNull(i - 1)) || !isSpace(t.getOrNull(i + 1))) return null
                out.add(t.substring(start, i).trim())
                start = i + 1
            }
        }
        out.add(t.substring(start).trim())
        return if (out.size >= 3 && !inCode) out else null
    }

    private fun row(cells: List<String>) = "| " + cells.joinToString(" | ") + " |"

    private fun gfm(rows: List<List<String>>): List<String> {
        val width = rows[0].size
        val hasHeader = rows[0].none { it.isNotEmpty() && isNumericCell(it) }
        val head = if (hasHeader) rows[0] else List(width) { "" }
        val body = if (hasHeader) rows.drop(1) else rows
        val aligns = (0 until width).map { col ->
            val cells = body.map { it.getOrElse(col) { "" } }.filter { it.isNotEmpty() }
            if (cells.isNotEmpty() && cells.all(::isNumericCell)) "---:" else "---"
        }
        return listOf(row(head), row(aligns)) + body.map { row(it + List(width - it.size) { "" }) }
    }

    private fun fenceMarker(line: String): String? {
        val t = line.trimStart(' ', '\t')
        val f = t.firstOrNull() ?: return null
        if (f != '`' && f != '~') return null
        val run = t.takeWhile { it == f }
        return if (run.length >= 3) run else null
    }

    fun normalize(src: String): String {
        if (!src.contains(" | ")) return src
        val lines = src.split("\n")
        val starts = IntArray(lines.size)
        for (k in 1 until lines.size) starts[k] = starts[k - 1] + lines[k - 1].length + 1
        fun admitted(k: Int, cells: List<String>, sepCols: Int): Boolean {
            val lead = lines[k].length - lines[k].trimStart().length
            return OrbKernel.gfmPipeRowAdmitted(starts[k] + lead, lines[k].trim().length, src.length, cells.size, sepCols)
        }
        val out = mutableListOf<String>()
        var fence: String? = null
        var i = 0
        while (i < lines.size) {
            val line = lines[i]
            val marker = fenceMarker(line)
            val open = fence
            if (open != null) {
                if (marker != null && marker[0] == open[0] && marker.length >= open.length) fence = null
                out.add(line); i++; continue
            }
            if (marker != null) { fence = marker; out.add(line); i++; continue }
            val first = cells(line)
            if (first == null || !admitted(i, first, first.size)) { out.add(line); i++; continue }
            val rows = mutableListOf(first)
            var j = i + 1
            while (j < lines.size) {
                val c = cells(lines[j])
                if (c == null || c.size != first.size || !admitted(j, c, first.size)) break
                rows.add(c); j++
            }
            val isGfm = rows.size >= 2 && rows[1].all { separator.matches(it.filterNot(Char::isWhitespace)) }
            if (rows.size < 2 || isGfm) {
                out.addAll(lines.subList(i, j)); i = j; continue
            }
            if (j == lines.size - 1 && lines[j].contains(" |")) {
                val t = lines[j].trim()
                val partial = t.split("|").map { it.trim() }
                if (partial.size < first.size && !t.startsWith("|")) { rows.add(partial); j++ }
            }
            if (out.isNotEmpty() && out.last().isNotBlank()) out.add("")
            out.addAll(gfm(rows))
            if (j < lines.size && lines[j].isNotBlank()) out.add("")
            i = j
        }
        return out.joinToString("\n")
    }
}
