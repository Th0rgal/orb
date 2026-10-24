import SwiftUI

/// Codex service tiers, as Orb's CodexSpeedPicker offers them.
@MainActor
enum OrbCodexSpeed {
    static let tiers = ["standard", "fast", "ultrafast"]
    static func label(_ tier: String) -> String { tier == "ultrafast" ? "Ultrafast" : tier == "fast" ? "Fast" : "Standard" }
    static func detail(_ tier: String) -> String {
        tier == "standard" ? "Normal subscription usage" : tier == "fast" ? "Compatible subscriptions · higher usage" : "Eligible subscriptions · 8× included usage"
    }
    static func of(_ mission: OrbJSON) -> String {
        let tier = mission["service_tier"].text
        return tier.isEmpty ? (mission["fast_mode"].flag ? "fast" : "standard") : tier
    }
    static func options(model: String, missionID: String? = nil) async throws -> [OrbJSON] {
        var path = "/api/control/codex-speed?model=\(OrbCore.escape(model))"
        if let missionID { path += "&mission_id=\(OrbCore.escape(missionID))" }
        return try await OrbCore.shared.call(path)["tiers"].items
    }
    /// Rejects a tier the connected subscriptions cannot serve before anything is sent.
    static func require(model: String, tier: String, missionID: String? = nil) async throws {
        guard tier != "standard" else { return }
        let option = try await options(model: model, missionID: missionID).first { $0["id"].text == tier }
        guard option?["available"].flag == true else {
            let reason = option?["reason"].text ?? ""
            throw OrbHTTPError(status: 400, detail: reason.isEmpty ? "This speed is not available on the connected subscriptions." : reason)
        }
    }
}

/// Form section choosing a Codex speed; unavailable tiers are disabled with their reason.
struct OrbCodexSpeedSection: View {
    let model: String
    var missionID: String?
    @Binding var tier: String
    @State private var options: [OrbJSON] = []
    @State private var error = ""

    var body: some View {
        Section {
            Picker("Speed", selection: $tier) {
                ForEach(OrbCodexSpeed.tiers, id: \.self) { id in
                    Text(OrbCodexSpeed.label(id)).tag(id).disabled(id != "standard" && !available(id))
                }
            }
            .accessibilityIdentifier("picker.codex-speed")
        } footer: {
            Text(error.isEmpty ? footer : error)
        }
        .task(id: model) { await load() }
    }

    private var footer: String {
        let reason = options.first { $0["id"].text == tier }?["reason"].text ?? ""
        return reason.isEmpty ? OrbCodexSpeed.detail(tier) : reason
    }
    private func available(_ id: String) -> Bool { options.first { $0["id"].text == id }?["available"].flag ?? false }
    private func load() async {
        guard !model.isEmpty else { options = []; return }
        do { options = try await OrbCodexSpeed.options(model: model, missionID: missionID); error = "" }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }
}

/// Fork a conversation into another harness/model (same workspace), as in Orb's
/// "Fork conversation" menu.
struct OrbForkSheet: View {
    let mission: OrbJSON
    let onForked: (OrbJSON) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var backends: [OrbJSON] = []
    @State private var modelsMap: OrbJSON = .null
    @State private var backend = ""
    @State private var model = ""
    @State private var effort = ""
    @State private var speed = "standard"
    @State private var busy = false
    @State private var error = ""
    @State private var key = UUID().uuidString
    static let effortsByHarness: [String: [String]] = [
        "antigravity": ["low", "medium", "high"],
        "codex": ["low", "medium", "high", "xhigh", "max"],
        "claudecode": ["low", "medium", "high", "xhigh", "max"],
    ]
    private static let remoteCapable: Set<String> = ["codex", "grok", "claudecode", "opencode", "antigravity", "vibe"]

    private var models: [OrbJSON] { modelsMap[backend].items.filter { !modelValue($0).isEmpty } }
    private var efforts: [String] { Self.effortsByHarness[backend] ?? [] }
    private func modelValue(_ m: OrbJSON) -> String { m["value"].text.isEmpty ? m["id"].text : m["value"].text }
    private func modelLabel(_ m: OrbJSON) -> String {
        for key in ["label", "displayName", "name"] where !m[key].text.isEmpty { return m[key].text }
        return modelValue(m)
    }
    private func unavailable(_ id: String) -> Bool { !mission["remote_node_id"].text.isEmpty && !Self.remoteCapable.contains(id) }

    var body: some View {
        NavigationStack {
            Form {
                if !error.isEmpty { OrbNotice(message: error) }
                harnessSection
                if backend == "codex" && !model.isEmpty { OrbCodexSpeedSection(model: model, tier: $speed) }
                Section {
                    Button { Task { await fork() } } label: {
                        HStack { Text(busy ? "Forking…" : "Fork conversation"); if busy { Spacer(); ProgressView() } }
                    }
                    .disabled(busy || backend.isEmpty || model.isEmpty || unavailable(backend))
                    .accessibilityIdentifier("fork.submit")
                } footer: {
                    Text("Starts a new conversation with this one's history in the same workspace. The original is not changed.")
                }
            }
            .navigationTitle("Fork conversation").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
            .task { await load() }
            .onChange(of: backend) { old, new in
                if old != new && !old.isEmpty { speed = "standard"; effort = ""; model = models.first.map(modelValue) ?? "" }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private var harnessSection: some View {
        Section {
            Picker("Harness", selection: $backend) {
                ForEach(backends, id: \.selfID) { b in
                    Text(b["name"].text.isEmpty ? b.selfID : b["name"].text).tag(b.selfID).disabled(unavailable(b.selfID))
                }
            }
            Picker("Model", selection: $model) {
                if models.isEmpty { Text("No models available").tag("") }
                ForEach(models, id: \.modelKey) { m in Text(modelLabel(m)).tag(modelValue(m)) }
            }
            if !efforts.isEmpty {
                Picker("Effort", selection: $effort) {
                    Text("Default").tag("")
                    ForEach(efforts, id: \.self) { Text($0 == "xhigh" ? "XHigh" : $0.capitalized).tag($0) }
                }
            }
        }
    }

    private func load() async {
        do {
            let catalog = try await OrbReadCache.agentCatalog()
            let response = catalog["backends"]
            backends = response.items.isEmpty ? response["backends"].items : response.items
            modelsMap = catalog["models"]["backends"]
            if backend.isEmpty {
                backend = mission["backend"].text.isEmpty ? (backends.first?.selfID ?? "") : mission["backend"].text
                let current = mission["model_override"].text
                model = models.contains { modelValue($0) == current } ? current : (models.first.map(modelValue) ?? "")
                effort = mission["model_effort"].text
                if backend == "codex" { speed = OrbCodexSpeed.of(mission) }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func fork() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            if backend == "codex" { try await OrbCodexSpeed.require(model: model, tier: speed) }
            var body: [String: OrbJSON] = ["backend": .string(backend), "model_override": .string(model), "model_effort": .string(effort), "idempotency_key": .string(key)]
            if backend == "codex" { body["service_tier"] = .string(speed) }
            let forked = try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(mission["id"].text))/fork", method: "POST", body: .object(body))
            OrbHaptics.success()
            dismiss()
            onForked(forked)
        } catch let e as OrbHTTPError where [404, 405].contains(e.status) {
            error = "This backend needs the conversation-fork update. The original mission has not been changed."
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private extension OrbJSON {
    var modelKey: String { self["value"].text.isEmpty ? self["id"].text : self["value"].text }
}
