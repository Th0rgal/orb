import Foundation

/// Minimal HTTP/1.1 request parser (Content-Length bodies only).
public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self).split(separator: "\r\n").map(String.init)
        let start = head.first?.split(separator: " ") ?? []
        guard start.count >= 2 else { return nil }
        method = String(start[0]); path = String(start[1])
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        body = Data(data[bodyStart..<(bodyStart + length)])
    }
}
