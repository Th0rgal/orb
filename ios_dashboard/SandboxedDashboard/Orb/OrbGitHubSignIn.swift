import CryptoKit
import Foundation
import Security
import SwiftUI
import UIKit

/// Guards the `sandboxed://auth/callback?token=` deep link, matching Android `OrbGitHubSignIn.kt`
/// and desktop `orb/src/githubSignIn.ts`.
final class OrbGitHubSignIn: @unchecked Sendable {
    protocol Store: AnyObject {
        func load() -> Pending?
        func save(_ pending: Pending?)
    }

    struct Pending: Codable, Equatable, Sendable {
        let endpoint: String
        let startedAtMs: Int64
        let state: String?
    }

    enum Decision: Equatable, Sendable {
        case accept(endpoint: String, token: String)
        case reject(reason: String)
    }

    struct CallbackQuery: Equatable, Sendable {
        let token: String?
        let error: String?
        let state: String?
    }

    static let maxAgeMs: Int64 = 10 * 60 * 1000
    static let redirectURI = "sandboxed://auth/callback"
    static let validatePath = "/api/auth/status"

    private let store: Store
    private let clock: () -> Int64

    init(store: Store = UserDefaultsStore.shared, clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.store = store
        self.clock = clock
    }

    static func normalize(_ endpoint: String) -> String {
        endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    /// 32 random bytes as URL-safe base64 without padding (43 chars, within Core's 16..128 limit).
    static func newState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func serverEchoesState(_ health: OrbJSON) -> Bool {
        health["github_oauth_client_state"].flag
    }

    static func isCallbackURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "sandboxed" &&
            url.host?.lowercased() == "auth" &&
            (url.path == "/callback" || url.path.isEmpty)
    }

    static func parseCallback(_ url: URL) -> CallbackQuery {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func val(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        return CallbackQuery(token: val("token"), error: val("error"), state: val("state"))
    }

    static func authorizeURL(baseURL: String, state: String) -> URL? {
        let clean = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var comps = URLComponents(string: "\(clean)/api/auth/github/start"),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              comps.host?.isEmpty == false else {
            return nil
        }
        comps.queryItems = [
            URLQueryItem(name: "redirect", value: redirectURI),
            URLQueryItem(name: "state", value: state)
        ]
        return comps.url
    }

    @discardableResult
    func begin(endpoint: String, state: String = OrbGitHubSignIn.newState()) -> String {
        store.save(Pending(endpoint: Self.normalize(endpoint), startedAtMs: clock(), state: state))
        return state
    }

    func isPending(endpoint: String) -> Bool {
        guard let pending = store.load() else { return false }
        let age = clock() - pending.startedAtMs
        return age >= 0 && age <= Self.maxAgeMs && pending.endpoint == Self.normalize(endpoint)
    }

    func onCallback(
        currentEndpoint: String,
        token: String?,
        error: String?,
        state: String? = nil,
        serverEchoesState: Bool = false
    ) -> Decision {
        let pending = store.load()
        store.save(nil)
        guard let pending else { return .reject(reason: "no sign-in in progress") }
        let age = clock() - pending.startedAtMs
        if age < 0 || age > Self.maxAgeMs { return .reject(reason: "sign-in expired") }
        if pending.endpoint != Self.normalize(currentEndpoint) { return .reject(reason: "endpoint changed") }
        let got = (state?.isEmpty == false) ? state : nil
        if got != nil || serverEchoesState {
            guard let expected = pending.state, !expected.isEmpty else {
                return .reject(reason: "state not recorded")
            }
            guard let got else {
                return .reject(reason: "missing state")
            }
            if !Self.constantTimeEqual(expected, got) {
                return .reject(reason: "state mismatch")
            }
        }
        if let err = error?.trimmingCharacters(in: .whitespacesAndNewlines), !err.isEmpty {
            return .reject(reason: "server error: \(err)")
        }
        guard let clean = token?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty else {
            return .reject(reason: "missing token")
        }
        return .accept(endpoint: pending.endpoint, token: clean)
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in ab.indices {
            diff |= ab[i] ^ bb[i]
        }
        return diff == 0
    }

    final class UserDefaultsStore: Store, @unchecked Sendable {
        static let shared = UserDefaultsStore()
        private let key = "orb.githubSignIn.pending"
        func load() -> Pending? {
            guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(Pending.self, from: data)
        }
        func save(_ pending: Pending?) {
            if let pending, let data = try? JSONEncoder().encode(pending) {
                UserDefaults.standard.set(data, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    final class MemoryStore: Store {
        var value: Pending?
        init(_ value: Pending? = nil) { self.value = value }
        func load() -> Pending? { value }
        func save(_ pending: Pending?) { value = pending }
    }

    /// Validates an issued bearer token directly against `GET /api/auth/status` before storing it.
    static func validateIssuedToken(endpoint: String, token: String) async -> Bool {
        let cleanBase = endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(cleanBase)\(validatePath)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }
}

/// Deterministic multipart archive builder and retention parser shared with `OrbDebugInfoView` and tests.
enum OrbBackupArchive {
    struct MultipartPayload: Sendable {
        let body: Data
        let contentType: String
        let sha256Hex: String
    }

    static func buildRestoreMultipart(
        zipData: Data,
        filename: String = "orb-backup.zip",
        boundary: String = "----OrbRestore\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    ) -> MultipartPayload {
        let safeName = filename
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let safeNameFinal = safeName.isEmpty ? "orb-backup.zip" : safeName
        let head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"backup\"; filename=\"\(safeNameFinal)\"\r\nContent-Type: application/zip\r\n\r\n"
        let tail = "\r\n--\(boundary)--\r\n"
        var body = Data(head.utf8)
        body.append(zipData)
        body.append(Data(tail.utf8))
        let sha = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return MultipartPayload(
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            sha256Hex: sha
        )
    }

    static func parseCleanupDays(_ raw: String) -> Result<Int, OrbHTTPError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber), let n = Int(trimmed) else {
            return .failure(OrbHTTPError(status: 0, detail: "Retention days must be a whole number between 1 and 365."))
        }
        guard (1...365).contains(n) else {
            return .failure(OrbHTTPError(status: 0, detail: "Retention days must be between 1 and 365."))
        }
        return .success(n)
    }

    static func interpretRestoreResponse(_ res: OrbJSON) -> (ok: Bool, message: String) {
        let success = res["success"].flag
        let restored = res["restored_files"].items.map(\.text).filter { !$0.isEmpty }
        let errors = res["errors"].items.map(\.text).filter { !$0.isEmpty }
        let rawMessage = res["message"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !success {
            let base = rawMessage.isEmpty
                ? "No files were restored. The backup may be empty or invalid."
                : rawMessage
            return (
                ok: false,
                message: errors.isEmpty ? base : "\(base) (\(errors.joined(separator: "; ")))"
            )
        }
        let summary = !rawMessage.isEmpty
            ? rawMessage
            : (restored.isEmpty ? "Backup restored." : "Restored \(restored.count) files (\(restored.joined(separator: ", "))).")
        return (ok: true, message: summary)
    }
}

/// Single-tenant server password rotation (`GET /api/auth/status`, `POST /api/auth/change-password`).
struct OrbChangePasswordSheet: View {
    var onSaved: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var requiresCurrent = true
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(OrbStyle.error) }
                }
                Section {
                    if requiresCurrent {
                        SecureField("Current password", text: $currentPassword)
                            .textContentType(.password)
                    }
                    SecureField("New password (at least 8 characters)", text: $newPassword)
                        .textContentType(.newPassword)
                    SecureField("Confirm new password", text: $confirmPassword)
                        .textContentType(.newPassword)
                } footer: {
                    Text("Updates the password stored on Core for single-tenant sign-in.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(OrbStyle.background)
            .navigationTitle("Change password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Update") {
                        Task { await submit() }
                    }
                    .disabled(saving || newPassword.isEmpty)
                }
            }
            .task {
                if let st = try? await OrbCore.shared.call("/api/auth/status") {
                    requiresCurrent = !st["dev_mode"].flag && st["password_source"].text != "none"
                }
            }
        }
    }

    private func submit() async {
        if requiresCurrent && currentPassword.isEmpty {
            error = "Enter your current password."
            return
        }
        if newPassword.count < 8 {
            error = "New password must be at least 8 characters."
            return
        }
        if newPassword != confirmPassword {
            error = "New passwords do not match."
            return
        }
        saving = true
        error = nil
        defer { saving = false }
        do {
            var body: [String: OrbJSON] = ["new_password": .string(newPassword)]
            if requiresCurrent {
                body["current_password"] = .string(currentPassword)
            }
            let res = try await OrbCore.shared.call("/api/auth/change-password", method: "POST", body: .object(body))
            if OrbKeychain.credentials(for: OrbCore.shared.baseURL) != nil {
                OrbKeychain.saveCredentials(.init(password: newPassword, username: nil), for: OrbCore.shared.baseURL)
            }
            let msg = res["message"].text.isEmpty ? "Server password updated." : res["message"].text
            onSaved(msg)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// GitHub device-flow integration (`Settings → Account`) for `git push` and `gh` inside mission workspaces.
struct OrbGitHubIntegrationSection: View {
    @State private var status: OrbJSON?
    @State private var authorizeState: OrbJSON?
    @State private var busy = false
    @State private var copied = false
    @State private var confirmDisconnect = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GitHub mission credentials").font(.subheadline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(titleText).font(.subheadline.weight(.medium))
                        Text(subtitleText).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if status?["connected"].flag == true {
                        Button("Disconnect", role: .destructive) { confirmDisconnect = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(busy)
                    } else {
                        Button(busy ? "Starting…" : (authorizeState != nil ? "Restart" : "Connect")) {
                            Task { await startDeviceFlow() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(busy || (status?["configured"] != .null && status?["configured"].flag == false))
                    }
                }

                if let auth = authorizeState {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Enter code \(auth["user_code"].text) at GitHub to finish connecting.")
                            .font(.footnote.monospaced())
                        HStack(spacing: 8) {
                            Button(copied ? "Copied" : "Copy code") {
                                UIPasteboard.general.string = auth["user_code"].text
                                copied = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            if let url = URL(string: auth["verification_uri"].text) {
                                Button("Open GitHub") {
                                    UIApplication.shared.open(url)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                    }
                }

                if let error {
                    Text(error).font(.footnote).foregroundStyle(OrbStyle.error)
                }
            }
            .padding(14)
            .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: 14))
        }
        .alert("Disconnect GitHub?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { Task { await disconnect() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove stored GitHub mission credentials from Core? Running or new missions will no longer receive this GitHub token.")
        }
        .task { await refresh() }
        .task(id: authorizeState?["user_code"].text ?? "") {
            guard authorizeState != nil else { return }
            let secs = max(4, Int(authorizeState?["interval"].number ?? 5))
            while !Task.isCancelled && authorizeState != nil {
                try? await Task.sleep(for: .seconds(secs))
                guard !Task.isCancelled else { break }
                if let s = try? await OrbCore.shared.call("/api/integrations/github/status") {
                    status = s
                    if s["connected"].flag {
                        authorizeState = nil
                        break
                    }
                }
            }
        }
    }

    private var titleText: String {
        guard let status else { return "Checking GitHub status…" }
        if status["connected"].flag {
            let name = status["login"].text.isEmpty ? status["user"]["login"].text : status["login"].text
            return name.isEmpty ? "Connected to GitHub" : "Connected as @\(name)"
        }
        return "GitHub account"
    }

    private var subtitleText: String {
        guard let status else { return "Credentials for git push and gh inside mission workspaces." }
        if status["connected"].flag {
            let scopeList = status["scopes"].items.map(\.text).filter { !$0.isEmpty }
            let scopes = scopeList.isEmpty ? status["scopes"].text : scopeList.joined(separator: ", ")
            return scopes.isEmpty ? "Available to mission workspaces." : "Scopes: \(scopes)"
        }
        if status["configured"] != .null && !status["configured"].flag {
            return "Configure GITHUB_OAUTH_CLIENT_ID on Core to connect."
        }
        return "Authorize git push and gh inside mission workspaces via GitHub device flow."
    }

    private func refresh() async {
        do {
            let s = try await OrbCore.shared.call("/api/integrations/github/status")
            status = s
            if s["connected"].flag {
                authorizeState = nil
            } else if s["pending"].flag && !s["user_code"].text.isEmpty && authorizeState == nil {
                authorizeState = s
            }
        } catch is CancellationError {} catch {
            // Optional on older servers; surface errors only on explicit user action.
        }
    }

    private func startDeviceFlow() async {
        busy = true
        error = nil
        copied = false
        defer { busy = false }
        do {
            let res = try await OrbCore.shared.call("/api/integrations/github/authorize", method: "POST")
            authorizeState = res
            UIPasteboard.general.string = res["user_code"].text
            copied = true
            if let url = URL(string: res["verification_uri"].text) {
                await UIApplication.shared.open(url)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func disconnect() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            _ = try await OrbCore.shared.call("/api/integrations/github", method: "DELETE")
            authorizeState = nil
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
