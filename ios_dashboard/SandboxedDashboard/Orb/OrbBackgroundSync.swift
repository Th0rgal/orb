import Foundation
import Network
import Observation
import UIKit

enum OrbBackgroundSyncMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case auto
    case on
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .on: "On"
        case .off: "Off"
        }
    }
}

enum OrbBackgroundSyncPauseReason: String, Codable, Equatable, Sendable {
    case dataSaver = "data_saver"
    case slowRtt = "slow_rtt"
    case streamLagged = "lagged"
    case unstableLink = "unstable"
}

struct OrbBackgroundSyncState: Equatable, Sendable {
    var mode: OrbBackgroundSyncMode
    var dataSaver: Bool
    var slowRttStreak: Int
    var fastRttStreak: Int
    var pausedByLink: Bool
    var linkPauseReason: OrbBackgroundSyncPauseReason?
    var cooldownUntilMs: Int64
    var recentDisconnectsMs: [Int64]
    var lastRttMs: Int?
    var srttMs: Int = 0
    var rttVarMs: Int = 0
    var consecutiveFailures: Int = 0

    var linkBudget: OrbKernel.ClientLinkBudgetResult {
        OrbKernel.clientLinkBudgetStep(
            srttMs: srttMs,
            rttVarMs: rttVarMs,
            consecutiveFailures: consecutiveFailures,
            isConstrained: dataSaver || mode == .off,
            p0InFlight: 0
        )
    }

    var pauseReason: OrbBackgroundSyncPauseReason? {
        switch mode {
        case .on, .off:
            return nil
        case .auto:
            if dataSaver { return .dataSaver }
            if pausedByLink { return linkPauseReason ?? .slowRtt }
            return nil
        }
    }

    var reason: String {
        switch mode {
        case .on:
            return "forced_on"
        case .off:
            return "forced_off"
        case .auto:
            return pauseReason?.rawValue ?? "healthy"
        }
    }

    var active: Bool {
        switch mode {
        case .on:
            return true
        case .off:
            return false
        case .auto:
            return !dataSaver && !pausedByLink
        }
    }
}

enum OrbBackgroundSyncEvent: Sendable {
    case setMode(OrbBackgroundSyncMode)
    case setDataSaver(Bool)
    case pingRtt(rttMs: Int, atMs: Int64)
    case streamLagged(atMs: Int64)
    case unexpectedDisconnect(atMs: Int64)
}

/// Pure, deterministic state machine shared with desktop (`orb/src/backgroundSync.ts`)
/// and Android (`OrbBackgroundSync.kt`), verified against `shared/orb-spec/fixtures/background-sync-policy.json`.
enum OrbBackgroundSyncPolicy {
    nonisolated static let maxWarmMissions = 12
    nonisolated static let rttSlowThresholdMs = 750
    nonisolated static let rttSlowStreakToPause = 2
    nonisolated static let rttFastThresholdMs = 350
    nonisolated static let rttFastStreakToResume = 3
    nonisolated static let resumeCooldownMs: Int64 = 30_000
    nonisolated static let disconnectWindowMs: Int64 = 60_000
    nonisolated static let disconnectBurstToPause = 2

    nonisolated static func normalizeMode(_ raw: Any?) -> OrbBackgroundSyncMode {
        guard let text = raw as? String else { return .auto }
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "on": return .on
        case "off": return .off
        default: return .auto
        }
    }

    nonisolated static func initialState(
        mode: OrbBackgroundSyncMode = .auto,
        dataSaver: Bool = false
    ) -> OrbBackgroundSyncState {
        OrbBackgroundSyncState(
            mode: mode,
            dataSaver: dataSaver,
            slowRttStreak: 0,
            fastRttStreak: 0,
            pausedByLink: false,
            linkPauseReason: nil,
            cooldownUntilMs: 0,
            recentDisconnectsMs: [],
            lastRttMs: nil
        )
    }

    nonisolated static func reduce(
        _ state: OrbBackgroundSyncState,
        event: OrbBackgroundSyncEvent
    ) -> OrbBackgroundSyncState {
        var next = state
        switch event {
        case .setMode(let mode):
            next.mode = mode
            return next

        case .setDataSaver(let enabled):
            next.dataSaver = enabled
            if enabled {
                next.fastRttStreak = 0
            }
            return next

        case .pingRtt(let rttMs, let atMs):
            let clamped = max(0, rttMs)
            next.lastRttMs = clamped
            let ewma = OrbKernel.rttEwmaStep(srttMs: next.srttMs, rttVarMs: next.rttVarMs, sampleMs: clamped)
            next.srttMs = ewma.srttMs
            next.rttVarMs = ewma.rttVarMs
            next.consecutiveFailures = 0
            if clamped > rttSlowThresholdMs {
                next.slowRttStreak += 1
                next.fastRttStreak = 0
                if next.slowRttStreak >= rttSlowStreakToPause {
                    next.pausedByLink = true
                    next.linkPauseReason = .slowRtt
                    next.cooldownUntilMs = max(next.cooldownUntilMs, atMs + resumeCooldownMs)
                }
                return next
            }
            next.slowRttStreak = 0
            if clamped < rttFastThresholdMs {
                next.fastRttStreak += 1
                if !next.dataSaver && next.pausedByLink && next.fastRttStreak >= rttFastStreakToResume && atMs >= next.cooldownUntilMs {
                    next.pausedByLink = false
                    next.linkPauseReason = nil
                    next.recentDisconnectsMs = []
                }
            } else {
                next.fastRttStreak = 0
            }
            return next

        case .streamLagged(let atMs):
            next.pausedByLink = true
            next.linkPauseReason = .streamLagged
            next.slowRttStreak = 0
            next.fastRttStreak = 0
            next.cooldownUntilMs = max(next.cooldownUntilMs, atMs + resumeCooldownMs)
            return next

        case .unexpectedDisconnect(let atMs):
            let cutoff = atMs - disconnectWindowMs
            var recent = next.recentDisconnectsMs.filter { $0 >= cutoff }
            recent.append(atMs)
            next.recentDisconnectsMs = recent
            next.fastRttStreak = 0
            next.consecutiveFailures = min(255, next.consecutiveFailures + 1)
            if recent.count >= disconnectBurstToPause {
                next.pausedByLink = true
                next.linkPauseReason = .unstableLink
                next.cooldownUntilMs = max(next.cooldownUntilMs, atMs + resumeCooldownMs)
            }
            return next
        }
    }

    nonisolated static func selectWarmMissionIds(
        backgroundActive: Bool,
        maxWarm: Int = maxWarmMissions,
        focusedIds: [String],
        liveIds: [String] = [],
        recentIds: [String],
        knownBtwByParent: [String: String] = [:],
        focusedBtwParents: [String] = []
    ) -> (missionIds: [String], btwParentIds: [String], allStreamIds: [String]) {
        let cap = max(1, maxWarm)
        var missionSet = Set<String>()
        var orderedMissions: [String] = []
        for id in focusedIds where !id.isEmpty && missionSet.insert(id).inserted {
            orderedMissions.append(id)
        }
        if backgroundActive {
            for id in liveIds {
                if orderedMissions.count >= cap { break }
                if !id.isEmpty && missionSet.insert(id).inserted {
                    orderedMissions.append(id)
                }
            }
            for id in recentIds.reversed() {
                if orderedMissions.count >= cap { break }
                if !id.isEmpty && missionSet.insert(id).inserted {
                    orderedMissions.append(id)
                }
            }
        }
        var btwParentSet = Set<String>()
        var btwParents: [String] = []
        if backgroundActive {
            for mid in orderedMissions where knownBtwByParent[mid] != nil {
                if btwParentSet.insert(mid).inserted {
                    btwParents.append(mid)
                }
            }
        } else {
            let openSet = Set(focusedBtwParents)
            for mid in orderedMissions where openSet.contains(mid) && knownBtwByParent[mid] != nil {
                if btwParentSet.insert(mid).inserted {
                    btwParents.append(mid)
                }
            }
        }
        for parent in focusedBtwParents where !parent.isEmpty && knownBtwByParent[parent] != nil {
            if btwParentSet.insert(parent).inserted {
                btwParents.append(parent)
            }
        }
        var streamSet = missionSet
        var allStreamIds = orderedMissions
        for parent in btwParents {
            if let btwId = knownBtwByParent[parent], !btwId.isEmpty, streamSet.insert(btwId).inserted {
                allStreamIds.append(btwId)
            }
        }
        return (orderedMissions, btwParents, allStreamIds)
    }
}

@Observable @MainActor
final class OrbBackgroundSyncMonitor {
    static let shared = OrbBackgroundSyncMonitor()
    private static let modeKey = "orb.backgroundSyncMode"

    private(set) var state: OrbBackgroundSyncState
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "orb.background-sync.path", qos: .utility)

    var mode: OrbBackgroundSyncMode {
        get { state.mode }
        set {
            let prevActive = state.active
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.modeKey)
            state = OrbBackgroundSyncPolicy.reduce(state, event: .setMode(newValue))
            if state.active != prevActive {
                OrbWarmSyncCoordinator.shared.reconcile()
            }
        }
    }

    var active: Bool { state.active }
    var pauseReason: OrbBackgroundSyncPauseReason? { state.pauseReason }
    var lastRttMs: Int? { state.lastRttMs }
    var linkBudget: OrbKernel.ClientLinkBudgetResult { state.linkBudget }

    var statusText: String {
        switch state.mode {
        case .on:
            return "Active — keeps up to 12 recently opened conversations and their /btw tabs live in the background."
        case .off:
            return "Off — only the open conversation subscribes live; returning uses lightweight catch-up."
        case .auto:
            let rttLabel = state.lastRttMs.map { " (\($0) ms)" } ?? ""
            if state.active {
                return "Active\(rttLabel) — pauses automatically on Low Data Mode or slow connections."
            }
            switch state.pauseReason {
            case .dataSaver:
                return "Paused — Low Data Mode is enabled on this device."
            case .slowRtt:
                return "Paused — high connection latency\(rttLabel); resumes automatically when fast again."
            case .streamLagged:
                return "Paused — stream fell behind; resumes automatically once stable."
            case .unstableLink:
                return "Paused — connection dropped repeatedly; resumes automatically once stable."
            case nil:
                return "Paused — waiting for a fast, stable connection."
            }
        }
    }

    private init() {
        let initialMode = OrbBackgroundSyncPolicy.normalizeMode(UserDefaults.standard.string(forKey: Self.modeKey))
        self.state = OrbBackgroundSyncPolicy.initialState(mode: initialMode, dataSaver: false)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let constrained = path.isConstrained
            Task { @MainActor [weak self] in
                self?.apply(.setDataSaver(constrained))
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    func notePingRtt(ms: Int, atMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        apply(.pingRtt(rttMs: ms, atMs: atMs))
    }

    func noteStreamLagged(atMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        apply(.streamLagged(atMs: atMs))
    }

    func noteUnexpectedDisconnect(atMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        apply(.unexpectedDisconnect(atMs: atMs))
    }

    func resetLinkState() {
        let prevActive = state.active
        state = OrbBackgroundSyncPolicy.initialState(mode: state.mode, dataSaver: state.dataSaver)
        if state.active != prevActive {
            OrbWarmSyncCoordinator.shared.reconcile()
        }
    }

    private func apply(_ event: OrbBackgroundSyncEvent) {
        let prevActive = state.active
        let prevP2Cap = state.linkBudget.p2Cap
        state = OrbBackgroundSyncPolicy.reduce(state, event: event)
        if state.active != prevActive || state.linkBudget.p2Cap != prevP2Cap {
            OrbWarmSyncCoordinator.shared.reconcile()
        }
    }
}

extension StoredEvent {
    /// Converts a sequenced live `/api/control/sync` WebSocket `AgentEvent` frame directly
    /// into a `StoredEvent` so cached transcripts and work folds advance in memory without
    /// triggering redundant HTTP `GET /events` or `GET /missions/:id` round-trips.
    nonisolated static func fromStreamFrame(
        missionId: String,
        type: String,
        data: [String: Any]
    ) -> StoredEvent? {
        let seq: Int64? = {
            if let s = data["sequence"] as? Int64 { return s }
            if let s = data["sequence"] as? Int { return Int64(s) }
            if let n = data["sequence"] as? NSNumber { return n.int64Value }
            return nil
        }()
        guard let sequence = seq, sequence > 0 else { return nil }
        let timestamp = (data["timestamp"] as? String)
            ?? (data["at"] as? String)
            ?? ISO8601DateFormatter().string(from: Date())

        switch type {
        case "user_message":
            let content = data["content"] as? String ?? ""
            var meta: [String: AnyCodable] = [:]
            if (data["queued"] as? Bool) == true {
                meta["queued"] = AnyCodable(true)
            }
            return StoredEvent(
                id: sequence,
                missionId: missionId,
                sequence: sequence,
                eventType: type,
                timestamp: timestamp,
                eventId: data["id"] as? String,
                toolCallId: nil,
                toolName: nil,
                content: content,
                metadata: meta
            )

        case "assistant_message", "assistant_message_canonical":
            let content = data["content"] as? String ?? ""
            var meta: [String: AnyCodable] = [:]
            if let success = data["success"] as? Bool {
                meta["success"] = AnyCodable(success)
            }
            if let bubbleId = data["bubble_id"] as? String {
                meta["bubble_id"] = AnyCodable(bubbleId)
            }
            if let revision = data["revision"] {
                meta["revision"] = AnyCodable(revision)
            }
            if let sharedFiles = data["shared_files"] {
                meta["shared_files"] = AnyCodable(sharedFiles)
            }
            if let costCents = data["cost_cents"] {
                meta["cost_cents"] = AnyCodable(costCents)
            }
            if let model = data["model"] as? String {
                meta["model"] = AnyCodable(model)
            }
            let eventId = (data["id"] as? String) ?? (data["bubble_id"] as? String)
            return StoredEvent(
                id: sequence,
                missionId: missionId,
                sequence: sequence,
                eventType: type,
                timestamp: timestamp,
                eventId: eventId,
                toolCallId: nil,
                toolName: nil,
                content: content,
                metadata: meta
            )

        case "tool_call":
            let toolCallId = data["tool_call_id"] as? String
            let toolName = data["name"] as? String
            let argsText: String
            if let raw = data["args"] as? String {
                argsText = raw
            } else if let args = data["args"], JSONSerialization.isValidJSONObject(args),
                      let bytes = try? JSONSerialization.data(withJSONObject: args),
                      let str = String(data: bytes, encoding: .utf8) {
                argsText = str
            } else {
                argsText = "{}"
            }
            return StoredEvent(
                id: sequence,
                missionId: missionId,
                sequence: sequence,
                eventType: type,
                timestamp: timestamp,
                eventId: nil,
                toolCallId: toolCallId,
                toolName: toolName,
                content: argsText,
                metadata: [:]
            )

        case "tool_result":
            let toolCallId = data["tool_call_id"] as? String
            let toolName = data["name"] as? String
            let resultText: String
            if let raw = data["result"] as? String {
                resultText = raw
            } else if let res = data["result"], JSONSerialization.isValidJSONObject(res),
                      let bytes = try? JSONSerialization.data(withJSONObject: res),
                      let str = String(data: bytes, encoding: .utf8) {
                resultText = str
            } else {
                resultText = ""
            }
            var meta: [String: AnyCodable] = [:]
            if (data["is_error"] as? Bool) == true {
                meta["is_error"] = AnyCodable(true)
            }
            return StoredEvent(
                id: sequence,
                missionId: missionId,
                sequence: sequence,
                eventType: type,
                timestamp: timestamp,
                eventId: nil,
                toolCallId: toolCallId,
                toolName: toolName,
                content: resultText,
                metadata: meta
            ).compacted

        case "thinking":
            guard (data["done"] as? Bool) != false else { return nil }
            let content = data["content"] as? String ?? ""
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return StoredEvent(
                id: sequence,
                missionId: missionId,
                sequence: sequence,
                eventType: type,
                timestamp: timestamp,
                eventId: data["event_id"] as? String,
                toolCallId: nil,
                toolName: nil,
                content: content,
                metadata: ["done": AnyCodable(true)]
            )

        case "goal_status", "goal_iteration":
            let content = (data["summary"] as? String) ?? (data["content"] as? String) ?? ""
            guard !content.isEmpty else { return nil }
            return StoredEvent(
                id: sequence,
                missionId: missionId,
                sequence: sequence,
                eventType: type,
                timestamp: timestamp,
                eventId: nil,
                toolCallId: nil,
                toolName: nil,
                content: content,
                metadata: [:]
            )

        default:
            return nil
        }
    }
}

/// Owns warm multiplexed WebSocket subscriptions for up to `12` recently opened missions
/// and their `/btw` companion sessions while Orb is foregrounded, plus dirty-flag tracking
/// for instant 0-HTTP reopens in both `Auto`/`On` and `Off` modes.
@MainActor
final class OrbWarmSyncCoordinator {
    static let shared = OrbWarmSyncCoordinator()

    typealias ViewListener = (String, [String: Any], StoredEvent?) -> Void

    private final class WarmSubscription {
        let missionId: String
        var task: Task<Void, Never>?
        var healthy = false
        var caughtUp = false
        var cursor: Int64?
        var listeners: [UUID: ViewListener] = [:]

        init(missionId: String, initialCursor: Int64?) {
            self.missionId = missionId
            self.cursor = initialCursor
        }

        var isCaughtUpHealthy: Bool { healthy && caughtUp }

        func cancel() {
            task?.cancel()
            task = nil
            healthy = false
            caughtUp = false
        }
    }

    private var activeScope = ""
    private var appIsActive = true
    private var focusedCounts: [String: Int] = [:]
    private var liveIds: [String] = []
    private var recentlyOpened: [String] = []
    private var focusedBtwParents: Set<String> = []
    private var warmSubs: [String: WarmSubscription] = [:]
    private var dirtyMissions: Set<String> = []
    private var dirtyBtwParents: Set<String> = []
    private var checkedCleanBtwParents: Set<String> = []

    private init() {
        self.appIsActive = UIApplication.shared.applicationState != .background
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appIsActive = false
                self.reconcile()
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appIsActive = true
                self.reconcile()
            }
        }
    }

    private var currentScope: String {
        "\(OrbCore.shared.endpoint)|\(OrbCore.shared.authToken ?? "")|\(OrbCore.shared.connectionGeneration)"
    }

    private func ensureScope() {
        let scope = currentScope
        guard activeScope != scope else { return }
        activeScope = scope
        for sub in warmSubs.values { sub.cancel() }
        warmSubs.removeAll()
        focusedCounts.removeAll()
        liveIds.removeAll()
        recentlyOpened.removeAll()
        focusedBtwParents.removeAll()
        dirtyMissions.removeAll()
        dirtyBtwParents.removeAll()
        checkedCleanBtwParents.removeAll()
        OrbBtwStore.stopAllWarmFollows()
    }

    func resetCaches() {
        for sub in warmSubs.values where sub.listeners.isEmpty {
            sub.cancel()
        }
        warmSubs = warmSubs.filter { !$0.value.listeners.isEmpty }
        liveIds.removeAll()
        recentlyOpened.removeAll()
        dirtyMissions.removeAll()
        dirtyBtwParents.removeAll()
        checkedCleanBtwParents.removeAll()
        OrbBtwStore.stopAllWarmFollows()
    }

    private func rememberRecent(_ missionId: String) {
        guard !missionId.isEmpty else { return }
        recentlyOpened.removeAll { $0 == missionId }
        recentlyOpened.append(missionId)
        if recentlyOpened.count > OrbBackgroundSyncPolicy.maxWarmMissions {
            recentlyOpened.removeFirst(recentlyOpened.count - OrbBackgroundSyncPolicy.maxWarmMissions)
        }
    }

    func noteLiveMissionIds(_ ids: [String]) {
        ensureScope()
        var unique: [String] = []
        var seen = Set<String>()
        for id in ids where !id.isEmpty && seen.insert(id).inserted {
            unique.append(id)
            if !OrbReadCache.readEvents(id).isEmpty {
                rememberRecent(id)
            }
        }
        for prev in liveIds where !seen.contains(prev) && !OrbReadCache.readEvents(prev).isEmpty {
            rememberRecent(prev)
        }
        liveIds = unique
        reconcile()
    }

    func noteOpened(_ missionId: String) {
        guard !missionId.isEmpty else { return }
        ensureScope()
        rememberRecent(missionId)
        focusedCounts[missionId, default: 0] += 1
        reconcile()
    }

    func noteClosed(_ missionId: String) {
        guard !missionId.isEmpty else { return }
        ensureScope()
        let next = (focusedCounts[missionId] ?? 0) - 1
        if next <= 0 {
            focusedCounts.removeValue(forKey: missionId)
        } else {
            focusedCounts[missionId] = next
        }
        reconcile()
    }

    func noteBtwSheetOpened(parentId: String) {
        guard !parentId.isEmpty else { return }
        ensureScope()
        focusedBtwParents.insert(parentId)
        reconcile()
    }

    func noteBtwSheetClosed(parentId: String) {
        guard !parentId.isEmpty else { return }
        ensureScope()
        focusedBtwParents.remove(parentId)
        reconcile()
    }

    func attach(
        missionId: String,
        sinceSeq: Int64?,
        onEvent: @escaping ViewListener
    ) -> UUID {
        ensureScope()
        let token = UUID()
        let sub = ensureSubscription(missionId: missionId, sinceSeq: sinceSeq)
        sub.listeners[token] = onEvent
        if sub.isCaughtUpHealthy {
            let cursor = sub.cursor
            Task { @MainActor [weak self, weak sub] in
                guard self != nil, let sub, sub.isCaughtUpHealthy, let listener = sub.listeners[token] else { return }
                listener("sync_caught_up", ["type": "sync_caught_up", "mission_id": missionId, "replayed": 0, "cursor": cursor as Any], nil)
            }
        }
        return token
    }

    func detach(missionId: String, token: UUID) {
        guard let sub = warmSubs[missionId] else { return }
        sub.listeners.removeValue(forKey: token)
        reconcile()
    }

    func markMissionSynced(_ missionId: String, lastSeq: Int64?) {
        ensureScope()
        dirtyMissions.remove(missionId)
        if let lastSeq, let sub = warmSubs[missionId] {
            sub.cursor = max(sub.cursor ?? lastSeq, lastSeq)
        }
    }

    func isMissionWarmLive(_ missionId: String) -> Bool {
        ensureScope()
        guard let sub = warmSubs[missionId], sub.isCaughtUpHealthy else { return false }
        return !dirtyMissions.contains(missionId) && !OrbReadCache.readEvents(missionId).isEmpty
    }

    func isMissionDirtyWhileUnfocused(_ missionId: String) -> Bool {
        ensureScope()
        return dirtyMissions.contains(missionId)
    }

    func canSkipFullRefreshOnReopen(_ missionId: String) -> Bool {
        ensureScope()
        if isMissionWarmLive(missionId) {
            return OrbReadCache.read("mission:\(missionId)") != nil
        }
        guard !dirtyMissions.contains(missionId),
              OrbCore.shared.isMultiplexSyncHealthy,
              !OrbReadCache.readEvents(missionId).isEmpty,
              OrbReadCache.read("mission:\(missionId)") != nil else {
            return false
        }
        return true
    }

    // MARK: - /btw dirty & clean state

    func markBtwClean(parentId: String) {
        ensureScope()
        dirtyBtwParents.remove(parentId)
        checkedCleanBtwParents.insert(parentId)
    }

    func markBtwDirty(parentId: String) {
        guard !parentId.isEmpty else { return }
        ensureScope()
        dirtyBtwParents.insert(parentId)
        checkedCleanBtwParents.remove(parentId)
    }

    func canSkipBtwServerCrawl(parentId: String) -> Bool {
        ensureScope()
        guard OrbCore.shared.isMultiplexSyncHealthy,
              !dirtyBtwParents.contains(parentId) else {
            return false
        }
        if let store = OrbBtwStore.peek(parentId), store.isWarmCaughtUp {
            return true
        }
        return checkedCleanBtwParents.contains(parentId)
    }

    func notePresentationHint(missionId: String, kind: String?, btwParentId: String?) {
        ensureScope()
        if let btwParentId, !btwParentId.isEmpty {
            if !missionId.isEmpty {
                let sKey = OrbBtwConfig.sessionKey(btwParentId)
                let known = OrbBtwStore.peek(btwParentId)?.boundID ?? UserDefaults.standard.string(forKey: sKey)
                if known != missionId {
                    UserDefaults.standard.set(missionId, forKey: sKey)
                    OrbBtwStore.peek(btwParentId)?.noteExternalSessionHint(missionId: missionId)
                    dirtyBtwParents.insert(btwParentId)
                    checkedCleanBtwParents.remove(btwParentId)
                    reconcile()
                }
            }
            if let store = OrbBtwStore.peek(btwParentId), store.isWarmCaughtUp {
                if kind == "mission_status" {
                    Task { try? await store.refreshStatusOnly() }
                }
            } else {
                dirtyBtwParents.insert(btwParentId)
                checkedCleanBtwParents.remove(btwParentId)
            }
        }
        if let sub = warmSubs[missionId], sub.isCaughtUpHealthy {
            return
        }
        dirtyMissions.insert(missionId)
    }

    func notePresentationStreamDisrupted() {
        ensureScope()
        for mid in Set(recentlyOpened + liveIds) {
            if warmSubs[mid]?.isCaughtUpHealthy != true {
                dirtyMissions.insert(mid)
            }
        }
        checkedCleanBtwParents.removeAll()
    }

    func reconcile() {
        ensureScope()
        if !appIsActive {
            for (_, sub) in warmSubs {
                if !sub.isCaughtUpHealthy || liveIds.contains(sub.missionId) { dirtyMissions.insert(sub.missionId) }
                sub.cancel()
            }
            warmSubs.removeAll()
            OrbBtwStore.stopAllWarmFollows()
            return
        }

        let budget = OrbBackgroundSyncMonitor.shared.linkBudget
        let bgActive = OrbBackgroundSyncMonitor.shared.active && OrbCore.shared.canUseMultiplexSync && budget.p2Cap > 0
        let warmCap = min(OrbBackgroundSyncPolicy.maxWarmMissions, max(1, budget.p2Cap * 3))
        let focusedIds = Array(focusedCounts.keys)
        let liveReady = liveIds.filter { !OrbReadCache.readEvents($0).isEmpty }
        for mid in liveReady { rememberRecent(mid) }
        let recentReady = recentlyOpened.filter { !OrbReadCache.readEvents($0).isEmpty }
        let knownBtw = OrbBtwStore.knownBoundIdsByParent(candidates: Set(focusedIds + liveReady + recentReady + Array(focusedBtwParents)))
        let selection = OrbBackgroundSyncPolicy.selectWarmMissionIds(
            backgroundActive: bgActive,
            maxWarm: warmCap,
            focusedIds: focusedIds,
            liveIds: liveReady,
            recentIds: recentReady,
            knownBtwByParent: knownBtw,
            focusedBtwParents: Array(focusedBtwParents)
        )
        let wantedMissions = Set(selection.missionIds)
        for (mid, sub) in Array(warmSubs) {
            if sub.listeners.isEmpty && !wantedMissions.contains(mid) {
                if !sub.isCaughtUpHealthy || liveIds.contains(mid) { dirtyMissions.insert(mid) }
                sub.cancel()
                warmSubs.removeValue(forKey: mid)
            }
        }
        if bgActive {
            for mid in selection.missionIds where warmSubs[mid] == nil {
                let cached = OrbReadCache.readEvents(mid)
                if !cached.isEmpty {
                    _ = ensureSubscription(missionId: mid, sinceSeq: cached.last?.sequence)
                }
            }
        }
        OrbBtwStore.reconcileWarmFollows(wantedParents: Set(selection.btwParentIds))
    }

    private func ensureSubscription(missionId: String, sinceSeq: Int64?) -> WarmSubscription {
        if let existing = warmSubs[missionId] {
            if existing.task == nil {
                startStream(existing)
            }
            return existing
        }
        let cachedSeq = sinceSeq ?? OrbReadCache.readEvents(missionId).last?.sequence
        let created = WarmSubscription(missionId: missionId, initialCursor: cachedSeq)
        warmSubs[missionId] = created
        startStream(created)
        return created
    }

    private func startStream(_ sub: WarmSubscription) {
        sub.task?.cancel()
        let missionId = sub.missionId
        let scope = activeScope
        sub.task = Task { @MainActor [weak self, weak sub] in
            while !Task.isCancelled {
                guard let self, let sub, self.activeScope == scope, self.warmSubs[missionId] === sub else { return }
                let inner = OrbCore.shared.streamControl(
                    missionId: missionId,
                    sinceSeq: sub.cursor
                ) { [weak self, weak sub] type, data in
                    guard let self, let sub, self.activeScope == scope else { return }
                    self.handleMissionStreamEvent(sub: sub, type: type, data: data)
                }
                await withTaskCancellationHandler {
                    await inner.value
                } onCancel: {
                    inner.cancel()
                }
                guard !Task.isCancelled, self.activeScope == scope, self.warmSubs[missionId] === sub else { return }
                sub.healthy = false
                sub.caughtUp = false
                if self.focusedCounts[missionId, default: 0] == 0 {
                    self.dirtyMissions.insert(missionId)
                }
                for listener in sub.listeners.values {
                    listener("disconnected", ["type": "disconnected"], nil)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func handleMissionStreamEvent(
        sub: WarmSubscription,
        type: String,
        data: [String: Any]
    ) {
        let missionId = sub.missionId
        if type == "connected" {
            sub.healthy = true
            for listener in sub.listeners.values {
                listener(type, data, nil)
            }
            return
        }
        if type == "sync_caught_up" {
            sub.healthy = true
            sub.caughtUp = true
            if let cur = (data["cursor"] as? NSNumber)?.int64Value, cur > 0 {
                sub.cursor = max(sub.cursor ?? cur, cur)
            }
            dirtyMissions.remove(missionId)
            for listener in sub.listeners.values {
                listener(type, data, nil)
            }
            return
        }
        if type == "stream_lagged" || type == "error" {
            sub.caughtUp = false
            dirtyMissions.insert(missionId)
            for listener in sub.listeners.values {
                listener(type, data, nil)
            }
            if type == "stream_lagged" && sub.listeners.isEmpty {
                let scope = activeScope
                Task { @MainActor [weak self, weak sub] in
                    guard let self, let sub, self.activeScope == scope, self.warmSubs[missionId] === sub else { return }
                    if let tail = try? await OrbCore.shared.getMissionEventsWithMeta(id: missionId, limit: 200, sinceSeq: nil),
                       !tail.events.isEmpty,
                       self.activeScope == scope,
                       self.warmSubs[missionId] === sub {
                        let existing = OrbReadCache.readEvents(missionId)
                        let merged = OrbConversation.mergeStoredEvents(existing: existing, incoming: tail.events)
                        OrbReadCache.saveEvents(missionId, events: merged)
                        if let lastSeq = merged.last?.sequence {
                            sub.cursor = max(sub.cursor ?? lastSeq, lastSeq)
                        }
                        if sub.healthy {
                            sub.caughtUp = true
                            self.dirtyMissions.remove(missionId)
                        }
                    }
                }
            }
            return
        }

        if let seq = (data["sequence"] as? NSNumber)?.int64Value, seq > 0 {
            sub.cursor = max(sub.cursor ?? seq, seq)
        }
        let stored = StoredEvent.fromStreamFrame(missionId: missionId, type: type, data: data)
        if let stored {
            let existing = OrbReadCache.readEvents(missionId)
            let merged = OrbConversation.mergeStoredEvents(existing: existing, incoming: [stored])
            OrbReadCache.saveEvents(missionId, events: merged)
            if OrbConversationHistory.eventTypes.contains(stored.eventType),
               let cachedMission = OrbReadCache.read("mission:\(missionId)"),
               case var .object(fields) = cachedMission {
                let updatedHistory = OrbConversationHistory.merge(fields["history"]?.items ?? [], events: [stored])
                fields["history"] = .array(updatedHistory)
                OrbReadCache.seed("mission:\(missionId)", value: .object(fields))
            }
        } else if type == "mission_status_changed",
                  let newStatus = data["status"] as? String, !newStatus.isEmpty,
                  let cachedMission = OrbReadCache.read("mission:\(missionId)"),
                  case var .object(fields) = cachedMission {
            fields["status"] = .string(newStatus)
            if let summary = data["summary"] as? String, !summary.isEmpty {
                fields["status_message"] = .string(summary)
            }
            OrbReadCache.seed("mission:\(missionId)", value: .object(fields))
        } else if type == "mission_settings_updated",
                  let cachedMission = OrbReadCache.read("mission:\(missionId)"),
                  case var .object(fields) = cachedMission {
            for k in ["backend", "agent", "model_override", "model_effort", "service_tier", "config_profile", "session_id", "updated_at"] {
                if let val = data[k] {
                    if let s = val as? String {
                        fields[k] = .string(s)
                    } else if val is NSNull {
                        fields[k] = .null
                    }
                }
            }
            if let fast = data["fast_mode"] as? Bool {
                fields["fast_mode"] = .bool(fast)
            }
            OrbReadCache.seed("mission:\(missionId)", value: .object(fields))
        }

        for listener in sub.listeners.values {
            listener(type, data, stored)
        }
    }
}
