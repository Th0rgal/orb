import LocalAuthentication
import SwiftUI
import UIKit

struct OrbBitwardenSettings: View {
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
    @State private var actingOn: String?
    @State private var secrets: [OrbJSON] = []
    @State private var loadingSecrets = false
    @State private var searchQuery = ""

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
        return selectedProjectId
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
                        unlocked = false
                        revealedValues.removeAll()
                    } label: {
                        Image(systemName: "lock.fill")
                    }
                    .accessibilityIdentifier("secrets.lock")
                }
            }
        }
        .task {
            detectBiometry()
            await authenticate()
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

    private var lockedView: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 68, height: 68)
                Image(systemName: biometryName == "Touch ID" ? "touchid" : "faceid")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            Text("Project Secrets Locked")
                .font(.headline)
            Text("Authenticate with \(biometryName) to view or edit Bitwarden Secrets Manager credentials for project paloma.")
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
                    Image(systemName: biometryName == "Touch ID" ? "touchid" : "faceid")
                    Text(authenticating ? "Authenticating…" : "Unlock with \(biometryName)")
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.accentColor)
                .foregroundStyle(.white)
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

            accessSection

            Section("Machine Account") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(status["configured"] == .bool(true) && isBwsAvailable ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(statusHeadline)
                                .font(.subheadline.weight(.medium))
                        }
                        Text(statusSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(status["configured"] == .bool(true) ? "Token" : "Connect") {
                        tokenSheet = true
                    }
                    .font(.subheadline)
                }

                if !projects.isEmpty {
                    Picker("Bitwarden project", selection: $selectedProjectId) {
                        ForEach(projects, id: \.selfID) { proj in
                            Text(proj["name"].text).tag(proj["id"].text)
                        }
                    }
                    .onChange(of: selectedProjectId) { _, newValue in
                        Task { await selectProject(newValue) }
                    }
                } else {
                    HStack {
                        Text("Connected project")
                        Spacer()
                        Text("—")
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if loading || loadingSecrets {
                    HStack {
                        ProgressView()
                        Text("Loading secrets…")
                            .foregroundStyle(.secondary)
                    }
                } else if filteredSecrets.isEmpty {
                    Text(searchQuery.isEmpty ? "No secrets in this Bitwarden project." : "No secrets match \"\(searchQuery)\".")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredSecrets, id: \.selfID) { secret in
                        secretRow(secret)
                    }
                }
            } header: {
                HStack {
                    Text("Secrets · \(selectedProjectName)")
                    Spacer()
                    Text("\(secrets.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .searchable(text: $searchQuery, prompt: "Filter keys or notes")
        .refreshable {
            await loadAll()
        }
    }

    @ViewBuilder
    private func secretRow(_ secret: OrbJSON) -> some View {
        let id = secret["id"].text
        let key = secret["key"].text
        let note = secret["note"].text
        let revealed = revealedValues[id]
        let isRevealing = revealingIds.contains(id)

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(key)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if copiedId == id {
                    Text("Copied")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                }
            }

            if let revealed {
                Text(revealed.isEmpty ? "(empty)" : revealed)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Text("••••••••••••••••••••")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 16) {
                Button {
                    Task { await toggleReveal(id: id) }
                } label: {
                    Label(revealed != nil ? "Hide" : (isRevealing ? "Loading…" : "Reveal"), systemImage: revealed != nil ? "eye.slash" : "eye")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(isRevealing)

                Button {
                    Task { await copySecret(id: id) }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Button {
                    editingSecret = OrbEditingSecret(secret: secret)
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Spacer()

                Button(role: .destructive) {
                    deletingSecret = secret
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    private var isBwsAvailable: Bool {
        status["bws_installed"] == .bool(true) || status["bws_available"] == .bool(true)
    }

    private var statusHeadline: String {
        if status != .null && !isBwsAvailable { return "bws CLI not installed" }
        if status["configured"] == .bool(true) { return "Connected" }
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
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            switch context.biometryType {
            case .faceID: biometryName = "Face ID"
            case .touchID: biometryName = "Touch ID"
            case .opticID: biometryName = "Optic ID"
            default: biometryName = "Biometrics"
            }
        } else {
            biometryName = "Passcode"
        }
    }

    private func authenticate() async {
        guard !authenticating else { return }
        authenticating = true
        authError = ""
        defer { authenticating = false }

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var policyError: NSError?
        let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &policyError)
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication

        guard context.canEvaluatePolicy(policy, error: &policyError) else {
            // Simulator or device without passcode configured
            unlocked = true
            await loadAll()
            return
        }

        do {
            let success = try await context.evaluatePolicy(
                policy,
                localizedReason: "Unlock secrets and mission access requests"
            )
            if success {
                unlocked = true
                await loadAll()
            } else {
                authError = "Authentication was not completed."
            }
        } catch {
            authError = error.localizedDescription
        }
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
            } else {
                projects = []
                secrets = []
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

    private func projectName(_ id: String) -> String {
        projects.first(where: { $0["id"].text == id })?["name"].text ?? String(id.prefix(8))
    }

    private func describe(_ r: OrbJSON) -> String {
        let key = r["key"].text, project = r["project_id"].text
        if r["kind"].text == "write" { return "Store \(key) in \(projectName(project))" }
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
                _ = try await client.call("/api/bitwarden/requests/\(id)/approve", method: "POST", body: .object(body))
            } else {
                _ = try await client.call("/api/bitwarden/requests/\(id)/reject", method: "POST")
            }
        } catch {
            self.error = error.localizedDescription
        }
        await loadBroker()
    }

    @ViewBuilder
    private var accessSection: some View {
        if !requests.isEmpty || !grants.isEmpty {
            Section("Mission access") {
                ForEach(requests, id: \.selfID) { r in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(describe(r)).font(.subheadline.weight(.medium))
                        Text([r["mission_title"].text, r["paloma_project"].text].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if !r["reason"].text.isEmpty {
                            Text("“\(r["reason"].text)”").font(.caption).italic()
                        }
                        HStack {
                            if r["kind"].text == "write" {
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
                        .disabled(actingOn != nil)
                    }
                }
                ForEach(grants, id: \.selfID) { g in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(g["scope"]["kind"].text == "all" ? "All projects"
                                 : g["scope"]["kind"].text == "project" ? "Project \(projectName(g["scope"]["project_id"].text))"
                                 : "Secret \(g["scope"]["key"].text)")
                                .font(.subheadline)
                            Text(g["mission_title"].text).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke") {
                            Task {
                                _ = try? await client.call("/api/bitwarden/grants/\(g["id"].text)", method: "DELETE")
                                await loadBroker()
                            }
                        }
                        .font(.subheadline)
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
            let detail = try await client.call("/api/bitwarden/secrets/\(id)/reveal")
            revealedValues[id] = detail["value"].text
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func copySecret(id: String) async {
        do {
            let val: String
            if let cached = revealedValues[id] {
                val = cached
            } else {
                let detail = try await client.call("/api/bitwarden/secrets/\(id)/reveal")
                val = detail["value"].text
            }
            UIPasteboard.general.string = val
            copiedId = id
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if copiedId == id { copiedId = nil }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteSecret(id: String) async {
        do {
            _ = try await client.call("/api/bitwarden/secrets/\(id)", method: "DELETE")
            secrets.removeAll { $0["id"].text == id }
            revealedValues.removeValue(forKey: id)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
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
            _ = try await client.call(
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
            self.error = error.localizedDescription
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
                    if let detail = try? await client.call("/api/bitwarden/secrets/\(existing["id"].text)/reveal") {
                        value = detail["value"].text
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
                _ = try await client.call(
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
                _ = try await client.call(
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
            self.error = error.localizedDescription
        }
    }
}

/// `sheet(item:)` needs an identity; a secret is identified by its Bitwarden id.
struct OrbEditingSecret: Identifiable {
    let secret: OrbJSON
    var id: String { secret["id"].text }
}
