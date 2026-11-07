import SwiftUI
import UIKit

struct OrbSelection {
    var provider = "agent", account = "", backend = "", model = "", node = "", repository = "", gitRef = ""
    var nodePinnedByUser = false
    var allow24hCommitment = false
    var serviceTier = "standard"
    var cyberMode = "automatic"
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
        if let autoLabel = OrbManaged.autoManagedLabel(node) {
            return autoLabel
        }
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
        if !cloud && backend == "opencode" && !node.isEmpty && node != "core" && model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw OrbHTTPError(status: 400, detail: "Choose an explicit model to run OpenCode on a remote machine, or select Core.")
        }
        if !cloud && OrbManaged.isAutoManagedTarget(node) && (backend == "grok" || backend == "vibe") {
            throw OrbHTTPError(status: 400, detail: "\(OrbStyle.serviceName(backend)) is not supported on managed cloud VMs. Choose Claude Code, Codex, OpenCode, or Antigravity, or select Core.")
        }
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
    var missionID: String? = nil
    var goal = false
    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [OrbJSON] = []
    @State private var models: [OrbJSON] = []
    @State private var backends: [OrbJSON] = []
    @State private var nodes: [OrbJSON] = []
    @State private var repos: [OrbJSON] = []
    @State private var backendModelsMap: OrbJSON = .null
    @State private var managedResponse: OrbManagedMachinesResponse? = nil
    @State private var agentVmsExpanded = false
    @State private var loadingOptions = false
    @State private var error = ""
    private var managedOwners: [String: String] {
        OrbManaged.ownerByNodeId(managedResponse?.machines ?? [])
    }
    private var staticComputeNodes: [OrbJSON] {
        nodes.filter { !OrbManaged.isManagedNode($0) }
    }
    private var userManagedNodes: [OrbJSON] {
        let owners = managedOwners
        return nodes.filter { OrbManaged.isUserManagedNode($0, managedOwnerByNodeId: owners) }
    }
    private var agentManagedNodes: [OrbJSON] {
        let owners = managedOwners
        return nodes.filter { OrbManaged.isAgentSpawnedManagedNode($0, managedOwnerByNodeId: owners) }
    }
    private var usableCloudProviders: [OrbManagedProviderInfo] {
        OrbManaged.usableProviders(managedResponse)
    }
    private func selectNode(_ id: String, allow24h: Bool = false) {
        selection.node = id
        selection.nodePinnedByUser = true
        selection.allow24hCommitment = allow24h
    }
    @ViewBuilder private func machineNodeRow(_ node: OrbJSON, isManaged: Bool = false) -> some View {
        let id = node["id"].text
        let chosen = selection.node == id
        let title = isManaged
            ? OrbManaged.nodeTitle(node)
            : (node["name"].text.isEmpty ? id : node["name"].text)
        let status = node["status"].text
        let providerBadge = isManaged ? OrbManaged.nodeProvider(node).map { OrbManaged.providerLabel($0) } : nil
        Button {
            selectNode(id)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let providerBadge, !providerBadge.isEmpty {
                        Text(providerBadge).font(.caption).foregroundStyle(.secondary)
                    } else if !status.isEmpty && status != "online" {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if chosen {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("picker.machine.\(id)")
    }
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
                    if existing, let onTransfer {
                        Button("Continue in workspace") { onTransfer(); dismiss() }.accessibilityIdentifier("picker.transfer")
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
                    if !existing {
                        Section("Machine") {
                            Button {
                                selectNode("core")
                            } label: {
                                HStack {
                                    Text("Core").foregroundStyle(.primary)
                                    Spacer()
                                    if selection.node.isEmpty || selection.node == "core" {
                                        Image(systemName: "checkmark")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("picker.machine.core")

                            ForEach(staticComputeNodes, id: \.["id"].text) { node in
                                machineNodeRow(node)
                            }
                        }

                        if !usableCloudProviders.isEmpty {
                            Section {
                                ForEach(usableCloudProviders) { provider in
                                    let sizes = OrbManaged.allowedSizes(provider.sizes, maxSize: managedResponse?.budget.max_size)
                                    let parsed = OrbManaged.parseAutoManagedTarget(selection.node)
                                    let selectedSize = (parsed?.provider == OrbManaged.machineProviderKey(provider.provider)) ? parsed?.size : nil
                                    NavigationLink {
                                        OrbProviderSizePickerView(
                                            provider: provider,
                                            sizes: sizes,
                                            selectedNode: selection.node,
                                            onSelect: { target, allow24h in
                                                selectNode(target, allow24h: allow24h)
                                            }
                                        )
                                    } label: {
                                        HStack(spacing: 10) {
                                            Label(OrbManaged.providerDisplayLabel(provider.provider, providers: usableCloudProviders), systemImage: "cloud")
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            if let selectedSize, !selectedSize.isEmpty {
                                                Text(OrbManaged.sizeLabel(selectedSize))
                                                    .font(.subheadline)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .accessibilityIdentifier("picker.cloud.\(provider.provider)")
                                }
                            } header: {
                                Text("Cloud VMs (start on send)")
                            }
                        }

                        if !userManagedNodes.isEmpty {
                            Section("Your VMs") {
                                ForEach(userManagedNodes, id: \.["id"].text) { node in
                                    machineNodeRow(node, isManaged: true)
                                }
                            }
                        }

                        if !agentManagedNodes.isEmpty {
                            Section {
                                DisclosureGroup(
                                    "Agent-spawned VMs (\(agentManagedNodes.count))",
                                    isExpanded: $agentVmsExpanded
                                ) {
                                    ForEach(agentManagedNodes, id: \.["id"].text) { node in
                                        machineNodeRow(node, isManaged: true)
                                    }
                                }
                                .accessibilityIdentifier("picker.agent-vms")
                            }
                        }
                    }
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
                    OrbCodexSpeedSection(model: selection.model, missionID: missionID, tier: $selection.serviceTier)
                }
                if !selection.cloud && selection.backend == "codex" {
                    OrbCyberSection(model: selection.model, remote: !selection.node.isEmpty && selection.node != "core", goal: goal, missionID: missionID, mode: $selection.cyberMode)
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
            .onChange(of: selection.backend) { _, _ in
                selection.model = ""
                selection.params = .array([])
                recomputeAutoNodeIfNeeded()
                Task { await loadModels() }
            }
            .onChange(of: selection.model) { _, _ in
                selection.params = models.first(where: { $0["id"].text == selection.model })?["variants"].items.first?["params"] ?? .array([])
                recomputeAutoNodeIfNeeded()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    private func recomputeAutoNodeIfNeeded() {
        guard !existing, !selection.cloud, !selection.nodePinnedByUser else { return }
        if selection.backend == "opencode" && selection.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selection.node = "core"
            return
        }
        if !nodes.isEmpty {
            selection.node = OrbSelection.firstAvailableNodeID(nodes, backend: selection.backend) ?? "core"
        }
    }
    private func applyAgentCatalog(_ catalog: OrbJSON) {
        let response = catalog["backends"]
        let rawBackends = response.items.isEmpty ? response["backends"].items : response.items
        backends = rawBackends.filter { $0["id"].text != "gemini" }
        nodes = OrbSelection.sortedComputeNodes(catalog["nodes"]["nodes"].items)
        if catalog["managed"] != .null, let decoded = try? OrbManaged.decode(catalog["managed"]) {
            managedResponse = decoded
        }
        let owners = OrbManaged.ownerByNodeId(managedResponse?.machines ?? [])
        if nodes.contains(where: { $0["id"].text == selection.node && OrbManaged.isAgentSpawnedManagedNode($0, managedOwnerByNodeId: owners) }) {
            agentVmsExpanded = true
        }
        recomputeAutoNodeIfNeeded()
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

private struct OrbProviderSizePickerView: View {
    let provider: OrbManagedProviderInfo
    let sizes: [OrbManagedSize]
    let selectedNode: String
    let onSelect: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pending24hSize: OrbManagedSize? = nil

    var body: some View {
        List {
            Section {
                ForEach(sizes, id: \.size) { s in
                    let target = OrbManaged.formatAutoManagedTarget(provider: provider.provider, size: s.size)
                    let chosen = selectedNode.lowercased() == target.lowercased()
                    Button {
                        if OrbManaged.is24hCommitmentSize(s) {
                            pending24hSize = s
                        } else {
                            onSelect(target, false)
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(OrbManaged.sizeLabel(s.size))
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    if OrbManaged.is24hCommitmentSize(s) {
                                        Text("24h min")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.secondary.opacity(0.14), in: Capsule())
                                    }
                                }
                                Text(OrbManaged.compactSizeSpec(s))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(OrbManaged.usdPerHour(s.usd_per_hour))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if chosen {
                                Image(systemName: "checkmark")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("picker.cloud.\(provider.provider).\(s.size)")
                }
            } footer: {
                Text("The VM will be provisioned automatically when you send your prompt.")
            }
        }
        .navigationTitle(OrbManaged.providerDisplayLabel(provider.provider))
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "24-hour minimum commitment",
            isPresented: Binding(
                get: { pending24hSize != nil },
                set: { if !$0 { pending24hSize = nil } }
            ),
            presenting: pending24hSize
        ) { size in
            Button("Cancel", role: .cancel) { pending24hSize = nil }
            Button("Select (\(OrbManaged.usd(size.usd_per_hour * Double(size.min_billing_hours ?? 24))) min)") {
                let target = OrbManaged.formatAutoManagedTarget(provider: provider.provider, size: size.size)
                pending24hSize = nil
                onSelect(target, true)
                dismiss()
            }
        } message: { size in
            let hours = size.min_billing_hours ?? 24
            Text("\(OrbManaged.providerDisplayLabel(provider.provider)) \(OrbManaged.sizeLabel(size.size)) carries a \(hours)-hour minimum lease (\(OrbManaged.usd(size.usd_per_hour * Double(hours))) total) once started on prompt send.")
        }
    }
}

/// Cloud turns carry no timestamps; time each from when this device first saw it working.
