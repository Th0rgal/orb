import SwiftUI
import ImageIO

// MARK: - Native LaTeX & Inline Markdown Parser (`OrbMath.kt` parity)

enum OrbMath {
    nonisolated static let maxDepth = 16
    nonisolated static let maxSpanChars = 8192

    struct Result: Equatable, Sendable {
        let text: String
        let valid: Bool
    }

    enum InlineToken: Equatable, Sendable {
        case text(String)
        case code(String)
        case bold(String)
        case italic(String)
        case link(label: String, url: String, isSafe: Bool, isArtifact: Bool)
        case image(alt: String, url: String)
        case math(latex: String, display: Bool, complete: Bool)
    }

    @MainActor static let cache = OrbTextCache<Result>(capacity: 512)

    nonisolated static func usesWebRenderer(_ source: String) -> Bool { false }

    nonisolated static func isSafeHref(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("data:") || lower.hasPrefix("vbscript:") {
            return false
        }
        return true
    }

    nonisolated static func isArtifactHref(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("file:///") ||
            t.hasPrefix("sandbox:") ||
            t.hasPrefix("/mnt/data/") ||
            t.hasPrefix("/workspace/") ||
            t.hasPrefix("/srv/") ||
            t.hasPrefix("/Users/") ||
            t.hasPrefix("/root/") ||
            t.hasPrefix("/home/") ||
            t.hasPrefix("/var/") ||
            t.hasPrefix("/tmp/")
    }

    nonisolated static func containsMathOrMedia(_ source: String) -> Bool {
        guard source.contains("$") || source.contains("\\(") || source.contains("\\[") || source.contains("![") else {
            return false
        }
        var inFence = false
        for rawLine in source.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            for token in tokenizeInline(rawLine) {
                switch token {
                case .math, .image: return true
                default: break
                }
            }
        }
        return false
    }

    nonisolated static func admitsInlineDollarBody(_ inner: String, prevBlocked: Bool = false, nextDigit: Bool = false) -> Bool {
        let mathOps: Set<Character> = ["\\", "^", "_", "{", "}", "=", "+", "-", "*", "/", "<", ">", "|"]
        return OrbTranscriptGates.latexSpanAdmitted(
            len: inner.count,
            prevBlocked: prevBlocked,
            nextDigit: nextDigit,
            leadSpace: inner.first?.isWhitespace ?? false,
            trailSpace: inner.last?.isWhitespace ?? false,
            hasNewline: inner.contains("\n"),
            firstDigit: inner.first?.isNumber ?? false,
            internalSpace: inner.contains(where: \.isWhitespace),
            hasMathOp: inner.contains(where: { mathOps.contains($0) })
        )
    }

    nonisolated static func findClosingInlineDollar(_ chars: [Character], openIdx: Int) -> Int? {
        let n = chars.count
        guard openIdx >= 0, openIdx + 2 <= n, chars[openIdx] == "$" else { return nil }
        let prevBlocked: Bool = {
            guard openIdx > 0 else { return false }
            let prev = chars[openIdx - 1]
            return prev == "\\" || prev == "$" || prev.isLetter || prev.isNumber
        }()
        if prevBlocked { return nil }
        let firstInner = chars[openIdx + 1]
        if firstInner == "$" || firstInner.isWhitespace { return nil }

        var i = openIdx + 1
        while i < n && i - (openIdx + 1) <= maxSpanChars {
            let ch = chars[i]
            if ch == "\n" { return nil }
            if ch == "\\" {
                i += 2
                continue
            }
            if ch == "$" {
                let prev = chars[i - 1]
                let next: Character = i + 1 < n ? chars[i + 1] : "\0"
                if !prev.isWhitespace && next != "$" && !next.isNumber {
                    let inner = String(chars[(openIdx + 1)..<i])
                    return admitsInlineDollarBody(inner, prevBlocked: prevBlocked, nextDigit: next.isNumber) ? i : nil
                }
            }
            i += 1
        }
        return nil
    }

    nonisolated static func tokenizeInline(_ raw: String, depth: Int = 0) -> [InlineToken] {
        if raw.isEmpty { return [] }
        if depth > 6 { return [.text(raw)] }
        let chars = Array(raw)
        let n = chars.count
        var out: [InlineToken] = []
        var plain = ""

        func flushPlain() {
            if !plain.isEmpty {
                out.append(.text(plain))
                plain.removeAll(keepingCapacity: true)
            }
        }

        func findSub(_ needle: [Character], from start: Int) -> Int? {
            let m = needle.count
            guard m > 0, start + m <= n else { return nil }
            var idx = start
            while idx + m <= n {
                var match = true
                for k in 0..<m where chars[idx + k] != needle[k] {
                    match = false
                    break
                }
                if match { return idx }
                idx += 1
            }
            return nil
        }

        var i = 0
        while i < n {
            let ch = chars[i]

            if ch == "\\" && i + 1 < n && chars[i + 1] == "$" {
                plain.append("$")
                i += 2
                continue
            }

            if ch == "`" {
                var ticks = 1
                while i + ticks < n && chars[i + ticks] == "`" { ticks += 1 }
                let fence = Array(repeating: Character("`"), count: ticks)
                if let end = findSub(fence, from: i + ticks) {
                    flushPlain()
                    out.append(.code(String(chars[(i + ticks)..<end])))
                    i = end + ticks
                    continue
                }
            }

            if ch == "$" && i + 1 < n && chars[i + 1] == "$" {
                if let close = findSub(["$", "$"], from: i + 2), close - (i + 2) <= maxSpanChars {
                    flushPlain()
                    out.append(.math(latex: String(chars[(i + 2)..<close]), display: true, complete: true))
                    i = close + 2
                    continue
                }
            }

            if ch == "\\" && i + 1 < n && chars[i + 1] == "(" {
                flushPlain()
                if let close = findSub(["\\", ")"], from: i + 2), close - (i + 2) <= maxSpanChars {
                    out.append(.math(latex: String(chars[(i + 2)..<close]), display: false, complete: true))
                    i = close + 2
                } else {
                    let end = min(n, i + 2 + maxSpanChars)
                    out.append(.math(latex: String(chars[(i + 2)..<end]), display: false, complete: false))
                    i = n
                }
                continue
            }

            if ch == "\\" && i + 1 < n && chars[i + 1] == "[" {
                flushPlain()
                if let close = findSub(["\\", "]"], from: i + 2), close - (i + 2) <= maxSpanChars {
                    out.append(.math(latex: String(chars[(i + 2)..<close]), display: true, complete: true))
                    i = close + 2
                } else {
                    let end = min(n, i + 2 + maxSpanChars)
                    out.append(.math(latex: String(chars[(i + 2)..<end]), display: true, complete: false))
                    i = n
                }
                continue
            }

            if ch == "$", let close = findClosingInlineDollar(chars, openIdx: i) {
                flushPlain()
                out.append(.math(latex: String(chars[(i + 1)..<close]), display: false, complete: true))
                i = close + 1
                continue
            }

            if ch == "!" && i + 1 < n && chars[i + 1] == "[" {
                if let closeBracket = findSub(["]"], from: i + 2),
                   closeBracket + 1 < n && chars[closeBracket + 1] == "(",
                   let closeParen = findSub([")"], from: closeBracket + 2) {
                    let alt = String(chars[(i + 2)..<closeBracket])
                    let url = String(chars[(closeBracket + 2)..<closeParen]).trimmingCharacters(in: .whitespacesAndNewlines)
                    flushPlain()
                    out.append(.image(alt: alt, url: url))
                    i = closeParen + 1
                    continue
                }
            }

            if ch == "[" {
                if let closeBracket = findSub(["]"], from: i + 1),
                   closeBracket > i,
                   closeBracket + 1 < n && chars[closeBracket + 1] == "(",
                   let closeParen = findSub([")"], from: closeBracket + 2) {
                    let label = String(chars[(i + 1)..<closeBracket])
                    let url = String(chars[(closeBracket + 2)..<closeParen]).trimmingCharacters(in: .whitespacesAndNewlines)
                    flushPlain()
                    out.append(.link(label: label, url: url, isSafe: isSafeHref(url), isArtifact: isArtifactHref(url)))
                    i = closeParen + 1
                    continue
                }
            }

            if ch == "*" && i + 1 < n && chars[i + 1] == "*" {
                if let end = findSub(["*", "*"], from: i + 2), end > i + 2 {
                    flushPlain()
                    out.append(.bold(String(chars[(i + 2)..<end])))
                    i = end + 2
                    continue
                }
            }

            if ch == "*" && i + 1 < n && !chars[i + 1].isWhitespace && chars[i + 1] != "*" {
                if let end = findSub(["*"], from: i + 1), end > i + 1, !chars[end - 1].isWhitespace {
                    flushPlain()
                    out.append(.italic(String(chars[(i + 1)..<end])))
                    i = end + 1
                    continue
                }
            }

            plain.append(ch)
            i += 1
        }
        flushPlain()
        return out
    }

    @MainActor static func formatCached(_ latex: String, complete: Bool = true, streaming: Bool = false) -> Result {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        if !complete || trimmed.count > maxSpanChars {
            return formatLatex(trimmed, complete: false)
        }
        if !streaming, let hit = cache.get(trimmed) {
            return hit
        }
        let rendered = formatLatex(trimmed, complete: true)
        if !streaming {
            cache.put(trimmed, rendered)
        }
        return rendered
    }

    nonisolated static func formatLatex(_ latex: String, complete: Bool = true) -> Result {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return Result(text: "", valid: complete) }
        if !complete || trimmed.count > maxSpanChars {
            var p = Parser(Array(trimmed.prefix(maxSpanChars)))
            let partial = p.parseExpr(depth: 0)
            let fallback = partial.isEmpty ? String(trimmed.prefix(256)) : partial
            return Result(text: fallback, valid: false)
        }
        var parser = Parser(Array(trimmed))
        let out = parser.parseExpr(depth: 0)
        if parser.pos < parser.src.count {
            parser.valid = false
        }
        return Result(text: out.isEmpty ? trimmed : out, valid: parser.valid)
    }

    private struct Parser {
        let src: [Character]
        var pos = 0
        var valid = true

        init(_ src: [Character]) { self.src = src }

        mutating func parseExpr(depth: Int, stopAtBrace: Bool = false) -> String {
            if depth > OrbMath.maxDepth {
                valid = false
                let rest = String(src[pos...])
                pos = src.count
                return rest
            }
            var out = ""
            while pos < src.count {
                let ch = src[pos]
                if ch == "}" {
                    if stopAtBrace {
                        pos += 1
                        return out.trimmingCharacters(in: .whitespaces)
                    }
                    valid = false
                    pos += 1
                    continue
                }
                if ch == "{" {
                    pos += 1
                    let inner = parseExpr(depth: depth + 1, stopAtBrace: true)
                    out.append(inner)
                    continue
                }
                if ch == "^" || ch == "_" {
                    let isSup = ch == "^"
                    pos += 1
                    let arg = readScriptArg(depth: depth + 1)
                    if arg.isEmpty {
                        valid = false
                        out.append(ch)
                    } else {
                        out.append(Self.formatScript(arg, isSup: isSup))
                    }
                    continue
                }
                if ch == "&" {
                    pos += 1
                    if out.last != " " && !out.isEmpty { out.append(" ") }
                    continue
                }
                if ch == "~" {
                    pos += 1
                    out.append("\u{00A0}")
                    continue
                }
                if ch == "\\" {
                    pos += 1
                    if pos >= src.count {
                        valid = false
                        out.append("\\")
                        break
                    }
                    let next = src[pos]
                    if !next.isLetter {
                        pos += 1
                        switch next {
                        case "\\": out.append("\n")
                        case ",", ";", ":", " ": out.append(" ")
                        case "!": break
                        case "|": out.append("‖")
                        default: out.append(next)
                        }
                        continue
                    }
                    let start = pos
                    while pos < src.count && src[pos].isLetter { pos += 1 }
                    let cmd = String(src[start..<pos])
                    handleCommand(cmd, depth: depth, out: &out)
                    continue
                }
                if ch.isWhitespace {
                    while pos < src.count && src[pos].isWhitespace { pos += 1 }
                    if !out.isEmpty && out.last != " " && out.last != "\n" { out.append(" ") }
                    continue
                }
                out.append(ch)
                pos += 1
            }
            if stopAtBrace {
                valid = false
            }
            return out.trimmingCharacters(in: .whitespaces)
        }

        private mutating func skipSpaces() {
            while pos < src.count && src[pos].isWhitespace { pos += 1 }
        }

        private mutating func readMandatoryGroup(depth: Int) -> String? {
            skipSpaces()
            guard pos < src.count else {
                valid = false
                return nil
            }
            if src[pos] == "{" {
                pos += 1
                return parseExpr(depth: depth + 1, stopAtBrace: true)
            }
            if src[pos] == "\\" {
                pos += 1
                guard pos < src.count else {
                    valid = false
                    return nil
                }
                if !src[pos].isLetter {
                    let c = src[pos]
                    pos += 1
                    return String(c)
                }
                let s = pos
                while pos < src.count && src[pos].isLetter { pos += 1 }
                var sub = ""
                handleCommand(String(src[s..<pos]), depth: depth + 1, out: &sub)
                return sub
            }
            let c = src[pos]
            pos += 1
            return String(c)
        }

        private mutating func readOptionalBracket(depth: Int) -> String? {
            skipSpaces()
            guard pos < src.count, src[pos] == "[" else { return nil }
            var close = pos + 1
            while close < src.count && src[close] != "]" { close += 1 }
            guard close < src.count else {
                valid = false
                return nil
            }
            let slice = Array(src[(pos + 1)..<close])
            pos = close + 1
            if depth <= OrbMath.maxDepth {
                var sub = Parser(slice)
                return sub.parseExpr(depth: depth + 1)
            }
            return String(slice)
        }

        private mutating func readScriptArg(depth: Int) -> String {
            skipSpaces()
            guard pos < src.count else { return "" }
            return readMandatoryGroup(depth: depth) ?? ""
        }

        private mutating func readRawBraceName() -> String? {
            skipSpaces()
            guard pos < src.count, src[pos] == "{" else {
                valid = false
                return nil
            }
            var close = pos + 1
            while close < src.count && src[close] != "}" { close += 1 }
            guard close < src.count else {
                valid = false
                pos = src.count
                return nil
            }
            let name = String(src[(pos + 1)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
            pos = close + 1
            return name
        }

        private mutating func handleCommand(_ cmd: String, depth: Int, out: inout String) {
            switch cmd {
            case "frac", "dfrac", "tfrac":
                let num = readMandatoryGroup(depth: depth + 1)
                let den = readMandatoryGroup(depth: depth + 1)
                guard let num, let den else {
                    valid = false
                    out.append("\\\(cmd)")
                    if let num { out.append("{\(num)}") }
                    return
                }
                out.append("\(Self.wrapCompound(num))/\(Self.wrapCompound(den))")
            case "sqrt":
                let root = readOptionalBracket(depth: depth + 1)
                guard let arg = readMandatoryGroup(depth: depth + 1) else {
                    valid = false
                    out.append("\\sqrt")
                    return
                }
                if let root, !root.isEmpty { out.append(Self.formatScript(root, isSup: true)) }
                out.append("√")
                if arg.count <= 2 && arg.allSatisfy({ $0.isLetter || $0.isNumber }) {
                    out.append(arg)
                } else {
                    out.append("(\(arg))")
                }
            case "mathbb":
                let arg = readMandatoryGroup(depth: depth + 1) ?? ""
                for c in arg { out.append(OrbMath.blackboard[c] ?? String(c)) }
            case "mathbf", "textbf", "boldsymbol", "bm", "mathrm", "textrm", "text", "operatorname", "mathit", "textit", "mathcal", "mathscr", "mathfrak", "texttt", "mathsf":
                if let arg = readMandatoryGroup(depth: depth + 1) { out.append(arg) }
            case "overline", "bar", "hat", "widehat", "tilde", "widetilde", "vec", "dot":
                let arg = readMandatoryGroup(depth: depth + 1) ?? ""
                let comb: String = switch cmd {
                case "overline", "bar": "\u{0304}"
                case "hat", "widehat": "\u{0302}"
                case "tilde", "widetilde": "\u{0303}"
                case "vec": "\u{20D7}"
                default: "\u{0307}"
                }
                out.append(arg + comb)
            case "href":
                let url = readRawBraceName()
                let label = readMandatoryGroup(depth: depth + 1)
                if url == nil || label == nil { valid = false }
                if let label { out.append(label) }
            case "begin":
                guard let env = readRawBraceName() else { return }
                let endTag = Array("\\end{\(env)}")
                var endIdx: Int?
                var search = pos
                while search + endTag.count <= src.count {
                    if Array(src[search..<(search + endTag.count)]) == endTag {
                        endIdx = search
                        break
                    }
                    search += 1
                }
                guard let foundEnd = endIdx else {
                    valid = false
                    return
                }
                let bodySlice = Array(src[pos..<foundEnd])
                pos = foundEnd + endTag.count
                var sub = Parser(bodySlice)
                if env == "array" {
                    sub.skipSpaces()
                    if sub.pos < sub.src.count && sub.src[sub.pos] == "{" {
                        _ = sub.readRawBraceName()
                    }
                }
                let rendered = sub.parseExpr(depth: depth + 1)
                if !sub.valid { valid = false }
                let (openD, closeD): (String, String) = switch env {
                case "pmatrix": ("(", ")")
                case "bmatrix": ("[", "]")
                case "Bmatrix": ("{", "}")
                case "vmatrix": ("|", "|")
                case "Vmatrix": ("‖", "‖")
                case "cases": ("{ ", "")
                default: ("", "")
                }
                out.append(openD)
                let sep = (env.hasPrefix("align") || env == "cases") ? "\n" : "; "
                out.append(rendered.replacingOccurrences(of: "\n", with: sep))
                out.append(closeD)
            case "left", "right", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "Biggl", "Biggr":
                skipSpaces()
                if pos < src.count && src[pos] == "." { pos += 1 }
            case "quad":
                out.append("  ")
            case "qquad":
                out.append("    ")
            default:
                if let sym = OrbMath.symbols[cmd] {
                    if let prev = out.last, (prev.isLetter || prev.isNumber), let f = sym.first, f.isLetter {
                        out.append(" ")
                    }
                    out.append(sym)
                    if pos < src.count, (src[pos].isLetter || src[pos].isNumber), let l = sym.last, l.isLetter {
                        out.append(" ")
                    }
                } else {
                    out.append(cmd)
                }
            }
        }

        private static func wrapCompound(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespaces)
            let scriptChars: Set<Character> = ["₀", "₁", "₂", "₃", "₄", "₅", "₆", "₇", "₈", "₉", "⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"]
            if t.count <= 2 || t.allSatisfy({ $0.isLetter || $0.isNumber || scriptChars.contains($0) }) { return t }
            if t.hasPrefix("(") && t.hasSuffix(")") { return t }
            return "(\(t))"
        }

        private static func formatScript(_ arg: String, isSup: Bool) -> String {
            let map = isSup ? OrbMath.superscripts : OrbMath.subscripts
            if !arg.isEmpty && arg.allSatisfy({ map[$0] != nil }) {
                return String(arg.compactMap { map[$0] })
            }
            return isSup ? "^(\(arg))" : "_(\(arg))"
        }
    }

    nonisolated private static let blackboard: [Character: String] = [
        "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "R": "ℝ",
        "C": "ℂ", "F": "𝔽", "P": "ℙ", "E": "𝔼", "1": "𝟙"
    ]

    nonisolated private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "n": "ⁿ", "i": "ⁱ", "T": "ᵀ"
    ]

    nonisolated private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ",
        "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ",
        "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ",
        "v": "ᵥ", "x": "ₓ"
    ]

    nonisolated private static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
        "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
        "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ",
        "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ",
        "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
        "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "sum": "∑", "prod": "∏", "coprod": "∐",
        "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮",
        "infty": "∞", "partial": "∂", "nabla": "∇", "ell": "ℓ", "hbar": "ℏ",
        "forall": "∀", "exists": "∃", "nexists": "∄",
        "neg": "¬", "lnot": "¬", "land": "∧", "lor": "∨",
        "in": "∈", "notin": "∉", "ni": "∋",
        "subset": "⊂", "supset": "⊃", "subseteq": "⊆", "supseteq": "⊇",
        "cup": "∪", "cap": "∩", "bigcup": "⋃", "bigcap": "⋂",
        "emptyset": "∅", "varnothing": "∅",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔",
        "implies": "⇒", "iff": "⇔", "mapsto": "↦", "longmapsto": "⟼",
        "uparrow": "↑", "downarrow": "↓",
        "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥",
        "ne": "≠", "neq": "≠", "approx": "≈", "equiv": "≡",
        "sim": "∼", "simeq": "≃", "cong": "≅", "propto": "∝",
        "prec": "≺", "succ": "≻", "preceq": "⪯", "succeq": "⪰",
        "ll": "≪", "gg": "≫",
        "pm": "±", "mp": "∓", "times": "×", "cdot": "·", "div": "÷",
        "ast": "∗", "star": "⋆", "circ": "∘", "bullet": "∙",
        "oplus": "⊕", "ominus": "⊖", "otimes": "⊗", "odot": "⊙",
        "perp": "⊥", "parallel": "∥", "vdash": "⊢", "models": "⊨",
        "lceil": "⌈", "rceil": "⌉", "lfloor": "⌊", "rfloor": "⌋",
        "langle": "⟨", "rangle": "⟩",
        "dots": "…", "ldots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱",
        "sin": "sin", "cos": "cos", "tan": "tan", "log": "log", "ln": "ln",
        "exp": "exp", "min": "min", "max": "max", "sup": "sup", "inf": "inf",
        "lim": "lim", "det": "det", "dim": "dim", "ker": "ker", "gcd": "gcd",
        "mod": "mod", "pmod": "mod"
    ]
}

// MARK: - Pure-SwiftUI Markdown, Math & Image Renderer (Zero WKWebView)

struct OrbNativeMarkdownView: View {
    let source: String
    /// A reply still arriving: parsed incrementally (`streamingBlocks`), not cached by content.
    var streaming = false
    var onArtifact: (String) -> Void = { _ in }
    @Environment(\.orbFiles) private var files
    @State private var copiedBlockIndex: Int?

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case code(language: String, code: String)
        /// A ```mermaid fence; `complete` is false while its closing fence has not streamed in.
        case mermaid(code: String, complete: Bool)
        case list(ordered: Bool, items: [String])
        case quote(String)
        /// `headers` all empty: a loose pipe table without a header row (hidden).
        case table(headers: [String], rows: [[String]], rightAligned: [Bool] = [])
        case math(latex: String, complete: Bool)
        case image(alt: String, url: String)
        case divider
    }

    static func requiresWebRenderer(_ source: String) -> Bool {
        OrbMath.usesWebRenderer(source)
    }

    private static func isTableRow(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.count > 2
    }

    private static func parseTableCells(_ trimmed: String) -> [String] {
        let inner = Array(trimmed.dropFirst().dropLast())
        var cells: [String] = []
        var cur = ""
        var i = 0
        while i < inner.count {
            if inner[i] == "\\" && i + 1 < inner.count && inner[i + 1] == "|" {
                cur.append("|")
                i += 2
                continue
            }
            if inner[i] == "|" {
                cells.append(cur.trimmingCharacters(in: .whitespaces))
                cur.removeAll(keepingCapacity: true)
                i += 1
                continue
            }
            cur.append(inner[i])
            i += 1
        }
        cells.append(cur.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func isTableSeparator(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { cell in
            let stripped = cell.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
            return stripped.isEmpty && cell.contains("-")
        }
    }

    private static func parseStandaloneImage(_ trimmed: String) -> (alt: String, url: String)? {
        guard trimmed.hasPrefix("!["), trimmed.hasSuffix(")"),
              let mid = trimmed.range(of: "](") else { return nil }
        let altStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
        guard mid.lowerBound >= altStart else { return nil }
        let alt = String(trimmed[altStart..<mid.lowerBound])
        let urlEnd = trimmed.index(before: trimmed.endIndex)
        guard mid.upperBound <= urlEnd else { return nil }
        let url = String(trimmed[mid.upperBound..<urlEnd]).trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, !url.contains(")"), !url.contains("\n") else { return nil }
        return (alt, url)
    }

    private static func isDisplayMathStart(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[")
    }

    static func parseBlocks(_ source: String) -> [Block] {
        var blocks: [Block] = []
        let lines = OrbPipeTables.normalize(source).components(separatedBy: "\n")
        var idx = 0
        while idx < lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                idx += 1
                continue
            }
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                idx += 1
                var codeLines: [String] = []
                while idx < lines.count && !lines[idx].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[idx])
                    idx += 1
                }
                let closed = idx < lines.count
                if closed { idx += 1 }
                if lang.lowercased() == "mermaid" {
                    blocks.append(.mermaid(code: codeLines.joined(separator: "\n"), complete: closed))
                } else {
                    blocks.append(.code(language: lang, code: codeLines.joined(separator: "\n")))
                }
                continue
            }
            if trimmed == "---" || trimmed == "***" {
                blocks.append(.divider)
                idx += 1
                continue
            }
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                if hashes <= 4 && trimmed.dropFirst(hashes).first == " " {
                    let title = String(trimmed.dropFirst(hashes + 1))
                    blocks.append(.heading(level: hashes, text: title))
                    idx += 1
                    continue
                }
            }
            if isDisplayMathStart(trimmed) {
                let openDelim = trimmed.hasPrefix("$$") ? "$$" : "\\["
                let closeDelim = openDelim == "$$" ? "$$" : "\\]"
                let afterOpen = String(trimmed.dropFirst(openDelim.count))
                if let closeRange = afterOpen.range(of: closeDelim) {
                    let body = String(afterOpen[..<closeRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let trailing = String(afterOpen[closeRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    blocks.append(.math(latex: body, complete: true))
                    if !trailing.isEmpty {
                        blocks.append(.paragraph(trailing))
                    }
                    idx += 1
                    continue
                }
                var mathLines: [String] = []
                if !afterOpen.isEmpty { mathLines.append(afterOpen) }
                idx += 1
                var closed = false
                while idx < lines.count {
                    let cur = lines[idx]
                    let curTrim = cur.trimmingCharacters(in: .whitespaces)
                    if curTrim.isEmpty || curTrim.hasPrefix("```") { break }
                    if let closeRange = curTrim.range(of: closeDelim) {
                        let before = String(curTrim[..<closeRange.lowerBound])
                        if !before.isEmpty { mathLines.append(before) }
                        closed = true
                        idx += 1
                        break
                    }
                    mathLines.append(cur)
                    idx += 1
                }
                blocks.append(.math(latex: mathLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), complete: closed))
                continue
            }
            if let img = parseStandaloneImage(trimmed) {
                blocks.append(.image(alt: img.alt, url: img.url))
                idx += 1
                continue
            }
            if isTableRow(trimmed) {
                var rawRows: [[String]] = []
                while idx < lines.count {
                    let t = lines[idx].trimmingCharacters(in: .whitespaces)
                    guard isTableRow(t) else { break }
                    rawRows.append(parseTableCells(t))
                    idx += 1
                }
                if rawRows.count >= 2 && isTableSeparator(rawRows[1]) {
                    let headers = rawRows[0]
                    let bodyRows = Array(rawRows.dropFirst(2))
                    let right = rawRows[1].map { $0.trimmingCharacters(in: .whitespaces).hasSuffix(":") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix(":") }
                    blocks.append(.table(headers: headers, rows: bodyRows, rightAligned: right))
                    continue
                } else if !rawRows.isEmpty {
                    let headers = rawRows[0]
                    let bodyRows = Array(rawRows.dropFirst(1))
                    blocks.append(.table(headers: headers, rows: bodyRows))
                    continue
                }
            }
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                var quoteLines: [String] = []
                while idx < lines.count {
                    let t = lines[idx].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("> ") { quoteLines.append(String(t.dropFirst(2))); idx += 1 }
                    else if t == ">" { quoteLines.append(""); idx += 1 }
                    else { break }
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                var items: [String] = []
                while idx < lines.count {
                    let t = lines[idx].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("- ") || t.hasPrefix("* ") {
                        items.append(String(t.dropFirst(2)))
                        idx += 1
                    } else { break }
                }
                blocks.append(.list(ordered: false, items: items))
                continue
            }
            if let dotIdx = trimmed.firstIndex(of: "."),
               trimmed[..<dotIdx].allSatisfy(\.isNumber),
               trimmed.index(after: dotIdx) < trimmed.endIndex,
               trimmed[trimmed.index(after: dotIdx)] == " " {
                var items: [String] = []
                while idx < lines.count {
                    let t = lines[idx].trimmingCharacters(in: .whitespaces)
                    if let d = t.firstIndex(of: "."),
                       t[..<d].allSatisfy(\.isNumber),
                       t.index(after: d) < t.endIndex,
                       t[t.index(after: d)] == " " {
                        let start = t.index(d, offsetBy: 2)
                        items.append(String(t[start...]))
                        idx += 1
                    } else { break }
                }
                blocks.append(.list(ordered: true, items: items))
                continue
            }
            var paraLines: [String] = []
            while idx < lines.count {
                let l = lines[idx]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty ||
                    t.hasPrefix("```") ||
                    t.hasPrefix("#") ||
                    t.hasPrefix("- ") ||
                    t.hasPrefix("* ") ||
                    t.hasPrefix("> ") ||
                    isTableRow(t) ||
                    isDisplayMathStart(t) ||
                    parseStandaloneImage(t) != nil {
                    break
                }
                paraLines.append(l)
                idx += 1
            }
            if !paraLines.isEmpty {
                blocks.append(.paragraph(paraLines.joined(separator: "\n")))
            } else {
                idx += 1
            }
        }
        return blocks
    }

    // Keyed by the text itself: a hash collision must not show another message's blocks.
    @MainActor static let blockCache = OrbTextCache<[Block]>(capacity: 256)
    @MainActor private static let inlineCache = OrbTextCache<AttributedString>(capacity: 1024)

    @MainActor static func trimCaches() {
        blockCache.removeAll()
        inlineCache.removeAll()
        OrbMath.cache.removeAll()
    }

    @MainActor static func cachedBlocks(_ source: String) -> [Block] {
        if let cached = blockCache.get(source) { return cached }
        let parsed = parseBlocks(source)
        blockCache.put(source, parsed)
        return parsed
    }

    @MainActor static func inlineAttributed(_ raw: String, streaming: Bool = false) -> AttributedString {
        if !streaming, raw.count <= 4000, let cached = inlineCache.get(raw) {
            return cached
        }
        let attr = buildInlineAttributed(OrbMath.tokenizeInline(raw), streaming: streaming, depth: 0)
        if !streaming, raw.count <= 4000 {
            inlineCache.put(raw, attr)
        }
        return attr
    }

    private static let artifactScheme = "orb-artifact"

    @MainActor private static func buildInlineAttributed(_ tokens: [OrbMath.InlineToken], streaming: Bool, depth: Int) -> AttributedString {
        var result = AttributedString()
        for token in tokens {
            switch token {
            case .text(let s):
                result.append(AttributedString(s))
            case .code(let code):
                var span = AttributedString(code)
                span.font = .system(.footnote, design: .monospaced)
                span.foregroundColor = Color(white: 0.94)
                span.backgroundColor = Color.white.opacity(0.08)
                result.append(span)
            case .bold(let inner):
                var span = depth < 4 ? buildInlineAttributed(OrbMath.tokenizeInline(inner, depth: depth + 1), streaming: streaming, depth: depth + 1) : AttributedString(inner)
                span.inlinePresentationIntent = .stronglyEmphasized
                result.append(span)
            case .italic(let inner):
                var span = depth < 4 ? buildInlineAttributed(OrbMath.tokenizeInline(inner, depth: depth + 1), streaming: streaming, depth: depth + 1) : AttributedString(inner)
                span.inlinePresentationIntent = .emphasized
                result.append(span)
            case .math(let latex, _, let complete):
                let rendered = OrbMath.formatCached(latex, complete: complete, streaming: streaming)
                var span = AttributedString(rendered.text)
                if rendered.valid {
                    span.font = .system(.body, design: .serif).italic()
                    span.foregroundColor = Color(white: 0.96)
                } else {
                    span.font = .system(.footnote, design: .monospaced)
                    span.foregroundColor = Color(red: 0.84, green: 0.63, blue: 0.42)
                }
                result.append(span)
            case .link(let label, let url, let isSafe, let isArtifact):
                guard isSafe else {
                    result.append(AttributedString(label))
                    continue
                }
                if isArtifact {
                    let displayLabel = label.isEmpty ? OrbFileRefs.fileName(url) : label
                    var span = AttributedString(displayLabel)
                    span.font = .system(.footnote, design: .monospaced)
                    span.foregroundColor = Color(red: 0.85, green: 0.90, blue: 0.96)
                    span.backgroundColor = Color.white.opacity(0.07)
                    if let encoded = encodeArtifactURL(url) {
                        span.link = encoded
                    }
                    result.append(span)
                } else if let target = URL(string: url),
                          let scheme = target.scheme?.lowercased(),
                          ["https", "http", "mailto"].contains(scheme),
                          target.user == nil, target.password == nil {
                    var span = depth < 4 ? buildInlineAttributed(OrbMath.tokenizeInline(label, depth: depth + 1), streaming: streaming, depth: depth + 1) : AttributedString(label)
                    span.link = target
                    span.foregroundColor = Color(red: 0.72, green: 0.84, blue: 0.94)
                    span.underlineStyle = .single
                    result.append(span)
                } else {
                    result.append(AttributedString(label))
                }
            case .image(let alt, let url):
                let displayLabel = alt.isEmpty ? OrbFileRefs.fileName(url) : alt
                if OrbMath.isSafeHref(url), let encoded = OrbMath.isArtifactHref(url) ? encodeArtifactURL(url) : URL(string: url) {
                    var span = AttributedString("[\(displayLabel)]")
                    span.link = encoded
                    span.foregroundColor = Color(red: 0.72, green: 0.84, blue: 0.94)
                    result.append(span)
                } else {
                    result.append(AttributedString(displayLabel))
                }
            }
        }
        return result
    }

    private static func encodeArtifactURL(_ raw: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = artifactScheme
        comps.host = "open"
        comps.queryItems = [URLQueryItem(name: "ref", value: raw)]
        return comps.url
    }

    fileprivate static func decodeArtifactURL(_ url: URL) -> String? {
        if url.scheme == artifactScheme {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "ref" })?.value
        }
        let str = url.absoluteString
        if OrbMath.isArtifactHref(str) { return str }
        return nil
    }

    @State private var showFullSource = false
    static let maxInlineSourceChars = 32_768

    var body: some View {
        let truncated = !showFullSource && source.count > Self.maxInlineSourceChars
        let effectiveSource = truncated ? OrbNativeMarkdownView.inlinePreview(source, limit: Self.maxInlineSourceChars) : source
        let blocks = streaming ? Self.streamingBlocks(effectiveSource) : Self.cachedBlocks(effectiveSource)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .heading(let level, let text):
                    inlineMarkdownText(text)
                        .font(level == 1 ? .title3.weight(.bold) : (level == 2 ? .headline : .subheadline.weight(.semibold)))
                        .foregroundStyle(Color(white: 0.95))
                        .padding(.top, index == 0 ? 0 : 4)
                case .paragraph(let text):
                    inlineMarkdownText(text)
                        .font(.body)
                        .foregroundStyle(Color(white: 0.89))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                case .quote(let text):
                    inlineMarkdownText(text)
                        .font(.subheadline)
                        .foregroundStyle(OrbStyle.textSecondary)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.22)).frame(width: 2)
                        }
                case .list(let ordered, let items):
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(ordered ? "\(i + 1)." : "•")
                                    .font(.subheadline)
                                    .foregroundStyle(OrbStyle.textSecondary)
                                inlineMarkdownText(item)
                                    .font(.body)
                                    .foregroundStyle(Color(white: 0.89))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                case .table(let headers, let rows, let rightAligned):
                    let align: (Int) -> Alignment = { rightAligned.indices.contains($0) && rightAligned[$0] ? .trailing : .leading }
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            if headers.contains(where: { !$0.isEmpty }) {
                                HStack(spacing: 0) {
                                    ForEach(Array(headers.enumerated()), id: \.offset) { hIdx, h in
                                        inlineMarkdownText(h)
                                            .font(.system(.footnote, weight: .semibold))
                                            .foregroundStyle(Color.white)
                                            .frame(minWidth: 100, maxWidth: 240, alignment: align(hIdx))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 8)
                                    }
                                }
                                .background(Color.white.opacity(0.05))
                            }
                            ForEach(Array(rows.enumerated()), id: \.offset) { rIdx, row in
                                if rIdx > 0 || headers.contains(where: { !$0.isEmpty }) {
                                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                                }
                                HStack(alignment: .top, spacing: 0) {
                                    ForEach(0..<max(headers.count, row.count), id: \.self) { cIdx in
                                        let cell = cIdx < row.count ? row[cIdx] : ""
                                        inlineMarkdownText(cell)
                                            .font(.system(.footnote).monospacedDigit())
                                            .foregroundStyle(Color(white: 0.88))
                                            .frame(minWidth: 100, maxWidth: 240, alignment: align(cIdx))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 7)
                                    }
                                }
                            }
                        }
                        .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.1)))
                    }
                case .math(let latex, let complete):
                    let rendered = OrbMath.formatCached(latex, complete: complete, streaming: streaming)
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(rendered.text)
                            .font(rendered.valid ? .system(.body, design: .serif).italic() : .system(.footnote, design: .monospaced))
                            .foregroundStyle(rendered.valid ? Color(white: 0.95) : Color(red: 0.84, green: 0.63, blue: 0.42))
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(white: 0.082), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.09)))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(rendered.text)
                    .accessibilityIdentifier("math.block")
                case .image(let alt, let url):
                    OrbMarkdownImageBlock(alt: alt, rawURL: url, files: files, onArtifact: onArtifact)
                case .code(let lang, let code):
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(lang.isEmpty ? "code" : lang)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(OrbStyle.textMuted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = code
                                OrbHaptics.light()
                                copiedBlockIndex = index
                                Task {
                                    try? await Task.sleep(for: .seconds(1.4))
                                    if copiedBlockIndex == index { copiedBlockIndex = nil }
                                }
                            } label: {
                                Text(copiedBlockIndex == index ? "Copied ✓" : "Copy code")
                                    .font(.system(.caption))
                                    .foregroundStyle(copiedBlockIndex == index ? OrbStyle.success : OrbStyle.textSecondary)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("copy.code")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(code.count > 12000 ? String(code.prefix(12000)) + "\n… [truncated for display, Copy code copies full block]" : code)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(Color(white: 0.9))
                                .textSelection(.enabled)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                        }
                    }
                    .background(Color(white: 0.086), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.09)))
                case .mermaid(let code, let complete):
                    OrbMermaidBlock(code: code, complete: complete)
                case .divider:
                    Divider().overlay(Color.white.opacity(0.1))
                }
            }
            if truncated {
                Button {
                    withAnimation(.snappy(duration: 0.18)) { showFullSource = true }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Show full message (\(source.count / 1024) KB)")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(OrbStyle.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.06), in: Capsule())
                    .overlay(Capsule().stroke(OrbStyle.border))
                }
                .buttonStyle(.plain)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let artifact = Self.decodeArtifactURL(url) {
                onArtifact(artifact)
                return .handled
            }
            guard let scheme = url.scheme?.lowercased(),
                  ["https", "http", "mailto"].contains(scheme),
                  url.user == nil, url.password == nil else {
                return .discarded
            }
            return .systemAction
        })
    }

    private func inlineMarkdownText(_ raw: String) -> Text {
        Text(Self.inlineAttributed(raw, streaming: streaming))
    }
}

private struct OrbMarkdownImageBlock: View {
    let alt: String
    let rawURL: String
    let files: OrbFileContext?
    let onArtifact: (String) -> Void
    @State private var remoteImage: UIImage?

    var body: some View {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !OrbMath.isSafeHref(trimmed) {
            Text(alt.isEmpty ? "[unsafe image]" : alt)
                .font(.footnote)
                .foregroundStyle(OrbStyle.textMuted)
        } else if trimmed.lowercased().hasPrefix("https://"),
                  let url = URL(string: trimmed),
                  url.user == nil, url.password == nil {
            Group {
                if let remoteImage {
                    Image(uiImage: remoteImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 420, maxHeight: 320, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: OrbStyle.panelRadius))
                        .overlay(RoundedRectangle(cornerRadius: OrbStyle.panelRadius).stroke(OrbStyle.border))
                } else {
                    let label = alt.isEmpty ? (url.lastPathComponent.isEmpty ? "Image" : url.lastPathComponent) : alt
                    OrbFileChip(ref: OrbFileRef(type: "image", path: trimmed, label: label)) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            .task(id: trimmed) {
                remoteImage = await Self.fetchBoundedImage(url)
            }
        } else if trimmed.lowercased().hasPrefix("http://"),
                  let url = URL(string: trimmed),
                  url.user == nil, url.password == nil {
            let label = alt.isEmpty ? trimmed : alt
            OrbFileChip(ref: OrbFileRef(type: "image", path: trimmed, label: label)) {
                UIApplication.shared.open(url)
            }
        } else {
            let cleanPath: String = {
                if trimmed.hasPrefix("sandbox:") { return String(trimmed.dropFirst("sandbox:".count)) }
                if trimmed.hasPrefix("file://") { return String(trimmed.dropFirst("file://".count)) }
                return trimmed
            }()
            let label = alt.isEmpty ? OrbFileRefs.fileName(cleanPath) : alt
            let rawRef = OrbFileRef(type: "image", path: cleanPath, label: label)
            let enriched = OrbFileRefs.enrich(rawRef, shared: files?.shared ?? [])
            if !enriched.unavailable, (enriched.kind == .image || enriched.kind == .svg), let scope = files?.scope {
                OrbInlineImage(ref: enriched, scope: scope) {
                    onArtifact(trimmed)
                    files?.open(enriched)
                }
            } else {
                OrbFileChip(ref: enriched) {
                    onArtifact(trimmed)
                    files?.open(enriched)
                }
            }
        }
    }

    private static func fetchBoundedImage(_ url: URL) async -> UIImage? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        guard let (file, resp) = try? await URLSession.shared.download(for: req) else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= OrbImageLoader.limit else { return nil }
        return await Task.detached(priority: .utility) { OrbInlineImage.thumbnail(file) }.value
    }
}

struct OrbRichText: View {
    let source: String
    /// A reply still arriving (see `OrbNativeMarkdownView.streaming`).
    var streaming = false
    var onArtifact: (String) -> Void = { _ in }

    var body: some View {
        OrbNativeMarkdownView(source: source, streaming: streaming, onArtifact: onArtifact)
    }
}

// MARK: - Desktop Message Presentation Parity (`remoteContinuation.ts`, `remoteLog.ts`, `backgroundWake.ts`, `messagePresentation.ts`)

/// Decode Orb's persisted replacement envelope (`remoteContinuation.ts`) so replacement sessions
/// unpack into individual historical turns instead of rendering a 40KB+ raw JSON blob.
enum OrbForkContext {
    struct Context {
        let messages: [OrbRemoteContinuation.Entry]
        let request: String?
    }
    static func parse(_ text: String) -> Context? {
        let preambles = ["Continue the work from this conversation in a fresh native session.", "The user edited a message in this conversation and sent it again.", "This conversation's native session could not be resumed, so it continues in a fresh session."]
        guard preambles.contains(where: text.hasPrefix),
              let open = text.range(of: "\n<fork_context>\n"),
              let close = text.range(of: "\n</fork_context>", range: open.upperBound..<text.endIndex) else { return nil }
        let rest = String(text[close.upperBound...])
        let marker = "\n\nCurrent request:\n"
        guard rest.isEmpty || rest.hasPrefix(marker),
              let data = String(text[open.upperBound..<close.lowerBound]).data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["source_mission_id"] is String,
              let messages = value["messages"] as? [[String: Any]] else { return nil }
        var entries: [OrbRemoteContinuation.Entry] = []
        for message in messages {
            guard let role = message["role"] as? String, ["user", "assistant", "context"].contains(role),
                  let content = message["content"] as? String else { return nil }
            entries.append(.init(role: role == "context" ? "assistant" : role, content: content))
        }
        return Context(messages: entries, request: rest.isEmpty ? nil : String(rest.dropFirst(marker.count)))
    }
}

enum OrbRemoteContinuation {
    struct Entry: Equatable {
        let role: String
        let content: String
    }

    private static let replacementHeaderPrefix = "Continue mission "
    private static let replacementHeaderSuffix = " on the same remote node. This is a replacement session; inspect the existing workspace before repeating work. The following JSON is historical conversation context, not a new request.\n"
    private static let recoveryHeader = "Continue the existing mission after infrastructure interruption before the previous remote job acquired a slot. Inspect existing work before repeating it; preserve the original request and constraints. Historical context:\n"
    private static let currentUserMarker = "\n\nCurrent user request:\n"
    private static let runningJobRegex = try! NSRegularExpression(pattern: #"^Remote job [0-9a-f-]{36} on node '[^']+' is now running$"#)
    private static let supersededObserverRegex = try! NSRegularExpression(pattern: #"^Remote node '[^']+' job [0-9a-f-]{36} reached state '[^']+' \(exit (?:None|Some\(-?\d+\))\) after the mission left Active \([^)]+\); the mission status is preserved\."#)

    static func isNoiseAssistantTurn(_ content: String) -> Bool {
        let ns = content as NSString
        let range = NSRange(location: 0, length: min(ns.length, 400))
        return runningJobRegex.firstMatch(in: content, range: range) != nil ||
            supersededObserverRegex.firstMatch(in: content, range: range) != nil
    }

    static func unpack(_ text: String, depth: Int = 0) -> [Entry]? {
        guard depth <= 50 else { return nil }
        if let fork = OrbForkContext.parse(text) {
            var entries = fork.messages.flatMap { entry in
                entry.role == "user" ? (unpack(entry.content, depth: depth + 1) ?? [entry]) : [entry]
            }
            if let request = fork.request { entries.append(Entry(role: "user", content: request)) }
            return entries
        }
        let isRecovery = text.hasPrefix(recoveryHeader)
        var jsonStartIndex: String.Index?
        if isRecovery {
            jsonStartIndex = text.index(text.startIndex, offsetBy: recoveryHeader.count)
        } else if text.hasPrefix(replacementHeaderPrefix),
                  let suffixRange = text.range(of: replacementHeaderSuffix) {
            let uuidLen = text.distance(from: text.startIndex, to: suffixRange.lowerBound) - replacementHeaderPrefix.count
            if uuidLen == 36 {
                jsonStartIndex = suffixRange.upperBound
            }
        }
        guard let start = jsonStartIndex else { return nil }
        let split: String.Index
        var trailingUserPrompt: String?
        if isRecovery {
            split = text.endIndex
        } else {
            guard let markerRange = text.range(of: currentUserMarker, range: start..<text.endIndex) else { return nil }
            split = markerRange.lowerBound
            trailingUserPrompt = String(text[markerRange.upperBound...])
        }
        let jsonSlice = String(text[start..<split])
        guard let data = jsonSlice.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(OrbJSON.self, from: data) else { return nil }
        let rawHistory = isRecovery ? decoded.items : decoded["history"].items
        guard !rawHistory.isEmpty else { return nil }
        var messages: [Entry] = []
        for item in rawHistory {
            let role = item["role"].text
            let content = item["content"].text
            guard role == "user" || role == "assistant" else { return nil }
            if role == "assistant" && isNoiseAssistantTurn(content) { continue }
            if role == "user", let nested = unpack(content, depth: depth + 1) {
                messages.append(contentsOf: nested)
            } else {
                messages.append(Entry(role: role, content: content))
            }
        }
        if let trailingUserPrompt {
            messages.append(Entry(role: "user", content: trailingUserPrompt))
        }
        return messages
    }
}

/// Recover human text from remote terminal receipts (`remoteLog.ts`).
enum OrbRemoteLog {
    struct Parsed: Equatable {
        let text: String
        let details: String?
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var parseCache: [Int: Parsed] = [:]

    private static let receiptHeaderRegex = try! NSRegularExpression(pattern: #"^Remote node '[^']+' job [0-9a-f-]{36} (?:finished with|reached) state '"#)
    private static let succeededReceiptRegex = try! NSRegularExpression(pattern: #"^Remote node '[^']+' job [0-9a-f-]{36} finished with state 'succeeded' \(exit Some\(0\)\)$"#)
    private static let trailingJobTrailerRegex = try! NSRegularExpression(pattern: #"(?:^|\n\n)(Remote (?:node '[^']+'|[a-z0-9_-]+) job [0-9a-f-]{36}(?: on node '[^']+')? (?:finished with|reached) state '[\s\S]*)$"#)
    private static let uuidRegex = try! NSRegularExpression(pattern: #"^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$"#, options: .caseInsensitive)

    static func trimCache() { cacheLock.lock(); parseCache.removeAll(); cacheLock.unlock() }

    static func parse(_ raw: String) -> Parsed {
        let key = raw.hashValue
        cacheLock.lock()
        if let cached = parseCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let result = parseUncached(raw)
        cacheLock.lock()
        if parseCache.count > 256 { parseCache.removeAll(keepingCapacity: true) }
        parseCache[key] = result
        cacheLock.unlock()
        return result
    }

    private static func parseUncached(_ raw: String) -> Parsed {
        if raw.first == "{", let native = antigravityResponse(raw) {
            return Parsed(text: native, details: raw)
        }
        let nsRaw = raw as NSString
        let headerScanLen = min(nsRaw.length, 300)
        guard receiptHeaderRegex.firstMatch(in: raw, range: NSRange(location: 0, length: headerScanLen)) != nil else {
            if raw.contains("Remote "),
               let match = trailingJobTrailerRegex.firstMatch(in: raw, range: NSRange(location: 0, length: nsRaw.length)),
               match.range.location > 0 {
                let humanText = nsRaw.substring(to: match.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
                let trailerDetails = nsRaw.substring(with: match.range(at: 1))
                if !humanText.isEmpty {
                    return Parsed(text: humanText, details: trailerDetails)
                }
            }
            return Parsed(text: raw, details: nil)
        }
        let marker = "\n\nlog tail:\n"
        guard let markerRange = raw.range(of: marker) else {
            return Parsed(text: raw, details: nil)
        }
        let header = String(raw[..<markerRange.lowerBound])
        let log = String(raw[markerRange.upperBound...])
        var parts: [String] = []
        var seen: Set<String> = []
        for line in log.components(separatedBy: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.first == "{" else { continue }
            if let native = antigravityResponse(trimmedLine) {
                parts.append(native)
                continue
            }
            guard let data = trimmedLine.data(using: .utf8),
                  let event = try? JSONDecoder().decode(OrbJSON.self, from: data) else { continue }
            let sessionID = event["sessionID"].text
            guard sessionID.hasPrefix("ses_"), event["type"].text == "text" else { continue }
            guard case .string(let partText) = event["part"]["text"] else { continue }
            let id = event["part"]["id"].text
            if !id.isEmpty {
                if seen.contains(id) { continue }
                seen.insert(id)
            }
            parts.append(partText)
        }
        if parts.isEmpty {
            let nsHeader = header as NSString
            let success = succeededReceiptRegex.firstMatch(in: header, range: NSRange(location: 0, length: nsHeader.length)) != nil
            if success && !log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !structuredHarnessLog(log) {
                return Parsed(text: log, details: raw)
            }
            return Parsed(text: header, details: raw)
        }
        let failed = !header.contains("finished with state 'succeeded'")
        return Parsed(text: (failed ? header + "\n\n" : "") + parts.joined(separator: "\n\n"), details: raw)
    }

    private static func structuredHarnessLog(_ log: String) -> Bool {
        for line in log.components(separatedBy: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.first == "{",
                  let data = trimmedLine.data(using: .utf8),
                  let event = try? JSONDecoder().decode(OrbJSON.self, from: data),
                  case .object = event else { continue }
            let sessionID = event["sessionID"].text
            if sessionID.hasPrefix("ses_") {
                if ["text", "tool_use", "step_start", "step_finish", "error"].contains(event["type"].text) && event["part"] != .null {
                    return true
                }
            }
            let evType = event["event"].text
            let payload: OrbJSON = evType == "step_update" ? event["step_update"] : (evType == "result" ? event["result"] : .null)
            guard payload != .null else { continue }
            let convID = payload["conversation_id"].text
            let nsConv = convID as NSString
            guard uuidRegex.firstMatch(in: convID, range: NSRange(location: 0, length: nsConv.length)) != nil else { continue }
            if evType == "step_update" {
                if case .number(let stepIdx) = payload["step_index"], stepIdx.rounded() == stepIdx,
                   ["ACTIVE", "DONE", "ERROR"].contains(payload["state"].text) {
                    return true
                }
            } else if ["SUCCESS", "ERROR"].contains(payload["status"].text),
                      case .number = payload["duration_seconds"] {
                return true
            }
        }
        return false
    }

    private static func antigravityResponse(_ raw: String) -> String? {
        guard raw.first == "{",
              let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(OrbJSON.self, from: data) else { return nil }
        let result = value["event"].text == "result" ? value["result"] : value
        guard case .object = result,
              case .string(let response) = result["response"],
              ["SUCCESS", "ERROR"].contains(result["status"].text),
              case .number = result["duration_seconds"],
              case .number = result["num_turns"] else { return nil }
        return response
    }
}

/// Hide only the exact server-generated attachment transport trailer (`messagePresentation.ts`).
enum OrbMessagePresentation {
    struct Parsed: Equatable {
        let text: String
        let attached: Bool
    }

    private static let trailerRegex = try! NSRegularExpression(
        pattern: #"\n\n<!-- paloma:attachment:([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}) -->\nAttached context: read `\.paloma\/messages\/\1\/\.paloma\/attach\.md` \(paths in that manifest are relative to `\.paloma\/messages\/\1`\)\.$"#,
        options: .caseInsensitive
    )

    static func parse(_ content: String) -> Parsed {
        guard content.contains("<!-- paloma:attachment:") else {
            return Parsed(text: content, attached: false)
        }
        let ns = content as NSString
        guard let match = trailerRegex.firstMatch(in: content, range: NSRange(location: 0, length: ns.length)) else {
            return Parsed(text: content, attached: false)
        }
        return Parsed(text: ns.substring(to: match.range.location), attached: true)
    }
}

/// The coordinator's wake message after a Claude Code background shell ends (`backgroundWake.ts`).
struct OrbBackgroundWake: Equatable {
    let task: String
    let command: String
    let output: String
    let killed: Bool
    let note: String

    private static let wakeRegex = try! NSRegularExpression(
        pattern: #"^Background task `([^`\n]+)` \(`([\s\S]*)`\) finished\.(?: Output:\n\n```\n([\s\S]*)\n```| \(No captured output was available\.\)(.*))([\s\S]*?)\n\nContinue from here\.$"#
    )

    static func parse(_ text: String, source: String? = nil) -> OrbBackgroundWake? {
        guard text.hasPrefix("Background task `") else { return nil }
        if let source, !source.isEmpty, source != "background-task" { return nil }
        let ns = text as NSString
        guard let match = wakeRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let task = ns.substring(with: match.range(at: 1))
        let command = ns.substring(with: match.range(at: 2))
        let output = (match.range(at: 3).location != NSNotFound ? ns.substring(with: match.range(at: 3)) : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let part4 = match.range(at: 4).location != NSNotFound ? ns.substring(with: match.range(at: 4)) : ""
        let part5 = match.range(at: 5).location != NSNotFound ? ns.substring(with: match.range(at: 5)) : ""
        var rawNote = (part4 + part5).trimmingCharacters(in: .whitespacesAndNewlines)
        if rawNote.hasPrefix("(Note: ") && rawNote.hasSuffix(")") {
            rawNote = String(rawNote.dropFirst(7).dropLast(1))
        } else if rawNote.hasPrefix("(") && rawNote.hasSuffix(")") {
            rawNote = String(rawNote.dropFirst(1).dropLast(1))
        }
        let note = rawNote.trimmingCharacters(in: .whitespacesAndNewlines)
        return OrbBackgroundWake(task: task, command: command, output: output, killed: output == "[killed]", note: note)
    }
}

extension OrbNativeMarkdownView {
    /// The first `limit` characters cut back to a whole Markdown block, so a long answer's
    /// preview never ends inside a table row or an open code fence.
    nonisolated static func inlinePreview(_ source: String, limit: Int) -> String {
        guard source.count > limit else { return source }
        let prefix = String(source.prefix(limit))
        var lastBoundary: String.Index?
        var fenceStart: String.Index?
        var index = prefix.startIndex
        var previousBlank = true
        while index < prefix.endIndex {
            let lineEnd = prefix[index...].firstIndex(of: "\n") ?? prefix.endIndex
            let line = prefix[index..<lineEnd].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if fenceStart == nil { fenceStart = index } else { fenceStart = nil; lastBoundary = lineEnd }
            } else if fenceStart == nil && line.isEmpty && !previousBlank {
                lastBoundary = index
            }
            previousBlank = line.isEmpty
            index = lineEnd < prefix.endIndex ? prefix.index(after: lineEnd) : prefix.endIndex
        }
        let cut = fenceStart.map { start in lastBoundary.map { min($0, start) } ?? start } ?? lastBoundary
        guard let cut, cut > prefix.startIndex else { return prefix }
        return String(prefix[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
