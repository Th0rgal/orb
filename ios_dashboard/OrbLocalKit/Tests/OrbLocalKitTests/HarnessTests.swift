import Foundation
import Testing
@testable import OrbLocalKit

@Suite struct HarnessDialectTests {
    let config = HarnessConfiguration(missionID: "m1", harness: .codex, workingDirectory: "/root/work", prompt: "hi",
                                      model: "gpt-5.5", inferenceBaseURL: "https://core.example/v1", inferenceKey: "sk-run",
                                      mcpServers: [MCPServerConfig(name: "ios", url: "http://127.0.0.1:7777/mcp", bearerToken: "tok")])

    @Test func codexLaunchRoutesThroughCoreAndLoadsIOSComputer() {
        let spec = CodexDialect().launch(config, prompt: "open maps", session: nil)
        #expect(spec.executable == "codex")
        #expect(spec.arguments.first == "exec")
        #expect(spec.arguments.contains("--json"))
        #expect(spec.arguments.contains("mcp_servers.ios.url=\"http://127.0.0.1:7777/mcp\""))
        #expect(spec.arguments.contains("model_providers.orb.base_url=\"https://core.example/v1\""))
        #expect(spec.environment["ORB_ROUTING_KEY"] == "sk-run")
        #expect(spec.environment["ORB_MCP_IOS_TOKEN"] == "tok")
        #expect(spec.arguments.last == "open maps")
        let resumed = CodexDialect().launch(config, prompt: "next", session: "thread-1")
        #expect(Array(resumed.arguments.prefix(3)) == ["exec", "resume", "thread-1"])
    }

    @Test func codexStreamNormalizesToOrbEvents() {
        let p = CodexDialect().parser()
        var events: [OrbEvent] = []
        for line in [
            #"{"type":"thread.started","thread_id":"th_1"}"#,
            #"{"type":"item.started","item":{"id":"c1","type":"mcp_tool_call","server":"ios","tool":"open_url","arguments":{"url":"maps://?q=coffee"},"status":"in_progress"}}"#,
            #"{"type":"item.completed","item":{"id":"c1","type":"mcp_tool_call","server":"ios","tool":"open_url","arguments":{},"result":{"content":[]},"status":"completed"}}"#,
            #"{"type":"item.completed","item":{"id":"a1","type":"agent_message","text":"Maps is open."}}"#,
            #"{"type":"turn.completed","usage":{}}"#,
        ] { events += p.consume(line) }
        events += p.finish(exitCode: 0, stderr: "")
        #expect(events.first == .session("th_1"))
        #expect(events.contains(.toolCall(id: "c1", name: "ios.open_url", args: ["url": "maps://?q=coffee"])))
        #expect(events.contains(.toolResult(id: "c1", name: "ios.open_url", result: ["content": []])))
        #expect(events.last == .turnCompleted(text: "Maps is open.", success: true))
    }

    @Test func claudeCodeStreamTracksToolNamesAndSession() {
        var c = config; c.harness = .claudeCode
        let spec = ClaudeCodeDialect().launch(c, prompt: "p", session: "s1")
        #expect(spec.environment["ANTHROPIC_BASE_URL"] == "https://core.example")
        #expect(spec.arguments.contains("--resume"))
        let mcp = spec.arguments[spec.arguments.firstIndex(of: "--mcp-config")! + 1]
        #expect(JSONValue.parse(mcp)?.pointer("/mcpServers/ios/headers/Authorization").string == "Bearer tok")
        let p = ClaudeCodeDialect().parser()
        var events: [OrbEvent] = []
        for line in [
            #"{"type":"system","subtype":"init","session_id":"sess"}"#,
            #"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"Hel"}}}"#,
            #"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"lo"}}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"mcp__ios__screenshot","input":{}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
            #"{"type":"result","is_error":false,"result":"Hello","session_id":"sess"}"#,
        ] { events += p.consume(line) }
        events += p.finish(exitCode: 0, stderr: "")
        #expect(events.contains(.session("sess")))
        #expect(events.contains(.textDelta("Hello")))
        #expect(events.contains { if case .toolResult(let id, let name, _) = $0 { return id == "t1" && name == "mcp__ios__screenshot" }; return false })
        #expect(events.last == .turnCompleted(text: "Hello", success: true))
    }

    @Test func openCodeAndAntigravityParse() {
        var c = config; c.harness = .openCode
        let spec = OpenCodeDialect().launch(c, prompt: "p", session: "ses_1")
        let cfg = JSONValue.parse(spec.environment["OPENCODE_CONFIG_CONTENT"]!)!
        #expect(cfg.pointer("/mcp/ios/url").string == "http://127.0.0.1:7777/mcp")
        #expect(spec.arguments.contains("--session"))
        let oc = OpenCodeDialect().parser()
        var events = oc.consume(#"{"type":"tool_use","sessionID":"ses_9","part":{"callID":"x","tool":"bash","state":{"status":"completed","input":{"command":"ls"},"output":"a"}}}"#)
        events += oc.consume(#"{"type":"text","part":{"text":"done"}}"#)
        events += oc.finish(exitCode: 0, stderr: "")
        #expect(events.first == .session("ses_9"))
        #expect(events.contains(.toolCall(id: "x", name: "bash", args: ["command": "ls"])))
        #expect(events.last == .turnCompleted(text: "done", success: true))

        let agy = AntigravityDialect().parser()
        var a = agy.consume(#"{"event":"init","init":{"conversation_id":"conv"}}"#)
        a += agy.consume(#"{"event":"step_update","step_update":{"step_index":1,"step_type":"agent_response","text_delta":"Hi"}}"#)
        a += agy.consume(#"{"event":"result","result":{"status":"SUCCESS"}}"#)
        a += agy.finish(exitCode: 0, stderr: "")
        #expect(a.first == .session("conv"))
        #expect(a.last == .turnCompleted(text: "Hi", success: true))
        #expect(AntigravityDialect().installCommand.isEmpty)
    }

    @Test func failedTurnIsResumableWhenSessionKnown() {
        let p = CodexDialect().parser()
        _ = p.consume(#"{"type":"thread.started","thread_id":"t"}"#)
        _ = p.consume(#"{"type":"turn.failed","error":{"message":"rate limited"}}"#)
        let closing = p.finish(exitCode: 1, stderr: "")
        #expect(closing == [.error("rate limited", resumable: true), .turnCompleted(text: "", success: false)])
    }
}

@Suite struct CLIHarnessTests {
    @Test func turnsQueueAndResumeNativeSession() async throws {
        let runtime = FakeRuntime(scripts: [
            [#"{"type":"thread.started","thread_id":"th"}"#, #"{"type":"item.completed","item":{"id":"a","type":"agent_message","text":"one"}}"#],
            [#"{"type":"item.completed","item":{"id":"b","type":"agent_message","text":"two"}}"#],
        ])
        let harness = CLIHarness(dialect: CodexDialect(), runtime: runtime)
        #expect(await harness.availability() == .available(version: "1.2.3"))
        try await harness.start(HarnessConfiguration(missionID: "m", harness: .codex, workingDirectory: "/w", prompt: "first"))
        try await harness.send("second")
        let first = await collect(harness.events)
        #expect(first.last == .turnCompleted(text: "one", success: true))
        let second = await collect(harness.events)
        #expect(second.last == .turnCompleted(text: "two", success: true))
        // The second turn resumes the native thread instead of starting fresh.
        #expect(runtime.launched[1].arguments.prefix(3) == ["exec", "resume", "th"])
        let snap = await harness.snapshot()
        #expect(snap?.sessionID == "th")
        #expect(snap?.transcript == "two")
    }

    @Test func missingCLIIsInstallableExceptAntigravity() async {
        let runtime = FakeRuntime(scripts: [])
        runtime.installed = false
        #expect(await CLIHarness(dialect: ClaudeCodeDialect(), runtime: runtime).availability() == .installable(command: "npm install -g @anthropic-ai/claude-code"))
        if case .unavailable = await CLIHarness(dialect: AntigravityDialect(), runtime: runtime).availability() {} else { Issue.record("agy must be unavailable") }
    }
}
