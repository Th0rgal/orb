import Foundation
import os

/// os.Logger categories for Orb. Filter in Console.app with
/// `subsystem:md.thomas.openagent.dashboard category:network` (etc.).
enum Log {
    nonisolated static let subsystem = Bundle.main.bundleIdentifier ?? "md.thomas.openagent.dashboard"

    enum Category: String, CaseIterable, Sendable {
        case network, cache, liveActivity, notifications, background, auth, crash
    }

    nonisolated static let network = Logger(subsystem: subsystem, category: Category.network.rawValue)
    nonisolated static let cache = Logger(subsystem: subsystem, category: Category.cache.rawValue)
    nonisolated static let liveActivity = Logger(subsystem: subsystem, category: Category.liveActivity.rawValue)
    nonisolated static let notifications = Logger(subsystem: subsystem, category: Category.notifications.rawValue)
    nonisolated static let background = Logger(subsystem: subsystem, category: Category.background.rawValue)
    nonisolated static let auth = Logger(subsystem: subsystem, category: Category.auth.rawValue)
    nonisolated static let crash = Logger(subsystem: subsystem, category: Category.crash.rawValue)

    nonisolated static func logger(_ category: Category) -> Logger {
        switch category {
        case .network: network
        case .cache: cache
        case .liveActivity: liveActivity
        case .notifications: notifications
        case .background: background
        case .auth: auth
        case .crash: crash
        }
    }

    /// Logs the error and records it in the ErrorRing.
    /// Network-layer errors are already recorded (with their real path) by the OrbCore transport,
    /// so they are only logged here.
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

/// Persisted structural crash breadcrumbs. Prompt and message text are never stored here.
enum OrbCrashBreadcrumbs {
    private final class InstallGate: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func tryAcquire() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
    nonisolated private static let installGate = InstallGate()
    nonisolated private static let lastKey = "orb.crash.last"
    nonisolated private static let activeKey = "orb.crash.active"
    nonisolated(unsafe) private static var previousHandler: (@convention(c) (NSException) -> Void)?
    nonisolated static func install() {
        guard installGate.tryAcquire() else { return }
        previousHandler = NSGetUncaughtExceptionHandler()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { OrbCrashBreadcrumbs.drainPendingIntoErrorRing() }
        }
        NSSetUncaughtExceptionHandler { exception in
            let frame = exception.callStackSymbols.first
            OrbCrashBreadcrumbs.recordCrash(reason: exception.name.rawValue, topFrame: frame, memoryMB: nil)
            OrbCrashBreadcrumbs.previousHandler?(exception)
        }
    }
    nonisolated static func enterConversation(missionId: String, turnCount: Int) {
        updateActive(["screen": "conversation", "missionId": missionId, "turnCount": turnCount])
    }
    nonisolated static func updateTurnCount(_ turnCount: Int) {
        var active = UserDefaults.standard.dictionary(forKey: activeKey) ?? [:]; active["turnCount"] = turnCount; updateActive(active)
    }
    nonisolated static func leaveConversation() { updateActive(["screen": "unknown", "turnCount": 0]) }
    nonisolated static func recordCrash(reason: String, topFrame: String?, memoryMB: Int?) {
        var record = UserDefaults.standard.dictionary(forKey: activeKey) ?? [:]
        record["reason"] = reason; record["topFrame"] = topFrame ?? ""; if let memoryMB { record["memoryMB"] = memoryMB } else { record.removeValue(forKey: "memoryMB") }
        UserDefaults.standard.set(record, forKey: lastKey)
    }
    nonisolated private static func updateActive(_ active: [String: Any]) { UserDefaults.standard.set(active, forKey: activeKey) }
    @MainActor static func drainPendingIntoErrorRing() {
        guard let record = UserDefaults.standard.dictionary(forKey: lastKey) else { return }
        UserDefaults.standard.removeObject(forKey: lastKey)
        let reason = record["reason"] as? String ?? "crash"
        let screen = record["screen"] as? String ?? "unknown"
        let mission = record["missionId"] as? String ?? ""
        let turns = record["turnCount"] as? Int ?? 0
        ErrorRing.shared.record(category: .crash, path: "crash", status: nil, message: "reason=\(reason) screen=\(screen) missionId=\(mission) turnCount=\(turns)")
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
        error is OrbHTTPError || error is URLError
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
        if let error = error as? OrbHTTPError, error.status > 0 { return error.status }
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
