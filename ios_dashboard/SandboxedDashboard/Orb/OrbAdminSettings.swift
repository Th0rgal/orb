import SwiftUI
import UIKit

// MARK: - Models & Routing (Orb: RoutingSettings.tsx, /api/model-routing)

struct OrbRoutingSettings: View {
    @State private var client = OrbSettingsClient()
    @State private var chains: [OrbJSON] = []
    @State private var health: [OrbJSON] = []
    @State private var events: [OrbJSON] = []
    @State private var catalog: [OrbJSON] = []
    @State private var error = ""
    @State private var notice = ""
    @State private var editing: OrbChainDraft?
    @State private var deleting: OrbJSON?
    @State private var busy = false

    var body: some View {
        List {
            OrbSettingsError(message: error)
            if !notice.isEmpty { Section { Text(notice).font(.footnote).textSelection(.enabled) } }
            chainsSection
            healthSection
            eventsSection
        }
        .scrollContentBackground(.hidden).background(OrbStyle.background)
        .navigationTitle("Fallback Chains").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { editing = OrbChainDraft() } label: { Image(systemName: "plus") }.accessibilityLabel("New chain") } }
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $editing) { draft in
            OrbChainEditor(draft: draft, catalog: catalog) { saved in
                editing = nil
                Task { await save(saved) }
            }
        }
        .alert("Delete chain?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { chain in
            Button("Delete", role: .destructive) { Task { await run { _ = try await client.call(Self.path(chain.selfID), method: "DELETE") } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Delete \($0["name"].text)? Requests using its ID stop resolving.") }
    }

    static func path(_ id: String) -> String { "/api/model-routing/chains/\(OrbCore.escape(id))" }

    private var chainsSection: some View {
        Section {
            if chains.isEmpty { Text("No chains.").foregroundStyle(.secondary) }
            ForEach(chains, id: \.selfID) { chain in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(chain["name"].text.isEmpty ? chain.selfID : chain["name"].text).font(.subheadline.weight(.medium))
                        if chain["is_default"].flag { Text("Default").font(.caption2.weight(.bold)).foregroundStyle(OrbStyle.success) }
                    }
                    Text(chain.selfID).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(chain["entries"].items.map { "\($0["provider_id"].text)/\($0["model_id"].text)" }.joined(separator: " → "))
                        .font(.caption).foregroundStyle(OrbStyle.textSecondary)
                }
                .contextMenu { chainMenu(chain) }
                .swipeActions { Button("Delete", role: .destructive) { deleting = chain } }
            }
        } header: { Text("Fallback chains") } footer: { Text("Requests to a chain ID try each provider/model in order, skipping accounts in cooldown. Long-press a chain for actions.") }
    }

    @ViewBuilder private func chainMenu(_ chain: OrbJSON) -> some View {
        Button { editing = OrbChainDraft(chain) } label: { Label("Edit", systemImage: "pencil") }
        if !chain["is_default"].flag {
            Button { Task { await run { _ = try await client.call(Self.path(chain.selfID), method: "PUT", body: .object(["is_default": .bool(true)])) } } } label: { Label("Make default", systemImage: "star") }
        }
        Button { Task { await test(chain.selfID) } } label: { Label("Test", systemImage: "play") }
        Button { Task { await resolve(chain.selfID) } } label: { Label("Resolve accounts", systemImage: "list.bullet") }
        Button { UIPasteboard.general.string = chain.selfID } label: { Label("Copy model ID", systemImage: "doc.on.doc") }
        Button(role: .destructive) { deleting = chain } label: { Label("Delete", systemImage: "trash") }
    }

    private var healthSection: some View {
        Section("Provider health") {
            if health.isEmpty { Text("No requests recorded yet.").foregroundStyle(.secondary) }
            ForEach(health, id: \.healthID) { h in
                HStack {
                    Circle().fill(h["is_healthy"].flag ? (h["is_degraded"].flag ? OrbStyle.warning : OrbStyle.success) : OrbStyle.error).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h["provider_id"].text.isEmpty ? h["account_id"].text : h["provider_id"].text).font(.subheadline)
                        Text(healthLine(h)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let cooldown = h["cooldown_remaining_secs"].number, cooldown > 0 {
                        Button("Clear") { Task { await run { _ = try await client.call("/api/model-routing/health/\(OrbCore.escape(h["account_id"].text))/clear", method: "POST") } } }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
    }

    private func healthLine(_ h: OrbJSON) -> String {
        var parts = ["\(h["total_successes"].display)/\(h["total_requests"].display) ok"]
        if let rl = h["total_rate_limits"].number, rl > 0 { parts.append("\(Int(rl)) rate limits") }
        if let latency = h["avg_latency_ms"].number { parts.append("\(Int(latency)) ms") }
        if let cooldown = h["cooldown_remaining_secs"].number, cooldown > 0 { parts.append("cooldown \(Int(cooldown)) s") }
        if !h["last_failure_reason"].text.isEmpty { parts.append(h["last_failure_reason"].text) }
        return parts.joined(separator: " · ")
    }

    private var eventsSection: some View {
        Section("Recent fallback events") {
            if events.isEmpty { Text("No fallbacks.").foregroundStyle(.secondary) }
            ForEach(Array(events.prefix(30).enumerated()), id: \.offset) { _, e in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(e["from_provider"].text)/\(e["from_model"].text) → \(e["to_provider"].text.isEmpty ? "none" : e["to_provider"].text)").font(.caption)
                    Text("\(e["reason"].text) · \(e["chain_id"].text) · \(OrbStyle.relativeTime(e["timestamp"].text))").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func load() async {
        do {
            async let c = client.call("/api/model-routing/chains")
            async let h = client.call("/api/model-routing/health")
            async let e = client.call("/api/model-routing/events")
            chains = try await c.items
            health = (try? await h.items) ?? []
            events = (try? await e.items) ?? []
            if catalog.isEmpty { catalog = (try? await client.call("/api/providers?include_all=true&include_unverified=true")["providers"].items) ?? [] }
            error = ""
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }

    private func run(_ action: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { try await action(); error = "" } catch is CancellationError {} catch { self.error = error.localizedDescription }
        await load()
    }

    private func save(_ draft: OrbChainDraft) async {
        let body: OrbJSON = .object([
            "id": .string(draft.chainID), "name": .string(draft.name), "strip_thinking": .bool(draft.stripThinking),
            "entries": .array(draft.entries.map { .object(["provider_id": .string($0.provider), "model_id": .string($0.model)]) }),
        ])
        await run { _ = try await client.call(draft.existing ? Self.path(draft.chainID) : "/api/model-routing/chains", method: draft.existing ? "PUT" : "POST", body: body) }
    }

    private func test(_ id: String) async {
        do {
            let result = try await client.call(Self.path(id) + "/test", method: "POST")
            let reply = result["response"]["choices"].items.first?["message"]["content"].text ?? ""
            let failure = result["response"]["error"]["message"].text
            notice = result["ok"].flag ? "Test \(id): OK · \(result["response"]["model"].text)\n\(reply)" : "Test \(id) failed (\(result["status"].display)): \(failure)"
        } catch { self.error = error.localizedDescription }
    }

    private func resolve(_ id: String) async {
        do {
            let rows = try await client.call(Self.path(id) + "/resolve").items
            notice = "Resolved \(id):\n" + rows.map { "\($0["provider_id"].text)/\($0["model_id"].text) · \($0["account_id"].text.prefix(8)) · \($0["has_credentials"].flag ? $0["auth_kind"].text : "no credentials")" }.joined(separator: "\n")
        } catch { self.error = error.localizedDescription }
    }
}

private extension OrbJSON { var healthID: String { self["account_id"].text } }

struct OrbChainDraft: Identifiable {
    struct Entry: Identifiable { let id = UUID(); var provider: String; var model: String }
    let id = UUID()
    var existing = false
    var chainID = "", name = "", stripThinking = false
    var entries: [Entry] = [Entry(provider: "", model: "")]
    init() {}
    init(_ chain: OrbJSON) {
        existing = true
        chainID = chain.selfID; name = chain["name"].text; stripThinking = chain["strip_thinking"].flag
        entries = chain["entries"].items.map { Entry(provider: $0["provider_id"].text, model: $0["model_id"].text) }
    }
}

private struct OrbChainEditor: View {
    @State var draft: OrbChainDraft
    let catalog: [OrbJSON]
    let onSave: (OrbChainDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    private var valid: Bool {
        !draft.chainID.trimmingCharacters(in: .whitespaces).isEmpty && !draft.entries.isEmpty
            && draft.entries.allSatisfy { !$0.provider.isEmpty && !$0.model.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Chain ID (e.g. builtin/smart)", text: $draft.chainID).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(draft.existing)
                    TextField("Name", text: $draft.name)
                    Toggle("Strip <think> blocks", isOn: $draft.stripThinking)
                }
                Section("Entries, in fallback order") {
                    ForEach($draft.entries) { $entry in entryRow($entry) }
                        .onDelete { draft.entries.remove(atOffsets: $0) }
                        .onMove { draft.entries.move(fromOffsets: $0, toOffset: $1) }
                    Button { draft.entries.append(.init(provider: "", model: "")) } label: { Label("Add entry", systemImage: "plus") }
                }
            }
            .navigationTitle(draft.existing ? "Edit chain" : "New chain").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("Save") { onSave(draft) }.disabled(!valid) }
            }
        }
    }

    private func entryRow(_ entry: Binding<OrbChainDraft.Entry>) -> some View {
        let models = catalog.first { $0.selfID == entry.wrappedValue.provider }?["models"].items ?? []
        return VStack(alignment: .leading) {
            Picker("Provider", selection: entry.provider) {
                Text("Choose provider").tag("")
                ForEach(catalog, id: \.selfID) { Text($0["name"].text.isEmpty ? $0.selfID : $0["name"].text).tag($0.selfID) }
                if !entry.wrappedValue.provider.isEmpty && !catalog.contains(where: { $0.selfID == entry.wrappedValue.provider }) {
                    Text(entry.wrappedValue.provider).tag(entry.wrappedValue.provider)
                }
            }
            if models.isEmpty {
                TextField("Model ID", text: entry.model).textInputAutocapitalization(.never).autocorrectionDisabled()
            } else {
                Picker("Model", selection: entry.model) {
                    Text("Choose model").tag("")
                    ForEach(models, id: \.selfID) { Text($0["name"].text.isEmpty ? $0.selfID : $0["name"].text).tag($0.selfID) }
                    if !entry.wrappedValue.model.isEmpty && !models.contains(where: { $0.selfID == entry.wrappedValue.model }) {
                        Text(entry.wrappedValue.model).tag(entry.wrappedValue.model)
                    }
                }
            }
        }
    }
}

// MARK: - Proxy API keys (Orb: ProxyApiKeys.tsx, /api/proxy-keys)

struct OrbProxyKeysSettings: View {
    @State private var client = OrbSettingsClient()
    @State private var keys: [OrbJSON] = []
    @State private var error = ""
    @State private var newName = ""
    @State private var created: OrbJSON = .null
    @State private var deleting: OrbJSON?
    @State private var cleanupDays = 30
    @State private var stale: [OrbJSON] = []
    @State private var confirmCleanup = false
    @State private var busy = false

    var body: some View {
        List {
            OrbSettingsError(message: error)
            createdSection
            Section {
                TextField("Key name", text: $newName)
                Button("Create key") { Task { await create() } }.disabled(busy || newName.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: { Text("New key") } footer: { Text("Proxy keys authenticate OpenAI-compatible clients against this backend's model router.") }
            Section("Keys") {
                if keys.isEmpty { Text("No keys.").foregroundStyle(.secondary) }
                ForEach(keys, id: \.selfID) { key in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key["name"].text).font(.subheadline)
                        Text("\(key["key_prefix"].text)… · created \(OrbStyle.relativeTime(key["created_at"].text)) · \(key["last_used_at"].text.isEmpty ? "never used" : "used \(OrbStyle.relativeTime(key["last_used_at"].text))")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions { Button("Delete", role: .destructive) { deleting = key } }
                }
            }
            Section {
                Stepper("Unused for \(cleanupDays) days", value: $cleanupDays, in: 1...365)
                Button("Find stale keys") { Task { await previewCleanup() } }.disabled(busy)
            } header: { Text("Cleanup") }
        }
        .scrollContentBackground(.hidden).background(OrbStyle.background)
        .navigationTitle("API Keys").navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .alert("Delete key?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { key in
            Button("Delete", role: .destructive) { Task { await delete([key]) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Clients using \($0["name"].text) stop working.") }
        .alert(stale.isEmpty ? "No stale keys" : "Delete \(stale.count) stale key\(stale.count == 1 ? "" : "s")?", isPresented: $confirmCleanup) {
            if !stale.isEmpty { Button("Delete", role: .destructive) { Task { await delete(stale) } } }
            Button(stale.isEmpty ? "OK" : "Cancel", role: .cancel) {}
        } message: { Text(stale.map { $0["name"].text }.joined(separator: ", ")) }
    }

    @ViewBuilder private var createdSection: some View {
        if created != .null {
            Section {
                Text(created["key"].text).font(.caption.monospaced()).textSelection(.enabled)
                Button("Copy key") { UIPasteboard.general.string = created["key"].text; OrbHaptics.success() }
                Button("Done") { created = .null }
            } header: { Text("Key \(created["name"].text)") } footer: { Text("Copy it now. It is not shown again.") }
        }
    }

    private func load() async {
        do { keys = try await client.call("/api/proxy-keys").items; error = "" }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func create() async {
        busy = true; defer { busy = false }
        do {
            created = try await client.call("/api/proxy-keys", method: "POST", body: .object(["name": .string(newName.trimmingCharacters(in: .whitespaces))]))
            newName = ""; error = ""
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
        await load()
    }
    private func previewCleanup() async {
        busy = true; defer { busy = false }
        do {
            stale = try await client.call("/api/proxy-keys/cleanup", method: "POST", body: .object(["max_age_days": .number(Double(cleanupDays)), "dry_run": .bool(true)]))["keys"].items
            confirmCleanup = true
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func delete(_ targets: [OrbJSON]) async {
        busy = true; defer { busy = false }
        var failures: [String] = []
        for key in targets {
            do { _ = try await client.call("/api/proxy-keys/\(OrbCore.escape(key.selfID))", method: "DELETE") }
            catch { failures.append("\(key["name"].text): \(error.localizedDescription)") }
        }
        error = failures.joined(separator: "\n")
        stale = []
        await load()
    }
}

// MARK: - Skills (Orb: SkillsSettings.tsx, /api/library/skill)

struct OrbSkillsSettings: View {
    @State private var client = OrbSettingsClient()
    @State private var skills: [OrbJSON] = []
    @State private var projects: [OrbJSON] = []
    @State private var search = ""
    @State private var error = ""
    @State private var creating = false
    @State private var newName = ""
    @State private var repo: OrbJSON?
    @State private var pulling = false
    @State private var opened: OrbSkillTarget?
    @State private var deleteTarget: String?
    @State private var deleteError = ""
    @State private var deleting = false

    /// Plain words for a failed delete (desktop: deleteMessage in SkillsSettings.tsx).
    static func deleteMessage(_ name: String, _ raw: String) -> String {
        let detail = raw.replacingOccurrences(of: #"^\d{3}\s+"#, with: "", options: .regularExpression)
        if detail.range(of: "gpg|sign", options: [.regularExpression, .caseInsensitive]) != nil { return "Core couldn’t sign the Library commit, so \(name) is still there." }
        if detail.range(of: "push|rejected|denied", options: [.regularExpression, .caseInsensitive]) != nil { return "Core couldn’t push the Library, so the delete isn’t saved yet." }
        return "Couldn’t delete \(name): \(detail)"
    }

    /// "Th0rgal/sandboxed-library · synced 2m ago" (desktop: SkillsSettings header).
    static func repoLine(_ status: OrbJSON?, now: Double = Date().timeIntervalSince1970) -> String {
        guard let status else { return "Library" }
        var remote = status["remote"].text
        if remote.hasSuffix(".git") { remote.removeLast(4) }
        let name = remote.split(whereSeparator: { $0 == "/" || $0 == ":" }).suffix(2).joined(separator: "/")
        let label = name.contains("/") ? name : "Library"
        guard let at = status["last_synced_at"].doubleValue else { return "\(label) · not synced yet" }
        return "\(label) · synced " + OrbSkillTime.ago(now - at)
    }

    private var filtered: [OrbJSON] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? skills : skills.filter { $0["name"].text.lowercased().contains(q) || $0["description"].text.lowercased().contains(q) }
    }

    var body: some View {
        List {
            OrbSettingsError(message: error)
            Section {
                ForEach(filtered, id: \.skillName) { skill in
                    // A skill behaves like a file: tap opens it, long-press or swipe for the rest.
                    Button { opened = OrbSkillTarget(name: skill.skillName, history: false) } label: { OrbSkillRow(skill: skill) }
                        .foregroundStyle(.primary)
                        .contextMenu {
                            Button { opened = OrbSkillTarget(name: skill.skillName, history: false) } label: { Label("Edit", systemImage: "pencil") }
                            Button { opened = OrbSkillTarget(name: skill.skillName, history: true) } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                            Button(role: .destructive) { deleteError = ""; deleteTarget = skill.skillName } label: { Label("Delete…", systemImage: "trash") }
                        }
                        .swipeActions { Button(role: .destructive) { deleteError = ""; deleteTarget = skill.skillName } label: { Label("Delete", systemImage: "trash") } }
                }
            } header: { Text(pulling ? "Pulling…" : Self.repoLine(repo)).textCase(nil) }
            Section("Project skills (@context/skills)") {
                ForEach(projects, id: \.projectSlug) { p in
                    NavigationLink { OrbDocuments(project: p.projectSlug, path: "skills") } label: { Text(p["title"].text.isEmpty ? p.projectSlug : p["title"].text) }
                }
            }
        }
        .searchable(text: $search, prompt: "Search skills")
        .scrollContentBackground(.hidden).background(OrbStyle.background)
        .navigationTitle("Skills").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button { Task { await pull() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Pull from the repo").disabled(pulling) }
            ToolbarItem(placement: .topBarTrailing) { Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("New skill") }
        }
        .alert("New Library skill", isPresented: $creating) {
            TextField("skill-name", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Create") { Task { await create() } }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .navigationDestination(item: $opened) { t in OrbSkillEditor(name: t.name, startOnHistory: t.history) }
        // A failed delete stays in this one confirm, in plain words, with Retry.
        .alert(deleteTarget.map { "Delete \($0)?" } ?? "", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 && !deleting { deleteTarget = nil } })) {
            Button(deleteError.isEmpty ? "Delete" : "Retry", role: .destructive) { if let name = deleteTarget { Task { await delete(name) } } }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { Text(deleteError.isEmpty ? "It leaves the Library and every agent." : deleteError) }
        .refreshable { await load() }
        .task { await load() }
    }

    /// Optimistic: the row goes at once and comes back if Core refuses. Retry-safe:
    /// a skill already gone (an earlier try failed at commit) only needs the commit.
    private func delete(_ name: String) async {
        deleting = true; defer { deleting = false }
        let before = skills
        skills.removeAll { $0.skillName == name }
        do {
            do { _ = try await client.callText("/api/library/skill/\(OrbCore.escape(name))", method: "DELETE") }
            catch { if !"\(error)".localizedCaseInsensitiveContains("not found") && !"\(error)".contains("404") { throw error } }
            try await OrbSkillEditor.commitAndPush("skill: delete \(name)", client: client)
            deleteTarget = nil; deleteError = ""
        } catch is CancellationError { skills = before } catch {
            skills = before
            deleteError = Self.deleteMessage(name, error.localizedDescription)
            deleteTarget = name
        }
    }

    private func load() async {
        do {
            skills = try await client.call("/api/library/skill").items.sorted { $0.skillName < $1.skillName }
            repo = try? await client.call("/api/library/status")
            let raw = (try? await client.call("/api/projects")) ?? .null
            projects = raw.items.isEmpty ? raw["projects"].items : raw.items
            error = ""
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func pull() async {
        pulling = true; defer { pulling = false }
        do { _ = try await client.callText("/api/library/sync", method: "POST"); await load() }
        catch is CancellationError {} catch { self.error = "Couldn’t pull the Library: \(error.localizedDescription)" }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "-")
        newName = ""
        guard !name.isEmpty else { return }
        let template = "---\nname: \(name)\ndescription: Describe when to use this skill.\n---\n\n# \(name)\n"
        do {
            _ = try await client.callText("/api/library/skill/\(OrbCore.escape(name))", method: "PUT", body: .object(["content": .string(template)]))
            try await OrbSkillEditor.commitAndPush("skill: create \(name)", client: client)
            await load()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

/// "just now" / "2m ago" from the shared Lean relative-time buckets.
enum OrbSkillTime {
    static func ago(_ secs: Double) -> String {
        let t = OrbKernel.relativeTimeString(elapsedSecs: Int(max(0, secs)))
        return t == "now" ? "just now" : "\(t) ago"
    }
}

private extension OrbJSON {
    var skillName: String { self["name"].text }
    var projectSlug: String { self["slug"].text }
}

/// Name, one-line description and at most one badge (desktop: skillBadge in skillRows.ts).
/// Drift and local edits are desktop-only, so a phone only ever shows "Always loaded".
struct OrbSkillTarget: Hashable { let name: String; let history: Bool }

private struct OrbSkillRow: View {
    let skill: OrbJSON
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(skill["name"].text).font(.subheadline.weight(.medium))
                if skill["scope"].text == "global" {
                    Text("Always loaded").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: Capsule())
                }
            }
            if !skill["description"].text.isEmpty { Text(skill["description"].text).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

private struct OrbSkillEditor: View {
    let name: String
    var startOnHistory = false
    @State private var files: [String] = []
    @State private var client = OrbSettingsClient()
    @State private var content = ""
    @State private var original = ""
    @State private var loaded = false
    @State private var editing = false
    @State private var saving = false
    @State private var error = ""
    @State private var saved = false
    @State private var history: [OrbJSON]?
    @State private var confirmDelete = false
    @State private var deleteError = ""
    @Environment(\.dismiss) private var dismiss

    /// Save lands in the Library repo (desktop: commitAndPush in skillsApi.ts).
    static func commitAndPush(_ message: String, client: OrbSettingsClient) async throws {
        _ = try await client.callText("/api/library/commit", method: "POST", body: .object(["message": .string(message)]))
        _ = try await client.callText("/api/library/push", method: "POST")
    }

    /// The rendered view hides the frontmatter.
    static func body(_ markdown: String) -> String {
        guard markdown.hasPrefix("---\n"), let end = markdown.range(of: "\n---", range: markdown.index(markdown.startIndex, offsetBy: 4)..<markdown.endIndex) else { return markdown }
        return String(markdown[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollViewReader { proxy in
        List {
            if !error.isEmpty {
                Section { OrbNotice(message: error); if content != original { Button("Retry") { Task { await save(content, message: "skill: update \(name)") } } } }
            }
            Section {
                if editing {
                    TextEditor(text: $content).font(.system(.footnote, design: .monospaced)).frame(minHeight: 320).disabled(!loaded || saving)
                } else {
                    OrbRichText(source: Self.body(content).isEmpty ? "_Loading…_" : Self.body(content))
                }
            } footer: { if saved && content == original { Text("Saved to repo") } }
            // Its files, like opening a folder.
            if !files.isEmpty {
                Section("Files") {
                    ForEach(files, id: \.self) { rel in
                        NavigationLink { OrbSkillFileView(skill: name, rel: rel) } label: {
                            Label { Text(rel).truncationMode(.middle).lineLimit(1) } icon: { Image(systemName: "doc.text") }
                        }
                    }
                }
            }
            Section("History") {
                Color.clear.frame(height: 0).id("history")
                if let history {
                    if history.isEmpty { Text("No saved versions yet.").foregroundStyle(.secondary) }
                    ForEach(Array(history.enumerated()), id: \.offset) { i, v in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(v["subject"].text).font(.subheadline).lineLimit(1)
                                Text("\(v["author"].text) · \(OrbSkillTime.ago(Date().timeIntervalSince1970 - (v["timestamp"].doubleValue ?? 0))) · \(String(v["rev"].text.prefix(7)))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if i > 0 { Button("Restore") { Task { await restore(v["rev"].text) } }.disabled(saving) }
                        }
                    }
                } else { Text("Loading…").foregroundStyle(.secondary).redacted(reason: .placeholder) }
            }
        }
        .scrollContentBackground(.hidden).background(OrbStyle.background)
        .navigationTitle(name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Like a document: Edit/Save in the bar, everything else in the … menu.
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(editing ? "Done" : "Edit") { editing.toggle() }.disabled(!loaded)
                Button(saving ? "Saving…" : "Save") { Task { await save(content, message: "skill: update \(name)") } }.disabled(!loaded || saving || content == original)
                Menu {
                    Button { withAnimation { proxy.scrollTo("history", anchor: .top) } } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    Button(role: .destructive) { deleteError = ""; confirmDelete = true } label: { Label("Delete…", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Actions for \(name)")
            }
        }
        // A failed delete stays here in plain words, with Retry.
        .alert("Delete \(name)?", isPresented: $confirmDelete) {
            Button(deleteError.isEmpty ? "Delete" : "Retry", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text(deleteError.isEmpty ? "It leaves the Library and every agent." : deleteError) }
        .task { await load(); if startOnHistory { withAnimation { proxy.scrollTo("history", anchor: .top) } } }
        }
    }

    private func delete() async {
        do {
            do { _ = try await client.callText("/api/library/skill/\(OrbCore.escape(name))", method: "DELETE") }
            catch { if !"\(error)".localizedCaseInsensitiveContains("not found") && !"\(error)".contains("404") { throw error } }
            try await Self.commitAndPush("skill: delete \(name)", client: client)
            dismiss()
        } catch is CancellationError {} catch {
            deleteError = OrbSkillsSettings.deleteMessage(name, error.localizedDescription)
            confirmDelete = true
        }
    }

    private func load() async {
        do {
            let skill = try await client.call("/api/library/skill/\(OrbCore.escape(name))")
            content = skill["content"].text
            files = Array(Set(skill["references"].items.map(\.text) + skill["files"].items.map { $0["path"].text.isEmpty ? $0["name"].text : $0["path"].text }).filter { !$0.isEmpty && $0 != "SKILL.md" }).sorted()
            original = content; loaded = true; error = ""
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
        // Older cores have no history endpoint: the section then stays empty.
        history = (try? await client.call("/api/library/skill/\(OrbCore.escape(name))/history").items) ?? []
    }
    private func save(_ text: String, message: String) async {
        saving = true; saved = false; defer { saving = false }
        do {
            _ = try await client.callText("/api/library/skill/\(OrbCore.escape(name))", method: "PUT", body: .object(["content": .string(text)]))
            try await Self.commitAndPush(message, client: client)
            content = text; original = text; error = ""; saved = true; editing = false
            history = (try? await client.call("/api/library/skill/\(OrbCore.escape(name))/history").items) ?? history
        } catch is CancellationError {} catch { self.error = "Couldn’t save to the repo: \(error.localizedDescription)" }
    }
    private func restore(_ rev: String) async {
        do {
            let old = try await client.callText("/api/library/skill/\(OrbCore.escape(name))/history/\(rev)")
            await save(old, message: "skill: restore \(name) to \(rev.prefix(7))")
        } catch { self.error = error.localizedDescription }
    }
}

/// A reference file of a skill, read-only on a phone (desktop edits it in the skill panel).
private struct OrbSkillFileView: View {
    let skill: String
    let rel: String
    @State private var client = OrbSettingsClient()
    @State private var text: String?
    @State private var error = ""
    var body: some View {
        ScrollView {
            if !error.isEmpty { OrbNotice(message: error).padding(16) }
            Group {
                if rel.hasSuffix(".md") { OrbRichText(source: text ?? "_Loading…_") }
                else { Text(text ?? "Loading…").font(.system(.footnote, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .padding(16)
            .redacted(reason: text == nil ? .placeholder : [])
        }
        .background(OrbStyle.background)
        .navigationTitle((rel as NSString).lastPathComponent).navigationBarTitleDisplayMode(.inline)
        .task {
            do { text = try await client.callText("/api/library/skill/\(OrbCore.escape(skill))/files/" + rel.split(separator: "/").map { OrbCore.escape(String($0)) }.joined(separator: "/")) }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Hermes coordinator (Orb: HermesSettings.tsx, /api/cloud/hermes/settings)

struct OrbHermesSettings: View {
    @State private var client = OrbSettingsClient()
    @State private var state: OrbJSON = .null
    @State private var draft = Draft()
    @State private var busy = false
    @State private var error = ""
    @State private var notice = ""

    struct Draft: Equatable {
        var defaultModel = "", reasoningEffort = "", telegramProgress = "new", soul = ""
        var useRouter = true, memory = true, userProfile = true, compression = true, telegramCleanup = false
        var memoryLimit = 8000.0, userLimit = 4000.0, compressionThreshold = 0.5
        init() {}
        init(_ s: OrbJSON) {
            defaultModel = s["default_model"].text; reasoningEffort = s["reasoning_effort"].text
            telegramProgress = s["telegram_tool_progress"].text.isEmpty ? "new" : s["telegram_tool_progress"].text
            soul = s["soul_markdown"].text
            useRouter = s["use_sandboxed_router"].flag; memory = s["memory_enabled"].flag; userProfile = s["user_profile_enabled"].flag
            compression = s["compression_enabled"].flag; telegramCleanup = s["telegram_cleanup_progress"].flag
            memoryLimit = s["memory_char_limit"].number ?? 8000; userLimit = s["user_char_limit"].number ?? 4000
            compressionThreshold = s["compression_threshold"].number ?? 0.5
        }
        func wire(restart: Bool) -> OrbJSON {
            .object([
                "default_model": .string(defaultModel.trimmingCharacters(in: .whitespaces)), "reasoning_effort": .string(reasoningEffort),
                "use_sandboxed_router": .bool(useRouter), "memory_enabled": .bool(memory), "user_profile_enabled": .bool(userProfile),
                "memory_char_limit": .number(memoryLimit), "user_char_limit": .number(userLimit),
                "compression_enabled": .bool(compression), "compression_threshold": .number(compressionThreshold),
                "telegram_tool_progress": .string(telegramProgress), "telegram_cleanup_progress": .bool(telegramCleanup),
                "soul_markdown": .string(soul), "restart_service": .bool(restart),
            ])
        }
    }

    var body: some View {
        Form {
            OrbSettingsError(message: error)
            if !notice.isEmpty { Section { Text(notice).font(.footnote).foregroundStyle(OrbStyle.success) } }
            if state == .null {
                Section { HStack(spacing: 8) { OrbRunningDots(size: 10); Text("Loading Hermes settings…").foregroundStyle(.secondary) } }
            } else {
                runtimeSection
                modelSection
                memorySection
                channelSection
                actionsSection
            }
        }
        .scrollContentBackground(.hidden).background(OrbStyle.background)
        .navigationTitle("Assistant").navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var runtimeSection: some View {
        let runtime = state["runtime"], sessions = state["sessions"]
        // Core's HermesRuntimeSummary: service_active, uses_sandboxed_proxy, token_present
        // (no service_state/api_server_healthy, which made this always read "Unreachable").
        return Section("Runtime & gateway") {
            ForEach(OrbTurnSummary.hermesRuntime(runtime), id: \.0) { row in
                LabeledContent(row.0, value: row.1)
            }
            if let line = OrbTurnSummary.hermesSessions(sessions) {
                LabeledContent("Sessions", value: line)
            }
        }
    }

    private var modelSection: some View {
        let models = state["models"].items.filter { !$0.selfID.isEmpty }
        return Section("Model & router") {
            Toggle("Route through Core router", isOn: $draft.useRouter)
            Picker("Default model", selection: $draft.defaultModel) {
                if !draft.defaultModel.isEmpty && !models.contains(where: { $0.selfID == draft.defaultModel }) { Text("\(draft.defaultModel) (current)").tag(draft.defaultModel) }
                ForEach(models, id: \.selfID) { m in Text(m["displayName"].text.isEmpty ? (m["name"].text.isEmpty ? m.selfID : m["name"].text) : m["displayName"].text).tag(m.selfID) }
            }
            Picker("Reasoning effort", selection: $draft.reasoningEffort) {
                Text("Default").tag("")
                ForEach(state["efforts"].items.filter { !$0.selfID.isEmpty }, id: \.selfID) { e in Text(e["name"].text.isEmpty ? e.selfID : e["name"].text).tag(e.selfID) }
            }
        }
    }

    private var memorySection: some View {
        Section("Memory & context compression") {
            Toggle("Persistent memory (MEMORY.md)", isOn: $draft.memory)
            if draft.memory { Stepper("Limit \(Int(draft.memoryLimit)) chars", value: $draft.memoryLimit, in: 1000...100_000, step: 1000) }
            Toggle("User profile memory (USER.md)", isOn: $draft.userProfile)
            if draft.userProfile { Stepper("Limit \(Int(draft.userLimit)) chars", value: $draft.userLimit, in: 1000...100_000, step: 1000) }
            Toggle("Context auto-compression", isOn: $draft.compression)
            if draft.compression {
                VStack(alignment: .leading) {
                    Text("Threshold \(Int(draft.compressionThreshold * 100))% of context")
                    Slider(value: $draft.compressionThreshold, in: 0.1...0.95, step: 0.05)
                }
            }
        }
    }

    private var channelSection: some View {
        Section("Channels & persona (SOUL.md)") {
            Picker("Telegram tool progress", selection: $draft.telegramProgress) {
                Text("Off").tag("off"); Text("New message").tag("new"); Text("Edit in place").tag("edit"); Text("All updates").tag("all")
            }
            Toggle("Clean up Telegram progress messages", isOn: $draft.telegramCleanup)
            TextEditor(text: $draft.soul).font(.system(.footnote, design: .monospaced)).frame(minHeight: 160)
        }
    }

    private var actionsSection: some View {
        Section {
            Button(busy ? "Saving…" : "Save") { Task { await save(restart: false) } }.disabled(busy || draft == Draft(state))
            Button("Save & restart Hermes") { Task { await save(restart: true) } }.disabled(busy)
        }
    }

    private func load() async {
        do { state = try await client.call("/api/cloud/hermes/settings"); draft = Draft(state); error = "" }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func save(restart: Bool) async {
        busy = true; defer { busy = false }
        notice = ""
        do {
            state = try await client.call("/api/cloud/hermes/settings", method: "PUT", body: draft.wire(restart: restart))
            draft = Draft(state); error = ""
            notice = restart ? "Saved configuration and restarted Hermes service." : "Saved Hermes configuration."
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
