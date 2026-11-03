package sh.sandboxed.dashboard.orb

/**
 * Splits opening Markdown code fences glued to the end of a prose line without
 * a newline (e.g. `cleanly!```mermaid`).
 * Desktop parity: orb/src/codeFences.ts; iOS: OrbCodeFences.swift; cases in
 * shared/orb-spec/fixtures/glued-code-fences.json.
 */
object OrbCodeFences {
    data class GluedFence(val offset: Int, val lang: String)

    private fun isAsciiAlpha(c: Char): Boolean =
        c in 'A'..'Z' || c in 'a'..'z'

    private fun isFenceLangChar(c: Char): Boolean =
        isAsciiAlpha(c) || c in '0'..'9' || c == '_' || c == '+' || c == '.' || c == '#' || c == '-'

    fun splitGlued(line: String): GluedFence? {
        val cleanLen = if (line.endsWith('\r')) line.length - 1 else line.length
        if (cleanLen < 5 || !line.contains("```")) return null

        var lead = 0
        while (lead < cleanLen && (line[lead] == ' ' || line[lead] == '\t')) lead++
        if (lead >= cleanLen) return null

        val first = line[lead]
        if (first == '|' || first == '>') return null
        if ((first == '`' || first == '~') && lead + 2 < cleanLen && line[lead + 1] == first && line[lead + 2] == first) {
            return null
        }

        var i = lead
        while (i < cleanLen) {
            val ch = line[i]
            if (ch == '\\' && i + 1 < cleanLen) {
                i += 2
                continue
            }
            if (ch == '`') {
                val tickStart = i
                while (i < cleanLen && line[i] == '`') i++
                val ticks = i - tickStart

                var j = i
                var closedAt = -1
                while (j + ticks <= cleanLen) {
                    if (line[j] == '`') {
                        val runStart = j
                        while (j < cleanLen && line[j] == '`') j++
                        if (j - runStart == ticks) {
                            closedAt = runStart
                            break
                        }
                    } else {
                        j++
                    }
                }
                if (closedAt != -1) {
                    i = closedAt + ticks
                    continue
                }

                if (ticks == 3 && tickStart > lead && i < cleanLen && isAsciiAlpha(line[i])) {
                    var k = i + 1
                    while (k < cleanLen && isFenceLangChar(line[k])) k++
                    if (k - i <= 32) {
                        var m = k
                        while (m < cleanLen && (line[m] == ' ' || line[m] == '\t')) m++
                        if (m == cleanLen && line.substring(0, tickStart).trim().isNotEmpty()) {
                            return GluedFence(offset = tickStart, lang = line.substring(i, k))
                        }
                    }
                }
                continue
            }
            i++
        }
        return null
    }

    private fun hasGluedFence(src: String): Boolean {
        var nextTicks = src.indexOf("```", 0)
        if (nextTicks == -1) return false

        var inFence = false
        var lineStart = 0
        while (lineStart <= src.length) {
            val nl = src.indexOf('\n', lineStart)
            val lineEnd = if (nl == -1) src.length else nl
            while (nextTicks != -1 && nextTicks < lineStart) nextTicks = src.indexOf("```", lineStart)
            if (nextTicks == -1) break
            if (nextTicks < lineEnd) {
                val rawLine = src.substring(lineStart, lineEnd)
                if (rawLine.trim().startsWith("```")) {
                    inFence = !inFence
                } else if (!inFence && splitGlued(rawLine) != null) {
                    return true
                }
            }
            if (nl == -1) break
            lineStart = nl + 1
        }
        return false
    }

    fun normalize(src: String): String {
        if (!src.contains("```") || !hasGluedFence(src)) return src
        val lines = src.split("\n")
        val out = ArrayList<String>(lines.size + 2)
        var inFence = false
        for (line in lines) {
            if (line.trim().startsWith("```")) {
                inFence = !inFence
                out.add(line)
                continue
            }
            if (!inFence) {
                val glued = splitGlued(line)
                if (glued != null) {
                    out.add(line.substring(0, glued.offset))
                    out.add(line.substring(glued.offset))
                    inFence = true
                    continue
                }
            }
            out.add(line)
        }
        return out.joinToString("\n")
    }
}
