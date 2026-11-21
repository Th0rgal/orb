import SwiftUI

struct OrbProviderLogin: Identifiable {
    let id: String
    let name: String
    let type: String
    let proxy: Bool
    let isNew: Bool
}

struct OrbResetPrompt: Identifiable {
    let id: String
    let provider: OrbJSON
    let summary: OrbSubscriptionResetSummary
    let idempotencyKey: String
}

struct OrbProviderLogo: View {
    let type: String
    var name: String = ""
    var size: CGFloat = 18

    private static func containsWord(_ text: String, _ word: String) -> Bool {
        text.split { !$0.isLetter && !$0.isNumber }.contains { $0 == word }
    }

    static func brandKey(type: String, name: String = "") -> String? {
        let key = type.lowercased()
        let combined = "\(key) \(name.lowercased())"
        if key.contains("hermes") { return "hermes" }
        if combined.contains("spark") || combined.contains("nvidia") || combined.contains("local") { return "nvidia" }
        if combined.contains("ethereum") || containsWord(combined, "ef") { return "ethereum" }
        if containsWord(combined, "particle") || combined.contains("particleai") || combined.contains("particle.ai") || combined.contains("particle-ai") || combined.contains("particle_ai") { return "particle" }
        if key.contains("anthropic") || key.contains("claude") { return "anthropic" }
        if key.contains("openai") || key.contains("codex") || key.contains("chatgpt") { return "openai" }
        if key.contains("kimi") || key.contains("moonshot") { return "kimi" }
        if key.contains("grok") { return "grok" }
        if key.contains("cursor") { return "cursor" }
        if key.contains("xai") { return "xai" }
        if key.contains("meta") || key.contains("muse") || key.contains("llama") { return "meta" }
        if key.contains("minimax") { return "minimax" }
        if key.contains("mistral") || key.contains("vibe") { return "mistral" }
        if key.contains("google") || key.contains("antigravity") || key.contains("gemini") { return "google" }
        if key.contains("zai") || key.contains("z.ai") || key.contains("z-ai") || key.contains("z_ai") || key.contains("zhipu") || key.contains("glm") { return "zai" }
        return nil
    }

    static func assetName(type: String, name: String = "") -> String? {
        brandKey(type: type, name: name).map { "provider-\($0)" }
    }

    var body: some View {
        let asset = Self.assetName(type: type, name: name)
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(OrbStyle.border, lineWidth: 1))
            if let asset {
                if asset == "provider-hermes" {
                    Image(asset)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size)
                } else {
                    Image(asset)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.primary)
                        .frame(width: size, height: size)
                }
            } else {
                Image(systemName: "cpu")
                    .font(.system(size: size * 0.8, weight: .medium))
                    .foregroundStyle(OrbStyle.textSecondary)
            }
        }
        .frame(width: size + 12, height: size + 12)
        .accessibilityHidden(true)
    }
}

struct OrbProvidersSettings: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var client = OrbSettingsClient()
    @State private var providers: [OrbJSON] = []
    @State private var usage: OrbJSON = .null
    @State private var health: [String: OrbJSON] = [:]
    @State private var error = ""
    @State private var usageError = ""
    @State private var loading = false
    @State private var ready = false
    @State private var busy = false
    @State private var editKey: OrbJSON?
    @State private var keySheet = false
    @State private var login: OrbProviderLogin?
    @State private var resetTarget: OrbResetPrompt?
    @State private var removeTarget: OrbJSON?
    @State private var pendingResetKeys: [String: String] = [:]
    static let subscriptionTypes = ["anthropic", "openai", "google", "xai", "kimi"]
    static func availableSubscriptionTypes(isAdmin: Bool = OrbCore.shared.isAdminUser) -> [String] {
        isAdmin ? subscriptionTypes : subscriptionTypes.filter { subscriptionLogin($0).proxy }
    }
    static func canManageProvider(_ provider: OrbJSON, isAdmin: Bool = OrbCore.shared.isAdminUser) -> Bool {
        isAdmin || provider["added_by_me"] == .bool(true)
    }
    static func isGloballyEnabled(_ p: OrbJSON) -> Bool {
        if case .bool(let g) = p["globally_enabled"] { return g }
        return p["enabled"] != .bool(false)
    }
    static func isUserSkipped(_ p: OrbJSON) -> Bool {
        p["user_enabled"] == .bool(false)
    }
    static func isEffectiveEnabled(_ p: OrbJSON) -> Bool {
        if case .bool(let eff) = p["effective_enabled"] { return eff }
        return p["enabled"] != .bool(false)
    }
    static func isMemberCustomBaseUrlAllowed(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("https://"),
              let url = URL(string: trimmed),
              url.host != nil else { return false }
        let rest = String(trimmed.dropFirst("https://".count))
        let hostPort = String(rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        if hostPort.isEmpty || hostPort.contains("[") || hostPort.contains("]") { return false }
        let host = String(hostPort.prefix { $0 != ":" }).lowercased()
        if host.isEmpty
            || host == "localhost"
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".internal")
            || host.hasSuffix(".local")
            || host.hasPrefix("127.")
            || host.hasPrefix("10.")
            || host.hasPrefix("192.168.")
            || host.hasPrefix("169.254.")
            || host.hasPrefix("0.") {
            return false
        }
        if host.hasPrefix("172.") {
            let after = host.dropFirst(4)
            let second = String(after.prefix { $0 != "." })
            if let n = Int(second), (16...31).contains(n) { return false }
        }
        if host.hasPrefix("100.") {
            let after = host.dropFirst(4)
            if !after.isEmpty && after.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        }
        return true
    }
    static func isCustomBaseUrlAllowed(_ raw: String, isAdmin: Bool = OrbCore.shared.isAdminUser) -> Bool {
        if isAdmin {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else { return false }
            return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        }
        return isMemberCustomBaseUrlAllowed(raw)
    }
    static func providerWriteError(_ error: Error, fallback: String) -> String {
        let detail: String
        if let httpErr = error as? OrbHTTPError {
            detail = httpErr.detail
        } else {
            detail = error.localizedDescription
        }
        var code = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = code.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(OrbJSON.self, from: data) {
            let extracted = !parsed["error"].text.isEmpty ? parsed["error"].text
                : !parsed["message"].text.isEmpty ? parsed["message"].text
                : parsed["detail"].text
            if !extracted.isEmpty { code = extracted }
        }
        switch code {
        case "not_account_owner":
            return "Only the person who added this account, or an admin, can change its credentials or remove it."
        case "base_url_not_allowed":
            return "Members can set a base URL only on custom accounts they added, and only to a public https:// address."
        case "admin_required":
            return "Only an admin can change this setting."
        case "account_disabled":
            return "Your account is disabled."
        default:
            return fallback
        }
    }
    var body: some View {
        let isAdmin = OrbCore.shared.isAdminUser
        List {
            OrbSettingsError(message: error)
            OrbSettingsError(message: usageError)
            if let user = OrbCore.shared.currentUser, let cap = user.dailySpendCapCents, cap > 0 {
                Section("Daily spend") {
                    LabeledContent(
                        "Today",
                        value: "\(OrbUsersModel.formatUsdFromCents(user.spentTodayCents)) / \(OrbUsersModel.formatUsdFromCents(cap))"
                    )
                    ProgressView(value: min(1.0, max(0.0, Double(user.spentTodayCents) / Double(max(1, cap)))))
                }
            }
            Section("Accounts") {
                if loading && providers.isEmpty {
                    ForEach(0..<3, id: \.self) { idx in
                        HStack(spacing: 12) {
                            OrbListIcon(symbol: "key")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(idx.isMultiple(of: 2) ? "Provider account" : "Subscription account")
                                    .font(.body.weight(.medium))
                                Text("oauth · connected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .redacted(reason: .placeholder)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .orbShimmer(active: true)
                        .allowsHitTesting(false)
                    }
                } else if ready && providers.isEmpty {
                    Text("No providers configured.").foregroundStyle(.secondary)
                }
                ForEach(providers, id: \.selfID) { provider in
                    DisclosureGroup {
                        let detail = usage[provider["id"].text]
                        OrbProviderQuota(value: detail)
                        if let reset = OrbSubscriptionResetSummary.from(detail) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(reset.badge).font(.caption.weight(.medium))
                                if !reset.detail.isEmpty {
                                    Text(reset.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if isAdmin {
                                Button("Use subscription reset…") {
                                    let pid = provider["id"].text
                                    let key = pendingResetKeys[pid] ?? UUID().uuidString.lowercased()
                                    pendingResetKeys[pid] = key
                                    resetTarget = OrbResetPrompt(
                                        id: pid,
                                        provider: provider,
                                        summary: reset,
                                        idempotencyKey: key
                                    )
                                }
                                .disabled(!ready || busy || !reset.usableNow)
                            }
                        }
                        if Self.supportsSubscriptionReset(provider) {
                            Toggle(
                                "Auto-use reset on limit",
                                isOn: Binding(
                                    get: { provider["auto_reset_on_limit"].flag },
                                    set: { next in Task { await setAutoReset(provider, enabled: next) } }
                                )
                            )
                            .disabled(!ready || busy)
                        }
                        if !detail["error"].text.isEmpty { Text(detail["error"].text).font(.caption).foregroundStyle(.orange) }
                        let providerHealth = health[provider["id"].text]
                        if let ph = providerHealth, ph["account_state"].text == "disabled_by_provider" {
                            let message = ph["disabled_by_provider_message"].text
                            Text(message.isEmpty
                                ? "The provider disabled this account. Ask the provider to restore it, then clear the disabled state."
                                : message)
                                .font(.caption).foregroundStyle(OrbStyle.error)
                        } else if providerHealth?["account_state"].text == "disabled" {
                            Text("This login is disabled in CLIProxyAPI. Re-enable the Core provider to restore it.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        let manages = Self.canManageProvider(provider, isAdmin: isAdmin)
                        OrbAccountVpnSettings(client: client, account: provider["id"].text).id(provider["id"].text)
                        let unverified = detail["status"].text == "needs_verification"
                        if unverified && manages {
                            // Google refuses this login until its owner verifies it; the
                            // OAuth sign-in itself is fine, so no Reconnect here.
                            Text("Google requires you to verify this account.").font(.caption).foregroundStyle(.orange)
                            Button("Verify account") { openURL(Self.verificationURL(detail, email: provider["account_email"].text)) }
                            if isAdmin {
                                Button("Check again") { Task { await recheck(provider) } }.disabled(!ready || busy)
                            }
                        }
                        if !detail["usage_note"].text.isEmpty { Text(detail["usage_note"].text).font(.caption).foregroundStyle(.secondary) }
                        Button(Self.canEditCredentials(provider, isAdmin: isAdmin) ? "Edit API key" : "Edit settings") {
                            editKey = provider; keySheet = true
                        }.disabled(!ready || busy)
                        if manages && Self.canConnectOAuth(provider) && !unverified {
                            if let spec = Self.loginSpec(provider, isAdmin: isAdmin) { Button("Connect / Reconnect") { login = spec }.disabled(!ready || busy) }
                            else if isAdmin { Text("This account must be connected on its credential owner.").font(.caption).foregroundStyle(.secondary) }
                        }
                        if let index = providers.firstIndex(where: { $0["id"].text == provider["id"].text }), providers.count > 1 {
                            if index > 0 {
                                Button("Try earlier") { Task { await moveProvider(from: index, to: index - 1) } }.disabled(!ready || busy)
                            }
                            if index < providers.count - 1 {
                                Button("Try later") { Task { await moveProvider(from: index, to: index + 1) } }.disabled(!ready || busy)
                            }
                        }
                        let globallyDisabled = !Self.isGloballyEnabled(provider)
                        Button(globallyDisabled ? "Enable" : "Disable") {
                            Task { await toggleGlobal(provider) }
                        }
                        .disabled(!ready || busy)
                        if OrbCore.shared.currentUser != nil {
                            let userSkipped = Self.isUserSkipped(provider)
                            Button(userSkipped ? "Use for my missions" : "Skip for my missions") {
                                Task { await toggleUserPreference(provider) }
                            }
                            .disabled(!ready || busy || globallyDisabled)
                        }
                        if manages {
                            Button("Remove provider…", role: .destructive) { removeTarget = provider }.disabled(!ready || busy)
                        }
                    } label: {
                        let parsed = Self.splitDisplayName(provider)
                        HStack(spacing: 12) {
                            OrbProviderLogo(type: provider["provider_type"].text, name: provider["name"].text)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(parsed.title)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(status(provider, accountHint: parsed.account))
                                    .font(.caption)
                                    .foregroundStyle(statusColor(provider))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            }
            if isAdmin {
                OrbCloudAccountsSettings(client: client)
            }
            Section {
                Button("Add API key", systemImage: "plus") { editKey = nil; keySheet = true }.disabled(!ready)
                Menu("Connect subscription") {
                    ForEach(Self.availableSubscriptionTypes(isAdmin: isAdmin), id: \.self) { type in
                        Button {
                            login = Self.subscriptionLogin(type)
                        } label: {
                            Label {
                                Text(type.capitalized)
                            } icon: {
                                if let asset = OrbProviderLogo.assetName(type: type) {
                                    Image(asset)
                                }
                            }
                        }
                    }
                }.disabled(!ready)
            }
        }
        .scrollContentBackground(.hidden).background(OrbStyle.background)
        .navigationTitle("Providers").navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(forceUsage: true) }
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await load(forceUsage: true) } }.disabled(loading) }
        .task {
            await load()
            await Poller.run(every: .seconds(30), immediately: false, while: { scenePhase == .active }) { await load(); return true }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load() } } }
        .sheet(isPresented: $keySheet, onDismiss: { editKey = nil }) {
            OrbProviderKeyEditor(provider: editKey, client: client) { Task { await load() } }
        }
        .sheet(item: $login) { spec in OrbProviderLoginView(spec: spec, client: client) { Task { await load() } } }
        .alert(
            "Use subscription reset?",
            isPresented: Binding(get: { resetTarget != nil }, set: { if !$0 { resetTarget = nil } }),
            presenting: resetTarget
        ) { prompt in
            Button("Cancel", role: .cancel) {
                pendingResetKeys.removeValue(forKey: prompt.id)
                resetTarget = nil
            }
            Button("Use reset", role: .destructive) { Task { await redeemReset(prompt) } }
        } message: { prompt in
            let parsed = Self.splitDisplayName(prompt.provider)
            let label = parsed.account.isEmpty ? parsed.title : parsed.account
            let detail = prompt.summary.detail.isEmpty ? "" : "\(prompt.summary.detail). "
            Text("Redeem 1 banked subscription reset on \(label)? \(detail)This immediately consumes a reset on your subscription and cannot be undone.")
        }
        .alert(
            "Remove provider?",
            isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } }),
            presenting: removeTarget
        ) { target in
            Button("Cancel", role: .cancel) { removeTarget = nil }
            Button("Remove", role: .destructive) { Task { await removeProvider(target) } }
        } message: { target in
            Text("Remove \(target["name"].text)? Any stored credentials for this account will be deleted.")
        }
    }
    /// Where the owner verifies an Antigravity account Google refuses: Google's
    /// validation page when the refusal carried one, else signing in to
    /// Antigravity with that account. Same as the desktop `verificationUrl`.
    static func verificationURL(_ detail: OrbJSON, email: String) -> URL {
        let given = detail["verification_url"].text
        if given.hasPrefix("https://"), let url = URL(string: given) { return url }
        var parts = URLComponents(string: "https://accounts.google.com/AccountChooser")!
        parts.queryItems = [URLQueryItem(name: "continue", value: "https://antigravity.google/")]
        if !email.isEmpty { parts.queryItems?.append(URLQueryItem(name: "Email", value: email)) }
        return parts.url!
    }
    static func canEditKey(_ provider: OrbJSON) -> Bool {
        provider["has_api_key"].flag || !provider["uses_oauth"].flag
    }
    static func canEditCredentials(_ provider: OrbJSON, isAdmin: Bool = OrbCore.shared.isAdminUser) -> Bool {
        canManageProvider(provider, isAdmin: isAdmin) && canEditKey(provider)
    }
    static func canEditBaseUrl(_ provider: OrbJSON?, type: String, isAdmin: Bool = OrbCore.shared.isAdminUser) -> Bool {
        type == "custom" && (provider == nil || canManageProvider(provider!, isAdmin: isAdmin))
    }
    static func canConnectOAuth(_ provider: OrbJSON) -> Bool {
        provider["uses_oauth"].flag && (provider["has_oauth"].flag || !provider["has_api_key"].flag)
    }
    /// Same as desktop `supportsSubscriptionReset`; spec: shared/orb-spec/fixtures/subscription-resets.json.
    static func supportsSubscriptionReset(_ provider: OrbJSON) -> Bool {
        guard provider["uses_oauth"].flag else { return false }
        if provider["has_api_key"] == .bool(true) && provider["has_oauth"] == .bool(false) { return false }
        let type = provider["provider_type"].text
        return type == "anthropic" || type == "openai"
    }
    static func subscriptionLogin(_ type: String) -> OrbProviderLogin {
        OrbProviderLogin(id: type, name: type.capitalized, type: type, proxy: type != "google", isNew: true)
    }
    static func loginSpec(_ provider: OrbJSON, isAdmin: Bool = OrbCore.shared.isAdminUser) -> OrbProviderLogin? {
        guard canManageProvider(provider, isAdmin: isAdmin), provider["uses_oauth"].flag else { return nil }
        let owner = provider["credential_owner"].text, type = provider["provider_type"].text
        let proxy = type != "google" && (owner == "cli_proxy" || (owner.isEmpty && subscriptionTypes.contains(type)))
        guard isAdmin || proxy else { return nil }
        guard type == "kimi" || proxy || (owner.isEmpty && type == "google") || (owner == "sandboxed_sh" && ["anthropic", "openai", "google"].contains(type)) else { return nil }
        return OrbProviderLogin(id: provider["id"].text, name: provider["name"].text, type: type, proxy: proxy, isNew: false)
    }
    static func splitDisplayName(_ p: OrbJSON) -> (title: String, account: String) {
        let raw = p["name"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitEmail = p["account_email"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasSuffix(")"), let openIdx = raw.lastIndex(of: "("), openIdx > raw.startIndex {
            let prefix = String(raw[..<openIdx]).trimmingCharacters(in: .whitespaces)
            let inside = String(raw[raw.index(after: openIdx)..<raw.index(before: raw.endIndex)]).trimmingCharacters(in: .whitespaces)
            if !prefix.isEmpty && !inside.isEmpty {
                return (prefix, inside)
            }
        }
        return (raw.isEmpty ? p["provider_type"].text : raw, explicitEmail)
    }

    static func loginStatusLabel(_ status: String) -> String? {
        status == "needs_reauth" ? "Sign in again" : nil
    }

    /// Terminal provider-side disable (Google TOS_VIOLATION and equivalent account bans).
    private func disabledState(_ p: OrbJSON) -> String {
        health[p["id"].text]?["account_state"].text ?? ""
    }
    private func statusColor(_ p: OrbJSON) -> Color {
        if ["disabled_by_provider", "disabled"].contains(disabledState(p)) { return OrbStyle.error }
        return quotaStatus(p)?.level.color ?? .secondary
    }
    private func status(_ p: OrbJSON, accountHint: String = "") -> String {
        let detail = usage[p["id"].text]
        let state: String
        var showResetBadge = false
        let healthState = disabledState(p)
        if healthState == "disabled_by_provider" {
            state = "Disabled by provider"
        } else if healthState == "disabled" {
            state = "Disabled"
        } else if !Self.isEffectiveEnabled(p) {
            if p["globally_enabled"] == .bool(false) { state = "Disabled by admin" }
            else if p["user_enabled"] == .bool(false) { state = "Skipped for your missions" }
            else { state = "Disabled" }
        }
        else if detail["status"].text == "needs_verification" { state = "Verification required" }
        else if let login = Self.loginStatusLabel(p["status"]["type"].text) ?? Self.loginStatusLabel(detail["status"].text) { state = login }
        else if !detail["error"].text.isEmpty { state = "Usage unavailable" }
        else if let quota = OrbProviderQuota.quotaStatus(OrbProviderQuota.windows(detail)) {
            state = quota.label
            showResetBadge = true
        } else {
            state = p["status"]["type"].text.replacingOccurrences(of: "_", with: " ")
            if detail["unified_status"].text.trimmingCharacters(in: .whitespaces).lowercased() == "rejected" {
                showResetBadge = true
            }
        }
        let lead = accountHint.isEmpty ? p["provider_type"].text : accountHint
        let resetBadge = showResetBadge ? (OrbSubscriptionResetSummary.from(detail)?.badge ?? "") : ""
        let rpmBadge = p["rpm_limit"].number.map { "\(Int($0)) RPM" } ?? ""
        let concBadge = p["max_concurrency"].number.map { "\(Int($0)) concurrent" } ?? ""
        return [lead, state, rpmBadge, concBadge, resetBadge].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    /// Quota severity of the row (nil while below 80% or when another state wins).
    private func quotaStatus(_ p: OrbJSON) -> OrbQuotaStatus? {
        let detail = usage[p["id"].text]
        guard Self.isEffectiveEnabled(p), p["status"]["type"].text != "needs_reauth", detail["status"].text != "needs_reauth", detail["error"].text.isEmpty else { return nil }
        return OrbProviderQuota.quotaStatus(OrbProviderQuota.windows(detail))
    }
    private static let quotaProbeProviderTypes: Set<String> = [
        "kimi", "minimax", "zai", "muse-code", "mistral"
    ]
    private static let maxConcurrentUsageProbes = 4

    private func load(forceUsage: Bool = false) async {
        guard !loading, client.current else { return }
        loading = true
        async let providersReq = client.call("/api/ai/providers")
        async let usageReq = client.call("/api/ai/providers/usage")
        async let healthReq = client.call("/api/model-routing/health")
        do {
            let response = try await providersReq
            providers = response["providers"] == .null ? response.items : response["providers"].items
            ready = true; error = ""
        } catch is CancellationError {
            loading = false
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            loading = false
            return
        } catch {
            loading = false
            ready = false
            self.error = error.localizedDescription
            return
        }
        do {
            let bulkEntries = try await usageReq["entries"]
            usage = bulkEntries
            if let rows = try? await healthReq.items {
                var byProvider: [String: OrbJSON] = [:]
                for row in rows {
                    let pid = row["provider_id"].text.isEmpty ? row["account_id"].text : row["provider_id"].text
                    if !pid.isEmpty { byProvider[pid] = row }
                    let aid = row["account_id"].text
                    if !aid.isEmpty { byProvider[aid] = row }
                }
                health = byProvider
            }
            usageError = ""
            loading = false
            var entries: [String: OrbJSON] = {
                if case .object(let existing) = bulkEntries { return existing }
                return [:]
            }()
            // Only probe per-account windows when missing, marked stale by the bulk cache, or explicitly forced.
            let targets = providers.filter { provider in
                let type = provider["provider_type"].text
                guard Self.quotaProbeProviderTypes.contains(type) || provider["uses_oauth"].flag else { return false }
                if forceUsage { return true }
                let id = provider["id"].text
                guard let cached = entries[id] else { return true }
                return cached["stale"] == .bool(true)
            }
            guard !targets.isEmpty else { return }
            let localClient = client
            var failed = false
            await withTaskGroup(of: (String, OrbJSON?).self) { group in
                var iterator = targets.makeIterator()
                for _ in 0..<min(Self.maxConcurrentUsageProbes, targets.count) {
                    if let next = iterator.next() {
                        let id = next["id"].text
                        group.addTask {
                            let value = try? await localClient.call("/api/ai/providers/\(OrbCore.escape(id))/usage")
                            return (id, value)
                        }
                    }
                }
                while let (id, value) = await group.next() {
                    if let value {
                        entries[id] = value
                        usage = .object(entries)
                    } else {
                        failed = true
                    }
                    if !Task.isCancelled, let next = iterator.next() {
                        let nextId = next["id"].text
                        group.addTask {
                            let val = try? await localClient.call("/api/ai/providers/\(OrbCore.escape(nextId))/usage")
                            return (nextId, val)
                        }
                    }
                }
            }
            if failed && !Task.isCancelled {
                usageError = "Some usage details are unavailable. Pull to refresh."
            }
        } catch is CancellationError {
            loading = false
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            loading = false
            return
        } catch {
            loading = false
            usageError = "Usage is unavailable. \(error.localizedDescription)"
        }
    }
    /// "Check again" after verifying the account with Google.
    private func recheck(_ provider: OrbJSON) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let id = provider["id"].text
        do {
            let value = try await client.call("/api/ai/providers/\(OrbCore.escape(id))/antigravity/recheck", method: "POST")
            var entries: [String: OrbJSON] = { if case .object(let existing) = usage { return existing }; return [:] }()
            entries[id] = value
            usage = .object(entries)
        } catch is CancellationError {} catch { usageError = Self.providerWriteError(error, fallback: error.localizedDescription) }
    }
    private func toggleGlobal(_ provider: OrbJSON) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let next = !Self.isGloballyEnabled(provider)
        do {
            _ = try await client.call("/api/ai/providers/\(OrbCore.escape(provider["id"].text))", method: "PUT", body: .object(["enabled": .bool(next)]))
            await load()
        } catch is CancellationError {} catch { self.error = Self.providerWriteError(error, fallback: "Could not update provider.") }
    }
    private func toggleUserPreference(_ provider: OrbJSON) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let next = Self.isUserSkipped(provider)
        do {
            _ = try await client.call("/api/ai/providers/\(OrbCore.escape(provider["id"].text))/preference", method: "PUT", body: .object(["enabled": .bool(next)]))
            await load()
        } catch is CancellationError {} catch { self.error = Self.providerWriteError(error, fallback: "Could not update provider preference.") }
    }
    private func moveProvider(from: Int, to: Int) async {
        guard !busy, from != to, providers.indices.contains(from), providers.indices.contains(to) else { return }
        busy = true; defer { busy = false }
        var ids = providers.map { $0["id"].text }
        let moved = ids.remove(at: from)
        ids.insert(moved, at: to)
        do {
            _ = try await client.call("/api/ai/providers/reorder", method: "POST", body: .object(["ids": .array(ids.map { .string($0) })]))
            await load()
        } catch is CancellationError {} catch { self.error = Self.providerWriteError(error, fallback: "Could not reorder providers.") }
    }
    private func removeProvider(_ provider: OrbJSON) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        removeTarget = nil
        do {
            _ = try await client.call("/api/ai/providers/\(OrbCore.escape(provider["id"].text))", method: "DELETE")
            await load()
        } catch is CancellationError {} catch { self.error = Self.providerWriteError(error, fallback: "Could not remove provider.") }
    }
    private func setAutoReset(_ provider: OrbJSON, enabled: Bool) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            _ = try await client.call("/api/ai/providers/\(OrbCore.escape(provider["id"].text))", method: "PUT", body: .object(["auto_reset_on_limit": .bool(enabled)]))
            await load()
        } catch is CancellationError {} catch { self.error = Self.providerWriteError(error, fallback: "Could not update auto-reset setting.") }
    }
    private func redeemReset(_ prompt: OrbResetPrompt) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        resetTarget = nil
        var payload: [String: OrbJSON] = ["idempotency_key": .string(prompt.idempotencyKey)]
        if let grantID = prompt.summary.primaryGrantID {
            payload["grant_id"] = .string(grantID)
        }
        do {
            let updated = try await client.call("/api/ai/providers/\(OrbCore.escape(prompt.id))/reset-usage", method: "POST", body: .object(payload))
            pendingResetKeys.removeValue(forKey: prompt.id)
            var entries: [String: OrbJSON] = { if case .object(let existing) = usage { return existing }; return [:] }()
            entries[prompt.id] = updated
            usage = .object(entries)
            await load()
        } catch is CancellationError {} catch { self.error = Self.providerWriteError(error, fallback: error.localizedDescription) }
    }
}

/// Normalized summary of banked subscription usage-limit resets (`subscription_resets`).
/// Spec: shared/orb-spec/fixtures/subscription-resets.json; mirrors desktop & Android.
struct OrbSubscriptionResetSummary: Equatable {
    let availableCount: Int
    let usableNow: Bool
    let badge: String
    let detail: String
    let primaryGrantID: String?

    static func formatExpiry(_ expiresAt: Double, now: Double) -> String? {
        let delta = expiresAt - now
        guard delta.isFinite, delta > 0 else { return nil }
        let mins = Int((delta / 60.0).rounded())
        if mins < 60 { return "expires in \(max(1, mins))m" }
        let hours = Int((Double(mins) / 60.0).rounded())
        if hours < 48 { return "expires in \(hours)h" }
        return "expires in \(Int((Double(hours) / 24.0).rounded()))d"
    }

    static func from(_ value: OrbJSON, now: Double = Date().timeIntervalSince1970) -> OrbSubscriptionResetSummary? {
        let resets = value["subscription_resets"]
        guard let rawCount = resets["available_count"].number, rawCount.isFinite, rawCount > 0 else { return nil }
        let availableCount = Int(rawCount.rounded(.down))
        guard availableCount > 0 else { return nil }
        let usableNow = resets["usable_now"].flag
        let grants = resets["grants"].items
        let primary = grants.first(where: { $0["usable_now"].flag }) ?? grants.first
        var parts: [String] = []
        if let primary {
            let clears = primary["clears"].items.map(\.text).filter { !$0.isEmpty }
            if !clears.isEmpty {
                parts.append("Clears \(OrbProviderQuota.joinNames(clears))")
            }
        }
        let expiry = primary?["expires_at"].number ?? grants.compactMap { $0["expires_at"].number }.first(where: { $0 > now })
        if let expiry, let expText = formatExpiry(expiry, now: now) {
            parts.append(expText)
        }
        if !usableNow {
            let reason = (!resets["unavailable_reason"].text.isEmpty ? resets["unavailable_reason"].text : (primary?["unavailable_reason"].text ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
            if !reason.isEmpty { parts.append(reason) }
        }
        let grantID = primary?["id"].text ?? ""
        return OrbSubscriptionResetSummary(
            availableCount: availableCount,
            usableNow: usableNow,
            badge: availableCount == 1 ? "1 reset available" : "\(availableCount) resets available",
            detail: parts.joined(separator: " · "),
            primaryGrantID: grantID.isEmpty ? nil : grantID
        )
    }
}

/// Anthropic unified rate-limit status as a friendly badge (nil = show nothing).
/// Spec: shared/orb-spec/fixtures/usage-limit-status.json; same as the desktop
/// `usageLimitStatus` and Android `usageLimitStatus`. Never shows a raw status.
struct OrbUsageLimitStatus: Equatable {
    enum Tone: String { case warning, error }
    let tone: Tone
    let label: String

    static func from(_ value: OrbJSON, now: Double = Date().timeIntervalSince1970) -> OrbUsageLimitStatus? {
        let status = value["unified_status"].text.trimmingCharacters(in: .whitespaces).lowercased()
        let claimKey = value["unified_representative_claim"].text.trimmingCharacters(in: .whitespaces).lowercased()
        let usedKey: String? = claimKey == "five_hour" ? "unified_5h_utilization" : (claimKey == "seven_day" ? "unified_7d_utilization" : nil)
        let used = usedKey.flatMap { value[$0].number }.flatMap { $0.isFinite ? $0 : nil }
        let reset = value["unified_reset"].number
        let left = reset.map { $0 - now }
        let hasReset = left != nil && left!.isFinite && left! > 0
        guard let badge = OrbKernel.usageLimitBadge(
            status: status,
            claim: claimKey,
            hasUtilization: used != nil,
            utilizationPct: used.map { Int(($0 * 100).rounded()) } ?? 0,
            hasReset: hasReset,
            resetRemSecs: hasReset ? Int(left!) : 0
        ) else { return nil }
        return .init(tone: badge.tone == "error" ? .error : .warning, label: badge.label)
    }
}

/// Same as orb/src/providerUsage.ts quotaLevel; spec: shared/orb-spec/fixtures/quota-level.json.
/// < 80% normal, 80-99% warning, 100% (rounded, as shown) exhausted.
enum OrbQuotaLevel: String {
    case normal, warning, exhausted
    static let warningPercent = 80
    static func of(_ used: Double?, hasReset: Bool = false) -> OrbQuotaLevel {
        guard let used, used.isFinite else { return hasReset ? .exhausted : .normal }
        let pct = Int((used * 100).rounded())
        return pct >= 100 ? .exhausted : pct >= warningPercent ? .warning : .normal
    }
    var rank: Int { self == .exhausted ? 2 : self == .warning ? 1 : 0 }
    /// System colors adapt to light/dark mode and Increase Contrast; nil = neutral.
    var color: Color? { self == .exhausted ? .red : self == .warning ? .orange : nil }
}

struct OrbQuotaStatus: Equatable {
    let level: OrbQuotaLevel
    let label: String
    let accountWide: Bool
}

struct OrbProviderQuota: View {
    let value: OrbJSON
    /// "Gemini · 5h" belongs to the Gemini pool; a plain "5h" to the whole account ("").
    static func quotaPool(_ label: String) -> String {
        guard let range = label.range(of: " · ") else { return "" }
        return String(label[..<range.lowerBound])
    }
    /// Same as orb/src/providerUsage.ts quotaStatus; spec: shared/orb-spec/fixtures/quota-exhausted.json.
    static func quotaStatus(_ windows: [(String, Double)]) -> OrbQuotaStatus? {
        var order: [String] = [], levels: [String: OrbQuotaLevel] = [:], pcts: [String: Int] = [:]
        for (label, used) in windows {
            let pool = quotaPool(label)
            if !order.contains(pool) { order.append(pool) }
            let level = OrbQuotaLevel.of(used)
            if level.rank > (levels[pool]?.rank ?? -1) { levels[pool] = level }
            pcts[pool] = max(pcts[pool] ?? 0, Int((min(1, max(0, used)) * 100).rounded()))
        }
        for level in [OrbQuotaLevel.exhausted, .warning] {
            let hit = order.filter { levels[$0] == level }
            if hit.isEmpty { continue }
            let accountWindow = hit.contains("")
            let names = joinNames(hit.filter { !$0.isEmpty })
            let subject = accountWindow || names.isEmpty ? "Quota" : "\(names) quota"
            let pct = hit.map { pcts[$0] ?? 0 }.max() ?? 0
            return level == .exhausted
                ? OrbQuotaStatus(level: level, label: "\(subject) exhausted", accountWide: accountWindow || hit.count == order.count)
                : OrbQuotaStatus(level: level, label: "\(subject) at \(pct)%", accountWide: accountWindow)
        }
        return nil
    }
    static func quotaExhaustedLabel(_ windows: [(String, Double)]) -> String? {
        guard let status = quotaStatus(windows), status.level == .exhausted else { return nil }
        return status.label
    }
    /// "Gemini", "Claude & GPT and Gemini", "A, B and C".
    static func joinNames(_ names: [String]) -> String {
        names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
    static func codexWindowLabel(_ minutes: Double?, fallback: String, otherMinutes: Double? = nil, explicitLabel: String? = nil) -> String {
        if let trimmed = explicitLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty { return trimmed }
        guard let raw = minutes, raw.isFinite, raw > 0 else { return fallback }
        let mins = Int(raw.rounded())
        let base: String
        if mins == 10080 { base = "Weekly" }
        else if mins >= 1440 && mins % 1440 == 0 { base = "\(mins / 1440)d" }
        else if mins >= 60 && mins % 60 == 0 { base = "\(mins / 60)h" }
        else { base = "\(mins)m" }
        if let other = otherMinutes, other.isFinite, other > 0, Int(other.rounded()) == mins {
            return "\(base) (secondary)"
        }
        return base
    }
    static func windows(_ value: OrbJSON) -> [(String, Double)] {
        var result: [(String, Double)] = []
        func add(_ label: String, _ key: String, scale: Double = 100, remaining: Bool = false) {
            if let raw = value[key].number, raw.isFinite { result.append((label, min(1, max(0, remaining ? 1 - raw / scale : raw / scale)))) }
        }
        add("5h", "unified_5h_utilization", scale: 1); add("Weekly", "unified_7d_utilization", scale: 1)
        let primaryMins = value["codex_primary_window_minutes"].number
        let secondaryMins = value["codex_secondary_window_minutes"].number
        if primaryMins != 0 {
            add(codexWindowLabel(primaryMins, fallback: "Primary", explicitLabel: value["codex_primary_window_label"].text), "codex_primary_used_percent")
        }
        if secondaryMins != 0 {
            let otherMins = value["codex_primary_used_percent"].number != nil ? primaryMins : nil
            add(codexWindowLabel(secondaryMins, fallback: "Secondary", otherMinutes: otherMins, explicitLabel: value["codex_secondary_window_label"].text), "codex_secondary_used_percent")
        }
        add("Credits", "xai_credit_used_percent")
        if value["kimi_windows"].items.isEmpty { add("5h", "kimi_5h_used_percent"); add("Weekly", "kimi_weekly_used_percent") }
        else { for window in value["kimi_windows"].items { if let percent = window["used_percent"].number, percent.isFinite { result.append((window["label"].text, min(1, max(0, percent / 100)))) } } }
        add("5h", "minimax_interval_remaining_percent", remaining: true); add("Weekly", "minimax_weekly_remaining_percent", remaining: true)
        add("5h", "zai_5h_used_percent"); add("Weekly", "zai_weekly_used_percent")
        if value["zai_5h_used_percent"] == .null && value["zai_weekly_used_percent"] == .null { add("Tokens", "zai_tokens_percentage") }
        add("5h", "muse_5h_used_percent"); add("Weekly", "muse_weekly_used_percent")
        add("Monthly", "mistral_monthly_used_percent")
        for window in value["antigravity_windows"].items {
            // Google omits a zero remaining fraction: a reset without a figure is spent.
            if let percent = window["used_percent"].number, percent.isFinite { result.append((window["label"].text, min(1, max(0, percent / 100)))) }
            else if window["used_percent"] == .null && window["reset_at"] != .null { result.append((window["label"].text, 1)) }
        }
        return result
    }
    var body: some View {
        let windows = Self.windows(value)
        if let limit = OrbUsageLimitStatus.from(value) {
            Label(limit.label, systemImage: limit.tone == .error ? "exclamationmark.octagon" : "exclamationmark.triangle")
                .font(.caption).foregroundStyle(limit.tone == .error ? Color.red : Color.orange)
        }
        if windows.isEmpty { Text("No quota information available.").font(.caption).foregroundStyle(.secondary) }
        // One row per pool with every window the API returns for it (desktop: provider-usage-row).
        ForEach(Self.pools(windows), id: \.name) { pool in
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { poolName(pool.name); chips(pool.windows) }
                VStack(alignment: .leading, spacing: 4) { poolName(pool.name); HStack(spacing: 12) { chips(pool.windows) } }
            }
            .font(.caption)
        }
    }
    /// Windows grouped by pool in API order; "Gemini · 5h" → ("Gemini", "5h").
    static func pools(_ windows: [(String, Double)]) -> [(name: String, windows: [(String, Double)])] {
        var out: [(name: String, windows: [(String, Double)])] = []
        for (label, used) in windows {
            let pool = quotaPool(label)
            let short = pool.isEmpty ? label : String(label.dropFirst(pool.count + 3))
            if let i = out.firstIndex(where: { $0.name == pool }) { out[i].windows.append((short, used)) }
            else { out.append((pool, [(short, used)])) }
        }
        return out
    }
    @ViewBuilder private func poolName(_ name: String) -> some View {
        if !name.isEmpty { Text(name).fontWeight(.medium).lineLimit(1) }
    }
    private func chips(_ windows: [(String, Double)]) -> some View {
        ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
            let level = OrbQuotaLevel.of(window.1)
            let pct = Int((window.1 * 100).rounded())
            HStack(spacing: 5) {
                Text(window.0 == "7d" ? "Weekly" : window.0).foregroundStyle(.secondary)
                ProgressView(value: min(1, max(0, window.1))).tint(level.color).frame(width: 44)
                Text("\(pct)%").monospacedDigit().foregroundStyle(level.color ?? .secondary).fontWeight(level == .normal ? nil : .semibold)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(window.0) \(pct)% used")
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
    @State private var rpmLimit = ""
    @State private var maxConcurrency = ""
    @State private var error = ""
    @State private var busy = false
    static let apiKeyTypes = ["anthropic", "openai", "google", "xai", "open-router", "groq", "mistral", "minimax", "zai", "custom"]
    enum CapParseResult: Equatable {
        case ok(Int?)
        case invalid
    }
    static func parseOptionalCap(_ raw: String, min: Int, max: Int) -> CapParseResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .ok(nil) }
        guard let n = Int(trimmed), n >= min, n <= max else { return .invalid }
        return .ok(n)
    }
    private var isAdmin: Bool { OrbCore.shared.isAdminUser }
    private var canEditCredentials: Bool {
        guard let provider else { return true }
        return OrbProvidersSettings.canEditCredentials(provider, isAdmin: isAdmin)
    }
    private var canEditBaseUrl: Bool {
        OrbProvidersSettings.canEditBaseUrl(provider, type: type, isAdmin: isAdmin)
    }
    private var capsValid: Bool {
        Self.parseOptionalCap(rpmLimit, min: 1, max: 100_000) != .invalid
        && Self.parseOptionalCap(maxConcurrency, min: 1, max: 1024) != .invalid
    }
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && (provider != nil || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        && capsValid
        && (!canEditBaseUrl || OrbProvidersSettings.isCustomBaseUrlAllowed(baseURL, isAdmin: isAdmin))
    }
    var body: some View {
        NavigationStack {
            Form {
                OrbSettingsError(message: error)
                if provider == nil { Picker("Provider", selection: $type) { ForEach(Self.apiKeyTypes, id: \.self) { Text($0).tag($0) } } }
                TextField("Name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                if canEditCredentials {
                    SecureField(provider == nil ? "API key" : "New API key (optional)", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if canEditBaseUrl {
                    TextField(isAdmin ? "Base URL" : "Base URL (public https://)", text: $baseURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("Router pacing (optional)") {
                    TextField("Requests / min limit (e.g. 300)", text: $rpmLimit).keyboardType(.numberPad)
                    TextField("Max concurrent requests (e.g. 10)", text: $maxConcurrency).keyboardType(.numberPad)
                }
            }.disabled(busy)
            .navigationTitle(provider == nil ? "Add API key" : (canEditCredentials ? "Edit API key" : "Edit provider settings")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(!valid || busy) }
            }
        }.interactiveDismissDisabled(busy)
        .onAppear {
            if let provider {
                name = provider["name"].text
                type = provider["provider_type"].text
                baseURL = provider["base_url"].text
                rpmLimit = provider["rpm_limit"].number.map { String(Int($0)) } ?? ""
                maxConcurrency = provider["max_concurrency"].number.map { String(Int($0)) } ?? ""
            }
        }
        .onDisappear { key = "" }
    }
    private func save() async {
        guard valid, !busy else { return }; busy = true; defer { busy = false }
        guard case .ok(let rpm) = Self.parseOptionalCap(rpmLimit, min: 1, max: 100_000),
              case .ok(let conc) = Self.parseOptionalCap(maxConcurrency, min: 1, max: 1024) else { return }
        var body: [String: OrbJSON] = ["name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines))]
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if canEditCredentials && !trimmedKey.isEmpty { body["api_key"] = .string(trimmedKey) }
        if provider == nil {
            body["provider_type"] = .string(type)
            if canEditBaseUrl { body["base_url"] = .string(baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if let rpm { body["rpm_limit"] = .number(Double(rpm)) }
            if let conc { body["max_concurrency"] = .number(Double(conc)) }
        } else if let provider {
            if canEditBaseUrl { body["base_url"] = .string(baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if let rpm { body["rpm_limit"] = .number(Double(rpm)) }
            else if provider["rpm_limit"].number != nil { body["rpm_limit"] = .null }
            if let conc { body["max_concurrency"] = .number(Double(conc)) }
            else if provider["max_concurrency"].number != nil { body["max_concurrency"] = .null }
        }
        do {
            _ = try await client.call("/api/ai/providers" + (provider.map { "/" + OrbCore.escape($0["id"].text) } ?? ""), method: provider == nil ? "POST" : "PUT", body: .object(body))
            key = ""; onSaved(); dismiss()
        } catch is CancellationError { key = ""; error = "Backend changed. Close and reopen this page." }
        catch { self.error = OrbProvidersSettings.providerWriteError(error, fallback: "Could not save the provider settings. Check the connection and try again.") }
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
        .onDisappear {
            callback = ""
            if spec.proxy && !session.isEmpty {
                let id = session
                Task { _ = try? await client.call("/api/ai/providers/cli-proxy-login/\(OrbCore.escape(id))", method: "DELETE") }
            }
        }
    }
    private func accept(_ state: OrbJSON) {
        if state["status"].text == "completed" { finished = true; callback = ""; onSaved(); dismiss() }
        else if state["status"].text == "failed" { finished = true; error = state["message"].text.isEmpty ? "Sign-in failed. Close and try again." : state["message"].text }
    }
    private func startAndPoll() async {
        do {
            let value = try await client.call(spec.proxy ? "/api/ai/providers/cli-proxy-login" : "/api/ai/providers/\(OrbCore.escape(spec.id))/oauth/authorize", method: "POST", body: spec.proxy ? .object(spec.isNew ? ["provider": .string(spec.type)] : ["provider": .string(spec.type), "provider_id": .string(spec.id)]) : .object(["method_index": .number(0)]))
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
        } catch is CancellationError {} catch { self.error = OrbProvidersSettings.providerWriteError(error, fallback: "Could not start sign-in. \(error.localizedDescription)") }
        starting = false
    }
    private func submit() async {
        guard !busy, !finished else { return }; busy = true; defer { busy = false }
        do {
            let path = spec.proxy ? "/api/ai/providers/cli-proxy-login/\(OrbCore.escape(session))/callback" : "/api/ai/providers/\(OrbCore.escape(spec.id))/oauth/callback"
            let state = try await client.call(path, method: "POST", body: .object(spec.proxy ? ["url": .string(callback.trimmingCharacters(in: .whitespacesAndNewlines))] : ["method_index": .number(0), "code": .string(callback.trimmingCharacters(in: .whitespacesAndNewlines))]))
            if spec.proxy { accept(state) } else { finished = true; callback = ""; onSaved(); dismiss() }
        } catch is CancellationError { error = "Backend changed. Close and reopen this page." }
        catch { self.error = OrbProvidersSettings.providerWriteError(error, fallback: "Could not complete sign-in. Check the pasted URL or code and try again.") }
    }
}

struct OrbCloudAccountsSettings: View {
    let client: OrbSettingsClient
    @Environment(\.scenePhase) private var scenePhase
    @State private var accounts: [OrbJSON] = []
    @State private var usage: OrbJSON = .null
    @State private var health: [String: OrbJSON] = [:]
    @State private var error = ""
    @State private var loaded = false
    private let dashboards = ["cursor_cloud": "https://cursor.com/dashboard/usage", "grok_bot": "https://grok.com/"]
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
                    HStack(spacing: 12) {
                        OrbProviderLogo(type: account["provider"].text, name: account["label"].text)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(account["label"].text)
                            Text(account["available"].flag ? "Available" : "Unavailable").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button("Refresh cloud accounts") { Task { await load() } }
        }.task { await load() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load() } } }
    }
    private func load() async {
        async let accountsReq = client.call("/api/cloud/accounts")
        async let usageReq = client.call("/api/cloud/usage")
        do { accounts = try await accountsReq.items; loaded = true; error = "" }
        catch is CancellationError { return }
        catch { self.error = "Cloud accounts unavailable."; loaded = true }
        do { usage = try await usageReq["accounts"] }
        catch { usage = .null }
    }
}


private struct OrbAccountVpnSettings: View {
    let client: OrbSettingsClient
    let account: String
    @State private var route: OrbJSON = .null
    @State private var busy = false
    @State private var error = ""

    private func update(_ country: String? = nil) async {
        guard !busy else { return }
        busy = true
        error = ""
        defer { busy = false }
        let path = "/api/ai/providers/\(OrbCore.escape(account))/vpn"
        do {
            if let country {
                let fields: [String: OrbJSON] = country.isEmpty ? ["mode": .string("direct")] :
                    ["mode": .string("vpn"), "country": .string(country)]
                route = try await client.call(path, method: "PUT", body: .object(fields))
            } else {
                route = try await client.call(path)
            }
        } catch { self.error = error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading) {
            if route != .null {
                let selected = route["country"].text
                let countries = Set(route["countries"].items.map(\.text) + [selected]).subtracting([""]).sorted()
                Picker("Account connection", selection: Binding(get: { selected }, set: { value in
                    Task { await update(value) }
                })) {
                    Text("Direct").tag("")
                    ForEach(countries, id: \.self) { Text("AirVPN · " + $0).tag($0) }
                }
                .disabled(busy || !route["can_configure"].flag)
                if !route["can_configure"].flag {
                    Text("This credential’s connection is managed by the sidecar.").font(.caption)
                } else if countries.isEmpty {
                    Text("Import a named server profile in AirVPN Settings to enable VPN routing.").font(.caption)
                }
                if route["status"].text == "verified" {
                    Text("Verified exit · " + route["server"].text + " · " + route["exits"].items.map(\.text).joined(separator: ", "))
                } else if route["status"].text == "blocked" {
                    Text(route["message"].text).font(.caption)
                    Button("Retry verification") { Task { await update(selected) } }
                        .disabled(busy || !route["can_configure"].flag)
                }
            }
            if !error.isEmpty {
                Text(error).font(.caption)
                Button("Retry connection settings") { Task { await update() } }.disabled(busy)
            }
        }.task(id: account) { await update() }
    }
}
