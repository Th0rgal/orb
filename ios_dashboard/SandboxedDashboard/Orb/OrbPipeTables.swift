import Foundation

/// Rewrites loose `a | b | c` pipe rows into GFM tables before Markdown parsing.
/// Desktop parity: orb/src/pipeTables.ts (rules documented there); cases in
/// shared/orb-spec/fixtures/loose-pipe-tables.json.
enum OrbPipeTables {
    static func isNumericCell(_ cell: String) -> Bool {
        let t = cell.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = t.range(of: "^[+\\-\u{2212}]?[$€£]?[0-9][0-9\u{00a0}\u{202f} ,.']*%?$", options: .regularExpression) != nil
        let hasDigit = t.contains { $0 >= "0" && $0 <= "9" }
        return OrbKernel.numericCellAdmitted(
            nonEmpty: !t.isEmpty,
            hasLeadingDigitOrSign: matches,
            hasDigit: hasDigit,
            allAllowedChars: matches
        )
    }

    private static func isSpace(_ c: Character?) -> Bool { c.map { $0 == " " || $0 == "\t" } ?? false }

    /// The cells of a loose row, or nil when the line is not one.
    static func cells(_ line: String) -> [String]? {
        if line.hasPrefix("    ") || line.hasPrefix("\t") { return nil }
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.contains("|") || t.hasPrefix("|") { return nil }
        if t.range(of: "^(#|>|[-*+]\\s|[0-9]+[.)]\\s)", options: .regularExpression) != nil { return nil }
        let chars = Array(t)
        var inCode = false
        var start = 0
        var out: [String] = []
        for i in chars.indices {
            let c = chars[i]
            if c == "`" { inCode.toggle() } else if c == "|" {
                if inCode { return nil }
                if !isSpace(i > 0 ? chars[i - 1] : nil) || !isSpace(i + 1 < chars.count ? chars[i + 1] : nil) { return nil }
                out.append(String(chars[start..<i]).trimmingCharacters(in: .whitespacesAndNewlines))
                start = i + 1
            }
        }
        out.append(String(chars[start...]).trimmingCharacters(in: .whitespacesAndNewlines))
        return out.count >= 3 && !inCode ? out : nil
    }

    private static func row(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }

    private static func gfm(_ rows: [[String]]) -> [String] {
        let width = rows[0].count
        let hasHeader = !rows[0].contains { !$0.isEmpty && isNumericCell($0) }
        let head = hasHeader ? rows[0] : Array(repeating: "", count: width)
        let body = hasHeader ? Array(rows.dropFirst()) : rows
        let aligns = (0..<width).map { col -> String in
            let cells = body.map { col < $0.count ? $0[col] : "" }.filter { !$0.isEmpty }
            return !cells.isEmpty && cells.allSatisfy(isNumericCell) ? "---:" : "---"
        }
        return [row(head), row(aligns)] + body.map { row($0 + Array(repeating: "", count: width - $0.count)) }
    }

    private static func fenceMarker(_ line: String) -> String? {
        let t = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let f = t.first, f == "`" || f == "~" else { return nil }
        let run = t.prefix(while: { $0 == f })
        return run.count >= 3 ? String(run) : nil
    }

    private static func hasLoosePipeOutsideFence(_ src: String) -> Bool {
        let utf8 = src.utf8
        var scanFenceChar: UInt8 = 0
        var scanFenceLen = 0
        var lineStart = utf8.startIndex
        while true {
            let nl = utf8[lineStart...].firstIndex(of: UInt8(ascii: "\n"))
            let lineEnd = nl ?? utf8.endIndex
            var p = lineStart
            while p < lineEnd && (utf8[p] == UInt8(ascii: " ") || utf8[p] == UInt8(ascii: "\t")) {
                p = utf8.index(after: p)
            }
            let c = p < lineEnd ? utf8[p] : 0
            if c == UInt8(ascii: "`") || c == UInt8(ascii: "~") {
                var q = p
                var run = 0
                while q < lineEnd && utf8[q] == c {
                    run += 1
                    q = utf8.index(after: q)
                }
                if run >= 3 {
                    if scanFenceLen > 0 {
                        if c == scanFenceChar && run >= scanFenceLen {
                            scanFenceChar = 0
                            scanFenceLen = 0
                        }
                    } else {
                        scanFenceChar = c
                        scanFenceLen = run
                    }
                    guard let nl else { break }
                    lineStart = utf8.index(after: nl)
                    continue
                }
            }
            if scanFenceLen == 0 && c != UInt8(ascii: "|") && p < lineEnd {
                var cur = p
                while let bar = utf8[cur..<lineEnd].firstIndex(of: UInt8(ascii: "|")) {
                    if bar > p {
                        let prev = utf8[utf8.index(before: bar)]
                        let nextIdx = utf8.index(after: bar)
                        if prev == UInt8(ascii: " ") && nextIdx < lineEnd && utf8[nextIdx] == UInt8(ascii: " ") {
                            return true
                        }
                    }
                    cur = utf8.index(after: bar)
                }
            }
            guard let nl else { break }
            lineStart = utf8.index(after: nl)
        }
        return false
    }

    static func normalize(_ src: String) -> String {
        guard src.contains(" | "), hasLoosePipeOutsideFence(src) else { return src }
        let lines = src.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var starts = [Int](repeating: 0, count: lines.count)
        for k in lines.indices.dropFirst() { starts[k] = starts[k - 1] + lines[k - 1].utf16.count + 1 }
        let bufLen = src.utf16.count
        func admitted(_ k: Int, _ cells: [String], sepCols: Int) -> Bool {
            let lead = lines[k].prefix(while: { $0 == " " || $0 == "\t" }).utf16.count
            let rowLen = lines[k].trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
            return OrbKernel.gfmPipeRowAdmitted(rowOff: starts[k] + lead, rowLen: rowLen, bufLen: bufLen, colCount: cells.count, sepCols: sepCols)
        }
        var out: [String] = []
        var fence: String?
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let marker = fenceMarker(line)
            if let open = fence {
                if let m = marker, m.first == open.first, m.count >= open.count { fence = nil }
                out.append(line); i += 1; continue
            }
            if marker != nil { fence = marker; out.append(line); i += 1; continue }
            guard let first = cells(line), admitted(i, first, sepCols: first.count) else { out.append(line); i += 1; continue }
            var rows = [first]
            var j = i + 1
            while j < lines.count, let c = cells(lines[j]), c.count == first.count, admitted(j, c, sepCols: first.count) { rows.append(c); j += 1 }
            let isGfm = rows.count >= 2 && rows[1].allSatisfy {
                $0.filter { !$0.isWhitespace }.range(of: "^:?-+:?$", options: .regularExpression) != nil
            }
            if rows.count < 2 || isGfm {
                out.append(contentsOf: lines[i..<j]); i = j; continue
            }
            if j == lines.count - 1 && lines[j].contains(" |") {
                let t = lines[j].trimmingCharacters(in: .whitespacesAndNewlines)
                let partial = t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if partial.count < first.count && !t.hasPrefix("|") { rows.append(partial); j += 1 }
            }
            if let last = out.last, !last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("") }
            out.append(contentsOf: gfm(rows))
            if j < lines.count && !lines[j].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("") }
            i = j
        }
        return out.joined(separator: "\n")
    }
}

/// Verified cross-client transcript safety gates (`lean/Orb/Transcript.lean`,
/// checked against `shared/orb-spec/fixtures/transcript-gates.json`).
enum OrbTranscriptGates {
    nonisolated static let maxLatexSpanChars = 8192

    struct CandidateKey: Hashable, Sendable {
        let tag: Int
        let item: Int
    }

    struct TurnKey: Equatable, Hashable, Sendable {
        let tag: Int
        let item: Int
        let gen: Int
    }

    nonisolated static func allocTurnKeys(_ candidates: [CandidateKey]) -> [TurnKey] {
        var seen = Set<CandidateKey>()
        var nextGen = 1
        var out: [TurnKey] = []
        out.reserveCapacity(candidates.count)
        for c in candidates {
            if seen.contains(c) {
                out.append(TurnKey(tag: c.tag, item: c.item, gen: nextGen))
                nextGen += 1
            } else {
                seen.insert(c)
                out.append(TurnKey(tag: c.tag, item: c.item, gen: 0))
            }
        }
        return out
    }

    /// Ensures strictly unique, non-empty row IDs (`ForEach` / `LazyColumn` safety)
    /// while leaving already-distinct non-empty IDs untouched (`gen == 0`).
    nonisolated static func ensureUniqueIds(_ candidates: [String]) -> [String] {
        var seen = Set<String>()
        var nextGen = 1
        var out: [String] = []
        out.reserveCapacity(candidates.count)
        for raw in candidates {
            if !raw.isEmpty && !seen.contains(raw) {
                seen.insert(raw)
                out.append(raw)
            } else {
                let base = raw.isEmpty ? "turn" : raw
                while seen.contains("\(base)#\(nextGen)") {
                    nextGen += 1
                }
                let fresh = "\(base)#\(nextGen)"
                nextGen += 1
                seen.insert(fresh)
                out.append(fresh)
            }
        }
        return out
    }

    nonisolated static func ensureUniqueRows(_ rows: [(String, String, String)]) -> [(String, String, String)] {
        let uniqueIds = ensureUniqueIds(rows.map(\.0))
        return zip(uniqueIds, rows).map { id, row in (id, row.1, row.2) }
    }

    nonisolated static func latexSpanAdmitted(
        len: Int,
        prevBlocked: Bool,
        nextDigit: Bool,
        leadSpace: Bool,
        trailSpace: Bool,
        hasNewline: Bool,
        firstDigit: Bool,
        internalSpace: Bool,
        hasMathOp: Bool
    ) -> Bool {
        len > 0 &&
            len <= maxLatexSpanChars &&
            !prevBlocked &&
            !nextDigit &&
            !leadSpace &&
            !trailSpace &&
            !hasNewline &&
            !(firstDigit && internalSpace && !hasMathOp)
    }

    nonisolated static func visibleTurnCount(
        total: Int,
        baseLimit: Int,
        expandedSteps: Int,
        stepSize: Int
    ) -> Int {
        let cap = max(0, baseLimit) + max(0, expandedSteps) * max(0, stepSize)
        return min(max(0, total), cap)
    }

    nonisolated static func hiddenTurnCount(
        total: Int,
        baseLimit: Int,
        expandedSteps: Int,
        stepSize: Int
    ) -> Int {
        max(0, total) - visibleTurnCount(total: total, baseLimit: baseLimit, expandedSteps: expandedSteps, stepSize: stepSize)
    }

    nonisolated static func admitMount(active: Int, cap: Int) -> (admitted: Bool, nextActive: Int) {
        let a = max(0, active)
        let c = max(0, cap)
        return a < c ? (true, a + 1) : (false, a)
    }
}
