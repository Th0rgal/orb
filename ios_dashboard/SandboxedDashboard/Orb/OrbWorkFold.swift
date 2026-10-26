import SwiftUI
import UIKit

// MARK: - Cursor-Style Work Model & Collapsible Activity Fold

struct OrbWorkModel: Equatable {
    struct ToolItem: Identifiable, Equatable {
        enum Status: Equatable { case running, done, error }
        let id: String
        let rawName: String
        let category: String
        let loadingLabel: String
        let completedLabel: String
        let target: String
        let argsText: String
        let outputText: String
        var status: Status
    }

    struct ThoughtItem: Identifiable, Equatable {
        let id: String
        let title: String
        let body: String
        var streaming: Bool
    }

    struct TodoItem: Identifiable, Equatable {
        let id: String
        let content: String
        let status: String
    }

    /// Narration: assistant text written between tool calls of the turn
    /// ("Let me check…"). It belongs to the work, so it renders inside the fold.
    struct NoteItem: Identifiable, Equatable {
        let id: String
        let text: String
        /// How many of `tools` precede this note, to keep the body in order.
        var afterTools: Int
    }

    var thoughts: [ThoughtItem] = []
    var tools: [ToolItem] = []
    var notes: [NoteItem] = []
    /// Trimmed texts of `notes`, so the history list hides the same rows.
    var narrationTexts: Set<String> { Set(notes.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }) }
    var todos: [TodoItem] = []
    /// How the turn went after the latest task-list update: a final answer
    /// arrived (`.finished`) or the turn failed/stopped without one
    /// (`.stopped`). Mirrors desktop `turnOutcomeAfter`.
    enum TurnOutcome: Equatable { case finished, stopped }
    var outcomeAfterTodos: TurnOutcome = .stopped
    private var todosFailed = false

    var isEmpty: Bool { thoughts.isEmpty && tools.isEmpty && notes.isEmpty }

    func liveHeadline(fallback: String) -> (action: String, detail: String) {
        if let activeTool = tools.last(where: { $0.status == .running }) {
            return (activeTool.loadingLabel, activeTool.target)
        }
        if let lastThought = thoughts.last, lastThought.streaming {
            let detail = lastThought.title == "Thought" ? "" : lastThought.title
            return ("Thinking", detail)
        }
        return (fallback, "")
    }

    /// Matches Cursor's `buildSummaryParts` (`Worked — 3 reads, 2 edits, 1 command`).
    var completedSummary: String {
        let reads = tools.filter { $0.category == "read" }.count
        let searches = tools.filter { $0.category == "search" }.count
        let edits = tools.filter { $0.category == "edit" }.count
        let commands = tools.filter { $0.category == "command" }.count
        let fetches = tools.filter { $0.category == "web" }.count
        let tasks = tools.filter { $0.category == "task" }.count
        let others = tools.filter { $0.category == "other" }.count

        var parts: [String] = []
        if !thoughts.isEmpty && tools.isEmpty {
            return thoughts.count == 1 ? (thoughts[0].title == "Thought" ? "Thought" : "Thought · \(thoughts[0].title)") : "Thought (\(thoughts.count) steps)"
        }
        if reads > 0 { parts.append("\(reads) \(reads == 1 ? "read" : "reads")") }
        if searches > 0 { parts.append("\(searches) \(searches == 1 ? "search" : "searches")") }
        if edits > 0 { parts.append("\(edits) \(edits == 1 ? "edit" : "edits")") }
        if commands > 0 { parts.append("\(commands) \(commands == 1 ? "command" : "commands")") }
        if fetches > 0 { parts.append("\(fetches) \(fetches == 1 ? "fetch" : "fetches")") }
        if tasks > 0 { parts.append("\(tasks) \(tasks == 1 ? "agent" : "agents")") }
        if others > 0 { parts.append("\(others) \(others == 1 ? "step" : "steps")") }
        if parts.isEmpty { return "Worked" }
        return "Worked — " + parts.joined(separator: ", ")
    }

    nonisolated static func isTaskListTool(_ name: String?) -> Bool {
        ["todowrite", "todo_write", "update_plan"].contains(name?.lowercased() ?? "")
    }

    static func build(from events: [StoredEvent], working: Bool) -> OrbWorkModel {
        var model = OrbWorkModel()
        var toolIndexByCallID: [String: Int] = [:]
        let narration = narrationKeys(narrationItems(events), standalone: { OrbOrchestration.kind($0) != nil })

        for (idx, event) in events.enumerated() {
            let isLastEvent = idx == events.count - 1
            switch event.eventType {
            case "user_message":
                // Like the desktop: the fold, counts and task list describe the
                // current turn, not every turn loaded so far.
                model = OrbWorkModel()
                toolIndexByCallID = [:]

            case "thinking":
                let trimmed = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let (title, body) = parseThought(trimmed)
                if !model.thoughts.isEmpty && model.thoughts[model.thoughts.count - 1].body == body && model.thoughts[model.thoughts.count - 1].title == title {
                    model.thoughts[model.thoughts.count - 1].streaming = working && isLastEvent
                } else {
                    model.thoughts.append(ThoughtItem(id: "thought-\(event.sequence)", title: title, body: body, streaming: working && isLastEvent))
                }

            case "tool_call":
                let rawName = event.toolName ?? "tool"
                if ["ui_native_request", "AskUserQuestion", "question"].contains(rawName) { continue }
                let parsed = (try? JSONDecoder().decode(OrbJSON.self, from: Data(event.content.utf8))) ?? .null
                if isTaskListTool(rawName) {
                    let items = extractTodos(from: parsed)
                    if !items.isEmpty { model.todos = items; model.outcomeAfterTodos = .stopped; model.todosFailed = false }
                    continue
                }
                let meta = classifyTool(name: rawName, args: parsed, rawContent: event.content)
                let callID = event.toolCallId ?? "seq-\(event.sequence)"
                let item = ToolItem(
                    id: callID,
                    rawName: rawName,
                    category: meta.category,
                    loadingLabel: meta.loading,
                    completedLabel: meta.completed,
                    target: meta.target,
                    argsText: formatCompactJSON(event.content),
                    outputText: "",
                    status: working ? .running : .done
                )
                toolIndexByCallID[callID] = model.tools.count
                model.tools.append(item)

            case "tool_result":
                guard let callID = event.toolCallId, let toolIdx = toolIndexByCallID[callID] else { continue }
                let isError = event.metadata["is_error"]?.value as? Bool == true || event.content.prefix(6).lowercased() == "error:"
                let output = formatCompactOutput(event.content)
                let old = model.tools[toolIdx]
                model.tools[toolIdx] = ToolItem(
                    id: old.id,
                    rawName: old.rawName,
                    category: old.category,
                    loadingLabel: old.loadingLabel,
                    completedLabel: old.completedLabel,
                    target: old.target,
                    argsText: old.argsText,
                    outputText: output,
                    status: isError ? .error : .done
                )

            case "goal_status", "goal_iteration":
                let text = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                model.tools.append(ToolItem(
                    id: "goal-\(event.sequence)",
                    rawName: event.eventType,
                    category: "other",
                    loadingLabel: "Updating goal",
                    completedLabel: "Goal update",
                    target: String(text.prefix(60)),
                    argsText: "",
                    outputText: text,
                    status: .done
                ))

            case "assistant_message":
                if narration.contains("seq-\(event.sequence)") {
                    model.notes.append(NoteItem(id: "note-\(event.sequence)", text: event.content, afterTools: model.tools.count))
                    continue
                }
                // A failure after an answer still means the turn stopped.
                let failed = event.metadata["success"]?.value as? Bool == false
                let nonEmpty = !event.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let step = OrbKernel.turnOutcomeStep(
                    prevFinished: model.outcomeAfterTodos == .finished,
                    prevFailed: model.todosFailed,
                    eventKind: 2,
                    isNarration: false,
                    isSuccessFalse: failed,
                    isTextNonEmpty: nonEmpty
                )
                model.outcomeAfterTodos = step.finished ? .finished : .stopped
                model.todosFailed = step.todosFailed

            default:
                break
            }
        }

        // Keep the latest 40 tools so the fold stays snappy on long missions.
        if model.tools.count > 40 {
            let dropped = model.tools.count - 40
            model.tools = Array(model.tools.suffix(40))
            model.notes = model.notes.map { var n = $0; n.afterTools = max(0, n.afterTools - dropped); return n }
        }
        if model.thoughts.count > 12 {
            model.thoughts = Array(model.thoughts.suffix(12))
        }
        return model
    }

    /// The transcript as desktop `StreamItem` kinds, for `narrationKeys`.
    /// Tool results merge into their call, so they are not items.
    enum NarrationItem: Equatable {
        case user
        case text(key: String, text: String, cumulative: Bool)
        case tool(name: String)
        case think
        case other
    }

    static func narrationItems(_ events: [StoredEvent]) -> [NarrationItem] {
        events.compactMap { event in
            switch event.eventType {
            case "user_message": return .user
            case "assistant_message":
                if event.metadata["success"]?.value as? Bool == false { return .other }
                return .text(key: "seq-\(event.sequence)", text: event.content, cumulative: false)
            case "thinking": return .think
            case "tool_call": return .tool(name: event.toolName ?? "tool")
            case "tool_result": return nil
            default: return .other
            }
        }
    }

    /// Same rule as desktop `narrationKeys` (orb/src/workModel.ts): a text is
    /// narration when a later work tool exists in the same turn and it either
    /// joins a fold that already holds a tool or is followed (through thoughts
    /// and more text) by one. Text after the last tool is the answer. The
    /// producer's cumulative bubble is never narration. Orchestration tools
    /// stand alone and do not count.
    static func narrationKeys(_ items: [NarrationItem], standalone: (String) -> Bool = { _ in false }) -> Set<String> {
        func isWorkTool(_ item: NarrationItem) -> Bool {
            if case .tool(let name) = item { return !standalone(name) }
            return false
        }
        var toolAhead = Array(repeating: false, count: items.count)
        var nextIsTool = Array(repeating: false, count: items.count)
        var ahead = false, next = false
        for i in items.indices.reversed() {
            toolAhead[i] = ahead; nextIsTool[i] = next
            switch items[i] {
            case .user: ahead = false; next = false
            case .text, .think: break
            case let item where isWorkTool(item): ahead = true; next = true
            default: next = false
            }
        }
        var keys = Set<String>()
        var foldHasTool = false
        for (i, item) in items.enumerated() {
            let itemKind: Int
            var isCumulative = false
            var isNonEmpty = false
            var textKey = ""
            switch item {
            case .user: itemKind = 0
            case .think: itemKind = 1
            case let .text(key, text, cumulative):
                itemKind = 2
                isCumulative = cumulative
                isNonEmpty = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                textKey = key
            default:
                itemKind = isWorkTool(item) ? 3 : 4
            }
            let verdict = OrbKernel.workfoldStep(
                itemKind: itemKind,
                isCumulative: isCumulative,
                isNonEmpty: isNonEmpty,
                toolAhead: toolAhead[i],
                nextIsTool: nextIsTool[i],
                foldHasTool: foldHasTool
            )
            if itemKind == 2 && verdict.foldItem { keys.insert(textKey) }
            foldHasTool = verdict.foldHasToolNext
        }
        return keys
    }

    /// One line of narration for the fold header: Markdown markers stripped,
    /// whitespace collapsed (desktop `narrationLine`).
    static func narrationLine(_ text: String) -> String {
        text.replacingOccurrences(of: "```[\\s\\S]*?(```|$)", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[*_`#>]+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func parseThought(_ text: String) -> (title: String, body: String) {
        let lines = text.components(separatedBy: .newlines)
        var lastHeader: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("**") && trimmed.hasSuffix("**") && trimmed.count > 4 {
                lastHeader = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("#") {
                lastHeader = trimmed.drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespaces)
            }
        }
        var body = text
        if let first = lines.first?.trimmingCharacters(in: .whitespaces),
           (first.hasPrefix("**") && first.hasSuffix("**")) || first.hasPrefix("#") {
            body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (lastHeader ?? "Thought", body.isEmpty ? text : body)
    }

    private static func extractTodos(from json: OrbJSON) -> [TodoItem] {
        let candidates = !json["todos"].items.isEmpty ? json["todos"].items : (!json["plan"].items.isEmpty ? json["plan"].items : json["input"]["todos"].items)
        return candidates.enumerated().compactMap { idx, item in
            let text = !item["content"].text.isEmpty ? item["content"].text : (!item["step"].text.isEmpty ? item["step"].text : item["title"].text)
            guard !text.isEmpty else { return nil }
            let status = OrbTurnSummary.taskStatus(item["status"].text)
            return TodoItem(id: item["id"].text.isEmpty ? "todo-\(idx)" : item["id"].text, content: text, status: status)
        }
    }

    private static func classifyTool(name: String, args: OrbJSON, rawContent: String) -> (category: String, loading: String, completed: String, target: String) {
        let input = args["input"] != .null ? args["input"] : (args["arguments"] != .null ? args["arguments"] : args)
        let n = name.lowercased().replacingOccurrences(of: "-", with: "_")

        func shortPath(_ raw: String) -> String {
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return "" }
            let parts = clean.split(separator: "/").map(String.init)
            if parts.count >= 2 { return parts.suffix(2).joined(separator: "/") }
            return parts.last ?? clean
        }

        let filePath = [input["file_path"].text, input["path"].text, input["target_file"].text, input["file"].text, input["filename"].text].first(where: { !$0.isEmpty }) ?? ""
        let command = [input["command"].text, input["cmd"].text, input["CommandLine"].text].first(where: { !$0.isEmpty }) ?? ""
        let query = [input["pattern"].text, input["query"].text, input["Query"].text, input["search"].text].first(where: { !$0.isEmpty }) ?? ""
        let url = [input["url"].text, input["Url"].text].first(where: { !$0.isEmpty }) ?? ""

        if ["read", "read_file", "view_file", "cat"].contains(n) {
            return ("read", "Reading", "Read", shortPath(filePath))
        }
        if ["ls", "list_dir", "list_directory", "find_by_name", "glob"].contains(n) {
            let target = !filePath.isEmpty ? shortPath(filePath) : (!query.isEmpty ? query : "")
            return ("read", "Listing", "Listed", target)
        }
        if ["edit", "write", "write_file", "write_to_file", "replace_file_content", "multi_replace_file_content", "multiedit", "patch", "apply_patch", "notebookedit"].contains(n) {
            return ("edit", "Editing", "Edited", shortPath(filePath))
        }
        if ["bash", "run_command", "shell", "exec", "terminal"].contains(n) {
            let firstLine = command.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
            let summary = firstLine.count > 48 ? String(firstLine.prefix(48)) + "…" : firstLine
            return ("command", "Running", "Ran", summary)
        }
        if ["grep", "grep_search", "rg", "ripgrep", "search", "semsearch"].contains(n) {
            let target = !query.isEmpty ? "\"\(query.prefix(36))\"" : shortPath(filePath)
            return ("search", "Searching", "Searched", target)
        }
        if ["websearch", "web_search", "search_web", "webfetch", "web_fetch", "read_url_content", "fetch"].contains(n) {
            let host = URL(string: url)?.host ?? (!query.isEmpty ? query : url)
            return ("web", "Fetching", "Fetched", String(host.prefix(40)))
        }
        if ["task", "subagent", "invoke_subagent", "delegate"].contains(n) {
            let desc = [input["description"].text, input["Role"].text, input["prompt"].text].first(where: { !$0.isEmpty }) ?? ""
            return ("task", "Working on task", "Completed task", String(desc.prefix(42)))
        }
        let fallbackTarget = !filePath.isEmpty ? shortPath(filePath) : (!command.isEmpty ? String(command.prefix(40)) : (!query.isEmpty ? String(query.prefix(36)) : ""))
        let cleanName = name.replacingOccurrences(of: "_", with: " ")
        return ("other", cleanName, cleanName, fallbackTarget)
    }

    private static func formatCompactJSON(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "{}" else { return "" }
        return String(trimmed.prefix(800))
    }

    private static func formatCompactOutput(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return String(trimmed.prefix(1200))
    }
}

struct OrbWorkFold: View {
    let model: OrbWorkModel
    let working: Bool
    let headline: (action: String, detail: String)
    let elapsed: String
    let accessibilityStatus: String
    var identifier = "agent-working"
    @State private var expanded = false
    @State private var expandedItemIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Expanded items render ABOVE the toggle button (matching Desktop WorkFold),
            // so the toggle button stays anchored at the bottom for easy collapsing.
            if expanded && !model.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(model.thoughts) { thought in
                        OrbThoughtRow(thought: thought, isExpanded: expandedItemIDs.contains(thought.id)) {
                            toggleItem(thought.id)
                        }
                    }
                    ForEach(Array(model.tools.enumerated()), id: \.element.id) { index, tool in
                        ForEach(model.notes.filter { $0.afterTools == index }) { note in
                            OrbNarrationRow(text: note.text)
                        }
                        OrbToolRow(tool: tool, isExpanded: expandedItemIDs.contains(tool.id)) {
                            toggleItem(tool.id)
                        }
                    }
                    ForEach(model.notes.filter { $0.afterTools >= model.tools.count }) { note in
                        OrbNarrationRow(text: note.text)
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(OrbStyle.borderStrong)
                        .frame(width: 1)
                        .padding(.vertical, 2)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if working {
                Button {
                    guard !model.isEmpty else { return }
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                    OrbHaptics.selection()
                } label: {
                    HStack(spacing: 8) {
                        OrbRunningDots(size: 12)
                        HStack(spacing: 5) {
                            Text(headline.action)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(OrbStyle.textSecondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .orbShimmer(active: true)
                            if !headline.detail.isEmpty {
                                Text(headline.detail)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(OrbStyle.textMuted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 6)
                        Text(elapsed)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(OrbStyle.textMuted)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        if !model.isEmpty {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(OrbStyle.textMuted)
                                .rotationEffect(.degrees(expanded ? -90 : 0))
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityStatus)
                .accessibilityIdentifier(identifier)
                // While the fold runs, the newest narration reads as one line
                // under its header instead of paragraphs in the transcript.
                if !expanded, let note = model.notes.last.map({ OrbWorkModel.narrationLine($0.text) }), !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(OrbStyle.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 20)
                        .accessibilityIdentifier("work-live-note")
                }
            } else if !model.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                    OrbHaptics.selection()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(OrbStyle.textMuted)
                            .rotationEffect(.degrees(expanded ? -90 : 0))
                        Text(model.completedSummary)
                            .font(.footnote)
                            .foregroundStyle(OrbStyle.textSecondary)
                            .orbAdaptiveLineLimit()
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("activity-fold")
            }
        }
    }

    private func toggleItem(_ id: String) {
        withAnimation(.snappy(duration: 0.18)) {
            if !expandedItemIDs.insert(id).inserted {
                expandedItemIDs.remove(id)
            }
        }
        OrbHaptics.selection()
    }
}

/// A narration paragraph inside the fold body: compact, secondary markdown.
private struct OrbNarrationRow: View {
    let text: String
    var body: some View {
        OrbRichText(source: text)
            .font(.caption)
            .foregroundStyle(OrbStyle.textSecondary)
            .padding(.vertical, 2)
    }
}

private struct OrbThoughtRow: View {
    let thought: OrbWorkModel.ThoughtItem
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isExpanded || thought.streaming {
                Text(thought.body)
                    .font(.caption)
                    .foregroundStyle(OrbStyle.textSecondary)
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .padding(.leading, 12)
                    .padding(.vertical, 2)
            }

            Button(action: onTap) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(OrbStyle.textMuted)
                        .rotationEffect(.degrees((isExpanded || thought.streaming) ? -90 : 0))
                    Text(thought.streaming ? "Thinking" : "Thought")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(OrbStyle.textSecondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .orbShimmer(active: thought.streaming)
                    if thought.title != "Thought" {
                        Text(thought.title)
                            .font(.caption)
                            .foregroundStyle(OrbStyle.textMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct OrbToolRow: View {
    let tool: OrbWorkModel.ToolItem
    let isExpanded: Bool
    let onTap: () -> Void
    @State private var copied = false

    private var hasDetails: Bool {
        !tool.argsText.isEmpty || !tool.outputText.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isExpanded && hasDetails {
                VStack(alignment: .leading, spacing: 6) {
                    let combined = [tool.argsText, tool.outputText].filter { !$0.isEmpty }.joined(separator: "\n\n")
                    HStack {
                        Text(tool.rawName)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(OrbStyle.textMuted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = combined
                            OrbHaptics.light()
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.2))
                                copied = false
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                Text(copied ? "Copied" : "Copy")
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(copied ? OrbStyle.success : OrbStyle.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    ScrollView {
                        Text(combined)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(OrbStyle.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                .padding(8)
                .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(OrbStyle.border))
                .padding(.leading, 14)
            }

            Button {
                if hasDetails { onTap() }
            } label: {
                HStack(spacing: 6) {
                    Group {
                        switch tool.status {
                        case .running:
                            OrbRunningDots(size: 9)
                        case .done:
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(OrbStyle.textMuted)
                        case .error:
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(OrbStyle.warning)
                        }
                    }
                    .frame(width: 12)

                    Text(tool.status == .running ? tool.loadingLabel : tool.completedLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(tool.status == .error ? OrbStyle.warning : OrbStyle.textSecondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    if !tool.target.isEmpty {
                        Text(tool.target)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(OrbStyle.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 4)

                    if hasDetails {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(OrbStyle.textMuted)
                            .rotationEffect(.degrees(isExpanded ? -90 : 0))
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

struct OrbMissionTasksCard: View {
    let todos: [OrbWorkModel.TodoItem]
    /// The turn is no longer running: an unfinished plan shows where it
    /// stopped, with no step in progress (desktop `taskCardView`).
    var ended = false
    /// How the turn ended after the last task-list update. A normal finish
    /// with open items only means the list went stale (ccd5a32b), so it is
    /// never labelled "Stopped".
    var outcome: OrbWorkModel.TurnOutcome = .stopped
    @State private var expanded = false

    enum CardState: Equatable { case live, done, stale, stopped }
    static func state(todos: [OrbWorkModel.TodoItem], ended: Bool, outcome: OrbWorkModel.TurnOutcome) -> CardState {
        if !ended { return .live }
        if todos.allSatisfy({ $0.status == "completed" || $0.status == "cancelled" }) { return .done }
        return outcome == .finished ? .stale : .stopped
    }
    static func label(todos: [OrbWorkModel.TodoItem], ended: Bool, outcome: OrbWorkModel.TurnOutcome) -> String {
        let done = todos.filter { $0.status == "completed" }.count
        switch state(todos: todos, ended: ended, outcome: outcome) {
        case .live, .done: return "\(done)/\(todos.count) tasks"
        case .stale: return "Task list not updated · turn finished (\(done)/\(todos.count))"
        case .stopped:
            let index = todos.firstIndex { $0.status == "in_progress" || $0.status == "pending" } ?? 0
            return "Stopped at step \(index + 1)/\(todos.count)"
        }
    }
    static func shownStatus(_ status: String, state: CardState) -> String {
        let open = status == "in_progress" || status == "pending"
        switch state {
        case .stale: return open ? "stale" : status
        case .stopped: return status == "in_progress" ? "pending" : status
        default: return status
        }
    }

    private var state: CardState { Self.state(todos: todos, ended: ended, outcome: outcome) }
    private func shownStatus(_ status: String) -> String { Self.shownStatus(status, state: state) }
    private var countLabel: String { Self.label(todos: todos, ended: ended, outcome: outcome) }

    private var completedCount: Int {
        todos.filter { $0.status == "completed" }.count
    }
    static func icon(_ status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "record.circle"
        case "cancelled": return "xmark.circle"
        case "stale": return "circle.dashed"
        default: return "circle"
        }
    }
    private var activeTodo: OrbWorkModel.TodoItem? {
        todos.first { $0.status == "in_progress" } ?? todos.first { $0.status == "pending" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
                OrbHaptics.selection()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: completedCount == todos.count ? "checkmark.circle.fill" : "checklist")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(completedCount == todos.count ? OrbStyle.success : OrbStyle.textSecondary)
                    Text(countLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(OrbStyle.textSecondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if let active = activeTodo, !expanded {
                        Text("· \(active.content)")
                            .font(.caption)
                            .foregroundStyle(OrbStyle.textMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(OrbStyle.textMuted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(todos) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: Self.icon(shownStatus(item.status)))
                                .font(.system(size: 11))
                                .foregroundStyle(item.status == "completed" ? OrbStyle.success : (shownStatus(item.status) == "in_progress" ? .white : OrbStyle.textMuted))
                                .padding(.top, 2)
                            Text(item.content)
                                .font(.caption)
                                .foregroundStyle(item.status == "completed" ? OrbStyle.textMuted : .primary.opacity(0.9))
                                .strikethrough(item.status == "completed" || item.status == "cancelled")
                                .italic(shownStatus(item.status) == "stale")
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityHint(shownStatus(item.status) == "stale" ? "Final status not reported by the agent" : "")
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(OrbStyle.border))
    }
}
