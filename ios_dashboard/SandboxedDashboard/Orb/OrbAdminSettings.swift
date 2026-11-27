import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Models & Routing (Orb: RoutingSettings.tsx, /api/model-routing)

enum OrbRoutingProvider {
    static func find(_ catalog: [OrbJSON], _ id: String) -> OrbJSON? {
        catalog.first { $0.selfID == id } ?? catalog.first {
            $0.selfID.hasPrefix("custom:") && (String($0.selfID.dropFirst(7)) == id ||
                $0["name"].text.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) } == id)
        }
    }
    static func label(_ catalog: [OrbJSON], _ id: String) -> String {
        guard let provider = find(catalog, id), !provider["name"].text.isEmpty else { return id }
        return provider["name"].text
    }
}

struct OrbRoutingSettings: View {
    @State private var client = OrbSettingsClient()
    @State private var chains: [OrbJSON] = []
    @State private var health: [OrbJSON] = []
    @State private var events: [OrbJSON] = []
    @State private var catalog: [OrbJSON] = []
    @State private var providerLabels: [String: String] = [:]
    @State private var showHealthyAccounts = false
    @State private var showEvents = false
    @State private var error = ""
    @State private var notice = ""
    @State private var editing: OrbChainDraft?
    @State private var deleting: OrbJSON?
    @State private var busy = false
    @State private var googleCapText = "10"
    @State private var savedGoogleCap = 10

    var body: some View {
        List {
            OrbSettingsError(message: error)
            if !notice.isEmpty { Section { Text(notice).font(.footnote).textSelection(.enabled) } }
            chainsSection
            concurrencySection
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
                    Text(chain["entries"].items.map { "\(OrbRoutingProvider.label(catalog, $0["provider_id"].text))/\($0["model_id"].text)" }.joined(separator: " → "))
                        .font(.caption).foregroundStyle(OrbStyle.textSecondary)
                }
                .contextMenu { chainMenu(chain) }
                .swipeActions { Button("Delete", role: .destructive) { deleting = chain } }
            }
        } header: { Text("Fallback chains") } footer: { Text("Requests to a chain ID try each provider/model in order, skipping accounts in cooldown. Long-press a chain for actions.") }
    }

    private var googleCapDirty: Bool {
        Int(googleCapText.trimmingCharacters(in: .whitespaces)) != savedGoogleCap
    }

    private var concurrencySection: some View {
        Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Google & Antigravity")
                        .font(.subheadline)
                    Text("Per-account in-flight cap (1–128)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                TextField("10", text: $googleCapText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .accessibilityLabel("Google and Antigravity per-account limit")
                Button("Save") {
                    Task { await saveGoogleConcurrency() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(busy || !googleCapDirty)
            }
        } header: {
            Text("Router concurrency")
        } footer: {
            Text("Maximum concurrent requests per Google or Antigravity account before spilling to the next account or queueing. Applies immediately without redeploying.")
        }
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

    private func isAttentionHealth(_ h: OrbJSON) -> Bool {
        !h["is_healthy"].flag || h["is_degraded"].flag || (h["cooldown_remaining_secs"].number ?? 0) > 0
    }

    private func accountTitle(_ h: OrbJSON) -> String {
        let pid = h["provider_id"].text.isEmpty ? h["account_id"].text : h["provider_id"].text
        let aid = h["account_id"].text
        if let mapped = providerLabels[aid], !mapped.isEmpty, mapped.lowercased() != pid.lowercased() {
            return "\(pid) · \(mapped)"
        }
        let inlineLabel = h["account_label"].text.isEmpty ? h["account_email"].text : h["account_label"].text
        if !inlineLabel.isEmpty {
            return "\(pid) · \(inlineLabel)"
        }
        if !aid.isEmpty && aid != pid {
            return "\(pid) · \(aid.prefix(8))"
        }
        return pid
    }

    @ViewBuilder
    private func healthRow(_ h: OrbJSON) -> some View {
        HStack {
            Circle()
                .fill(h["is_healthy"].flag ? (h["is_degraded"].flag ? OrbStyle.warning : OrbStyle.success) : OrbStyle.error)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(accountTitle(h))
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(healthLine(h))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if h["disabled_by_provider"].flag || (h["cooldown_remaining_secs"].number ?? 0) > 0 {
                Button("Clear") {
                    Task { await run { _ = try await client.call("/api/model-routing/health/\(OrbCore.escape(h["account_id"].text))/clear", method: "POST") } }
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private var healthSection: some View {
        let attentionRows = health.filter(isAttentionHealth)
        let healthyRows = health.filter { !isAttentionHealth($0) }
        return Section("Provider health") {
            if health.isEmpty { Text("No requests recorded yet.").foregroundStyle(.secondary) }
            ForEach(attentionRows, id: \.healthID) { healthRow($0) }
            if !healthyRows.isEmpty {
                DisclosureGroup("Healthy accounts (\(healthyRows.count))", isExpanded: $showHealthyAccounts) {
                    ForEach(healthyRows, id: \.healthID) { healthRow($0) }
                }
                .font(.subheadline)
            }
        }
    }

    private func healthLine(_ h: OrbJSON) -> String {
        var parts = ["\(h["total_successes"].display)/\(h["total_requests"].display) ok"]
        if let rl = h["total_rate_limits"].number, rl > 0 { parts.append("\(Int(rl)) rate limits") }
        if let keyRpm = h["rate_limit_snapshot"]["key_rpm_limit"].number {
            parts.append("\(Int(keyRpm)) RPM")
        } else if let reqLim = h["rate_limit_snapshot"]["requests_limit"].number {
            if let rem = h["rate_limit_snapshot"]["requests_remaining"].number {
                parts.append("\(Int(rem))/\(Int(reqLim)) req")
            } else {
                parts.append("\(Int(reqLim)) RPM")
            }
        }
        if let latency = h["avg_latency_ms"].number { parts.append("\(Int(latency)) ms") }
        if let cooldown = h["cooldown_remaining_secs"].number, cooldown > 0 {
            parts.append("cooldown \(OrbActivityCompaction.formatCooldown(Int(cooldown)))")
        }
        if h["disabled_by_provider"].flag {
            parts.append("disabled by provider")
            let message = h["disabled_by_provider_message"].text
            if !message.isEmpty { parts.append(message) }
        }
        if !h["last_failure_reason"].text.isEmpty { parts.append(h["last_failure_reason"].text) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var eventsSection: some View {
        if !events.isEmpty {
            Section {
                DisclosureGroup("Recent fallback events (\(events.count))", isExpanded: $showEvents) {
                    ForEach(Array(events.prefix(30).enumerated()), id: \.offset) { _, e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(e["from_provider"].text)/\(e["from_model"].text) → \(e["to_provider"].text.isEmpty ? "none" : e["to_provider"].text)")
                                .font(.caption)
                                .lineLimit(1)
                            Text("\(e["reason"].text) · \(e["chain_id"].text) · \(OrbStyle.relativeTime(e["timestamp"].text))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .font(.subheadline)
            }
        }
    }

    private func load() async {
        do {
            async let c = client.call("/api/model-routing/chains")
            async let h = client.call("/api/model-routing/health")
            async let e = client.call("/api/model-routing/events")
            async let p = client.call("/api/ai/providers")
            async let s = client.call("/api/settings")
            chains = try await c.items
            health = (try? await h.items) ?? []
            events = (try? await e.items) ?? []
            if let settingsResp = try? await s, let cap = settingsResp["google_max_concurrency"].number.map(Int.init), cap >= 1 {
                savedGoogleCap = cap
                googleCapText = "\(cap)"
            }
            if let provResp = try? await p {
                let list = provResp["providers"] == .null ? provResp.items : provResp["providers"].items
                var map: [String: String] = [:]
                for item in list {
                    let parsed = OrbProvidersSettings.splitDisplayName(item)
                    map[item["id"].text] = parsed.account.isEmpty ? parsed.title : parsed.account
                }
                providerLabels = map
            }
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

    private func saveGoogleConcurrency() async {
        guard let parsed = Int(googleCapText.trimmingCharacters(in: .whitespaces)), (1...128).contains(parsed) else {
            error = "Per-account concurrency must be a whole number from 1 to 128."
            return
        }
        await run {
            let updated = try await client.call("/api/settings", method: "PUT", body: .object(["google_max_concurrency": .number(Double(parsed))]))
            let resolved = updated["google_max_concurrency"].number.map(Int.init) ?? parsed
            savedGoogleCap = resolved
            googleCapText = "\(resolved)"
            notice = "Updated Google & Antigravity per-account cap to \(resolved)."
        }
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
                    TextField("Name", text: $draft.name).textInputAutocapitalization(.never).autocorrectionDisabled()
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
        let provider = OrbRoutingProvider.find(catalog, entry.wrappedValue.provider)
        let models = provider?["models"].items ?? []
        let selection = Binding(get: { provider?.selfID ?? entry.wrappedValue.provider }, set: { entry.wrappedValue.provider = $0 })
        return VStack(alignment: .leading) {
            Picker("Provider", selection: selection) {
                Text("Choose provider").tag("")
                ForEach(catalog, id: \.selfID) { Text(OrbRoutingProvider.label(catalog, $0.selfID)).tag($0.selfID) }
                if !entry.wrappedValue.provider.isEmpty && provider == nil {
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
    @State private var creatingKey = false
    @State private var created: OrbJSON = .null
    @State private var deleting: OrbJSON?
    @State private var cleanupDays = 30
    @State private var stale: [OrbJSON] = []
    @State private var confirmCleanup = false
    @State private var busy = false

    static func cleanKeyTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let spaceIdx = trimmed.lastIndex(of: " ") {
            let tail = String(trimmed[trimmed.index(after: spaceIdx)...])
            if tail.count >= 19, tail.dropFirst(4).first == "-", tail.contains("T"), (tail.hasSuffix("Z") || tail.contains("+") || tail.contains(":")) {
                let prefix = String(trimmed[..<spaceIdx]).trimmingCharacters(in: .whitespaces)
                if !prefix.isEmpty { return prefix }
            }
        }
        return trimmed
    }

    var body: some View {
        List {
            OrbSettingsError(message: error)
            createdSection
            Section {
                if keys.isEmpty { Text("No keys.").foregroundStyle(.secondary) }
                ForEach(keys, id: \.selfID) { key in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.cleanKeyTitle(key["name"].text)).font(.subheadline).lineLimit(1)
                        Text("\(key["key_prefix"].text)… · created \(OrbStyle.relativeTime(key["created_at"].text)) · \(key["last_used_at"].text.isEmpty ? "never used" : "used \(OrbStyle.relativeTime(key["last_used_at"].text))")")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .swipeActions { Button("Delete", role: .destructive) { deleting = key } }
                }
            } header: {
                Text("Keys (\(keys.count))")
            } footer: {
                Text("Proxy keys authenticate OpenAI-compatible clients against this backend's model router.")
            }
            Section("Cleanup") {
                Stepper("Unused for \(cleanupDays) days", value: $cleanupDays, in: 1...365)
                Button("Find stale keys") { Task { await previewCleanup() } }.disabled(busy)
            }
        }
        .scrollContentBackground(.hidden).background(OrbStyle.background)
        .navigationTitle("API Keys").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newName = ""
                    creatingKey = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New key")
            }
        }
        .alert("New API key", isPresented: $creatingKey) {
            TextField("Key name", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Create") { Task { await create() } }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { newName = "" }
        }
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
    @State private var repoSheetOpen = false
    @State private var repoDraft = ""
    @State private var repoBusy = false
    @State private var repoError = ""
    @State private var failedRepoRemote: String?
    @State private var unconfigured = false
    @State private var divergedMessage: String?
    @State private var divergedBusy = false

    static func isDivergedError(_ error: Error) -> Bool {
        if let http = error as? OrbHTTPError, http.status == 409 && http.detail.localizedCaseInsensitiveContains("DIVERGED") {
            return true
        }
        let text = error.localizedDescription
        return text.localizedCaseInsensitiveContains("DIVERGED_HISTORY") || (text.contains("409") && text.localizedCaseInsensitiveContains("diverged"))
    }

    static func isUnconfiguredError(_ error: Error) -> Bool {
        if let http = error as? OrbHTTPError, http.status == 503 { return true }
        let text = error.localizedDescription
        return text.contains("503") && text.localizedCaseInsensitiveContains("library")
    }

    static func libraryRemoteUpdateError(_ res: OrbJSON) -> String? {
        let err = res["library_error"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        return err.isEmpty ? nil : err
    }

    static func normalizeLibraryRemote(_ remote: String?) -> String {
        var s = (remote ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        return s
    }

    static func sameLibraryRemote(_ a: String?, _ b: String?) -> Bool {
        let na = normalizeLibraryRemote(a)
        let nb = normalizeLibraryRemote(b)
        return !na.isEmpty && na == nb
    }

    static func needsLibraryRemoteInit(
        nextRemote: String?,
        activeRepoRemote: String?,
        failedInitRemote: String?
    ) -> Bool {
        guard let nextRemote, !nextRemote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if let failedInitRemote, sameLibraryRemote(nextRemote, failedInitRemote) {
            return true
        }
        return !sameLibraryRemote(nextRemote, activeRepoRemote)
    }

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
            if unconfigured {
                Section("Library repository") {
                    Text("Connect your own Git repository to save your private skills across missions and workspaces.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Configure repository…") {
                        repoDraft = failedRepoRemote ?? repo?["remote"].text ?? ""
                        repoError = ""
                        repoSheetOpen = true
                    }
                    .accessibilityIdentifier("skills.configure-repo")
                }
            }
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    repoDraft = failedRepoRemote ?? repo?["remote"].text ?? ""
                    repoError = ""
                    repoSheetOpen = true
                } label: { Image(systemName: "link") }
                    .accessibilityLabel("Library repository")
            }
            ToolbarItem(placement: .topBarTrailing) { Button { Task { await pull() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Pull from the repo").disabled(pulling) }
            ToolbarItem(placement: .topBarTrailing) { Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("New skill") }
        }
        .sheet(isPresented: $repoSheetOpen) {
            let retryingFailed = failedRepoRemote != nil && Self.sameLibraryRemote(repoDraft, failedRepoRemote)
            NavigationStack {
                Form {
                    if !repoError.isEmpty {
                        Section { Text(repoError).font(.footnote).foregroundStyle(OrbStyle.error) }
                    }
                    Section {
                        TextField("git@github.com:org/library.git", text: $repoDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    } header: {
                        Text("Git remote URL")
                    } footer: {
                        Text("Leave empty or tap Disconnect to detach the Library remote.")
                    }
                    if !(repo?["remote"].text ?? "").isEmpty {
                        Section {
                            Button("Disconnect repository", role: .destructive) {
                                Task { await saveRepoRemote(nil) }
                            }
                            .disabled(repoBusy)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(OrbStyle.background)
                .navigationTitle("Library repository")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { repoSheetOpen = false }.disabled(repoBusy)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(repoBusy ? (retryingFailed ? "Retrying…" : "Saving…") : (retryingFailed ? "Retry" : "Save")) {
                            let trimmed = repoDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task { await saveRepoRemote(trimmed.isEmpty ? nil : trimmed) }
                        }
                        .disabled(repoBusy)
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .alert("Library history diverged", isPresented: Binding(get: { divergedMessage != nil }, set: { if !$0 && !divergedBusy { divergedMessage = nil } })) {
            Button("Reset to remote", role: .destructive) { Task { await resolveDiverged(forcePush: false) } }
            Button("Overwrite remote", role: .destructive) { Task { await resolveDiverged(forcePush: true) } }
            Button("Cancel", role: .cancel) { divergedMessage = nil }
        } message: {
            Text(divergedMessage ?? "Local and remote Library commits have diverged. Choose whether to reset Core to the remote branch or force-push Core's commits.")
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
            async let s = client.call("/api/library/skill")
            async let r = client.call("/api/library/status")
            async let p = client.call("/api/projects")
            skills = try await s.items.sorted { $0.skillName < $1.skillName }
            repo = try? await r
            let raw = (try? await p) ?? .null
            projects = raw.items.isEmpty ? raw["projects"].items : raw.items
            unconfigured = false
            error = ""
        } catch is CancellationError {} catch {
            if Self.isUnconfiguredError(error) {
                skills = []
                repo = try? await client.call("/api/library/status")
                unconfigured = true
                self.error = ""
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    private func pull() async {
        pulling = true; defer { pulling = false }
        do { _ = try await client.callText("/api/library/sync", method: "POST"); await load() }
        catch is CancellationError {} catch {
            if Self.isDivergedError(error) {
                divergedMessage = "Local and remote Library commits have diverged. Reset Core's copy to the remote branch, or overwrite the remote branch with Core's commits."
            } else {
                self.error = "Couldn’t pull the Library: \(error.localizedDescription)"
            }
        }
    }

    private func saveRepoRemote(_ url: String?) async {
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNext = (trimmed?.isEmpty == false) ? trimmed : nil
        let needsInit = Self.needsLibraryRemoteInit(
            nextRemote: normalizedNext,
            activeRepoRemote: repo?["remote"].text,
            failedInitRemote: failedRepoRemote
        )
        repoBusy = true; defer { repoBusy = false }
        repoError = ""
        do {
            var payload: [String: OrbJSON] = [
                "library_remote": normalizedNext.map(OrbJSON.string) ?? .null
            ]
            if needsInit {
                payload["force_reinitialize"] = .bool(true)
            }
            let res = try await client.call(
                "/api/settings/library-remote",
                method: "PUT",
                body: .object(payload)
            )
            if let err = Self.libraryRemoteUpdateError(res) {
                if let normalizedNext { failedRepoRemote = normalizedNext }
                repoError = err
                return
            }
            if let normalizedNext, needsInit, !res["library_reinitialized"].flag {
                let status = try await client.call("/api/library/status")
                guard Self.sameLibraryRemote(status["remote"].text, normalizedNext) else {
                    failedRepoRemote = normalizedNext
                    repoError = "Library repository was not initialized for this remote. Check the URL and retry."
                    return
                }
                repo = status
            }
            failedRepoRemote = nil
            repoSheetOpen = false
            await load()
        } catch is CancellationError {} catch {
            if let normalizedNext { failedRepoRemote = normalizedNext }
            repoError = error.localizedDescription
        }
    }

    private func resolveDiverged(forcePush: Bool) async {
        divergedBusy = true; defer { divergedBusy = false }
        do {
            let path = forcePush ? "/api/library/force-push" : "/api/library/force-sync"
            _ = try await client.callText(path, method: "POST")
            divergedMessage = nil
            await load()
        } catch is CancellationError {} catch {
            self.error = error.localizedDescription
            divergedMessage = nil
        }
    }

    static func normalizeSkillName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9-_]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func create() async {
        let name = Self.normalizeSkillName(newName)
        newName = ""
        guard !name.isEmpty else {
            self.error = "Enter a skill name such as lean-prover."
            return
        }
        if skills.contains(where: { $0.skillName.caseInsensitiveCompare(name) == .orderedSame }) {
            self.error = "\"\(name)\" already exists in the Library."
            return
        }
        let template = "---\nname: \(name)\ndescription: \"Describe when \(name) should be used.\"\nmetadata:\n  sandboxed:\n    audience: [mission, local]\n---\n\n# \(name)\n\n## When to use\n\n- \n\n## Instructions\n\n- \n"
        do {
            let latest = try await client.call("/api/library/skill").items.sorted { $0.skillName < $1.skillName }
            skills = latest
            if latest.contains(where: { $0.skillName.caseInsensitiveCompare(name) == .orderedSame }) {
                self.error = "\"\(name)\" already exists in the Library."
                return
            }
            _ = try await client.callText("/api/library/skill/\(OrbCore.escape(name))", method: "PUT", body: .object(["content": .string(template)]))
            try await OrbSkillEditor.commitAndPush("skill: create \(name)", client: client)
            await load()
        } catch is CancellationError {} catch {
            if Self.isDivergedError(error) {
                divergedMessage = "Skill saved on Core, but local and remote Library commits have diverged. Reset to remote or overwrite remote."
            } else {
                self.error = error.localizedDescription
            }
        }
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
    @State private var divergedMessage: String?
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
        .alert("Library history diverged", isPresented: Binding(get: { divergedMessage != nil }, set: { if !$0 { divergedMessage = nil } })) {
            Button("Reset to remote", role: .destructive) {
                Task {
                    do {
                        _ = try await client.callText("/api/library/force-sync", method: "POST")
                        divergedMessage = nil
                        await load()
                    } catch is CancellationError {} catch {
                        self.error = error.localizedDescription
                        divergedMessage = nil
                    }
                }
            }
            Button("Overwrite remote", role: .destructive) {
                Task {
                    do {
                        _ = try await client.callText("/api/library/force-push", method: "POST")
                        divergedMessage = nil
                        saved = true
                        editing = false
                        await load()
                    } catch is CancellationError {} catch {
                        self.error = error.localizedDescription
                        divergedMessage = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) { divergedMessage = nil }
        } message: { Text(divergedMessage ?? "Local and remote Library commits have diverged.") }
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
        async let skillReq = client.call("/api/library/skill/\(OrbCore.escape(name))")
        async let historyReq = client.call("/api/library/skill/\(OrbCore.escape(name))/history")
        do {
            let skill = try await skillReq
            content = skill["content"].text
            files = Array(Set(skill["references"].items.map(\.text) + skill["files"].items.map { $0["path"].text.isEmpty ? $0["name"].text : $0["path"].text }).filter { !$0.isEmpty && $0 != "SKILL.md" }).sorted()
            original = content; loaded = true; error = ""
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
        // Older cores have no history endpoint: the section then stays empty.
        history = (try? await historyReq.items) ?? []
    }
    private func save(_ text: String, message: String) async {
        saving = true; saved = false; defer { saving = false }
        do {
            _ = try await client.callText("/api/library/skill/\(OrbCore.escape(name))", method: "PUT", body: .object(["content": .string(text)]))
            try await Self.commitAndPush(message, client: client)
            content = text; original = text; error = ""; saved = true; editing = false
            history = (try? await client.call("/api/library/skill/\(OrbCore.escape(name))/history").items) ?? history
        } catch is CancellationError {} catch {
            if OrbSkillsSettings.isDivergedError(error) {
                divergedMessage = "Your edit was committed on Core, but pushing failed because local and remote Library history diverged."
            } else {
                self.error = "Couldn’t save to the repo: \(error.localizedDescription)"
            }
        }
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
    @State private var loading = true
    @State private var busy = false
    @State private var saveTask: Task<Void, Never>? = nil
    @State private var error = ""
    @State private var unavailable = ""
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
            if !unavailable.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Assistant not set up on this Core")
                            .font(.subheadline.weight(.semibold))
                        Text("\(unavailable). The Assistant runs on a Hermes gateway that Core proxies for the user named in HERMES_CLOUD_OWNER. Missions and local agents work without it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Check again") { Task { await load() } }
                        .disabled(loading)
                }
            } else if loading && state == .null {
                Section { HStack(spacing: 8) { OrbRunningDots(size: 10); Text("Loading Hermes settings…").foregroundStyle(.secondary) } }
            } else if state != .null {
                runtimeSection
                modelSection
                memorySection
                channelSection
                actionsSection
            } else if !error.isEmpty {
                Section { Button("Retry") { Task { await load() } } }
            }
        }
        .scrollContentBackground(.hidden).background(OrbStyle.background)
        .navigationTitle("Assistant").navigationBarTitleDisplayMode(.inline)
        .task(id: OrbCore.shared.connectionGeneration) {
            saveTask?.cancel()
            saveTask = nil
            busy = false
            client = OrbSettingsClient()
            state = .null
            draft = Draft()
            notice = ""
            await load()
        }
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
            if draft.memory { Stepper("Limit \(Int(draft.memoryLimit)) chars", value: $draft.memoryLimit, in: 1000...200_000, step: 1000) }
            Toggle("User profile memory (USER.md)", isOn: $draft.userProfile)
            if draft.userProfile { Stepper("Limit \(Int(draft.userLimit)) chars", value: $draft.userLimit, in: 1000...200_000, step: 1000) }
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
        Section("Channels & persona") {
            Picker("Telegram tool progress", selection: $draft.telegramProgress) {
                Text("Off").tag("off"); Text("New message").tag("new"); Text("Edit in place").tag("edit"); Text("All updates").tag("all")
            }
            Toggle("Clean up Telegram progress messages", isOn: $draft.telegramCleanup)
            NavigationLink {
                OrbSoulEditorView(soul: $draft.soul)
            } label: {
                LabeledContent("Persona (SOUL.md)") {
                    Text(draft.soul.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Empty" : "\(draft.soul.count) chars")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .accessibilityIdentifier("hermes.soul")
        }
    }

    private var actionsSection: some View {
        Section {
            Button(busy ? "Saving…" : "Save") { startSave(restart: false) }.disabled(busy || draft == Draft(state))
            Button("Save & restart Hermes") { startSave(restart: true) }.disabled(busy)
        }
    }

    private func startSave(restart: Bool) {
        saveTask?.cancel()
        saveTask = Task { await save(restart: restart) }
    }

    private func load() async {
        let activeClient = client
        loading = true
        error = ""
        unavailable = ""
        defer { if activeClient.current { loading = false } }
        do {
            let loaded = try await activeClient.call("/api/cloud/hermes/settings")
            guard activeClient.current else { return }
            state = loaded
            draft = Draft(loaded)
            error = ""
            unavailable = ""
        } catch is CancellationError {}
        catch {
            guard activeClient.current else { return }
            state = .null
            draft = Draft()
            if let reason = OrbTurnSummary.hermesUnavailableMessage(for: error) {
                unavailable = reason
                self.error = ""
            } else {
                self.error = error.localizedDescription
            }
        }
    }
    private func save(restart: Bool) async {
        let activeClient = client
        let wireBody = draft.wire(restart: restart)
        busy = true
        notice = ""
        defer { if activeClient.current { busy = false; saveTask = nil } }
        do {
            let updated = try await activeClient.call("/api/cloud/hermes/settings", method: "PUT", body: wireBody)
            guard activeClient.current else { return }
            state = updated
            draft = Draft(updated); error = ""; unavailable = ""
            notice = restart ? "Saved configuration and restarted Hermes service." : "Saved Hermes configuration."
        } catch is CancellationError {}
        catch {
            guard activeClient.current else { return }
            if let reason = OrbTurnSummary.hermesUnavailableMessage(for: error) {
                state = .null
                draft = Draft()
                unavailable = reason
                self.error = ""
            } else {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct OrbSoulEditorView: View {
    @Binding var soul: String
    var body: some View {
        TextEditor(text: $soul)
            .font(.system(.footnote, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(12)
            .background(OrbStyle.background)
            .navigationTitle("Persona (SOUL.md)")
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - AirVPN settings & account routes (Orb: AirVpnSettings.tsx, airVpnModel.ts)

enum OrbAirVpnModel {
    struct TunnelSummary: Equatable, Sendable {
        let device: String
        let country: String
        let server: String
        let exits: [String]
        let accounts: Int
    }

    struct ProfileView: Equatable, Sendable, Identifiable {
        var id: String { device }
        let device: String
        let country: String
        let server: String
        let active: Bool
        let exits: [String]
        let accounts: Int
    }

    struct StatusView: Equatable, Sendable {
        let apiKeyConfigured: Bool
        let sessionLimit: Int
        let profiles: [ProfileView]
        let activeTunnels: [TunnelSummary]
    }

    struct FilenameHint: Equatable, Sendable {
        let country: String
        let server: String
        let device: String
    }

    private static func asInt(_ val: OrbJSON, fallback: Int) -> Int {
        if let d = val.doubleValue, d.isFinite { return max(0, Int(d)) }
        if case .string(let s) = val, !s.isEmpty, s.allSatisfy(\.isNumber), let n = Int(s) { return max(0, n) }
        return fallback
    }

    static func parseStatus(_ payload: OrbJSON) -> StatusView? {
        guard case .object = payload,
              case .bool(let configured) = payload["api_key_configured"],
              case .array(let rawDevices) = payload["devices"] else {
            return nil
        }
        var devices = rawDevices.compactMap { item -> String? in
            let s = item.text
            return s.isEmpty ? nil : s
        }
        let sessionLimit = max(1, asInt(payload["session_limit"], fallback: 5))

        var activeTunnels: [TunnelSummary] = []
        if case .array(let rawTunnels) = payload["active_tunnels"] {
            for t in rawTunnels {
                let dev = t["device"].text
                guard !dev.isEmpty else { continue }
                let exits = t["exits"].items.map(\.text).filter { !$0.isEmpty }
                activeTunnels.append(TunnelSummary(
                    device: dev,
                    country: t["country"].text,
                    server: t["server"].text,
                    exits: exits,
                    accounts: asInt(t["accounts"], fallback: 0)
                ))
            }
        }
        var tunnelByDevice: [String: TunnelSummary] = [:]
        for t in activeTunnels { tunnelByDevice[t.device] = t }

        var metaByDevice: [String: (country: String, server: String)] = [:]
        if case .array(let rawProfiles) = payload["profiles"] {
            for p in rawProfiles {
                let dev = p["device"].text
                guard !dev.isEmpty else { continue }
                metaByDevice[dev] = (p["country"].text, p["server"].text)
                if !devices.contains(dev) { devices.append(dev) }
            }
        }

        let profiles = devices.map { dev -> ProfileView in
            let meta = metaByDevice[dev]
            let live = tunnelByDevice[dev]
            let country = !(meta?.country.isEmpty ?? true) ? meta!.country : (live?.country ?? "")
            let server = !(meta?.server.isEmpty ?? true) ? meta!.server : (live?.server ?? "")
            return ProfileView(
                device: dev,
                country: country,
                server: server,
                active: live != nil,
                exits: live?.exits ?? [],
                accounts: live?.accounts ?? 0
            )
        }
        return StatusView(
            apiKeyConfigured: configured,
            sessionLimit: sessionLimit,
            profiles: profiles,
            activeTunnels: activeTunnels
        )
    }

    private static func slugify(_ raw: String) -> String {
        var out = ""
        var prevDash = false
        for ch in raw.lowercased() {
            if (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") {
                out.append(ch)
                prevDash = false
            } else if !prevDash && !out.isEmpty {
                out.append("-")
                prevDash = true
            }
        }
        while out.last == "-" { out.removeLast() }
        return String(out.prefix(64))
    }

    static func parseFilenameHint(_ filename: String) -> FilenameHint {
        let leaf = filename.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? filename
        let base: String
        if leaf.lowercased().hasSuffix(".conf") {
            base = String(leaf.dropLast(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            base = leaf.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !base.isEmpty else { return FilenameHint(country: "", server: "", device: "") }

        if let re = try? NSRegularExpression(
            pattern: "^AirVPN_([A-Za-z]{2})(?:-[A-Za-z0-9-]+)?_([A-Za-z0-9-]+?)(?:_(?:UDP|TCP|Entry|TLS|IPv4|IPv6).*)?$",
            options: [.caseInsensitive]
        ), let match = re.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)),
           let ccRange = Range(match.range(at: 1), in: base),
           let srvRange = Range(match.range(at: 2), in: base) {
            let cc = base[ccRange].uppercased()
            let srv = String(base[srvRange])
            return FilenameHint(country: cc, server: srv, device: slugify("orb-\(cc)-\(srv)"))
        }

        if base.count <= 56, base.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) {
            return FilenameHint(country: "", server: base, device: slugify("orb-\(base)"))
        }
        return FilenameHint(country: "", server: "", device: "")
    }

    static func sessionSummary(activeSessions: Int?, orbTunnels: Int, sessionLimit: Int = 5) -> String {
        let limit = sessionLimit > 0 ? sessionLimit : 5
        let orb = max(0, orbTunnels)
        guard let rawActive = activeSessions else {
            if orb == 0 { return "Up to \(limit) concurrent sessions across AirVPN" }
            return "\(orb) Orb tunnel\(orb == 1 ? "" : "s") active · up to \(limit) concurrent sessions"
        }
        let active = max(0, rawActive)
        let external = max(0, active - orb)
        let free = max(0, limit - active)
        return "\(active) / \(limit) active sessions · \(orb) Orb tunnel\(orb == 1 ? "" : "s") · \(external) external · \(free) free"
    }
}

struct OrbAirVpnSettings: View {
    @State private var client = OrbSettingsClient()
    @State private var status: OrbAirVpnModel.StatusView?
    @State private var providers: [OrbJSON] = []
    @State private var activeSessions: Int?
    @State private var error = ""
    @State private var notice = ""
    @State private var busy = false

    @State private var editingKey = false
    @State private var keyDraft = ""

    @State private var importingProfile = false
    @State private var replacingDevice: String?
    @State private var deviceDraft = ""
    @State private var countryDraft = ""
    @State private var serverDraft = ""
    @State private var profileDraft = ""
    @State private var pickingFile = false

    @State private var deletingDevice: String?
    @State private var routesRevision = 0

    private var isAdmin: Bool { OrbCore.shared.isAdminUser }

    var body: some View {
        List {
            OrbSettingsError(message: error)
            if !notice.isEmpty {
                Section { Text(notice).font(.footnote) }
            }
            if isAdmin {
                subscriptionSection
                profilesSection
            }
            accountRoutesSection
        }
        .scrollContentBackground(.hidden).background(OrbStyle.background)
        .navigationTitle("AirVPN").navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await load()
            routesRevision += 1
        }
        .task { await load() }
        .alert("AirVPN API key", isPresented: $editingKey) {
            SecureField("AirVPN API key", text: $keyDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save key") { Task { await saveKey() } }
                .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { keyDraft = "" }
        } message: {
            Text("Generate a key in AirVPN’s Client Area → API. Core encrypts it at rest.")
        }
        .sheet(isPresented: $importingProfile) {
            importProfileSheet
        }
        .alert("Remove \(deletingDevice ?? "")?", isPresented: Binding(get: { deletingDevice != nil }, set: { if !$0 { deletingDevice = nil } })) {
            Button("Remove profile", role: .destructive) {
                if let dev = deletingDevice { Task { await removeProfile(dev) } }
            }
            Button("Cancel", role: .cancel) { deletingDevice = nil }
        } message: {
            Text("Any active Orb tunnel using this WireGuard device profile will be drained and disconnected.")
        }
    }

    private var subscriptionSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("API key")
                    Text(status?.apiKeyConfigured == true ? "Configured · Stored encrypted on Core" : "Not configured")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(status?.apiKeyConfigured == true ? "Update" : "Set key") {
                    keyDraft = ""
                    editingKey = true
                }
                .disabled(busy)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Session budget").font(.subheadline)
                Text(OrbAirVpnModel.sessionSummary(
                    activeSessions: activeSessions,
                    orbTunnels: status?.activeTunnels.count ?? 0,
                    sessionLimit: status?.sessionLimit ?? 5
                ))
                .font(.caption).foregroundStyle(.secondary)
                if status?.apiKeyConfigured == true {
                    Button("Check active sessions") { Task { await checkSessions() } }
                        .disabled(busy)
                }
            }
        } header: {
            Text("Subscription & sessions")
        } footer: {
            Text("AirVPN allows up to 5 concurrent WireGuard sessions across Orb and external devices.")
        }
    }

    private var profilesSection: some View {
        Section {
            if let profiles = status?.profiles, !profiles.isEmpty {
                ForEach(profiles) { prof in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(prof.country.isEmpty ? prof.device : "\(prof.country) · \(prof.server.isEmpty ? prof.device : prof.server)")
                            .font(.subheadline.weight(.medium))
                        Text(profileSubtitle(prof))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Remove", role: .destructive) { deletingDevice = prof.device }
                        Button("Replace") { openImportSheet(prof) }.tint(.blue)
                    }
                }
            } else {
                Text("No WireGuard profiles imported.").foregroundStyle(.secondary)
            }
            Button("Import WireGuard profile…") { openImportSheet(nil) }
                .disabled(busy)
        } header: {
            Text("WireGuard profiles (\(status?.profiles.count ?? 0))")
        } footer: {
            Text("Different provider categories share one tunnel per country. Import extra profiles in the same country only when multiple accounts of the same provider need distinct public exits.")
        }
    }

    private var accountRoutesSection: some View {
        Section {
            if providers.isEmpty {
                Text("No connected provider accounts.").foregroundStyle(.secondary)
            } else {
                ForEach(providers, id: \.selfID) { account in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(account["name"].text.isEmpty ? account.selfID : account["name"].text)
                            .font(.subheadline.weight(.medium))
                        OrbAccountVpnSettings(
                            client: client,
                            account: account.selfID,
                            nativeAccount: account["provider_type"].text == "antigravity"
                        )
                        .id("\(account.selfID)-\(routesRevision)")
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Account routes")
        }
    }

    private var importProfileSheet: some View {
        NavigationStack {
            Form {
                Section("WireGuard .conf file") {
                    Button("Choose .conf file from Files…") { pickingFile = true }
                    TextEditor(text: $profileDraft)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 120)
                }
                Section("Server metadata") {
                    TextField("Country code (e.g. CH, NL, FR)", text: $countryDraft)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("AirVPN server name (e.g. Kitalpha)", text: $serverDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Device name (e.g. orb-ch)", text: $deviceDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(replacingDevice != nil)
                }
            }
            .navigationTitle(replacingDevice.map { "Replace \($0)" } ?? "Import profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { profileDraft = ""; importingProfile = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { Task { await saveProfile() } }
                        .disabled(busy || profileDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.data, .plainText]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url), data.count <= 30_000,
                   let text = String(data: data, encoding: .utf8) {
                    let hint = OrbAirVpnModel.parseFilenameHint(url.lastPathComponent)
                    if countryDraft.trimmingCharacters(in: .whitespaces).isEmpty && !hint.country.isEmpty {
                        countryDraft = hint.country
                    }
                    if serverDraft.trimmingCharacters(in: .whitespaces).isEmpty && !hint.server.isEmpty {
                        serverDraft = hint.server
                    }
                    if replacingDevice == nil && deviceDraft.trimmingCharacters(in: .whitespaces).isEmpty && !hint.device.isEmpty {
                        deviceDraft = hint.device
                    }
                    profileDraft = text
                }
            }
        }
    }

    private func profileSubtitle(_ prof: OrbAirVpnModel.ProfileView) -> String {
        if prof.active {
            let ipText = prof.exits.isEmpty ? "" : " · \(prof.exits.joined(separator: ", "))"
            return "\(prof.device) · Active\(ipText) · \(prof.accounts) account\(prof.accounts == 1 ? "" : "s")"
        }
        return "\(prof.device) · Idle"
    }

    private func openImportSheet(_ existing: OrbAirVpnModel.ProfileView?) {
        replacingDevice = existing?.device
        deviceDraft = existing?.device ?? ""
        countryDraft = existing?.country ?? ""
        serverDraft = existing?.server ?? ""
        profileDraft = ""
        importingProfile = true
    }

    private func load() async {
        do {
            if isAdmin {
                let raw = try await client.call("/api/settings/airvpn")
                status = OrbAirVpnModel.parseStatus(raw)
            }
            let list = try await client.call("/api/ai/providers")
            let rows = list.items.isEmpty ? list["providers"].items : list.items
            providers = rows.filter {
                if case .bool(false) = $0["has_credentials"] { return false }
                return !$0.selfID.isEmpty
            }
            error = ""
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func saveKey() async {
        let clean = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await client.call("/api/settings/airvpn", method: "PUT", body: .object(["api_key": .string(clean)]))
            keyDraft = ""
            editingKey = false
            notice = "API key saved."
            await load()
            routesRevision += 1
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func checkSessions() async {
        busy = true; defer { busy = false }
        do {
            let res = try await client.call("/api/settings/airvpn", method: "POST")
            let count = Int(res["active_sessions"].doubleValue ?? Double(res["active_sessions"].text) ?? 0)
            activeSessions = count
            notice = "AirVPN reports \(count) active session\(count == 1 ? "" : "s")."
            await load()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func saveProfile() async {
        let dev = deviceDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cc = countryDraft.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let srv = serverDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let conf = profileDraft
        guard !dev.isEmpty, cc.count == 2, !srv.isEmpty, !conf.isEmpty else {
            error = "Fill in country code, AirVPN server name, device name, and WireGuard profile."
            return
        }
        busy = true; defer { busy = false }
        do {
            _ = try await client.call("/api/settings/airvpn", method: "PUT", body: .object([
                "device_id": .string(dev),
                "country": .string(cc),
                "server": .string(srv),
                "profile": .string(conf),
            ]))
            profileDraft = ""
            importingProfile = false
            notice = "Device profile saved."
            await load()
            routesRevision += 1
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func removeProfile(_ dev: String) async {
        busy = true; defer { busy = false }
        do {
            _ = try await client.call("/api/settings/airvpn", method: "DELETE", body: .object(["device_id": .string(dev)]))
            deletingDevice = nil
            notice = "Removed profile \(dev)."
            await load()
            routesRevision += 1
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
