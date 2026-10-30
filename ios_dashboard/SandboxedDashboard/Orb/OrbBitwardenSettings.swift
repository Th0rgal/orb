import CryptoKit
import LocalAuthentication
import SwiftUI
import UIKit

struct OrbBitwardenSettings: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var client = OrbSettingsClient()
    @State private var unlocked = false
    @State private var authError = ""
    @State private var authenticating = false
    @State private var biometryName = "Face ID"

    @State private var loading = false
    @State private var error = ""
    @State private var status: OrbJSON = .null
    @State private var projects: [OrbJSON] = []
    @State private var selectedProjectId = ""
    @State private var requests: [OrbJSON] = []
    @State private var grants: [OrbJSON] = []
    @AppStorage("orb.secretGrants.expanded") private var showGrants = false
    @State private var actingOn: String?
    @State private var secrets: [OrbJSON] = []
    @State private var loadingSecrets = false
    @State private var searchQuery = ""
    @State private var showAccountDetails = false

    @State private var revealedValues: [String: String] = [:]
    @State private var revealingIds: Set<String> = []
    @State private var copiedId: String?

    @State private var tokenSheet = false
    @State private var createSheet = false
    @State private var editingSecret: OrbEditingSecret?
    @State private var deletingSecret: OrbJSON?

    private var filteredSecrets: [OrbJSON] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return secrets }
        return secrets.filter { s in
            s["key"].text.lowercased().contains(q) || s["note"].text.lowercased().contains(q)
        }
    }

    private var selectedProjectName: String {
        if let found = projects.first(where: { $0["id"].text == selectedProjectId }) {
            let name = found["name"].text
            if !name.isEmpty { return name }
        }
        return selectedProjectId.isEmpty ? "Default" : selectedProjectId
    }

    var body: some View {
        Group {
            if !unlocked {
                lockedView
            } else {
                unlockedListView
            }
        }
        .background(OrbStyle.background)
        .navigationTitle("Secrets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if unlocked {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        createSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(status["configured"] != .bool(true))
                    .accessibilityIdentifier("secrets.add")

                    Button {
                        lockSession()
                    } label: {
                        Image(systemName: "lock.fill")
                    }
                    .accessibilityIdentifier("secrets.lock")
                }
            }
        }
        .task {
            detectBiometry()
            if !unlocked {
                await authenticate()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                lockSession()
            }
        }
        .task(id: unlocked) {
            // Missions can ask while the page is open: refresh requests every 10 s.
            while unlocked && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if unlocked { await loadBroker() }
            }
        }
        .sheet(isPresented: $tokenSheet) {
            OrbBitwardenTokenSheet(
                client: client,
                initialServerUrl: status["server_url"].text,
                onSaved: {
                    Task { await loadAll() }
                }
            )
        }
        .sheet(isPresented: $createSheet) {
            OrbBitwardenSecretEditorSheet(
                client: client,
                projectId: selectedProjectId,
                projectName: selectedProjectName,
                existing: nil,
                onSaved: {
                    Task { await loadSecrets(projectId: selectedProjectId) }
                }
            )
        }
        .sheet(item: $editingSecret) { editing in
            OrbBitwardenSecretEditorSheet(
                client: client,
                projectId: selectedProjectId,
                projectName: selectedProjectName,
                existing: editing.secret,
                onSaved: {
                    revealedValues.removeValue(forKey: editing.id)
                    Task { await loadSecrets(projectId: selectedProjectId) }
                }
            )
        }
        .alert(
            "Delete secret?",
            isPresented: Binding(
                get: { deletingSecret != nil },
                set: { if !$0 { deletingSecret = nil } }
            ),
            presenting: deletingSecret
        ) { secret in
            Button("Cancel", role: .cancel) { deletingSecret = nil }
            Button("Delete", role: .destructive) {
                let id = secret["id"].text
                deletingSecret = nil
                Task { await deleteSecret(id: id) }
            }
        } message: { secret in
            Text("Delete \(secret["key"].text) from Bitwarden project \(selectedProjectName)? This cannot be undone.")
        }
    }

    private func lockSession() {
        unlocked = false
        revealedValues.removeAll()
        OrbBiometric.clearUnlockedContext()
    }

    private var lockedView: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 68, height: 68)
                Image(systemName: OrbBiometric.symbolName)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.white)
            }
            Text("Secrets Vault Locked")
                .font(.headline)
            Text("Authenticate with \(biometryName) to view or manage Bitwarden Secrets Manager keys.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            if !authError.isEmpty {
                Text(authError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Button {
                Task { await authenticate() }
            } label: {
                HStack(spacing: 8) {
                    if authenticating {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.black)
                    } else {
                        Image(systemName: OrbBiometric.symbolName)
                    }
                    Text(authenticating ? "Authenticating…" : "Unlock with \(biometryName)")
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.white)
                .foregroundStyle(.black)
                .clipShape(Capsule())
            }
            .disabled(authenticating)
            .accessibilityIdentifier("secrets.unlock")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unlockedListView: some View {
        List {
            OrbSettingsError(message: error)

            pendingRequestsSection

            Section {
                if !projects.isEmpty {
                    Picker("Project", selection: $selectedProjectId) {
                        ForEach(projects, id: \.selfID) { proj in
                            Text(proj["name"].text).tag(proj["id"].text)
                        }
                    }
                    .onChange(of: selectedProjectId) { _, newValue in
                        Task { await selectProject(newValue) }
                    }
                }

                DisclosureGroup(isExpanded: $showAccountDetails) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(statusSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(status["configured"] == .bool(true) ? "Update Token" : "Connect") {
                            tokenSheet = true
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)

                    if !grants.isEmpty {
                        // Collapsed by default; the choice is remembered on this device.
                        DisclosureGroup(isExpanded: $showGrants) {
                            // Grants of one mission are listed together so its title appears once.
                            ForEach(grantGroups, id: \.first!.selfID) { group in
                                HStack {
                                    Text(OrbMissionAccessMonitor.requester(group[0]))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer()
                                    if group.count > 1 {
                                        Button("Revoke all", role: .destructive) { revoke(group) }
                                            .font(.caption2)
                                            .buttonStyle(.borderless)
                                    }
                                }
                                ForEach(group, id: \.selfID) { g in
                                    HStack {
                                        Text(g["scope"]["kind"].text == "all" ? "All projects"
                                             : g["scope"]["kind"].text == "project" ? "Project \(projectName(g["scope"]["project_id"].text))"
                                             : g["scope"]["key"].text)
                                            .font(.caption.monospaced())
                                            .lineLimit(1)
                                        Spacer()
                                        Text(Self.timeLeft(g["expires_at"].text))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Button("Revoke", role: .destructive) { revoke([g]) }
                                            .font(.caption2)
                                            .buttonStyle(.borderless)
                                    }
                                    .padding(.leading, 12)
                                }
                            }
                        } label: {
                            Text(grantSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(status["configured"] == .bool(true) && isBwsAvailable ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(statusHeadline)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(accountSummaryBadge)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if loading || loadingSecrets {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading secrets…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else if filteredSecrets.isEmpty {
                    Text(searchQuery.isEmpty ? "No secrets in this Bitwarden project." : "No secrets match \"\(searchQuery)\".")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(filteredSecrets, id: \.selfID) { secret in
                        secretRow(secret)
                    }
                }
            } header: {
                HStack {
                    Text(selectedProjectName)
                    Spacer()
                    Text(searchQuery.isEmpty ? "\(secrets.count)" : "\(filteredSecrets.count) of \(secrets.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 20)
        }
        .searchable(text: $searchQuery, prompt: "Filter keys or notes")
        .refreshable {
            await loadAll()
        }
    }

    private var accountSummaryBadge: String {
        if !grants.isEmpty {
            return "\(grants.count) grant\(grants.count == 1 ? "" : "s")"
        }
        return status["configured"] == .bool(true) ? "Connected" : ""
    }

    @ViewBuilder
    private func secretRow(_ secret: OrbJSON) -> some View {
        let id = secret["id"].text
        let key = secret["key"].text
        let note = secret["note"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let revealed = revealedValues[id]
        let isRevealing = revealingIds.contains(id)

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(key)
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if copiedId == id {
                            Label("Copied", systemImage: "checkmark")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                                .transition(.opacity)
                        }
                    }
                    if !note.isEmpty {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(revealed != nil ? 4 : 1)
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 2) {
                    Button {
                        Task { await copySecret(id: id) }
                    } label: {
                        Image(systemName: copiedId == id ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(copiedId == id ? Color.green : Color.secondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy \(key)")

                    Button {
                        Task { await toggleReveal(id: id) }
                    } label: {
                        Group {
                            if isRevealing {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: revealed != nil ? "eye.slash.fill" : "eye")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(revealed != nil ? Color.accentColor : Color.secondary)
                            }
                        }
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(isRevealing)
                    .accessibilityLabel(revealed != nil ? "Hide \(key)" : "Reveal \(key)")

                    Menu {
                        Button {
                            Task { await copySecret(id: id) }
                        } label: {
                            Label("Copy Value", systemImage: "doc.on.doc")
                        }
                        Button {
                            UIPasteboard.general.string = key
                            OrbHaptics.light()
                        } label: {
                            Label("Copy Key Name", systemImage: "tag")
                        }
                        Button {
                            Task { await toggleReveal(id: id) }
                        } label: {
                            Label(revealed != nil ? "Hide Value" : "Reveal Value", systemImage: revealed != nil ? "eye.slash" : "eye")
                        }
                        Button {
                            editingSecret = OrbEditingSecret(secret: secret)
                        } label: {
                            Label("Edit Secret", systemImage: "pencil")
                        }
                        Divider()
                        Button(role: .destructive) {
                            deletingSecret = secret
                        } label: {
                            Label("Delete Secret", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("More actions for \(key)")
                }
            }

            if let revealed {
                HStack(alignment: .top, spacing: 8) {
                    Text(revealed.isEmpty ? "(empty)" : revealed)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deletingSecret = secret
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                editingSecret = OrbEditingSecret(secret: secret)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { await copySecret(id: id) }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .tint(.green)
        }
    }

    private var isBwsAvailable: Bool {
        status["bws_installed"] == .bool(true) || status["bws_available"] == .bool(true)
    }

    private var statusHeadline: String {
        if status != .null && !isBwsAvailable { return "bws CLI not installed" }
        if status["configured"] == .bool(true) { return "Bitwarden Connected" }
        return "Access token required"
    }

    private var statusSubtitle: String {
        let src = status["token_source"].text
        let hint = status["token_hint"].text
        if status["configured"] == .bool(true) {
            let label = src == "settings" ? "Saved in settings" : src == "env" ? "From BWS_ACCESS_TOKEN" : "From workspace template"
            return hint.isEmpty ? label : "\(label) (\(hint))"
        }
        return "Configure a Bitwarden Secrets Manager Machine Account token."
    }

    private func detectBiometry() {
        biometryName = OrbBiometric.name
    }

    private func authenticate() async {
        guard !authenticating else { return }
        authenticating = true
        authError = ""
        defer { authenticating = false }

        if let message = await OrbBiometric.authenticate(
            reason: "Unlock secrets and mission access requests",
            reuseUnlocked: true
        ) {
            if !message.isEmpty {
                authError = message
            }
            return
        }
        unlocked = true
        await loadAll()
    }

    private func loadAll() async {
        loading = true
        error = ""
        defer { loading = false }
        do {
            let st = try await client.call("/api/bitwarden/status")
            status = st
            let defaultProj = selectedProjectId.isEmpty ? st["default_project_id"].text : selectedProjectId
            await loadBroker()

            if st["configured"] == .bool(true) && isBwsAvailable {
                let projs = (try? await client.call("/api/bitwarden/projects").items) ?? []
                projects = projs
                let target = projs.contains(where: { $0["id"].text == defaultProj })
                    ? defaultProj
                    : (projs.first?["id"].text ?? defaultProj)
                selectedProjectId = target
                await loadSecrets(projectId: target)
                showAccountDetails = false
            } else {
                projects = []
                secrets = []
                showAccountDetails = true
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadSecrets(projectId: String) async {
        guard !projectId.isEmpty else { return }
        loadingSecrets = true
        defer { loadingSecrets = false }
        do {
            let rows = try await client.call("/api/bitwarden/projects/\(projectId)/secrets").items
            secrets = rows
            revealedValues.removeAll()
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    // Browsing a project must not change any binding: bindings grant missions access.
    private func selectProject(_ projectId: String) async {
        await loadSecrets(projectId: projectId)
    }

    private func loadBroker() async {
        guard let snap = try? await client.call("/api/bitwarden/broker") else { return }
        requests = snap["requests"].items.filter { $0["status"].text == "pending" }
        grants = snap["grants"].items
    }

    private var grantGroups: [[OrbJSON]] {
        var order: [String] = []
        var groups: [String: [OrbJSON]] = [:]
        for g in grants {
            let id = OrbMissionAccessMonitor.subjectKey(g)
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(g)
        }
        return order.compactMap { groups[$0] }
    }

    private var grantSummary: String {
        let next = grants.compactMap { Self.minutesLeft($0["expires_at"].text) }.min()
        return "\(grants.count) active \(grants.count == 1 ? "grant" : "grants")"
            + (next.map { " · next expires in \(Self.format($0))" } ?? "")
    }

    static func minutesLeft(_ raw: String) -> Int? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else { return nil }
        return max(0, Int(date.timeIntervalSinceNow / 60))
    }

    static func format(_ m: Int) -> String { m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min" }

    static func timeLeft(_ raw: String) -> String { minutesLeft(raw).map(format) ?? "" }

    /// Not optimistic: Core may refuse, so rows stay until the reload confirms it.
    private func revoke(_ group: [OrbJSON]) {
        Task {
            for g in group { _ = try? await client.call("/api/bitwarden/grants/\(g["id"].text)", method: "DELETE") }
            await loadBroker()
        }
    }

    private func projectName(_ id: String) -> String {
        projects.first(where: { $0["id"].text == id })?["name"].text ?? String(id.prefix(8))
    }

    private func describe(_ r: OrbJSON) -> String {
        let key = r["key"].text, project = r["project_id"].text
        if r["kind"].text == "write" { return "Store \(key) in \(projectName(project))" }
        if r["kind"].text == "delete" { return "Delete \(key) from \(projectName(project))" }
        if r["kind"].text == "move" {
            return "Move \(key) from \(projectName(project)) to \(projectName(r["target_project_id"].text))"
        }
        if !key.isEmpty { return "Read \(key)" }
        if r["all_projects"] == .bool(true) { return "Read every project" }
        return "Read project \(projectName(project))"
    }

    private func respond(_ r: OrbJSON, scope: String?) async {
        let id = r["id"].text
        actingOn = id
        defer { actingOn = nil }
        do {
            if let scope {
                var body: [String: OrbJSON] = [:]
                if !scope.isEmpty { body["scope"] = .string(scope) }
                _ = try await OrbApprovalKey.signedCall("/api/bitwarden/requests/\(id)/approve", method: "POST", body: .object(body), summary: "Approve: \(describe(r))")
            } else {
                _ = try await OrbApprovalKey.signedCall("/api/bitwarden/requests/\(id)/reject", method: "POST", summary: "Decline: \(describe(r))")
            }
            OrbHaptics.success()
            OrbUsageTelemetry.recordGrant(id, approve: scope != nil, enrolled: true)
        } catch {
            if let msg = OrbBiometric.friendlyError(error) {
                self.error = msg
            }
        }
        await loadBroker()
    }

    @ViewBuilder
    private var pendingRequestsSection: some View {
        if !requests.isEmpty {
            Section("Pending Secret Requests") {
                ForEach(requests, id: \.selfID) { r in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(describe(r)).font(.subheadline.weight(.medium))
                        Text([OrbMissionAccessMonitor.requester(r), r["paloma_project"].text].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if !r["reason"].text.isEmpty {
                            Text("“\(r["reason"].text)”").font(.caption).italic()
                        }
                        HStack {
                            if r["kind"].text != "read" {
                                Button("Approve") { Task { await respond(r, scope: "") } }
                            } else {
                                if !r["key"].text.isEmpty {
                                    Button("Secret") { Task { await respond(r, scope: "secret") } }
                                }
                                if !r["project_id"].text.isEmpty {
                                    Button("Project") { Task { await respond(r, scope: "project") } }
                                }
                                Button("All") { Task { await respond(r, scope: "all") } }
                            }
                            Spacer()
                            Button("Decline", role: .destructive) { Task { await respond(r, scope: nil) } }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(actingOn != nil)
                    }
                }
            }
        }
    }

    private func toggleReveal(id: String) async {
        if revealedValues[id] != nil {
            revealedValues.removeValue(forKey: id)
            return
        }
        revealingIds.insert(id)
        defer { revealingIds.remove(id) }
        do {
            let detail = try await OrbApprovalKey.signedCall("/api/bitwarden/secrets/\(id)/reveal", summary: "Reveal a secret")
            revealedValues[id] = detail["value"].text
        } catch {
            if let msg = OrbBiometric.friendlyError(error) {
                self.error = msg
            }
        }
    }

    private func copySecret(id: String) async {
        do {
            let val: String
            if let cached = revealedValues[id] {
                val = cached
            } else {
                let detail = try await OrbApprovalKey.signedCall("/api/bitwarden/secrets/\(id)/reveal", summary: "Reveal a secret")
                val = detail["value"].text
            }
            UIPasteboard.general.string = val
            OrbHaptics.success()
            copiedId = id
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if copiedId == id { copiedId = nil }
        } catch {
            if let msg = OrbBiometric.friendlyError(error) {
                self.error = msg
            }
        }
    }

    private func deleteSecret(id: String) async {
        do {
            _ = try await OrbApprovalKey.signedCall("/api/bitwarden/secrets/\(id)", method: "DELETE", summary: "Delete a secret")
            secrets.removeAll { $0["id"].text == id }
            revealedValues.removeValue(forKey: id)
            OrbHaptics.success()
        } catch {
            if let msg = OrbBiometric.friendlyError(error) {
                self.error = msg
            }
        }
    }
}

private struct OrbBitwardenTokenSheet: View {
    let client: OrbSettingsClient
    let initialServerUrl: String
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var token = ""
    @State private var serverUrl = ""
    @State private var saving = false
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                OrbSettingsError(message: error)
                Section {
                    SecureField("0.xxxx-xxxx...", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Machine Account Access Token")
                } footer: {
                    Text("Encrypted at rest on agent-core. Used by bws to read and write secrets in your Bitwarden project.")
                }

                Section("Server URL (Optional)") {
                    TextField("https://vault.bitwarden.com", text: $serverUrl)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
            }
            .navigationTitle("Machine Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(saving || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                serverUrl = initialServerUrl
            }
        }
    }

    private func save() async {
        saving = true
        error = ""
        defer { saving = false }
        do {
            _ = try await OrbApprovalKey.signedCall(
                summary: "Change the Bitwarden connection",
                "/api/bitwarden/config",
                method: "PUT",
                body: .object([
                    "access_token": .string(token.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "server_url": .string(serverUrl.trimmingCharacters(in: .whitespacesAndNewlines))
                ])
            )
            onSaved()
            dismiss()
        } catch {
            if let msg = OrbBiometric.friendlyError(error) {
                self.error = msg
            }
        }
    }
}

private struct OrbBitwardenSecretEditorSheet: View {
    let client: OrbSettingsClient
    let projectId: String
    let projectName: String
    let existing: OrbJSON?
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var key = ""
    @State private var value = ""
    @State private var note = ""
    @State private var loadingValue = false
    @State private var saving = false
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                OrbSettingsError(message: error)
                Section("Key") {
                    TextField("DATABASE_URL", text: $key)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                }
                Section("Value") {
                    if loadingValue {
                        HStack {
                            ProgressView()
                            Text("Loading current value…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        TextEditor(text: $value)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 110)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                Section("Note (Optional)") {
                    TextField("Used by production workers", text: $note)
                }
            }
            .navigationTitle(existing == nil ? "New Secret · \(projectName)" : "Edit Secret")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : (existing == nil ? "Create" : "Save")) {
                        Task { await save() }
                    }
                    .disabled(saving || loadingValue || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task {
                if let existing {
                    key = existing["key"].text
                    note = existing["note"].text
                    loadingValue = true
                    defer { loadingValue = false }
                    if let detail = try? await OrbApprovalKey.signedCall("/api/bitwarden/secrets/\(existing["id"].text)/reveal", summary: "Reveal \(existing["key"].text)") {
                        value = detail["value"].text
                    } else {
                        // Without the current value, saving would overwrite it with an empty one.
                        dismiss()
                    }
                }
            }
        }
    }

    private func save() async {
        saving = true
        error = ""
        defer { saving = false }
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let existing {
                _ = try await OrbApprovalKey.signedCall(
                    summary: "Edit \(trimmedKey)",
                    "/api/bitwarden/secrets/\(existing["id"].text)",
                    method: "PUT",
                    body: .object([
                        "key": .string(trimmedKey),
                        "value": .string(value),
                        "note": .string(note),
                        "project_id": .string(projectId)
                    ])
                )
            } else {
                _ = try await OrbApprovalKey.signedCall(
                    summary: "Create \(trimmedKey)",
                    "/api/bitwarden/projects/\(projectId)/secrets",
                    method: "POST",
                    body: .object([
                        "key": .string(trimmedKey),
                        "value": .string(value),
                        "note": .string(note)
                    ])
                )
            }
            onSaved()
            dismiss()
        } catch {
            if let msg = OrbBiometric.friendlyError(error) {
                self.error = msg
            }
        }
    }
}

/// `sheet(item:)` needs an identity; a secret is identified by its Bitwarden id.
struct OrbEditingSecret: Identifiable {
    let secret: OrbJSON
    var id: String { secret["id"].text }
}


/// Device-signed approvals: Core accepts sensitive secret operations only with a
/// signature from an enrolled device key. Here the key lives in the Secure
/// Enclave, reuses the unlocked foreground authentication context when active,
/// and signs one request without duplicate biometric prompts.
@MainActor
enum OrbApprovalKey {
    private static var keyURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("approval-key.bin")
    }
    private static var deviceKey: String { "orb.approvalDevice.\(OrbCore.shared.endpoint)" }
    static var deviceId: String? {
        get { UserDefaults.standard.string(forKey: deviceKey) }
        set { UserDefaults.standard.set(newValue, forKey: deviceKey) }
    }

    static var publicKey: String? {
        guard let blob = try? Data(contentsOf: keyURL),
              let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob) else { return nil }
        return key.publicKey.derRepresentation.base64EncodedString()
    }

    static func create() throws -> String {
        var cfError: Unmanaged<CFError>?
        let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], &cfError
        ) ?? SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &cfError
        )
        guard let access else { throw OrbHTTPError(status: 0, detail: "Secure Enclave access control unavailable") }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        try FileManager.default.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try key.dataRepresentation.write(to: keyURL, options: [.atomic, .completeFileProtection])
        return key.publicKey.derRepresentation.base64EncodedString()
    }

    static func sign(_ payload: String, reason: String) async throws -> String {
        let blob = try Data(contentsOf: keyURL)
        let data = Data(payload.utf8)
        // Core writes the summary into the signed payload: show that, not caller text.
        let shown = payload.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? reason

        // 1. If the user already unlocked biometrics in this active foreground session,
        // reuse that LAContext first so Reveal/Copy/Edit doesn't re-prompt on every tap.
        if let reused = OrbBiometric.activeUnlockedContext() {
            reused.localizedReason = shown
            if let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: reused),
               let sig = try? key.signature(for: data) {
                return sig.derRepresentation.base64EncodedString()
            }
        }

        // 2. Otherwise evaluate once and pass the authenticated LAContext to Secure Enclave.
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedReason = shown
        context.touchIDAuthenticationAllowableReuseDuration = 60
        var authError: NSError?
        let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError)
            ? .deviceOwnerAuthentication
            : .deviceOwnerAuthenticationWithBiometrics
        if context.canEvaluatePolicy(policy, error: &authError) {
            _ = try await context.evaluatePolicy(policy, localizedReason: shown)
            OrbBiometric.recordUnlockedContext(context)
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
        return try key.signature(for: data).derRepresentation.base64EncodedString()
    }

    /// Ensures this device's Secure Enclave P-256 key is matched or enrolled on Core.
    @MainActor
    static func ensureEnrolled(forceRefresh: Bool = false) async -> Bool {
        if !forceRefresh, let existing = deviceId, !existing.isEmpty, publicKey != nil {
            return true
        }
        guard let d = try? await OrbCore.shared.call("/api/approvals/devices") else {
            return deviceId != nil && publicKey != nil
        }
        let devices = d["devices"].items
        if let mine = publicKey,
           let match = devices.first(where: { $0["public_key"].text == mine }) {
            let id = match["id"].text
            if !id.isEmpty {
                deviceId = id
                return true
            }
        }
        deviceId = nil
        guard d["mode"].text != "enforce" else { return false }
        return (try? await enroll(code: "")) != nil
    }

    /// Enrolls this phone's Secure Enclave key, creating it first if needed.
    /// `code` is the one-time enrollment code Core requires in enforce mode.
    @discardableResult
    static func enroll(code: String) async throws -> String {
        let pub = try publicKey ?? create()
        let device = try await OrbCore.shared.call("/api/approvals/devices", method: "POST", body: .object([
            "name": .string("Orb on \(UIDevice.current.name)"),
            "platform": .string("ios"),
            "public_key": .string(pub),
            "enrollment_code": .string(code.trimmingCharacters(in: .whitespacesAndNewlines))
        ]))
        let id = device["id"].text
        guard !id.isEmpty else { throw OrbHTTPError(status: 0, detail: "Core did not return a device id") }
        deviceId = id
        OrbApprovalEnrollmentMonitor.shared.markEnrolled()
        return id
    }

    /// Send a protected request, signed when this phone is enrolled.
    @MainActor
    static func signedCall(summary: String, _ path: String, method: String = "GET", body: OrbJSON? = nil) async throws -> OrbJSON {
        try await signedCall(path, method: method, body: body, summary: summary)
    }

    @MainActor
    static func signedCall(_ path: String, method: String = "GET", body: OrbJSON? = nil, summary: String) async throws -> OrbJSON {
        let raw = try body.map { try JSONEncoder().encode($0) }
        _ = await ensureEnrolled()
        return try await performSignedCall(path, method: method, rawBody: raw, summary: summary, allowReenroll: true)
    }

    @MainActor
    private static func performSignedCall(_ path: String, method: String, rawBody: Data?, summary: String, allowReenroll: Bool) async throws -> OrbJSON {
        var headers: [String: String] = [:]
        if let device = deviceId, !device.isEmpty, publicKey != nil {
            let challenge = try await OrbCore.shared.call(
                "/api/approvals/challenge",
                method: "POST",
                body: .object([
                    "method": .string(method),
                    "path": .string(path),
                    "body": .string(rawBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""),
                    "summary": .string(summary)
                ])
            )
            let signature = try await sign(challenge["payload"].text, reason: summary)
            headers["X-Paloma-Approval"] = "\(challenge["challenge_id"].text).\(device).\(signature)"
        }
        do {
            return try await OrbCore.shared.call(path, method: method, rawBody: rawBody, headers: headers)
        } catch let err as OrbHTTPError where allowReenroll && err.status == 403 {
            if await ensureEnrolled(forceRefresh: true) {
                return try await performSignedCall(path, method: method, rawBody: rawBody, summary: summary, allowReenroll: false)
            }
            throw err
        }
    }
}
