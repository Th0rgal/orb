import Foundation

/// iOS-native actions an agent can request. Every case maps to a public API;
/// there is deliberately no `tap(x,y)`.
public enum IOSComputerAction: Equatable, Sendable {
    case screenshot(maxDimension: Int?)
    case observe(sinceSequence: UInt64?)
    case openURL(String)
    case openApp(String)
    case appAction(app: String, action: String, parameters: [String: String])
    case typeText(String)
    case keyboardDelete(Int)
    case keyboardReturn
    case keyboardContext
    case clipboardSet(String)
    case clipboardGet
    case runShortcut(name: String, input: String?)
    case share(text: String?, url: String?)
    case wait(seconds: Double)
    case listApps
    case capabilities

    public var name: String {
        switch self {
        case .screenshot: "screenshot"
        case .observe: "observe"
        case .openURL: "open_url"
        case .openApp: "open_app"
        case .appAction: "app_action"
        case .typeText: "type_text"
        case .keyboardDelete: "keyboard_delete"
        case .keyboardReturn: "keyboard_return"
        case .keyboardContext: "keyboard_context"
        case .clipboardSet: "clipboard_set"
        case .clipboardGet: "clipboard_get"
        case .runShortcut: "run_shortcut"
        case .share: "share"
        case .wait: "wait"
        case .listApps: "list_apps"
        case .capabilities: "capabilities"
        }
    }
}

/// A captured screen frame plus whatever on-device perception produced.
public struct ScreenFrame: Equatable, Sendable {
    public var sequence: UInt64
    public var capturedAt: Date
    public var width: Int
    public var height: Int
    public var mimeType: String
    public var data: Data
    /// On-device OCR lines (Vision), top-to-bottom, with normalized boxes.
    public var text: [RecognizedText]
    /// `broadcast` (other apps visible) or `in_app` (only Orb's own UI).
    public var source: String

    public init(sequence: UInt64, capturedAt: Date, width: Int, height: Int, mimeType: String, data: Data,
                text: [RecognizedText] = [], source: String) {
        self.sequence = sequence; self.capturedAt = capturedAt; self.width = width; self.height = height
        self.mimeType = mimeType; self.data = data; self.text = text; self.source = source
    }

    public var dataURL: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }

    public var summary: JSONValue {
        [
            "sequence": .number(Double(sequence)),
            "captured_at": .string(ISO8601DateFormatter().string(from: capturedAt)),
            "width": .number(Double(width)), "height": .number(Double(height)),
            "source": .string(source),
            "text": .array(text.map(\.json)),
        ]
    }
}

public struct RecognizedText: Equatable, Sendable, Codable {
    public var string: String
    public var confidence: Double
    /// Normalized (0...1) box, origin top-left.
    public var x: Double, y: Double, width: Double, height: Double
    public init(string: String, confidence: Double, x: Double, y: Double, width: Double, height: Double) {
        self.string = string; self.confidence = confidence; self.x = x; self.y = y; self.width = width; self.height = height
    }
    var json: JSONValue {
        ["text": .string(string), "confidence": .number((confidence * 100).rounded() / 100),
         "box": [.number(x), .number(y), .number(width), .number(height)]]
    }
}

public struct ComputerActionResult: Equatable, Sendable {
    public var ok: Bool
    public var detail: JSONValue
    public var frame: ScreenFrame?
    public init(ok: Bool, detail: JSONValue, frame: ScreenFrame? = nil) {
        self.ok = ok; self.detail = detail; self.frame = frame
    }
    public static func refused(_ reason: String, alternative: String? = nil) -> Self {
        var detail: [String: JSONValue] = ["ok": false, "unsupported": true, "reason": .string(reason)]
        if let alternative { detail["alternative"] = .string(alternative) }
        return .init(ok: false, detail: .object(detail))
    }
}

/// Implemented by the app with UIKit/ReplayKit/App Group plumbing.
public protocol IOSActionExecutor: AnyObject, Sendable {
    func perform(_ action: IOSComputerAction) async -> ComputerActionResult
}

/// Translates OpenAI Computer Use actions (Responses API `computer_call`) into
/// iOS actions. Pointer actions are refused with an explanation instead of
/// being faked; keyboard actions route to the Orb keyboard.
public enum OpenAIComputerTranslator {
    public enum Outcome: Equatable, Sendable {
        case perform([IOSComputerAction])
        case refuse(String)
    }

    public static func translate(_ action: JSONValue) -> Outcome {
        switch action["type"].text {
        case "screenshot": return .perform([.screenshot(maxDimension: nil)])
        case "wait": return .perform([.wait(seconds: action["ms"].number.map { $0 / 1000 } ?? 1.5), .screenshot(maxDimension: nil)])
        case "type": return .perform([.typeText(action["text"].text), .screenshot(maxDimension: nil)])
        case "keypress":
            var out: [IOSComputerAction] = []
            for key in action["keys"].array.map({ $0.text.uppercased() }) {
                switch key {
                case "ENTER", "RETURN": out.append(.keyboardReturn)
                case "BACKSPACE", "DELETE": out.append(.keyboardDelete(1))
                case "SPACE": out.append(.typeText(" "))
                case "TAB": out.append(.typeText("\t"))
                default:
                    if key.count == 1 { out.append(.typeText(key.lowercased())) }
                    else { return .refuse("Key \(key) has no iOS equivalent; only text, space, tab, return and backspace can be sent through the Orb keyboard.") }
                }
            }
            return .perform(out + [.screenshot(maxDimension: nil)])
        case "click", "double_click", "drag", "move", "scroll":
            return .refuse("iOS does not allow an app to \(action["type"].text.replacingOccurrences(of: "_", with: " ")) in other apps. Use open_url/open_app deep links, run_shortcut, or type_text into an already focused field instead.")
        default:
            return .refuse("Unsupported computer action \(action["type"].text)")
        }
    }
}
