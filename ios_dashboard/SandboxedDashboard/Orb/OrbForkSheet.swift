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

struct OrbCyberSection: View {
    let model: String
    let remote: Bool
    let goal: Bool
    var missionID: String?
    @Binding var mode: String
    @State private var routes: [String: Bool] = [:]
    @State private var routeLoading = false
    @State private var routeFailed = false
    @State private var state: OrbJSON = .null
    @State private var saving = false
    @State private var unavailable = false
    @State private var error = ""

    var body: some View {
        Section {
            if unavailable {
                LabeledContent("Cyber", value: "Unavailable")
            } else {
                Picker("Cyber", selection: Binding(
                    get: { mode },
                    set: { next in
                        guard next != mode else { return }
                        if let missionID { Task { await save(missionID, next: next) } }
                        else { mode = next }
                    }
                )) {
                    ForEach(OrbCyberAccess.modes, id: \.self) { id in
                        Text(OrbCyberAccess.label(id)).tag(id).disabled(saving || disabled(id))
                    }
                }
                .disabled(saving)
                .accessibilityIdentifier("picker.codex-cyber")
            }
        } footer: {
            Text(footer)
        }
        .task(id: "\(missionID ?? "")|\(model)|\(remote)") { await load() }
    }

    private func compatibility(_ id: String) -> String? {
        remote && model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : OrbCyberAccess.compatibility(mode: id, model: model)
    }
    private func goalReason(_ id: String) -> String? {
        goal && id != "automatic" ? "Native goals cannot confirm an explicit Cyber program. Choose Automatic explicitly." : nil
    }
    private func routeReason(_ id: String) -> String? {
        guard remote, id != "automatic" else { return nil }
        if routeFailed { return "Could not check the Cyber route. Reopen settings to retry." }
        if routeLoading { return "Checking the selected Cyber route…" }
        if routes[id] != true { return "This remote route cannot guarantee the selected Cyber program. Choose Automatic explicitly or a direct OpenAI route." }
        return nil
    }
    private func disabled(_ id: String) -> Bool {
        compatibility(id) != nil || goalReason(id) != nil || routeReason(id) != nil
    }
    private var footer: String {
        if !error.isEmpty { return error }
        if unavailable { return "The connected backend does not expose cyber settings, or the request failed. Update or reconnect before changing this option." }
        if let reason = goalReason(mode) ?? routeReason(mode) ?? compatibility(mode) { return reason }
        let detail = mode == "standard" ? "Standard safeguards" : (mode == "daybreak" ? "Requires approved account access" : "Use the account’s default access")
        guard missionID != nil else { return detail }
        let status = OrbCyberAccess.confirmed(state) ? "Confirmed (\(state["confirmed_program"].text))" : "Requested"
        return "\(status) · Applies to the next turn."
    }
    private func load() async {
        error = ""
        if let missionID {
            do {
                try await OrbCyberAccess.require(model: "", mode: "automatic", remote: false, goal: false)
                let fetched = try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(missionID))/cyber")
                guard OrbCyberAccess.modes.contains(fetched["mode"].text) else { unavailable = true; return }
                state = fetched
                mode = fetched["mode"].text
                unavailable = false
            } catch is CancellationError { return }
            catch { unavailable = true; return }
        } else {
            unavailable = false
        }
        guard remote else { routes = [:]; routeLoading = false; routeFailed = false; return }
        routeLoading = true; routeFailed = false
        defer { routeLoading = false }
        do {
            async let standard = OrbCore.shared.call(OrbCyberAccess.capabilityPath(model: model, mode: "standard", remote: true))
            async let daybreak = OrbCore.shared.call(OrbCyberAccess.capabilityPath(model: model, mode: "daybreak", remote: true))
            let (s, d) = try await (standard, daybreak)
            routes = ["standard": s["route_supported"] == .bool(true), "daybreak": d["route_supported"] == .bool(true)]
        } catch is CancellationError {}
        catch { routeFailed = true; routes = [:] }
    }
    private func save(_ missionID: String, next: String) async {
        saving = true; defer { saving = false }
        do {
            try await OrbCyberAccess.require(model: model, mode: next, remote: remote, goal: goal)
            let saved = try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(missionID))/cyber", method: "PATCH", body: .object(["mode": .string(next)]))
            guard OrbCyberAccess.modes.contains(saved["mode"].text) else {
                throw OrbHTTPError(status: 400, detail: "The backend did not return a Cyber selection. Reopen settings to verify it.")
            }
            state = saved
            mode = saved["mode"].text
            error = ""
        } catch { self.error = OrbCyberAccess.error(error) }
    }
}

/// Fork a conversation into another harness/model (same workspace), as in Orb's
/// "Fork conversation" menu.
struct OrbForkSheet: View {
    let mission: OrbJSON
    var transfer = false
    let onForked: (OrbJSON) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var backends: [OrbJSON] = []
    @State private var nodes: [OrbJSON] = []
    @State private var modelsMap: OrbJSON = .null
    @State private var backend = ""
    @State private var targetNode = "core"
    @State private var model = ""
    @State private var effort = ""
    @State private var speed = "standard"
    @State private var busy = false
    @State private var error = ""
    @State private var key = UUID().uuidString
    @State private var created: OrbJSON?
    @State private var submitted: OrbJSON?
    static let effortsByHarness: [String: [String]] = [
        "antigravity": ["low", "medium", "high"],
        "codex": ["low", "medium", "high", "xhigh", "max"],
        "claudecode": ["low", "medium", "high", "xhigh", "max"],
    ]
    private static let remoteCapable: Set<String> = ["codex", "grok", "claudecode", "opencode", "antigravity", "vibe"]

    private var isCloudSource: Bool {
        mission["backend"].text.hasPrefix("cloud_") || !mission["cloud"]["provider"].text.isEmpty
    }
    private var isRemoteTarget: Bool {
        isCloudSource ? (!targetNode.isEmpty && targetNode != "core") : !mission["remote_node_id"].text.isEmpty
    }
    private var models: [OrbJSON] { modelsMap[backend].items.filter { !modelValue($0).isEmpty } }
    private var efforts: [String] { Self.effortsByHarness[backend] ?? [] }
    private func modelValue(_ m: OrbJSON) -> String { m["value"].text.isEmpty ? m["id"].text : m["value"].text }
    private func modelLabel(_ m: OrbJSON) -> String {
        for key in ["label", "displayName", "name"] where !m[key].text.isEmpty { return m[key].text }
        return modelValue(m)
    }
    private func unavailable(_ id: String) -> Bool { isRemoteTarget && !Self.remoteCapable.contains(id) }

    var body: some View {
        NavigationStack {
            Form {
                if !error.isEmpty { OrbNotice(message: error) }
                harnessSection.disabled(busy || submitted != nil)
                if backend == "codex" && !model.isEmpty { OrbCodexSpeedSection(model: model, tier: $speed).disabled(busy || submitted != nil) }
                Section {
                    Button { Task { await fork() } } label: {
                        HStack {
                            Text(busy ? (transfer ? "Transferring…" : isCloudSource ? "Handing off…" : "Forking…") : (created != nil ? "Retry archiving" : isCloudSource ? "Continue in workspace" : transfer ? "Transfer conversation" : "Fork conversation"))
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || backend.isEmpty || model.isEmpty || unavailable(backend))
                    .accessibilityIdentifier("fork.submit")
                    if let created {
                        Button("Open transferred conversation") { dismiss(); onForked(created) }.disabled(busy)
                    }
                } footer: {
                    Text(isCloudSource ? "Starts a workspace agent with this cloud conversation's history on the selected machine." : transfer ? "Stops the current agent, continues with the selected agent and conversation history, then archives the original." : "Starts a new conversation with this one's history in the same workspace. The original is not changed.")
                }
            }
            .navigationTitle(isCloudSource ? "Continue in workspace" : transfer ? "Transfer to another agent" : "Fork conversation").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.disabled(busy) } }
            .task { await load() }
            .onChange(of: backend) { old, new in
                if old != new && !old.isEmpty { speed = "standard"; effort = ""; model = models.first.map(modelValue) ?? "" }
            }
        }
        .interactiveDismissDisabled(busy)
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private var harnessSection: some View {
        Section {
            if isCloudSource {
                Picker("Machine", selection: $targetNode) {
                    Text("Core").tag("core")
                    ForEach(nodes.indices, id: \.self) { idx in
                        let n = nodes[idx]
                        Text(n["name"].text.isEmpty ? n["id"].text : n["name"].text).tag(n["id"].text)
                    }
                }
            }
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
            let rawBackends = response.items.isEmpty ? response["backends"].items : response.items
            backends = rawBackends.filter { $0.selfID != "gemini" }
            nodes = OrbSelection.sortedComputeNodes(catalog["nodes"]["nodes"].items)
            modelsMap = catalog["models"]["backends"]
            if backend.isEmpty {
                let rawBackend = mission["backend"].text
                backend = (rawBackend.isEmpty || isCloudSource) ? (backends.first?.selfID ?? "") : rawBackend
                let current = mission["model_override"].text
                model = models.contains { modelValue($0) == current } ? current : (models.first.map(modelValue) ?? "")
                effort = isCloudSource ? "" : mission["model_effort"].text
                if backend == "codex" && !isCloudSource { speed = OrbCodexSpeed.of(mission) }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func fork() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            if submitted == nil && backend == "codex" {
                let cyber = try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(mission["id"].text))/cyber")
                guard OrbCyberAccess.modes.contains(cyber["mode"].text) else {
                    throw OrbHTTPError(status: 400, detail: "The backend did not return a Cyber selection. Your draft is kept.")
                }
                try await OrbCyberAccess.require(model: model, mode: cyber["mode"].text, remote: OrbContinuation.remoteNodeID(for: mission) != "core", goal: false)
                try await OrbCodexSpeed.require(model: model, tier: speed)
            }
            var body: [String: OrbJSON] = ["backend": .string(backend), "model_override": .string(model), "model_effort": .string(effort), "idempotency_key": .string(key)]
            if backend == "codex" { body["service_tier"] = .string(speed) }
            if isCloudSource && !targetNode.isEmpty && targetNode != "core" {
                body["remote_node_id"] = .string(targetNode)
            }
            let base = "/api/control/missions/\(OrbCore.escape(mission["id"].text))"
            let forked: OrbJSON
            if let created { forked = created }
            else {
                if transfer && !isCloudSource { try await stopSource(base) }
                if submitted == nil { submitted = .object(body) }
                forked = try await OrbCore.shared.call(base + "/fork", method: "POST", body: submitted!)
                created = forked
            }
            if transfer && !isCloudSource {
                _ = try await OrbCore.shared.call(base + "/status", method: "POST", body: .object(["status": .string("acknowledged")]))
            }
            OrbHaptics.success()
            OrbUsageTelemetry.shared.trackAction(.fork, surface: "fork_sheet")
            dismiss()
            onForked(forked)
        } catch let e as OrbHTTPError where [404, 405].contains(e.status) {
            error = created != nil ? "The new agent is ready, but the original could not be archived." : transfer ? "Transfer is unavailable on this server. The original conversation is retained; it may have been stopped." : "This backend needs the conversation-fork update. The original mission has not been changed."
        } catch {
            let msg = OrbCyberAccess.error(error)
            self.error = created == nil ? msg : "The new agent is ready, but the original could not be archived. " + msg
        }
    }

    private func stopSource(_ base: String) async throws {
        let api = OrbCore.shared
        let source = try await api.call(base)
        if Self.sourceStopped(source) { return }
        let cancelPath = source["backend"].text.hasPrefix("cloud_") ? "/cloud/cancel" : "/cancel"
        _ = try await api.call(base + cancelPath, method: "POST")
        for _ in 0..<20 {
            if Self.sourceStopped(try await api.call(base)) { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw OrbHTTPError(status: 409, detail: "The original agent has not stopped yet. Wait and retry the transfer.")
    }

    static func sourceStopped(_ mission: OrbJSON) -> Bool {
        ["awaiting_user", "blocked", "paused", "interrupted", "failed", "completed", "cancelled", "acknowledged"].contains(mission["status"].text)
            && mission["execution"]["state"].text != "running"
            && !["queued", "running"].contains(mission["remote_job"]["node_state"].text)
    }
}

private extension OrbJSON {
    var modelKey: String { self["value"].text.isEmpty ? self["id"].text : self["value"].text }
}
