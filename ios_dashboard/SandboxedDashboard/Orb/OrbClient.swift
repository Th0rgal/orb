import Foundation
import Observation

/// The one HTTP client for the Core backend: server URL, auth (Keychain
/// token + saved login), typed and untyped JSON calls, control streams. Every
/// request goes through `send`, so 401 handling and errors (`OrbHTTPError`) are
/// the same everywhere.
@MainActor
@Observable
final class OrbCore {
    static let shared = OrbCore()
    nonisolated init() { OrbCrashBreadcrumbs.install() }

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
    @ObservationIgnored private var endpointCooldowns: [String: Date] = [:]
    @ObservationIgnored private var missionDeltaScope: String = ""
    @ObservationIgnored private var missionDeltaCursor: String?
    @ObservationIgnored private var missionDeltaPolls: Int = 0
    @ObservationIgnored private var missionDeltaLastFullSync: Date = .distantPast
    @ObservationIgnored private var missionDeltaCache: [OrbJSON] = []
    @ObservationIgnored private var syncHub: ControlSyncHub?

    private func resetMissionDeltaState() {
        missionDeltaScope = ""
        missionDeltaCursor = nil
        missionDeltaPolls = 0
        missionDeltaLastFullSync = .distantPast
        missionDeltaCache.removeAll()
        syncHub?.closeAll()
        syncHub = nil
    }

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
            endpointCooldowns.removeAll()
            resetMissionDeltaState()
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
    var githubEnabled: Bool = false
    var githubOAuthClientState: Bool = false
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

    /// Saves a server-validated OAuth session token for `baseURL` without retaining an old password login.
    func acceptIssuedToken(_ token: String) throws {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw OrbHTTPError(status: 0, detail: "Missing authentication token")
        }
        let currentEndpoint = baseURL
        loginAttempt = UUID()
        guard OrbKeychain.save(clean, for: currentEndpoint) else {
            throw NSError(
                domain: "OrbKeychain",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not securely save your login. Please unlock your device and try again."]
            )
        }
        OrbKeychain.saveCredentials(nil, for: currentEndpoint)
        cachedTokenEndpoint = currentEndpoint
        cachedJwtToken = clean
        UserDefaults.standard.removeObject(forKey: "jwt_token")
        authSessionExpired = false
        connectionGeneration += 1
    }
    
    func logout() {
        loginAttempt = UUID()
        sessionRecovery?.cancel(); sessionRecovery = nil; authRefreshing = false
        OrbKeychain.saveCredentials(nil, for: baseURL)
        jwtToken = nil
        authSessionExpired = false
        resetMissionDeltaState()
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
            let githubEnabled: Bool?
            let githubOAuthClientState: Bool?
            let version: String?

            enum CodingKeys: String, CodingKey {
                case status, version
                case authRequired = "auth_required"
                case authMode = "auth_mode"
                case githubEnabled = "github_enabled"
                case githubOAuthClientState = "github_oauth_client_state"
            }
        }
        
        let response: HealthResponse = try await get("/api/health", authenticated: false)
        authRequired = response.authRequired
        githubEnabled = response.githubEnabled == true
        githubOAuthClientState = response.githubOAuthClientState == true
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
        beforeSeq: Int64? = nil,
        maxPayload: Int? = StoredEvent.resultKeepUTF8
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
        if let maxPayload = maxPayload {
            queryItems.append(URLQueryItem(name: "max_payload", value: String(maxPayload)))
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

    var canUseMultiplexSync: Bool {
        #if DEBUG
        let isUITestMock = ProcessInfo.processInfo.arguments.contains("-api_base_url")
        #else
        let isUITestMock = false
        #endif
        return !isUITestMock && jwtToken != nil && webSocketOpenFailureStreak < Self.webSocketMaxOpenFailures
    }

    var isMultiplexSyncHealthy: Bool {
        guard let hub = syncHub, !hub.closed, hub.opened else { return false }
        return hub.scope == "\(endpoint)|\(jwtToken ?? "")"
    }

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
        #if DEBUG
        let isUITestMock = ProcessInfo.processInfo.arguments.contains("-api_base_url")
        #else
        let isUITestMock = false
        #endif
        let canMultiplex = !isUITestMock && preferWebSocket && token != nil &&
            (kinds == nil || kinds == ["presentation"] || kinds == ["fido"]) &&
            webSocketOpenFailureStreak < Self.webSocketMaxOpenFailures

        return Task { [weak self] in
            guard let self else { return }
            if canMultiplex, let token {
                let opened = await self.runMultiplexedControlSync(
                    missionId: missionId,
                    sinceSeq: sinceSeq,
                    kinds: kinds,
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
                    error: "Multiplexed sync WebSocket did not open; falling back to SSE",
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
            if kinds == ["presentation"] {
                queryItems.append(URLQueryItem(name: "profile", value: "presentation"))
                queryItems.append(URLQueryItem(name: "kinds", value: "mission_presentation"))
            }
            else { queryItems.append(URLQueryItem(name: "kinds", value: kinds.joined(separator: ","))) }
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

    @MainActor
    private final class ControlSyncHub {
        struct Subscriber {
            let id: UUID
            let missionId: String?
            let kinds: [String]?
            let sinceSeq: Int64?
            let generation: Int
            let onDiagnostic: ((ControlStreamDiagnostic) -> Void)?
            let onEvent: (String, [String: Any]) -> Void
            var openedNotified: Bool
            let finish: (Bool) -> Void
        }

        let scope: String
        let candidates: [String]
        let token: String
        private(set) var opened = false
        private(set) var closed = false
        private var subscribers: [UUID: Subscriber] = [:]
        private var subscribedMissions: Set<String> = []
        private var presentationSent: Bool?
        private var wsTask: URLSessionWebSocketTask?
        private var runnerTask: Task<Void, Never>?

        init(scope: String, candidates: [String], token: String) {
            self.scope = scope
            self.candidates = candidates
            self.token = token
            self.runnerTask = Task { @MainActor [weak self] in
                await self?.run()
            }
        }

        func addSubscriber(_ sub: Subscriber) {
            guard !closed else {
                sub.finish(opened)
                return
            }
            var entry = sub
            if opened {
                entry.openedNotified = true
                entry.onEvent("connected", ["type": "connected", "transport": ControlStreamTransport.webSocket.rawValue])
            }
            subscribers[entry.id] = entry
            syncSubscriptions()
        }

        func removeSubscriber(_ id: UUID) {
            guard let removed = subscribers.removeValue(forKey: id) else { return }
            removed.finish(opened)
            syncSubscriptions()
            if subscribers.isEmpty {
                closeAll()
            }
        }

        func closeAll() {
            guard !closed else { return }
            closed = true
            let wasOpened = opened
            let subs = Array(subscribers.values)
            subscribers.removeAll()
            wsTask?.cancel(with: .normalClosure, reason: nil)
            wsTask = nil
            runnerTask?.cancel()
            runnerTask = nil
            for sub in subs {
                sub.finish(wasOpened || sub.openedNotified)
            }
        }

        private func sendJSON(_ obj: [String: Any]) {
            guard opened, let task = wsTask,
                  let data = try? JSONSerialization.data(withJSONObject: obj),
                  let text = String(data: data, encoding: .utf8) else { return }
            Task { try? await task.send(.string(text)) }
        }

        private func syncSubscriptions() {
            guard opened, !closed else { return }
            let wantPresentation = subscribers.values.contains { $0.kinds == ["presentation"] }
            if presentationSent != wantPresentation {
                presentationSent = wantPresentation
                sendJSON(["op": "set_presentation", "enabled": wantPresentation])
            }
            var wantedMissions: [String: Int64?] = [:]
            for sub in subscribers.values {
                guard let mid = sub.missionId, !mid.isEmpty else { continue }
                if let existing = wantedMissions[mid] {
                    if let a = existing, let b = sub.sinceSeq {
                        wantedMissions[mid] = min(a, b)
                    } else {
                        wantedMissions[mid] = nil
                    }
                } else {
                    wantedMissions[mid] = sub.sinceSeq
                }
            }
            for mid in Array(subscribedMissions) where wantedMissions[mid] == nil {
                subscribedMissions.remove(mid)
                sendJSON(["op": "unsubscribe", "mission_id": mid])
            }
            for (mid, seq) in wantedMissions where !subscribedMissions.contains(mid) {
                subscribedMissions.insert(mid)
                var msg: [String: Any] = [
                    "op": "subscribe",
                    "mission_id": mid,
                    "max_payload": StoredEvent.resultKeepUTF8
                ]
                if let seq { msg["since_seq"] = seq }
                sendJSON(msg)
            }
        }

        private static func makeWSURL(base: String, path: String) -> URL? {
            let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard var comp = URLComponents(string: trimmed + path) else { return nil }
            switch comp.scheme?.lowercased() {
            case "https": comp.scheme = "wss"
            case "http": comp.scheme = "ws"
            default: return nil
            }
            return comp.url
        }

        private func run() async {
            for base in candidates {
                if Task.isCancelled || closed { break }
                guard let url = Self.makeWSURL(base: base, path: "/api/control/sync") else { continue }
                var request = URLRequest(url: url)
                let connectDeadlineSecs = max(6.0, Double(OrbBackgroundSyncMonitor.shared.linkBudget.connectDeadlineMs) / 1000.0)
                request.timeoutInterval = connectDeadlineSecs
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let task = OrbCore.streamSession.webSocketTask(with: request)
                self.wsTask = task
                self.subscribedMissions.removeAll()
                self.presentationSent = nil
                task.resume()

                var awaitingPongSinceMs: Int64? = nil
                let pingLoop = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(10))
                        guard let self, !self.closed, self.opened else { continue }
                        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                        let pongDeadlineMs = Int64(OrbBackgroundSyncMonitor.shared.linkBudget.pongDeadlineMs)
                        if let since = awaitingPongSinceMs, nowMs - since >= pongDeadlineMs {
                            task.cancel(with: .goingAway, reason: nil)
                            break
                        }
                        if awaitingPongSinceMs == nil {
                            awaitingPongSinceMs = nowMs
                        }
                        self.sendJSON(["op": "ping", "ts": nowMs])
                    }
                }

                do {
                    while !Task.isCancelled && !closed {
                        let message = try await task.receive()
                        awaitingPongSinceMs = nil
                        let text: String
                        switch message {
                        case .string(let s): text = s
                        case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                        @unknown default: continue
                        }
                        guard !text.isEmpty,
                              let data = text.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
                            continue
                        }
                        if !opened {
                            opened = true
                            for key in Array(subscribers.keys) {
                                guard var sub = subscribers[key], !sub.openedNotified else { continue }
                                sub.openedNotified = true
                                subscribers[key] = sub
                                sub.onEvent("connected", ["type": "connected", "transport": ControlStreamTransport.webSocket.rawValue])
                            }
                            syncSubscriptions()
                            sendJSON(["op": "ping", "ts": Int64(Date().timeIntervalSince1970 * 1000)])
                        }
                        let eventType = obj["type"] as? String ?? ""
                        if eventType.isEmpty || eventType == "sync_ready" || eventType == "subscribed" || eventType == "unsubscribed" {
                            continue
                        }
                        if eventType == "heartbeat" || eventType == "pong" {
                            if eventType == "pong", let ts = (obj["ts"] as? NSNumber)?.int64Value {
                                let rtt = Int(Int64(Date().timeIntervalSince1970 * 1000) - ts)
                                if rtt >= 0 && rtt < 120_000 {
                                    OrbBackgroundSyncMonitor.shared.notePingRtt(ms: rtt)
                                }
                            }
                            for sub in subscribers.values {
                                sub.onEvent("heartbeat", ["type": "heartbeat", "transport": ControlStreamTransport.webSocket.rawValue])
                            }
                            continue
                        }
                        if eventType == "stream_lagged" {
                            let targetMid = (obj["mission_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                            if targetMid == nil || targetMid?.isEmpty == true {
                                OrbBackgroundSyncMonitor.shared.noteStreamLagged()
                            }
                        }
                        if eventType == "mission_presentation" {
                            for sub in subscribers.values where sub.kinds == ["presentation"] {
                                sub.onEvent(eventType, obj)
                            }
                            continue
                        }
                        if eventType == "mission_placement_changed" {
                            OrbCore.applyIncomingPlacementEvent(obj)
                            for sub in subscribers.values where sub.kinds == ["presentation"] || sub.missionId != nil || sub.kinds == nil {
                                sub.onEvent(eventType, obj)
                            }
                            continue
                        }
                        if eventType == "fido_sign_request" {
                            for sub in subscribers.values where sub.kinds == ["fido"] || sub.missionId != nil {
                                sub.onEvent(eventType, obj)
                            }
                            continue
                        }
                        let targetMid = obj["mission_id"] as? String
                        for sub in subscribers.values {
                            if let mid = sub.missionId {
                                if targetMid == nil || targetMid == mid {
                                    sub.onEvent(eventType, obj)
                                }
                            } else if sub.kinds == nil {
                                sub.onEvent(eventType, obj)
                            }
                        }
                    }
                } catch {
                    pingLoop.cancel()
                    task.cancel(with: .normalClosure, reason: nil)
                    if opened {
                        if !closed {
                            OrbBackgroundSyncMonitor.shared.noteUnexpectedDisconnect()
                        }
                        // Socket was established and later dropped; finish active tasks so callers reconnect cleanly.
                        break
                    }
                    // Try next candidate endpoint before falling back to SSE.
                    continue
                }
                pingLoop.cancel()
                break
            }
            closeAll()
        }
    }

    /// Multiplexes presentation, FIDO, and per-mission subscriptions onto one shared
    /// `/api/control/sync` WebSocket. Returns `true` if the socket opened; `false` triggers SSE fallback.
    private func runMultiplexedControlSync(
        missionId: String?,
        sinceSeq: Int64?,
        kinds: [String]?,
        token: String,
        generation: Int,
        onDiagnostic: ((ControlStreamDiagnostic) -> Void)?,
        onEvent: @escaping (String, [String: Any]) -> Void
    ) async -> Bool {
        let currentEndpoint = endpoint
        let scope = "\(currentEndpoint)|\(token)"
        if let existing = syncHub, existing.closed || existing.scope != scope {
            existing.closeAll()
            syncHub = nil
        }
        let hub: ControlSyncHub
        if let existing = syncHub {
            hub = existing
        } else {
            let candidates = orderedCandidateEndpoints(for: currentEndpoint)
            guard !candidates.isEmpty else { return false }
            let created = ControlSyncHub(scope: scope, candidates: candidates, token: token)
            syncHub = created
            hub = created
        }

        let subId = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                var resumed = false
                let sub = ControlSyncHub.Subscriber(
                    id: subId,
                    missionId: missionId,
                    kinds: kinds,
                    sinceSeq: sinceSeq,
                    generation: generation,
                    onDiagnostic: onDiagnostic,
                    onEvent: onEvent,
                    openedNotified: false,
                    finish: { didOpen in
                        guard !resumed else { return }
                        resumed = true
                        continuation.resume(returning: didOpen)
                    }
                )
                hub.addSubscriber(sub)
            }
        } onCancel: {
            Task { @MainActor [weak hub] in
                hub?.removeSubscriber(subId)
            }
        }
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
                if eventType == "mission_placement_changed" {
                    OrbCore.applyIncomingPlacementEvent(obj)
                }
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
    func call(
        _ path: String,
        method: String = "GET",
        body: OrbJSON? = nil,
        rawBody: Data? = nil,
        headers: [String: String] = [:],
        explicitEndpoint: String? = nil,
        explicitToken: String? = nil
    ) async throws -> OrbJSON {
        let base = explicitEndpoint ?? endpoint
        let bearer = explicitToken ?? (authToken ?? "")
        guard let url = URL(string: base + path) else {
            ErrorRing.shared.recordRequest(path: "\(method) \(path)", error: OrbHTTPError.invalidURL)
            throw OrbHTTPError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
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

    /// For endpoints that answer plain text ("Committed successfully", a file at a revision).
    func callText(_ path: String, method: String = "GET", body: OrbJSON? = nil) async throws -> String {
        guard let url = URL(string: endpoint + path) else { throw OrbHTTPError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("Bearer \(authToken ?? "")", forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, _) = try await send(request, session: .shared, label: "\(method) \(path)", failure: "Request failed")
        return String(decoding: data, as: UTF8.self)
    }

    /// For endpoints that answer binary payloads (such as `.zip` settings backups).
    func callData(
        _ path: String,
        method: String = "GET",
        rawBody: Data? = nil,
        headers: [String: String] = [:],
        explicitEndpoint: String? = nil,
        explicitToken: String? = nil
    ) async throws -> Data {
        let base = explicitEndpoint ?? endpoint
        let bearer = explicitToken ?? (authToken ?? "")
        guard let url = URL(string: base + path) else { throw OrbHTTPError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 90
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        if let rawBody { request.httpBody = rawBody }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, _) = try await send(request, session: .shared, label: "\(method) \(path)", failure: "Request failed")
        return data
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

    nonisolated private static let unreservedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    nonisolated static func escape(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? "" }

    private func fetchAncestor(_ id: String) async -> OrbRow? {
        if let cached = OrbHierarchy.cachedAncestor(id) { return cached }
        do {
            let raw = try await call("/api/control/missions/\(Self.escape(id))?include_history=false")
            let mid = raw["id"].text
            if !mid.isEmpty {
                OrbReadCache.seedMemory("mission:\(mid)", value: raw)
            }
            let row = OrbRow(raw)
            OrbHierarchy.storeAncestor(row)
            return row
        } catch let http as OrbHTTPError where http.status == 404 {
            OrbHierarchy.markGone(id)
            return nil
        } catch {
            return OrbHierarchy.cachedAncestor(id, allowStale: true)
        }
    }

    /// A project's recent history plus open missions beyond the page (`openBeyondPage`, M2)
    /// and any paged-out ancestors (`withAncestors`), matching desktop `listProjectMissions`.
    func missions(_ project: String, includeArchived: Bool = false) async throws -> [OrbRow] {
        let escaped = Self.escape(project)
        var history: [OrbRow] = []
        var liveRows: [OrbRow] = []
        if includeArchived {
            var offset = 0
            while true {
                let page = try await call("/api/control/missions?project=\(escaped)&all=true&limit=100&offset=\(offset)").items
                for raw in page {
                    let mid = raw["id"].text
                    if !mid.isEmpty { OrbReadCache.seedMemory("mission:\(mid)", value: raw) }
                }
                let fresh = page.map { OrbRow($0) }.filter { row in !history.contains(where: { $0.id == row.id }) }
                history += fresh
                if page.count < 100 || fresh.isEmpty { break }
                offset += page.count
            }
        } else {
            async let historyPage = call("/api/control/missions?project=\(escaped)&all=true&limit=100&offset=0")
            async let firstLivePage = call("/api/control/missions?project=\(escaped)&limit=200")
            let (rawHistory, rawFirstLive) = try await (historyPage, firstLivePage)
            for raw in rawHistory.items + rawFirstLive.items {
                let mid = raw["id"].text
                if !mid.isEmpty { OrbReadCache.seedMemory("mission:\(mid)", value: raw) }
            }
            history = rawHistory.items.map { OrbRow($0) }
            var livePages: [[OrbJSON]] = [rawFirstLive.items]
            var offset = 200
            while livePages.last?.count == 200 && offset < 1000 {
                let next = try await call("/api/control/missions?project=\(escaped)&limit=200&offset=\(offset)").items
                for raw in next {
                    let mid = raw["id"].text
                    if !mid.isEmpty { OrbReadCache.seedMemory("mission:\(mid)", value: raw) }
                }
                livePages.append(next)
                offset += 200
            }
            liveRows = livePages.flatMap { $0 }.map { OrbRow($0) }
        }

        var byID: [String: OrbRow] = [:]
        var merged: [OrbRow] = []
        let beyond = includeArchived ? [] : OrbMissionTree.openBeyondPage(history, extra: liveRows)
        for row in history + beyond where byID[row.id] == nil {
            byID[row.id] = row
            merged.append(row)
        }
        merged.sort { $0.updatedAt > $1.updatedAt }

        let ownIDs = Set(merged.map(\.id))
        let withParents = await OrbMissionTree.withAncestors(merged) { [weak self] id in
            await self?.fetchAncestor(id)
        }
        let scoped = OrbMissionTree.filterToProjectScope(withParents, projectSlug: project, ownIDs: ownIDs)
        return OrbMissionTree.mergePendingStagedRows(OrbMissionTree.filterMobile(scoped), projectSlug: project)
    }

    @discardableResult
    func moveMissions(
        ids: [String],
        project: String?,
        folder: String,
        approvalPolicy: String = "check",
        clientOpID: UInt32 = 0,
        fallbackRows: [OrbRow] = []
    ) async throws -> [OrbPlacementCommitItem] {
        var payload: [String: OrbJSON] = [
            "mission_ids": .array(ids.map(OrbJSON.string)),
            "project": project.flatMap { $0.isEmpty ? nil : OrbJSON.string($0) } ?? .null,
            "folder": .string(OrbRow.normalizeFolder(folder)),
            "approval_policy": .string(approvalPolicy),
        ]
        if clientOpID != 0 {
            payload["client_op_id"] = .number(Double(clientOpID))
            payload["client_id"] = .string(OrbHierarchy.localClientID)
        }
        let response: OrbJSON
        do {
            response = try await call("/api/control/missions/move", method: "POST", body: .object(payload))
        } catch {
            if let confirmation = OrbApprovalTransferConfirmationError.parse(from: error) {
                throw confirmation
            }
            throw error
        }
        let rawAck = UInt32(max(0, Int(response["client_op_id"].doubleValue ?? Double(clientOpID))))
        let respClientID = response["client_id"].text.isEmpty ? OrbHierarchy.localClientID : response["client_id"].text
        let ackOp = OrbHierarchy.resolveLocalAckOpID(clientOpID: rawAck, clientID: respClientID)
        let items: [OrbPlacementCommitItem] = response["moved"].items.compactMap { m in
            let mid = m["mission_id"].text
            guard !mid.isEmpty else { return nil }
            let proj = m["project"].text.isEmpty ? nil : m["project"].text
            let targetFolder = m["folder"].text
            let rev = UInt64(max(0, Int64(m["placement_revision"].doubleValue ?? 0)))
            return OrbPlacementCommitItem(missionID: mid, project: proj, folder: targetFolder, placementRevision: rev)
        }
        let accepted = OrbHierarchy.commitAuthoritativePlacements(items, ackOpID: ackOp)
        if !accepted.isEmpty {
            var byID: [String: OrbRow] = [:]
            for r in fallbackRows where !r.id.isEmpty && byID[r.id] == nil { byID[r.id] = r }
            OrbReadCache.applyPlacementCommit(accepted, fallbackRows: byID)
            var info: [String: Any] = ["moves": accepted]
            if !fallbackRows.isEmpty { info["rows"] = fallbackRows }
            NotificationCenter.default.post(
                name: Notification.Name("OrbMissionPlacementChanged"),
                object: nil,
                userInfo: info
            )
        }
        return accepted
    }

    static func applyTransferMovedMissions(_ response: OrbJSON, fallbackProject: String) {
        let items: [OrbPlacementCommitItem] = response["moved_missions"].items.compactMap { m in
            let mid = m["mission_id"].text
            guard !mid.isEmpty else { return nil }
            let projText = m["project"].text
            let proj = projText.isEmpty ? (fallbackProject.isEmpty ? nil : fallbackProject) : projText
            let targetFolder = m["folder"].text
            let rev = UInt64(max(0, Int64(m["placement_revision"].doubleValue ?? 0)))
            return OrbPlacementCommitItem(missionID: mid, project: proj, folder: targetFolder, placementRevision: rev)
        }
        guard !items.isEmpty else { return }
        let accepted = OrbHierarchy.commitAuthoritativePlacements(items, ackOpID: 0)
        if !accepted.isEmpty {
            OrbReadCache.applyPlacementCommit(accepted)
            NotificationCenter.default.post(
                name: Notification.Name("OrbMissionPlacementChanged"),
                object: nil,
                userInfo: ["moves": accepted]
            )
        }
    }

    @discardableResult
    nonisolated static func applyIncomingPlacementEvent(_ obj: [String: Any]) -> [OrbPlacementCommitItem] {
        let rawMoves = (obj["moves"] as? [[String: Any]]) ?? (obj["moved"] as? [[String: Any]]) ?? []
        guard !rawMoves.isEmpty else { return [] }
        let rawOp = UInt32(max(0, (obj["client_op_id"] as? NSNumber)?.intValue ?? 0))
        let ackOp = OrbHierarchy.resolveLocalAckOpID(clientOpID: rawOp, clientID: obj["client_id"] as? String)
        let items: [OrbPlacementCommitItem] = rawMoves.compactMap { m in
            let mid = ((m["mission_id"] as? String) ?? (m["id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !mid.isEmpty else { return nil }
            let proj: String?
            if let s = m["project"] as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                proj = trimmed.isEmpty ? nil : trimmed
            } else {
                proj = nil
            }
            let targetFolder = (m["folder"] as? String) ?? ""
            let rev = UInt64(max(0, (m["placement_revision"] as? NSNumber)?.int64Value ?? 0))
            return OrbPlacementCommitItem(missionID: mid, project: proj, folder: targetFolder, placementRevision: rev)
        }
        guard !items.isEmpty else { return [] }
        let accepted = OrbHierarchy.commitAuthoritativePlacements(items, ackOpID: ackOp)
        if !accepted.isEmpty {
            let applyMain = { @MainActor in
                OrbReadCache.applyPlacementCommit(accepted)
                NotificationCenter.default.post(
                    name: Notification.Name("OrbMissionPlacementChanged"),
                    object: nil,
                    userInfo: ["moves": accepted]
                )
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated(applyMain)
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated(applyMain)
                }
            }
        }
        return accepted
    }

    private func advanceMissionDeltaCursor(with items: [OrbJSON]) {
        var maxDate: Date? = missionDeltaCursor.flatMap { OrbDateCache.parse($0) }
        for item in items {
            let stamp = item["updated_at"].text.isEmpty ? item["created_at"].text : item["updated_at"].text
            if let parsed = OrbDateCache.parse(stamp) {
                if maxDate == nil || parsed > maxDate! {
                    maxDate = parsed
                }
            }
            let metaStamp = item["metadata_updated_at"].text
            if !metaStamp.isEmpty, let parsedMeta = OrbDateCache.parse(metaStamp) {
                if maxDate == nil || parsedMeta > maxDate! {
                    maxDate = parsedMeta
                }
            }
        }
        if let maxDate {
            let overlapped = maxDate.addingTimeInterval(-2.0)
            missionDeltaCursor = overlapped.ISO8601Format()
        }
    }

    /// Incremental global mission sync (`?updated_since=` with `-2s` overlap margin,
    /// full sync on cold start and every 20 polls / 10 minutes), matching desktop `listMissions`.
    func syncRecentMissions(limit: Int = 100, includeAll: Bool = true, forceFull: Bool = false) async throws -> OrbJSON {
        let currentScope = "\(endpoint)|\(authToken ?? "")|\(limit)|\(includeAll)"
        let now = Date()
        let needFull = forceFull ||
            missionDeltaScope != currentScope ||
            missionDeltaCursor == nil ||
            missionDeltaCache.isEmpty ||
            missionDeltaPolls >= 20 ||
            now.timeIntervalSince(missionDeltaLastFullSync) >= 600

        let baseQuery = "/api/control/missions?limit=\(limit)\(includeAll ? "&all=true" : "")"
        if needFull {
            let raw = try await call(baseQuery)
            missionDeltaScope = currentScope
            missionDeltaCache = raw.items
            missionDeltaPolls = 0
            missionDeltaLastFullSync = now
            missionDeltaCursor = nil
            advanceMissionDeltaCursor(with: raw.items)
            return raw
        }

        let cursor = missionDeltaCursor ?? ""
        let delta = try await call("\(baseQuery)&updated_since=\(Self.escape(cursor))")
        missionDeltaPolls += 1
        if !delta.items.isEmpty {
            var byId: [String: OrbJSON] = [:]
            for existing in missionDeltaCache {
                let id = existing["id"].text
                if !id.isEmpty { byId[id] = existing }
            }
            for updated in delta.items {
                let id = updated["id"].text
                if !id.isEmpty {
                    _ = OrbRow(updated)
                    byId[id] = updated
                }
            }
            let merged = byId.values.sorted { a, b in
                let ta = a["updated_at"].text.isEmpty ? a["created_at"].text : a["updated_at"].text
                let tb = b["updated_at"].text.isEmpty ? b["created_at"].text : b["updated_at"].text
                return ta > tb
            }
            missionDeltaCache = Array(merged.prefix(limit))
            advanceMissionDeltaCursor(with: delta.items)
        }
        return .array(missionDeltaCache)
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

    private func orderedCandidateEndpoints(for primary: String) -> [String] {
        let candidates = OrbConnection.candidateEndpoints(for: primary)
        guard candidates.count > 1 else { return candidates }
        let now = Date()
        var healthy: [String] = []
        var cooling: [String] = []
        for url in candidates {
            if let until = endpointCooldowns[url], until > now {
                cooling.append(url)
            } else {
                healthy.append(url)
            }
        }
        return healthy + cooling
    }

    private func sendAttempt(_ request: URLRequest, session: URLSession, currentEndpoint: String, failure: String) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OrbHTTPError.invalidResponse }
        if http.statusCode == 401 {
            let text = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if request.url?.path.hasSuffix("/api/auth/change-password") == true,
               text.localizedCaseInsensitiveContains("current password") {
                throw OrbHTTPError(status: 401, detail: text)
            }
            // A rejected login or an old in-flight request must not clear a newer session.
            let candidates = OrbConnection.candidateEndpoints(for: currentEndpoint)
            let matchesEndpoint = candidates.contains { request.url?.absoluteString.hasPrefix($0 + "/") == true }
            if let authorization = request.value(forHTTPHeaderField: "Authorization"),
               authorization == "Bearer \(authToken ?? "")",
               matchesEndpoint {
                markSessionExpired()
            }
            throw OrbHTTPError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw OrbHTTPError(status: http.statusCode, detail: text.isEmpty ? failure : text)
        }
        return (data, http)
    }

    /// The single transport: performs the request (with 1 fast retry and multi-path
    /// failover on idempotent GET/HEAD and `Idempotency-Key` writes), maps failures to
    /// `OrbHTTPError`, expires the session on a 401 for the current token, and records failures.
    private func send(_ request: URLRequest, session: URLSession, label: String, failure: String) async throws -> (Data, HTTPURLResponse) {
        let method = (request.httpMethod ?? "GET").uppercased()
        let currentEndpoint = endpoint
        var baseRequest = request
        if (baseRequest.value(forHTTPHeaderField: "Idempotency-Key") ?? "").isEmpty,
           !currentEndpoint.isEmpty,
           let abs = baseRequest.url?.absoluteString,
           abs.hasPrefix(currentEndpoint + "/") {
            let suffixPath = String(abs.dropFirst(currentEndpoint.count))
            if OrbConnection.shouldAttachIdempotencyKey(method: method, path: suffixPath) {
                baseRequest.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
            }
        }
        let hasIdempotencyKey = !(baseRequest.value(forHTTPHeaderField: "Idempotency-Key") ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        let idempotent = method == "GET" || method == "HEAD" || hasIdempotencyKey
        let suffix: String? = {
            guard idempotent, !currentEndpoint.isEmpty,
                  let abs = baseRequest.url?.absoluteString,
                  abs.hasPrefix(currentEndpoint + "/") else { return nil }
            return String(abs.dropFirst(currentEndpoint.count))
        }()
        let candidates = suffix != nil ? orderedCandidateEndpoints(for: currentEndpoint) : [currentEndpoint]

        do {
            var lastError: Error?
            for (idx, base) in candidates.enumerated() {
                let isLastCandidate = idx + 1 == candidates.count
                var candidateReq = baseRequest
                if let suffix, base != currentEndpoint, let rewritten = URL(string: base + suffix) {
                    candidateReq.url = rewritten
                }
                let maxAttempts = idempotent ? 2 : 1
                for attempt in 0..<maxAttempts {
                    try Task.checkCancellation()
                    do {
                        let out = try await sendAttempt(candidateReq, session: session, currentEndpoint: currentEndpoint, failure: failure)
                        endpointCooldowns.removeValue(forKey: base)
                        return out
                    } catch {
                        lastError = error
                        if error is CancellationError || !OrbConnection.isFastRetryableGetError(error) || !idempotent {
                            throw error
                        }
                        if attempt + 1 < maxAttempts {
                            try await Task.sleep(nanoseconds: 250_000_000)
                            continue
                        }
                        if !isLastCandidate {
                            endpointCooldowns[base] = Date().addingTimeInterval(20)
                        }
                    }
                }
            }
            throw lastError ?? OrbHTTPError.invalidResponse
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
