import BackgroundTasks
import Foundation
import OrbLocalKit
import UIKit
import UserNotifications

/// Bridges OrbLocalKit to Orb Core using the app's authenticated session.
struct OrbCoreBridge: OrbCoreClient {
    func post(_ path: String, _ body: JSONValue) async throws -> JSONValue {
        let wire = try JSONDecoder().decode(OrbJSON.self, from: body.encoded())
        let result = try await OrbCore.shared.call(path, method: "POST", body: wire)
        return JSONValue.parse(try JSONEncoder().encode(result)) ?? .null
    }
}

/// Responses API transport through Core's `/v1` proxy with a per-mission key.
final class CoreInferenceTransport: InferenceTransport, @unchecked Sendable {
    let base: String
    let key: String
    init(base: String, key: String) { self.base = base; self.key = key }
    func post(path: String, body: Data) async throws -> Data {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HarnessError.protocolError("Core inference proxy returned \(http.statusCode): \(String(decoding: data.prefix(400), as: UTF8.self))")
        }
        return data
    }
}

/// Stable identity of this iPhone as an Orb client. Nonisolated so value
/// types (e.g. `OrbRow`) can check mission ownership from any context.
enum OrbClientIdentity {
    static let id: String = {
        if let saved = UserDefaults.standard.string(forKey: "orb.clientID") { return saved }
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: "orb.clientID")
        return fresh
    }()
}

/// The iPhone as an Orb execution node. Owns client identity, the delivery
/// inbox, the mission runner and the iOS lifecycle around it.
@MainActor
@Observable
final class LocalAgentNode {
    static let shared = LocalAgentNode()
    nonisolated static let engineTag = "ios-engine:"
    nonisolated static let computerUseEngine = "computer-use"
    nonisolated static let cliEngine = "cli"

    var clientID: String { OrbClientIdentity.id }
    private(set) var registered = false
    private(set) var lastError = ""
    private(set) var states: [String: LocalMissionState] = [:]
    private(set) var runtimeStatus = RuntimeStatus(available: false, engine: "ish-arm64", detail: "Checking…")
    private(set) var harnessAvailability: [HarnessKind: HarnessAvailability] = [:]

    @ObservationIgnored private var runner: LocalMissionRunner?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var proxyKeys: [String: (id: String, key: String)] = [:]
    @ObservationIgnored private var continued: BGTask?
    @ObservationIgnored private var backgroundGrace: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var started = false

    private init() {}

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "orb.localAgents.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "orb.localAgents.enabled"); if newValue { start() } else { stop() } }
    }

    private var checkpointDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orb/local-missions", isDirectory: true)
    }

    func start() {
        guard enabled, !started, APIService.shared.isConfigured else { return }
        started = true
        let runner = LocalMissionRunner(core: OrbCoreBridge(), clientID: clientID, checkpoints: CheckpointStore(directory: checkpointDirectory)) { kind, engine in
            // Called off the main actor by the runner; resolve configuration via the node.
            LocalAgentNode.makeHarness(kind: kind, engine: engine)
        }
        self.runner = runner
        Task {
            _ = await runner.observe { mission, state in Task { @MainActor in LocalAgentNode.shared.states[mission] = state; LocalAgentNode.shared.stateChanged(mission, state) } }
            await refreshAvailability()
            await register()
            await recover()
        }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollInbox()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    func stop() {
        poller?.cancel(); poller = nil
        started = false
    }

    // MARK: Registration

    func register() async {
        await refreshAvailability()
        let caps = OrbIOSActionExecutor.shared.capabilities
        var harnesses = ["codex"]
        harnesses += harnessAvailability.filter { $0.value.isAvailable }.map(\.key.rawValue)
        let body: OrbJSON = .object([
            "client_id": .string(clientID), "platform": .string("ios"), "runtime": .string("ios"),
            "name": .string(UIDevice.current.name),
            "capabilities": .object(caps.registry.mapValues { .bool($0) }),
            "harnesses": .array(Array(Set(harnesses)).sorted().map(OrbJSON.string)),
            "detail": .object([
                "os": .string("iOS \(UIDevice.current.systemVersion)"),
                "unix_runtime": .string(runtimeStatus.detail),
                "agent_report": (try? JSONDecoder().decode(OrbJSON.self, from: caps.agentReport.encoded())) ?? .null,
            ]),
        ])
        do {
            _ = try await OrbCore.shared.call("/api/control/clients", method: "POST", body: body)
            registered = true
            lastError = ""
        } catch {
            registered = false
            lastError = "Could not register this iPhone with Core: \(error.localizedDescription)"
        }
    }

    func refreshAvailability() async {
        let runtime = ISHLinuxRuntime.shared
        runtimeStatus = await runtime.status()
        var result: [HarnessKind: HarnessAvailability] = [:]
        for kind in HarnessKind.allCases {
            result[kind] = runtimeStatus.available
                ? await CLIHarness(dialect: HarnessDialects.dialect(for: kind), runtime: runtime).availability()
                : .unavailable(reason: runtimeStatus.detail)
        }
        harnessAvailability = result
    }

    // MARK: Inbox → runner

    private struct Delivery: Codable { var target: String; var id: String; var content: String }
    private var pendingURL: URL { checkpointDirectory.appendingPathComponent("inbox.json") }

    private func pollInbox() async {
        guard registered, UIApplication.shared.applicationState != .background || continued != nil else { return }
        do {
            let inbox = try await OrbCore.shared.call("/api/control/clients/\(clientID)/inbox")
            var pending = (try? JSONDecoder().decode([Delivery].self, from: Data(contentsOf: pendingURL))) ?? []
            for message in inbox["messages"].items {
                let delivery = Delivery(target: message["target_mission_id"].text, id: message["id"].text, content: message["content"].text)
                guard !delivery.target.isEmpty, !pending.contains(where: { $0.id == delivery.id }) else { continue }
                // Persist locally before acknowledging so a crash cannot lose it.
                pending.append(delivery)
                try FileManager.default.createDirectory(at: checkpointDirectory, withIntermediateDirectories: true)
                try JSONEncoder().encode(pending).write(to: pendingURL, options: .atomic)
                _ = try await OrbCore.shared.call("/api/control/missions/\(delivery.target)/client-run", method: "POST",
                                                  body: .object(["op": .string("received"), "client_id": .string(clientID), "message_id": .string(delivery.id)]))
            }
            for delivery in pending {
                // A live mission receives it as a follow-up; otherwise a new turn starts.
                do {
                    try await deliver(delivery)
                } catch let error as HarnessError {
                    // Permanent on this iPhone: settle visibly instead of retrying forever.
                    await reportUnrunnable(delivery.target, error.localizedDescription)
                }
                pending.removeAll { $0.id == delivery.id }
                try JSONEncoder().encode(pending).write(to: pendingURL, options: .atomic)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func reportUnrunnable(_ mission: String, _ reason: String) async {
        lastError = reason
        _ = try? await OrbCore.shared.call("/api/control/missions/\(mission)/client-transcript", method: "POST", body: .object([
            "id": .string(UUID().uuidString.lowercased()), "role": .string("assistant"),
            "content": .string("This iPhone could not run the mission: \(reason)"),
        ]))
        _ = try? await OrbCore.shared.call("/api/control/missions/\(mission)/client-status", method: "POST", body: .object(["status": .string("failed")]))
    }

    private func deliver(_ delivery: Delivery) async throws {
        guard let runner else { return }
        let mission = try await OrbCore.shared.call("/api/control/missions/\(delivery.target)")
        let config = try await configuration(for: mission, prompt: delivery.content)
        let engine = engine(for: mission)
        beginContinuedProcessing(title: mission["title"].text)
        try await runner.run(mission: delivery.target, configuration: config, prompt: delivery.content, engine: engine)
    }

    private func engine(for mission: OrbJSON) -> String {
        mission["tags"].items.map(\.text).first { $0.hasPrefix(Self.engineTag) }.map { String($0.dropFirst(Self.engineTag.count)) }
            ?? (mission["backend"].text == "codex" && harnessAvailability[.codex]?.isAvailable != true ? Self.computerUseEngine : Self.cliEngine)
    }

    private func configuration(for mission: OrbJSON, prompt: String) async throws -> HarnessConfiguration {
        let id = mission["id"].text
        guard let kind = HarnessKind(rawValue: mission["backend"].text) else {
            throw HarnessError.unsupported("\(mission["backend"].text) cannot run on iPhone")
        }
        let key = try await proxyKey(for: id)
        let project = mission["project"].text.isEmpty ? "default" : mission["project"].text
        let cwd = "/root/work/" + project.filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        try? FileManager.default.createDirectory(at: ISHLinuxRuntime.shared.guestToHost(cwd), withIntermediateDirectories: true)
        let mcp = try LoopbackMCPServer.shared.start(server: IOSComputerMCPServer(executor: OrbIOSActionExecutor.shared))
        let previous = CheckpointStore(directory: checkpointDirectory).load(id)
        return HarnessConfiguration(
            missionID: id, harness: kind, workingDirectory: cwd, prompt: prompt,
            model: mission["model_override"].text.isEmpty ? nil : mission["model_override"].text,
            effort: mission["model_effort"].text.isEmpty ? nil : mission["model_effort"].text,
            inferenceBaseURL: OrbCore.shared.endpoint + "/v1", inferenceKey: key,
            mcpServers: [mcp], environment: ["ORB_MISSION_ID": id],
            sessionID: previous?.harness.sessionID)
    }

    /// One Core proxy key per phone mission; revoked when the mission settles.
    private func proxyKey(for mission: String) async throws -> String {
        if let existing = proxyKeys[mission] { return existing.key }
        let created = try await OrbCore.shared.call("/api/proxy-keys", method: "POST", body: .object(["name": .string("Orb iPhone \(mission)")]))
        guard !created["key"].text.isEmpty else { throw HarnessError.protocolError("Core did not return a proxy key") }
        proxyKeys[mission] = (created["id"].text, created["key"].text)
        return created["key"].text
    }

    nonisolated static func makeHarness(kind: HarnessKind, engine: String?) -> (any IOSLocalHarness)? {
        if engine == computerUseEngine {
            // The transport is resolved per mission; see `ComputerUseHarnessProxy`.
            return ComputerUseHarnessProxy()
        }
        return CLIHarness(dialect: HarnessDialects.dialect(for: kind), runtime: ISHLinuxRuntime.shared)
    }

    func stop(mission: String) async {
        await runner?.stop(mission: mission)
    }

    // MARK: Lifecycle

    private func stateChanged(_ mission: String, _ state: LocalMissionState) {
        if state.isTerminal, let key = proxyKeys.removeValue(forKey: mission) {
            Task { _ = try? await OrbCore.shared.call("/api/proxy-keys/\(key.id)", method: "DELETE") }
        }
        if !states.values.contains(where: { !$0.isTerminal }) { endBackgroundWork() }
        if state == .suspendedByIOS || state == .resumeRequired { notifyResumeRequired() }
    }

    func scenePhaseChanged(_ phase: UIApplication.State) {
        guard let runner else { return }
        Task {
            switch phase {
            case .background:
                let continuing = continued != nil
                if !continuing { beginGrace() }
                await runner.lifecycle(.enteredBackground(continuedProcessing: continuing))
            case .active:
                endGrace()
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["orb.local.resume"])
                await runner.lifecycle(.enteredForeground)
                await register()
                await recover()
            default: break
            }
        }
    }

    /// Resume missions iOS terminated mid-turn. Requires Orb in the foreground.
    private func recover() async {
        guard let runner, UIApplication.shared.applicationState == .active else { return }
        for checkpoint in await runner.recoverable() {
            if await runner.isRunning(checkpoint.missionID) { continue }
            do {
                let mission = try await OrbCore.shared.call("/api/control/missions/\(checkpoint.missionID)")
                guard ["active", "pending", "running", "awaiting_user", "interrupted"].contains(mission["status"].text),
                      mission["tags"].items.contains(where: { $0.text == "worker-client:\(clientID)" }) else {
                    await runner.discard(checkpoint.missionID); continue
                }
                var c = checkpoint
                c.harness.configuration = try await configuration(for: mission, prompt: checkpoint.inflightPrompt ?? "Continue.")
                c.harness.configuration.sessionID = checkpoint.harness.sessionID
                try await runner.resume(c, engine: engine(for: mission))
            } catch {
                lastError = "Could not resume \(checkpoint.missionID): \(error.localizedDescription)"
            }
        }
    }

    /// iOS 26 continued processing: user-initiated work keeps running in the
    /// background with a system progress UI the user can cancel.
    private func beginContinuedProcessing(title: String) {
        guard continued == nil, UIApplication.shared.applicationState == .active else { return }
        let identifier = "md.thomas.openagent.dashboard.agent.\(UUID().uuidString.prefix(8))"
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] bgTask in
            guard let bgTask = bgTask as? BGContinuedProcessingTask else { bgTask.setTaskCompleted(success: false); return }
            // Delivered on the main queue (`using: .main`).
            nonisolated(unsafe) let task = bgTask
            MainActor.assumeIsolated {
                self?.continued = task
                task.progress.totalUnitCount = 100
                task.expirationHandler = { Task { @MainActor in
                    await LocalAgentNode.shared.runner?.lifecycle(.backgroundTimeExpired)
                    LocalAgentNode.shared.continued = nil
                } }
                Task { @MainActor in
                    var tick: Int64 = 0
                    while let self, self.continued === task, self.states.values.contains(where: { !$0.isTerminal }) {
                        tick = min(95, tick + 1)
                        task.progress.completedUnitCount = tick
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                    }
                    task.progress.completedUnitCount = 100
                    task.setTaskCompleted(success: true)
                    self?.continued = nil
                }
            }
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Orb agent running", subtitle: title.isEmpty ? "On this iPhone" : title)
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) } catch { lastError = "Background continuation unavailable: \(error.localizedDescription)" }
    }

    private func endBackgroundWork() { endGrace() }

    private func beginGrace() {
        guard backgroundGrace == .invalid else { return }
        backgroundGrace = UIApplication.shared.beginBackgroundTask(withName: "orb.local.grace") { [weak self] in
            Task { @MainActor in
                await self?.runner?.lifecycle(.backgroundTimeExpired)
                self?.endGrace()
            }
        }
    }

    private func endGrace() {
        if backgroundGrace != .invalid { UIApplication.shared.endBackgroundTask(backgroundGrace); backgroundGrace = .invalid }
    }

    private func notifyResumeRequired() {
        let content = UNMutableNotificationContent()
        content.title = "Your iPhone agent is paused"
        content.body = "iOS suspended Orb. Open Orb to let the agent continue on this iPhone."
        content.userInfo = ["orb_resume_local": true]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "orb.local.resume", content: content, trigger: nil))
    }
}

/// Lazily binds a `ComputerUseAgent` to its mission's proxy key when started.
final class ComputerUseHarnessProxy: IOSLocalHarness, @unchecked Sendable {
    let kind: HarnessKind = .codex
    private let lock = NSLock()
    private var inner: ComputerUseAgent?
    private let continuation: AsyncStream<OrbEvent>.Continuation
    let events: AsyncStream<OrbEvent>

    init() { (events, continuation) = AsyncStream.makeStream(of: OrbEvent.self, bufferingPolicy: .unbounded) }

    func availability() async -> HarnessAvailability { .available(version: ComputerUseAgent.engine) }

    func start(_ configuration: HarnessConfiguration) async throws {
        guard let base = configuration.inferenceBaseURL, let key = configuration.inferenceKey else {
            throw HarnessError.unsupported("Computer use needs Core's inference proxy")
        }
        let caps = await MainActor.run { OrbIOSActionExecutor.shared.capabilities }
        let agent = ComputerUseAgent(transport: CoreInferenceTransport(base: base, key: key), executor: OrbIOSActionExecutor.shared, capabilities: caps)
        lock.withLock { inner = agent }
        let continuation = continuation
        Task { for await event in agent.events { continuation.yield(event) } }
        try await agent.start(configuration)
    }

    func send(_ input: String) async throws { try await current().send(input) }
    func interrupt() async throws { try await current().interrupt() }
    func terminate() async throws { try await lock.withLock { inner }?.terminate() }
    func restore(_ state: HarnessState) async throws { try await start(state.configuration) }
    func snapshot() async -> HarnessState? { await lock.withLock { inner }?.snapshot() }
    private func current() throws -> ComputerUseAgent {
        guard let agent = lock.withLock({ inner }) else { throw HarnessError.notStarted }
        return agent
    }
}
