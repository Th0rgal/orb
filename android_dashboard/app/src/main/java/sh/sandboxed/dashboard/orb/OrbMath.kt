package sh.sandboxed.dashboard.orb

data class OrbMathResult(
    val text: String,
    val valid: Boolean
)

sealed class OrbInlineToken {
    data class Text(val text: String) : OrbInlineToken()
    data class Code(val code: String) : OrbInlineToken()
    data class Bold(val inner: String) : OrbInlineToken()
    data class Italic(val inner: String) : OrbInlineToken()
    data class Link(val label: String, val url: String, val isSafe: Boolean, val isArtifact: Boolean) : OrbInlineToken()
    data class Image(val alt: String, val url: String) : OrbInlineToken()
    data class Math(val latex: String, val display: Boolean, val complete: Boolean) : OrbInlineToken()
}

object OrbMath {
    const val MAX_DEPTH = 16
    const val MAX_SPAN_CHARS = 8192

    val cache = OrbTextCache<OrbMathResult>(512)

    fun usesWebRenderer(@Suppress("UNUSED_PARAMETER") source: String): Boolean = false

    fun isSafeHref(raw: String): Boolean {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return false
        val lower = trimmed.lowercase()
        if (lower.startsWith("javascript:") || lower.startsWith("data:") || lower.startsWith("vbscript:")) {
            return false
        }
        return true
    }

    fun isArtifactHref(raw: String): Boolean {
        val t = raw.trim()
        return t.startsWith("file:///") ||
            t.startsWith("sandbox:") ||
            t.startsWith("/mnt/data/") ||
            t.startsWith("/workspace/") ||
            t.startsWith("/srv/") ||
            t.startsWith("/Users/") ||
            t.startsWith("/root/") ||
            t.startsWith("/home/") ||
            t.startsWith("/var/") ||
            t.startsWith("/tmp/")
    }

    fun containsMathOrMedia(source: String): Boolean {
        if (!source.contains('$') && !source.contains("\\(") && !source.contains("\\[") && !source.contains("![")) {
            return false
        }
        var inFence = false
        for (rawLine in source.split("\n")) {
            val trimmed = rawLine.trim()
            if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) {
                inFence = !inFence
                continue
            }
            if (inFence) continue
            for (token in tokenizeInline(rawLine)) {
                if (token is OrbInlineToken.Math || token is OrbInlineToken.Image) return true
            }
        }
        return false
    }

    /**
     * Pandoc-aligned inline `$...$` delimiter check:
     * - Opening `$` not preceded by `\`, `$`, or ASCII alphanumeric; not followed by whitespace or `$`.
     * - Closing `$` not preceded by `\` or whitespace; not followed by `$` or ASCII digit (`$15 and $20`).
     * - Rejects multi-word prose starting with a digit when no math operator is present.
     */
    fun findClosingInlineDollar(text: String, openIdx: Int): Int {
        val n = text.length
        if (openIdx < 0 || openIdx + 2 > n || text[openIdx] != '$') return -1
        if (openIdx > 0) {
            val prev = text[openIdx - 1]
            if (prev == '\\' || prev == '$' || prev.isLetterOrDigit()) return -1
        }
        val firstInner = text[openIdx + 1]
        if (firstInner == '$' || firstInner.isWhitespace()) return -1

        var i = openIdx + 1
        while (i < n && i - (openIdx + 1) <= MAX_SPAN_CHARS) {
            val ch = text[i]
            if (ch == '\n') return -1
            if (ch == '\\') {
                i += 2
                continue
            }
            if (ch == '$') {
                val prev = text[i - 1]
                val next = if (i + 1 < n) text[i + 1] else '\u0000'
                if (!prev.isWhitespace() && next != '$' && !next.isDigit()) {
                    val inner = text.substring(openIdx + 1, i)
                    if (admitsInlineDollarBody(inner)) return i
                    return -1
                }
            }
            i++
        }
        return -1
    }

    fun admitsInlineDollarBody(inner: String): Boolean {
        if (inner.isEmpty() || inner.length > MAX_SPAN_CHARS) return false
        if (inner.first().isWhitespace() || inner.last().isWhitespace()) return false
        if (inner.first().isDigit() && inner.any { it.isWhitespace() }) {
            val hasMathOp = inner.any { it in "\\^_{}=+-*/<>|" }
            if (!hasMathOp) return false
        }
        return true
    }

    fun tokenizeInline(raw: String, depth: Int = 0): List<OrbInlineToken> {
        if (raw.isEmpty() || depth > 6) return if (raw.isEmpty()) emptyList() else listOf(OrbInlineToken.Text(raw))
        val out = mutableListOf<OrbInlineToken>()
        val plain = StringBuilder()
        fun flushPlain() {
            if (plain.isNotEmpty()) {
                out.add(OrbInlineToken.Text(plain.toString()))
                plain.setLength(0)
            }
        }

        var i = 0
        val n = raw.length
        while (i < n) {
            val ch = raw[i]

            // Escaped dollar `\$` renders as literal `$`
            if (ch == '\\' && i + 1 < n && raw[i + 1] == '$') {
                plain.append('$')
                i += 2
                continue
            }

            // Inline code span `...`
            if (ch == '`') {
                var ticks = 1
                while (i + ticks < n && raw[i + ticks] == '`') ticks++
                val fence = raw.substring(i, i + ticks)
                val end = raw.indexOf(fence, i + ticks)
                if (end >= 0) {
                    flushPlain()
                    out.add(OrbInlineToken.Code(raw.substring(i + ticks, end)))
                    i = end + ticks
                    continue
                }
            }

            // Inline/display `$$...$$`
            if (ch == '$' && i + 1 < n && raw[i + 1] == '$') {
                val close = raw.indexOf("$$", i + 2)
                if (close >= 0 && close - (i + 2) <= MAX_SPAN_CHARS) {
                    flushPlain()
                    out.add(OrbInlineToken.Math(raw.substring(i + 2, close), display = true, complete = true))
                    i = close + 2
                    continue
                }
            }

            // Parenthesized math `\(...\)`
            if (ch == '\\' && i + 1 < n && raw[i + 1] == '(') {
                val close = raw.indexOf("\\)", i + 2)
                flushPlain()
                if (close >= 0 && close - (i + 2) <= MAX_SPAN_CHARS) {
                    out.add(OrbInlineToken.Math(raw.substring(i + 2, close), display = false, complete = true))
                    i = close + 2
                } else {
                    val rest = raw.substring(i + 2).take(MAX_SPAN_CHARS)
                    out.add(OrbInlineToken.Math(rest, display = false, complete = false))
                    i = n
                }
                continue
            }

            // Bracketed math `\[...\]`
            if (ch == '\\' && i + 1 < n && raw[i + 1] == '[') {
                val close = raw.indexOf("\\]", i + 2)
                flushPlain()
                if (close >= 0 && close - (i + 2) <= MAX_SPAN_CHARS) {
                    out.add(OrbInlineToken.Math(raw.substring(i + 2, close), display = true, complete = true))
                    i = close + 2
                } else {
                    val rest = raw.substring(i + 2).take(MAX_SPAN_CHARS)
                    out.add(OrbInlineToken.Math(rest, display = true, complete = false))
                    i = n
                }
                continue
            }

            // Inline dollar `$...$`
            if (ch == '$') {
                val close = findClosingInlineDollar(raw, i)
                if (close > i) {
                    flushPlain()
                    out.add(OrbInlineToken.Math(raw.substring(i + 1, close), display = false, complete = true))
                    i = close + 1
                    continue
                }
            }

            // Inline image `![alt](url)`
            if (ch == '!' && i + 1 < n && raw[i + 1] == '[') {
                val closeBracket = raw.indexOf(']', i + 2)
                if (closeBracket >= i + 2 && closeBracket + 1 < n && raw[closeBracket + 1] == '(') {
                    val closeParen = raw.indexOf(')', closeBracket + 2)
                    if (closeParen > closeBracket + 1) {
                        val alt = raw.substring(i + 2, closeBracket)
                        val url = raw.substring(closeBracket + 2, closeParen).trim()
                        flushPlain()
                        out.add(OrbInlineToken.Image(alt, url))
                        i = closeParen + 1
                        continue
                    }
                }
            }

            // Link `[label](url)`
            if (ch == '[') {
                val closeBracket = raw.indexOf(']', i + 1)
                if (closeBracket > i && closeBracket + 1 < n && raw[closeBracket + 1] == '(') {
                    val closeParen = raw.indexOf(')', closeBracket + 2)
                    if (closeParen > closeBracket + 1) {
                        val label = raw.substring(i + 1, closeBracket)
                        val url = raw.substring(closeBracket + 2, closeParen).trim()
                        flushPlain()
                        out.add(
                            OrbInlineToken.Link(
                                label = label,
                                url = url,
                                isSafe = isSafeHref(url),
                                isArtifact = isArtifactHref(url)
                            )
                        )
                        i = closeParen + 1
                        continue
                    }
                }
            }

            // Bold `**...**`
            if (ch == '*' && i + 1 < n && raw[i + 1] == '*') {
                val end = raw.indexOf("**", i + 2)
                if (end > i + 2) {
                    flushPlain()
                    out.add(OrbInlineToken.Bold(raw.substring(i + 2, end)))
                    i = end + 2
                    continue
                }
            }

            // Italic `*...*` (non-whitespace bounded)
            if (ch == '*' && i + 1 < n && !raw[i + 1].isWhitespace() && raw[i + 1] != '*') {
                val end = raw.indexOf('*', i + 1)
                if (end > i + 1 && !raw[end - 1].isWhitespace()) {
                    flushPlain()
                    out.add(OrbInlineToken.Italic(raw.substring(i + 1, end)))
                    i = end + 1
                    continue
                }
            }

            plain.append(ch)
            i++
        }
        flushPlain()
        return out
    }

    fun formatCached(latex: String, complete: Boolean = true, streaming: Boolean = false): OrbMathResult {
        val trimmed = latex.trim()
        if (!complete || trimmed.length > MAX_SPAN_CHARS) {
            return formatLatex(trimmed, complete = false)
        }
        if (!streaming) {
            cache.get(trimmed)?.let { return it }
        }
        val rendered = formatLatex(trimmed, complete = true)
        if (!streaming) {
            cache.put(trimmed, rendered)
        }
        return rendered
    }

    fun formatLatex(latex: String, complete: Boolean = true): OrbMathResult {
        val trimmed = latex.trim()
        if (trimmed.isEmpty()) return OrbMathResult("", valid = complete)
        if (!complete || trimmed.length > MAX_SPAN_CHARS) {
            val partial = runCatching { Parser(trimmed.take(MAX_SPAN_CHARS)).parseExpr(0) }.getOrNull()
            return OrbMathResult(partial?.ifEmpty { trimmed.take(256) } ?: trimmed.take(256), valid = false)
        }
        val parser = Parser(trimmed)
        val out = parser.parseExpr(0)
        if (parser.pos < trimmed.length) {
            parser.valid = false
        }
        return OrbMathResult(if (parser.valid && out.isNotEmpty()) out else out.ifEmpty { trimmed }, valid = parser.valid)
    }

    private class Parser(val src: String) {
        var pos = 0
        var valid = true

        fun parseExpr(depth: Int, stopAtBrace: Boolean = false): String {
            if (depth > MAX_DEPTH) {
                valid = false
                val start = pos
                pos = src.length
                return src.substring(start)
            }
            val sb = StringBuilder()
            while (pos < src.length) {
                val ch = src[pos]
                if (ch == '}') {
                    if (stopAtBrace) {
                        pos++
                        return sb.toString()
                    }
                    valid = false
                    pos++
                    continue
                }
                if (ch == '{') {
                    pos++
                    val startBefore = pos
                    val inner = parseExpr(depth + 1, stopAtBrace = true)
                    if (startBefore <= src.length && (pos == src.length && (src.isEmpty() || src.last() != '}'))) {
                        // Checked precisely inside group helper below
                    }
                    sb.append(inner)
                    continue
                }
                if (ch == '^' || ch == '_') {
                    val isSup = ch == '^'
                    pos++
                    val arg = readScriptArg(depth + 1)
                    if (arg.isEmpty()) {
                        valid = false
                        sb.append(ch)
                    } else {
                        sb.append(formatScript(arg, isSup))
                    }
                    continue
                }
                if (ch == '&') {
                    pos++
                    if (sb.isNotEmpty() && sb.last() != ' ') sb.append(' ')
                    continue
                }
                if (ch == '~') {
                    pos++
                    sb.append('\u00A0')
                    continue
                }
                if (ch == '\\') {
                    pos++
                    if (pos >= src.length) {
                        valid = false
                        sb.append('\\')
                        break
                    }
                    val next = src[pos]
                    if (!next.isLetter()) {
                        pos++
                        when (next) {
                            '\\' -> sb.append('\n')
                            ',', ';', ':' -> sb.append(' ')
                            '!' -> Unit
                            '{', '}', '$', '%', '&', '#', '_' -> sb.append(next)
                            ' ' -> sb.append(' ')
                            '|' -> sb.append('‖')
                            else -> sb.append(next)
                        }
                        continue
                    }
                    val cmdStart = pos
                    while (pos < src.length && src[pos].isLetter()) pos++
                    val cmd = src.substring(cmdStart, pos)
                    handleCommand(cmd, depth, sb)
                    continue
                }
                if (ch.isWhitespace()) {
                    while (pos < src.length && src[pos].isWhitespace()) pos++
                    if (sb.isNotEmpty() && sb.last() != ' ' && sb.last() != '\n') sb.append(' ')
                    continue
                }
                sb.append(ch)
                pos++
            }
            if (stopAtBrace) {
                valid = false
            }
            return sb.toString().trim()
        }

        private fun skipSpaces() {
            while (pos < src.length && src[pos].isWhitespace()) pos++
        }

        private fun readMandatoryGroup(depth: Int): String? {
            skipSpaces()
            if (pos >= src.length) {
                valid = false
                return null
            }
            if (src[pos] == '{') {
                pos++
                val savedValid = valid
                val body = parseExpr(depth + 1, stopAtBrace = true)
                if (!valid && savedValid) return body
                return body
            }
            if (src[pos] == '\\') {
                val sub = StringBuilder()
                pos++
                if (pos >= src.length) {
                    valid = false
                    return null
                }
                if (!src[pos].isLetter()) {
                    val c = src[pos++]
                    return c.toString()
                }
                val s = pos
                while (pos < src.length && src[pos].isLetter()) pos++
                handleCommand(src.substring(s, pos), depth + 1, sub)
                return sub.toString()
            }
            return src[pos++].toString()
        }

        private fun readOptionalBracket(depth: Int): String? {
            skipSpaces()
            if (pos >= src.length || src[pos] != '[') return null
            val close = src.indexOf(']', pos + 1)
            if (close < 0) {
                valid = false
                return null
            }
            val inner = src.substring(pos + 1, close)
            pos = close + 1
            return if (depth <= MAX_DEPTH) Parser(inner).parseExpr(depth + 1) else inner
        }

        private fun readScriptArg(depth: Int): String {
            skipSpaces()
            if (pos >= src.length) return ""
            return readMandatoryGroup(depth) ?: ""
        }

        private fun readRawBraceName(): String? {
            skipSpaces()
            if (pos >= src.length || src[pos] != '{') {
                valid = false
                return null
            }
            val close = src.indexOf('}', pos + 1)
            if (close < 0) {
                valid = false
                pos = src.length
                return null
            }
            val name = src.substring(pos + 1, close).trim()
            pos = close + 1
            return name
        }

        private fun handleCommand(cmd: String, depth: Int, sb: StringBuilder) {
            when (cmd) {
                "frac", "dfrac", "tfrac" -> {
                    val num = readMandatoryGroup(depth + 1)
                    val den = readMandatoryGroup(depth + 1)
                    if (num == null || den == null) {
                        valid = false
                        sb.append("\\$cmd")
                        if (num != null) sb.append('{').append(num).append('}')
                        return
                    }
                    val nStr = wrapCompound(num)
                    val dStr = wrapCompound(den)
                    sb.append(nStr).append('/').append(dStr)
                }
                "sqrt" -> {
                    val root = readOptionalBracket(depth + 1)
                    val arg = readMandatoryGroup(depth + 1)
                    if (arg == null) {
                        valid = false
                        sb.append("\\sqrt")
                        return
                    }
                    if (!root.isNullOrEmpty()) sb.append(formatScript(root, isSup = true))
                    sb.append('√')
                    if (arg.length <= 2 && arg.all { it.isLetterOrDigit() }) sb.append(arg) else sb.append('(').append(arg).append(')')
                }
                "mathbb" -> {
                    val arg = readMandatoryGroup(depth + 1) ?: ""
                    for (c in arg) sb.append(BLACKBOARD[c] ?: c.toString())
                }
                "mathbf", "textbf", "boldsymbol", "bm", "mathrm", "textrm", "text", "operatorname", "mathit", "textit", "mathcal", "mathscr", "mathfrak", "texttt", "mathsf" -> {
                    val arg = readMandatoryGroup(depth + 1)
                    if (arg != null) sb.append(arg)
                }
                "overline", "bar", "hat", "widehat", "tilde", "widetilde", "vec", "dot" -> {
                    val arg = readMandatoryGroup(depth + 1) ?: ""
                    val comb = when (cmd) {
                        "overline", "bar" -> "\u0304"
                        "hat", "widehat" -> "\u0302"
                        "tilde", "widetilde" -> "\u0303"
                        "vec" -> "\u20D7"
                        else -> "\u0307"
                    }
                    sb.append(arg).append(comb)
                }
                "href" -> {
                    // Consume URL without ever executing it; render safe label text only.
                    val url = readRawBraceName()
                    val label = readMandatoryGroup(depth + 1)
                    if (url == null || label == null) {
                        valid = false
                    }
                    if (label != null) sb.append(label)
                }
                "begin" -> {
                    val env = readRawBraceName() ?: return
                    val endTag = "\\end{$env}"
                    val endIdx = src.indexOf(endTag, pos)
                    if (endIdx < 0) {
                        valid = false
                        return
                    }
                    val bodyRaw = src.substring(pos, endIdx)
                    pos = endIdx + endTag.length
                    if (env == "array") {
                        // Skip optional column alignment `{ccc}`
                        val sub = Parser(bodyRaw)
                        sub.skipSpaces()
                        if (sub.pos < bodyRaw.length && bodyRaw[sub.pos] == '{') {
                            sub.readRawBraceName()
                        }
                        val rendered = sub.parseExpr(depth + 1)
                        if (!sub.valid) valid = false
                        sb.append(rendered)
                        return
                    }
                    val sub = Parser(bodyRaw)
                    val rendered = sub.parseExpr(depth + 1)
                    if (!sub.valid) valid = false
                    val (openD, closeD) = when (env) {
                        "pmatrix" -> "(" to ")"
                        "bmatrix" -> "[" to "]"
                        "Bmatrix" -> "{" to "}"
                        "vmatrix" -> "|" to "|"
                        "Vmatrix" -> "‖" to "‖"
                        "cases" -> "{ " to ""
                        else -> "" to ""
                    }
                    if (openD.isNotEmpty()) sb.append(openD)
                    sb.append(rendered.replace("\n", if (env.startsWith("align") || env == "cases") "\n" else "; "))
                    if (closeD.isNotEmpty()) sb.append(closeD)
                }
                "left", "right", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "Biggl", "Biggr" -> {
                    skipSpaces()
                    if (pos < src.length && src[pos] == '.') {
                        pos++
                    }
                }
                "quad" -> sb.append("  ")
                "qquad" -> sb.append("    ")
                else -> {
                    val sym = SYMBOLS[cmd]
                    if (sym != null) {
                        if (sb.isNotEmpty() && sb.last().isLetterOrDigit() && sym.first().isLetter()) {
                            sb.append(' ')
                        }
                        sb.append(sym)
                        if (pos < src.length && src[pos].isLetterOrDigit() && sym.last().isLetter()) {
                            sb.append(' ')
                        }
                    } else {
                        // Preserve scrubbed or custom TeX identifiers legibly (e.g. `\xxxxx` in fixtures)
                        sb.append(cmd)
                    }
                }
            }
        }

        private fun wrapCompound(s: String): String {
            val t = s.trim()
            if (t.length <= 2 || t.all { it.isLetterOrDigit() || it in "₀₁₂₃₄₅₆₇₈₉⁰¹²³⁴⁵⁶⁷⁸⁹" }) return t
            if (t.startsWith("(") && t.endsWith(")")) return t
            return "($t)"
        }

        private fun formatScript(arg: String, isSup: Boolean): String {
            val map = if (isSup) SUPERSCRIPTS else SUBSCRIPTS
            if (arg.isNotEmpty() && arg.all { it in map }) {
                return buildString(arg.length) { for (c in arg) append(map[c]!!) }
            }
            return if (isSup) "^($arg)" else "_($arg)"
        }
    }

    private val BLACKBOARD = mapOf(
        'N' to "ℕ", 'Z' to "ℤ", 'Q' to "ℚ", 'R' to "ℝ",
        'C' to "ℂ", 'F' to "𝔽", 'P' to "ℙ", 'E' to "𝔼", '1' to "𝟙"
    )

    private val SUPERSCRIPTS = mapOf(
        '0' to '⁰', '1' to '¹', '2' to '²', '3' to '³', '4' to '⁴',
        '5' to '⁵', '6' to '⁶', '7' to '⁷', '8' to '⁸', '9' to '⁹',
        '+' to '⁺', '-' to '⁻', '=' to '⁼', '(' to '⁽', ')' to '⁾',
        'n' to 'ⁿ', 'i' to 'ⁱ', 'T' to 'ᵀ'
    )

    private val SUBSCRIPTS = mapOf(
        '0' to '₀', '1' to '₁', '2' to '₂', '3' to '₃', '4' to '₄',
        '5' to '₅', '6' to '₆', '7' to '₇', '8' to '₈', '9' to '₉',
        '+' to '₊', '-' to '₋', '=' to '₌', '(' to '₍', ')' to '₎',
        'a' to 'ₐ', 'e' to 'ₑ', 'h' to 'ₕ', 'i' to 'ᵢ', 'j' to 'ⱼ',
        'k' to 'ₖ', 'l' to 'ₗ', 'm' to 'ₘ', 'n' to 'ₙ', 'o' to 'ₒ',
        'p' to 'ₚ', 'r' to 'ᵣ', 's' to 'ₛ', 't' to 'ₜ', 'u' to 'ᵤ',
        'v' to 'ᵥ', 'x' to 'ₓ'
    )

    private val SYMBOLS = mapOf(
        "alpha" to "α", "beta" to "β", "gamma" to "γ", "delta" to "δ",
        "epsilon" to "ϵ", "varepsilon" to "ε", "zeta" to "ζ", "eta" to "η",
        "theta" to "θ", "vartheta" to "ϑ", "iota" to "ι", "kappa" to "κ",
        "lambda" to "λ", "mu" to "μ", "nu" to "ν", "xi" to "ξ",
        "pi" to "π", "varpi" to "ϖ", "rho" to "ρ", "varrho" to "ϱ",
        "sigma" to "σ", "varsigma" to "ς", "tau" to "τ", "upsilon" to "υ",
        "phi" to "ϕ", "varphi" to "φ", "chi" to "χ", "psi" to "ψ", "omega" to "ω",
        "Gamma" to "Γ", "Delta" to "Δ", "Theta" to "Θ", "Lambda" to "Λ",
        "Xi" to "Ξ", "Pi" to "Π", "Sigma" to "Σ", "Upsilon" to "Υ",
        "Phi" to "Φ", "Psi" to "Ψ", "Omega" to "Ω",
        "sum" to "∑", "prod" to "∏", "coprod" to "∐",
        "int" to "∫", "iint" to "∬", "iiint" to "∭", "oint" to "∮",
        "infty" to "∞", "partial" to "∂", "nabla" to "∇", "ell" to "ℓ", "hbar" to "ℏ",
        "forall" to "∀", "exists" to "∃", "nexists" to "∄",
        "neg" to "¬", "lnot" to "¬", "land" to "∧", "lor" to "∨",
        "in" to "∈", "notin" to "∉", "ni" to "∋",
        "subset" to "⊂", "supset" to "⊃", "subseteq" to "⊆", "supseteq" to "⊇",
        "cup" to "∪", "cap" to "∩", "bigcup" to "⋃", "bigcap" to "⋂",
        "emptyset" to "∅", "varnothing" to "∅",
        "to" to "→", "rightarrow" to "→", "leftarrow" to "←", "leftrightarrow" to "↔",
        "Rightarrow" to "⇒", "Leftarrow" to "⇐", "Leftrightarrow" to "⇔",
        "implies" to "⇒", "iff" to "⇔", "mapsto" to "↦", "longmapsto" to "⟼",
        "uparrow" to "↑", "downarrow" to "↓",
        "le" to "≤", "leq" to "≤", "ge" to "≥", "geq" to "≥",
        "ne" to "≠", "neq" to "≠", "approx" to "≈", "equiv" to "≡",
        "sim" to "∼", "simeq" to "≃", "cong" to "≅", "propto" to "∝",
        "prec" to "≺", "succ" to "≻", "preceq" to "⪯", "succeq" to "⪰",
        "ll" to "≪", "gg" to "≫",
        "pm" to "±", "mp" to "∓", "times" to "×", "cdot" to "·", "div" to "÷",
        "ast" to "∗", "star" to "⋆", "circ" to "∘", "bullet" to "∙",
        "oplus" to "⊕", "ominus" to "⊖", "otimes" to "⊗", "odot" to "⊙",
        "perp" to "⊥", "parallel" to "∥", "vdash" to "⊢", "models" to "⊨",
        "lceil" to "⌈", "rceil" to "⌉", "lfloor" to "⌊", "rfloor" to "⌋",
        "langle" to "⟨", "rangle" to "⟩",
        "dots" to "…", "ldots" to "…", "cdots" to "⋯", "vdots" to "⋮", "ddots" to "⋱",
        "sin" to "sin", "cos" to "cos", "tan" to "tan", "log" to "log", "ln" to "ln",
        "exp" to "exp", "min" to "min", "max" to "max", "sup" to "sup", "inf" to "inf",
        "lim" to "lim", "det" to "det", "dim" to "dim", "ker" to "ker", "gcd" to "gcd",
        "mod" to "mod", "pmod" to "mod"
    )
}
