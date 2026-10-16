import SwiftUI

/// Harness and model of the /btw side agent (Orb: Settings → Side Questions).
@MainActor
enum OrbBtwConfig {
    private static let harnessKey = "orb.btw.harness", modelKey = "orb.btw.model"
    static let harnesses: [(String, String)] = [("opencode", "OpenCode"), ("claudecode", "Claude Code"), ("codex", "Codex"), ("grok", "Grok")]
    static var harness: String {
        get { UserDefaults.standard.string(forKey: harnessKey) ?? "opencode" }
        set { UserDefaults.standard.set(newValue, forKey: harnessKey) }
    }
    static var model: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? "builtin/smart" }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }
    /// One side session per parent conversation and backend.
    static func sessionKey(_ parent: String) -> String { "orb.btw.session:\(OrbCore.shared.endpoint):\(parent)" }
}

struct OrbBtwSettingsView: View {
    @State private var harness = OrbBtwConfig.harness
    @State private var model = OrbBtwConfig.model
    @State private var message = ""
    var body: some View {
        Form {
            Section {
                Picker("Harness", selection: $harness) {
                    ForEach(OrbBtwConfig.harnesses, id: \.0) { Text($0.1).tag($0.0) }
                }
                TextField("Model", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
            } footer: {
                Text("An independent agent in the main agent's folder, with the normal harness tools and permissions. Files are shared with the main agent.")
            }
            Section {
                Button("Save") {
                    OrbBtwConfig.harness = harness
                    OrbBtwConfig.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
                    message = "Saved. Applies to the next side question."
                }
                .disabled(model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .scrollContentBackground(.hidden).background(OrbStyle.background)
        .navigationTitle("Side questions").navigationBarTitleDisplayMode(.inline)
    }
}

/// `/btw`: ask an independent side agent about a conversation without
/// interrupting it. Core forks a side session (`POST …/btw/agent`) that shares
/// the main agent's working directory; follow-ups continue that session.
struct OrbSideQuestionSheet: View {
    let parentID: String
    @State var question: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var sideID: String?
    @State private var side: OrbJSON = .null
    @State private var busy = false
    @State private var error = ""
    @FocusState private var focused: Bool
    private static let live: Set<String> = ["active", "running", "pending", "queued", "starting", "resuming", "waiting_background", "paused"]

    /// Turns from earlier side sessions of this conversation (any device).
    @State private var earlier: [(role: String, text: String)] = []
    @State private var earlierLoaded = false

    private var running: Bool { Self.live.contains(side["status"].text) }
    private var exchanges: [(role: String, text: String)] { earlier + current }
    private var current: [(role: String, text: String)] {
        side["history"].items.compactMap { h in
            let role = h["role"].text
            guard role == "user" || role == "assistant" else { return nil }
            var text = h["content"].text
            // The first turn embeds the parent conversation; show only the request.
            if role == "user", let range = text.range(of: "Current request:\n", options: .backwards) { text = String(text[range.upperBound...]) }
            return (role, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !error.isEmpty { OrbNotice(message: error) }
                    if exchanges.isEmpty && !running {
                        Text("Ask about this conversation without interrupting it. The side agent reads the conversation and shares its working folder.")
                            .font(.footnote).foregroundStyle(OrbStyle.textSecondary)
                    }
                    ForEach(Array(exchanges.enumerated()), id: \.offset) { _, item in exchangeRow(item.role, item.text) }
                    if running {
                        HStack(spacing: 8) { OrbRunningDots(size: 10); Text(statusText).font(.footnote).foregroundStyle(OrbStyle.textSecondary) }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(OrbStyle.background)
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .navigationTitle("Side question").navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .task(id: phase) { await follow() }
            .onAppear {
                sideID = UserDefaults.standard.string(forKey: OrbBtwConfig.sessionKey(parentID))
                focused = sideID == nil
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if running { Button("Stop side agent", role: .destructive) { Task { await stop() } } }
                Button("New side session") { reset() }.disabled(running || sideID == nil)
                Text("\(OrbStyle.serviceName(OrbBtwConfig.harness)) · \(OrbBtwConfig.model)")
            } label: { Image(systemName: "ellipsis") }
        }
    }

    private var statusText: String {
        switch side["status"].text {
        case "paused": return "Side agent paused"
        case "waiting_background": return "Waiting for background work…"
        case "pending", "queued", "starting", "resuming": return "Waiting to start…"
        default: return "Thinking…"
        }
    }

    private func exchangeRow(_ role: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(role == "user" ? "You" : "Side agent").font(.caption.weight(.semibold)).foregroundStyle(OrbStyle.textSecondary)
            Text(text).font(.subheadline).textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(role == "user" ? OrbStyle.elevated : OrbStyle.card, in: RoundedRectangle(cornerRadius: OrbStyle.panelRadius))
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask a side question", text: $question, axis: .vertical)
                .lineLimit(1...5).focused($focused)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(OrbStyle.card, in: RoundedRectangle(cornerRadius: 18))
                .accessibilityIdentifier("btw.input")
            Button { Task { await ask() } } label: {
                Image(systemName: busy ? "hourglass" : "arrow.up").font(.system(size: 15, weight: .bold))
                    .frame(width: 34, height: 34).background(Color.white, in: Circle()).foregroundStyle(.black)
            }
            .disabled(busy || running || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("btw.send")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(OrbStyle.background)
    }

    private func reset() {
        UserDefaults.standard.removeObject(forKey: OrbBtwConfig.sessionKey(parentID))
        sideID = nil; side = .null; error = ""; earlier = []; earlierLoaded = true
    }

    /// Same rules as Orb desktop (`reconcileBtwServerHistory`): every side
    /// mission tagged with this conversation, oldest first, rebuilt from events.
    static func question(_ content: String) -> String {
        var text = content
        if let range = text.range(of: "\nCurrent request:\n", options: .backwards) { text = String(text[range.upperBound...]) }
        let lines = text.components(separatedBy: "\n")
        let kept = lines.reversed().drop(while: { $0.hasPrefix("Attachment: ") || $0.trimmingCharacters(in: .whitespaces).isEmpty }).reversed()
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func synthetic(_ text: String) -> Bool {
        text.range(of: #"^Remote (?:node '[^']+'|\w+) job [0-9a-f-]{36} (?:on node '[^']+' )?(?:finished with(?:out assistant text| state)|reached state) "#, options: .regularExpression) != nil
            || text.hasPrefix("Native Codex goal stopped with status ")
    }

    private func loadEarlier() async {
        guard !earlierLoaded else { return }
        let tag = "btw-parent:\(parentID)"
        guard let rows = try? await OrbCore.shared.call("/api/control/missions?tag=\(OrbCore.escape(tag))&all=true&limit=50") else { return }
        let all = rows["missions"].items.isEmpty ? rows.items : rows["missions"].items
        // A stored session may have been replaced: follow superseded_by first,
        // so the replacement is the current session, not an "earlier" one.
        var hops = 0
        while let id = sideID, hops < 10,
              let next = all.first(where: { $0["id"].text == id })?["tags"].items.map(\.text)
                  .first(where: { $0.hasPrefix("superseded_by:") }) {
            sideID = String(next.dropFirst("superseded_by:".count))
            UserDefaults.standard.set(sideID, forKey: OrbBtwConfig.sessionKey(parentID))
            hops += 1
        }
        let list = all
            .filter { m in
                let tags = m["tags"].items.map(\.text)
                return tags.contains(tag) && !tags.contains("superseded")
            }
            .sorted { $0["created_at"].text < $1["created_at"].text }
        // Continue the newest session when this device has none yet.
        if sideID == nil, let latest = list.last {
            sideID = latest["id"].text
            UserDefaults.standard.set(sideID, forKey: OrbBtwConfig.sessionKey(parentID))
        }
        var turns: [(role: String, text: String)] = []
        for m in list where m["id"].text != sideID {
            guard let events = try? await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(m["id"].text))/events") else { continue }
            // Like Orb desktop: only answered turns, one entry per question.
            var question = ""
            var answers: [String] = []
            func flush() {
                let answer = answers.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !question.isEmpty && !answer.isEmpty { turns.append(("user", question)); turns.append(("assistant", answer)) }
                question = ""; answers = []
            }
            for e in events.items.sorted(by: { ($0["sequence"].doubleValue ?? 0) < ($1["sequence"].doubleValue ?? 0) }) {
                let content = e["content"].text.trimmingCharacters(in: .whitespacesAndNewlines)
                switch e["event_type"].text {
                case "user_message":
                    flush()
                    question = Self.question(content)
                case "assistant_message", "assistant_message_canonical":
                    if !content.isEmpty, answers.last != content, !Self.synthetic(content) { answers.append(content) }
                default: break
                }
            }
            flush()
        }
        earlier = turns
        earlierLoaded = true
        // Show the history instead of covering it with the keyboard.
        if !turns.isEmpty && question.isEmpty { focused = false }
    }

    private func load() async throws {
        await loadEarlier()
        guard let id = sideID else { return }
        do {
            side = try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(id))")
            // A recovered side session points at its replacement.
            if let next = side["tags"].items.map(\.text).first(where: { $0.hasPrefix("superseded_by:") }) {
                sideID = String(next.dropFirst("superseded_by:".count))
                UserDefaults.standard.set(sideID, forKey: OrbBtwConfig.sessionKey(parentID))
                side = try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(sideID ?? ""))")
            }
        } catch let e as OrbHTTPError where e.status == 404 {
            reset()
        }
    }

    private func follow() async {
        guard phase == .active else { return }
        while !Task.isCancelled {
            do { try await load() } catch is CancellationError { return } catch { self.error = error.localizedDescription }
            do { try await Task.sleep(for: .seconds(running || busy ? 2 : 15)) } catch { return }
        }
    }

    private func ask() async {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !text.isEmpty else { return }
        busy = true; defer { busy = false }
        do {
            try await load()
            if running { throw OrbHTTPError(status: 409, detail: "The side agent is still running. Stop it before sending another question.") }
            if let id = sideID {
                _ = try await OrbCore.shared.call("/api/control/message", method: "POST", body: .object([
                    "mission_id": .string(id), "content": .string(text), "client_message_id": .string(UUID().uuidString),
                ]))
            } else {
                let parent = try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(parentID))")
                if parent["tags"].items.contains(where: { $0.text == "placement:client" }) {
                    throw OrbHTTPError(status: 409, detail: "This conversation runs on a computer. Ask side questions from Orb on that computer.")
                }
                let created = try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(parentID))/btw/agent", method: "POST", body: .object([
                    "backend": .string(OrbBtwConfig.harness), "model_override": .string(OrbBtwConfig.model), "model_effort": .null,
                    "idempotency_key": .string(UUID().uuidString), "side_question": .string(text),
                ]))
                sideID = created["id"].text
                UserDefaults.standard.set(sideID, forKey: OrbBtwConfig.sessionKey(parentID))
            }
            question = ""
            error = ""
            try await load()
        } catch let e as OrbHTTPError where [404, 405].contains(e.status) && sideID == nil {
            error = "This backend does not support /btw side agents yet."
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func stop() async {
        guard let id = sideID else { return }
        do { _ = try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(id))/cancel", method: "POST"); try await load() }
        catch { self.error = error.localizedDescription }
    }
}

struct OrbSideQuestionRequest: Identifiable {
    let id = UUID()
    let parent: String
    let question: String
}

extension OrbConversation {
    /// `/btw <question>` in the composer opens a side question instead of messaging the agent.
    static func btwQuestion(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "/btw" { return "" }
        guard trimmed.hasPrefix("/btw ") || trimmed.hasPrefix("/btw\n") else { return nil }
        return String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
