import Foundation

/// Commands from the agent to the Orb keyboard extension, carried through the
/// shared App Group container. The extension only runs while it is the active
/// keyboard, so commands wait (with a deadline) until it drains them.
public struct KeyboardCommand: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case insert, delete, `return`, context }
    public var id: UUID
    public var kind: Kind
    public var text: String?
    public var count: Int?
    public var createdAt: Date
    public var expiresAt: Date

    public init(id: UUID = UUID(), kind: Kind, text: String? = nil, count: Int? = nil, createdAt: Date = Date(), ttl: TimeInterval = 20) {
        self.id = id; self.kind = kind; self.text = text; self.count = count
        self.createdAt = createdAt; self.expiresAt = createdAt.addingTimeInterval(ttl)
    }

    public static let maxInsertLength = 4096
}

public struct KeyboardResult: Codable, Equatable, Sendable {
    public var id: UUID
    public var ok: Bool
    public var reason: String?
    /// Context snapshot after the command (never from secure fields; iOS does
    /// not show custom keyboards there).
    public var before: String?
    public var after: String?
    public var selected: String?
    public var keyboardType: Int?
    public var returnKeyType: Int?
    public var hostBundleID: String?
    public var completedAt: Date

    public init(id: UUID, ok: Bool, reason: String? = nil, before: String? = nil, after: String? = nil, selected: String? = nil,
                keyboardType: Int? = nil, returnKeyType: Int? = nil, hostBundleID: String? = nil, completedAt: Date = Date()) {
        self.id = id; self.ok = ok; self.reason = reason; self.before = before; self.after = after; self.selected = selected
        self.keyboardType = keyboardType; self.returnKeyType = returnKeyType; self.hostBundleID = hostBundleID; self.completedAt = completedAt
    }
}

/// Presence beacon written by the keyboard while it is on screen.
public struct KeyboardPresence: Codable, Equatable, Sendable {
    public var visible: Bool
    public var fullAccess: Bool
    public var updatedAt: Date
    public init(visible: Bool, fullAccess: Bool, updatedAt: Date = Date()) {
        self.visible = visible; self.fullAccess = fullAccess; self.updatedAt = updatedAt
    }
    /// The beacon is refreshed every second while visible.
    public func isActive(now: Date = Date()) -> Bool { visible && now.timeIntervalSince(updatedAt) < 3 }
}

/// File-backed queue in the App Group container: `commands/<id>.json` written
/// by the app, `results/<id>.json` written by the keyboard. Both sides poll
/// and ping each other with Darwin notifications (payload-free by design).
public final class KeyboardCommandQueue: @unchecked Sendable {
    public static let commandNotification = "md.thomas.orb.keyboard.command"
    public static let resultNotification = "md.thomas.orb.keyboard.result"
    private let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL) {
        self.root = root
        // Seconds since 1970 keep sub-second ordering across processes.
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        for dir in ["commands", "results"] {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
    }

    private func file(_ dir: String, _ id: UUID) -> URL { root.appendingPathComponent(dir).appendingPathComponent("\(id.uuidString).json") }
    private var presenceURL: URL { root.appendingPathComponent("presence.json") }

    // App side
    public func enqueue(_ command: KeyboardCommand) throws {
        if let text = command.text, text.count > KeyboardCommand.maxInsertLength {
            throw HarnessError.unsupported("Keyboard insert exceeds \(KeyboardCommand.maxInsertLength) characters")
        }
        try encoder.encode(command).write(to: file("commands", command.id), options: .atomic)
    }

    public func result(for id: UUID) -> KeyboardResult? {
        guard let data = try? Data(contentsOf: file("results", id)), let r = try? decoder.decode(KeyboardResult.self, from: data) else { return nil }
        try? FileManager.default.removeItem(at: file("results", id))
        return r
    }

    public func cancel(_ id: UUID) { try? FileManager.default.removeItem(at: file("commands", id)) }

    public func presence() -> KeyboardPresence? {
        (try? Data(contentsOf: presenceURL)).flatMap { try? decoder.decode(KeyboardPresence.self, from: $0) }
    }

    // Keyboard side
    /// Pending, unexpired commands oldest first. Expired ones are answered
    /// with a failure so the agent is not left waiting.
    public func drain(now: Date = Date()) -> [KeyboardCommand] {
        let dir = root.appendingPathComponent("commands")
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [KeyboardCommand] = []
        for url in urls where url.pathExtension == "json" {
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url), let c = try? decoder.decode(KeyboardCommand.self, from: data) else { continue }
            if c.expiresAt < now { complete(KeyboardResult(id: c.id, ok: false, reason: "expired")); continue }
            out.append(c)
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    public func complete(_ result: KeyboardResult) {
        try? encoder.encode(result).write(to: file("results", result.id), options: .atomic)
    }

    public func setPresence(_ presence: KeyboardPresence) {
        try? encoder.encode(presence).write(to: presenceURL, options: .atomic)
    }
}
