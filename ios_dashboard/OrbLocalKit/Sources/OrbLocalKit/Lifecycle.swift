import Foundation

/// Explicit execution state of a phone-owned mission. Computation never
/// silently moves to Orb Core: when iOS stops Orb, the state says so.
public enum LocalMissionState: String, Codable, Sendable, CaseIterable {
    case running
    /// Orb is backgrounded but iOS granted execution time (continued
    /// processing task, or the short post-background grace period).
    case backgroundRunning = "background_running"
    /// iOS suspended Orb mid-turn; the native session is checkpointed.
    case suspendedByIOS = "suspended_by_ios"
    /// The turn cannot continue until the user reopens Orb.
    case resumeRequired = "resume_required"
    case interrupted
    case completed
    case failed

    /// Core's client-status vocabulary (`set_client_mission_status`).
    /// `nil` means "still the phone's run; do not settle it in Core".
    public var coreStatus: String? {
        switch self {
        case .running, .backgroundRunning, .suspendedByIOS, .resumeRequired: nil
        case .interrupted: "interrupted"
        case .completed: "awaiting_user"
        case .failed: "failed"
        }
    }

    public var isTerminal: Bool { coreStatus != nil }
}

public enum LifecycleSignal: Equatable, Sendable {
    case turnStarted
    case enteredBackground(continuedProcessing: Bool)
    case enteredForeground
    case backgroundTimeExpired
    /// App launched and found this checkpoint from a previous process.
    case relaunched
    case turnFinished(success: Bool)
    case userStopped
}

public enum LocalMissionLifecycle {
    public static func next(_ state: LocalMissionState, _ signal: LifecycleSignal) -> LocalMissionState {
        switch (state, signal) {
        case (_, .userStopped): return .interrupted
        case (_, .turnFinished(let ok)): return ok ? .completed : .failed
        case (_, .turnStarted): return .running
        case (.running, .enteredBackground(let continued)): return continued ? .backgroundRunning : .suspendedByIOS
        case (.backgroundRunning, .backgroundTimeExpired), (.running, .backgroundTimeExpired): return .suspendedByIOS
        case (.backgroundRunning, .enteredForeground): return .running
        case (.suspendedByIOS, .enteredForeground): return .running
        // A new process cannot reattach to a turn the old process was running:
        // the guest interpreter died with it. Resume replays the native session.
        case (.running, .relaunched), (.backgroundRunning, .relaunched), (.suspendedByIOS, .relaunched):
            return .resumeRequired
        default: return state
        }
    }
}

/// Durable record for one phone-owned mission, written on every state change.
public struct LocalMissionCheckpoint: Codable, Equatable, Sendable {
    public var missionID: String
    public var clientID: String
    public var runID: String?
    public var generation: UInt64?
    public var state: LocalMissionState
    public var harness: HarnessState
    /// The prompt of the turn in flight, re-sent on resume if it never finished.
    public var inflightPrompt: String?
    public var updatedAt: Date

    public init(missionID: String, clientID: String, runID: String?, generation: UInt64?, state: LocalMissionState,
                harness: HarnessState, inflightPrompt: String?, updatedAt: Date = Date()) {
        self.missionID = missionID; self.clientID = clientID; self.runID = runID; self.generation = generation
        self.state = state; self.harness = harness; self.inflightPrompt = inflightPrompt; self.updatedAt = updatedAt
    }
}

/// Atomic file-per-mission checkpoint store (App Group container on device).
public final class CheckpointStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ mission: String) -> URL {
        let safe = mission.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return directory.appendingPathComponent("\(safe).json")
    }

    public func save(_ checkpoint: LocalMissionCheckpoint) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(checkpoint)
        try lock.withLock { try data.write(to: url(checkpoint.missionID), options: .atomic) }
    }

    public func load(_ mission: String) -> LocalMissionCheckpoint? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return lock.withLock { (try? Data(contentsOf: url(mission))).flatMap { try? decoder.decode(LocalMissionCheckpoint.self, from: $0) } }
    }

    public func all() -> [LocalMissionCheckpoint] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { load($0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func remove(_ mission: String) {
        lock.withLock { try? FileManager.default.removeItem(at: url(mission)) }
    }
}
