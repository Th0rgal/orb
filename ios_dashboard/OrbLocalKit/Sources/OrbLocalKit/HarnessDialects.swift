import Foundation

/// The only per-harness code: how to launch one headless turn and how to read
/// its JSONL stream. Every dialect runs one process per turn and resumes the
/// native session on the next turn, so suspension between turns loses nothing.
public protocol HarnessDialect: Sendable {
    var kind: HarnessKind { get }
    /// Binary name inside the runtime's PATH.
    var executable: String { get }
    /// How to install the CLI inside the runtime when it is missing.
    var installCommand: String { get }
    func launch(_ configuration: HarnessConfiguration, prompt: String, session: String?) -> LaunchSpec
    func parser() -> any HarnessStreamParser
}

public protocol HarnessStreamParser: AnyObject {
    /// Translate one stdout line into normalized events.
    func consume(_ line: String) -> [OrbEvent]
    /// Called once at process exit; returns the closing events.
    func finish(exitCode: Int32, stderr: String) -> [OrbEvent]
}

public enum HarnessDialects {
    public static func dialect(for kind: HarnessKind) -> any HarnessDialect {
        switch kind {
        case .codex: CodexDialect()
        case .claudeCode: ClaudeCodeDialect()
        case .openCode: OpenCodeDialect()
        case .antigravity: AntigravityDialect()
        }
    }
}

/// Shared bookkeeping: accumulated answer text, session id, failure.
class BaseParser {
    var text = ""
    var session: String?
    var failure: String?
    var completed = false

    func closing(exitCode: Int32, stderr: String) -> [OrbEvent] {
        var events: [OrbEvent] = []
        let ok = failure == nil && exitCode == 0
        if !ok {
            let message = failure ?? (stderr.isEmpty ? "Harness exited with code \(exitCode)" : String(stderr.suffix(1000)))
            events.append(.error(message, resumable: session != nil))
        }
        events.append(.turnCompleted(text: text, success: ok))
        return events
    }

    func sessionEvent(_ id: String?) -> [OrbEvent] {
        guard let id, !id.isEmpty, id != session else { return [] }
        session = id
        return [.session(id)]
    }
}

// MARK: - Codex (`codex exec --json`)

public struct CodexDialect: HarnessDialect {
    public init() {}
    public var kind: HarnessKind { .codex }
    public var executable: String { "codex" }
    public var installCommand: String { "npm install -g @openai/codex" }

    public func launch(_ c: HarnessConfiguration, prompt: String, session: String?) -> LaunchSpec {
        var args = ["exec"]
        if let session { args += ["resume", session] }
        args += ["--json", "--skip-git-repo-check", "--dangerously-bypass-approvals-and-sandbox"]
        if let model = c.model, !model.isEmpty { args += ["--model", model] }
        if let effort = c.effort, !effort.isEmpty { args += ["-c", "model_reasoning_effort=\"\(effort)\""] }
        var env = c.environment
        if let base = c.inferenceBaseURL {
            // Route through Orb Core's Responses proxy with a per-run key.
            args += ["-c", "model_provider=\"orb\"",
                     "-c", "model_providers.orb.name=\"Orb\"",
                     "-c", "model_providers.orb.base_url=\"\(base)\"",
                     "-c", "model_providers.orb.env_key=\"ORB_ROUTING_KEY\"",
                     "-c", "model_providers.orb.wire_api=\"responses\""]
            if let key = c.inferenceKey { env["ORB_ROUTING_KEY"] = key }
        }
        for server in c.mcpServers {
            args += ["-c", "mcp_servers.\(server.name).url=\"\(server.url)\""]
            if let token = server.bearerToken {
                let variable = "ORB_MCP_\(server.name.uppercased())_TOKEN"
                env[variable] = token
                args += ["-c", "mcp_servers.\(server.name).bearer_token_env_var=\"\(variable)\""]
            }
        }
        args.append(prompt)
        return LaunchSpec(executable: executable, arguments: args, environment: env, workingDirectory: c.workingDirectory)
    }

    public func parser() -> any HarnessStreamParser { Parser() }

    final class Parser: BaseParser, HarnessStreamParser {
        func consume(_ line: String) -> [OrbEvent] {
            guard let v = JSONValue.parse(line) else { return [] }
            switch v["type"].text {
            case "thread.started": return sessionEvent(v["thread_id"].string)
            case "turn.failed": failure = v.pointer("/error/message").string ?? "Codex turn failed"; return []
            case "error": failure = v["message"].string ?? "Codex error"; return []
            case "item.started", "item.updated", "item.completed":
                return item(v["item"], done: v["type"].text == "item.completed")
            default: return []
            }
        }

        private func item(_ item: JSONValue, done: Bool) -> [OrbEvent] {
            let id = item["id"].text
            switch item["type"].text {
            case "agent_message":
                guard done else { return [] }
                let piece = item["text"].text
                text += text.isEmpty ? piece : "\n\n" + piece
                return [.textDelta(text)]
            case "reasoning":
                return done ? [.thinking(item["text"].text, done: true)] : []
            case "command_execution":
                if !done { return [.toolCall(id: id, name: "shell", args: ["command": item["command"]]), .activity(label: "Running: \(item["command"].text.prefix(80))", tool: "shell")] }
                return [.toolResult(id: id, name: "shell", result: ["exit_code": item["exit_code"], "output": .string(String(item["aggregated_output"].text.suffix(16_000)))])]
            case "mcp_tool_call":
                let name = "\(item["server"].text).\(item["tool"].text)"
                if !done { return [.toolCall(id: id, name: name, args: item["arguments"])] }
                return [.toolResult(id: id, name: name, result: item["result"].isNull ? item["error"] : item["result"])]
            case "file_change":
                return done ? [.toolCall(id: id, name: "apply_patch", args: ["changes": item["changes"]]), .toolResult(id: id, name: "apply_patch", result: ["status": item["status"]])] : []
            case "web_search":
                return done ? [.toolCall(id: id, name: "web_search", args: ["query": item["query"]])] : []
            default: return []
            }
        }

        func finish(exitCode: Int32, stderr: String) -> [OrbEvent] { closing(exitCode: exitCode, stderr: stderr) }
    }
}

// MARK: - Claude Code (`claude -p --output-format stream-json`)

public struct ClaudeCodeDialect: HarnessDialect {
    public init() {}
    public var kind: HarnessKind { .claudeCode }
    public var executable: String { "claude" }
    public var installCommand: String { "npm install -g @anthropic-ai/claude-code" }

    public func launch(_ c: HarnessConfiguration, prompt: String, session: String?) -> LaunchSpec {
        var args = ["--print", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--dangerously-skip-permissions", "--disallowedTools", "CronCreate,CronDelete,CronList"]
        if let model = c.model, !model.isEmpty { args += ["--model", model.replacingOccurrences(of: "anthropic/", with: "")] }
        if let session { args += ["--resume", session] }
        var env = c.environment
        if let base = c.inferenceBaseURL {
            // Core's `/v1/messages` proxy; Claude Code appends `/v1/messages`.
            env["ANTHROPIC_BASE_URL"] = base.hasSuffix("/v1") ? String(base.dropLast(3)) : base
            if let key = c.inferenceKey { env["ANTHROPIC_API_KEY"] = key }
        }
        if !c.mcpServers.isEmpty {
            var servers: [String: JSONValue] = [:]
            for s in c.mcpServers {
                var entry: [String: JSONValue] = ["type": "http", "url": .string(s.url)]
                if let token = s.bearerToken { entry["headers"] = ["Authorization": .string("Bearer \(token)")] }
                servers[s.name] = .object(entry)
            }
            args += ["--mcp-config", JSONValue.object(["mcpServers": .object(servers)]).compact]
        }
        args.append(prompt)
        return LaunchSpec(executable: executable, arguments: args, environment: env, workingDirectory: c.workingDirectory)
    }

    public func parser() -> any HarnessStreamParser { Parser() }

    final class Parser: BaseParser, HarnessStreamParser {
        private var names: [String: String] = [:]
        func consume(_ line: String) -> [OrbEvent] {
            guard let v = JSONValue.parse(line) else { return [] }
            switch v["type"].text {
            case "system" where v["subtype"].text == "init":
                return sessionEvent(v["session_id"].string)
            case "stream_event":
                let delta = v.pointer("/event/delta")
                if delta["type"].text == "text_delta" { text += delta["text"].text; return [.textDelta(text)] }
                if delta["type"].text == "thinking_delta" { return [.thinking(delta["thinking"].text, done: false)] }
                return []
            case "assistant":
                return v.pointer("/message/content").array.compactMap { block -> OrbEvent? in
                    guard block["type"].text == "tool_use" else { return nil }
                    names[block["id"].text] = block["name"].text
                    return .toolCall(id: block["id"].text, name: block["name"].text, args: block["input"])
                }
            case "user":
                return v.pointer("/message/content").array.compactMap { block -> OrbEvent? in
                    guard block["type"].text == "tool_result" else { return nil }
                    let id = block["tool_use_id"].text
                    return .toolResult(id: id, name: names[id] ?? "tool", result: ["content": block["content"], "is_error": block["is_error"]])
                }
            case "result":
                _ = sessionEvent(v["session_id"].string)
                if v["is_error"].bool == true { failure = v["result"].string ?? "Claude Code turn failed" }
                else if let result = v["result"].string, !result.isEmpty { text = result }
                return session.map { [.session($0)] } ?? []
            default: return []
            }
        }
        func finish(exitCode: Int32, stderr: String) -> [OrbEvent] { closing(exitCode: exitCode, stderr: stderr) }
    }
}

// MARK: - OpenCode (`opencode run --format json`)

public struct OpenCodeDialect: HarnessDialect {
    public init() {}
    public var kind: HarnessKind { .openCode }
    public var executable: String { "opencode" }
    public var installCommand: String { "npm install -g opencode-ai" }

    public func launch(_ c: HarnessConfiguration, prompt: String, session: String?) -> LaunchSpec {
        var args = ["run", "--format", "json", "--dir", c.workingDirectory]
        var env = c.environment
        var config: [String: JSONValue] = [:]
        if let base = c.inferenceBaseURL {
            let route = c.model ?? "default"
            config["model"] = .string("orb-routing/\(route)")
            config["enabled_providers"] = ["orb-routing"]
            config["provider"] = ["orb-routing": [
                "npm": "@ai-sdk/openai-compatible", "name": "Orb routing",
                "options": ["baseURL": .string(base), "apiKey": "{env:ORB_ROUTING_KEY}",
                            "headers": ["x-sandboxed-mission-id": .string(c.missionID)]],
                "models": .object([route: ["name": .string(route), "id": .string(route)]]),
            ]]
            if let key = c.inferenceKey { env["ORB_ROUTING_KEY"] = key }
            args += ["--model", "orb-routing/\(route)"]
        } else if let model = c.model, !model.isEmpty {
            args += ["--model", model]
        }
        if !c.mcpServers.isEmpty {
            var mcp: [String: JSONValue] = [:]
            for s in c.mcpServers {
                var entry: [String: JSONValue] = ["type": "remote", "url": .string(s.url), "enabled": true]
                if let token = s.bearerToken { entry["headers"] = ["Authorization": .string("Bearer \(token)")] }
                mcp[s.name] = .object(entry)
            }
            config["mcp"] = .object(mcp)
        }
        if !config.isEmpty { env["OPENCODE_CONFIG_CONTENT"] = JSONValue.object(config).compact }
        if let session { args += session.hasPrefix("ses_") ? ["--session", session] : ["--continue"] }
        args.append(prompt)
        return LaunchSpec(executable: executable, arguments: args, environment: env, workingDirectory: c.workingDirectory)
    }

    public func parser() -> any HarnessStreamParser { Parser() }

    final class Parser: BaseParser, HarnessStreamParser {
        private var called: Set<String> = []
        func consume(_ line: String) -> [OrbEvent] {
            guard let v = JSONValue.parse(line) else { return [] }
            var events = sessionEvent(v["sessionID"].string.flatMap { $0.hasPrefix("ses_") ? $0 : nil })
            switch v["type"].text {
            case "text":
                text += v.pointer("/part/text").text
                events.append(.textDelta(text))
            case "tool_use":
                let part = v["part"], id = part["callID"].text, tool = part["tool"].text
                if called.insert(id).inserted { events.append(.toolCall(id: id, name: tool, args: part.pointer("/state/input"))) }
                let status = part.pointer("/state/status").text
                if status == "completed" || status == "error" {
                    events.append(.toolResult(id: id, name: tool, result: part.pointer("/state/output").isNull ? part.pointer("/state/error") : part.pointer("/state/output")))
                }
            case "error":
                failure = v.pointer("/error/data/message").string ?? v.pointer("/error/message").string ?? "OpenCode error"
            default: break
            }
            return events
        }
        func finish(exitCode: Int32, stderr: String) -> [OrbEvent] { closing(exitCode: exitCode, stderr: stderr) }
    }
}

// MARK: - Antigravity (`agy --output-format stream-json`)

public struct AntigravityDialect: HarnessDialect {
    public init() {}
    public var kind: HarnessKind { .antigravity }
    public var executable: String { "agy" }
    /// Google distributes `agy` as a native binary; there is no npm package.
    public var installCommand: String { "" }

    public func launch(_ c: HarnessConfiguration, prompt: String, session: String?) -> LaunchSpec {
        // Mirrors `shared/antigravity.rs::args_with_effort`.
        var args = ["--output-format", "stream-json", "--dangerously-skip-permissions"]
        if let model = c.model, !model.isEmpty { args += ["--model", model] }
        if let effort = c.effort, !effort.isEmpty { args += ["--effort", effort] }
        if let session { args += ["--conversation", session] }
        args += ["-p", prompt]
        return LaunchSpec(executable: executable, arguments: args, environment: c.environment, workingDirectory: c.workingDirectory)
    }

    public func parser() -> any HarnessStreamParser { Parser() }

    final class Parser: BaseParser, HarnessStreamParser {
        private var seenSteps: Set<Int> = []
        func consume(_ line: String) -> [OrbEvent] {
            guard let v = JSONValue.parse(line) else { return [] }
            let kind = v["event"].text
            let body = kind == "init" ? (v["init"].isNull ? v : v["init"]) : v[kind]
            var events = sessionEvent(body["conversation_id"].string ?? v["conversation_id"].string)
            switch kind {
            case "step_update":
                let step = body["step_index"].int ?? -1
                if body["step_type"].text == "agent_response", let delta = body["text_delta"].string, !delta.isEmpty {
                    text += delta
                    events.append(.textDelta(text))
                } else if body["step_type"].text == "tool_call", seenSteps.insert(step).inserted {
                    events.append(.toolCall(id: "agy-\(step)", name: body["tool_name"].string ?? "tool", args: body["tool_input"]))
                }
            case "result":
                if body["status"].text != "SUCCESS" { failure = body["error"].string ?? "Antigravity result: \(body["status"].text)" }
                if let response = body["response"].string, !response.isEmpty, text.isEmpty {
                    text = response
                    events.append(.textDelta(text))
                }
            default: break
            }
            return events
        }
        func finish(exitCode: Int32, stderr: String) -> [OrbEvent] { closing(exitCode: exitCode, stderr: stderr) }
    }
}
