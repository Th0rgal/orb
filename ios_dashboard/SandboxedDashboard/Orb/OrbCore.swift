import Foundation
import Security
import CryptoKit

/// Lossless wire values for provider-specific capabilities and model parameters.
indirect enum OrbJSON: Codable, Sendable, Equatable {
    case object([String: OrbJSON]), array([OrbJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([OrbJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: OrbJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
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
    subscript(_ key: String) -> OrbJSON { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var text: String { if case .string(let v) = self { return v }; return "" }
    var items: [OrbJSON] { if case .array(let v) = self { return v }; return [] }
    var flag: Bool { if case .bool(let v) = self { return v }; return false }
    var doubleValue: Double? { if case .number(let v) = self { return v }; return nil }
}

/// Remote placement can be reported by either the mission or its current job.
enum OrbContinuation {
    static func remoteNodeID(for mission: OrbJSON, fallback: String = "") -> String {
        let candidates = [
            mission["remote_job"]["node_id"].text,
            mission["remote_node_id"].text,
            mission["execution"]["scope_unit"].text.hasPrefix("remote-node:")
                ? String(mission["execution"]["scope_unit"].text.dropFirst("remote-node:".count).split(separator: ":").first ?? "")
                : "",
            fallback
        ]
        for raw in candidates {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "core"
    }

    static func identity(for mission: OrbJSON) -> OrbJSON? {
        guard !mission["track"].text.isEmpty,
              mission["remote_node_id"].text.isEmpty,
              mission["remote_job"] == .null,
              !mission["execution"]["scope_unit"].text.hasPrefix("remote-node:") else { return nil }
        return .object(["project": mission["project"], "track": mission["track"], "github_pr": mission["github_pr"]])
    }
}

struct OrbPlacementCommitItem: Equatable, Sendable {
    let missionID: String
    let project: String?
    let folder: String
    let placementRevision: UInt64
    var isPreview: Bool = false
}

struct OrbApprovalTransferConfirmationError: LocalizedError, Equatable, Sendable {
    struct ActiveGrant: Equatable, Sendable {
        let id: String
        let secretName: String
        let sourceProject: String?
    }
    struct PendingRequest: Equatable, Sendable {
        let id: String
        let secretName: String
        let operation: String
    }
    let message: String
    let targetProject: String
    let activeGrants: [ActiveGrant]
    let pendingRequests: [PendingRequest]

    var errorDescription: String? { message }

    var summaryText: String {
        var names = Set<String>()
        for g in activeGrants where !g.secretName.isEmpty { names.insert(g.secretName) }
        for p in pendingRequests where !p.secretName.isEmpty { names.insert(p.secretName) }
        let sorted = names.sorted()
        var parts: [String] = []
        if !activeGrants.isEmpty {
            parts.append("\(activeGrants.count) active Touch-ID grant\(activeGrants.count == 1 ? "" : "s")")
        }
        if !pendingRequests.isEmpty {
            parts.append("\(pendingRequests.count) pending secret request\(pendingRequests.count == 1 ? "" : "s")")
        }
        let detail = parts.isEmpty ? message : "This conversation tree holds \(parts.joined(separator: " and "))"
        let suffix = sorted.isEmpty ? "" : " (\(sorted.joined(separator: ", ")))"
        let dest = targetProject.isEmpty ? "the destination project" : targetProject
        return "\(detail)\(suffix). Choose whether to revoke them before moving to \(dest) or keep them bound to \(dest)."
    }

    static func parse(from error: Error) -> Self? {
        guard let http = error as? OrbHTTPError, http.status == 409,
              let data = http.detail.data(using: .utf8),
              let json = try? JSONDecoder().decode(OrbJSON.self, from: data),
              json["code"].text == "approval_transfer_confirmation_required" else {
            return nil
        }
        let grantsRaw = json["active_grants"].items.isEmpty ? json["grants"].items : json["active_grants"].items
        let grants = grantsRaw.map { g in
            ActiveGrant(
                id: g["id"].text,
                secretName: g["secret_name"].text,
                sourceProject: g["source_project"] == .null ? nil : g["source_project"].text
            )
        }
        let pending = json["pending_requests"].items.map { p in
            PendingRequest(
                id: p["id"].text,
                secretName: p["secret_name"].text,
                operation: p["operation"].text
            )
        }
        let msg = json["error"].text.isEmpty ? "Moving across projects affects active secret approvals." : json["error"].text
        return Self(
            message: msg,
            targetProject: json["target_project"].text,
            activeGrants: grants,
            pendingRequests: pending
        )
    }
}

struct OrbRow: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let state: String
    let project: String
    let folder: String
    let placementRevision: UInt64
    let backend: String
    let cloud: Bool
    let updatedAt: String
    let raw: OrbJSON
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.project == rhs.project && lhs.folder == rhs.folder &&
        lhs.placementRevision == rhs.placementRevision && lhs.raw == rhs.raw
    }
    func hash(into h: inout Hasher) { h.combine(id) }
    static func normalizeFolder(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }
    init(_ value: OrbJSON, project isProject: Bool = false) {
        id = value[isProject ? "slug" : "id"].text
        // Forks share the conversation's name; older forks were titled "… · fork".
        let title = value["title"].text
        let placeholder = value["orb_placeholder"].flag
        name = title.isEmpty ? (placeholder ? "Parent mission" : id) : (title.hasSuffix(" · fork") ? String(title.dropLast(7)) : title)
        state = value["status"].text
        backend = value["backend"].text
        cloud = value["backend"].text.hasPrefix("cloud_") || value["execution_kind"].text == "cloud" || value["tags"].items.contains(where: { $0.text.hasPrefix("cloud:") }) || value["cloud"] != .null
        updatedAt = value["updated_at"].text.isEmpty ? value["created_at"].text : value["updated_at"].text
        let rawRev = value["placement_revision"].doubleValue.map { UInt64(max(0, $0)) } ?? 0
        let rawFolder = Self.normalizeFolder(value["folder"].text)
        let rawProj = value["project"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isProject && !placeholder && !id.isEmpty {
            let resolved = OrbHierarchy.observeAndResolvePlacement(
                id: id,
                value: value,
                rawProject: rawProj,
                rawFolder: rawFolder,
                rawRev: rawRev,
                rawTitle: title,
                rawStatus: state,
                rawBackend: backend
            )
            project = resolved.project
            folder = resolved.folder
            placementRevision = resolved.revision
            if case var .object(dict) = value {
                dict["project"] = resolved.project.isEmpty ? .null : .string(resolved.project)
                dict["folder"] = .string(resolved.folder)
                dict["placement_revision"] = .number(Double(resolved.revision))
                if resolved.projected {
                    dict["orb_projected_move"] = .bool(true)
                } else {
                    dict.removeValue(forKey: "orb_projected_move")
                }
                raw = .object(dict)
            } else {
                raw = value
            }
        } else {
            project = rawProj
            folder = rawFolder
            placementRevision = rawRev
            raw = value
        }
    }
    func withPatchedPlacement(project nextProject: String, folder nextFolder: String, revision nextRevision: UInt64, isPreview: Bool = false) -> Self {
        var nextRaw = raw
        if case var .object(dict) = nextRaw {
            dict["project"] = nextProject.isEmpty ? .null : .string(nextProject)
            dict["folder"] = .string(nextFolder)
            dict["placement_revision"] = .number(Double(nextRevision))
            if isPreview {
                dict["orb_projected_move"] = .bool(true)
            } else {
                dict.removeValue(forKey: "orb_projected_move")
            }
            nextRaw = .object(dict)
        }
        return Self(
            id: id,
            name: name,
            state: state,
            project: nextProject,
            folder: nextFolder,
            placementRevision: nextRevision,
            backend: backend,
            cloud: cloud,
            updatedAt: updatedAt,
            raw: nextRaw
        )
    }
    fileprivate init(
        id: String,
        name: String,
        state: String,
        project: String,
        folder: String,
        placementRevision: UInt64,
        backend: String,
        cloud: Bool,
        updatedAt: String,
        raw: OrbJSON
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.project = project
        self.folder = folder
        self.placementRevision = placementRevision
        self.backend = backend
        self.cloud = cloud
        self.updatedAt = updatedAt
        self.raw = raw
    }
    var isPlaceholder: Bool { raw["orb_placeholder"].flag }
    var isParticipant: Bool { raw["viewer_role"].text == "participant" }
    var ownerUsername: String? {
        let u = raw["owner_username"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        return u.isEmpty ? nil : u
    }
    /// The conversation this one was forked from (a `fork-of:` tag, or an older fork stored as a child).
    var forkSource: String? {
        if let tag = raw["tags"].items.map(\.text).first(where: { $0.hasPrefix("fork-of:") }) { return String(tag.dropFirst(8)) }
        let p = raw["parent_mission_id"].text
        return !p.isEmpty && raw["title"].text.hasSuffix(" · fork") ? p : nil
    }
    /// The mission that launched this one. A fork is another version, never launched work.
    /// Sticky (docs/specs/sidebar-hierarchy.md): a payload without the link never
    /// moves a known child to the root; only `OrbHierarchy.reparent` changes it.
    var parentMissionID: String? {
        if let found = payloadParentID { OrbHierarchy.remember(id, parent: found); return found }
        return OrbHierarchy.parent(of: id)
    }
    fileprivate var payloadParentID: String? {
        Self.extractPayloadParentID(from: raw)
    }
    static func extractPayloadParentID(from value: OrbJSON) -> String? {
        let forkSrc: String? = {
            if let tag = value["tags"].items.map(\.text).first(where: { $0.hasPrefix("fork-of:") }) { return String(tag.dropFirst(8)) }
            let p = value["parent_mission_id"].text
            return !p.isEmpty && value["title"].text.hasSuffix(" · fork") ? p : nil
        }()
        let p = value["parent_mission_id"].text
        if !p.isEmpty && forkSrc != p { return p }
        let cp = value["callback_parent_mission_id"].text
        if !cp.isEmpty { return cp }
        for tag in value["tags"].items.map(\.text) {
            let lower = tag.lowercased()
            for prefix in ["parent:", "parent_mission:", "parent-mission:", "spawned_by:", "spawned-by:"] {
                if lower.hasPrefix(prefix) {
                    let v = String(tag.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !v.isEmpty { return v }
                }
            }
        }
        return nil
    }
    fileprivate var hasDirectBtwTag: Bool {
        Self.hasDirectBtwTag(in: raw)
    }
    static func hasDirectBtwTag(in value: OrbJSON) -> Bool {
        value["tags"].items.map(\.text).contains { $0.hasPrefix("btw-parent:") || $0 == "btw-subagent" }
    }
    static func isClientPlacement(_ value: OrbJSON) -> Bool {
        let pk = value["placement_kind"].text
        return pk == "client" || pk.hasPrefix("client:")
    }
    static func hasTypedSuperseded(_ value: OrbJSON) -> Bool {
        let st = value["status"].text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if st == "superseded" { return true }
        let next = value["superseded_by_mission_id"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !next.isEmpty
    }
    var isClientPlacement: Bool { Self.isClientPlacement(raw) }
    var hasTypedSuperseded: Bool { Self.hasTypedSuperseded(raw) }
    var mobile: Bool { !OrbHierarchy.isBtw(self) }
    var active: Bool { missionState?.isActive ?? false }
}

/// Parent links, `/btw` subtree markers, and monotone `(project, folder, placement_revision)`
/// state (`orb_placement_merge_step`) remembered across payloads, so a partial or delayed
/// pre-move poll cannot un-nest a child, surface a `/btw` worker, or snap a moved mission back.
enum OrbHierarchy {
    struct Seen: Equatable, Sendable {
        var title: String?
        var project: String?
        var folder: String?
        var status: String?
        var backend: String?
    }
    struct PlacementState: Equatable, Sendable {
        var project: String
        var folder: String
        var revision: UInt64
        var pendingOpID: UInt32
        var rollbackProject: String?
        var rollbackFolder: String?
        var rollbackRevision: UInt64?
    }
    private struct CachedAncestor {
        var row: OrbRow
        let fetchedAt: Date
    }
    static let ancestorTTLSeconds: TimeInterval = 60
    static let localClientID: String = UUID().uuidString

    private static let lock = NSLock()
    nonisolated(unsafe) private static var parents: [String: String] = [:]
    nonisolated(unsafe) private static var btwIDs: Set<String> = []
    nonisolated(unsafe) private static var seenFacts: [String: Seen] = [:]
    nonisolated(unsafe) private static var placements: [String: PlacementState] = [:]
    nonisolated(unsafe) private static var stagedRows: [String: OrbRow] = [:]
    nonisolated(unsafe) private static var nextOpID: UInt32 = 0
    nonisolated(unsafe) private static var ancestors: [String: CachedAncestor] = [:]
    nonisolated(unsafe) private static var goneIDs: Set<String> = []

    static func resolveLocalAckOpID(clientOpID: UInt32, clientID: String?) -> UInt32 {
        guard clientOpID != 0, let clientID, clientID == localClientID else { return 0 }
        return clientOpID
    }

    static func retainStagedRows(_ rows: [OrbRow]) {
        guard !rows.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if stagedRows.count > 256 { stagedRows.removeAll(keepingCapacity: true) }
        for row in rows where !row.id.isEmpty {
            stagedRows[row.id] = row
        }
    }

    static func stagedRow(for id: String) -> OrbRow? {
        guard !id.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        return stagedRows[id]
    }

    static func pendingPreviewRows(forProject slug: String) -> [OrbRow] {
        let target = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return [] }
        lock.lock()
        var matches: [OrbRow] = []
        for (mid, st) in placements where st.pendingOpID != 0 {
            guard st.project.caseInsensitiveCompare(target) == .orderedSame,
                  let base = stagedRows[mid] else { continue }
            let isNested = hasNestedParentLocked(id: mid, payloadParent: nil, directBtw: false)
            matches.append(base.withPatchedPlacement(
                project: st.project,
                folder: isNested ? "" : st.folder,
                revision: st.revision,
                isPreview: true
            ))
        }
        lock.unlock()
        return matches
    }

    static func allocateOpID() -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        nextOpID = nextOpID >= 0xFFFF_FFFE ? 1 : nextOpID + 1
        return nextOpID
    }

    private static func hasNestedParentLocked(id: String, payloadParent: String?, directBtw: Bool) -> Bool {
        if payloadParent != nil || parents[id] != nil { return true }
        if directBtw || btwIDs.contains(id) { return true }
        return false
    }

    static func observeAndResolvePlacement(
        id: String,
        value: OrbJSON,
        rawProject: String,
        rawFolder: String,
        rawRev: UInt64,
        rawTitle: String,
        rawStatus: String,
        rawBackend: String
    ) -> (project: String, folder: String, revision: UInt64, projected: Bool) {
        let payloadParent = OrbRow.extractPayloadParentID(from: value)
        let directBtw = OrbRow.hasDirectBtwTag(in: value)
        let isProjectedPreview = value["orb_projected_move"].flag
        let hasProjectField: Bool = {
            if case .object(let d) = value { return d["project"] != nil }
            return false
        }()
        let hasFolderField: Bool = {
            if case .object(let d) = value { return d["folder"] != nil }
            return false
        }()
        let hasRevField: Bool = {
            if case .object(let d) = value { return d["placement_revision"] != nil }
            return false
        }()
        let hasPlacement = !isProjectedPreview && (hasProjectField || hasFolderField || hasRevField)

        lock.lock()
        defer { lock.unlock() }
        goneIDs.remove(id)
        if let payloadParent { parents[id] = payloadParent }
        if directBtw { btwIDs.insert(id) }
        let isNested = hasNestedParentLocked(id: id, payloadParent: payloadParent, directBtw: directBtw)
        let incFolder = isNested ? "" : rawFolder

        var resolvedProject = rawProject
        var resolvedFolder = incFolder
        var resolvedRev = rawRev
        var isProjected = isProjectedPreview

        if let cur = placements[id] {
            if !hasPlacement {
                resolvedProject = cur.project
                resolvedFolder = isNested ? "" : cur.folder
                resolvedRev = cur.revision
                isProjected = cur.pendingOpID != 0
            } else {
                let effProj = hasProjectField ? rawProject : cur.project
                let effFolder = isNested ? "" : (hasFolderField ? rawFolder : cur.folder)
                let verdict = OrbKernel.placementMergeStep(
                    curRev: cur.revision,
                    incRev: rawRev,
                    pendingOpId: cur.pendingOpID,
                    ackOpId: 0,
                    sourceKind: 0,
                    hasPlacement: true
                )
                if verdict.admitted {
                    let nextRev = max(cur.revision, rawRev, UInt64(verdict.nextRev32))
                    if !verdict.clearPending && cur.pendingOpID != 0 {
                        let rbProj = hasProjectField ? rawProject : (cur.rollbackProject ?? cur.project)
                        let rbFolder = isNested ? "" : (hasFolderField ? rawFolder : (cur.rollbackFolder ?? cur.folder))
                        let nextState = PlacementState(
                            project: cur.project,
                            folder: isNested ? "" : cur.folder,
                            revision: nextRev,
                            pendingOpID: cur.pendingOpID,
                            rollbackProject: rbProj,
                            rollbackFolder: rbFolder,
                            rollbackRevision: nextRev
                        )
                        placements[id] = nextState
                        resolvedProject = nextState.project
                        resolvedFolder = nextState.folder
                        resolvedRev = nextState.revision
                        isProjected = true
                    } else {
                        let nextState = PlacementState(
                            project: effProj,
                            folder: effFolder,
                            revision: nextRev,
                            pendingOpID: verdict.clearPending ? 0 : cur.pendingOpID,
                            rollbackProject: verdict.clearPending ? nil : cur.rollbackProject,
                            rollbackFolder: verdict.clearPending ? nil : cur.rollbackFolder,
                            rollbackRevision: verdict.clearPending ? nil : cur.rollbackRevision
                        )
                        placements[id] = nextState
                        resolvedProject = nextState.project
                        resolvedFolder = nextState.folder
                        resolvedRev = nextState.revision
                        isProjected = nextState.pendingOpID != 0
                    }
                } else {
                    resolvedProject = cur.project
                    resolvedFolder = isNested ? "" : cur.folder
                    resolvedRev = cur.revision
                    isProjected = cur.pendingOpID != 0
                }
            }
        } else if hasPlacement {
            let initState = PlacementState(
                project: rawProject,
                folder: incFolder,
                revision: rawRev,
                pendingOpID: 0
            )
            placements[id] = initState
            isProjected = false
        }

        var seen = seenFacts[id] ?? Seen()
        if !rawTitle.isEmpty { seen.title = rawTitle }
        if !isProjectedPreview && (!resolvedProject.isEmpty || hasProjectField) { seen.project = resolvedProject }
        if !isProjectedPreview { seen.folder = resolvedFolder }
        if !rawStatus.isEmpty && rawStatus != "unknown" { seen.status = rawStatus }
        if !rawBackend.isEmpty { seen.backend = rawBackend }
        seenFacts[id] = seen

        return (resolvedProject, resolvedFolder, resolvedRev, isProjected)
    }

    static func observe(_ row: OrbRow) {
        guard !row.id.isEmpty, !row.isPlaceholder else { return }
        // Re-observing an already-constructed `OrbRow` records sticky hierarchy links and
        // display facts without re-running `placementMergeStep` on reconciled row fields.
        let payloadParent = OrbRow.extractPayloadParentID(from: row.raw)
        let directBtw = OrbRow.hasDirectBtwTag(in: row.raw)
        let isProjectedPreview = row.raw["orb_projected_move"].flag
        let rawTitle = row.raw["title"].text
        lock.lock()
        defer { lock.unlock() }
        goneIDs.remove(row.id)
        if let payloadParent { parents[row.id] = payloadParent }
        if directBtw { btwIDs.insert(row.id) }
        if isNestedParent(id: row.id), var cur = placements[row.id], !cur.folder.isEmpty {
            cur.folder = ""
            placements[row.id] = cur
        }
        var seen = seenFacts[row.id] ?? Seen()
        if !rawTitle.isEmpty { seen.title = rawTitle }
        if !isProjectedPreview {
            if !row.project.isEmpty { seen.project = row.project }
            seen.folder = isNestedParent(id: row.id) ? "" : row.folder
        }
        if !row.state.isEmpty && row.state != "unknown" { seen.status = row.state }
        if !row.backend.isEmpty { seen.backend = row.backend }
        seenFacts[row.id] = seen
    }

    private static func isNestedParent(id: String) -> Bool {
        hasNestedParentLocked(id: id, payloadParent: nil, directBtw: false)
    }

    static func stageOptimisticPlacement(
        id: String,
        toProject: String,
        toFolder: String,
        opID: UInt32,
        fallbackProject: String = "",
        fallbackFolder: String = "",
        fallbackRevision: UInt64 = 0
    ) {
        guard !id.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let cur = placements[id] ?? PlacementState(
            project: fallbackProject,
            folder: OrbRow.normalizeFolder(fallbackFolder),
            revision: fallbackRevision,
            pendingOpID: 0
        )
        let isNested = hasNestedParentLocked(id: id, payloadParent: nil, directBtw: false)
        let normFolder = isNested ? "" : OrbRow.normalizeFolder(toFolder)
        let normProject = toProject.trimmingCharacters(in: .whitespacesAndNewlines)
        let verdict = OrbKernel.placementMergeStep(
            curRev: cur.revision,
            incRev: cur.revision,
            pendingOpId: cur.pendingOpID,
            ackOpId: opID,
            sourceKind: 2,
            hasPlacement: true
        )
        guard verdict.admitted else { return }
        placements[id] = PlacementState(
            project: normProject,
            folder: normFolder,
            revision: cur.revision,
            pendingOpID: opID,
            rollbackProject: cur.rollbackProject ?? cur.project,
            rollbackFolder: cur.rollbackFolder ?? cur.folder,
            rollbackRevision: cur.rollbackRevision ?? cur.revision
        )
        if var seen = seenFacts[id] {
            seen.project = normProject
            seen.folder = normFolder
            seenFacts[id] = seen
        }
    }

    @discardableResult
    static func stageOptimisticPlacement(
        rootIDs: [String],
        descendantIDs: [String] = [],
        project: String,
        folder: String,
        opID: UInt32
    ) -> [String] {
        var staged: [String] = []
        for rid in rootIDs where !rid.isEmpty {
            stageOptimisticPlacement(id: rid, toProject: project, toFolder: folder, opID: opID)
            if placement(of: rid)?.pendingOpID == opID { staged.append(rid) }
        }
        for did in descendantIDs where !did.isEmpty {
            stageOptimisticPlacement(id: did, toProject: project, toFolder: "", opID: opID)
            if placement(of: did)?.pendingOpID == opID { staged.append(did) }
        }
        return staged
    }

    @discardableResult
    static func rollbackOptimisticPlacement(id: String, ackOpID: UInt32) -> Bool {
        guard !id.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard let cur = placements[id] else { return false }
        let verdict = OrbKernel.placementMergeStep(
            curRev: cur.revision,
            incRev: cur.revision,
            pendingOpId: cur.pendingOpID,
            ackOpId: ackOpID,
            sourceKind: 3,
            hasPlacement: false
        )
        guard verdict.admitted else { return false }
        let prevProj = cur.rollbackProject ?? cur.project
        let prevFolder = cur.rollbackFolder ?? cur.folder
        let prevRev = cur.rollbackRevision ?? cur.revision
        placements[id] = PlacementState(
            project: prevProj,
            folder: prevFolder,
            revision: prevRev,
            pendingOpID: 0
        )
        if var seen = seenFacts[id] {
            seen.project = prevProj
            seen.folder = prevFolder
            seenFacts[id] = seen
        }
        return true
    }

    @discardableResult
    static func rollbackOptimisticPlacement(missionIDs: [String], opID: UInt32) -> [String] {
        missionIDs.filter { rollbackOptimisticPlacement(id: $0, ackOpID: opID) }
    }

    @discardableResult
    static func commitAuthoritativePlacements(_ items: [OrbPlacementCommitItem], ackOpID: UInt32 = 0) -> [OrbPlacementCommitItem] {
        var accepted: [OrbPlacementCommitItem] = []
        lock.lock()
        defer { lock.unlock() }
        for item in items where !item.missionID.isEmpty {
            let cur = placements[item.missionID]
            let isNested = hasNestedParentLocked(id: item.missionID, payloadParent: nil, directBtw: false)
            let normFolder = isNested ? "" : OrbRow.normalizeFolder(item.folder)
            let normProj = (item.project ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let verdict = OrbKernel.placementMergeStep(
                curRev: cur?.revision ?? 0,
                incRev: item.placementRevision,
                pendingOpId: cur?.pendingOpID ?? 0,
                ackOpId: ackOpID,
                sourceKind: 1,
                hasPlacement: true
            )
            if !verdict.admitted {
                if ackOpID != 0, let cur, cur.pendingOpID == ackOpID, item.placementRevision < cur.revision {
                    let rbVerdict = OrbKernel.placementMergeStep(
                        curRev: cur.revision,
                        incRev: cur.revision,
                        pendingOpId: cur.pendingOpID,
                        ackOpId: ackOpID,
                        sourceKind: 3,
                        hasPlacement: false
                    )
                    if rbVerdict.admitted {
                        let settledProj = cur.rollbackProject ?? cur.project
                        let settledFolder = isNested ? "" : (cur.rollbackFolder ?? cur.folder)
                        let settledRev = cur.rollbackRevision ?? cur.revision
                        placements[item.missionID] = PlacementState(
                            project: settledProj,
                            folder: settledFolder,
                            revision: settledRev,
                            pendingOpID: 0
                        )
                        var seen = seenFacts[item.missionID] ?? Seen()
                        seen.project = settledProj
                        seen.folder = settledFolder
                        seenFacts[item.missionID] = seen
                        if var anc = ancestors[item.missionID] {
                            anc.row = anc.row.withPatchedPlacement(
                                project: settledProj,
                                folder: settledFolder,
                                revision: settledRev
                            )
                            ancestors[item.missionID] = anc
                        }
                        accepted.append(OrbPlacementCommitItem(
                            missionID: item.missionID,
                            project: settledProj.isEmpty ? nil : settledProj,
                            folder: settledFolder,
                            placementRevision: settledRev
                        ))
                    }
                }
                continue
            }
            let nextPending: UInt32 = verdict.clearPending ? 0 : (cur?.pendingOpID ?? 0)
            if !verdict.clearPending, nextPending != 0, let cur {
                placements[item.missionID] = PlacementState(
                    project: cur.project,
                    folder: cur.folder,
                    revision: item.placementRevision,
                    pendingOpID: nextPending,
                    rollbackProject: normProj,
                    rollbackFolder: normFolder,
                    rollbackRevision: item.placementRevision
                )
                continue
            }
            placements[item.missionID] = PlacementState(
                project: normProj,
                folder: normFolder,
                revision: item.placementRevision,
                pendingOpID: nextPending,
                rollbackProject: nil,
                rollbackFolder: nil,
                rollbackRevision: nil
            )
            var seen = seenFacts[item.missionID] ?? Seen()
            seen.project = normProj
            seen.folder = normFolder
            seenFacts[item.missionID] = seen
            if var anc = ancestors[item.missionID] {
                anc.row = anc.row.withPatchedPlacement(
                    project: normProj,
                    folder: normFolder,
                    revision: item.placementRevision
                )
                ancestors[item.missionID] = anc
            }
            accepted.append(OrbPlacementCommitItem(
                missionID: item.missionID,
                project: normProj.isEmpty ? nil : normProj,
                folder: normFolder,
                placementRevision: item.placementRevision
            ))
        }
        return accepted
    }

    static func placement(of id: String) -> PlacementState? {
        lock.lock(); defer { lock.unlock() }
        return placements[id]
    }
    static func seen(_ id: String) -> Seen? {
        lock.lock(); defer { lock.unlock() }
        return seenFacts[id]
    }
    static func cachedAncestor(_ id: String, now: Date = Date(), allowStale: Bool = false) -> OrbRow? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = ancestors[id] else { return nil }
        if allowStale || now.timeIntervalSince(entry.fetchedAt) < ancestorTTLSeconds {
            return entry.row
        }
        return nil
    }
    static func storeAncestor(_ row: OrbRow, now: Date = Date()) {
        guard !row.id.isEmpty else { return }
        observe(row)
        lock.lock()
        ancestors[row.id] = CachedAncestor(row: row, fetchedAt: now)
        goneIDs.remove(row.id)
        lock.unlock()
    }
    static func markGone(_ id: String) {
        guard !id.isEmpty else { return }
        lock.lock()
        ancestors.removeValue(forKey: id)
        goneIDs.insert(id)
        lock.unlock()
    }
    static func isGone(_ id: String) -> Bool {
        if isBtwID(id) { return true }
        lock.lock(); defer { lock.unlock() }
        return goneIDs.contains(id)
    }
    private static func isBtwID(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        if btwIDs.contains(id) { return true }
        var seen: Set<String> = [id]
        var cursor = parents[id]
        while let current = cursor, seen.count < 16, seen.insert(current).inserted {
            if btwIDs.contains(current) { return true }
            cursor = parents[current]
        }
        return false
    }
    static func remember(_ id: String, parent: String) {
        guard !id.isEmpty else { return }
        lock.lock(); parents[id] = parent; lock.unlock()
    }
    static func parent(of id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return parents[id]
    }
    static func isBtw(_ row: OrbRow) -> Bool {
        if row.hasDirectBtwTag {
            if !row.id.isEmpty {
                lock.lock(); btwIDs.insert(row.id); lock.unlock()
            }
            return true
        }
        lock.lock(); defer { lock.unlock() }
        if !row.id.isEmpty, btwIDs.contains(row.id) { return true }
        var seen: Set<String> = row.id.isEmpty ? [] : [row.id]
        var cursor = row.payloadParentID ?? parents[row.id]
        while let current = cursor, seen.count < 16, seen.insert(current).inserted {
            if btwIDs.contains(current) { return true }
            cursor = parents[current]
        }
        return false
    }
    /// Explicit re-parent (nil detaches): the only way a remembered parent changes.
    static func reparent(_ id: String, parent: String?) {
        lock.lock(); parents[id] = parent; lock.unlock()
    }
    static func reset() {
        lock.lock()
        parents.removeAll()
        btwIDs.removeAll()
        seenFacts.removeAll()
        placements.removeAll()
        stagedRows.removeAll()
        nextOpID = 0
        ancestors.removeAll()
        goneIDs.removeAll()
        lock.unlock()
    }
}

struct OrbNestedMission: Identifiable, Hashable {
    let mission: OrbRow
    var children: [OrbNestedMission]
    /// An earlier version (fork) of the conversation it is listed in.
    var version: Bool
    var id: String { mission.id }
    init(mission: OrbRow, children: [OrbNestedMission] = [], version: Bool = false) {
        self.mission = mission
        self.children = children
        self.version = version
    }
}

enum OrbMissionTree {
    /// Exclude `/btw` side-question forks and every descendant worker in their subtrees.
    static func filterMobile(_ rows: [OrbRow]) -> [OrbRow] {
        for row in rows { OrbHierarchy.observe(row) }
        return rows.filter(\.mobile)
    }

    /// Keep archived/completed parents as context for visible child workers without restoring all archived missions.
    static func treeRows(_ missions: [OrbRow], visible: (OrbRow) -> Bool) -> [OrbRow] {
        var byID: [String: OrbRow] = [:]
        for m in missions where byID[m.id] == nil { byID[m.id] = m }
        var retained = Set(missions.filter(visible).map(\.id))
        for mission in missions where visible(mission) {
            var seen: Set<String> = [mission.id]
            var parent = mission.parentMissionID
            while let p = parent, !seen.contains(p) {
                seen.insert(p)
                guard let row = byID[p] else { break }
                retained.insert(p)
                parent = row.parentMissionID
            }
        }
        return missions.filter { retained.contains($0.id) }
    }

    private static let forkSettleMs: Int64 = 15_000
    static let recentOpenSeconds: TimeInterval = 7 * 24 * 60 * 60
    private static let liveOpenStates: Set<String> = [
        "active", "running", "pending", "queued", "awaiting_user", "resuming", "starting", "waiting_background"
    ]
    private static let recentOpenStates: Set<String> = [
        "interrupted", "failed", "paused", "blocked"
    ]

    private static func epochMs(_ raw: String) -> Int64 {
        guard !raw.isEmpty, let date = OrbStyle.parseDate(raw) else { return 0 }
        return Int64((date.timeIntervalSince1970 * 1000.0).rounded())
    }

    static func isSuperseded(_ mission: OrbRow) -> Bool {
        if mission.active { return false }
        return mission.hasTypedSuperseded
    }

    /// True when a mission or any of its ancestors is superseded and this mission is not actively running.
    static func isSupersededInTree(_ mission: OrbRow, byID: [String: OrbRow]) -> Bool {
        if mission.active { return false }
        if isSuperseded(mission) { return true }
        var seen: Set<String> = [mission.id]
        var parent = mission.parentMissionID
        while let p = parent, !seen.contains(p) {
            seen.insert(p)
            guard let row = byID[p] else { break }
            if isSuperseded(row) { return true }
            parent = row.parentMissionID
        }
        return false
    }

    /// Open missions older than the history page (`sidebar-hierarchy.md` M2):
    /// live ones always; stopped ones within 7 days; children only when live or their parent is listed.
    static func openBeyondPage(_ history: [OrbRow], extra: [OrbRow], now: Date = Date()) -> [OrbRow] {
        for row in history { OrbHierarchy.observe(row) }
        for row in extra { OrbHierarchy.observe(row) }
        let listed = Set(history.map(\.id))
        let nowMs = Int64((now.timeIntervalSince1970 * 1000.0).rounded())
        let recentWindowMs = Int64(recentOpenSeconds * 1000.0)
        let wanted = extra.filter { m in
            guard !listed.contains(m.id), m.mobile else { return false }
            let status = m.state.lowercased()
            if liveOpenStates.contains(status) { return true }
            if recentOpenStates.contains(status) {
                let ts = epochMs(m.updatedAt)
                return ts > 0 && nowMs - ts <= recentWindowMs
            }
            return false
        }
        let ids = listed.union(wanted.map(\.id))
        return wanted.filter { m in
            guard let p = m.parentMissionID else { return true }
            return liveOpenStates.contains(m.state.lowercased()) || ids.contains(p)
        }
    }

    /// Parents referenced by loaded rows that the rows do not contain.
    static func missingParentIDs(_ rows: [OrbRow]) -> [String] {
        let ids = Set(rows.map(\.id))
        var missing: [String] = []
        var seen: Set<String> = []
        for row in rows {
            if let parent = row.parentMissionID, !ids.contains(parent), seen.insert(parent).inserted {
                missing.append(parent)
            }
        }
        return missing
    }

    /// Fetch missing ancestors up to `maxDepth` and place each fetched ancestor right before its first descendant.
    static func withAncestors(
        _ rows: [OrbRow],
        maxDepth: Int = 8,
        fetchByID: @escaping @Sendable (String) async -> OrbRow?
    ) async -> [OrbRow] {
        var known: [String: OrbRow] = [:]
        for row in rows where known[row.id] == nil { known[row.id] = row }
        var knownOrder = rows
        var fetched: [String: OrbRow] = [:]
        var tried: Set<String> = []
        for _ in 0..<maxDepth {
            let wanted = missingParentIDs(knownOrder).filter { !tried.contains($0) }
            if wanted.isEmpty { break }
            tried.formUnion(wanted)
            let results = await withTaskGroup(of: OrbRow?.self, returning: [OrbRow].self) { group in
                for id in wanted {
                    group.addTask { await fetchByID(id) }
                }
                var collected: [OrbRow] = []
                for await item in group {
                    if let item { collected.append(item) }
                }
                return collected
            }
            let byFetchedID = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
            for id in wanted {
                if let row = byFetchedID[id], known[row.id] == nil {
                    known[row.id] = row
                    knownOrder.append(row)
                    fetched[row.id] = row
                }
            }
        }
        if fetched.isEmpty { return rows }
        var out: [OrbRow] = []
        var placed: Set<String> = []
        func place(_ row: OrbRow, seen: inout Set<String>) {
            if let parent = row.parentMissionID,
               let anc = fetched[parent],
               !placed.contains(parent),
               !seen.contains(parent) {
                seen.insert(parent)
                place(anc, seen: &seen)
            }
            if placed.insert(row.id).inserted {
                out.append(row)
            }
        }
        for row in rows {
            var seen: Set<String> = [row.id]
            place(row, seen: &seen)
        }
        return out
    }

    /// Filters a fetched project mission list (`ownIDs` + `withAncestors`) by each row's reconciled
    /// project so stale in-flight refreshes never reinsert conversations moved out optimistically or authoritatively.
    static func filterToProjectScope(_ rows: [OrbRow], projectSlug: String, ownIDs: Set<String>) -> [OrbRow] {
        let target = projectSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            if !row.project.isEmpty {
                return row.project.caseInsensitiveCompare(target) == .orderedSame
            }
            if let st = OrbHierarchy.placement(of: row.id), (st.revision > 0 || st.pendingOpID != 0) {
                return false
            }
            return ownIDs.contains(row.id)
        }
    }

    private static func rowSortMs(_ row: OrbRow) -> Int64 {
        let u = epochMs(row.updatedAt)
        return u > 0 ? u : epochMs(row.raw["created_at"].text)
    }

    static func insertRowByRecency(_ list: inout [OrbRow], _ row: OrbRow) {
        let ts = rowSortMs(row)
        if ts > 0, let idx = list.firstIndex(where: { rowSortMs($0) < ts }) {
            list.insert(row, at: idx)
        } else if ts > 0 {
            list.append(row)
        } else {
            list.insert(row, at: 0)
        }
    }

    /// Merges any in-flight optimistic destination preview rows (`pendingOpID != 0`) into `rows`
    /// so a concurrent destination `load()` finishing before `POST /move` commits never drops the preview.
    static func mergePendingStagedRows(_ rows: [OrbRow], projectSlug: String) -> [OrbRow] {
        let previews = OrbHierarchy.pendingPreviewRows(forProject: projectSlug).filter(\.mobile)
        guard !previews.isEmpty else { return rows }
        var out = rows
        var existing = Set(rows.map(\.id))
        for preview in previews where existing.insert(preview.id).inserted {
            insertRowByRecency(&out, preview)
        }
        return out
    }

    /// Applies placement updates (optimistic preview, authoritative commit, or failed-move rollback)
    /// directly to a project's loaded `OrbRow` list, inserting staged cross-project arrivals in recency
    /// order without requiring a server reload unless an uncached remote SSE mission arrived (`missingIDs`).
    static func applyPlacementItems(
        to existing: [OrbRow],
        projectSlug: String,
        moves: [OrbPlacementCommitItem],
        fallbackRows: [String: OrbRow] = [:]
    ) -> (rows: [OrbRow], changed: Bool, missingIDs: [String]) {
        guard !moves.isEmpty else { return (existing, false, []) }
        let targetSlug = projectSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        let byID = Dictionary(uniqueKeysWithValues: moves.map { ($0.missionID, $0) })
        var changed = false
        var nextRows: [OrbRow] = []
        nextRows.reserveCapacity(existing.count + moves.count)
        var presentIDs: Set<String> = []
        for row in existing {
            guard let move = byID[row.id] else {
                nextRows.append(row)
                presentIDs.insert(row.id)
                continue
            }
            let targetProj = (move.project ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if targetProj.caseInsensitiveCompare(targetSlug) != .orderedSame {
                changed = true
                continue
            }
            nextRows.append(row.withPatchedPlacement(
                project: targetProj,
                folder: move.folder,
                revision: move.placementRevision,
                isPreview: move.isPreview
            ))
            presentIDs.insert(row.id)
            changed = true
        }
        var missingIDs: [String] = []
        for move in moves {
            let targetProj = (move.project ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard targetProj.caseInsensitiveCompare(targetSlug) == .orderedSame,
                  !presentIDs.contains(move.missionID) else { continue }
            if let source = fallbackRows[move.missionID] ?? OrbHierarchy.stagedRow(for: move.missionID) {
                guard source.mobile else { continue }
                let patched = source.withPatchedPlacement(
                    project: targetProj,
                    folder: move.folder,
                    revision: move.placementRevision,
                    isPreview: move.isPreview
                )
                insertRowByRecency(&nextRows, patched)
                presentIDs.insert(move.missionID)
                changed = true
            } else if !move.isPreview {
                missingIDs.append(move.missionID)
            }
        }
        return (nextRows, changed, missingIDs)
    }

    /// Snapshots root missions under `oldFolder` before any async move runs and groups IDs by
    /// destination folder so fork-family expansion on the leader never corrupts sibling suffixes.
    static func planVirtualFolderMigration(
        missions: [OrbRow],
        from oldFolder: String,
        to destination: String
    ) -> [(folder: String, ids: [String])] {
        let normOld = OrbRow.normalizeFolder(oldFolder)
        let normDest = OrbRow.normalizeFolder(destination)
        guard !normOld.isEmpty, normOld != normDest else { return [] }
        var order: [String] = []
        var byTarget: [String: [String]] = [:]
        var seenIDs: Set<String> = []
        for row in missions {
            guard !row.id.isEmpty, row.parentMissionID == nil, seenIDs.insert(row.id).inserted else { continue }
            let cur = OrbRow.normalizeFolder(row.folder)
            guard cur == normOld || cur.hasPrefix(normOld + "/") else { continue }
            let suffix = String(cur.dropFirst(normOld.count))
            let target = OrbRow.normalizeFolder(normDest + suffix)
            if byTarget[target] == nil {
                order.append(target)
                byTarget[target] = [row.id]
            } else {
                byTarget[target]?.append(row.id)
            }
        }
        return order.compactMap { target in
            guard let ids = byTarget[target], !ids.isEmpty else { return nil }
            return (folder: target, ids: ids)
        }
    }

    /// Stand-in row for a parent that is not in the loaded rows (cross-project, or transient fetch error).
    /// Returns `nil` only when Core confirmed the parent is gone (404) or in a `/btw` subtree.
    static func placeholderParent(_ projectSlug: String) -> (String, OrbRow) -> OrbRow? {
        { parentID, child in
            if OrbHierarchy.isGone(parentID) { return nil }
            let known = OrbHierarchy.seen(parentID)
            let parentFolder = OrbRow.normalizeFolder(known?.folder ?? child.folder)
            var dict: [String: OrbJSON] = [
                "id": .string(parentID),
                "title": known?.title.map(OrbJSON.string) ?? .null,
                "status": .string(known?.status ?? "unknown"),
                "project": .string(known?.project ?? projectSlug),
                "folder": .string(parentFolder),
                "tags": .array([]),
                "history": .array([]),
                "created_at": child.raw["created_at"],
                "updated_at": .string(child.updatedAt),
                "orb_placeholder": .bool(true),
            ]
            if let backend = known?.backend, !backend.isEmpty {
                dict["backend"] = .string(backend)
            }
            return OrbRow(.object(dict))
        }
    }

    private static func isRetiredVersion(_ mission: OrbRow) -> Bool {
        let lower = mission.state.lowercased()
        if lower == "acknowledged" || lower == "archived" { return true }
        return mission.hasTypedSuperseded || mission.raw["tags"].items.contains { $0.text.lowercased() == "orb-archived" }
    }

    /// Maps each listed fork to its conversation's leader using the normative
    /// `(unretired, live, effectiveActivity, forkDepth)` rank (`docs/specs/sidebar-hierarchy.md` F1).
    static func forkLeaders(_ missions: [OrbRow]) -> [String: OrbRow] {
        var byID: [String: OrbRow] = [:]
        for mission in missions where byID[mission.id] == nil { byID[mission.id] = mission }
        struct Lineage { let rootID: String; let depth: Int; let ancestors: [String] }
        func lineage(_ mission: OrbRow) -> Lineage {
            var current = mission
            var seen: Set<String> = []
            var ancestors: [String] = []
            while let source = current.forkSource, let next = byID[source], !seen.contains(source) {
                seen.insert(current.id)
                current = next
                ancestors.append(current.id)
            }
            return Lineage(rootID: current.id, depth: ancestors.count, ancestors: ancestors)
        }
        var info: [String: Lineage] = [:]
        var rootOrder: [String] = []
        var groups: [String: [OrbRow]] = [:]
        for mission in missions {
            let lin = info[mission.id] ?? lineage(mission)
            info[mission.id] = lin
            if groups[lin.rootID] == nil { rootOrder.append(lin.rootID) }
            groups[lin.rootID, default: []].append(mission)
        }
        var leaders: [String: OrbRow] = [:]
        for rootID in rootOrder {
            guard let group = groups[rootID], group.count > 1 else { continue }
            var effective: [String: Int64] = [:]
            for m in group { effective[m.id] = epochMs(m.updatedAt) }
            for m in group {
                let created = epochMs(m.raw["created_at"].text)
                guard created > 0, let ancestors = info[m.id]?.ancestors else { continue }
                for ancID in ancestors {
                    if let ancAct = effective[ancID], ancAct <= created + forkSettleMs {
                        effective[ancID] = min(ancAct, created)
                    }
                }
            }
            func rank(_ m: OrbRow) -> (Int, Int, Int64, Int) {
                (isRetiredVersion(m) ? 0 : 1, m.active ? 1 : 0, effective[m.id] ?? 0, info[m.id]?.depth ?? 0)
            }
            var leader = group[0]
            var bestRank = rank(leader)
            for candidate in group.dropFirst() {
                let r = rank(candidate)
                if r > bestRank {
                    leader = candidate
                    bestRank = r
                }
            }
            for mission in group { leaders[mission.id] = leader }
        }
        return leaders
    }

    /// Roots keep the order of the list, and so do the children of each mission.
    /// The most recently active version of a forked conversation leads; earlier
    /// versions are listed inside it after its launched work. When `placeholder`
    /// is provided, a child whose parent is missing from `missions` is held under
    /// a stand-in parent row unless `placeholder` returns `nil` (parent confirmed gone).
    static func nest(_ missions: [OrbRow], placeholder: ((String, OrbRow) -> OrbRow?)? = nil) -> [OrbNestedMission] {
        var byID: [String: OrbRow] = [:]
        for mission in missions where byID[mission.id] == nil {
            byID[mission.id] = mission
        }
        let leaders = forkLeaders(missions)
        var versionsByLeader: [String: [OrbRow]] = [:]
        var childrenByParent: [String: [OrbRow]] = [:]
        var placeholders: [String: OrbRow] = [:]
        var roots: [OrbRow] = []
        for mission in missions {
            if let leader = leaders[mission.id], leader.id != mission.id {
                versionsByLeader[leader.id, default: []].append(mission)
                continue
            }
            // A leading fork takes the place of the conversation it continues.
            let place = leaders[mission.id].flatMap { leader in missions.first { leaders[$0.id]?.id == leader.id && $0.forkSource == nil } } ?? mission
            let parentID = place.parentMissionID
            if let parentID,
               let parent = byID[parentID],
               parent.id != mission.id,
               !reaches(byID: byID, from: parent, target: mission.id) {
                childrenByParent[parentID, default: []].append(mission)
            } else if let parentID, parentID != mission.id, byID[parentID] == nil, let placeholder {
                if let existing = placeholders[parentID] {
                    childrenByParent[existing.id, default: []].append(mission)
                } else if let standIn = placeholder(parentID, place) {
                    placeholders[parentID] = standIn
                    roots.append(standIn)
                    childrenByParent[standIn.id, default: []].append(mission)
                } else {
                    roots.append(mission)
                }
            } else {
                roots.append(mission)
            }
        }
        func build(_ row: OrbRow, visited: Set<String>) -> OrbNestedMission {
            var nextVisited = visited
            nextVisited.insert(row.id)
            let kids = (childrenByParent[row.id] ?? []).filter { !nextVisited.contains($0.id) }.map { build($0, visited: nextVisited) }
            let versions = (versionsByLeader[row.id] ?? []).sorted { $0.updatedAt > $1.updatedAt }.map { version -> OrbNestedMission in
                var node = build(version, visited: nextVisited)
                node.version = true
                return node
            }
            return OrbNestedMission(mission: row, children: kids + versions)
        }
        return roots.map { build($0, visited: []) }
    }

    private static func reaches(byID: [String: OrbRow], from: OrbRow, target: String) -> Bool {
        var seen: Set<String> = []
        var current: OrbRow? = from
        while let cur = current, !seen.contains(cur.id) {
            if cur.id == target { return true }
            seen.insert(cur.id)
            if let p = cur.parentMissionID {
                current = byID[p]
            } else {
                current = nil
            }
        }
        return false
    }

    static func countNested(_ node: OrbNestedMission, matches: (OrbRow) -> Bool = { _ in true }) -> Int {
        node.children.reduce(0) { sum, child in
            child.version ? sum : sum + (matches(child.mission) ? 1 : 0) + countNested(child, matches: matches)
        }
    }

    static func countVersions(_ node: OrbNestedMission) -> Int { node.children.filter(\.version).count }

    static func subtree(_ missions: [OrbRow], rootIDs: [String]) -> [OrbRow] {
        guard !rootIDs.isEmpty else { return [] }
        var byID: [String: OrbRow] = [:]
        for m in missions where byID[m.id] == nil { byID[m.id] = m }
        var buckets: [String: [OrbRow]] = [:]
        for m in missions {
            let bucket = m.project.isEmpty ? "default" : m.project
            buckets[bucket, default: []].append(m)
        }
        let leadersByBucket = buckets.mapValues { forkLeaders($0) }
        var included = Set(rootIDs)
        for rid in rootIDs {
            guard let target = byID[rid] else { continue }
            let bucket = target.project.isEmpty ? "default" : target.project
            guard let leaders = leadersByBucket[bucket], leaders[rid]?.id == rid else { continue }
            for sibling in buckets[bucket] ?? [] where leaders[sibling.id]?.id == rid {
                included.insert(sibling.id)
            }
        }
        var added = true
        while added {
            added = false
            for mission in missions where !included.contains(mission.id) {
                if let parent = mission.parentMissionID, included.contains(parent) {
                    included.insert(mission.id)
                    added = true
                }
            }
        }
        return missions.filter { included.contains($0.id) }
    }

    static func filterArchivedByAge(_ rows: [OrbRow], maxAgeSeconds: TimeInterval?, now: Date = Date()) -> [OrbRow] {
        guard let maxAgeSeconds else { return rows }
        let cutoff = now.addingTimeInterval(-maxAgeSeconds)
        return rows.filter { row in
            guard let date = OrbStyle.parseDate(row.updatedAt) else { return false }
            return date <= cutoff
        }
    }
}

enum OrbKeychain {
    struct Credentials: Codable { let password: String; let username: String? }
    static func credentials(for endpoint: String) -> Credentials? {
        guard let text = token(for: endpoint, service: "md.thomas.orb.credentials"), let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }
    @discardableResult static func saveCredentials(_ value: Credentials?, for endpoint: String) -> Bool {
        guard let value else { return save(nil, for: endpoint, service: "md.thomas.orb.credentials") }
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return false }
        return save(text, for: endpoint, service: "md.thomas.orb.credentials")
    }
    static func token(for endpoint: String, service: String = "md.thomas.orb.core") -> String? {
        var query = base(endpoint, service: service)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    @discardableResult static func save(_ value: String?, for endpoint: String, service: String = "md.thomas.orb.core") -> Bool {
        let query = base(endpoint, service: service)
        guard let value else { let code = SecItemDelete(query as CFDictionary); return code == errSecSuccess || code == errSecItemNotFound }
        let data = Data(value.utf8)
        let attributes: [CFString: Any] = [kSecValueData: data]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecSuccess { return true }
        _ = SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData] = data
        insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
    private static func base(_ endpoint: String, service: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: endpoint]
    }
}

/// Persist the exact request before submitting. An uncertain response never creates a new identity.
struct OrbPending: Codable, Sendable {
    let path: String
    let body: OrbJSON
}

private actor OrbDiskWriter {
    static let shared = OrbDiskWriter()
    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func read(from url: URL) -> Data? {
        try? Data(contentsOf: url)
    }
}

@MainActor
enum OrbDisk {
    private static var urlCache: [String: URL] = [:]
    static func url(_ key: String, accountScope: String? = nil) -> URL {
        let scope = (accountScope ?? (OrbCore.shared.endpoint + ":" + (OrbCore.shared.authToken ?? ""))) + ":" + key
        if let cached = urlCache[scope] { return cached }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orb")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        let result = root.appendingPathComponent(name + ".json")
        if urlCache.count > 1024 { urlCache.removeAll(keepingCapacity: true) }
        urlCache[scope] = result
        return result
    }
    static func read<T: Decodable>(_ key: String, as type: T.Type, accountScope: String? = nil) -> T? {
        guard let data = try? Data(contentsOf: url(key, accountScope: accountScope)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func readAsync<T: Decodable & Sendable>(_ key: String, as type: T.Type) async -> T? {
        let target = url(key)
        guard let data = await OrbDiskWriter.shared.read(from: target) else { return nil }
        return await Task.detached(priority: .utility) {
            try? JSONDecoder().decode(type, from: data)
        }.value
    }
    static func save<T: Encodable>(_ value: T, key: String) throws {
        try JSONEncoder().encode(value).write(to: url(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func saveAsync<T: Encodable & Sendable>(_ value: T, key: String, accountScope: String? = nil) {
        let target = url(key, accountScope: accountScope)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? await OrbDiskWriter.shared.write(data, to: target)
        }
    }
    static func remove(_ key: String) { try? FileManager.default.removeItem(at: url(key)) }
}

/// Account-scoped, bounded read-through cache. In-flight loads are shared with navigation.
@MainActor
enum OrbReadCache {
    private struct Entry { let value: OrbJSON; let date: Date }
    private static var values: [String: Entry] = [:]
    private static var eventValues: [String: [StoredEvent]] = [:]
    private static var eventFetchedAt: [String: Date] = [:]
    private static var eventPending: [String: Task<[StoredEvent], Error>] = [:]
    /// Network source for `events(_:)`; tests replace it.
    static var eventsFetcher: @MainActor (_ missionID: String, _ limit: Int) async throws -> [StoredEvent] = { id, limit in
        try await OrbCore.shared.getMissionEventsWithMeta(id: id, limit: limit, sinceSeq: nil).events
    }
    private struct Pending { let id = UUID(); let task: Task<OrbJSON, Error> }
    private static var pending: [String: Pending] = [:]
    private static var cachedProjectSlugs: Set<String> = []
    private static func key(_ name: String) -> String {
        if name.hasPrefix("project:") {
            let rest = String(name.dropFirst("project:".count))
            let slug = rest.hasSuffix(":all") ? String(rest.dropLast(4)) : rest
            if !slug.isEmpty { cachedProjectSlugs.insert(slug) }
        }
        return OrbDisk.url(name).absoluteString
    }
    static func read(_ name: String) -> OrbJSON? {
        let scope = key(name)
        if let cached = values[scope]?.value { return cached }
        if let disk = OrbDisk.read(name, as: OrbJSON.self) {
            values[scope] = Entry(value: disk, date: .distantPast)
            return disk
        }
        return nil
    }
    /// Navigation must not decode a long transcript or project roster on the main actor.
    static func readAsync(_ name: String) async -> OrbJSON? {
        let scope = key(name)
        if let cached = values[scope]?.value { return cached }
        let disk = await OrbDisk.readAsync(name, as: OrbJSON.self)
        guard scope == key(name), !Task.isCancelled else { return nil }
        // A network response may have arrived while disk decoding was in flight.
        if let cached = values[scope]?.value { return cached }
        if let disk { values[scope] = Entry(value: disk, date: .distantPast) }
        return disk
    }
    static func seedMemory(_ name: String, value: OrbJSON) {
        let scope = key(name)
        // List rows do not own conversation history. In particular, after memory
        // trimming they must not mask the full conversation still saved on disk.
        if name.hasPrefix("mission:"), value["history"].items.isEmpty { return }
        if values.count >= 256, let oldest = values.min(by: { $0.value.date < $1.value.date })?.key { values[oldest] = nil }
        values[scope] = Entry(value: value, date: Date())
    }
    static func seed(_ name: String, value: OrbJSON) {
        if name.hasPrefix("mission:"), value["history"].items.isEmpty { return }
        seedMemory(name, value: value)
        OrbDisk.saveAsync(value, key: name)
    }
    /// Reconciles an authoritative mission mutation (e.g. `PATCH /settings` or `mission_settings_updated`)
    /// into the in-memory and disk read cache while preserving any cached conversation history and
    /// fencing any in-flight read started before the mutation so it cannot overwrite the cache.
    static func saveMission(_ id: String, value: OrbJSON) {
        let name = "mission:\(id)"
        let scope = key(name)
        pending[scope] = nil
        var merged = value
        if merged["history"].items.isEmpty,
           let existing = values[scope]?.value ?? OrbDisk.read(name, as: OrbJSON.self),
           !existing["history"].items.isEmpty,
           case var .object(fields) = merged {
            fields["history"] = existing["history"]
            merged = .object(fields)
        }
        if values.count >= 256, let oldest = values.min(by: { $0.value.date < $1.value.date })?.key { values[oldest] = nil }
        values[scope] = Entry(value: merged, date: Date())
        OrbDisk.saveAsync(merged, key: name)
    }
    static func seedFromGlobalMissions(_ rawMissions: [OrbJSON]) {
        var byProject: [String: [OrbJSON]] = [:]
        var activeIds: [String] = []
        for item in rawMissions {
            let mid = item["id"].text
            if !mid.isEmpty {
                seedMemory("mission:\(mid)", value: item)
                let row = OrbRow(item)
                if row.active && !row.cloud && row.mobile {
                    activeIds.append(mid)
                }
            }
            let proj = item["project"].text
            if !proj.isEmpty {
                byProject[proj, default: []].append(item)
            }
        }
        OrbWarmSyncCoordinator.shared.noteLiveMissionIds(Array(activeIds.prefix(8)))
        for (proj, list) in byProject {
            let cacheName = "project:\(proj)"
            let scope = key(cacheName)
            if values[scope] == nil && read(cacheName) == nil {
                values[scope] = Entry(
                    value: .object(["missions": .array(list), "manifest": .null]),
                    date: Date().addingTimeInterval(-25) // allow quick display while still refreshing
                )
            }
        }
    }
    static func readMemoryEvents(_ missionID: String) -> [StoredEvent] {
        let cacheName = "events:\(missionID)"
        let scope = key(cacheName)
        return eventValues[scope] ?? []
    }
    static func readEvents(_ missionID: String) -> [StoredEvent] {
        let cacheName = "events:\(missionID)"
        let scope = key(cacheName)
        if let cached = eventValues[scope] { return cached }
        if let disk = OrbDisk.read(cacheName, as: [StoredEvent].self)?.map(\.compacted) {
            eventValues[scope] = disk
            return disk
        }
        return []
    }
    static func readEventsAsync(_ missionID: String) async -> [StoredEvent] {
        let cacheName = "events:\(missionID)"
        let scope = key(cacheName)
        if let cached = eventValues[scope] { return cached }
        let disk = await OrbDisk.readAsync(cacheName, as: [StoredEvent].self)
        guard scope == key(cacheName), !Task.isCancelled else { return [] }
        if let cached = eventValues[scope] { return cached }
        let events = (disk ?? []).map(\.compacted)
        if !events.isEmpty { eventValues[scope] = events }
        return events
    }
    static func saveEvents(_ missionID: String, events: [StoredEvent]) {
        let cacheName = "events:\(missionID)"
        let scope = key(cacheName)
        if eventValues.count >= 48, let firstKey = eventValues.keys.first {
            eventValues.removeValue(forKey: firstKey)
        }
        let capped = (events.count > 250 ? events.suffix(250) : events[...]).map(\.compacted)
        eventValues[scope] = capped
        OrbDisk.saveAsync(capped, key: cacheName)
    }
    /// The one way to fetch a mission's recent events: account-scoped, TTL-bounded, and
    /// concurrent callers share one request. Results also land in the disk cache.
    static func events(_ missionID: String, limit: Int = 120, ttl: TimeInterval = 30, force: Bool = false, now: @MainActor () -> Date = { Date() }) async throws -> [StoredEvent] {
        let scope = key("events:\(missionID)")
        if !force, let fetched = eventFetchedAt[scope], now().timeIntervalSince(fetched) < ttl, let cached = eventValues[scope] {
            return cached
        }
        if let task = eventPending[scope] { return try await task.value }
        let task = Task { @MainActor in try await eventsFetcher(missionID, limit) }
        eventPending[scope] = task
        defer { eventPending[scope] = nil }
        let events = try await task.value
        // The account may have changed while the request was in flight.
        guard scope == key("events:\(missionID)") else { throw CancellationError() }
        saveEvents(missionID, events: events)
        eventFetchedAt[scope] = now()
        return events.map(\.compacted)
    }
    static func load(_ name: String, ttl: TimeInterval = 30, force: Bool = false, fetch: @escaping @MainActor () async throws -> OrbJSON) async throws -> OrbJSON {
        let scope = key(name)
        if !force, let entry = values[scope], Date().timeIntervalSince(entry.date) < ttl { return entry.value }
        if let item = pending[scope] {
            let value = try await item.task.value
            guard scope == key(name) else { throw CancellationError() }
            return value
        }
        let task = Task { try await fetch() }
        let item = Pending(task: task)
        pending[scope] = item
        defer { if pending[scope]?.id == item.id { pending[scope] = nil } }
        let value = try await task.value
        // The account changed while this was in flight: the answer belongs to nobody.
        guard scope == key(name) else { throw CancellationError() }
        // Invalidated while in flight (a send): its waiters still get this answer, but it
        // is not cached, so the next load fetches fresh data. Throwing here surfaced as a
        // "Connection unavailable … cancelled" error after every send.
        guard pending[scope]?.id == item.id else { return value }
        if values.count >= 256, let oldest = values.min(by: { $0.value.date < $1.value.date })?.key { values[oldest] = nil }
        values[scope] = Entry(value: value, date: Date())
        OrbDisk.saveAsync(value, key: name)
        return value
    }
    /// Settings → Debug info → Clear caches: drops memory and disk copies for every account.
    static func clearAll() {
        OrbHierarchy.reset()
        OrbWarmSyncCoordinator.shared.resetCaches()
        OrbBtwStore.resetAll()
        for item in pending.values { item.task.cancel() }
        pending.removeAll()
        values.removeAll()
        eventValues.removeAll()
        eventFetchedAt.removeAll()
        for task in eventPending.values { task.cancel() }
        eventPending.removeAll()
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orb")
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            do { try FileManager.default.removeItem(at: file) } catch { Log.error(.cache, "clear cache file", path: file.lastPathComponent, error) }
        }
        Log.cache.notice("cleared \(files.count) cache files")
    }
    /// Drops memory copies (disk copies stay) so a suspended app is a small jetsam target.
    static func trimMemory() {
        OrbWarmSyncCoordinator.shared.resetCaches()
        OrbBtwStore.trimMemory()
        values.removeAll()
        eventValues.removeAll()
        eventFetchedAt.removeAll()
    }
    static func invalidate(_ name: String) {
        let scope = key(name)
        pending[scope] = nil
        if let old = values[scope] { values[scope] = Entry(value: old.value, date: .distantPast) }
    }
    private static func jsonSortMs(_ raw: OrbJSON) -> Int64 {
        let u = raw["updated_at"].text
        if !u.isEmpty, let date = OrbStyle.parseDate(u) {
            return Int64((date.timeIntervalSince1970 * 1000.0).rounded())
        }
        let c = raw["created_at"].text
        if !c.isEmpty, let date = OrbStyle.parseDate(c) {
            return Int64((date.timeIntervalSince1970 * 1000.0).rounded())
        }
        return 0
    }
    static func applyPlacementCommit(
        _ accepted: [OrbPlacementCommitItem],
        fallbackRows: [String: OrbRow] = [:],
        persistToDisk: Bool = true
    ) {
        guard !accepted.isEmpty else { return }
        let byID = Dictionary(uniqueKeysWithValues: accepted.map { ($0.missionID, $0) })
        var touchedProjects: Set<String> = []
        for item in accepted {
            if let p = item.project, !p.isEmpty { touchedProjects.insert(p) }
            let mKey = "mission:\(item.missionID)"
            let mScope = key(mKey)
            if let entry = values[mScope], case var .object(dict) = entry.value {
                if let oldProj = dict["project"]?.text, !oldProj.isEmpty { touchedProjects.insert(oldProj) }
                dict["project"] = item.project.map(OrbJSON.string) ?? .null
                dict["folder"] = .string(item.folder)
                dict["placement_revision"] = .number(Double(item.placementRevision))
                if item.isPreview {
                    dict["orb_projected_move"] = .bool(true)
                } else {
                    dict.removeValue(forKey: "orb_projected_move")
                }
                let nextVal: OrbJSON = .object(dict)
                values[mScope] = Entry(value: nextVal, date: entry.date)
                if persistToDisk && !item.isPreview {
                    OrbDisk.saveAsync(nextVal, key: mKey)
                }
            }
        }
        // Evict cross-project moved missions immediately from every cached `project:<slug>` / `project:<slug>:all` entry,
        // patch in-place, and insert staged arriving rows in recency order so cold destination views render immediately.
        let candidateSlugs = cachedProjectSlugs.union(touchedProjects)
        for slug in candidateSlugs where !slug.isEmpty {
            for suffix in ["", ":all"] {
                let cacheName = "project:\(slug)\(suffix)"
                let scopeKey = key(cacheName)
                guard let entry = values[scopeKey] ?? OrbDisk.read(cacheName, as: OrbJSON.self).map({ Entry(value: $0, date: .distantPast) }),
                      case var .object(root) = entry.value,
                      case .array(let list) = root["missions"] else {
                    pending[scopeKey] = nil
                    continue
                }
                var changed = false
                var nextList: [OrbJSON] = []
                nextList.reserveCapacity(list.count + accepted.count)
                var presentIDs: Set<String> = []
                for raw in list {
                    let mid = raw["id"].text
                    guard let move = byID[mid] else {
                        nextList.append(raw)
                        if !mid.isEmpty { presentIDs.insert(mid) }
                        continue
                    }
                    let targetProj = move.project ?? ""
                    if targetProj.caseInsensitiveCompare(slug) != .orderedSame {
                        changed = true
                        touchedProjects.insert(slug)
                        continue
                    }
                    if case var .object(dict) = raw {
                        dict["project"] = targetProj.isEmpty ? .null : .string(targetProj)
                        dict["folder"] = .string(move.folder)
                        dict["placement_revision"] = .number(Double(move.placementRevision))
                        if move.isPreview {
                            dict["orb_projected_move"] = .bool(true)
                        } else {
                            dict.removeValue(forKey: "orb_projected_move")
                        }
                        nextList.append(.object(dict))
                        presentIDs.insert(mid)
                        changed = true
                    } else {
                        nextList.append(raw)
                        if !mid.isEmpty { presentIDs.insert(mid) }
                    }
                }
                for move in accepted {
                    let targetProj = move.project ?? ""
                    guard targetProj.caseInsensitiveCompare(slug) == .orderedSame,
                          !presentIDs.contains(move.missionID),
                          let source = fallbackRows[move.missionID] ?? OrbHierarchy.stagedRow(for: move.missionID) else { continue }
                    if suffix.isEmpty && source.state == "acknowledged" { continue }
                    let patched = source.withPatchedPlacement(
                        project: targetProj,
                        folder: move.folder,
                        revision: move.placementRevision,
                        isPreview: move.isPreview
                    ).raw
                    let ts = jsonSortMs(patched)
                    if ts > 0, let idx = nextList.firstIndex(where: { jsonSortMs($0) < ts }) {
                        nextList.insert(patched, at: idx)
                    } else if ts > 0 {
                        nextList.append(patched)
                    } else {
                        nextList.insert(patched, at: 0)
                    }
                    presentIDs.insert(move.missionID)
                    changed = true
                }
                pending[scopeKey] = nil
                if changed {
                    root["missions"] = .array(nextList)
                    let updated: OrbJSON = .object(root)
                    values[scopeKey] = Entry(value: updated, date: .distantPast)
                    if persistToDisk && !accepted.contains(where: \.isPreview) {
                        OrbDisk.saveAsync(updated, key: cacheName)
                    }
                }
            }
        }
    }
    static func project(_ id: String, includeArchived: Bool = false, force: Bool = false) async throws -> OrbJSON {
        let cacheKey = includeArchived ? "project:\(id):all" : "project:\(id)"
        return try await load(cacheKey, force: force) {
            async let missions = OrbCore.shared.missions(id, includeArchived: includeArchived)
            async let manifest = OrbCore.shared.call("/api/projects/\(OrbCore.escape(id))/context/manifest")
            return try await .object(["missions": .array(missions.map(\.raw)), "manifest": manifest])
        }
    }
    static func conversation(_ id: String, force: Bool = false) async throws -> OrbJSON {
        try await load("mission:\(id)", force: force) {
            try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(id))?include_history=false")
        }
    }
    static func cloud(_ id: String, force: Bool = false) async throws -> OrbJSON {
        try await load("cloud:\(id)", force: force) {
            try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(id))/cloud")
        }
    }
    static func agentCatalog(force: Bool = false) async throws -> OrbJSON {
        try await load("catalog:agent", ttl: 120, force: force) {
            async let backends = OrbCore.shared.call("/api/backends")
            async let nodes = OrbCore.shared.call("/api/remote-nodes")
            async let models = OrbCore.shared.call("/api/providers/backend-models")
            async let managed = try? OrbCore.shared.call("/api/managed-machines")
            return try await .object([
                "backends": backends,
                "nodes": nodes,
                "models": models,
                "managed": (await managed) ?? .null
            ])
        }
    }
    static func cloudAccounts(force: Bool = false) async throws -> OrbJSON {
        try await load("catalog:cloud:accounts", ttl: 90, force: force) {
            try await OrbCore.shared.call("/api/cloud/accounts")
        }
    }
    static func cloudOptions(_ endpoint: String, force: Bool = false) async throws -> OrbJSON {
        try await load("catalog:cloud:\(endpoint)", ttl: 120, force: force) {
            try await OrbCore.shared.call("/api/cloud/\(endpoint)/options")
        }
    }
    static func prefetch(_ rows: [OrbRow]) async {
        let liveTargets = rows.filter { $0.active && !$0.cloud && $0.mobile }.prefix(8)
        let topTargets = rows.prefix(5)
        var seen = Set<String>()
        let combined = (Array(liveTargets) + Array(topTargets)).filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        let tasks: [Task<Void, Never>] = combined.map { row in
            Task { @MainActor in
                guard !Task.isCancelled else { return }
                if row.raw != .null && !row.raw["history"].items.isEmpty {
                    seedMemory("mission:\(row.id)", value: row.raw)
                } else {
                    _ = try? await conversation(row.id)
                }
                if row.cloud {
                    _ = try? await cloud(row.id)
                } else if readEvents(row.id).isEmpty {
                    _ = await Log.attempt(.cache, "events prefetch", path: row.id) { try await events(row.id, limit: 150) }
                }
            }
        }
        for t in tasks {
            await t.value
        }
        OrbWarmSyncCoordinator.shared.reconcile()
    }
}

/// Small snapshots stay separate from full history and its paging cursor.
@MainActor enum OrbPresentation {
    private static var recent: [String] = []
    private static var pending: Set<String> = []
    private static var listChanged = false
    private static var labels: [String: String] = [:]
    static func activity(_ id: String?) -> String? { id.flatMap { labels[scope + ":" + $0] } }
    private static var scope: String { OrbCore.shared.endpoint + ":" + (OrbCore.shared.authToken ?? "") }
    private static var rememberedScope = ""
    private static func ensureScope() {
        guard rememberedScope != scope else { return }
        rememberedScope = scope
        recent.removeAll(); pending.removeAll(); labels.removeAll(); listChanged = false
    }
    static func remember(_ id: String) {
        ensureScope()
        recent.removeAll { $0 == id }; recent.append(id)
        if recent.count > 12 { recent.removeFirst() }
    }
    static func history(_ snapshot: OrbJSON) -> [OrbJSON] {
        snapshot["events"].items.compactMap { event in
            let type = event["event_type"].text
            if case .bool(true) = event["metadata"]["queued"] { return nil }
            guard type == "assistant_message" || type == "assistant_message_canonical" || type == "user_message" else { return nil }
            return .object(["role": .string(type == "user_message" ? "user" : "assistant"), "content": event["content"]])
        }
    }
    static func load(_ id: String) async -> OrbJSON? {
        let account = scope
        guard let value = try? await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(id))/snapshot?profile=presentation"),
              value["profile"].text == "presentation", account == scope, !Task.isCancelled else { return nil }
        let previous = await OrbReadCache.readAsync("presentation:\(id)")
        guard account == scope, !Task.isCancelled else { return nil }
        if let previous, case .number(let old) = previous["revision"], case .number(let new) = value["revision"], old >= new { return previous }
        if labels.count >= 48 { labels.removeAll() }
        labels[scope + ":" + id] = value["activity"].text
        OrbReadCache.seed("presentation:\(id)", value: value)
        return value
    }
    static func monitor() async {
        while !Task.isCancelled {
            ensureScope()
            let account = scope
            let stream = OrbCore.shared.streamControl(missionId: nil, kinds: ["presentation"]) { type, data in
                if type == "status" || type == "stream_lagged" {
                    pending.formUnion(recent)
                    OrbWarmSyncCoordinator.shared.notePresentationStreamDisrupted()
                }
                if type == "mission_placement_changed" {
                    OrbCore.applyIncomingPlacementEvent(data)
                    listChanged = true
                    return
                }
                guard type == "mission_presentation", let id = data["mission_id"] as? String else { return }
                let kind = data["kind"] as? String
                OrbWarmSyncCoordinator.shared.notePresentationHint(
                    missionId: id,
                    kind: kind,
                    btwParentId: data["btw_parent_id"] as? String
                )
                if kind == "mission_activity" {
                    if recent.contains(id), let label = data["label"] as? String {
                        if labels.count >= 48 { labels.removeAll() }
                        labels[scope + ":" + id] = String(label.prefix(160))
                    }
                    return
                }
                labels[scope + ":" + id] = nil
                listChanged = true
                if recent.contains(id) && !OrbWarmSyncCoordinator.shared.isMissionWarmLive(id) {
                    pending.insert(id)
                }
            }
            // Reconcile after a real reconnect, not on a polling timer.
            var closed = false
            let completion = Task { await stream.value; closed = true }
            pending.formUnion(recent)
            while !Task.isCancelled && account == scope && !closed {
                if listChanged {
                    listChanged = false
                    NotificationCenter.default.post(name: Notification.Name("OrbPresentationChanged"), object: nil)
                }
                let ids = Array(pending.prefix(3)); pending.subtract(ids)
                for id in ids { _ = await load(id) }
                try? await Task.sleep(for: .seconds(1))
            }
            stream.cancel(); completion.cancel()
            if !Task.isCancelled { try? await Task.sleep(for: .seconds(2)) }
        }
    }
}
