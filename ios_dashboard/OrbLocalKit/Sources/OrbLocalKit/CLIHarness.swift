import Foundation

/// The one execution engine behind every `IOSLocalHarness`. It owns turn
/// sequencing, queued input, interruption and checkpointing; the dialect only
/// supplies argv and a stream parser.
public final class CLIHarness: IOSLocalHarness, @unchecked Sendable {
    public let kind: HarnessKind
    private let dialect: any HarnessDialect
    private let runtime: any UnixRuntime
    private let lock = NSLock()
    private var configuration: HarnessConfiguration?
    private var session: String?
    private var transcript = ""
    private var queue: [String] = []
    private var process: (any RuntimeProcess)?
    private var turn: Task<Void, Never>?
    private let continuation: AsyncStream<OrbEvent>.Continuation
    public let events: AsyncStream<OrbEvent>

    public init(dialect: any HarnessDialect, runtime: any UnixRuntime) {
        self.kind = dialect.kind
        self.dialect = dialect
        self.runtime = runtime
        (events, continuation) = AsyncStream.makeStream(of: OrbEvent.self, bufferingPolicy: .unbounded)
    }

    public func availability() async -> HarnessAvailability {
        let status = await runtime.status()
        guard status.available else { return .unavailable(reason: status.detail) }
        guard let probe = try? await runtime.run("command -v \(dialect.executable) && \(dialect.executable) --version", cwd: nil, timeout: 60) else {
            return .unavailable(reason: "Runtime probe failed")
        }
        if probe.code == 0 {
            let version = probe.output.split(separator: "\n").last.map(String.init)
            return .available(version: version)
        }
        return dialect.installCommand.isEmpty
            ? .unavailable(reason: "\(kind.displayName) has no build for the on-device Linux runtime")
            : .installable(command: dialect.installCommand)
    }

    public func start(_ configuration: HarnessConfiguration) async throws {
        let busy: Bool = lock.withLock {
            if turn != nil { return true }
            self.configuration = configuration
            self.session = configuration.sessionID
            return false
        }
        if busy { throw HarnessError.alreadyRunning }
        begin(prompt: configuration.prompt)
    }

    public func send(_ input: String) async throws {
        let action: (prompt: String?, configured: Bool) = lock.withLock {
            guard configuration != nil else { return (nil, false) }
            if turn != nil { queue.append(input); return (nil, true) }
            return (input, true)
        }
        guard action.configured else { throw HarnessError.notStarted }
        if let prompt = action.prompt { begin(prompt: prompt) }
    }

    public func interrupt() async throws {
        let running = lock.withLock { process }
        await running?.signal(2)
    }

    public func terminate() async throws {
        let (running, task): ((any RuntimeProcess)?, Task<Void, Never>?) = lock.withLock {
            queue.removeAll()
            return (process, turn)
        }
        await running?.signal(9)
        task?.cancel()
        _ = await task?.value
    }

    public func restore(_ state: HarnessState) async throws {
        let pending: [String] = lock.withLock {
            configuration = state.configuration
            session = state.sessionID
            transcript = state.transcript
            queue = state.pendingInput
            return queue
        }
        if !pending.isEmpty {
            let first = lock.withLock { queue.removeFirst() }
            begin(prompt: first)
        }
    }

    public func snapshot() async -> HarnessState? {
        lock.withLock {
            configuration.map { HarnessState(configuration: $0, sessionID: session, transcript: transcript, pendingInput: queue) }
        }
    }

    public var isRunning: Bool { lock.withLock { turn != nil } }

    private func begin(prompt: String) {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runTurn(prompt: prompt)
            let next: String? = self.lock.withLock {
                self.turn = nil
                self.process = nil
                return self.queue.isEmpty ? nil : self.queue.removeFirst()
            }
            if let next, !Task.isCancelled { self.begin(prompt: next) }
        }
        lock.withLock { turn = task }
    }

    private func runTurn(prompt: String) async {
        guard let (config, resume) = lock.withLock({ configuration.map { ($0, session) } }) else { return }
        let spec = dialect.launch(config, prompt: prompt, session: resume)
        let parser = dialect.parser()
        let process: any RuntimeProcess
        do {
            process = try await runtime.launch(spec)
        } catch {
            emit(.error("Cannot start \(kind.displayName): \(error.localizedDescription)", resumable: true))
            emit(.turnCompleted(text: "", success: false))
            return
        }
        lock.withLock { self.process = process }
        let stderr = Task { () -> String in
            var tail = ""
            for await line in process.stderrLines { tail = String((tail + line + "\n").suffix(4000)) }
            return tail
        }
        for await line in process.lines {
            for event in parser.consume(line) { emit(event) }
        }
        let code = await process.waitForExit()
        for event in parser.finish(exitCode: code, stderr: await stderr.value) { emit(event) }
    }

    private func emit(_ event: OrbEvent) {
        lock.withLock {
            switch event {
            case .session(let id): session = id
            case .turnCompleted(let text, _): if !text.isEmpty { transcript = text }
            default: break
            }
        }
        continuation.yield(event)
    }
}
