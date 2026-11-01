import SwiftUI
import UIKit

struct OrbSelection {
    var provider = "agent", account = "", backend = "", model = "", node = "", repository = "", gitRef = ""
    var serviceTier = "standard"
    var params: OrbJSON = .array([])
    var canCancel = false
    var cloud: Bool { provider != "agent" }
    var needsAgentSelection: Bool { cloud ? account.isEmpty : backend.isEmpty }
    var primaryIcon: String {
        if cloud { return "cloud" }
        switch backend {
        case "": return "cpu"
        case "claudecode": return "sparkles"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "opencode": return "terminal"
        case "antigravity": return "wand.and.stars"
        case "grok": return "bolt.fill"
        default: return "cpu"
        }
    }
    var primaryPillLabel: String {
        if cloud {
            let service = ["cursor_cloud": "Cursor", "grok_bot": "Grok", "hermes": "Hermes"][provider] ?? provider
            return model.isEmpty ? service : Self.shortModelName(model, harness: service)
        }
        if backend.isEmpty {
            return "Agent"
        }
        let harness = OrbStyle.serviceName(backend)
        if model.isEmpty {
            return harness
        }
        return Self.shortModelName(model, harness: harness)
    }
    var machinePillLabel: String? {
        guard !cloud, !node.isEmpty, node != "core" else { return nil }
        switch node {
        case "dgx-spark": return "spark"
        case "dgx-spark-admin": return "spark·admin"
        default:
            if let dash = node.lastIndex(of: "-") {
                let suffix = node[node.index(after: dash)...]
                let prefix = String(node[..<dash])
                if !prefix.isEmpty && suffix.count == 8 && suffix.allSatisfy({ $0.isHexDigit }) {
                    return prefix
                }
            }
            return node
        }
    }
    private static func shortModelName(_ raw: String, harness: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = s.lastIndex(of: "/"), slash < s.index(before: s.endIndex) {
            s = String(s[s.index(after: slash)...])
        }
        for prefix in ["anthropic.", "openai.", "google.", "xai."] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        // Strip trailing date stamps like -20250514
        if s.count > 10, let dash = s.lastIndex(of: "-") {
            let tail = s[s.index(after: dash)...]
            if tail.count == 8 && tail.allSatisfy(\.isNumber) {
                s = String(s[..<dash])
            }
        }
        if !harness.isEmpty, s.lowercased().hasPrefix(harness.lowercased() + " ") {
            let rest = String(s.dropFirst(harness.count + 1)).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return s
    }
    var label: String { [cloud ? ["cursor_cloud": "Cursor Cloud", "grok_bot": "Grok Bot", "hermes": "Hermes"][provider] ?? provider : backend.isEmpty ? "Select agent" : OrbStyle.serviceName(backend), model].filter { !$0.isEmpty }.joined(separator: " · ") }
    var compactLabel: String {
        if let machine = machinePillLabel {
            return "\(primaryPillLabel) · \(machine)"
        }
        return primaryPillLabel
    }
    var wire: OrbJSON {
        var value: [String: OrbJSON] = ["provider": .string(provider), "account": .string(account)]
        if !model.isEmpty { value["model"] = .string(model); if !params.items.isEmpty { value["model_params"] = params } }
        if !repository.isEmpty { value["repository"] = .string(repository) }
        if !gitRef.isEmpty { value["git_ref"] = .string(gitRef) }
        return .object(value)
    }
    mutating func restore(_ value: OrbJSON) { provider = value["provider"].text; account = value["account"].text; model = value["model"].text; params = value["model_params"] == .null ? .array([]) : value["model_params"]; repository = value["repository"].text; gitRef = value["git_ref"].text }
    func validate() throws {
        if cloud && account.isEmpty || !cloud && backend.isEmpty { throw OrbHTTPError(status: 400, detail: "Choose an available agent and account.") }
        if provider == "cursor_cloud" && (repository.isEmpty || gitRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { throw OrbHTTPError(status: 400, detail: "Choose a repository and Git reference for Cursor Cloud.") }
    }
    static let minAutoNodeMemBytes: Double = 8.0 * 1024.0 * 1024.0 * 1024.0
    static let minAutoNodeDiskBytes: Double = 20.0 * 1024.0 * 1024.0 * 1024.0

    static func isUsableComputeNode(_ node: OrbJSON) -> Bool {
        guard node["status"].text == "online", !node["cordoned"].flag else { return false }
        let labels = node["labels"].items.map(\.text)
        return !labels.contains("manual-only")
    }
    static func isAutoSchedulableNode(_ node: OrbJSON, backend: String? = nil) -> Bool {
        guard node["status"].text == "online", !node["cordoned"].flag, !node["disk_pressure_pinned"].flag else { return false }
        let labels = node["labels"].items.map(\.text)
        if labels.contains("manual-only") || labels.contains("managed") || labels.contains("small") { return false }
        if let mem = node["mem_available_bytes"].number, mem < minAutoNodeMemBytes { return false }
        if let disk = node["disk_available_bytes"].number, disk < minAutoNodeDiskBytes { return false }
        if let backend, !backend.isEmpty, node["quarantined_harnesses"].items.contains(where: { $0.text == backend }) { return false }
        return true
    }
    static func sortedComputeNodes(_ rawNodes: [OrbJSON]) -> [OrbJSON] {
        let hasSparkAdmin = rawNodes.contains { $0["id"].text == "dgx-spark-admin" && $0["status"].text == "online" }
        let filtered = hasSparkAdmin ? rawNodes.filter { $0["id"].text != "dgx-spark" } : rawNodes
        return filtered.sorted { a, b in
            let aUsable = isUsableComputeNode(a)
            let bUsable = isUsableComputeNode(b)
            if aUsable != bUsable { return aUsable && !bUsable }
            let aJobs = a["active_jobs"].number ?? 0
            let bJobs = b["active_jobs"].number ?? 0
            if aJobs != bJobs { return aJobs < bJobs }
            let aFree = a["mem_available_bytes"].number ?? -1
            let bFree = b["mem_available_bytes"].number ?? -1
            if aFree != bFree { return aFree > bFree }
            return a["id"].text < b["id"].text
        }
    }
    static func firstAvailableNodeID(_ rawNodes: [OrbJSON], backend: String? = nil) -> String? {
        let sorted = sortedComputeNodes(rawNodes)
        guard let first = sorted.first(where: { isAutoSchedulableNode($0, backend: backend) }) else { return nil }
        let id = first["id"].text
        return id.isEmpty ? nil : id
    }
}

struct OrbAgentPicker: View {
    @Binding var selection: OrbSelection
    let existing: Bool
    var onTransfer: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [OrbJSON] = []
    @State private var models: [OrbJSON] = []
    @State private var backends: [OrbJSON] = []
    @State private var nodes: [OrbJSON] = []
    @State private var repos: [OrbJSON] = []
    @State private var backendModelsMap: OrbJSON = .null
    @State private var loadingOptions = false
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Form {
                if !error.isEmpty { OrbNotice(message: error) }
                if !existing {
                    Picker("Service", selection: $selection.provider) {
                        Text("Agent").tag("agent"); Text("Hermes").tag("hermes"); Text("Cursor Cloud").tag("cursor_cloud"); Text("Grok Bot").tag("grok_bot")
                    }.accessibilityIdentifier("picker.service")
                }
                if selection.cloud {
                    Picker("Account", selection: $selection.account) {
                        Text("Choose account").tag("")
                        ForEach(accounts.filter { $0["provider"].text == selection.provider }.indices, id: \.self) { index in
                            let account = accounts.filter { $0["provider"].text == selection.provider }[index]
                            Text(account["label"].text.isEmpty ? account["id"].text : account["label"].text).tag(account["id"].text).disabled(!account["available"].flag)
                        }
                    }.disabled(existing).accessibilityIdentifier("picker.account")
                    if selection.provider == "cursor_cloud" && !existing {
                        Picker("Repository", selection: $selection.repository) { Text("Choose repository").tag(""); ForEach(repos.indices, id: \.self) { Text(repos[$0]["url"].text).tag(repos[$0]["url"].text) } }.accessibilityIdentifier("picker.repository")
                        TextField("Git reference (required)", text: $selection.gitRef).accessibilityIdentifier("picker.git-ref").textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } else {
                    if existing {
                        LabeledContent("Harness", value: OrbStyle.serviceName(selection.backend))
                        if let onTransfer {
                            Button("Transfer to another agent") { onTransfer(); dismiss() }.accessibilityIdentifier("picker.transfer")
                        }
                    } else {
                        Picker("Harness", selection: $selection.backend) { Text("Choose harness").tag(""); ForEach(backends.indices, id: \.self) { Text(backends[$0]["name"].text.isEmpty ? backends[$0]["id"].text : backends[$0]["name"].text).tag(backends[$0]["id"].text) } }.accessibilityIdentifier("picker.harness")
                    }
                    if !existing { Picker("Machine", selection: $selection.node) { Text("Core").tag("core"); ForEach(nodes.indices, id: \.self) { Text(nodes[$0]["name"].text.isEmpty ? nodes[$0]["id"].text : nodes[$0]["name"].text).tag(nodes[$0]["id"].text) } } }
                }
                if selection.provider != "grok_bot" { Picker("Model", selection: $selection.model) {
                    Text("Service default").tag("")
                    ForEach(models.filter { !($0["id"].text.isEmpty && $0["value"].text.isEmpty) }.indices, id: \.self) { index in
                        let filtered = models.filter { !($0["id"].text.isEmpty && $0["value"].text.isEmpty) }
                        let model = filtered[index]
                        let display = !model["displayName"].text.isEmpty ? model["displayName"].text : (!model["name"].text.isEmpty ? model["name"].text : (!model["label"].text.isEmpty ? model["label"].text : model["id"].text))
                        Text(display).tag(model["id"].text.isEmpty ? model["value"].text : model["id"].text)
                    }
                }.accessibilityIdentifier("picker.model") }
                if let model = models.first(where: { $0["id"].text == selection.model }), model["variants"].items.count > 1 {
                    let variants = model["variants"].items
                    Picker("Configuration", selection: Binding(get: { variants.firstIndex(where: { $0["params"] == selection.params }) ?? 0 }, set: { selection.params = variants[$0]["params"] })) {
                        ForEach(variants.indices, id: \.self) { index in
                            Text(variants[index]["displayName"].text.isEmpty ? variants[index]["params"].items.map { $0["value"].text }.joined(separator: " · ") : variants[index]["displayName"].text).tag(index)
                        }
                    }
                }
                if !selection.cloud && selection.backend == "codex" && !selection.model.isEmpty {
                    OrbCodexSpeedSection(model: selection.model, tier: $selection.serviceTier)
                }
                if loadingOptions && models.isEmpty {
                    HStack(spacing: 8) {
                        OrbRunningDots(size: 10)
                        Text("Loading options…").font(.footnote).foregroundStyle(OrbStyle.textSecondary)
                    }
                }
                if existing && selection.provider != "grok_bot" { Text("Model changes apply to the next message.").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("Agent settings").navigationBarTitleDisplayMode(.inline).scrollDismissesKeyboard(.interactively).toolbar { Button("Done") { dismiss() } }
            .task { await load() }
            .onChange(of: selection.provider) { _, _ in selection.account = ""; selection.model = ""; selection.params = .array([]); Task { await load() } }
            .onChange(of: selection.backend) { _, _ in Task { await loadModels() } }
            .onChange(of: selection.model) { _, _ in selection.params = models.first(where: { $0["id"].text == selection.model })?["variants"].items.first?["params"] ?? .array([]) }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    private func applyAgentCatalog(_ catalog: OrbJSON) {
        let response = catalog["backends"]
        let rawBackends = response.items.isEmpty ? response["backends"].items : response.items
        backends = rawBackends.filter { $0["id"].text != "gemini" }
        nodes = OrbSelection.sortedComputeNodes(catalog["nodes"]["nodes"].items)
        if !existing && selection.node.isEmpty {
            selection.node = OrbSelection.firstAvailableNodeID(nodes, backend: selection.backend) ?? "core"
        }
        backendModelsMap = catalog["models"]["backends"]
        models = backendModelsMap[selection.backend].items
    }
    private func load() async {
        loadingOptions = true
        defer { loadingOptions = false }
        do {
            if selection.cloud {
                if let cachedAccounts = OrbReadCache.read("catalog:cloud:accounts") {
                    accounts = cachedAccounts.items
                }
                let provider = selection.provider
                if provider != "grok_bot" {
                    let endpoint = provider == "hermes" ? "hermes" : "cursor"
                    if let cachedOpts = OrbReadCache.read("catalog:cloud:\(endpoint)") {
                        models = cachedOpts["models"]["items"].items
                        repos = cachedOpts["repositories"]["items"].items
                    }
                    async let accountsTask = OrbReadCache.cloudAccounts()
                    async let optionsTask = OrbReadCache.cloudOptions(endpoint)
                    let (accValue, optValue) = try await (accountsTask, optionsTask)
                    accounts = accValue.items
                    if selection.provider == provider {
                        models = optValue["models"]["items"].items
                        repos = optValue["repositories"]["items"].items
                    }
                } else {
                    accounts = try await OrbReadCache.cloudAccounts().items
                    models = []
                }
            } else {
                if let cached = OrbReadCache.read("catalog:agent") {
                    applyAgentCatalog(cached)
                }
                let catalog = try await OrbReadCache.agentCatalog()
                applyAgentCatalog(catalog)
            }
            error = ""
        } catch { self.error = error.localizedDescription }
    }
    private func loadModels() async {
        let provider = selection.provider, backend = selection.backend
        if !selection.cloud && backendModelsMap != .null {
            models = backendModelsMap[backend].items
            return
        }
        do {
            if selection.cloud {
                guard provider != "grok_bot" else { models = []; return }
                let endpoint = provider == "hermes" ? "hermes" : "cursor"
                if let cachedOpts = OrbReadCache.read("catalog:cloud:\(endpoint)") {
                    models = cachedOpts["models"]["items"].items
                    repos = cachedOpts["repositories"]["items"].items
                }
                let value = try await OrbReadCache.cloudOptions(endpoint)
                guard selection.provider == provider else { return }
                models = value["models"]["items"].items; repos = value["repositories"]["items"].items
            } else {
                let catalog = try await OrbReadCache.agentCatalog()
                guard selection.backend == backend && selection.provider == provider else { return }
                backendModelsMap = catalog["models"]["backends"]
                models = backendModelsMap[backend].items
            }
        } catch { self.error = error.localizedDescription }
    }
}

/// Cloud turns carry no timestamps; time each from when this device first saw it working.
