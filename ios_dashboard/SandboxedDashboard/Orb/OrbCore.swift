import Foundation
import Security
import CryptoKit

/// Lossless wire values for provider-specific capabilities and model parameters.
indirect enum OrbJSON: Codable, Sendable, Equatable {
    case object([String: OrbJSON]), array([OrbJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([OrbJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: OrbJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> OrbJSON { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var text: String { if case .string(let v) = self { return v }; return "" }
    var items: [OrbJSON] { if case .array(let v) = self { return v }; return [] }
    var flag: Bool { if case .bool(let v) = self { return v }; return false }
    var doubleValue: Double? { if case .number(let v) = self { return v }; return nil }
}

/// Remote placement can be reported by either the mission or its current job.
enum OrbContinuation {
    static func remoteNodeID(for mission: OrbJSON, fallback: String = "") -> String {
        let candidates = [
            mission["remote_job"]["node_id"].text,
            mission["remote_node_id"].text,
            mission["execution"]["scope_unit"].text.hasPrefix("remote-node:")
                ? String(mission["execution"]["scope_unit"].text.dropFirst("remote-node:".count).split(separator: ":").first ?? "")
                : "",
            fallback
        ]
        for raw in candidates {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "core"
    }

    static func identity(for mission: OrbJSON) -> OrbJSON? {
        guard !mission["track"].text.isEmpty,
              mission["remote_node_id"].text.isEmpty,
              mission["remote_job"] == .null,
              !mission["execution"]["scope_unit"].text.hasPrefix("remote-node:") else { return nil }
        return .object(["project": mission["project"], "track": mission["track"], "github_pr": mission["github_pr"]])
    }
}

struct OrbRow: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let state: String
    let folder: String
    let backend: String
    let cloud: Bool
    let updatedAt: String
    let raw: OrbJSON
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.raw == rhs.raw }
    func hash(into h: inout Hasher) { h.combine(id) }
    init(_ value: OrbJSON, project: Bool = false) {
        raw = value
        id = value[project ? "slug" : "id"].text
        // Forks share the conversation's name; older forks were titled "… · fork".
        let title = value["title"].text
        name = title.isEmpty ? id : (title.hasSuffix(" · fork") ? String(title.dropLast(7)) : title)
        state = value["status"].text
        folder = value["tags"].items.map(\.text).first(where: { $0.hasPrefix("orb-folder:") }).map { String($0.dropFirst(11)) } ?? ""
        backend = value["backend"].text
        cloud = value["backend"].text.hasPrefix("cloud_") || value["execution_kind"].text == "cloud" || value["tags"].items.contains(where: { $0.text.hasPrefix("cloud:") }) || value["cloud"] != .null
        updatedAt = value["updated_at"].text.isEmpty ? value["created_at"].text : value["updated_at"].text
    }
    /// The conversation this one was forked from (a `fork-of:` tag, or an older fork stored as a child).
    var forkSource: String? {
        if let tag = raw["tags"].items.map(\.text).first(where: { $0.hasPrefix("fork-of:") }) { return String(tag.dropFirst(8)) }
        let p = raw["parent_mission_id"].text
        return !p.isEmpty && raw["title"].text.hasSuffix(" · fork") ? p : nil
    }
    /// The mission that launched this one. A fork is another version, never launched work.
    /// Sticky (docs/specs/sidebar-hierarchy.md): a payload without the link never
    /// moves a known child to the root; only `OrbHierarchy.reparent` changes it.
    var parentMissionID: String? {
        if let found = payloadParentID { OrbHierarchy.remember(id, parent: found); return found }
        return OrbHierarchy.parent(of: id)
    }
    private var payloadParentID: String? {
        let p = raw["parent_mission_id"].text
        if !p.isEmpty && forkSource != p { return p }
        let cp = raw["callback_parent_mission_id"].text
        return cp.isEmpty ? nil : cp
    }
    var mobile: Bool { !raw["tags"].items.contains(where: { $0.text.hasPrefix("btw-parent:") }) }
    var active: Bool { missionState?.isActive ?? false }
}

/// Parent links remembered across payloads, so a partial answer cannot un-nest a child.
enum OrbHierarchy {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var parents: [String: String] = [:]
    static func remember(_ id: String, parent: String) {
        guard !id.isEmpty else { return }
        lock.lock(); parents[id] = parent; lock.unlock()
    }
    static func parent(of id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return parents[id]
    }
    /// Explicit re-parent (nil detaches): the only way a remembered parent changes.
    static func reparent(_ id: String, parent: String?) {
        lock.lock(); parents[id] = parent; lock.unlock()
    }
    static func reset() { lock.lock(); parents.removeAll(); lock.unlock() }
}

struct OrbNestedMission: Identifiable, Hashable {
    let mission: OrbRow
    var children: [OrbNestedMission]
    /// An earlier version (fork) of the conversation it is listed in.
    var version: Bool
    var id: String { mission.id }
    init(mission: OrbRow, children: [OrbNestedMission] = [], version: Bool = false) {
        self.mission = mission
        self.children = children
        self.version = version
    }
}

enum OrbMissionTree {
    /// Keep archived/completed parents as context for visible child workers without restoring all archived missions.
    static func treeRows(_ missions: [OrbRow], visible: (OrbRow) -> Bool) -> [OrbRow] {
        var byID: [String: OrbRow] = [:]
        for m in missions where byID[m.id] == nil { byID[m.id] = m }
        var retained = Set(missions.filter(visible).map(\.id))
        for mission in missions where visible(mission) {
            var seen: Set<String> = [mission.id]
            var parent = mission.parentMissionID
            while let p = parent, !seen.contains(p) {
                seen.insert(p)
                guard let row = byID[p] else { break }
                retained.insert(p)
                parent = row.parentMissionID
            }
        }
        return missions.filter { retained.contains($0.id) }
    }

    /// Maps each listed fork to the most recently active version of its conversation.
    static func forkLeaders(_ missions: [OrbRow]) -> [String: OrbRow] {
        var byID: [String: OrbRow] = [:]
        for mission in missions where byID[mission.id] == nil { byID[mission.id] = mission }
        func root(_ mission: OrbRow) -> String {
            var current = mission
            var seen: Set<String> = []
            while let source = current.forkSource, let next = byID[source], !seen.contains(source) {
                seen.insert(current.id)
                current = next
            }
            return current.id
        }
        var groups: [String: [OrbRow]] = [:]
        for mission in missions { groups[root(mission), default: []].append(mission) }
        var leaders: [String: OrbRow] = [:]
        for group in groups.values where group.count > 1 {
            let leader = group.max { $0.updatedAt < $1.updatedAt }!
            for mission in group { leaders[mission.id] = leader }
        }
        return leaders
    }

    /// Roots keep the order of the list, and so do the children of each mission.
    /// The most recently active version of a forked conversation leads; earlier
    /// versions are listed inside it after its launched work.
    static func nest(_ missions: [OrbRow]) -> [OrbNestedMission] {
        var byID: [String: OrbRow] = [:]
        for mission in missions where byID[mission.id] == nil {
            byID[mission.id] = mission
        }
        let leaders = forkLeaders(missions)
        var versionsByLeader: [String: [OrbRow]] = [:]
        var childrenByParent: [String: [OrbRow]] = [:]
        var roots: [OrbRow] = []
        for mission in missions {
            if let leader = leaders[mission.id], leader.id != mission.id {
                versionsByLeader[leader.id, default: []].append(mission)
                continue
            }
            // A leading fork takes the place of the conversation it continues.
            let place = leaders[mission.id].flatMap { leader in missions.first { leaders[$0.id]?.id == leader.id && $0.forkSource == nil } } ?? mission
            if let parentID = place.parentMissionID,
               let parent = byID[parentID],
               parent.id != mission.id,
               !reaches(byID: byID, from: parent, target: mission.id) {
                childrenByParent[parentID, default: []].append(mission)
            } else {
                roots.append(mission)
            }
        }
        func build(_ row: OrbRow, visited: Set<String>) -> OrbNestedMission {
            var nextVisited = visited
            nextVisited.insert(row.id)
            let kids = (childrenByParent[row.id] ?? []).filter { !nextVisited.contains($0.id) }.map { build($0, visited: nextVisited) }
            let versions = (versionsByLeader[row.id] ?? []).sorted { $0.updatedAt > $1.updatedAt }.map { version -> OrbNestedMission in
                var node = build(version, visited: nextVisited)
                node.version = true
                return node
            }
            return OrbNestedMission(mission: row, children: kids + versions)
        }
        return roots.map { build($0, visited: []) }
    }

    private static func reaches(byID: [String: OrbRow], from: OrbRow, target: String) -> Bool {
        var seen: Set<String> = []
        var current: OrbRow? = from
        while let cur = current, !seen.contains(cur.id) {
            if cur.id == target { return true }
            seen.insert(cur.id)
            if let p = cur.parentMissionID {
                current = byID[p]
            } else {
                current = nil
            }
        }
        return false
    }

    static func countNested(_ node: OrbNestedMission, matches: (OrbRow) -> Bool = { _ in true }) -> Int {
        node.children.reduce(0) { sum, child in
            child.version ? sum : sum + (matches(child.mission) ? 1 : 0) + countNested(child, matches: matches)
        }
    }

    static func countVersions(_ node: OrbNestedMission) -> Int { node.children.filter(\.version).count }

    static func subtree(_ missions: [OrbRow], rootIDs: [String]) -> [OrbRow] {
        var included = Set(rootIDs)
        var added = true
        while added {
            added = false
            for mission in missions where !included.contains(mission.id) {
                if let parent = mission.parentMissionID, included.contains(parent) {
                    included.insert(mission.id)
                    added = true
                }
            }
        }
        return missions.filter { included.contains($0.id) }
    }

    static func filterArchivedByAge(_ rows: [OrbRow], maxAgeSeconds: TimeInterval?, now: Date = Date()) -> [OrbRow] {
        guard let maxAgeSeconds else { return rows }
        let cutoff = now.addingTimeInterval(-maxAgeSeconds)
        return rows.filter { row in
            guard let date = OrbStyle.parseDate(row.updatedAt) else { return false }
            return date <= cutoff
        }
    }
}

enum OrbKeychain {
    struct Credentials: Codable { let password: String; let username: String? }
    static func credentials(for endpoint: String) -> Credentials? {
        guard let text = token(for: endpoint, service: "md.thomas.orb.credentials"), let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }
    @discardableResult static func saveCredentials(_ value: Credentials?, for endpoint: String) -> Bool {
        guard let value else { return save(nil, for: endpoint, service: "md.thomas.orb.credentials") }
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return false }
        return save(text, for: endpoint, service: "md.thomas.orb.credentials")
    }
    static func token(for endpoint: String, service: String = "md.thomas.orb.core") -> String? {
        var query = base(endpoint, service: service)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    @discardableResult static func save(_ value: String?, for endpoint: String, service: String = "md.thomas.orb.core") -> Bool {
        let query = base(endpoint, service: service)
        guard let value else { let code = SecItemDelete(query as CFDictionary); return code == errSecSuccess || code == errSecItemNotFound }
        let data = Data(value.utf8)
        let attributes: [CFString: Any] = [kSecValueData: data]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecSuccess { return true }
        _ = SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData] = data
        insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
    private static func base(_ endpoint: String, service: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: endpoint]
    }
}

/// Persist the exact request before submitting. An uncertain response never creates a new identity.
struct OrbPending: Codable, Sendable {
    let path: String
    let body: OrbJSON
}

private actor OrbDiskWriter {
    static let shared = OrbDiskWriter()
    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func read(from url: URL) -> Data? {
        try? Data(contentsOf: url)
    }
}

@MainActor
enum OrbDisk {
    private static var urlCache: [String: URL] = [:]
    static func url(_ key: String, accountScope: String? = nil) -> URL {
        let scope = (accountScope ?? (OrbCore.shared.endpoint + ":" + (OrbCore.shared.authToken ?? ""))) + ":" + key
        if let cached = urlCache[scope] { return cached }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orb")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        let result = root.appendingPathComponent(name + ".json")
        if urlCache.count > 1024 { urlCache.removeAll(keepingCapacity: true) }
        urlCache[scope] = result
        return result
    }
    static func read<T: Decodable>(_ key: String, as type: T.Type, accountScope: String? = nil) -> T? {
        guard let data = try? Data(contentsOf: url(key, accountScope: accountScope)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func readAsync<T: Decodable & Sendable>(_ key: String, as type: T.Type) async -> T? {
        let target = url(key)
        guard let data = await OrbDiskWriter.shared.read(from: target) else { return nil }
        return await Task.detached(priority: .utility) {
            try? JSONDecoder().decode(type, from: data)
        }.value
    }
    static func save<T: Encodable>(_ value: T, key: String) throws {
        try JSONEncoder().encode(value).write(to: url(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func saveAsync<T: Encodable & Sendable>(_ value: T, key: String, accountScope: String? = nil) {
        let target = url(key, accountScope: accountScope)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? await OrbDiskWriter.shared.write(data, to: target)
        }
    }
    static func remove(_ key: String) { try? FileManager.default.removeItem(at: url(key)) }
}

/// Account-scoped, bounded read-through cache. In-flight loads are shared with navigation.
@MainActor
enum OrbReadCache {
    private struct Entry { let value: OrbJSON; let date: Date }
    private static var values: [String: Entry] = [:]
    private static var eventValues: [String: [StoredEvent]] = [:]
    private static var eventFetchedAt: [String: Date] = [:]
    private static var eventPending: [String: Task<[StoredEvent], Error>] = [:]
    /// Network source for `events(_:)`; tests replace it.
    static var eventsFetcher: @MainActor (_ missionID: String, _ limit: Int) async throws -> [StoredEvent] = { id, limit in
        try await OrbCore.shared.getMissionEventsWithMeta(id: id, limit: limit, sinceSeq: nil).events
    }
    private struct Pending { let id = UUID(); let task: Task<OrbJSON, Error> }
    private static var pending: [String: Pending] = [:]
    private static func key(_ name: String) -> String { OrbDisk.url(name).absoluteString }
    static func read(_ name: String) -> OrbJSON? {
        let scope = key(name)
        if let cached = values[scope]?.value { return cached }
        if let disk = OrbDisk.read(name, as: OrbJSON.self) {
            values[scope] = Entry(value: disk, date: .distantPast)
            return disk
        }
        return nil
    }
    /// Navigation must not decode a long transcript or project roster on the main actor.
    static func readAsync(_ name: String) async -> OrbJSON? {
        let scope = key(name)
        if let cached = values[scope]?.value { return cached }
        let disk = await OrbDisk.readAsync(name, as: OrbJSON.self)
        guard scope == key(name), !Task.isCancelled else { return nil }
        // A network response may have arrived while disk decoding was in flight.
        if let cached = values[scope]?.value { return cached }
        if let disk { values[scope] = Entry(value: disk, date: .distantPast) }
        return disk
    }
    static func seedMemory(_ name: String, value: OrbJSON) {
        let scope = key(name)
        // List rows do not own conversation history. In particular, after memory
        // trimming they must not mask the full conversation still saved on disk.
        if name.hasPrefix("mission:"), value["history"].items.isEmpty { return }
        if values.count >= 256, let oldest = values.min(by: { $0.value.date < $1.value.date })?.key { values[oldest] = nil }
        values[scope] = Entry(value: value, date: Date())
    }
    static func seed(_ name: String, value: OrbJSON) {
        if name.hasPrefix("mission:"), value["history"].items.isEmpty { return }
        seedMemory(name, value: value)
        OrbDisk.saveAsync(value, key: name)
    }
    static func seedFromGlobalMissions(_ rawMissions: [OrbJSON]) {
        var byProject: [String: [OrbJSON]] = [:]
        for item in rawMissions {
            let mid = item["id"].text
            if !mid.isEmpty {
                seedMemory("mission:\(mid)", value: item)
            }
            let proj = item["project"].text
            if !proj.isEmpty {
                byProject[proj, default: []].append(item)
            }
        }
        for (proj, list) in byProject {
            let cacheName = "project:\(proj)"
            let scope = key(cacheName)
            if values[scope] == nil && read(cacheName) == nil {
                values[scope] = Entry(
                    value: .object(["missions": .array(list), "manifest": .null]),
                    date: Date().addingTimeInterval(-25) // allow quick display while still refreshing
                )
            }
        }
    }
    static func readMemoryEvents(_ missionID: String) -> [StoredEvent] {
        let cacheName = "events:\(missionID)"
        let scope = key(cacheName)
        return eventValues[scope] ?? []
    }
    static func readEvents(_ missionID: String) -> [StoredEvent] {
        let cacheName = "events:\(missionID)"
        let scope = key(cacheName)
        if let cached = eventValues[scope] { return cached }
        if let disk = OrbDisk.read(cacheName, as: [StoredEvent].self)?.map(\.compacted) {
            eventValues[scope] = disk
            return disk
        }
        return []
    }
    static func readEventsAsync(_ missionID: String) async -> [StoredEvent] {
        let cacheName = "events:\(missionID)"
        let scope = key(cacheName)
        if let cached = eventValues[scope] { return cached }
        let disk = await OrbDisk.readAsync(cacheName, as: [StoredEvent].self)
        guard scope == key(cacheName), !Task.isCancelled else { return [] }
        if let cached = eventValues[scope] { return cached }
        let events = (disk ?? []).map(\.compacted)
        if !events.isEmpty { eventValues[scope] = events }
        return events
    }
    static func saveEvents(_ missionID: String, events: [StoredEvent]) {
        let cacheName = "events:\(missionID)"
        let scope = key(cacheName)
        if eventValues.count >= 48, let firstKey = eventValues.keys.first {
            eventValues.removeValue(forKey: firstKey)
        }
        let capped = (events.count > 250 ? events.suffix(250) : events[...]).map(\.compacted)
        eventValues[scope] = capped
        OrbDisk.saveAsync(capped, key: cacheName)
    }
    /// The one way to fetch a mission's recent events: account-scoped, TTL-bounded, and
    /// concurrent callers share one request. Results also land in the disk cache.
    static func events(_ missionID: String, limit: Int = 120, ttl: TimeInterval = 30, force: Bool = false, now: @MainActor () -> Date = { Date() }) async throws -> [StoredEvent] {
        let scope = key("events:\(missionID)")
        if !force, let fetched = eventFetchedAt[scope], now().timeIntervalSince(fetched) < ttl, let cached = eventValues[scope] {
            return cached
        }
        if let task = eventPending[scope] { return try await task.value }
        let task = Task { @MainActor in try await eventsFetcher(missionID, limit) }
        eventPending[scope] = task
        defer { eventPending[scope] = nil }
        let events = try await task.value
        // The account may have changed while the request was in flight.
        guard scope == key("events:\(missionID)") else { throw CancellationError() }
        saveEvents(missionID, events: events)
        eventFetchedAt[scope] = now()
        return events.map(\.compacted)
    }
    static func load(_ name: String, ttl: TimeInterval = 30, force: Bool = false, fetch: @escaping @MainActor () async throws -> OrbJSON) async throws -> OrbJSON {
        let scope = key(name)
        if !force, let entry = values[scope], Date().timeIntervalSince(entry.date) < ttl { return entry.value }
        if let item = pending[scope] {
            let value = try await item.task.value
            guard scope == key(name) else { throw CancellationError() }
            return value
        }
        let task = Task { try await fetch() }
        let item = Pending(task: task)
        pending[scope] = item
        defer { if pending[scope]?.id == item.id { pending[scope] = nil } }
        let value = try await task.value
        // The account changed while this was in flight: the answer belongs to nobody.
        guard scope == key(name) else { throw CancellationError() }
        // Invalidated while in flight (a send): its waiters still get this answer, but it
        // is not cached, so the next load fetches fresh data. Throwing here surfaced as a
        // "Connection unavailable … cancelled" error after every send.
        guard pending[scope]?.id == item.id else { return value }
        if values.count >= 256, let oldest = values.min(by: { $0.value.date < $1.value.date })?.key { values[oldest] = nil }
        values[scope] = Entry(value: value, date: Date())
        OrbDisk.saveAsync(value, key: name)
        return value
    }
    /// Settings → Debug info → Clear caches: drops memory and disk copies for every account.
    static func clearAll() {
        for item in pending.values { item.task.cancel() }
        pending.removeAll()
        values.removeAll()
        eventValues.removeAll()
        eventFetchedAt.removeAll()
        for task in eventPending.values { task.cancel() }
        eventPending.removeAll()
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orb")
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            do { try FileManager.default.removeItem(at: file) } catch { Log.error(.cache, "clear cache file", path: file.lastPathComponent, error) }
        }
        Log.cache.notice("cleared \(files.count) cache files")
    }
    /// Drops memory copies (disk copies stay) so a suspended app is a small jetsam target.
    static func trimMemory() {
        values.removeAll()
        eventValues.removeAll()
        eventFetchedAt.removeAll()
    }
    static func invalidate(_ name: String) {
        let scope = key(name)
        pending[scope] = nil
        if let old = values[scope] { values[scope] = Entry(value: old.value, date: .distantPast) }
    }
    static func project(_ id: String, includeArchived: Bool = false, force: Bool = false) async throws -> OrbJSON {
        let cacheKey = includeArchived ? "project:\(id):all" : "project:\(id)"
        return try await load(cacheKey, force: force) {
            async let missions = OrbCore.shared.missions(id, includeArchived: includeArchived)
            async let manifest = OrbCore.shared.call("/api/projects/\(OrbCore.escape(id))/context/manifest")
            return try await .object(["missions": .array(missions.map(\.raw)), "manifest": manifest])
        }
    }
    static func conversation(_ id: String, force: Bool = false) async throws -> OrbJSON {
        try await load("mission:\(id)", force: force) {
            try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(id))")
        }
    }
    static func cloud(_ id: String, force: Bool = false) async throws -> OrbJSON {
        try await load("cloud:\(id)", force: force) {
            try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(id))/cloud")
        }
    }
    static func agentCatalog(force: Bool = false) async throws -> OrbJSON {
        try await load("catalog:agent", ttl: 120, force: force) {
            async let backends = OrbCore.shared.call("/api/backends")
            async let nodes = OrbCore.shared.call("/api/remote-nodes")
            async let models = OrbCore.shared.call("/api/providers/backend-models")
            return try await .object(["backends": backends, "nodes": nodes, "models": models])
        }
    }
    static func cloudAccounts(force: Bool = false) async throws -> OrbJSON {
        try await load("catalog:cloud:accounts", ttl: 90, force: force) {
            try await OrbCore.shared.call("/api/cloud/accounts")
        }
    }
    static func cloudOptions(_ endpoint: String, force: Bool = false) async throws -> OrbJSON {
        try await load("catalog:cloud:\(endpoint)", ttl: 120, force: force) {
            try await OrbCore.shared.call("/api/cloud/\(endpoint)/options")
        }
    }
    static func prefetch(_ rows: [OrbRow]) async {
        let tasks: [Task<Void, Never>] = rows.prefix(5).map { row in
            Task { @MainActor in
                guard !Task.isCancelled else { return }
                if row.raw != .null && !row.raw["history"].items.isEmpty {
                    seedMemory("mission:\(row.id)", value: row.raw)
                } else {
                    _ = try? await conversation(row.id)
                }
                if row.cloud {
                    _ = try? await cloud(row.id)
                } else if readEvents(row.id).isEmpty {
                    _ = await Log.attempt(.cache, "events prefetch", path: row.id) { try await events(row.id, limit: 150) }
                }
            }
        }
        for t in tasks {
            await t.value
        }
    }
}

/// Small snapshots stay separate from full history and its paging cursor.
@MainActor enum OrbPresentation {
    private static var recent: [String] = []
    private static var pending: Set<String> = []
    private static var listChanged = false
    private static var labels: [String: String] = [:]
    static func activity(_ id: String?) -> String? { id.flatMap { labels[scope + ":" + $0] } }
    private static var scope: String { OrbCore.shared.endpoint + ":" + (OrbCore.shared.authToken ?? "") }
    private static var rememberedScope = ""
    private static func ensureScope() {
        guard rememberedScope != scope else { return }
        rememberedScope = scope
        recent.removeAll(); pending.removeAll(); labels.removeAll(); listChanged = false
    }
    static func remember(_ id: String) {
        ensureScope()
        recent.removeAll { $0 == id }; recent.append(id)
        if recent.count > 12 { recent.removeFirst() }
    }
    static func history(_ snapshot: OrbJSON) -> [OrbJSON] {
        snapshot["events"].items.compactMap { event in
            let type = event["event_type"].text
            if case .bool(true) = event["metadata"]["queued"] { return nil }
            guard type == "assistant_message" || type == "user_message" else { return nil }
            return .object(["role": .string(type == "user_message" ? "user" : "assistant"), "content": event["content"]])
        }
    }
    static func load(_ id: String) async -> OrbJSON? {
        let account = scope
        guard let value = try? await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(id))/snapshot?profile=presentation"),
              value["profile"].text == "presentation", account == scope, !Task.isCancelled else { return nil }
        let previous = await OrbReadCache.readAsync("presentation:\(id)")
        guard account == scope, !Task.isCancelled else { return nil }
        if let previous, case .number(let old) = previous["revision"], case .number(let new) = value["revision"], old >= new { return previous }
        if labels.count >= 48 { labels.removeAll() }
        labels[scope + ":" + id] = value["activity"].text
        OrbReadCache.seed("presentation:\(id)", value: value)
        return value
    }
    static func monitor() async {
        while !Task.isCancelled {
            ensureScope()
            let account = scope
            let stream = OrbCore.shared.streamControl(missionId: nil, kinds: ["presentation"], preferWebSocket: false) { type, data in
                if type == "status" || type == "stream_lagged" { pending.formUnion(recent) }
                guard type == "mission_presentation", let id = data["mission_id"] as? String else { return }
                if (data["kind"] as? String) == "mission_activity" {
                    if recent.contains(id), let label = data["label"] as? String {
                        if labels.count >= 48 { labels.removeAll() }
                        labels[scope + ":" + id] = String(label.prefix(160))
                    }
                    return
                }
                labels[scope + ":" + id] = nil
                listChanged = true
                if recent.contains(id) { pending.insert(id) }
            }
            // Reconcile after a real reconnect, not on a polling timer.
            var closed = false
            let completion = Task { await stream.value; closed = true }
            pending.formUnion(recent)
            while !Task.isCancelled && account == scope && !closed {
                if listChanged {
                    listChanged = false
                    NotificationCenter.default.post(name: Notification.Name("OrbPresentationChanged"), object: nil)
                }
                let ids = Array(pending.prefix(3)); pending.subtract(ids)
                for id in ids { _ = await load(id) }
                try? await Task.sleep(for: .seconds(1))
            }
            stream.cancel(); completion.cancel()
            if !Task.isCancelled { try? await Task.sleep(for: .seconds(2)) }
        }
    }
}
