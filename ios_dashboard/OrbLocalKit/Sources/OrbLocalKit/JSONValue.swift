import Foundation

/// Lossless JSON used on every wire this package speaks: Orb Core, harness
/// JSONL streams, MCP JSON-RPC and the OpenAI Responses API.
public indirect enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public subscript(_ key: String) -> JSONValue {
        if case .object(let v) = self { return v[key] ?? .null }
        return .null
    }
    public subscript(_ index: Int) -> JSONValue {
        if case .array(let v) = self, v.indices.contains(index) { return v[index] }
        return .null
    }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var text: String { string ?? "" }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var int: Int? { number.map { Int($0) } }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }
    public var object: [String: JSONValue] { if case .object(let v) = self { return v }; return [:] }
    public var isNull: Bool { self == .null }

    /// `/a/b/0` style lookup, mirroring `serde_json::Value::pointer`.
    public func pointer(_ path: String) -> JSONValue {
        var current = self
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if let index = Int(part), case .array = current { current = current[index] }
            else { current = current[String(part)] }
        }
        return current
    }

    public static func parse(_ line: String) -> JSONValue? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    public static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    public var compact: String { String(decoding: encoded(), as: UTF8.self) }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }
}
