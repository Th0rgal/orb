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
}

struct OrbRow: Identifiable, Hashable {
    let id: String
    let name: String
    let state: String
    let folder: String
    let backend: String
    let cloud: Bool
    let raw: OrbJSON
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.raw == rhs.raw }
    func hash(into h: inout Hasher) { h.combine(id) }
    init(_ value: OrbJSON, project: Bool = false) {
        raw = value
        id = value[project ? "slug" : "id"].text
        name = value["title"].text.isEmpty ? id : value["title"].text
        state = value["status"].text
        folder = value["tags"].items.map(\.text).first(where: { $0.hasPrefix("orb-folder:") }).map { String($0.dropFirst(11)) } ?? ""
        backend = value["backend"].text
        cloud = value["backend"].text.hasPrefix("cloud_") || value["execution_kind"].text == "cloud" || value["tags"].items.contains(where: { $0.text.hasPrefix("cloud:") }) || value["cloud"] != .null
    }
    var mobile: Bool { !raw["tags"].items.contains(where: { $0.text == "placement:client" || $0.text.hasPrefix("btw-parent:") }) }
    var active: Bool { ["active", "pending", "running", "starting"].contains(state) }
}

struct OrbHTTPError: LocalizedError {
    let status: Int
    let detail: String
    var errorDescription: String? { "\(status): \(detail)" }
}

enum OrbKeychain {
    static func token(for endpoint: String) -> String? {
        var query = base(endpoint)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    @discardableResult static func save(_ value: String?, for endpoint: String) -> Bool {
        let query = base(endpoint)
        guard let value else { let code = SecItemDelete(query as CFDictionary); return code == errSecSuccess || code == errSecItemNotFound }
        let attributes: [CFString: Any] = [kSecValueData: Data(value.utf8)]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecSuccess { return true }
        guard result == errSecItemNotFound else { return false }
        var insert = query
        insert[kSecValueData] = Data(value.utf8)
        insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
    private static func base(_ endpoint: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "md.thomas.orb.core", kSecAttrAccount: endpoint]
    }
}

@MainActor
final class OrbCore {
    static let shared = OrbCore()
    var endpoint: String { APIService.shared.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    func call(_ path: String, method: String = "GET", body: OrbJSON? = nil) async throws -> OrbJSON {
        guard let url = URL(string: endpoint + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("Bearer \(APIService.shared.authToken ?? "")", forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 {
            let api = APIService.shared
            if url.absoluteString.hasPrefix(endpoint + "/"),
               request.value(forHTTPHeaderField: "Authorization") == "Bearer \(api.authToken ?? "")" {
                api.markSessionExpired()
            }
            throw APIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else { throw OrbHTTPError(status: http.statusCode, detail: String(data: data, encoding: .utf8) ?? "Request failed") }
        return data.isEmpty ? .null : try JSONDecoder().decode(OrbJSON.self, from: data)
    }
    static func escape(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
    func missions(_ project: String) async throws -> [OrbRow] {
        var rows: [OrbRow] = [], offset = 0
        while true {
            let page = try await call("/api/control/missions?project=\(Self.escape(project))&all=true&limit=100&offset=\(offset)").items
            let fresh = page.map { OrbRow($0) }.filter { row in !rows.contains(where: { $0.id == row.id }) }
            rows += fresh
            if page.count < 100 || fresh.isEmpty { break }
            offset += page.count
        }
        return rows.filter(\.mobile)
    }
}

/// Persist the exact request before submitting. An uncertain response never creates a new identity.
struct OrbPending: Codable {
    let path: String
    let body: OrbJSON
}
@MainActor
enum OrbDisk {
    static func url(_ key: String) -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orb")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scope = OrbCore.shared.endpoint + ":" + (APIService.shared.authToken ?? "") + ":" + key
        let name = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(name + ".json")
    }
    static func read<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: url(key)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func save<T: Encodable>(_ value: T, key: String) throws { try JSONEncoder().encode(value).write(to: url(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    static func remove(_ key: String) { try? FileManager.default.removeItem(at: url(key)) }
}

/// Account-scoped, bounded read-through cache. In-flight loads are shared with navigation.
@MainActor
enum OrbReadCache {
    private struct Entry { let value: OrbJSON; let date: Date }
    private static var values: [String: Entry] = [:]
    private struct Pending { let id = UUID(); let task: Task<OrbJSON, Error> }
    private static var pending: [String: Pending] = [:]
    private static func key(_ name: String) -> String { OrbDisk.url(name).absoluteString }
    static func read(_ name: String) -> OrbJSON? {
        values[key(name)]?.value ?? OrbDisk.read(name, as: OrbJSON.self)
    }
    static func load(_ name: String, force: Bool = false, fetch: @escaping @MainActor () async throws -> OrbJSON) async throws -> OrbJSON {
        let scope = key(name)
        if !force, let entry = values[scope], Date().timeIntervalSince(entry.date) < 30 { return entry.value }
        if let item = pending[scope] {
            let value = try await item.task.value
            guard scope == key(name), !item.task.isCancelled else { throw CancellationError() }
            return value
        }
        let task = Task { try await fetch() }
        let item = Pending(task: task)
        pending[scope] = item
        defer { if pending[scope]?.id == item.id { pending[scope] = nil } }
        let value = try await task.value
        guard scope == key(name), pending[scope]?.id == item.id else { throw CancellationError() }
        if values.count >= 64, let oldest = values.min(by: { $0.value.date < $1.value.date })?.key { values[oldest] = nil }
        values[scope] = Entry(value: value, date: Date())
        try? OrbDisk.save(value, key: name)
        return value
    }
    static func invalidate(_ name: String) {
        let scope = key(name)
        pending[scope]?.task.cancel()
        pending[scope] = nil
        if let old = values[scope] { values[scope] = Entry(value: old.value, date: .distantPast) }
    }
    static func project(_ id: String, force: Bool = false) async throws -> OrbJSON {
        try await load("project:\(id)", force: force) {
            async let missions = OrbCore.shared.missions(id)
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
    static func prefetch(_ rows: [OrbRow]) async {
        for row in rows.prefix(2) {
            guard !Task.isCancelled else { return }
            do {
                _ = try await conversation(row.id)
                if row.cloud { _ = try await cloud(row.id) }
            } catch { return }
        }
    }
}
