import Foundation
@testable import OrbLocalKit

/// Scripted Unix runtime: each launch replays the next canned stdout.
final class FakeRuntime: UnixRuntime, @unchecked Sendable {
    let lock = NSLock()
    var scripts: [[String]]
    var exitCodes: [Int32]
    var launched: [LaunchSpec] = []
    var installed = true

    init(scripts: [[String]], exitCodes: [Int32] = []) {
        self.scripts = scripts
        self.exitCodes = exitCodes
    }

    func status() async -> RuntimeStatus {
        RuntimeStatus(available: true, engine: "fake", detail: "test", shell: true, pty: true, processes: true, sockets: true)
    }

    func launch(_ spec: LaunchSpec) async throws -> RuntimeProcess {
        let (lines, code): ([String], Int32) = lock.withLock {
            launched.append(spec)
            let l = scripts.isEmpty ? [] : scripts.removeFirst()
            let c = exitCodes.isEmpty ? 0 : exitCodes.removeFirst()
            return (l, c)
        }
        return FakeProcess(lines: lines, code: code)
    }

    func run(_ command: String, cwd: String?, timeout: TimeInterval) async throws -> (code: Int32, output: String) {
        installed ? (0, "/usr/bin/tool\n1.2.3") : (1, "")
    }
}

final class FakeProcess: RuntimeProcess, @unchecked Sendable {
    let lines: AsyncStream<String>
    let stderrLines: AsyncStream<String>
    let code: Int32
    var signals: [Int32] = []

    init(lines: [String], code: Int32) {
        self.code = code
        self.lines = AsyncStream { c in for l in lines { c.yield(l) }; c.finish() }
        self.stderrLines = AsyncStream { c in if code != 0 { c.yield("boom") }; c.finish() }
    }
    func write(_ data: Data) async throws {}
    func closeInput() async {}
    func signal(_ signal: Int32) async { signals.append(signal) }
    func waitForExit() async -> Int32 { code }
}

final class RecordingExecutor: IOSActionExecutor, @unchecked Sendable {
    let lock = NSLock()
    var actions: [IOSComputerAction] = []
    var sequence: UInt64 = 0

    func perform(_ action: IOSComputerAction) async -> ComputerActionResult {
        lock.withLock { actions.append(action) }
        switch action {
        case .screenshot, .wait, .typeText, .observe:
            let seq: UInt64 = lock.withLock { sequence += 1; return sequence }
            let frame = ScreenFrame(sequence: seq, capturedAt: Date(), width: 2, height: 4, mimeType: "image/jpeg",
                                    data: Data([0xFF, 0xD8, 0xFF]), text: [RecognizedText(string: "Search", confidence: 0.9, x: 0, y: 0, width: 1, height: 0.1)],
                                    source: "broadcast")
            return .init(ok: true, detail: ["ok": true], frame: frame)
        case .openURL(let url): return .init(ok: true, detail: ["ok": true, "opened": .string(url)])
        default: return .init(ok: true, detail: ["ok": true])
        }
    }
}

final class FakeCore: OrbCoreClient, @unchecked Sendable {
    let lock = NSLock()
    var posts: [(String, JSONValue)] = []
    func post(_ path: String, _ body: JSONValue) async throws -> JSONValue {
        lock.withLock { posts.append((path, body)) }
        if path.hasSuffix("/client-run") { return ["run_id": "run-1", "generation": 1, "prompt": body["prompt"]] }
        return ["ok": true]
    }
    func paths() -> [String] { lock.withLock { posts.map(\.0) } }
    func bodies(_ suffix: String) -> [JSONValue] { lock.withLock { posts.filter { $0.0.hasSuffix(suffix) }.map(\.1) } }
}

final class ScriptedTransport: InferenceTransport, @unchecked Sendable {
    let lock = NSLock()
    var responses: [JSONValue]
    var requests: [JSONValue] = []
    init(_ responses: [JSONValue]) { self.responses = responses }
    func post(path: String, body: Data) async throws -> Data {
        try lock.withLock {
            requests.append(JSONValue.parse(body) ?? .null)
            guard !responses.isEmpty else { throw HarnessError.protocolError("no scripted response") }
            return responses.removeFirst().encoded()
        }
    }
}

func collect(_ stream: AsyncStream<OrbEvent>, until done: (OrbEvent) -> Bool = { if case .turnCompleted = $0 { return true }; return false }) async -> [OrbEvent] {
    var out: [OrbEvent] = []
    for await e in stream { out.append(e); if done(e) { break } }
    return out
}
