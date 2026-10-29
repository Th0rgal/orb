import Foundation

/// Shared mobile UI compaction & sanitization rules (`shared/orb-spec/fixtures/mobile-debloat.json`),
/// mirrored in Android `OrbActivityCompaction.kt`.
enum OrbActivityCompaction {
    struct CoalescedCommand: Identifiable, Equatable, Sendable {
        let id: String
        let status: String
        let exitCode: Int?
        let host: String
        let command: String
        let missionId: String
        let timestamp: String
        let detail: String
    }

    struct ErrorInput: Equatable, Sendable {
        let category: String
        let summary: String
        let detail: String
        let at: Double
    }

    struct CoalescedError: Identifiable, Equatable, Sendable {
        var id: String { "\(category)|\(summary)|\(detail)|\(at)" }
        let category: String
        let summary: String
        let detail: String
        let count: Int
        let at: Double
    }

    static let preExecPrefix = "[pre-exec] "

    /// Coalesces newest-first privilege command audit entries by pairing each `EXIT <code>`
    /// row with its nearest older matching `[pre-exec]` row on the same host. Unmatched
    /// `[pre-exec]` rows remain visible as in-flight `RUN` rows with the prefix stripped.
    static func coalescePrivilegeCommands(_ commands: [OrbJSON]) -> [CoalescedCommand] {
        var consumed = Set<Int>()
        var result: [CoalescedCommand] = []
        for idx in commands.indices {
            if consumed.contains(idx) { continue }
            let entry = commands[idx]
            let host = !entry["target_host"].text.isEmpty ? entry["target_host"].text : entry["host"].text
            let rawCmd = entry["command"].text.trimmingCharacters(in: .whitespacesAndNewlines)
            let exitVal = entry["exit_code"].doubleValue.map { Int($0) }
            let id = entry["id"].text.isEmpty ? "cmd-\(idx)" : entry["id"].text
            let missionId = entry["mission_id"].text
            let grantId = entry["grant_id"].text
            let cwd = entry["cwd"].text
            let ts = !entry["at"].text.isEmpty ? entry["at"].text : (!entry["recorded_at"].text.isEmpty ? entry["recorded_at"].text : (!entry["created_at"].text.isEmpty ? entry["created_at"].text : entry["timestamp"].text))
            let stderr = entry["stderr"].text
            let stdout = entry["stdout"].text
            let detail = [stderr, stdout].filter { !$0.isEmpty }.joined(separator: "\n")

            if let code = exitVal {
                let expectedPre = preExecPrefix + rawCmd
                if idx + 1 < commands.count {
                    for olderIdx in (idx + 1)..<commands.count where !consumed.contains(olderIdx) {
                        let older = commands[olderIdx]
                        let olderHost = !older["target_host"].text.isEmpty ? older["target_host"].text : older["host"].text
                        if older["exit_code"].doubleValue == nil,
                           olderHost == host,
                           older["mission_id"].text == missionId,
                           older["grant_id"].text == grantId,
                           older["cwd"].text == cwd,
                           older["command"].text.trimmingCharacters(in: .whitespacesAndNewlines) == expectedPre {
                            consumed.insert(olderIdx)
                            break
                        }
                    }
                }
                result.append(CoalescedCommand(
                    id: id,
                    status: "EXIT \(code)",
                    exitCode: code,
                    host: host,
                    command: rawCmd,
                    missionId: missionId,
                    timestamp: ts,
                    detail: detail
                ))
            } else {
                let cleanCmd = rawCmd.hasPrefix(preExecPrefix)
                    ? String(rawCmd.dropFirst(preExecPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    : rawCmd
                result.append(CoalescedCommand(
                    id: id,
                    status: "RUN",
                    exitCode: nil,
                    host: host,
                    command: cleanCmd,
                    missionId: missionId,
                    timestamp: ts,
                    detail: detail
                ))
            }
        }
        return result
    }

    /// Collapses consecutive identical `(category, summary, detail)` error entries,
    /// keeping the newest timestamp and recording `count`.
    static func coalesceErrors(_ entries: [ErrorInput]) -> [CoalescedError] {
        var out: [CoalescedError] = []
        for entry in entries {
            if let last = out.last,
               last.category == entry.category,
               last.summary == entry.summary,
               last.detail == entry.detail {
                out[out.count - 1] = CoalescedError(
                    category: last.category,
                    summary: last.summary,
                    detail: last.detail,
                    count: last.count + 1,
                    at: last.at
                )
            } else {
                out.append(CoalescedError(
                    category: entry.category,
                    summary: entry.summary,
                    detail: entry.detail,
                    count: 1,
                    at: entry.at
                ))
            }
        }
        return out
    }

    /// Deduplicates active mission-access grants by `(requester_mission_id, target_mission_id, scope)`,
    /// keeping the grant with the latest `expires_at` while preserving first-seen order.
    static func dedupeMissionGrants(_ grants: [OrbJSON]) -> [OrbJSON] {
        var indexByKey: [String: Int] = [:]
        var out: [OrbJSON] = []
        for grant in grants {
            let req = grant["requester_mission_id"].text
            let tgt = grant["target_mission_id"].text
            let scope = grant["scope"].text
            let key = (req.isEmpty && tgt.isEmpty) ? "id:\(grant["id"].text)" : "\(req)|\(tgt)|\(scope)"
            if let existingIdx = indexByKey[key] {
                if grant["expires_at"].text > out[existingIdx]["expires_at"].text {
                    out[existingIdx] = grant
                }
            } else {
                indexByKey[key] = out.count
                out.append(grant)
            }
        }
        return out
    }

    /// Formats cooldown seconds into concise human units (`45s`, `4m 21s`, `1h`, `3d 17h`).
    static func formatCooldown(_ seconds: Int) -> String {
        if seconds <= 0 { return "0s" }
        if seconds >= 86_400 {
            let d = seconds / 86_400
            let h = (seconds % 86_400) / 3_600
            return h > 0 ? "\(d)d \(h)h" : "\(d)d"
        }
        if seconds >= 3_600 {
            let h = seconds / 3_600
            let m = (seconds % 3_600) / 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        if seconds >= 60 {
            let m = seconds / 60
            let s = seconds % 60
            return s > 0 ? "\(m)m \(s)s" : "\(m)m"
        }
        return "\(seconds)s"
    }

    /// Strips Markdown pipe-table alignment separators (`|---|---|`) and joins cells with ` · `
    /// so collapsed 2–3 line Inbox previews stay scannable.
    static func cleanInboxPreview(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let pipeCount = trimmed.reduce(into: 0) { if $1 == "|" { $0 += 1 } }
        guard pipeCount >= 2 else { return trimmed }

        let startsWithPipe = trimmed.hasPrefix("|")
        let rawParts = trimmed.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        var cells: [(text: String, isIntro: Bool)] = []
        for (idx, part) in rawParts.enumerated() {
            let collapsed = part
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if collapsed.isEmpty { continue }
            if collapsed.contains("-") && collapsed.allSatisfy({ $0 == "-" || $0 == ":" || $0 == " " }) {
                continue
            }
            cells.append((collapsed, idx == 0 && !startsWithPipe))
        }
        guard !cells.isEmpty else { return trimmed }
        var output = cells[0].text
        for cell in cells.dropFirst() {
            if cells[0].isIntro && output == cells[0].text && (output.hasSuffix(":") || output.hasSuffix(".") || output.hasSuffix("!") || output.hasSuffix("?")) {
                output += " " + cell.text
            } else {
                output += " · " + cell.text
            }
        }
        return output
    }

    /// True when an assistant message contains only whitespace or placeholder dots (`.`, `...`, `…`).
    static func isPlaceholderTurn(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return trimmed.allSatisfy { $0 == "." || $0 == "…" }
    }

    /// True only for canonical 36-character `8-4-4-4-12` hex UUIDs accepted by Core's
    /// `/api/control/inbox-state/seen/:mission_id` endpoint.
    static func isCanonicalUUID(_ id: String) -> Bool {
        let chars = Array(id.utf8)
        guard chars.count == 36 else { return false }
        for (i, b) in chars.enumerated() {
            if i == 8 || i == 13 || i == 18 || i == 23 {
                if b != UInt8(ascii: "-") { return false }
            } else {
                let isHex = (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
                    || (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "f"))
                    || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "F"))
                if !isHex { return false }
            }
        }
        return true
    }
}
