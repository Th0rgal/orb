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
        .navigationTitle("Routing").navigationBarTitleDisplayMode(.inline)
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
        .navigationTitle("Proxy API keys").navigationBarTitleDisplayMode(.inline)
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

    private var filtered: [OrbJSON] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? skills : skills.filter { $0["name"].text.lowercased().contains(q) || $0["description"].text.lowercased().contains(q) }
    }

    var body: some View {
        List {
            OrbSettingsError(message: error)
            Section {
                ForEach(filtered, id: \.skillName) { skill in
                    NavigationLink { OrbSkillEditor(name: skill.skillName) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.skillName).font(.subheadline.weight(.medium))
                            if !skill["description"].text.isEmpty { Text(skill["description"].text).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }
                }
            } header: { Text("Library catalog (\(filtered.count))") } footer: { Text("Library skills are synced into every mission workspace.") }
            Section("Project skills (@context/skills)") {
                ForEach(projects, id: \.projectSlug) { p in
                    NavigationLink { OrbDocuments(project: p.projectSlug, path: "skills") } label: { Text(p["title"].text.isEmpty ? p.projectSlug : p["title"].text) }
                }
            }
        }
        .searchable(text: $search, prompt: "Search skills")
        .scrollContentBackground(.hidden).background(OrbStyle.background)
        .navigationTitle("Skills").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("New skill") } }
        .alert("New Library skill", isPresented: $creating) {
            TextField("skill-name", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Create") { Task { await create() } }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            skills = try await client.call("/api/library/skill").items.sorted { $0.skillName < $1.skillName }
            let raw = (try? await client.call("/api/projects")) ?? .null
            projects = raw.items.isEmpty ? raw["projects"].items : raw.items
            error = ""
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "-")
        newName = ""
        guard !name.isEmpty else { return }
        let template = "---\nname: \(name)\ndescription: Describe when to use this skill.\n---\n\n# \(name)\n"
        do {
            _ = try await client.call("/api/library/skill/\(OrbCore.escape(name))", method: "PUT", body: .object(["content": .string(template)]))
            await load()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

private extension OrbJSON {
    var skillName: String { self["name"].text }
    var projectSlug: String { self["slug"].text }
}

private struct OrbSkillEditor: View {
    let name: String
    @State private var client = OrbSettingsClient()
    @State private var content = ""
    @State private var original = ""
    @State private var loaded = false
    @State private var saving = false
    @State private var error = ""
    @State private var notice = ""

    var body: some View {
        VStack(spacing: 0) {
            if !error.isEmpty { OrbNotice(message: error).padding(.horizontal) }
            if !notice.isEmpty { Text(notice).font(.footnote).foregroundStyle(.secondary).padding(.horizontal) }
            TextEditor(text: $content)
                .font(.system(.footnote, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .disabled(!loaded)
        }
        .background(OrbStyle.background)
        .navigationTitle(name).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(saving ? "Saving…" : "Save") { Task { await save() } }.disabled(!loaded || saving || content == original) } }
        .task { await load() }
    }

    private func load() async {
        do {
            content = try await client.call("/api/library/skill/\(OrbCore.escape(name))")["content"].text
            original = content; loaded = true; error = ""
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func save() async {
        saving = true; defer { saving = false }
        do {
            _ = try await client.call("/api/library/skill/\(OrbCore.escape(name))", method: "PUT", body: .object(["content": .string(content)]))
            original = content; error = ""; notice = "Saved to the Library."
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
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
            Toggle("Route through sandboxed.sh router", isOn: $draft.useRouter)
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
