import SwiftUI

enum OrbUsersModel {
    static let reservedUnixUsernames: Set<String> = [
        "root", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail", "news",
        "uucp", "proxy", "www-data", "backup", "list", "irc", "gnats", "nobody",
        "systemd-network", "systemd-resolve", "messagebus", "sshd", "orb-node",
        "orb-privd", "sandboxed", "ubuntu", "debian", "admin",
    ]

    nonisolated static func validUnixUsername(_ raw: String) -> Bool {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, v.utf8.count <= 31, !reservedUnixUsernames.contains(v) else { return false }
        var chars = v.unicodeScalars.makeIterator()
        guard let first = chars.next() else { return false }
        let isFirstLower = (first.value >= 97 && first.value <= 122) || first.value == 95
        guard isFirstLower else { return false }
        while let ch = chars.next() {
            let v = ch.value
            let ok = (v >= 97 && v <= 122) || (v >= 48 && v <= 57) || v == 95 || v == 45
            if !ok { return false }
        }
        return true
    }

    nonisolated static func defaultUnixUsernameFor(_ username: String) -> String {
        let lower = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var slug = ""
        var prevDash = false
        for scalar in lower.unicodeScalars {
            let v = scalar.value
            let isAlnum = (v >= 97 && v <= 122) || (v >= 48 && v <= 57)
            if isAlnum {
                slug.unicodeScalars.append(scalar)
                prevDash = false
            } else if !prevDash && !slug.isEmpty {
                slug.append("-")
                prevDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.count > 27 { slug = String(slug.prefix(27)) }
        while slug.hasSuffix("-") { slug.removeLast() }
        guard !slug.isEmpty else { return "" }
        let candidate = "orb-\(slug)"
        return validUnixUsername(candidate) ? candidate : ""
    }

    nonisolated static func formatUsdFromCents(_ cents: Int?) -> String {
        guard let cents else { return "Unlimited" }
        return String(format: "$%.2f", Double(max(0, cents)) / 100.0)
    }

    nonisolated static func parseUsdToCents(_ raw: String) -> Int?? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "$", with: "")
        if trimmed.isEmpty { return .some(nil) }
        guard let num = Double(trimmed), num.isFinite, num >= 0, num <= 1_000_000 else {
            return nil
        }
        return .some(Int((num * 100.0).rounded()))
    }

    nonisolated static func isLegacySingleTenantFallback(status: Int?, authMode: String) -> Bool {
        guard status == 404 else { return false }
        return authMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "multi_user"
    }

    nonisolated static func resetPasswordPath(for userId: String) -> String {
        "/api/admin/users/\(OrbCore.escape(userId))/reset-password"
    }
}

struct OrbAdminUser: Identifiable, Equatable {
    let id: String
    var username: String
    var role: String
    var unixUsername: String?
    var dailySpendCapCents: Int?
    var spentTodayCents: Int
    var disabled: Bool
    var createdAt: String
    var lastLoginAt: String?

    init(
        id: String,
        username: String,
        role: String,
        unixUsername: String? = nil,
        dailySpendCapCents: Int? = nil,
        spentTodayCents: Int = 0,
        disabled: Bool = false,
        createdAt: String = "",
        lastLoginAt: String? = nil
    ) {
        self.id = id
        self.username = username
        self.role = role
        self.unixUsername = unixUsername
        self.dailySpendCapCents = dailySpendCapCents
        self.spentTodayCents = spentTodayCents
        self.disabled = disabled
        self.createdAt = createdAt
        self.lastLoginAt = lastLoginAt
    }

    nonisolated static func singleTenantAdmin(
        id: String? = nil,
        username: String? = nil,
        unixUsername: String? = nil,
        dailySpendCapCents: Int? = nil,
        spentTodayCents: Int = 0
    ) -> Self {
        let cleanId = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanUser = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self(
            id: cleanId.isEmpty ? "admin" : cleanId,
            username: cleanUser.isEmpty ? "admin" : cleanUser,
            role: "admin",
            unixUsername: unixUsername,
            dailySpendCapCents: dailySpendCapCents,
            spentTodayCents: spentTodayCents
        )
    }

    init?(_ j: OrbJSON) {
        let id = j["id"].text
        let username = j["username"].text
        guard !id.isEmpty, !username.isEmpty else { return nil }
        self.id = id
        self.username = username
        self.role = j["role"].text == "admin" ? "admin" : "member"
        let unix = j["unix_username"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.unixUsername = unix.isEmpty ? nil : unix
        self.dailySpendCapCents = j["daily_spend_cap_cents"].doubleValue.map { Int($0.rounded()) }
        self.spentTodayCents = j["spent_today_cents"].doubleValue.map { max(0, Int($0.rounded())) } ?? 0
        self.disabled = j["disabled"].flag
        self.createdAt = j["created_at"].text
        let last = j["last_login_at"].text
        self.lastLoginAt = last.isEmpty ? nil : last
    }
}

struct OrbUsersSettings: View {
    @State private var client = OrbSettingsClient()
    @State private var users: [OrbAdminUser] = []
    @State private var loading = false
    @State private var ready = false
    @State private var legacySingleTenant = false
    @State private var error = ""
    @State private var creating = false
    @State private var editing: OrbAdminUser?

    private var activeAdminCount: Int {
        users.filter { $0.role == "admin" && !$0.disabled }.count
    }

    var body: some View {
        List {
            OrbSettingsError(message: error)
            if loading && users.isEmpty {
                ProgressView("Loading users…")
            }
            Section {
                if ready && users.isEmpty {
                    Text("No users configured.")
                        .foregroundStyle(.secondary)
                }
                ForEach(users) { user in
                    Button {
                        if !legacySingleTenant {
                            editing = user
                        }
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text("@\(user.username)")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(user.role == "admin" ? "Admin" : "Member")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(user.role == "admin" ? OrbStyle.success : OrbStyle.textSecondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.white.opacity(0.08), in: Capsule())
                                    if legacySingleTenant || OrbCore.shared.currentUser?.id == user.id {
                                        Text("You")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(OrbStyle.textSecondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.white.opacity(0.08), in: Capsule())
                                    }
                                    if user.disabled {
                                        Text("Disabled")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(OrbStyle.warning)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(OrbStyle.warning.opacity(0.16), in: Capsule())
                                    }
                                }
                                Text(subtitle(for: user))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if !legacySingleTenant {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(legacySingleTenant)
                    .accessibilityIdentifier("users.row.\(user.username)")
                }
            } header: {
                Text("Accounts")
            } footer: {
                if legacySingleTenant {
                    Text("Connected Core server is running in single-tenant mode. Upgrade Core to add or manage multi-user accounts.")
                } else {
                    Text("Each user runs in their own Linux home directory on shared compute nodes. User workspaces and missions remain private.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(OrbStyle.background)
        .navigationTitle("Users")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    creating = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(legacySingleTenant)
                .accessibilityLabel("New user")
                .accessibilityIdentifier("users.create")
            }
        }
        .task { await load() }
        .sheet(isPresented: $creating) {
            OrbCreateUserSheet(client: client) {
                Task { await load() }
            }
        }
        .sheet(item: $editing) { user in
            OrbEditUserSheet(
                user: user,
                isSoleActiveAdmin: user.role == "admin" && !user.disabled && activeAdminCount <= 1,
                client: client,
                onChanged: { Task { await load() } }
            )
        }
    }

    private func subtitle(for user: OrbAdminUser) -> String {
        if legacySingleTenant {
            return "Server password · Full Core & fleet access · No daily cap"
        }
        var parts: [String] = []
        if let unix = user.unixUsername {
            parts.append("/home/\(unix)")
        }
        let spent = OrbUsersModel.formatUsdFromCents(user.spentTodayCents)
        if let cap = user.dailySpendCapCents {
            parts.append("\(spent) / \(OrbUsersModel.formatUsdFromCents(cap)) today")
        } else if user.spentTodayCents > 0 {
            parts.append("\(spent) today")
        } else {
            parts.append("No daily cap")
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard !loading, client.current else { return }
        loading = true
        defer { loading = false }
        do {
            let res = try await client.call("/api/admin/users")
            let rawItems = res["users"] == .null ? res.items : res["users"].items
            users = rawItems.compactMap(OrbAdminUser.init)
            legacySingleTenant = false
            ready = true
            error = ""
        } catch is CancellationError {
            return
        } catch let http as OrbHTTPError where http.status == 404 {
            if OrbCore.shared.authMode == .multiUser {
                await OrbCore.shared.refreshCurrentUser()
            }
            if OrbUsersModel.isLegacySingleTenantFallback(status: 404, authMode: OrbCore.shared.authMode.rawValue) {
                let cur = OrbCore.shared.currentUser
                users = [
                    OrbAdminUser.singleTenantAdmin(
                        id: cur?.id,
                        username: cur?.username,
                        unixUsername: cur?.unixUsername,
                        dailySpendCapCents: cur?.dailySpendCapCents,
                        spentTodayCents: cur?.spentTodayCents ?? 0
                    )
                ]
                legacySingleTenant = true
                ready = true
                error = ""
            } else {
                self.error = http.localizedDescription
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct OrbCreateUserSheet: View {
    let client: OrbSettingsClient
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var role = "member"
    @State private var unixUsername = ""
    @State private var unixEdited = false
    @State private var dailyCapUsd = ""
    @State private var saving = false
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                if !error.isEmpty {
                    Section { Text(error).font(.footnote).foregroundStyle(OrbStyle.error) }
                }
                Section("Identity") {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: username) { _, next in
                            if !unixEdited {
                                unixUsername = OrbUsersModel.defaultUnixUsernameFor(next)
                            }
                        }
                    SecureField("Temporary password (8+ chars)", text: $password)
                        .textContentType(.newPassword)
                    Picker("Role", selection: $role) {
                        Text("Member").tag("member")
                        Text("Admin").tag("admin")
                    }
                }
                Section {
                    TextField("orb-alice", text: $unixUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .onChange(of: unixUsername) { _, next in
                            if next != OrbUsersModel.defaultUnixUsernameFor(username) {
                                unixEdited = true
                            }
                        }
                } header: {
                    Text("Linux account")
                } footer: {
                    Text("Lowercase POSIX username (`[a-z_][a-z0-9_-]{0,30}`) provisioned on shared compute nodes.")
                }
                Section {
                    TextField("Unlimited (USD / day)", text: $dailyCapUsd)
                        .keyboardType(.decimalPad)
                } header: {
                    Text("Daily AI & compute cap (USD)")
                } footer: {
                    Text("Leave blank for no daily limit.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(OrbStyle.background)
            .navigationTitle("New user")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Creating…" : "Create") {
                        Task { await submit() }
                    }
                    .disabled(saving || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.count < 8)
                }
            }
        }
    }

    private func submit() async {
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUnix = unixUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUser.isEmpty else { error = "Enter a username."; return }
        guard password.count >= 8 else { error = "Password must be at least 8 characters."; return }
        guard OrbUsersModel.validUnixUsername(cleanUnix) else {
            error = "Enter a valid non-reserved POSIX Linux username."
            return
        }
        guard let parsedCap = OrbUsersModel.parseUsdToCents(dailyCapUsd) else {
            error = "Enter a valid non-negative USD daily cap."
            return
        }
        saving = true
        error = ""
        defer { saving = false }
        do {
            var body: [String: OrbJSON] = [
                "username": .string(cleanUser),
                "password": .string(password),
                "role": .string(role),
                "unix_username": .string(cleanUnix),
            ]
            if let cents = parsedCap {
                body["daily_spend_cap_cents"] = .number(Double(cents))
            }
            _ = try await client.call("/api/admin/users", method: "POST", body: .object(body))
            onCreated()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct OrbEditUserSheet: View {
    let user: OrbAdminUser
    let isSoleActiveAdmin: Bool
    let client: OrbSettingsClient
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var role: String
    @State private var unixUsername: String
    @State private var dailyCapUsd: String
    @State private var disabled: Bool
    @State private var newPassword = ""
    @State private var resetNotice = ""
    @State private var confirmDelete = false
    @State private var saving = false
    @State private var error = ""

    init(user: OrbAdminUser, isSoleActiveAdmin: Bool, client: OrbSettingsClient, onChanged: @escaping () -> Void) {
        self.user = user
        self.isSoleActiveAdmin = isSoleActiveAdmin
        self.client = client
        self.onChanged = onChanged
        _role = State(initialValue: user.role)
        _unixUsername = State(initialValue: user.unixUsername ?? OrbUsersModel.defaultUnixUsernameFor(user.username))
        _dailyCapUsd = State(initialValue: user.dailySpendCapCents.map { String(format: "%.2f", Double($0) / 100.0) } ?? "")
        _disabled = State(initialValue: user.disabled)
    }

    private var isSelf: Bool {
        OrbCore.shared.currentUser?.id == user.id
    }

    var body: some View {
        NavigationStack {
            Form {
                if !error.isEmpty {
                    Section { Text(error).font(.footnote).foregroundStyle(OrbStyle.error) }
                }
                if !resetNotice.isEmpty {
                    Section { Text(resetNotice).font(.footnote).foregroundStyle(OrbStyle.success) }
                }
                Section("Account") {
                    LabeledContent("Username", value: "@\(user.username)")
                    Picker("Role", selection: $role) {
                        Text("Member").tag("member")
                        Text("Admin").tag("admin")
                    }
                    .disabled(isSoleActiveAdmin)
                    Toggle("Disable sign-in", isOn: $disabled)
                        .disabled(isSoleActiveAdmin || isSelf)
                }
                Section("Linux confinement") {
                    TextField("orb-user", text: $unixUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                }
                Section("Daily spend") {
                    LabeledContent("Spent today", value: OrbUsersModel.formatUsdFromCents(user.spentTodayCents))
                    TextField("Unlimited (USD / day)", text: $dailyCapUsd)
                        .keyboardType(.decimalPad)
                }
                Section("Reset password") {
                    SecureField("New password (8+ chars)", text: $newPassword)
                        .textContentType(.newPassword)
                    Button("Set temporary password") {
                        Task { await resetPassword() }
                    }
                    .disabled(saving || newPassword.count < 8)
                }
                if !isSoleActiveAdmin && !isSelf {
                    Section {
                        Button("Delete user…", role: .destructive) {
                            confirmDelete = true
                        }
                        .disabled(saving)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(OrbStyle.background)
            .navigationTitle("@\(user.username)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(saving)
                }
            }
            .alert("Delete @\(user.username)?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { Task { await deleteUser() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Revokes active sessions and removes this user account.")
            }
        }
    }

    private func save() async {
        let cleanUnix = unixUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OrbUsersModel.validUnixUsername(cleanUnix) else {
            error = "Enter a valid non-reserved POSIX Linux username."
            return
        }
        guard let parsedCap = OrbUsersModel.parseUsdToCents(dailyCapUsd) else {
            error = "Enter a valid non-negative USD daily cap."
            return
        }
        saving = true
        error = ""
        defer { saving = false }
        do {
            let body: [String: OrbJSON] = [
                "role": .string(role),
                "unix_username": .string(cleanUnix),
                "disabled": .bool(disabled),
                "daily_spend_cap_cents": parsedCap.map { .number(Double($0)) } ?? .null,
            ]
            _ = try await client.call("/api/admin/users/\(OrbCore.escape(user.id))", method: "PATCH", body: .object(body))
            if isSelf { await OrbCore.shared.refreshCurrentUser() }
            onChanged()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func resetPassword() async {
        guard newPassword.count >= 8 else { return }
        saving = true
        error = ""
        resetNotice = ""
        defer { saving = false }
        do {
            _ = try await client.call(
                OrbUsersModel.resetPasswordPath(for: user.id),
                method: "POST",
                body: .object(["password": .string(newPassword), "new_password": .string(newPassword)])
            )
            newPassword = ""
            resetNotice = "Password updated and active sessions rotated."
            onChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteUser() async {
        saving = true
        error = ""
        defer { saving = false }
        do {
            _ = try await client.call("/api/admin/users/\(OrbCore.escape(user.id))", method: "DELETE")
            onChanged()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
