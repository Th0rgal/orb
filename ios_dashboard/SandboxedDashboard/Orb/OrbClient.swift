import Foundation
import Observation

/// The one HTTP client for the sandboxed.sh backend: server URL, auth (Keychain
/// token + saved login), typed and untyped JSON calls, control streams. Every
/// request goes through `send`, so 401 handling and errors (`OrbHTTPError`) are
/// the same everywhere.
@MainActor
@Observable
final class OrbCore {
    static let shared = OrbCore()
    nonisolated init() {}

    nonisolated static let defaultBaseURL: String = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "SandboxedDefaultAPIBaseURL") as? String
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }()

    /// Per-request timeout for ordinary JSON calls. Anything that hasn't started
    /// returning data within this window is treated as failed. Default
    /// `URLSession.shared` ships with 60s, which is far too long for a chat
    /// app's cold-start path — the user sits at "Connecting…" with no feedback.
    /// Combined with retry-on-transient at the call site, a tight 10s surfaces
    /// failures fast without sacrificing reliability.
    nonisolated static let requestTimeout: TimeInterval = 10

    /// Full-transfer cap for ordinary JSON calls. Default is 7 days; a stalled
    /// large download (e.g. a multi-MB event tail over a flaky cellular link)
    /// would block the call until the user kills the app. 25s caps the longest
    /// user-attention window on a stuck spinner; the retry layer handles the
    /// failure cleanly.
    nonisolated static let resourceTimeout: TimeInterval = 25

    /// SSE inactivity threshold. If no bytes arrive for this long the stream is
    /// considered dead and the caller's reconnect logic re-runs. Covers the
    /// silent-half-open-socket case (cell→wifi handoff, NAT idle reset).
    ///
    /// Set to 60s rather than 30s because some agents (Codex high-reasoning,
    /// long-running tool calls) emit no bytes for ≥30s during normal
    /// operation. The proper fix is server-side pings every ~15s for every
    /// open stream; until that lands universally, 60s is the safer tradeoff
    /// — false-positive reconnect storms are worse than slow detection of a
    /// genuinely dead socket, which `NetworkMonitor` (NWPathMonitor +
    /// /api/health probes) catches independently.
    nonisolated static let streamInactivityTimeout: TimeInterval = 60

    /// Hard cap on the SSE line-buffer (1 MiB). A pathological server that
    /// never emits a newline must not be allowed to balloon memory.
    nonisolated static let streamMaxBufferBytes: Int = 1 << 20

    /// Dedicated session for JSON calls. `URLSession.shared`'s defaults
    /// (60s request, 7d resource, infinite cache) are wrong for a chat app on
    /// bad networks — short timeouts surface failures fast and let the UI
    /// retry instead of holding a spinner indefinitely.
    nonisolated private static let jsonSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: config)
    }()

    /// Session used for SSE. `timeoutIntervalForRequest` here doubles as the
    /// stream inactivity timeout: per URLSession semantics it's the maximum
    /// gap between bytes received, so a healthy stream emitting events
    /// regularly resets the clock and stays alive indefinitely, while a
    /// silent half-open socket (cell→wifi handoff, NAT idle reset) fails
    /// within `streamInactivityTimeout` and triggers the caller's reconnect
    /// loop. `timeoutIntervalForResource` stays effectively unbounded so
    /// long-running missions aren't capped.
    nonisolated private static let streamSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = streamInactivityTimeout
        config.timeoutIntervalForResource = TimeInterval.greatestFiniteMagnitude
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()


    // Configuration
    @ObservationIgnored private var cachedBaseURL: String?
    @ObservationIgnored private var cachedTokenEndpoint: String?
    @ObservationIgnored private var cachedJwtToken: String?

    var baseURL: String {
        get {
            if let cachedBaseURL { return cachedBaseURL }
            let stored = UserDefaults.standard.string(forKey: "api_base_url")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let resolved = stored.isEmpty ? Self.defaultBaseURL : stored
            cachedBaseURL = resolved
            return resolved
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = trimmed.isEmpty ? Self.defaultBaseURL : trimmed
            cachedBaseURL = resolved
            cachedTokenEndpoint = nil
            cachedJwtToken = nil
            #if DEBUG
            // UI tests point the app at loopback fixtures with `-api_base_url`; never let a
            // test that edits the server URL overwrite the operator's saved endpoint.
            if ProcessInfo.processInfo.arguments.contains("-api_base_url") { return }
            #endif
            UserDefaults.standard.set(trimmed, forKey: "api_base_url")
        }
    }

    /// Whether the server URL has been configured
    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            makeURL("/api/health") != nil
    }
    
    private var jwtToken: String? {
        get {
            let currentEndpoint = baseURL
            if cachedTokenEndpoint == currentEndpoint {
                return cachedJwtToken
            }
            if let legacy = UserDefaults.standard.string(forKey: "jwt_token"), !legacy.isEmpty {
                _ = OrbKeychain.save(legacy, for: currentEndpoint)
                UserDefaults.standard.removeObject(forKey: "jwt_token")
                cachedTokenEndpoint = currentEndpoint
                cachedJwtToken = legacy
                return legacy
            }
            let token = OrbKeychain.token(for: currentEndpoint)
            cachedTokenEndpoint = currentEndpoint
            cachedJwtToken = token
            return token
        }
        set {
            let currentEndpoint = baseURL
            cachedTokenEndpoint = currentEndpoint
            cachedJwtToken = newValue
            _ = OrbKeychain.save(newValue, for: currentEndpoint)
            UserDefaults.standard.removeObject(forKey: "jwt_token")
        }
    }
    
    var authToken: String? {
        jwtToken
    }

    /// `baseURL` without a trailing slash; requests are built as `endpoint + path`.
    var endpoint: String { baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }

    var isAuthenticated: Bool {
        jwtToken != nil
    }
    
    var authRequired: Bool = false
    var authMode: AuthMode = .singleTenant
    var authSessionExpired: Bool = false
    var authRefreshing = false
    /// Core version from the last `/api/health` (nil until probed or when the server omits it).
    var backendVersion: String?
    private var sessionRecovery: Task<Void, Never>?
    private var loginAttempt = UUID()
    var connectionGeneration = 0

    enum AuthMode: String {
        case disabled = "disabled"
        case singleTenant = "single_tenant"
        case multiUser = "multi_user"
    }

    enum ControlStreamTransport: String, Sendable {
        case sse
        case webSocket = "ws"
    }

    enum ControlStreamPhase: String, Sendable {
        case connecting
        case open
        case heartbeat
        case event
        case closed
        case error
        case fallback
    }

    struct ControlStreamDiagnostic: Sendable {
        let transport: ControlStreamTransport
        let phase: ControlStreamPhase
        let host: String?
        let status: Int?
        let bytes: Int?
        let error: String?
        let eventType: String?
        let generation: Int
        let timestamp: Date
    }
    
    
    // MARK: - Authentication
    
    func login(password: String, username: String? = nil) async throws -> Bool {
        struct LoginRequest: Encodable {
            let password: String
            let username: String?
        }
        
        struct LoginResponse: Decodable {
            let token: String
            let exp: Int
        }
        
        let endpoint = baseURL
        let attempt = UUID()
        loginAttempt = attempt
        let response: LoginResponse = try await post("/api/auth/login", body: LoginRequest(password: password, username: username), authenticated: false)
        try Task.checkCancellation()
        guard endpoint == baseURL, attempt == loginAttempt else { throw CancellationError() }
        guard OrbKeychain.save(response.token, for: endpoint),
              OrbKeychain.saveCredentials(.init(password: password, username: username), for: endpoint) else {
            throw NSError(domain: "OrbKeychain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not securely save your login. Please unlock your device and try again."])
        }
        cachedTokenEndpoint = endpoint
        cachedJwtToken = response.token
        UserDefaults.standard.removeObject(forKey: "jwt_token")
        authSessionExpired = false
        return true
    }
    
    func logout() {
        loginAttempt = UUID()
        sessionRecovery?.cancel(); sessionRecovery = nil; authRefreshing = false
        OrbKeychain.saveCredentials(nil, for: baseURL)
        jwtToken = nil
        authSessionExpired = false
        // Mission titles must not stay on the Lock Screen after sign-out.
        OrbFleetActivityController.shared.endAll()
    }

    func markSessionExpired() {
        guard !authRefreshing else { return }
        jwtToken = nil
        authSessionExpired = true
        guard OrbKeychain.credentials(for: baseURL) != nil else { return }
        authRefreshing = true
        sessionRecovery = Task { @MainActor in
            await restoreSavedSession()
            authRefreshing = false
            sessionRecovery = nil
            connectionGeneration += 1
        }
    }

    /// Credentials stay in the device Keychain across app updates; tokens can be renewed.
    func restoreSavedSession() async {
        guard let saved = OrbKeychain.credentials(for: baseURL) else { return }
        do { _ = try await login(password: saved.password, username: saved.username) }
        catch { /* Keep the saved login on transient failures; the reconnect UI remains available. */ }
    }
    
    func checkHealth() async throws -> Bool {
        struct HealthResponse: Decodable {
            let status: String
            let authRequired: Bool
            let authMode: String?
            let version: String?

            enum CodingKeys: String, CodingKey {
                case status, version
                case authRequired = "auth_required"
                case authMode = "auth_mode"
            }
        }
        
        let response: HealthResponse = try await get("/api/health", authenticated: false)
        authRequired = response.authRequired
        backendVersion = response.version
        if let modeRaw = response.authMode, let mode = AuthMode(rawValue: modeRaw) {
            authMode = mode
        } else {
            authMode = authRequired ? .singleTenant : .disabled
        }
        return response.status == "ok"
    }
    
    func getMissionEventsWithMeta(
        id: String,
        types: [String]? = nil,
        limit: Int? = nil,
        sinceSeq: Int64? = nil,
        beforeSeq: Int64? = nil
    ) async throws -> MissionEventsResult {
        var queryItems: [URLQueryItem] = []
        if let types = types {
            queryItems.append(URLQueryItem(name: "types", value: types.joined(separator: ",")))
        }
        if let limit = limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let sinceSeq = sinceSeq {
            queryItems.append(URLQueryItem(name: "since_seq", value: String(sinceSeq)))
        }
        if let beforeSeq = beforeSeq {
            queryItems.append(URLQueryItem(name: "before_seq", value: String(beforeSeq)))
        }

        var urlString = "/api/control/missions/\(id)/events"
        if !queryItems.isEmpty {
            var components = URLComponents(string: urlString)
            components?.queryItems = queryItems
            if let fullPath = components?.string {
                urlString = fullPath
            }
        }

        let (events, response): ([StoredEvent], HTTPURLResponse) = try await getWithResponse(urlString)
        let maxSequence = (response.value(forHTTPHeaderField: "X-Max-Sequence") ?? response.value(forHTTPHeaderField: "x-max-sequence"))
            .flatMap { Int64($0) }
        return MissionEventsResult(events: events, maxSequence: maxSequence)
    }

    // MARK: - FIDO Signing

    func fidoRespond(requestId: String, approved: Bool) async throws {
        let _: EmptyResponse = try await post(
            "/api/fido/respond",
            body: FidoRespondBody(request_id: requestId, approved: approved)
        )
    }

    /// Signing requests still waiting for an answer (`GET /api/fido/pending`),
    /// as payloads shaped like the `fido_sign_request` stream event.
    func fidoPending() async throws -> [[String: Any]] {
        let list: FidoPendingResponse = try await get("/api/fido/pending")
        return list.payloads
    }

    // MARK: - Control Streaming

    /// After this many consecutive WebSocket open failures, stop trying WS
    /// for the rest of the process lifetime and go straight to SSE. Some
    /// deployments (reverse proxies without upgrade support) close every WS
    /// attempt with 1011; retrying on each reconnect just adds latency and
    /// noise before the inevitable SSE fallback.
    nonisolated static let webSocketMaxOpenFailures = 3
    private var webSocketOpenFailureStreak = 0

    func streamControl(
        missionId: String?,
        sinceSeq: Int64? = nil,
        kinds: [String]? = nil,
        preferWebSocket: Bool = true,
        generation: Int = 0,
        onDiagnostic: ((ControlStreamDiagnostic) -> Void)? = nil,
        onEvent: @escaping (String, [String: Any]) -> Void
    ) -> Task<Void, Never> {
        let token = jwtToken

        return Task { [weak self] in
            guard let self else { return }
            // The WebSocket transport has no kind filter; a filtered stream is SSE only.
            if preferWebSocket, kinds == nil, token != nil, self.webSocketOpenFailureStreak < Self.webSocketMaxOpenFailures {
                let opened = await self.runControlWebSocket(
                    missionId: missionId,
                    sinceSeq: sinceSeq,
                    token: token,
                    generation: generation,
                    onDiagnostic: onDiagnostic,
                    onEvent: onEvent
                )
                if opened {
                    self.webSocketOpenFailureStreak = 0
                }
                if opened || Task.isCancelled {
                    return
                }
                self.webSocketOpenFailureStreak += 1
                self.emitDiagnostic(
                    transport: .webSocket,
                    phase: .fallback,
                    host: nil,
                    status: nil,
                    bytes: nil,
                    error: "WebSocket did not open; falling back to SSE",
                    eventType: nil,
                    generation: generation,
                    onDiagnostic: onDiagnostic
                )
            }
            await self.runControlSSE(
                missionId: missionId,
                sinceSeq: sinceSeq,
                kinds: kinds,
                token: token,
                generation: generation,
                onDiagnostic: onDiagnostic,
                onEvent: onEvent
            )
        }
    }

    private func runControlSSE(
        missionId: String?,
        sinceSeq: Int64?,
        kinds: [String]? = nil,
        token: String?,
        generation: Int,
        onDiagnostic: ((ControlStreamDiagnostic) -> Void)?,
        onEvent: @escaping (String, [String: Any]) -> Void
    ) async {
        let maxBuffer = Self.streamMaxBufferBytes
        let inactivity = Self.streamInactivityTimeout
        let session = Self.streamSession
        var queryItems = missionId.map { [URLQueryItem(name: "mission", value: $0)] } ?? []
        if let sinceSeq {
            queryItems.append(URLQueryItem(name: "since_seq", value: String(sinceSeq)))
        }
        if let kinds, !kinds.isEmpty {
            queryItems.append(URLQueryItem(name: "kinds", value: kinds.joined(separator: ",")))
        }
        guard let url = makeURL("/api/control/stream", queryItems: queryItems) else {
            emitDiagnostic(transport: .sse, phase: .error, host: nil, status: nil, bytes: nil, error: "Invalid server URL", eventType: nil, generation: generation, onDiagnostic: onDiagnostic)
            onEvent("error", ["message": "Invalid server URL", "reason": "invalid_configuration"])
            return
        }

        emitDiagnostic(transport: .sse, phase: .connecting, host: url.host, status: nil, bytes: nil, error: nil, eventType: nil, generation: generation, onDiagnostic: onDiagnostic)

        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (rawStream, response) = try await session.bytes(for: request)

            // Reject HTTP errors up front. The previous code happily fed
            // a 401 HTML body through the SSE parser, which silently
            // dropped events and left the user staring at "Reconnecting…".
            if let http = response as? HTTPURLResponse {
                guard (200..<300).contains(http.statusCode) else {
                    if http.statusCode == 401, token == authToken,
                       url.absoluteString.hasPrefix(baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/") {
                        markSessionExpired()
                    }
                    emitDiagnostic(transport: .sse, phase: .error, host: url.host, status: http.statusCode, bytes: nil, error: "Stream rejected", eventType: nil, generation: generation, onDiagnostic: onDiagnostic)
                    onEvent("error", [
                        "message": "Stream rejected by server (HTTP \(http.statusCode))",
                        "status": http.statusCode
                    ])
                    return
                }
                emitDiagnostic(transport: .sse, phase: .open, host: url.host, status: http.statusCode, bytes: nil, error: nil, eventType: nil, generation: generation, onDiagnostic: onDiagnostic)
            }
            onEvent("connected", ["type": "connected", "transport": ControlStreamTransport.sse.rawValue])

            // `rawStream.lines` decodes chunks as UTF-8 and yields per line.
            var eventType = "message"
            var dataLines: [String] = []
            var bufferedBytes = 0
            var bytesRead = 0

            for try await line in rawStream.lines {
                if Task.isCancelled { return }
                bytesRead += line.utf8.count + 1

                // Hard cap on per-event payload — a server that never emits a
                // blank line must not balloon this buffer.
                bufferedBytes += line.utf8.count + 1
                if bufferedBytes > maxBuffer {
                    emitDiagnostic(transport: .sse, phase: .error, host: url.host, status: nil, bytes: bytesRead, error: "Stream event exceeded buffer", eventType: nil, generation: generation, onDiagnostic: onDiagnostic)
                    onEvent("error", ["message": "Stream event exceeded \(maxBuffer) bytes — dropping connection"])
                    return
                }

                if line.isEmpty {
                    let dispatched = Self.dispatchSSEEvent(
                        eventType: eventType,
                        dataLines: dataLines,
                        onEvent: onEvent
                    )
                    if dispatched {
                        emitDiagnostic(transport: .sse, phase: .event, host: url.host, status: nil, bytes: bytesRead, error: nil, eventType: eventType, generation: generation, onDiagnostic: onDiagnostic)
                    }
                    eventType = "message"
                    dataLines.removeAll(keepingCapacity: true)
                    bufferedBytes = 0
                    continue
                }

                if line.hasPrefix(":") {
                    emitDiagnostic(transport: .sse, phase: .heartbeat, host: url.host, status: nil, bytes: bytesRead, error: nil, eventType: "heartbeat", generation: generation, onDiagnostic: onDiagnostic)
                    onEvent("heartbeat", ["type": "heartbeat", "transport": ControlStreamTransport.sse.rawValue])
                    continue
                }

                guard let colonIdx = line.firstIndex(of: ":") else { continue }
                let field = line[..<colonIdx]
                var value = line[line.index(after: colonIdx)...]
                if value.first == " " { value = value.dropFirst() }

                switch field {
                case "event":
                    eventType = String(value)
                case "data":
                    dataLines.append(String(value))
                default:
                    break
                }
            }
            emitDiagnostic(transport: .sse, phase: .closed, host: url.host, status: nil, bytes: bytesRead, error: nil, eventType: nil, generation: generation, onDiagnostic: onDiagnostic)
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .timedOut {
            emitDiagnostic(transport: .sse, phase: .error, host: url.host, status: nil, bytes: nil, error: "inactivity", eventType: nil, generation: generation, onDiagnostic: onDiagnostic)
            onEvent("error", [
                "message": "Stream idle (no data for \(Int(inactivity))s) — reconnecting",
                "reason": "inactivity"
            ])
        } catch {
            if !Task.isCancelled {
                emitDiagnostic(transport: .sse, phase: .error, host: url.host, status: nil, bytes: nil, error: error.localizedDescription, eventType: nil, generation: generation, onDiagnostic: onDiagnostic)
                onEvent("error", ["message": "Stream connection failed: \(error.localizedDescription)"])
            }
        }
    }

    /// Returns true after the socket opened. A false return means callers may
    /// try SSE fallback immediately.
    private func runControlWebSocket(
        missionId: String?,
        sinceSeq: Int64?,
        token: String?,
        generation: Int,
        onDiagnostic: ((ControlStreamDiagnostic) -> Void)?,
        onEvent: @escaping (String, [String: Any]) -> Void
    ) async -> Bool {
        guard let url = makeWebSocketURL("/api/control/ws", queryItems: missionId.map { [URLQueryItem(name: "mission", value: $0)] } ?? []) else {
            emitDiagnostic(transport: .webSocket, phase: .error, host: nil, status: nil, bytes: nil, error: "Invalid WebSocket URL", eventType: nil, generation: generation, onDiagnostic: onDiagnostic)
            onEvent("error", ["message": "Invalid server URL", "reason": "invalid_configuration"])
            return false
        }

        emitDiagnostic(transport: .webSocket, phase: .connecting, host: url.host, status: nil, bytes: nil, error: nil, eventType: nil, generation: generation, onDiagnostic: onDiagnostic)

        var request = URLRequest(url: url)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let task = Self.streamSession.webSocketTask(with: request)
        task.resume()

        var opened = false
        var bytesRead = 0
        do {
            if let sinceSeq {
                let resume = ["type": "resume", "since_seq": sinceSeq] as [String: Any]
                let data = try JSONSerialization.data(withJSONObject: resume)
                if let string = String(data: data, encoding: .utf8) {
                    try await task.send(.string(string))
                }
            }

            while !Task.isCancelled {
                let message = try await task.receive()
                let text: String
                switch message {
                case .string(let value):
                    text = value
                case .data(let data):
                    text = String(data: data, encoding: .utf8) ?? ""
                @unknown default:
                    continue
                }
                guard !text.isEmpty else { continue }
                bytesRead += text.utf8.count
                if !opened {
                    opened = true
                    emitDiagnostic(transport: .webSocket, phase: .open, host: url.host, status: 101, bytes: bytesRead, error: nil, eventType: nil, generation: generation, onDiagnostic: onDiagnostic)
                    onEvent("connected", ["type": "connected", "transport": ControlStreamTransport.webSocket.rawValue])
                }
                guard let data = text.data(using: .utf8),
                      let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
                    onEvent("parseError", ["raw": text, "reason": "invalid websocket json"])
                    continue
                }

                if let seq = obj["seq"] as? Int64 ?? (obj["seq"] as? Int).map(Int64.init),
                   obj["type"] == nil {
                    emitDiagnostic(transport: .webSocket, phase: .heartbeat, host: url.host, status: nil, bytes: bytesRead, error: nil, eventType: "heartbeat", generation: generation, onDiagnostic: onDiagnostic)
                    onEvent("heartbeat", ["type": "heartbeat", "transport": ControlStreamTransport.webSocket.rawValue, "seq": seq])
                    continue
                }

                let eventType = obj["type"] as? String ?? "message"
                emitDiagnostic(transport: .webSocket, phase: .event, host: url.host, status: nil, bytes: bytesRead, error: nil, eventType: eventType, generation: generation, onDiagnostic: onDiagnostic)
                onEvent(eventType, obj)
            }
        } catch is CancellationError {
            task.cancel(with: .normalClosure, reason: nil)
            return opened
        } catch {
            let nsError = error as NSError
            emitDiagnostic(transport: .webSocket, phase: .error, host: url.host, status: nsError.code, bytes: bytesRead, error: error.localizedDescription, eventType: nil, generation: generation, onDiagnostic: onDiagnostic)
            onEvent("error", [
                "message": opened
                    ? "WebSocket stream failed: \(error.localizedDescription)"
                    : "WebSocket failed to open: \(error.localizedDescription)",
                "reason": opened ? "web_socket_failed" : "web_socket_open_failed",
                "transport": ControlStreamTransport.webSocket.rawValue
            ])
        }
        task.cancel(with: .normalClosure, reason: nil)
        return opened
    }

    /// Flush a complete SSE event. `dataLines` are joined with `\n` per spec —
    /// the previous code joined with empty string, mangling multi-line JSON
    /// payloads. Only object-shaped JSON is forwarded; scalars/arrays/garbage
    /// surface as a structured `parseError` so the caller can log them
    /// instead of silently dropping data.
    @MainActor
    @discardableResult
    private static func dispatchSSEEvent(
        eventType: String,
        dataLines: [String],
        onEvent: (String, [String: Any]) -> Void
    ) -> Bool {
        guard !dataLines.isEmpty else { return false }
        let payload = dataLines.joined(separator: "\n")
        guard !payload.isEmpty else { return false }

        guard let data = payload.data(using: .utf8) else {
            onEvent("parseError", ["raw": payload, "reason": "non-utf8 payload"])
            return true
        }
        do {
            let parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            if let obj = parsed as? [String: Any] {
                onEvent(eventType, obj)
            } else {
                onEvent("parseError", ["raw": payload, "reason": "non-object payload"])
            }
        } catch {
            onEvent("parseError", ["raw": payload, "reason": error.localizedDescription])
        }
        return true
    }
    
    // MARK: - Requests

    private struct EmptyResponse: Decodable {}

    /// Untyped JSON call used by the Orb screens. `rawBody` sends exact bytes
    /// (device-signed requests hash them); `headers` are added as-is.
    func call(_ path: String, method: String = "GET", body: OrbJSON? = nil, rawBody: Data? = nil, headers: [String: String] = [:]) async throws -> OrbJSON {
        guard let url = URL(string: endpoint + path) else {
            ErrorRing.shared.recordRequest(path: "\(method) \(path)", error: OrbHTTPError.invalidURL)
            throw OrbHTTPError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("Bearer \(authToken ?? "")", forHTTPHeaderField: "Authorization")
        if let rawBody { request.httpBody = rawBody; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        else if let body {
            do { request.httpBody = try JSONEncoder().encode(body) }
            catch { ErrorRing.shared.recordRequest(path: "\(method) \(path)", error: error); throw error }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, _) = try await send(request, session: .shared, label: "\(method) \(path)", failure: "Request failed")
        if data.isEmpty { return .null }
        return try await decode(OrbJSON.self, from: data, label: "\(method) \(path)")
    }

    func transcribe(_ wav: Data, language: String) async throws -> String {
        guard wav.count <= 4 * 1024 * 1024,
              let url = URL(string: endpoint + "/api/voice/transcribe?language=" + Self.escape(language)) else { throw OrbHTTPError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 100
        request.setValue("Bearer \(authToken ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = wav
        let (data, _) = try await send(request, session: .shared, label: "POST /api/voice/transcribe", failure: "Transcription failed")
        return try await decode(OrbJSON.self, from: data, label: "POST /api/voice/transcribe")["text"].text
    }

    nonisolated static func escape(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }

    func missions(_ project: String, includeArchived: Bool = false) async throws -> [OrbRow] {
        var rows: [OrbRow] = [], offset = 0
        while true {
            let page = try await call("/api/control/missions?project=\(Self.escape(project))&all=true&limit=100&offset=\(offset)").items
            for raw in page {
                let mid = raw["id"].text
                if !mid.isEmpty {
                    OrbReadCache.seedMemory("mission:\(mid)", value: raw)
                }
            }
            let fresh = page.map { OrbRow($0) }.filter { row in !rows.contains(where: { $0.id == row.id }) }
            rows += fresh
            if !includeArchived || page.count < 100 || fresh.isEmpty { break }
            offset += page.count
        }
        return rows.filter(\.mobile)
    }

    private func get<T: Decodable>(_ path: String, authenticated: Bool = true) async throws -> T {
        try await getWithResponse(path, authenticated: authenticated).0
    }

    /// GET that also returns the underlying `HTTPURLResponse` so callers can
    /// inspect response headers (e.g. `X-Max-Sequence` for delta-event resume).
    private func getWithResponse<T: Decodable>(
        _ path: String,
        authenticated: Bool = true
    ) async throws -> (T, HTTPURLResponse) {
        try await typed(path, method: "GET", body: nil as OrbJSON?, authenticated: authenticated)
    }

    private func post<T: Decodable, B: Encodable>(
        _ path: String,
        body: B,
        authenticated: Bool = true
    ) async throws -> T {
        try await typed(path, method: "POST", body: body, authenticated: authenticated).0
    }

    private func typed<T: Decodable, B: Encodable>(_ path: String, method: String, body: B?, authenticated: Bool) async throws -> (T, HTTPURLResponse) {
        guard let url = makeURL(path) else { throw OrbHTTPError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if authenticated, let token = jwtToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let label = "\(method) \(url.path)"
        let (data, response) = try await send(request, session: Self.jsonSession, label: label, failure: "Unknown error")
        if data.isEmpty || T.self == EmptyResponse.self, let empty = EmptyResponse() as? T {
            return (empty, response)
        }
        return (try await decode(T.self, from: data, label: label), response)
    }

    /// The single transport: performs the request, maps failures to
    /// `OrbHTTPError`, expires the session on a 401 for the current token, and
    /// records failures in the diagnostics ring.
    private func send(_ request: URLRequest, session: URLSession, label: String, failure: String) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw OrbHTTPError.invalidResponse }
            if http.statusCode == 401 {
                // A rejected login or an old in-flight request must not clear a newer session.
                if let authorization = request.value(forHTTPHeaderField: "Authorization"),
                   authorization == "Bearer \(authToken ?? "")",
                   request.url?.absoluteString.hasPrefix(endpoint + "/") == true {
                    markSessionExpired()
                }
                throw OrbHTTPError.unauthorized
            }
            guard (200..<300).contains(http.statusCode) else {
                let text = String(data: data, encoding: .utf8) ?? ""
                throw OrbHTTPError(status: http.statusCode, detail: text.isEmpty ? failure : text)
            }
            return (data, http)
        } catch {
            ErrorRing.shared.recordRequest(path: label, error: error)
            throw error
        }
    }

    /// Decodes off the main actor so a multi-MB events payload does not block the UI.
    private func decode<T: Decodable>(_ type: T.Type, from data: Data, label: String) async throws -> T {
        do {
            return try await Task.detached(priority: .userInitiated) {
                try DecodedBox(value: JSONDecoder().decode(T.self, from: data))
            }.value.value
        } catch {
            let wrapped = OrbHTTPError.decoding(error)
            ErrorRing.shared.recordRequest(path: label, error: wrapped)
            throw wrapped
        }
    }

    private func makeURL(_ path: String) -> URL? {
        makeURL(path, queryItems: [])
    }

    private func makeURL(_ path: String, queryItems: [URLQueryItem]) -> URL? {
        guard var components = makeURLComponents(path) else { return nil }
        // Only override the query when the caller passes explicit items —
        // assigning nil here used to wipe query strings already embedded in
        // `path` (e.g. "/api/fs/list?path=/root"), which the server rejected
        // with 400 "missing field" errors.
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url
    }

    private func makeWebSocketURL(_ path: String, queryItems: [URLQueryItem]) -> URL? {
        guard var components = makeURLComponents(path) else { return nil }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: return nil
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    private func makeURLComponents(_ path: String) -> URLComponents? {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let components = URLComponents(string: "\(trimmedBase)\(normalizedPath)"),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              components.host?.isEmpty == false
        else {
            return nil
        }
        return components
    }

    private func emitDiagnostic(
        transport: ControlStreamTransport,
        phase: ControlStreamPhase,
        host: String?,
        status: Int?,
        bytes: Int?,
        error: String?,
        eventType: String?,
        generation: Int,
        onDiagnostic: ((ControlStreamDiagnostic) -> Void)?
    ) {
        onDiagnostic?(ControlStreamDiagnostic(
            transport: transport,
            phase: phase,
            host: host,
            status: status,
            bytes: bytes,
            error: error,
            eventType: eventType,
            generation: generation,
            timestamp: Date()
        ))
    }
    
}

/// Sendable transport for decoded values across the detached-decode boundary.
/// Marked `@unchecked` because `T: Decodable` makes no Sendable promise and we
/// can't constrain every existing Decodable type in the codebase. Safe in
/// practice: the producer (decode task) has the only reference until `.value`
/// crosses back to the consumer actor, after which the producer is gone.
private struct DecodedBox<T>: @unchecked Sendable {
    let value: T
}

/// Result of a `/missions/:id/events` fetch. `maxSequence` is the response's
/// `X-Max-Sequence` header.
///
/// `Sendable` so it can cross `async let` boundaries from the main actor —
/// `StoredEvent` and `AnyCodable` are Sendable above.
struct MissionEventsResult: Sendable {
    let events: [StoredEvent]
    let maxSequence: Int64?
}


/// The one error type for backend requests. `status` is the HTTP status
/// (401 for an expired session) or 0 for failures that never got a response.
struct OrbHTTPError: LocalizedError, Equatable {
    enum Kind: Equatable { case http, unauthorized, invalidURL, invalidResponse, decoding }
    let status: Int
    let detail: String
    var kind: Kind = .http

    init(status: Int, detail: String, kind: Kind = .http) {
        self.status = status
        self.detail = detail
        self.kind = kind
    }

    static let unauthorized = OrbHTTPError(status: 401, detail: "Authentication required", kind: .unauthorized)
    static let invalidURL = OrbHTTPError(status: 0, detail: "Invalid URL", kind: .invalidURL)
    static let invalidResponse = OrbHTTPError(status: 0, detail: "Invalid response from server", kind: .invalidResponse)
    static func decoding(_ error: Error) -> OrbHTTPError {
        OrbHTTPError(status: 0, detail: "Failed to decode response: \(error.localizedDescription)", kind: .decoding)
    }

    var errorDescription: String? { kind == .http ? "\(status): \(detail)" : detail }
}
