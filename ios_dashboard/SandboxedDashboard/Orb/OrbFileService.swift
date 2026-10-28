import Foundation
import CryptoKit

/// Why a shared file could not be opened, in words the person can act on.
enum OrbFileError: LocalizedError, Equatable {
    case notFound(String)
    case machineOffline
    case offline
    case unauthorized
    case failed(String)

    var rank: Int {
        switch self {
        case .notFound: 0
        case .failed: 1
        case .machineOffline: 2
        case .unauthorized: 3
        case .offline: 4
        }
    }

    var errorDescription: String? {
        switch self {
        case .notFound(let name): "\(name) is no longer in the mission workspace."
        case .machineOffline: "The machine running this mission is offline or unreachable. Try again when it is back."
        case .offline: "You’re offline. Connect to the internet and try again."
        case .unauthorized: "Your session expired. Sign in again to open this file."
        case .failed(let detail): detail
        }
    }

    /// Core's file routes answer with plain-text errors; map them to a cause.
    static func from(status: Int, body: String, name: String) -> OrbFileError {
        let text = body.lowercased()
        if status == 401 { return .unauthorized }
        if text.contains("unreachable") || text.contains("destination unavailable") || text.contains("remote file source is unavailable")
            || text.contains("remote job is unavailable") || text.contains("update the node") || status == 502 || status == 503 || status == 504 {
            return .machineOffline
        }
        if status == 404 || text.contains("not found") || text.contains("no such file") || text.contains("file is unavailable") || text.contains("outside") {
            return .notFound(name)
        }
        return .failed(body.isEmpty ? "Couldn’t open \(name) (HTTP \(status))." : "Couldn’t open \(name): \(body.prefix(200))")
    }

    static func from(_ error: Error, name: String) -> OrbFileError {
        if let e = error as? OrbFileError { return e }
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff: return .offline
            case .timedOut, .cannotConnectToHost, .cannotFindHost: return .failed("Orb couldn’t reach the server. Try again.")
            default: break
            }
        }
        return .failed(error.localizedDescription)
    }
}

/// One workspace directory entry from `POST /api/file-resources` (`list`).
struct OrbWorkspaceEntry: Identifiable, Hashable, Sendable {
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int64?
    var id: String { path }
}

/// Fetches shared and workspace files for previews and the share sheet.
///
/// Order, matching desktop Orb (`fileResources.ts`):
/// 1. the `shared_files` url Core published (`/api/fs/download`, streamed with progress);
/// 2. the mission's workspace through `POST /api/file-resources` (`resolve`, then
///    1 MiB `download` chunks). Core proxies this to remote nodes, managed machines
///    and transferred workspaces, so it is the only path that reaches them;
/// 3. `/api/fs/download?path=…&mission_id=…` for Core paths outside the workspace
///    (context uploads under /root/context).
@MainActor
final class OrbFileService {
    static let shared = OrbFileService()

    struct Scope: Hashable, Sendable {
        var missionID: String?
        var workspaceID: String?
        /// Another session of the replacement chain (`earlier:<id>`); nil is the mission's own workspace.
        var source: String? = nil
    }

    /// An earlier or later attempt of this mission on the same machine, browsable read-only.
    struct Session: Identifiable, Hashable, Sendable {
        let id: String
        let label: String
        let later: Bool
    }

    private struct Chunk: Decodable { let bytes: [UInt8]?; let next: Int64?; let size: Int64? }
    private struct Match: Decodable { let path: String; let size: Int64? }
    private struct Resolved: Decodable { struct Row: Decodable { let matches: [Match]? }; let results: [Row]? }
    private struct Listing: Decodable {
        struct Entry: Decodable { let name: String; let path: String; let kind: String?; let size: Int64? }
        let entries: [Entry]?
    }
    private struct Roots: Decodable { struct Source: Decodable { let id: String; let label: String?; let group: String?; let available: Bool? }; let sources: [Source]? }

    private var core: OrbCore { .shared }
    private var inflight: [String: Task<URL, Error>] = [:]

    static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("orb-files", isDirectory: true)
    }

    private func cacheKey(_ ref: OrbFileRef, _ scope: Scope) -> String {
        let raw = [core.endpoint, core.authToken ?? "", scope.workspaceID ?? "", scope.missionID ?? "", scope.source ?? "", ref.url ?? "", ref.path, ref.size.map(String.init) ?? ""].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(raw.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func destination(_ ref: OrbFileRef, _ scope: Scope) -> URL {
        let name = ref.name
        let safe = ["", ".", ".."].contains(name) ? "file" : name.replacingOccurrences(of: "/", with: "_")
        return Self.cacheRoot.appendingPathComponent(cacheKey(ref, scope), isDirectory: true).appendingPathComponent(safe)
    }

    /// A previously downloaded copy, if any.
    func cached(_ ref: OrbFileRef, scope: Scope) -> URL? {
        let url = destination(ref, scope)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Downloads `ref` to the cache. `progress` gets 0…1, or nil while the size is unknown.
    func fetch(_ ref: OrbFileRef, scope: Scope, progress: @escaping @MainActor (Double?) -> Void = { _ in }) async throws -> URL {
        if let url = cached(ref, scope: scope) { progress(1); return url }
        let key = cacheKey(ref, scope)
        if let task = inflight[key] {
            let url = try await task.value
            guard key == cacheKey(ref, scope) else { throw OrbFileError.unauthorized }
            return url
        }
        let task = Task { @MainActor in try await self.download(ref, scope: scope, progress: progress) }
        inflight[key] = task
        defer { inflight[key] = nil }
        let url = try await task.value
        guard key == cacheKey(ref, scope) else {
            try? FileManager.default.removeItem(at: url)
            throw OrbFileError.unauthorized
        }
        return url
    }

    private func download(_ ref: OrbFileRef, scope: Scope, progress: @escaping @MainActor (Double?) -> Void) async throws -> URL {
        let target = destination(ref, scope)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = target.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partial)
        var failure: OrbFileError = .notFound(ref.label)
        func remember(_ error: Error) {
            // The most actionable cause wins (offline > session > machine down > other > not found).
            let e = OrbFileError.from(error, name: ref.label)
            if e.rank > failure.rank { failure = e }
        }
        // 1. Published download url.
        if let raw = ref.url, let url = sameOriginURL(raw) {
            do { try await stream(url, to: partial, name: ref.label, progress: progress); return try finish(partial, target) }
            catch { remember(error); if failure.rank >= OrbFileError.unauthorized.rank { throw failure } }
        }
        // 2. The mission workspace, wherever it runs.
        if let mission = scope.missionID {
            do {
                try await workspaceDownload(ref, mission: mission, sources: downloadSources(ref, scope), to: partial, progress: progress)
                return try finish(partial, target)
            } catch { remember(error); if failure.rank >= OrbFileError.machineOffline.rank { throw failure } }
        }
        // 3. Core paths outside the workspace (context uploads).
        var queries: [[URLQueryItem]] = []
        if let mission = scope.missionID {
            var items = [URLQueryItem(name: "path", value: ref.path)]
            if let ws = scope.workspaceID, !ws.isEmpty { items.append(.init(name: "workspace_id", value: ws)) }
            items.append(.init(name: "mission_id", value: mission))
            queries.append(items)
        }
        if ref.path.hasPrefix("/") { queries.append([URLQueryItem(name: "path", value: ref.path)]) }
        for query in queries {
            var components = URLComponents(string: core.endpoint + "/api/fs/download")
            components?.queryItems = query
            guard let url = components?.url else { continue }
            do { try await stream(url, to: partial, name: ref.label, progress: progress); return try finish(partial, target) }
            catch { remember(error); if failure.rank >= OrbFileError.unauthorized.rank { throw failure } }
        }
        throw failure
    }

    private func finish(_ partial: URL, _ target: URL) throws -> URL {
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: partial, to: target)
        return target
    }

    private func sameOriginURL(_ raw: String) -> URL? {
        guard let base = URL(string: core.endpoint), let url = URL(string: raw, relativeTo: base)?.absoluteURL,
              url.scheme == base.scheme, url.host == base.host, url.port == base.port else { return nil }
        return url
    }

    private func request(_ url: URL, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 30) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(core.authToken ?? "")", forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    /// Streams a GET to disk with byte progress (large files never sit in memory).
    private func stream(_ url: URL, to file: URL, name: String, progress: @escaping @MainActor (Double?) -> Void) async throws {
        let delegate = OrbDownloadProgress { value in Task { @MainActor in progress(value) } }
        let (temp, response) = try await URLSession.shared.download(for: request(url, timeout: 60), delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw OrbFileError.failed("Invalid response for \(name).") }
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? String(contentsOf: temp, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: temp)
            throw OrbFileError.from(status: http.statusCode, body: String(body.prefix(400)), name: name)
        }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temp, to: file)
        progress(1)
    }

    private func fileResources(_ body: [String: Any], name: String) async throws -> Data {
        guard let url = URL(string: core.endpoint + "/api/file-resources") else { throw OrbFileError.failed("Invalid server URL.") }
        let data = try JSONSerialization.data(withJSONObject: body)
        let (reply, response) = try await URLSession.shared.data(for: request(url, method: "POST", body: data, timeout: 45))
        guard let http = response as? HTTPURLResponse else { throw OrbFileError.failed("Invalid response for \(name).") }
        guard (200..<300).contains(http.statusCode) else {
            throw OrbFileError.from(status: http.statusCode, body: String(data: reply.prefix(400), encoding: .utf8) ?? "", name: name)
        }
        return reply
    }

    /// The workspace first; an absolute path agents cite from an earlier
    /// session of the chain resolves in that session (Core checks the chain).
    private func downloadSources(_ ref: OrbFileRef, _ scope: Scope) async -> [String] {
        if let source = scope.source { return [source] }
        guard ref.path.hasPrefix("/") else { return ["workspace"] }
        return ["workspace"] + ((try? await roots(scope).sessions) ?? []).map(\.id)
    }

    private func workspaceDownload(_ ref: OrbFileRef, mission: String, sources: [String], to file: URL, progress: @escaping @MainActor (Double?) -> Void) async throws {
        var found: (String, Match)?
        for source in sources where found == nil {
            let resolvedData = try await fileResources(["mission_id": mission, "source": source, "action": "resolve", "paths": [ref.path]], name: ref.label)
            let resolved = try JSONDecoder().decode(Resolved.self, from: resolvedData)
            found = resolved.results?.first?.matches?.first.map { (source, $0) }
        }
        guard let (source, match) = found else { throw OrbFileError.notFound(ref.label) }
        let base: [String: Any] = ["mission_id": mission, "source": source]
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var offset: Int64 = 0
        var total = match.size ?? ref.size
        progress(total.map { $0 > 0 ? 0 : 1 })
        while true {
            try Task.checkCancellation()
            let data = try await fileResources(base.merging(["action": "download", "path": match.path, "offset": offset]) { $1 }, name: ref.label)
            let chunk = try await Task.detached(priority: .userInitiated) { try JSONDecoder().decode(Chunk.self, from: data) }.value
            let bytes = chunk.bytes ?? []
            if !bytes.isEmpty { try handle.write(contentsOf: Data(bytes)) }
            total = chunk.size ?? total
            offset = chunk.next ?? (offset + Int64(bytes.count))
            if let total, total > 0 { progress(min(1, Double(offset) / Double(total))) }
            if bytes.isEmpty || (total.map { offset >= $0 } ?? true) { break }
        }
        progress(1)
    }

    /// Whether the mission has a workspace, and the other sessions of its chain on the same machine.
    func roots(_ scope: Scope) async throws -> (workspace: Bool, sessions: [Session]) {
        guard let mission = scope.missionID else { return (false, []) }
        let data = try await fileResources(["mission_id": mission, "action": "roots"], name: "workspace")
        let sources = try JSONDecoder().decode(Roots.self, from: data).sources ?? []
        return (
            sources.contains { $0.id == "workspace" && $0.available != false },
            sources.filter { $0.group != nil && $0.available != false }
                .map { Session(id: $0.id, label: $0.label ?? $0.id, later: $0.group == "later") }
        )
    }

    /// Read-only listing of one workspace directory ("" is the root).
    func list(_ scope: Scope, path: String) async throws -> [OrbWorkspaceEntry] {
        guard let mission = scope.missionID else { return [] }
        do {
            let data = try await fileResources(["mission_id": mission, "source": scope.source ?? "workspace", "action": "list", "path": path], name: path.isEmpty ? "Workspace" : path)
            let listing = try JSONDecoder().decode(Listing.self, from: data)
            return (listing.entries ?? []).map { OrbWorkspaceEntry(name: $0.name, path: $0.path, isDirectory: $0.kind == "dir", size: $0.size) }
        } catch { throw OrbFileError.from(error, name: path.isEmpty ? "Workspace" : path) }
    }

    /// Every assistant message of the mission, for the Files tab.
    func sharedFiles(_ scope: Scope) async throws -> [OrbFileRef] {
        guard let mission = scope.missionID else { return [] }
        do {
            let json = try await core.call("/api/control/missions/\(OrbCore.escape(mission))/events?types=assistant_message&limit=4000&include_counts=false")
            return OrbFileRefs.collect(OrbFileRefs.messages(json))
        } catch { throw OrbFileError.from(error, name: "Files") }
    }
}

/// Reports `URLSession` download progress (nil until the size is known).
final class OrbDownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double?) -> Void
    private var observation: NSKeyValueObservation?
    init(_ report: @escaping @Sendable (Double?) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted, options: [.new]) { [report] progress, _ in
            report(progress.totalUnitCount > 0 ? progress.fractionCompleted : nil)
        }
    }
}
