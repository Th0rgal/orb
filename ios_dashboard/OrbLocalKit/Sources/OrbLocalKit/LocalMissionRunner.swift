import Foundation

/// Orb Core endpoints a client-owned mission uses. All exist in Core:
/// `client-run`, `client-events`, `client-transcript`, `client-status`,
/// `/api/control/clients`.
public protocol OrbCoreClient: Sendable {
    func post(_ path: String, _ body: JSONValue) async throws -> JSONValue
}

public struct RunReceipt: Codable, Equatable, Sendable {
    public var runID: String
    public var generation: UInt64
    public var prompt: String
}

/// Batches normalized events so a chatty harness does not issue one request
/// per token. Text deltas are coalesced to the latest accumulated value.
public struct EventBatcher: Sendable {
    public private(set) var pending: [JSONValue] = []
    public init() {}
    public mutating func add(_ event: OrbEvent) {
        guard let wire = event.wire else { return }
        if case .textDelta = event, let last = pending.last, last["type"].text == "text_delta" {
            pending[pending.count - 1] = wire
        } else {
            pending.append(wire)
        }
    }
    public mutating func take(max: Int = 256) -> [JSONValue] {
        let n = min(max, pending.count)
        defer { pending.removeFirst(n) }
        return Array(pending.prefix(n))
    }
    public var isEmpty: Bool { pending.isEmpty }
}

/// Runs phone-owned missions: claims the run in Core, drives one
/// `IOSLocalHarness`, streams its events into the existing conversation,
/// checkpoints after every change, and settles status. Never hands execution
/// to Core: suspension is recorded as such and resumed on the phone.
public actor LocalMissionRunner {
    public typealias HarnessFactory = @Sendable (HarnessKind, String?) -> (any IOSLocalHarness)?

    private let core: any OrbCoreClient
    private let clientID: String
    private let checkpoints: CheckpointStore
    private let makeHarness: HarnessFactory
    private var live: [String: Live] = [:]
    public private(set) var states: [String: LocalMissionState] = [:]
    private var observers: [UUID: @Sendable (String, LocalMissionState) -> Void] = [:]

    struct Live {
        var harness: any IOSLocalHarness
        var pump: Task<Void, Never>
        var receipt: RunReceipt
        var checkpoint: LocalMissionCheckpoint
    }

    public init(core: any OrbCoreClient, clientID: String, checkpoints: CheckpointStore, makeHarness: @escaping HarnessFactory) {
        self.core = core
        self.clientID = clientID
        self.checkpoints = checkpoints
        self.makeHarness = makeHarness
    }

    public func observe(_ handler: @escaping @Sendable (String, LocalMissionState) -> Void) -> UUID {
        let id = UUID(); observers[id] = handler; return id
    }

    public func isRunning(_ mission: String) -> Bool { live[mission] != nil }

    /// Start (or continue) a turn on a phone-owned mission. `engine` selects a
    /// harness implementation when several share a kind (e.g. the native
    /// computer-use loop vs. the Codex CLI).
    public func run(mission: String, configuration base: HarnessConfiguration, prompt: String, engine: String? = nil) async throws {
        if let existing = live[mission] {
            try await existing.harness.send(prompt)
            return
        }
        guard let harness = makeHarness(base.harness, engine) else {
            throw HarnessError.runtimeUnavailable("\(base.harness.displayName) is not available on this iPhone")
        }
        let begun = try await core.post("/api/control/missions/\(mission)/client-run", [
            "op": "begin", "client_id": .string(clientID), "prompt": .string(prompt),
            "cwd": .string(base.workingDirectory), "session_id": base.sessionID.map(JSONValue.string) ?? .null,
        ])
        guard let runID = begun["run_id"].string, let generation = begun["generation"].number else {
            throw HarnessError.protocolError("Core did not grant a run")
        }
        let receipt = RunReceipt(runID: runID, generation: UInt64(generation), prompt: begun["prompt"].string ?? prompt)
        var configuration = base
        configuration.prompt = receipt.prompt
        let checkpoint = LocalMissionCheckpoint(
            missionID: mission, clientID: clientID, runID: runID, generation: receipt.generation, state: .running,
            harness: HarnessState(configuration: configuration, sessionID: base.sessionID, transcript: ""),
            inflightPrompt: receipt.prompt)
        try checkpoints.save(checkpoint)
        let pump = Task { [weak self] () -> Void in await self?.pump(mission: mission, harness: harness) }
        live[mission] = Live(harness: harness, pump: pump, receipt: receipt, checkpoint: checkpoint)
        set(mission, .running)
        try await harness.start(configuration)
    }

    public func send(mission: String, text: String) async throws {
        guard let l = live[mission] else { throw HarnessError.notStarted }
        try await l.harness.send(text)
    }

    public func interrupt(mission: String) async throws { try await live[mission]?.harness.interrupt() }

    public func stop(mission: String) async {
        guard let l = live[mission] else { return }
        try? await l.harness.terminate()
        await settle(mission, .interrupted)
    }

    public func lifecycle(_ signal: LifecycleSignal) async {
        for mission in Array(live.keys) {
            let next = LocalMissionLifecycle.next(states[mission] ?? .running, signal)
            set(mission, next)
            await persist(mission)
        }
    }

    /// Missions found on disk from a previous process. Their in-flight turn
    /// died with that process; the native session id lets the harness resume.
    public func recoverable() -> [LocalMissionCheckpoint] {
        checkpoints.all().filter { !$0.state.isTerminal }.map { c in
            var c = c
            c.state = LocalMissionLifecycle.next(c.state, .relaunched)
            return c
        }
    }

    /// Resume after relaunch: begin a new Core run (the old one is stale) and
    /// replay the interrupted prompt into the restored native session.
    public func resume(_ checkpoint: LocalMissionCheckpoint, engine: String? = nil) async throws {
        // The previous process's Core run is still open; close it with its own
        // receipt so `begin` can grant a fresh generation to this process.
        if let run = checkpoint.runID, let generation = checkpoint.generation {
            _ = try? await core.post("/api/control/missions/\(checkpoint.missionID)/client-status", [
                "status": "interrupted", "run_id": .string(run), "generation": .number(Double(generation)),
            ])
        }
        var config = checkpoint.harness.configuration
        config.sessionID = checkpoint.harness.sessionID
        let prompt = checkpoint.inflightPrompt.map {
            "Orb was suspended by iOS while you were working on the previous request; continue it.\n\n" + $0
        } ?? "Continue."
        try await run(mission: checkpoint.missionID, configuration: config, prompt: prompt, engine: engine)
    }

    public func discard(_ mission: String) { checkpoints.remove(mission) }

    private func pump(mission: String, harness: any IOSLocalHarness) async {
        var batch = EventBatcher()
        var lastFlush = Date()
        for await event in harness.events {
            switch event {
            case .session(let id):
                live[mission]?.checkpoint.harness.sessionID = id
                await persist(mission)
            case .turnCompleted(let text, let success):
                batch.add(.activity(label: success ? "Finished" : "Stopped", tool: "orb-ios"))
                await flush(mission, &batch)
                if !text.isEmpty { await transcript(mission, text) }
                live[mission]?.checkpoint.harness.transcript = text
                live[mission]?.checkpoint.inflightPrompt = nil
                if !(await harness.snapshot()?.pendingInput.isEmpty ?? true) { await persist(mission); continue }
                await settle(mission, success ? .completed : .failed)
                return
            default:
                batch.add(event)
                if batch.pending.count >= 32 || Date().timeIntervalSince(lastFlush) > 0.25 {
                    await flush(mission, &batch)
                    lastFlush = Date()
                }
            }
        }
    }

    private func flush(_ mission: String, _ batch: inout EventBatcher) async {
        guard let receipt = live[mission]?.receipt else { return }
        while !batch.isEmpty {
            let events = batch.take()
            _ = try? await core.post("/api/control/missions/\(mission)/client-events", [
                "run_id": .string(receipt.runID), "generation": .number(Double(receipt.generation)), "events": .array(events),
            ])
        }
    }

    private func transcript(_ mission: String, _ text: String) async {
        guard let receipt = live[mission]?.receipt else { return }
        _ = try? await core.post("/api/control/missions/\(mission)/client-transcript", [
            "id": .string(UUID().uuidString.lowercased()), "role": "assistant", "content": .string(text),
            "run_id": .string(receipt.runID), "generation": .number(Double(receipt.generation)),
        ])
    }

    private func settle(_ mission: String, _ state: LocalMissionState) async {
        guard let l = live.removeValue(forKey: mission) else { return }
        l.pump.cancel()
        set(mission, state)
        if let status = state.coreStatus {
            _ = try? await core.post("/api/control/missions/\(mission)/client-status", [
                "status": .string(status), "run_id": .string(l.receipt.runID), "generation": .number(Double(l.receipt.generation)),
            ])
        }
        var c = l.checkpoint
        c.state = state
        c.updatedAt = Date()
        // Keep the native session id for follow-ups; drop the run receipt.
        c.runID = nil; c.generation = nil
        try? checkpoints.save(c)
    }

    private func persist(_ mission: String) async {
        guard var l = live[mission] else { return }
        if let snap = await l.harness.snapshot() {
            l.checkpoint.harness.pendingInput = snap.pendingInput
            if let s = snap.sessionID { l.checkpoint.harness.sessionID = s }
        }
        l.checkpoint.state = states[mission] ?? .running
        l.checkpoint.updatedAt = Date()
        live[mission] = l
        try? checkpoints.save(l.checkpoint)
    }

    private func set(_ mission: String, _ state: LocalMissionState) {
        states[mission] = state
        for o in observers.values { o(mission, state) }
    }
}
