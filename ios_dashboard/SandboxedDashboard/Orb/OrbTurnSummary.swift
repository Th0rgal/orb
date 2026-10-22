import SwiftUI

/// Turn-level facts shared with Orb desktop (`TurnStatus.tsx`, `Changes.tsx`,
/// `workModel.ts`): task status vocabulary, when the turn started, what it
/// changed and where it ships.
enum OrbTurnSummary {
    /// Harnesses drift in vocabulary (blocked, done, canceled…); one odd status
    /// must not count a finished task as pending. Same mapping as the desktop.
    static func taskStatus(_ raw: String) -> String {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        if ["in_progress", "active", "running", "doing", "started"].contains(v) { return "in_progress" }
        if ["completed", "complete", "done", "finished", "succeeded"].contains(v) { return "completed" }
        if ["cancelled", "canceled", "skipped", "abandoned"].contains(v) { return "cancelled" }
        return "pending"
    }

    /// Server time of the latest delivered user message: the clock survives
    /// relaunches instead of restarting at 0:00 when the app first sees the turn.
    static func turnStart(_ events: [StoredEvent]) -> Date? {
        guard let last = events.last(where: { $0.eventType == "user_message" }) else { return nil }
        return parseDate(last.timestamp)
    }

    static func parseDate(_ raw: String) -> Date? { OrbDateCache.parse(raw) }

    /// Desktop `formatElapsed`: "20:12" read as a time of day next to the status bar clock.
    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m) min \(String(format: "%02d", s % 60)) s" }
        return "\(m / 60) h \(String(format: "%02d", m % 60))"
    }

    struct FileChange: Equatable, Identifiable {
        let file: String
        var additions: Int
        var deletions: Int
        var edits: Int
        var id: String { file }
    }

    /// Files the agent edited in this conversation, from its finished edit tool calls.
    static func changedFiles(_ events: [StoredEvent]) -> [FileChange] {
        let finished = Set(events.filter { $0.eventType == "tool_result" && $0.metadata["is_error"]?.value as? Bool != true }.compactMap(\.toolCallId))
        var order: [String] = []
        var rows: [String: FileChange] = [:]
        for event in events where event.eventType == "tool_call" {
            guard let call = event.toolCallId, finished.contains(call),
                  let stats = diffStats(tool: event.toolName ?? "", content: event.content) else { continue }
            if rows[stats.file] == nil { order.append(stats.file); rows[stats.file] = FileChange(file: stats.file, additions: 0, deletions: 0, edits: 0) }
            rows[stats.file]!.additions += stats.additions
            rows[stats.file]!.deletions += stats.deletions
            rows[stats.file]!.edits += 1
        }
        return order.compactMap { rows[$0] }.sorted { $0.additions + $0.deletions > $1.additions + $1.deletions }
    }

    static func diffStats(tool: String, content: String) -> (file: String, additions: Int, deletions: Int)? {
        let name = tool.lowercased().replacingOccurrences(of: "functions.", with: "")
        guard ["edit", "write", "multiedit", "str_replace_based_edit_tool", "write_file", "edit_file"].contains(name) else { return nil }
        let raw = (try? JSONDecoder().decode(OrbJSON.self, from: Data(content.utf8))) ?? .null
        let args = raw["input"] != .null ? raw["input"] : raw
        let file = [args["file_path"].text, args["path"].text, args["target_file"].text].first { !$0.isEmpty } ?? ""
        guard !file.isEmpty else { return nil }
        if name == "multiedit" {
            let parts = args["edits"].items.map { lineDiff(old: $0["old_string"].text, new: $0["new_string"].text) }
            return (file, parts.reduce(0) { $0 + $1.0 }, parts.reduce(0) { $0 + $1.1 })
        }
        if args["old_string"] == .null && args["new_string"] == .null {
            return (file, lines(args["content"].text).count, 0)
        }
        let d = lineDiff(old: args["old_string"].text, new: args["new_string"].text)
        return (file, d.0, d.1)
    }

    /// A trailing newline ends the last line; it does not start another one.
    private static func lines(_ text: String) -> [Substring] {
        var rows = text.split(separator: "\n", omittingEmptySubsequences: false)
        if rows.last?.isEmpty == true { rows.removeLast() }
        return rows
    }

    /// Lines added and removed once the shared head and tail are set aside.
    static func lineDiff(old: String, new: String) -> (Int, Int) {
        var a = lines(old)[...], b = lines(new)[...]
        while let x = a.first, let y = b.first, x == y { a = a.dropFirst(); b = b.dropFirst() }
        while let x = a.last, let y = b.last, x == y { a = a.dropLast(); b = b.dropLast() }
        return (b.count, a.count)
    }

    /// `github_pr` is free-form: a URL, `owner/repo#123`, or a bare number.
    static func prLink(_ raw: String) -> (label: String, url: URL?)? {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return nil }
        if let m = v.firstMatch(of: #/^https://github\.com/([^/]+/[^/]+)/pull/(\d+)/#) {
            return ("\(m.1)#\(m.2)", URL(string: v))
        }
        if let m = v.wholeMatch(of: #/([\w.-]+/[\w.-]+)#(\d+)/#) {
            return (v, URL(string: "https://github.com/\(m.1)/pull/\(m.2)"))
        }
        return (v.allSatisfy(\.isNumber) ? "PR \(v)" : v, nil)
    }

    /// Hermes runtime as Core reports it (`HermesRuntimeSummary`), same line as the desktop.
    static func hermesRuntime(_ r: OrbJSON) -> [(String, String)] {
        guard case .object = r else { return [("Status", "Unavailable")] }
        var rows: [(String, String)] = []
        if case .bool(let active) = r["service_active"] { rows.append(("Service", active ? "Active" : "Stopped")) }
        else { rows.append(("Service", r["service_state"].text.isEmpty ? "Unknown" : r["service_state"].text)) }
        if !r["gateway_state"].text.isEmpty { rows.append(("Gateway", r["gateway_state"].text)) }
        if case .bool(let healthy) = r["api_server_healthy"] { rows.append(("API", healthy ? "Healthy" : "Unreachable")) }
        if case .bool(let proxy) = r["uses_sandboxed_proxy"] { rows.append(("Route", proxy ? "Via Core proxy" : "Direct provider")) }
        if case .bool(false) = r["token_present"] { rows.append(("Token", "Missing")) }
        let notes = r["notes"].items.map(\.text).filter { !$0.isEmpty }
        if !notes.isEmpty { rows.append(("Notes", notes.joined(separator: " · "))) }
        return rows
    }

    /// Core's `HermesSessionRollup`: `total` and `open` sessions since `since`.
    static func hermesSessions(_ s: OrbJSON) -> String? {
        guard let total = s["total"].doubleValue else { return nil }
        let open = Int(s["open"].doubleValue ?? 0)
        return "\(Int(total)) · \(open) open"
    }
}

/// Codex-style review entry point at the end of a turn: what changed and where it ships.
struct OrbChangesCard: View {
    let files: [OrbTurnSummary.FileChange]
    let pr: (label: String, url: URL?)?
    @State private var expanded = false
    @Environment(\.openURL) private var openURL

    private var additions: Int { files.reduce(0) { $0 + $1.additions } }
    private var deletions: Int { files.reduce(0) { $0 + $1.deletions } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if expanded { fileList }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(OrbStyle.border))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("turn.changes")
    }

    /// One row when it fits; at large text sizes the PR link moves under the summary
    /// instead of squeezing "3 files changed" into one character per line.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                summaryButton
                Spacer(minLength: 4)
                if let pr { prButton(pr) }
            }
            VStack(alignment: .leading, spacing: 6) {
                summaryButton
                if let pr { prButton(pr) }
            }
        }
    }

    private var summaryButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
        } label: {
            summary
        }
        .buttonStyle(.plain)
        .disabled(files.isEmpty)
        .accessibilityIdentifier("turn.changes.summary")
    }

    private var summary: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OrbStyle.textSecondary)
            if files.isEmpty {
                Text("No file changes").font(.caption.weight(.medium)).foregroundStyle(OrbStyle.textSecondary)
            } else {
                Text("\(files.count) file\(files.count == 1 ? "" : "s") changed")
                    .font(.caption.weight(.medium)).foregroundStyle(OrbStyle.textSecondary)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Text("+\(additions)").font(.caption.monospacedDigit()).foregroundStyle(OrbStyle.success)
                Text("−\(deletions)").font(.caption.monospacedDigit()).foregroundStyle(OrbStyle.error)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(OrbStyle.textMuted)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func prButton(_ pr: (label: String, url: URL?)) -> some View {
        let label = HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.pull").font(.system(size: 11, weight: .medium))
            Text(pr.label).font(.caption.weight(.medium)).lineLimit(1)
        }
        if let url = pr.url {
            Button { openURL(url) } label: { label }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .accessibilityIdentifier("turn.changes.pr")
        } else {
            label.foregroundStyle(OrbStyle.textSecondary).accessibilityIdentifier("turn.changes.pr")
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(files) { file in
                HStack(spacing: 6) {
                    Text(file.file.split(separator: "/").suffix(3).joined(separator: "/"))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 4)
                    Text("+\(file.additions)").font(.caption2.monospacedDigit()).foregroundStyle(OrbStyle.success)
                    Text("−\(file.deletions)").font(.caption2.monospacedDigit()).foregroundStyle(OrbStyle.error)
                }
            }
        }
        .padding(.top, 2)
    }
}

/// When an assistant turn completed and how long it worked; same rules as the
/// desktop `turnTiming.ts` (response action row).
struct OrbTurnTiming: Equatable {
    let completedAt: Date
    let workedSeconds: Int?

    /// Completion time and duration of each assistant answer, keyed by its trimmed
    /// text: the stored `assistant_message` time, measured from the latest user
    /// message before it. The newest occurrence of a repeated answer wins.
    static func byAnswer(_ events: [StoredEvent]) -> [String: OrbTurnTiming] {
        var out: [String: OrbTurnTiming] = [:]
        var start: Date?
        for event in events {
            switch event.eventType {
            case "user_message": start = OrbDateCache.parse(event.timestamp) ?? start
            case "assistant_message", "assistant_message_canonical":
                guard let end = OrbDateCache.parse(event.timestamp) else { continue }
                let text = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let worked = start.flatMap { $0 <= end ? Int(end.timeIntervalSince($0)) : nil }
                out[text] = OrbTurnTiming(completedAt: end, workedSeconds: worked)
            default: continue
            }
        }
        return out
    }

    /// "just now", "5m ago", "2h ago", "6d ago", then a short date from 30 days.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        if hours / 24 < 30 { return "\(hours / 24)d ago" }
        let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }

    /// "Oct 16, 2026, 5:30 AM" in the device's locale and time zone.
    static func absolute(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
    }

    /// "42s", "3m 5s", "12h 6m", "2d 3h".
    static func workedFor(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return s % 60 == 0 ? "\(m)m" : "\(m)m \(s % 60)s" }
        let h = m / 60
        if h < 24 { return m % 60 == 0 ? "\(h)h" : "\(h)h \(m % 60)m" }
        return h % 24 == 0 ? "\(h / 24)d" : "\(h / 24)d \(h % 24)h"
    }
}
