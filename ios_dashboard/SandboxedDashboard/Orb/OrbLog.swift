import Foundation
import os

/// os.Logger categories for Orb. Filter in Console.app with
/// `subsystem:md.thomas.openagent.dashboard category:network` (etc.).
enum Log {
    nonisolated static let subsystem = Bundle.main.bundleIdentifier ?? "md.thomas.openagent.dashboard"

    enum Category: String, CaseIterable, Sendable {
        case network, cache, liveActivity, notifications, background, auth
    }

    nonisolated static let network = Logger(subsystem: subsystem, category: Category.network.rawValue)
    nonisolated static let cache = Logger(subsystem: subsystem, category: Category.cache.rawValue)
    nonisolated static let liveActivity = Logger(subsystem: subsystem, category: Category.liveActivity.rawValue)
    nonisolated static let notifications = Logger(subsystem: subsystem, category: Category.notifications.rawValue)
    nonisolated static let background = Logger(subsystem: subsystem, category: Category.background.rawValue)
    nonisolated static let auth = Logger(subsystem: subsystem, category: Category.auth.rawValue)

    nonisolated static func logger(_ category: Category) -> Logger {
        switch category {
        case .network: network
        case .cache: cache
        case .liveActivity: liveActivity
        case .notifications: notifications
        case .background: background
        case .auth: auth
        }
    }

    /// Logs the error and records it in the ErrorRing.
    /// Network-layer errors are already recorded (with their real path) by OrbCore.call and
    /// APIService, so they are only logged here.
    @MainActor
    static func error(_ category: Category, _ what: String, path: String? = nil, _ error: Error) {
        let status = ErrorRing.status(of: error)
        logger(category).error("\(what, privacy: .public) failed\(path.map { " [\($0)]" } ?? "", privacy: .public)\(status.map { " HTTP \($0)" } ?? "", privacy: .public): \(error.localizedDescription, privacy: .public)")
        guard !ErrorRing.isNetworkLayer(error) else { return }
        ErrorRing.shared.record(category: category, path: path ?? what, status: status, message: error.localizedDescription)
    }

    /// Replacement for `try?` on calls whose failure should be visible: returns nil on
    /// failure after logging it. Cancellation is expected (views disappear) and is not recorded.
    @MainActor
    static func attempt<T>(_ category: Category, _ what: String, path: String? = nil, _ operation: @MainActor () async throws -> T) async -> T? {
        do {
            return try await operation()
        } catch is CancellationError {
            return nil
        } catch let error as URLError where error.code == .cancelled {
            return nil
        } catch {
            Log.error(category, what, path: path, error)
            return nil
        }
    }
}

/// In-memory ring of the last 50 errors, shown in Settings → Debug info.
@MainActor
@Observable
final class ErrorRing {
    struct Entry: Identifiable, Equatable, Sendable {
        let id = UUID()
        let time: Date
        let category: Log.Category
        let path: String
        let status: Int?
        let message: String
    }

    static let shared = ErrorRing()
    static let capacity = 50
    private(set) var entries: [Entry] = []

    init() {}

    func record(category: Log.Category, path: String, status: Int?, message: String, time: Date = Date()) {
        entries.append(Entry(time: time, category: category, path: path, status: status, message: String(message.prefix(300))))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    func clear() { entries.removeAll() }

    nonisolated static func isNetworkLayer(_ error: Error) -> Bool {
        error is OrbHTTPError || error is APIError || error is URLError
    }

    /// Records a failed request from the network layer. Cancellations are expected noise.
    func recordRequest(path: String, error: Error) {
        if error is CancellationError { return }
        if let error = error as? URLError, error.code == .cancelled { return }
        let status = Self.status(of: error)
        Log.network.error("request \(path, privacy: .public) failed\(status.map { " HTTP \($0)" } ?? "", privacy: .public): \(error.localizedDescription, privacy: .public)")
        record(category: .network, path: Self.redact(path), status: status, message: error.localizedDescription)
    }

    /// Drops query strings so diagnostics never carry search terms or tokens.
    nonisolated static func redact(_ path: String) -> String {
        path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
    }

    nonisolated static func status(of error: Error) -> Int? {
        if let error = error as? OrbHTTPError { return error.status }
        if let error = error as? APIError {
            switch error {
            case .httpError(let code, _): return code
            case .unauthorized: return 401
            default: return nil
            }
        }
        return nil
    }
}

/// Timestamps for the debug screen.
@MainActor
enum OrbDiagnosticsClock {
    private static let lastBackgroundRefreshKey = "orb.debug.lastBackgroundRefresh"
    static var lastBackgroundRefresh: Date? {
        get { UserDefaults.standard.object(forKey: lastBackgroundRefreshKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastBackgroundRefreshKey) }
    }
}
