import Foundation

/// MCP (JSON-RPC 2.0) server exposing the iPhone as a computer-use
/// environment. Transport-agnostic: the app serves it over loopback
/// streamable HTTP so harnesses running in the local Linux runtime connect to
/// `http://127.0.0.1:<port>/mcp`. Every Codex, Claude Code and OpenCode build
/// speaks MCP, so this is how "Codex Computer Use" reaches the phone.
public final class IOSComputerMCPServer: @unchecked Sendable {
    public static let protocolVersion = "2025-06-18"
    private let executor: any IOSActionExecutor
    private let observer: (@Sendable (String, JSONValue, ComputerActionResult) -> Void)?

    public init(executor: any IOSActionExecutor, observer: (@Sendable (String, JSONValue, ComputerActionResult) -> Void)? = nil) {
        self.executor = executor
        self.observer = observer
    }

    public static let tools: [JSONValue] = [
        tool("capabilities", "Report what this iPhone allows an agent to do, including the missing primitives (no cross-app tap/swipe). Call this first.", [:]),
        tool("screenshot", "Capture the current iPhone screen (from the user's Orb screen broadcast) with on-device OCR text and boxes.",
             ["max_dimension": ["type": "integer", "description": "Longest side in pixels (default 1024)."]]),
        tool("observe", "Wait until the screen materially changes after `since_sequence`, then return the new frame.",
             ["since_sequence": ["type": "integer"]]),
        tool("open_url", "Open a URL with iOS (universal links, https, maps://, tel:, sms:, mailto:, shortcuts://, app URL schemes).",
             ["url": ["type": "string"]], required: ["url"]),
        tool("open_app", "Open an app by registry id (see list_apps) or bundle-style name.", ["app": ["type": "string"]], required: ["app"]),
        tool("list_apps", "List known apps with their verified deep-link actions and whether iOS reports them installed.", [:]),
        tool("app_action", "Run a verified deep-link action, e.g. app=maps action=search parameters={query:'coffee'}.",
             ["app": ["type": "string"], "action": ["type": "string"], "parameters": ["type": "object", "additionalProperties": ["type": "string"]]],
             required: ["app", "action"]),
        tool("type_text", "Insert text into the focused field of the frontmost app through the Orb keyboard (must be the active keyboard).",
             ["text": ["type": "string"]], required: ["text"]),
        tool("keyboard_delete", "Delete characters before the cursor through the Orb keyboard.", ["count": ["type": "integer"]]),
        tool("keyboard_return", "Press return in the focused field through the Orb keyboard.", [:]),
        tool("keyboard_context", "Read the text around the cursor and the field traits (never secure fields).", [:]),
        tool("clipboard_set", "Put text on the system pasteboard.", ["text": ["type": "string"]], required: ["text"]),
        tool("clipboard_get", "Read the system pasteboard (iOS may show a paste permission prompt).", [:]),
        tool("run_shortcut", "Run a user Shortcut by name via shortcuts://run-shortcut, optionally with text input.",
             ["name": ["type": "string"], "input": ["type": "string"]], required: ["name"]),
        tool("share", "Present the iOS share sheet with text and/or a URL (needs the user to pick a target).",
             ["text": ["type": "string"], "url": ["type": "string"]]),
        tool("wait", "Sleep, then return a fresh screenshot.", ["seconds": ["type": "number"]]),
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["name": .string(name), "description": .string(description),
         "inputSchema": ["type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string))]]
    }

    /// Handle one JSON-RPC message; `nil` for notifications.
    public func handle(_ request: JSONValue) async -> JSONValue? {
        let id = request["id"]
        let method = request["method"].text
        if id.isNull { return nil }
        switch method {
        case "initialize":
            return reply(id, ["protocolVersion": .string(request.pointer("/params/protocolVersion").string ?? Self.protocolVersion),
                              "capabilities": ["tools": ["listChanged": false]],
                              "serverInfo": ["name": "orb-ios-computer", "version": "1.0.0"],
                              "instructions": "This server controls an iPhone through public iOS APIs only. Call capabilities first; there is no tap/swipe."])
        case "ping": return reply(id, [:])
        case "tools/list": return reply(id, ["tools": .array(Self.tools)])
        case "tools/call":
            let name = request.pointer("/params/name").text
            let args = request.pointer("/params/arguments")
            guard let action = Self.action(name, args) else {
                return reply(id, ["isError": true, "content": [["type": "text", "text": .string("Unknown tool \(name)")]]])
            }
            let result = await executor.perform(action)
            observer?(name, args, result)
            return reply(id, Self.content(result))
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": .string("Method not found: \(method)")]]
        }
    }

    public func handle(data: Data) async -> Data? {
        guard let value = JSONValue.parse(data) else {
            return JSONValue.object(["jsonrpc": "2.0", "id": nil, "error": ["code": -32700, "message": "Parse error"]]).encoded()
        }
        if case .array(let batch) = value {
            var out: [JSONValue] = []
            for item in batch { if let r = await handle(item) { out.append(r) } }
            return out.isEmpty ? nil : JSONValue.array(out).encoded()
        }
        return await handle(value)?.encoded()
    }

    private func reply(_ id: JSONValue, _ result: JSONValue) -> JSONValue { ["jsonrpc": "2.0", "id": id, "result": result] }

    static func content(_ result: ComputerActionResult) -> JSONValue {
        var detail = result.detail
        if let frame = result.frame, case .object(var o) = detail { o["frame"] = frame.summary; detail = .object(o) }
        var content: [JSONValue] = [["type": "text", "text": .string(detail.compact)]]
        if let frame = result.frame {
            content.append(["type": "image", "data": .string(frame.data.base64EncodedString()), "mimeType": .string(frame.mimeType)])
        }
        return ["content": .array(content), "isError": .bool(!result.ok)]
    }

    public static func action(_ name: String, _ a: JSONValue) -> IOSComputerAction? {
        switch name {
        case "capabilities": return .capabilities
        case "screenshot": return .screenshot(maxDimension: a["max_dimension"].int)
        case "observe": return .observe(sinceSequence: a["since_sequence"].number.map { UInt64(max(0, $0)) })
        case "open_url": return a["url"].string.map(IOSComputerAction.openURL)
        case "open_app": return a["app"].string.map(IOSComputerAction.openApp)
        case "list_apps": return .listApps
        case "app_action":
            guard let app = a["app"].string, let action = a["action"].string else { return nil }
            return .appAction(app: app, action: action, parameters: a["parameters"].object.compactMapValues(\.string))
        case "type_text": return a["text"].string.map(IOSComputerAction.typeText)
        case "keyboard_delete": return .keyboardDelete(max(1, a["count"].int ?? 1))
        case "keyboard_return": return .keyboardReturn
        case "keyboard_context": return .keyboardContext
        case "clipboard_set": return a["text"].string.map(IOSComputerAction.clipboardSet)
        case "clipboard_get": return .clipboardGet
        case "run_shortcut": return a["name"].string.map { .runShortcut(name: $0, input: a["input"].string) }
        case "share": return .share(text: a["text"].string, url: a["url"].string)
        case "wait": return .wait(seconds: min(30, max(0, a["seconds"].number ?? 1)))
        default: return nil
        }
    }
}
