import SwiftUI

struct OrbDirectoryUser: Identifiable, Equatable {
    let id: String
    let username: String
    let role: String

    init?(_ j: OrbJSON) {
        let id = j["id"].text
        let username = j["username"].text
        guard !id.isEmpty, !username.isEmpty else { return nil }
        self.id = id
        self.username = username
        self.role = j["role"].text == "admin" ? "admin" : "member"
    }
}

struct OrbMissionShareItem: Identifiable, Equatable {
    var id: String { userID }
    let userID: String
    let username: String
    let role: String

    init?(_ j: OrbJSON) {
        let uid = j["user_id"].text.isEmpty ? j["id"].text : j["user_id"].text
        let username = j["username"].text
        guard !uid.isEmpty else { return nil }
        self.userID = uid
        self.username = username.isEmpty ? uid : username
        self.role = j["role"].text.isEmpty ? "participant" : j["role"].text
    }
}

enum OrbMissionSharing {
    @MainActor
    static func leaveSharedMission(missionID: String) async throws {
        let api = OrbCore.shared
        if api.currentUser == nil {
            await api.refreshCurrentUser()
        }
        guard let myID = api.currentUser?.id, !myID.isEmpty else {
            throw OrbHTTPError(status: 400, detail: "Current user identity is unavailable.")
        }
        _ = try await api.call(
            "/api/control/missions/\(OrbCore.escape(missionID))/shares/\(OrbCore.escape(myID))",
            method: "DELETE"
        )
        OrbReadCache.invalidate("mission:\(missionID)")
    }
}

struct OrbShareMissionSheet: View {
    let missionID: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var shares: [OrbMissionShareItem] = []
    @State private var directory: [OrbDirectoryUser] = []
    @State private var search = ""
    @State private var loading = true
    @State private var busyUserID: String?
    @State private var error = ""

    private let api = OrbCore.shared

    private var availableUsers: [OrbDirectoryUser] {
        let sharedIDs = Set(shares.map(\.userID))
        let myID = api.currentUser?.id ?? ""
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return directory.filter { u in
            u.id != myID && !sharedIDs.contains(u.id) && (q.isEmpty || u.username.localizedCaseInsensitiveContains(q))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !error.isEmpty {
                    Section { Text(error).font(.footnote).foregroundStyle(OrbStyle.error) }
                }
                Section {
                    if loading && shares.isEmpty {
                        ProgressView()
                    } else if shares.isEmpty {
                        Text("Only you can see this conversation.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(shares) { share in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("@\(share.username)")
                                        .font(.subheadline.weight(.medium))
                                    Text("Participant · can read and send follow-ups")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Remove", role: .destructive) {
                                    Task { await remove(share.userID) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(busyUserID != nil)
                            }
                        }
                    }
                } header: {
                    Text("Collaborators")
                } footer: {
                    Text("Participants can read messages, view files, and send follow-up turns, without access to your other projects or settings.")
                }

                Section("Add people") {
                    if !loading && availableUsers.isEmpty {
                        Text(search.isEmpty ? "No other users available to invite." : "No matching users.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(availableUsers) { user in
                        HStack {
                            Text("@\(user.username)")
                                .font(.subheadline)
                            Spacer()
                            Button(busyUserID == user.id ? "Adding…" : "Add") {
                                Task { await add(user) }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(busyUserID != nil)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Find user")
            .scrollContentBackground(.hidden)
            .background(OrbStyle.background)
            .navigationTitle(title.isEmpty ? "Share mission" : "Share “\(title)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            async let sharesReq = api.call("/api/control/missions/\(OrbCore.escape(missionID))/shares")
            async let dirReq = api.call("/api/users/directory")
            let (sharesVal, dirVal) = try await (sharesReq, dirReq)
            let rawShares = sharesVal["shares"] == .null ? sharesVal.items : sharesVal["shares"].items
            let rawUsers = dirVal["users"] == .null ? dirVal.items : dirVal["users"].items
            shares = rawShares.compactMap(OrbMissionShareItem.init)
            directory = rawUsers.compactMap(OrbDirectoryUser.init)
            error = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func add(_ user: OrbDirectoryUser) async {
        guard busyUserID == nil else { return }
        busyUserID = user.id
        defer { busyUserID = nil }
        do {
            _ = try await api.call(
                "/api/control/missions/\(OrbCore.escape(missionID))/shares",
                method: "POST",
                body: .object(["user_id": .string(user.id)])
            )
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove(_ userID: String) async {
        guard busyUserID == nil else { return }
        busyUserID = userID
        defer { busyUserID = nil }
        do {
            _ = try await api.call(
                "/api/control/missions/\(OrbCore.escape(missionID))/shares/\(OrbCore.escape(userID))",
                method: "DELETE"
            )
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
