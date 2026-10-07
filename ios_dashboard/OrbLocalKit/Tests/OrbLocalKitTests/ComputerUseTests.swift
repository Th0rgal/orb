import Foundation
import Testing
@testable import OrbLocalKit

@Suite struct ComputerUseTests {
    @Test func pointerActionsAreRefusedNotFaked() {
        for type in ["click", "double_click", "drag", "move", "scroll"] {
            guard case .refuse(let reason) = OpenAIComputerTranslator.translate(["type": .string(type), "x": 10, "y": 20]) else {
                Issue.record("\(type) must be refused"); continue
            }
            #expect(reason.contains("iOS does not allow"))
        }
        #expect(OpenAIComputerTranslator.translate(["type": "type", "text": "hello"]) == .perform([.typeText("hello"), .screenshot(maxDimension: nil)]))
        #expect(OpenAIComputerTranslator.translate(["type": "keypress", "keys": ["ENTER"]]) == .perform([.keyboardReturn, .screenshot(maxDimension: nil)]))
        if case .refuse = OpenAIComputerTranslator.translate(["type": "keypress", "keys": ["CMD", "C"]]) {} else { Issue.record("modifier chords are unsupported") }
    }

    @Test func capabilityReportStatesMissingPrimitive() {
        let caps = DeviceCapabilities(localAgents: true, unixShell: true, screenObservation: true, keyboardInjection: true)
        #expect(caps.agentReport["arbitrary_cross_app_tap"] == false)
        #expect(caps.agentReport["screen_read"] == true)
        #expect(caps.registry["arbitrary_ui_injection"] == false)
        #expect(caps.agentReport["background_app_open"] == "unknown")
    }

    @Test func agentLoopOpensAppTypesAndObserves() async throws {
        let executor = RecordingExecutor()
        let transport = ScriptedTransport([
            ["id": "r1", "output": [
                ["type": "reasoning", "summary": [["type": "summary_text", "text": "Open Maps first."]]],
                ["type": "function_call", "call_id": "f1", "name": "open_url", "arguments": #"{"url":"maps://?q=coffee"}"#],
            ]],
            ["id": "r2", "output": [
                ["type": "computer_call", "call_id": "c1", "actions": [["type": "click", "x": 5, "y": 5], ["type": "type", "text": "espresso"]], "pending_safety_checks": []],
            ]],
            ["id": "r3", "output": [["type": "message", "content": [["type": "output_text", "text": "Searched Maps for espresso."]]]]],
        ])
        let agent = ComputerUseAgent(transport: transport, executor: executor, capabilities: DeviceCapabilities(screenObservation: true, keyboardInjection: true))
        try await agent.start(HarnessConfiguration(missionID: "m", harness: .codex, workingDirectory: "/", prompt: "Find espresso nearby"))
        let events = await collect(agent.events)
        #expect(events.last == .turnCompleted(text: "Searched Maps for espresso.", success: true))
        #expect(events.contains(.thinking("Open Maps first.", done: true)))
        #expect(executor.actions.contains(.openURL("maps://?q=coffee")))
        #expect(executor.actions.contains(.typeText("espresso")))
        // The click was refused, and the model was told why.
        let third = transport.requests[2]["input"].array
        #expect(third.contains { $0["type"] == "computer_call_output" && $0["call_id"] == "c1" })
        #expect(third.contains { $0.pointer("/content/0/text").text.contains("iOS does not allow") })
        // First request carries a screenshot and the GA computer tool.
        #expect(transport.requests[0]["tools"][0] == ["type": "computer"])
        #expect(transport.requests[0]["store"] == false)
        #expect(transport.requests[0].pointer("/input/0/content/1/type") == "input_image")
    }

    @Test func pruningKeepsNewestScreenshotsOnly() {
        let shot: (String) -> JSONValue = { ["type": "computer_call_output", "call_id": .string($0), "output": ["type": "computer_screenshot", "image_url": "data:image/jpeg;base64,AAAA"]] }
        let pruned = ComputerUseAgent.pruneImages([shot("a"), shot("b"), shot("c")], keep: 1)
        #expect(pruned[2].pointer("/output/image_url") == "data:image/jpeg;base64,AAAA")
        #expect(pruned[0].pointer("/output/image_url").text.hasPrefix("data:image/png"))
    }

    @Test func sseResponsesDecode() throws {
        let sse = "event: response.created\ndata: {\"type\":\"response.created\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"output\":[]}}\n\n"
        #expect(try ComputerUseAgent.decodeResponse(Data(sse.utf8))["id"] == "r")
    }
}

@Suite struct MCPServerTests {
    @Test func toolsListAndCallRoundTrip() async throws {
        let executor = RecordingExecutor()
        let server = IOSComputerMCPServer(executor: executor)
        let initReply = await server.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26"]])
        #expect(initReply?.pointer("/result/protocolVersion") == "2025-03-26")
        let list = await server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let names = list?.pointer("/result/tools").array.map(\.["name"].text) ?? []
        #expect(names.contains("open_url") && names.contains("type_text") && names.contains("screenshot"))
        #expect(!names.contains("tap") && !names.contains("click"))
        let shot = await server.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "screenshot", "arguments": [:]]])
        #expect(shot?.pointer("/result/content/1/type") == "image")
        #expect(shot?.pointer("/result/content/0/text").text.contains("\"Search\"") == true)
        #expect(await server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        let unknown = await server.handle(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "tap", "arguments": ["x": 1]]])
        #expect(unknown?.pointer("/result/isError") == true)
    }
}

@Suite struct PerceptionTests {
    @Test func detectorIgnoresNoiseAndCatchesChanges() {
        var d = FrameChangeDetector(columns: 4, rows: 4, cellThreshold: 10, areaThreshold: 0.1, keyframeInterval: 1000)
        let a = [UInt8](repeating: 100, count: 16)
        var noisy = a; noisy[0] = 105
        var changed = a; for i in 0..<4 { changed[i] = 200 }
        let t = Date()
        let first = d.accept(a, at: t)
        let noise = d.accept(noisy, at: t)
        let change = d.accept(changed, at: t)
        let keyframe = d.accept(changed, at: t.addingTimeInterval(2000))
        #expect(first && !noise && change && keyframe)
    }

    @Test func signatureDownsamples() {
        let d = FrameChangeDetector(columns: 2, rows: 2)
        var pixels = [UInt8](repeating: 0, count: 8 * 8)
        for y in 0..<4 { for x in 0..<4 { pixels[y * 8 + x] = 255 } }
        let sig = pixels.withUnsafeBufferPointer { d.signature(luma: $0, width: 8, height: 8, bytesPerRow: 8) }
        #expect(sig == [255, 0, 0, 0])
    }

    @Test func scaling() {
        #expect(scaledFrameSize(width: 1179, height: 2556, maxDimension: 1024) == (472, 1024))
        #expect(scaledFrameSize(width: 300, height: 600, maxDimension: 1024) == (300, 600))
    }
}

@Suite struct KeyboardAndRegistryTests {
    @Test func keyboardQueueRoundTripAndExpiry() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = KeyboardCommandQueue(root: dir), keyboard = KeyboardCommandQueue(root: dir)
        let insert = KeyboardCommand(kind: .insert, text: "hello")
        let stale = KeyboardCommand(kind: .delete, count: 1, createdAt: Date().addingTimeInterval(-60), ttl: 5)
        try app.enqueue(insert); try app.enqueue(stale)
        let drained = keyboard.drain()
        #expect(drained.map(\.id) == [insert.id])
        #expect(app.result(for: stale.id)?.reason == "expired")
        keyboard.complete(KeyboardResult(id: insert.id, ok: true, before: "hello"))
        #expect(app.result(for: insert.id)?.before == "hello")
        #expect(app.result(for: insert.id) == nil)
        keyboard.setPresence(KeyboardPresence(visible: true, fullAccess: true))
        #expect(app.presence()?.isActive() == true)
        #expect(throws: HarnessError.self) { try app.enqueue(KeyboardCommand(kind: .insert, text: String(repeating: "a", count: 5000))) }
    }

    @Test func registryBuildsEncodedVerifiedURLs() throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let registry = AppRegistry(store: store)
        #expect(try registry.url(app: "Telegram", action: "open_chat", parameters: ["username": "durov"]).absoluteString == "tg://resolve?domain=durov")
        #expect(try registry.url(app: "maps", action: "search", parameters: ["query": "coffee & tea"]).absoluteString == "maps://?q=coffee%20%26%20tea")
        #expect(try registry.url(app: "safari", action: "open", parameters: ["url": "https://example.com/a?b=c"]).absoluteString == "https://example.com/a?b=c")
        #expect(throws: AppRegistryError.missingParameter("number")) { try registry.url(app: "phone", action: "call", parameters: [:]) }
        registry.observe("telegram") { $0.installed = true; $0.verifiedActions["open_chat"] = true }
        #expect(AppRegistry(store: store).observation("telegram")?.verifiedActions["open_chat"] == true)
        #expect(registry.querySchemes.count <= 25)
    }
}

@Suite struct RunnerTests {
    @Test func lifecycleTransitions() {
        #expect(LocalMissionLifecycle.next(.running, .enteredBackground(continuedProcessing: true)) == .backgroundRunning)
        #expect(LocalMissionLifecycle.next(.running, .enteredBackground(continuedProcessing: false)) == .suspendedByIOS)
        #expect(LocalMissionLifecycle.next(.backgroundRunning, .backgroundTimeExpired) == .suspendedByIOS)
        #expect(LocalMissionLifecycle.next(.suspendedByIOS, .relaunched) == .resumeRequired)
        #expect(LocalMissionLifecycle.next(.resumeRequired, .turnStarted) == .running)
        #expect(LocalMissionLifecycle.next(.completed, .enteredForeground) == .completed)
        #expect(LocalMissionState.suspendedByIOS.coreStatus == nil)
        #expect(LocalMissionState.completed.coreStatus == "awaiting_user")
    }

    @Test func runnerStreamsEventsSettlesAndCheckpoints() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let core = FakeCore()
        let runtime = FakeRuntime(scripts: [[
            #"{"type":"thread.started","thread_id":"th"}"#,
            #"{"type":"item.started","item":{"id":"c1","type":"mcp_tool_call","server":"ios","tool":"open_url","arguments":{"url":"maps://"}}}"#,
            #"{"type":"item.completed","item":{"id":"a","type":"agent_message","text":"done"}}"#,
        ]])
        let store = CheckpointStore(directory: dir)
        let runner = LocalMissionRunner(core: core, clientID: "phone", checkpoints: store) { kind, _ in
            CLIHarness(dialect: HarnessDialects.dialect(for: kind), runtime: runtime)
        }
        try await runner.run(mission: "m1", configuration: HarnessConfiguration(missionID: "m1", harness: .codex, workingDirectory: "/w", prompt: "go"), prompt: "go")
        for _ in 0..<200 where await runner.isRunning("m1") { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(await runner.states["m1"] == .completed)
        let events = core.bodies("/client-events").flatMap { $0["events"].array }
        #expect(events.contains { $0["type"] == "tool_call" && $0["name"] == "ios.open_url" })
        #expect(core.bodies("/client-events").allSatisfy { $0["run_id"] == "run-1" })
        #expect(core.bodies("/client-transcript").first?["content"] == "done")
        #expect(core.bodies("/client-status").first?["status"] == "awaiting_user")
        let saved = store.load("m1")
        #expect(saved?.state == .completed)
        #expect(saved?.harness.sessionID == "th")
        #expect(await runner.recoverable().isEmpty)
    }

    @Test func interruptedProcessIsRecoverableAndResumesNativeSession() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = CheckpointStore(directory: dir)
        let config = HarnessConfiguration(missionID: "m2", harness: .claudeCode, workingDirectory: "/w", prompt: "p")
        try store.save(LocalMissionCheckpoint(missionID: "m2", clientID: "phone", runID: "old", generation: 1, state: .suspendedByIOS,
                                              harness: HarnessState(configuration: config, sessionID: "sess-9", transcript: ""), inflightPrompt: "build it"))
        let core = FakeCore()
        let runtime = FakeRuntime(scripts: [[#"{"type":"result","is_error":false,"result":"resumed","session_id":"sess-9"}"#]])
        let runner = LocalMissionRunner(core: core, clientID: "phone", checkpoints: store) { kind, _ in
            CLIHarness(dialect: HarnessDialects.dialect(for: kind), runtime: runtime)
        }
        let recoverable = await runner.recoverable()
        #expect(recoverable.map(\.state) == [.resumeRequired])
        try await runner.resume(recoverable[0])
        for _ in 0..<200 where await runner.isRunning("m2") { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(runtime.launched.first?.arguments.contains("sess-9") == true)
        #expect(core.bodies("/client-run").first?["prompt"].text.contains("build it") == true)
        // The stale run from the killed process is closed before a new one begins.
        #expect(core.bodies("/client-status").first == ["status": "interrupted", "run_id": "old", "generation": 1])
        #expect(core.paths().firstIndex { $0.hasSuffix("/client-status") }! < core.paths().firstIndex { $0.hasSuffix("/client-run") }!)
        #expect(await runner.states["m2"] == .completed)
    }

    @Test func batcherCoalescesTextDeltas() {
        var b = EventBatcher()
        b.add(.textDelta("a")); b.add(.textDelta("ab")); b.add(.toolCall(id: "1", name: "x", args: [:])); b.add(.textDelta("abc")); b.add(.session("s"))
        #expect(b.take().map(\.["type"].text) == ["text_delta", "tool_call", "text_delta"])
    }
}

@Suite struct HTTPRequestTests {
    @Test func parsesCompleteRequestsOnly() {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let raw = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer t\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let full = HTTPRequest(Data(raw.utf8))
        #expect(full?.method == "POST")
        #expect(full?.headers["authorization"] == "Bearer t")
        #expect(full.map { String(decoding: $0.body, as: UTF8.self) } == body)
        #expect(HTTPRequest(Data(raw.dropLast(5).utf8)) == nil)
        #expect(HTTPRequest(Data("POST /mcp HTTP/1.1\r\nContent-Length: 0\r\n".utf8)) == nil)
    }
}
