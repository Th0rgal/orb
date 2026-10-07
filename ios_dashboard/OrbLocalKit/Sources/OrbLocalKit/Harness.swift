import Foundation

/// Orb's normalized transcript event, the same shape Core's `AgentEvent`
/// persists (see `src/api/control/events.rs`). Local harnesses emit these and
/// the runner forwards them to `/api/control/missions/:id/client-events`.
public enum OrbEvent: Equatable, Sendable {
    case textDelta(String)
    case thinking(String, done: Bool)
    case toolCall(id: String, name: String, args: JSONValue)
    case toolResult(id: String, name: String, result: JSONValue)
    case activity(label: String, tool: String)
    case error(String, resumable: Bool)
    /// Native harness session identity, used for resume. Not sent to Core.
    case session(String)
    /// The turn finished. `text` is the final assistant answer for this turn.
    case turnCompleted(text: String, success: Bool)

    /// Wire form for `client-events`. `session`/`turnCompleted` are runner
    /// bookkeeping and map to `client-transcript`/`client-status` instead.
    public var wire: JSONValue? {
        switch self {
        case .textDelta(let text): return ["type": "text_delta", "content": .string(text)]
        case .thinking(let text, let done): return ["type": "thinking", "content": .string(text), "done": .bool(done)]
        case .toolCall(let id, let name, let args):
            return ["type": "tool_call", "tool_call_id": .string(id), "name": .string(name), "args": args]
        case .toolResult(let id, let name, let result):
            return ["type": "tool_result", "tool_call_id": .string(id), "name": .string(name), "result": result]
        case .activity(let label, let tool): return ["type": "activity", "label": .string(label), "tool_name": .string(tool)]
        case .error(let message, let resumable): return ["type": "error", "message": .string(message), "resumable": .bool(resumable)]
        case .session, .turnCompleted: return nil
        }
    }
}

public enum HarnessKind: String, CaseIterable, Codable, Sendable {
    case claudeCode = "claudecode"
    case codex = "codex"
    case antigravity = "antigravity"
    case openCode = "opencode"

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .openCode: "OpenCode"
        }
    }
}

public enum HarnessAvailability: Equatable, Sendable {
    case available(version: String?)
    /// Installable inside the local runtime (e.g. `npm i -g`), not yet present.
    case installable(command: String)
    case unavailable(reason: String)

    public var isAvailable: Bool { if case .available = self { return true }; return false }
}

public struct HarnessConfiguration: Equatable, Sendable, Codable {
    public var missionID: String
    public var harness: HarnessKind
    public var workingDirectory: String
    public var prompt: String
    public var model: String?
    public var effort: String?
    /// OpenAI/Anthropic-compatible endpoint the harness should talk to. On iOS
    /// this is Core's `/v1` proxy with a per-run proxy key, so provider
    /// credentials never land on the phone's filesystem.
    public var inferenceBaseURL: String?
    public var inferenceKey: String?
    /// MCP servers the harness should load, e.g. the on-device iOS computer.
    public var mcpServers: [MCPServerConfig]
    public var environment: [String: String]
    public var sessionID: String?

    public init(missionID: String, harness: HarnessKind, workingDirectory: String, prompt: String,
                model: String? = nil, effort: String? = nil, inferenceBaseURL: String? = nil,
                inferenceKey: String? = nil, mcpServers: [MCPServerConfig] = [],
                environment: [String: String] = [:], sessionID: String? = nil) {
        self.missionID = missionID; self.harness = harness; self.workingDirectory = workingDirectory
        self.prompt = prompt; self.model = model; self.effort = effort
        self.inferenceBaseURL = inferenceBaseURL; self.inferenceKey = inferenceKey
        self.mcpServers = mcpServers; self.environment = environment; self.sessionID = sessionID
    }
}

public struct MCPServerConfig: Equatable, Sendable, Codable {
    public var name: String
    /// Streamable HTTP endpoint (the in-app loopback server).
    public var url: String
    public var bearerToken: String?
    public init(name: String, url: String, bearerToken: String? = nil) {
        self.name = name; self.url = url; self.bearerToken = bearerToken
    }
}

/// Everything needed to continue a harness after iOS terminated Orb.
public struct HarnessState: Equatable, Sendable, Codable {
    public var configuration: HarnessConfiguration
    public var sessionID: String?
    public var transcript: String
    public var pendingInput: [String]
    public init(configuration: HarnessConfiguration, sessionID: String?, transcript: String, pendingInput: [String] = []) {
        self.configuration = configuration; self.sessionID = sessionID
        self.transcript = transcript; self.pendingInput = pendingInput
    }
}

/// The single harness abstraction. All four CLIs are driven through the same
/// implementation (`CLIHarness`) and differ only in their `HarnessDialect`.
public protocol IOSLocalHarness: AnyObject, Sendable {
    var kind: HarnessKind { get }
    func availability() async -> HarnessAvailability
    func start(_ configuration: HarnessConfiguration) async throws
    func send(_ input: String) async throws
    func interrupt() async throws
    func terminate() async throws
    func restore(_ state: HarnessState) async throws
    var events: AsyncStream<OrbEvent> { get }
    func snapshot() async -> HarnessState?
}

/// A process launched inside the local Unix runtime. On device this is backed
/// by the ARM64 Linux interpreter; in tests by a scripted fake.
public protocol RuntimeProcess: AnyObject, Sendable {
    func write(_ data: Data) async throws
    func closeInput() async
    func signal(_ signal: Int32) async
    /// stdout lines, then finishes when the process exits.
    var lines: AsyncStream<String> { get }
    var stderrLines: AsyncStream<String> { get }
    func waitForExit() async -> Int32
}

public struct LaunchSpec: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String
    /// Files to materialize before launch (paths relative to the guest root).
    public var files: [String: String]
    public init(executable: String, arguments: [String], environment: [String: String] = [:],
                workingDirectory: String, files: [String: String] = [:]) {
        self.executable = executable; self.arguments = arguments
        self.environment = environment; self.workingDirectory = workingDirectory; self.files = files
    }
}

public protocol UnixRuntime: AnyObject, Sendable {
    /// Human-readable status for the capability report.
    func status() async -> RuntimeStatus
    func launch(_ spec: LaunchSpec) async throws -> RuntimeProcess
    /// Runs a short command to completion (probes, installs, git).
    func run(_ command: String, cwd: String?, timeout: TimeInterval) async throws -> (code: Int32, output: String)
}

public struct RuntimeStatus: Equatable, Sendable, Codable {
    public var available: Bool
    public var engine: String
    public var detail: String
    public var shell: Bool
    public var pty: Bool
    public var processes: Bool
    public var sockets: Bool
    public init(available: Bool, engine: String, detail: String, shell: Bool = false,
                pty: Bool = false, processes: Bool = false, sockets: Bool = false) {
        self.available = available; self.engine = engine; self.detail = detail
        self.shell = shell; self.pty = pty; self.processes = processes; self.sockets = sockets
    }
}

public enum HarnessError: Error, Equatable, LocalizedError {
    case runtimeUnavailable(String)
    case notStarted
    case alreadyRunning
    case unsupported(String)
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .runtimeUnavailable(let s): "Local runtime unavailable: \(s)"
        case .notStarted: "The harness is not running"
        case .alreadyRunning: "The harness is already running a turn"
        case .unsupported(let s): s
        case .protocolError(let s): s
        }
    }
}
