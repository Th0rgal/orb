import Foundation

/// Rewrites loose `a | b | c` pipe rows into GFM tables before Markdown parsing.
/// Desktop parity: orb/src/pipeTables.ts (rules documented there); cases in
/// shared/orb-spec/fixtures/loose-pipe-tables.json.
enum OrbPipeTables {
    static func isNumericCell(_ cell: String) -> Bool {
        let t = cell.trimmingCharacters(in: .whitespaces)
        return t.range(of: "^[+\\-\u{2212}]?[$€£]?[0-9][0-9\u{00a0}\u{202f} ,.']*%?$", options: .regularExpression) != nil
    }

    private static func isSpace(_ c: Character?) -> Bool { c.map { $0 == " " || $0 == "\t" } ?? false }

    /// The cells of a loose row, or nil when the line is not one.
    static func cells(_ line: String) -> [String]? {
        if line.hasPrefix("    ") || line.hasPrefix("\t") { return nil }
        let t = line.trimmingCharacters(in: .whitespaces)
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
                out.append(String(chars[start..<i]).trimmingCharacters(in: .whitespaces))
                start = i + 1
            }
        }
        out.append(String(chars[start...]).trimmingCharacters(in: .whitespaces))
        return out.count >= 3 && OrbKernel.gfmPipeRowAdmitted(rowLen: t.count, colCount: out.count, sepCols: out.count, unterminatedEscape: inCode) ? out : nil
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

    static func normalize(_ src: String) -> String {
        guard src.contains(" | ") else { return src }
        let lines = src.components(separatedBy: "\n")
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
            guard let first = cells(line) else { out.append(line); i += 1; continue }
            var rows = [first]
            var j = i + 1
            while j < lines.count, let c = cells(lines[j]), c.count == first.count { rows.append(c); j += 1 }
            let isGfm = rows.count >= 2 && rows[1].allSatisfy {
                $0.filter { !$0.isWhitespace }.range(of: "^:?-+:?$", options: .regularExpression) != nil
            }
            if rows.count < 2 || isGfm {
                out.append(contentsOf: lines[i..<j]); i = j; continue
            }
            if j == lines.count - 1 && lines[j].contains(" |") {
                let t = lines[j].trimmingCharacters(in: .whitespaces)
                let partial = t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if partial.count < first.count && !t.hasPrefix("|") { rows.append(partial); j += 1 }
            }
            if let last = out.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { out.append("") }
            out.append(contentsOf: gfm(rows))
            if j < lines.count && !lines[j].trimmingCharacters(in: .whitespaces).isEmpty { out.append("") }
            i = j
        }
        return out.joined(separator: "\n")
    }
}
