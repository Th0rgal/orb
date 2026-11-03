import Foundation

/// Splits opening Markdown code fences glued to the end of a prose line without
/// a newline (e.g. `cleanly!```mermaid`).
/// Desktop parity: orb/src/codeFences.ts; Android: OrbCodeFences.kt; cases in
/// shared/orb-spec/fixtures/glued-code-fences.json.
enum OrbCodeFences {
    struct GluedFence: Equatable, Sendable {
        let utf8Offset: Int
        let lang: String
    }

    private static func isAsciiAlpha(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z")) ||
            (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
    }

    private static func isFenceLangByte(_ b: UInt8) -> Bool {
        isAsciiAlpha(b) ||
            (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")) ||
            b == UInt8(ascii: "_") ||
            b == UInt8(ascii: "+") ||
            b == UInt8(ascii: ".") ||
            b == UInt8(ascii: "#") ||
            b == UInt8(ascii: "-")
    }

    static func splitGlued<S: StringProtocol>(_ raw: S) -> GluedFence? {
        if let result = raw.utf8.withContiguousStorageIfAvailable({ scanGlued($0) }) {
            return result
        }
        let copy = Array(raw.utf8)
        return copy.withUnsafeBufferPointer { scanGlued($0) }
    }

    private static func scanGlued(_ utf8: UnsafeBufferPointer<UInt8>) -> GluedFence? {
        var cleanLen = utf8.count
        if cleanLen > 0 && utf8[cleanLen - 1] == UInt8(ascii: "\r") {
            cleanLen -= 1
        }
        guard cleanLen >= 5 else { return nil }

        var hasTriple = false
        var s = 0
        while s + 2 < cleanLen {
            if utf8[s] == UInt8(ascii: "`") && utf8[s + 1] == UInt8(ascii: "`") && utf8[s + 2] == UInt8(ascii: "`") {
                hasTriple = true
                break
            }
            s += 1
        }
        guard hasTriple else { return nil }

        var lead = 0
        while lead < cleanLen && (utf8[lead] == UInt8(ascii: " ") || utf8[lead] == UInt8(ascii: "\t")) {
            lead += 1
        }
        guard lead < cleanLen else { return nil }

        let first = utf8[lead]
        if first == UInt8(ascii: "|") || first == UInt8(ascii: ">") { return nil }
        if (first == UInt8(ascii: "`") || first == UInt8(ascii: "~")) &&
            lead + 2 < cleanLen && utf8[lead + 1] == first && utf8[lead + 2] == first {
            return nil
        }

        var i = lead
        while i < cleanLen {
            let ch = utf8[i]
            if ch == UInt8(ascii: "\\") && i + 1 < cleanLen {
                i += 2
                continue
            }
            if ch == UInt8(ascii: "`") {
                let tickStart = i
                while i < cleanLen && utf8[i] == UInt8(ascii: "`") { i += 1 }
                let ticks = i - tickStart

                var j = i
                var closedAt = -1
                while j + ticks <= cleanLen {
                    if utf8[j] == UInt8(ascii: "`") {
                        let runStart = j
                        while j < cleanLen && utf8[j] == UInt8(ascii: "`") { j += 1 }
                        if j - runStart == ticks {
                            closedAt = runStart
                            break
                        }
                    } else {
                        j += 1
                    }
                }
                if closedAt != -1 {
                    i = closedAt + ticks
                    continue
                }

                if ticks == 3 && tickStart > lead && i < cleanLen && isAsciiAlpha(utf8[i]) {
                    var k = i + 1
                    while k < cleanLen && isFenceLangByte(utf8[k]) { k += 1 }
                    if k - i <= 32 {
                        var m = k
                        while m < cleanLen && (utf8[m] == UInt8(ascii: " ") || utf8[m] == UInt8(ascii: "\t")) {
                            m += 1
                        }
                        if m == cleanLen {
                            let before = String(decoding: utf8[0..<tickStart], as: UTF8.self)
                            if !before.trimmingCharacters(in: .whitespaces).isEmpty {
                                let lang = String(decoding: utf8[i..<k], as: UTF8.self)
                                return GluedFence(utf8Offset: tickStart, lang: lang)
                            }
                        }
                    }
                }
                continue
            }
            i += 1
        }
        return nil
    }

    private static func hasGluedFence(_ src: String) -> Bool {
        let utf8 = src.utf8
        var inFence = false
        var lineStart = utf8.startIndex
        while true {
            let nl = utf8[lineStart...].firstIndex(of: UInt8(ascii: "\n"))
            let lineEnd = nl ?? utf8.endIndex
            let lineSub = Substring(utf8[lineStart..<lineEnd])
            if lineSub.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
            } else if !inFence && splitGlued(lineSub) != nil {
                return true
            }
            guard let nl else { break }
            lineStart = utf8.index(after: nl)
        }
        return false
    }

    static func normalize(_ src: String) -> String {
        guard src.contains("```"), hasGluedFence(src) else { return src }
        let lines = src.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count + 2)
        var inFence = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                out.append(line)
                continue
            }
            if !inFence, let glued = splitGlued(line) {
                let utf8 = line.utf8
                let splitIdx = utf8.index(utf8.startIndex, offsetBy: glued.utf8Offset)
                out.append(String(Substring(utf8[..<splitIdx])))
                out.append(String(Substring(utf8[splitIdx...])))
                inFence = true
                continue
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}
