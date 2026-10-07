import Foundation
import Network
import OrbLocalKit

/// Loopback-only MCP endpoint (`POST http://127.0.0.1:<port>/mcp`, MCP
/// streamable HTTP with JSON responses). Guest processes in the Linux runtime
/// use host sockets, so `codex`, `claude` and `opencode` connect to it like any
/// remote MCP server. A per-launch bearer token keeps other apps out.
final class LoopbackMCPServer: @unchecked Sendable {
    static let shared = LoopbackMCPServer()
    let token = UUID().uuidString + UUID().uuidString
    private let queue = DispatchQueue(label: "orb.mcp.loopback")
    private var listener: NWListener?
    private var server: IOSComputerMCPServer?
    private(set) var port: UInt16 = 0
    private let lock = NSLock()

    func start(server: IOSComputerMCPServer) throws -> MCPServerConfig {
        lock.lock(); defer { lock.unlock() }
        self.server = server
        if listener == nil {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            parameters.acceptLocalOnly = true
            let listener = try NWListener(using: parameters)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } else if case .failed = state { ready.signal() } }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 3)
            port = listener.port?.rawValue ?? 0
            self.listener = listener
        }
        return MCPServerConfig(name: "ios", url: "http://127.0.0.1:\(port)/mcp", bearerToken: token)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest(buffer) {
                Task { await self.respond(connection, request) }
            } else if complete || error != nil || buffer.count > 8 << 20 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, _ request: HTTPRequest) async {
        guard request.headers["authorization"] == "Bearer \(token)" else { return send(connection, 401, Data("unauthorized".utf8)) }
        guard request.method == "POST", request.path.hasPrefix("/mcp") else {
            // No server-initiated stream: GET is not offered (spec allows 405).
            return send(connection, 405, Data())
        }
        guard let server = lock.withLock({ server }) else { return send(connection, 503, Data()) }
        if let reply = await server.handle(data: request.body) { send(connection, 200, reply, type: "application/json") }
        else { send(connection, 202, Data()) }
    }

    private func send(_ connection: NWConnection, _ status: Int, _ body: Data, type: String = "text/plain") {
        let reason = [200: "OK", 202: "Accepted", 401: "Unauthorized", 405: "Method Not Allowed", 503: "Service Unavailable"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        if status == 405 { head = head.replacingOccurrences(of: "Connection: close", with: "Allow: POST\r\nConnection: close") }
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
