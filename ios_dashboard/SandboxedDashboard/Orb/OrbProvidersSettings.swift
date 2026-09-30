import SwiftUI

struct OrbProviderLogin: Identifiable {
    let id: String
    let name: String
    let type: String
    let proxy: Bool
}

struct OrbProvidersSettings: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var client = OrbSettingsClient()
    @State private var providers: [OrbJSON] = []
    @State private var usage: OrbJSON = .null
    @State private var error = ""
    @State private var usageError = ""
    @State private var loading = false
    @State private var ready = false
    @State private var busy = false
    @State private var editKey: OrbJSON?
    @State private var keySheet = false
    @State private var login: OrbProviderLogin?
    static let subscriptionTypes = ["anthropic", "openai", "google", "xai", "kimi"]
    var body: some View {
        List {
            OrbSettingsError(message: error)
            OrbSettingsError(message: usageError)
            if loading && providers.isEmpty { ProgressView("Loading providers…") }
            Section("Accounts") {
                if ready && providers.isEmpty { Text("No providers configured.").foregroundStyle(.secondary) }
                ForEach(providers, id: \.selfID) { provider in
                    DisclosureGroup {
                        let detail = usage[provider["id"].text]
                        OrbProviderQuota(value: detail)
                        if !detail["error"].text.isEmpty { Text(detail["error"].text).font(.caption).foregroundStyle(.orange) }
                        if !detail["usage_note"].text.isEmpty { Text(detail["usage_note"].text).font(.caption).foregroundStyle(.secondary) }
                        if Self.canEditKey(provider) { Button("Edit API key") { editKey = provider; keySheet = true }.disabled(!ready || busy) }
                        if Self.canConnectOAuth(provider) {
                            if let spec = Self.loginSpec(provider) { Button("Connect / Reconnect") { login = spec }.disabled(!ready || busy) }
                            else { Text("This account must be connected on its credential owner.").font(.caption).foregroundStyle(.secondary) }
                        }
                        Button(provider["enabled"] == .bool(false) ? "Enable" : "Disable") { Task { await toggle(provider) } }.disabled(!ready || busy)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(provider["name"].text)
                            Text(status(provider)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            OrbCloudAccountsSettings(client: client)
            Section {
                Button("Add API key", systemImage: "plus") { editKey = nil; keySheet = true }.disabled(!ready)
                Menu("Connect subscription") {
                    ForEach(Self.subscriptionTypes, id: \.self) { type in
                        Button(type.capitalized) { login = Self.subscriptionLogin(type) }
                    }
                }.disabled(!ready)
            }
        }
        .scrollContentBackground(.hidden).background(OrbStyle.background)
        .navigationTitle("Providers").navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading) }
        .task {
            await load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
                if scenePhase == .active { await load() }
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load() } } }
        .sheet(isPresented: $keySheet, onDismiss: { editKey = nil }) {
            OrbProviderKeyEditor(provider: editKey, client: client) { Task { await load() } }
        }
        .sheet(item: $login) { spec in OrbProviderLoginView(spec: spec, client: client) { Task { await load() } } }
    }
    static func canEditKey(_ provider: OrbJSON) -> Bool {
        provider["has_api_key"].flag || !provider["uses_oauth"].flag
    }
    static func canConnectOAuth(_ provider: OrbJSON) -> Bool {
        provider["uses_oauth"].flag && (provider["has_oauth"].flag || !provider["has_api_key"].flag)
    }
    static func subscriptionLogin(_ type: String) -> OrbProviderLogin {
        OrbProviderLogin(id: type, name: type.capitalized, type: type, proxy: !["kimi", "google"].contains(type))
    }
    static func loginSpec(_ provider: OrbJSON) -> OrbProviderLogin? {
        guard provider["uses_oauth"].flag else { return nil }
        let owner = provider["credential_owner"].text, type = provider["provider_type"].text
        let proxy = !["kimi", "google"].contains(type) && (owner == "cli_proxy" || (owner.isEmpty && subscriptionTypes.contains(type)))
        guard type == "kimi" || proxy || (owner == "sandboxed_sh" && ["anthropic", "openai", "google"].contains(type)) else { return nil }
        return OrbProviderLogin(id: provider["id"].text, name: provider["name"].text, type: type, proxy: proxy)
    }
    private func status(_ p: OrbJSON) -> String {
        let detail = usage[p["id"].text]
        let state: String
        if p["enabled"] == .bool(false) { state = "Disabled" }
        else if p["status"]["type"].text == "needs_reauth" || detail["status"].text == "needs_reauth" { state = "Reconnect" }
        else if !detail["error"].text.isEmpty { state = "Usage unavailable" }
        else if OrbProviderQuota.windows(detail).contains(where: { $0.1 >= 1 }) { state = "Quota exhausted" }
        else { state = p["status"]["type"].text.replacingOccurrences(of: "_", with: " ") }
        return "\(p["provider_type"].text) · \(state)"
    }
    private func load() async {
        guard !loading, client.current else { return }; loading = true; defer { loading = false }
        do {
            let response = try await client.call("/api/ai/providers")
            providers = response["providers"] == .null ? response.items : response["providers"].items
            ready = true; error = ""
        } catch is CancellationError { return }
        catch { ready = false; self.error = error.localizedDescription; return }
        do {
            usage = try await client.call("/api/ai/providers/usage")["entries"]; usageError = ""
            // The bulk endpoint may only have a cache; request current subscription windows too.
            for provider in providers where ["kimi", "minimax", "zai"].contains(provider["provider_type"].text) || provider["uses_oauth"].flag {
                let id = provider["id"].text
                do {
                    let value = try await client.call("/api/ai/providers/\(OrbCore.escape(id))/usage")
                    if case .object(var entries) = usage { entries[id] = value; usage = .object(entries) }
                    else { usage = .object([id: value]) }
                } catch is CancellationError { return }
                catch { usageError = "Some usage details are unavailable. Pull to refresh." }
            }
        } catch is CancellationError { return }
        catch { usageError = "Usage is unavailable. \(error.localizedDescription)" }
    }
    private func toggle(_ provider: OrbJSON) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            _ = try await client.call("/api/ai/providers/\(OrbCore.escape(provider["id"].text))", method: "PUT", body: .object(["enabled": .bool(provider["enabled"] == .bool(false))]))
            await load()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

struct OrbProviderQuota: View {
    let value: OrbJSON
    static func windows(_ value: OrbJSON) -> [(String, Double)] {
        var result: [(String, Double)] = []
        func add(_ label: String, _ key: String, scale: Double = 100, remaining: Bool = false) {
            if let raw = value[key].number, raw.isFinite { result.append((label, min(1, max(0, remaining ? 1 - raw / scale : raw / scale)))) }
        }
        add("5h", "unified_5h_utilization", scale: 1); add("Weekly", "unified_7d_utilization", scale: 1)
        if value["codex_primary_window_minutes"].number != 0 { add("Primary", "codex_primary_used_percent") }
        if value["codex_secondary_window_minutes"].number != 0 { add("Secondary", "codex_secondary_used_percent") }
        add("Credits", "xai_credit_used_percent")
        if value["kimi_windows"].items.isEmpty { add("5h", "kimi_5h_used_percent"); add("Weekly", "kimi_weekly_used_percent") }
        else { for window in value["kimi_windows"].items { if let percent = window["used_percent"].number, percent.isFinite { result.append((window["label"].text, min(1, max(0, percent / 100)))) } } }
        add("5h", "minimax_interval_remaining_percent", remaining: true); add("Weekly", "minimax_weekly_remaining_percent", remaining: true)
        add("5h", "zai_5h_used_percent"); add("Weekly", "zai_weekly_used_percent")
        if value["zai_5h_used_percent"] == .null && value["zai_weekly_used_percent"] == .null { add("Tokens", "zai_tokens_percentage") }
        return result
    }
    var body: some View {
        let windows = Self.windows(value)
        if windows.isEmpty { Text("No quota information available.").font(.caption).foregroundStyle(.secondary) }
        ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
            VStack(alignment: .leading) { LabeledContent(window.0, value: "\(Int((window.1 * 100).rounded()))% used"); ProgressView(value: window.1) }
        }
    }
}

struct OrbProviderKeyEditor: View {
    let provider: OrbJSON?
    let client: OrbSettingsClient
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var type = "openai"
    @State private var name = ""
    @State private var key = ""
    @State private var baseURL = ""
    @State private var error = ""
    @State private var busy = false
    private let types = ["anthropic", "openai", "google", "xai", "kimi", "open-router", "groq", "mistral", "minimax", "zai", "custom"]
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && (provider != nil || type != "custom" || (URL(string: baseURL)?.host != nil && ["http", "https"].contains(URL(string: baseURL)?.scheme ?? "")))
    }
    var body: some View {
        NavigationStack {
            Form {
                OrbSettingsError(message: error)
                if provider == nil { Picker("Provider", selection: $type) { ForEach(types, id: \.self) { Text($0).tag($0) } } }
                TextField("Name", text: $name)
                SecureField("API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                if provider == nil && type == "custom" { TextField("Base URL", text: $baseURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled() }
            }.disabled(busy)
            .navigationTitle(provider == nil ? "Add API key" : "Edit API key").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(!valid || busy) }
            }
        }.interactiveDismissDisabled(busy)
        .onAppear { if let provider { name = provider["name"].text; type = provider["provider_type"].text } }
        .onDisappear { key = "" }
    }
    private func save() async {
        guard valid, !busy else { return }; busy = true; defer { busy = false }
        var body: [String: OrbJSON] = ["name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)), "api_key": .string(key.trimmingCharacters(in: .whitespacesAndNewlines))]
        if provider == nil { body["provider_type"] = .string(type); if type == "custom" { body["base_url"] = .string(baseURL) } }
        do {
            _ = try await client.call("/api/ai/providers" + (provider.map { "/" + OrbCore.escape($0["id"].text) } ?? ""), method: provider == nil ? "POST" : "PUT", body: .object(body))
            key = ""; onSaved(); dismiss()
        } catch is CancellationError { key = ""; error = "Backend changed. Close and reopen this page." }
        catch { self.error = "Could not save the API key. Check the connection and try again." }
    }
}

struct OrbProviderLoginView: View {
    let spec: OrbProviderLogin
    let client: OrbSettingsClient
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = ""
    @State private var url: URL?
    @State private var instructions = ""
    @State private var device = false
    @State private var callback = ""
    @State private var error = ""
    @State private var starting = true
    @State private var busy = false
    @State private var finished = false
    var body: some View {
        NavigationStack {
            Form {
                OrbSettingsError(message: error)
                if starting { ProgressView("Starting login…") }
                if let url {
                    Button("Open sign-in page") { openURL(url) }
                    if !instructions.isEmpty { Text(instructions).textSelection(.enabled) }
                    if !spec.proxy && spec.type == "kimi" {
                        Text("Approve the code in your browser, then return here.")
                        Button("Complete sign-in") { Task { await submit() } }.disabled(busy || finished)
                    }
                    else if device { Text("Complete sign-in in your browser, then return here. This page checks for completion automatically.") }
                    else {
                        Text("After signing in, paste the final redirect URL or authorization code below if the browser cannot return to Orb.").font(.caption).foregroundStyle(.secondary)
                        TextField("Redirect URL or code", text: $callback).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Complete sign-in") { Task { await submit() } }.disabled(callback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy || finished)
                    }
                }
            }
            .navigationTitle(spec.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) } }
        }.interactiveDismissDisabled(busy)
        .task { await startAndPoll() }
        .onDisappear { callback = "" }
    }
    private func accept(_ state: OrbJSON) {
        if state["status"].text == "completed" { finished = true; callback = ""; onSaved(); dismiss() }
        else if state["status"].text == "failed" { finished = true; error = state["message"].text.isEmpty ? "Sign-in failed. Close and try again." : state["message"].text }
    }
    private func startAndPoll() async {
        do {
            let value = try await client.call(spec.proxy ? "/api/ai/providers/cli-proxy-login" : "/api/ai/providers/\(OrbCore.escape(spec.id))/oauth/authorize", method: "POST", body: spec.proxy ? .object(["provider": .string(spec.type)]) : .object(["method_index": .number(0)]))
            session = spec.proxy ? value["session_id"].text : spec.id
            let link = value[spec.proxy ? "auth_url" : "url"].text
            guard let parsed = URL(string: link), ["https", "http"].contains(parsed.scheme ?? ""), parsed.host != nil, !session.isEmpty else { throw URLError(.badServerResponse) }
            url = parsed; instructions = value["instructions"].text
            device = value[spec.proxy ? "flow" : "method"].text == "device"
            starting = false; openURL(parsed)
            if spec.proxy {
                while !Task.isCancelled && !finished {
                    try await Task.sleep(for: .seconds(2))
                    if scenePhase == .active && !busy {
                        do { accept(try await client.call("/api/ai/providers/cli-proxy-login/\(OrbCore.escape(session))")); if !finished { error = "" } }
                        catch is CancellationError { return }
                        catch { self.error = "Could not check sign-in yet. Retrying…" }
                    }
                }
            }
        } catch is CancellationError {} catch { self.error = "Could not start sign-in. \(error.localizedDescription)" }
        starting = false
    }
    private func submit() async {
        guard !busy, !finished else { return }; busy = true; defer { busy = false }
        do {
            let path = spec.proxy ? "/api/ai/providers/cli-proxy-login/\(OrbCore.escape(session))/callback" : "/api/ai/providers/\(OrbCore.escape(spec.id))/oauth/callback"
            let state = try await client.call(path, method: "POST", body: .object(spec.proxy ? ["url": .string(callback.trimmingCharacters(in: .whitespacesAndNewlines))] : ["method_index": .number(0), "code": .string(callback.trimmingCharacters(in: .whitespacesAndNewlines))]))
            if spec.proxy { accept(state) } else { finished = true; callback = ""; onSaved(); dismiss() }
        } catch is CancellationError { error = "Backend changed. Close and reopen this page." }
        catch { self.error = "Could not complete sign-in. Check the pasted URL or code and try again." }
    }
}

struct OrbCloudAccountsSettings: View {
    let client: OrbSettingsClient
    @Environment(\.scenePhase) private var scenePhase
    @State private var accounts: [OrbJSON] = []
    @State private var usage: OrbJSON = .null
    @State private var error = ""
    @State private var loaded = false
    private let dashboards = ["chatgpt": "https://chatgpt.com/", "cursor_cloud": "https://cursor.com/dashboard/usage", "grok_bot": "https://grok.com/"]
    var body: some View {
        Section("Cloud agents") {
            if !error.isEmpty { Text(error).foregroundStyle(.orange) }
            if !loaded { ProgressView() }
            if loaded && accounts.isEmpty && error.isEmpty { Text("No cloud accounts configured.").foregroundStyle(.secondary) }
            ForEach(accounts, id: \.selfID) { account in
                DisclosureGroup {
                    if !account["reason"].text.isEmpty { Text(account["reason"].text).font(.caption) }
                    let windows = usage[account["id"].text]["windows"].items
                    ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                        if let percent = window["used_percent"].number {
                            LabeledContent(window["label"].text, value: "\(Int(percent.rounded()))% used")
                            ProgressView(value: min(1, max(0, percent / 100)))
                        }
                    }
                    if let raw = dashboards[account["provider"].text], let url = URL(string: raw) { Link("Open provider dashboard", destination: url) }
                } label: {
                    VStack(alignment: .leading) {
                        Text(account["label"].text)
                        Text(account["available"].flag ? "Available" : "Unavailable").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button("Refresh cloud accounts") { Task { await load() } }
        }.task { await load() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load() } } }
    }
    private func load() async {
        do { accounts = try await client.call("/api/cloud/accounts").items; loaded = true; error = "" }
        catch is CancellationError { return }
        catch { self.error = "Cloud accounts unavailable."; loaded = true }
        do { usage = try await client.call("/api/cloud/usage")["accounts"] }
        catch { usage = .null }
    }
}
