import Foundation

/// HTTP seam so the loop is testable on Linux; the app supplies URLSession.
public protocol InferenceTransport: Sendable {
    func post(path: String, body: Data) async throws -> Data
}

/// In-process OpenAI Computer Use agent loop (Responses API `computer` tool)
/// bound to the iPhone. It needs no Unix runtime, so it is the computer-use
/// path that works on every device; the Codex CLI reaches the same executor
/// through `IOSComputerMCPServer`.
///
/// Loop: screenshot → model → `computer_call` / `function_call` → iOS action →
/// new screenshot → model … until the model answers without tool calls.
/// Requests are stateless (full input, `store:false`) because ChatGPT-backed
/// Codex accounts behind Orb Core's proxy reject `previous_response_id`.
public final class ComputerUseAgent: IOSLocalHarness, @unchecked Sendable {
    public let kind: HarnessKind = .codex
    public static let engine = "orb-native-responses-computer-use"
    /// GA `computer` tool model (Responses API). Overridable per mission.
    public static let defaultModel = "gpt-5.4"
    public var maxSteps = 40
    /// Keep only the most recent screenshots in context; older ones become text.
    public var retainedImages = 3

    private let transport: any InferenceTransport
    private let executor: any IOSActionExecutor
    private let capabilities: DeviceCapabilities
    private let lock = NSLock()
    private var configuration: HarnessConfiguration?
    private var input: [JSONValue] = []
    private var transcript = ""
    private var queue: [String] = []
    private var turn: Task<Void, Never>?
    private var interrupted = false
    private let continuation: AsyncStream<OrbEvent>.Continuation
    public let events: AsyncStream<OrbEvent>

    public init(transport: any InferenceTransport, executor: any IOSActionExecutor, capabilities: DeviceCapabilities) {
        self.transport = transport
        self.executor = executor
        self.capabilities = capabilities
        (events, continuation) = AsyncStream.makeStream(of: OrbEvent.self, bufferingPolicy: .unbounded)
    }

    public func availability() async -> HarnessAvailability { .available(version: Self.engine) }

    public func start(_ configuration: HarnessConfiguration) async throws {
        let busy = lock.withLock { () -> Bool in
            if turn != nil { return true }
            self.configuration = configuration
            return false
        }
        if busy { throw HarnessError.alreadyRunning }
        begin(configuration.prompt)
    }

    public func send(_ text: String) async throws {
        let now: String? = try lock.withLock {
            guard configuration != nil else { throw HarnessError.notStarted }
            if turn != nil { queue.append(text); return nil }
            return text
        }
        if let now { begin(now) }
    }

    public func interrupt() async throws { lock.withLock { interrupted = true } }

    public func terminate() async throws {
        let task = lock.withLock { () -> Task<Void, Never>? in queue.removeAll(); interrupted = true; return turn }
        task?.cancel()
        _ = await task?.value
    }

    public func restore(_ state: HarnessState) async throws {
        let next: String? = lock.withLock {
            configuration = state.configuration
            transcript = state.transcript
            // Only text history survives a restart; screenshots are re-taken.
            if !state.transcript.isEmpty {
                input = [["role": "user", "content": .string(state.configuration.prompt)],
                         ["role": "assistant", "content": .string(state.transcript)]]
            }
            queue = state.pendingInput
            return queue.isEmpty ? nil : queue.removeFirst()
        }
        if let next { begin(next) }
    }

    public func snapshot() async -> HarnessState? {
        lock.withLock { configuration.map { HarnessState(configuration: $0, sessionID: nil, transcript: transcript, pendingInput: queue) } }
    }

    private func begin(_ prompt: String) {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(prompt)
            let next: String? = self.lock.withLock {
                self.turn = nil
                return self.queue.isEmpty ? nil : self.queue.removeFirst()
            }
            if let next, !Task.isCancelled { self.begin(next) }
        }
        lock.withLock { turn = task; interrupted = false }
    }

    public static let functionTools: [JSONValue] = IOSComputerMCPServer.tools
        .filter { !["screenshot", "wait", "type_text"].contains($0["name"].text) }
        .map { ["type": "function", "name": $0["name"], "description": $0["description"], "parameters": $0["inputSchema"]] }

    func instructions() -> String {
        """
        You operate the user's iPhone through public iOS APIs. Capabilities: \(capabilities.agentReport.compact)
        You cannot click, tap, scroll or drag in other apps; such computer actions will be refused. \
        Move between apps with open_url/open_app/app_action/run_shortcut, type with the computer `type` action \
        (Orb keyboard, focused field only) and verify every step with a fresh screenshot. Never enter passwords or payment data.
        """
    }

    private func run(_ prompt: String) async {
        guard let config = lock.withLock({ configuration }) else { return }
        var items = lock.withLock { input }
        var userContent: [JSONValue] = [["type": "input_text", "text": .string(prompt)]]
        let first = await executor.perform(.screenshot(maxDimension: nil))
        if let frame = first.frame {
            userContent.append(["type": "input_image", "image_url": .string(frame.dataURL), "detail": "original"])
        }
        items.append(["role": "user", "content": .array(userContent)])
        var answer = ""
        var success = true
        steps: for step in 0..<maxSteps {
            if Task.isCancelled || lock.withLock({ interrupted }) {
                continuation.yield(.error("Interrupted", resumable: true)); success = false; break
            }
            let body: JSONValue = [
                "model": .string(config.model.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultModel),
                "instructions": .string(instructions()),
                "tools": .array([["type": "computer"]] + Self.functionTools),
                "input": .array(Self.pruneImages(items, keep: retainedImages)),
                "truncation": "auto", "store": false, "stream": true,
                "reasoning": ["summary": "auto"],
            ]
            let response: JSONValue
            do {
                let data = try await transport.post(path: "/responses", body: body.encoded())
                response = try Self.decodeResponse(data)
            } catch {
                continuation.yield(.error("Computer use request failed: \(error.localizedDescription)", resumable: true))
                success = false
                break
            }
            if let message = response.pointer("/error/message").string {
                continuation.yield(.error(message, resumable: true)); success = false; break
            }
            var acted = false
            for item in response["output"].array {
                items.append(item)
                switch item["type"].text {
                case "reasoning":
                    let summary = item["summary"].array.map { $0["text"].text }.joined(separator: "\n")
                    if !summary.isEmpty { continuation.yield(.thinking(summary, done: true)) }
                case "message":
                    let text = item["content"].array.filter { $0["type"].text == "output_text" }.map { $0["text"].text }.joined()
                    if !text.isEmpty { answer += answer.isEmpty ? text : "\n\n" + text; continuation.yield(.textDelta(answer)) }
                case "computer_call":
                    acted = true
                    items.append(contentsOf: await computerCall(item, step: step))
                case "function_call":
                    acted = true
                    items.append(contentsOf: await functionCall(item))
                default: break
                }
            }
            if !acted { break steps }
            if step == maxSteps - 1 { continuation.yield(.error("Stopped after \(maxSteps) computer-use steps", resumable: true)) }
        }
        lock.withLock {
            input = Self.pruneImages(items, keep: 0)
            if !answer.isEmpty { transcript = answer }
        }
        continuation.yield(.turnCompleted(text: answer, success: success))
    }

    private func computerCall(_ item: JSONValue, step: Int) async -> [JSONValue] {
        let callID = item["call_id"].text
        // GA `computer` emits `actions` (batched); the preview tool emits `action`.
        let actions = item["actions"].array.isEmpty ? [item["action"]] : item["actions"].array
        var notes: [String] = []
        var frame: ScreenFrame?
        for (index, action) in actions.enumerated() where !action.isNull {
            let toolID = "\(callID)#\(index)"
            continuation.yield(.toolCall(id: toolID, name: "computer.\(action["type"].text)", args: action))
            switch OpenAIComputerTranslator.translate(action) {
            case .refuse(let reason):
                notes.append(reason)
                continuation.yield(.toolResult(id: toolID, name: "computer.\(action["type"].text)", result: ["ok": false, "reason": .string(reason)]))
            case .perform(let steps):
                for s in steps {
                    let result = await executor.perform(s)
                    if let f = result.frame { frame = f }
                    if !result.ok { notes.append(result.detail["reason"].string ?? result.detail.compact) }
                }
                continuation.yield(.toolResult(id: toolID, name: "computer.\(action["type"].text)", result: ["ok": .bool(notes.isEmpty), "screen_sequence": frame.map { .number(Double($0.sequence)) } ?? .null]))
            }
        }
        if frame == nil { frame = await executor.perform(.screenshot(maxDimension: nil)).frame }
        var out: [JSONValue] = []
        var output: [String: JSONValue] = ["type": "computer_call_output", "call_id": .string(callID)]
        if let frame { output["output"] = ["type": "computer_screenshot", "image_url": .string(frame.dataURL)] }
        // Pending safety checks need a human; Orb surfaces them instead of auto-acknowledging.
        if !item["pending_safety_checks"].array.isEmpty {
            notes.append("Safety checks require user confirmation: \(item["pending_safety_checks"].array.map { $0["message"].text }.joined(separator: "; ")). Ask the user before continuing.")
        }
        out.append(.object(output))
        if !notes.isEmpty {
            out.append(["role": "user", "content": [["type": "input_text", "text": .string("Orb (iOS): " + notes.joined(separator: " "))]]])
        }
        return out
    }

    private func functionCall(_ item: JSONValue) async -> [JSONValue] {
        let callID = item["call_id"].text, name = item["name"].text
        let args = JSONValue.parse(item["arguments"].text) ?? [:]
        continuation.yield(.toolCall(id: callID, name: "computer.\(name)", args: args))
        let result: ComputerActionResult
        if let action = IOSComputerMCPServer.action(name, args) { result = await executor.perform(action) }
        else { result = .refused("Unknown function \(name)") }
        continuation.yield(.toolResult(id: callID, name: "computer.\(name)", result: result.detail))
        var out: [JSONValue] = [["type": "function_call_output", "call_id": .string(callID), "output": .string(result.detail.compact)]]
        if let frame = result.frame {
            out.append(["role": "user", "content": [["type": "input_text", "text": .string("Screen after \(name):")],
                                                    ["type": "input_image", "image_url": .string(frame.dataURL)]]])
        }
        return out
    }

    /// Accepts both a JSON response and an SSE stream ending in `response.completed`.
    public static func decodeResponse(_ data: Data) throws -> JSONValue {
        if let value = JSONValue.parse(data), !value["output"].isNull || !value["error"].isNull { return value }
        var last: JSONValue?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("data:") {
            guard let event = JSONValue.parse(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) else { continue }
            if ["response.completed", "response.failed", "response.incomplete"].contains(event["type"].text) { last = event["response"] }
            if event["type"].text == "error" { last = ["error": ["message": .string(event["message"].string ?? event.pointer("/error/message").text)]] }
        }
        guard let last else { throw HarnessError.protocolError("Responses stream ended without a completed response") }
        return last
    }

    /// Replace all but the newest `keep` images with a placeholder so context
    /// stays bounded across long computer-use sessions.
    public static func pruneImages(_ items: [JSONValue], keep: Int) -> [JSONValue] {
        var remaining = keep
        var out = items
        for i in out.indices.reversed() {
            let item = out[i]
            if item["type"].text == "computer_call_output", !item.pointer("/output/image_url").isNull {
                if remaining > 0 { remaining -= 1; continue }
                // A computer_call_output must keep a screenshot; use a 1x1 PNG.
                var o = item.object; o["output"] = ["type": "computer_screenshot", "image_url": .string(Self.blankPNG)]; out[i] = .object(o)
            } else if case .array(let content) = item["content"], content.contains(where: { $0["type"].text == "input_image" }) {
                if remaining > 0 { remaining -= 1; continue }
                var o = item.object
                o["content"] = .array(content.map { $0["type"].text == "input_image" ? ["type": "input_text", "text": "[earlier screenshot omitted]"] : $0 })
                out[i] = .object(o)
            }
        }
        return out
    }

    static let blankPNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
}
