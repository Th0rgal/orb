import Foundation
import SwiftUI

/// Fleet harness software inventory & readiness model mirroring `orb/src/softwareInventory.ts`.
struct OrbSoftwareLaunch: Codable, Equatable, Sendable {
    var session: String
    var harness: String
    var version: String?
    var runner: String
    var started_at: Double
    var pid: Int
}

struct OrbSoftwareComponent: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var version: String?
    var path: String?
    var installed: Bool
    var owner: String
    var update_supported: Bool
    var latest: String?
    var release_error: String?
    var running: [OrbSoftwareLaunch]
    var instructions: String
    var ready: Bool?
    var ready_detail: String?
}

struct OrbSoftwareJob: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var component: String
    var version: String
    var path: String
    var state: String
    var error: String?
    var created_at: Double?
    var updated_at: Double?
}

struct OrbSoftwareRuntime: Codable, Equatable, Sendable {
    var name: String
    var version: String
    var build: String
    var path: String?
    var restart_required: Bool
    var running: [OrbSoftwareLaunch]?
}

struct OrbSoftwareInventory: Codable, Equatable, Sendable {
    var checked_at: Double
    var components: [OrbSoftwareComponent]
    var runtime: OrbSoftwareRuntime
    var jobs: [OrbSoftwareJob]
}

struct OrbSoftwareMachine: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var online: Bool
    var inventory: OrbSoftwareInventory?
    var error: String?
}

enum OrbSoftwareStatusTone: Equatable, Sendable {
    case normal
    case attention
    case failed
}

enum OrbAgentSoftware {
    static func decode(_ data: Data) throws -> OrbSoftwareInventory {
        try JSONDecoder().decode(OrbSoftwareInventory.self, from: data)
    }

    static func decode(_ json: OrbJSON) throws -> OrbSoftwareInventory {
        try decode(JSONEncoder().encode(json))
    }

    static func softwareVersion(_ raw: String?) -> [Int]? {
        guard let raw else { return nil }
        for token in raw.split(whereSeparator: \.isWhitespace) {
            let trimmed = token.hasPrefix("v") ? token.dropFirst() : token[...]
            let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count == 3, let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]) {
                return [a, b, c]
            }
        }
        return nil
    }

    static func displayVersion(_ raw: String?) -> String {
        if let parsed = softwareVersion(raw) {
            return parsed.map(String.init).joined(separator: ".")
        }
        if let raw, !raw.isEmpty { return raw }
        return "—"
    }

    static func newer(_ latest: String?, _ current: String?) -> Bool {
        guard let a = softwareVersion(latest), let b = softwareVersion(current) else { return false }
        for i in 0..<3 where a[i] != b[i] {
            return a[i] > b[i]
        }
        return false
    }

    static func matchesSoftwareJob(_ job: OrbSoftwareJob, _ row: OrbSoftwareComponent) -> Bool {
        job.component == row.id && ((row.path ?? "").isEmpty || job.path == row.path)
    }

    static func canInstallSoftware(_ row: OrbSoftwareComponent) -> Bool {
        !row.installed && row.update_supported && !(row.latest ?? "").isEmpty
    }

    static func canUpdateSoftware(_ row: OrbSoftwareComponent) -> Bool {
        row.installed && row.update_supported && !(row.path ?? "").isEmpty && newer(row.latest, row.version)
    }

    static func activeJob(in inventory: OrbSoftwareInventory?, for row: OrbSoftwareComponent) -> OrbSoftwareJob? {
        inventory?.jobs.last(where: { matchesSoftwareJob($0, row) })
    }

    static func availableSoftwareUpdates(_ machines: [OrbSoftwareMachine]) -> [(machine: OrbSoftwareMachine, row: OrbSoftwareComponent)] {
        machines.compactMap { machine -> [(OrbSoftwareMachine, OrbSoftwareComponent)]? in
            guard machine.online, (machine.error ?? "").isEmpty, let inv = machine.inventory else { return nil }
            return inv.components.compactMap { row in
                guard canUpdateSoftware(row) || canInstallSoftware(row) else { return nil }
                let blocked = inv.jobs.contains { matchesSoftwareJob($0, row) && ($0.state == "queued" || $0.state == "installing") }
                return blocked ? nil : (machine, row)
            }
        }.flatMap { $0 }
    }

    static func softwareAttentionSummary(_ machines: [OrbSoftwareMachine]) -> String {
        let restarts = machines.filter { $0.inventory?.runtime.restart_required == true }.count
        let missing = machines.reduce(0) { $0 + ($1.inventory?.components.filter { !$0.installed }.count ?? 0) }
        let unready = machines.reduce(0) { $0 + ($1.inventory?.components.filter { $0.installed && $0.ready == false }.count ?? 0) }
        let updates = machines.reduce(0) { $0 + ($1.inventory?.components.filter { $0.installed && newer($0.latest, $0.version) }.count ?? 0) }
        return [
            restarts > 0 ? "\(restarts) restart\(restarts == 1 ? "" : "s") needed" : "",
            missing > 0 ? "\(missing) missing" : "",
            unready > 0 ? "\(unready) setup needed" : "",
            updates > 0 ? "\(updates) update\(updates == 1 ? "" : "s")" : ""
        ].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func componentStatus(_ row: OrbSoftwareComponent, job: OrbSoftwareJob?) -> (label: String, tone: OrbSoftwareStatusTone) {
        if job?.state == "queued" { return ("Waiting for \(row.name) sessions", .normal) }
        if job?.state == "installing" { return (row.installed ? "Updating…" : "Installing…", .normal) }
        if job?.state == "failed" { return (row.installed ? "Update failed" : "Install failed", .failed) }
        let installable = canInstallSoftware(row)
        if !row.installed {
            return (installable ? "Not installed · \(row.latest ?? "")" : "Not installed", installable ? .attention : .normal)
        }
        if row.release_error != nil { return ("Version check unavailable", .normal) }
        if softwareVersion(row.version) == nil { return ("Version unknown", .normal) }
        if newer(row.latest, row.version) { return ("→ \(row.latest ?? "")", .attention) }
        if row.ready == false { return ("Setup required", .attention) }
        if (row.latest ?? "").isEmpty { return (row.ready == true ? "Ready" : "Release unknown", .normal) }
        return ("Up to date", .normal)
    }
}

struct OrbAgentSoftwareSection: View {
    let nodes: [OrbJSON]
    let reloadToken: Int
    @State private var client = OrbSettingsClient()
    @State private var machines: [OrbSoftwareMachine] = []
    @State private var refreshing = false
    @State private var expanded = false
    @State private var busyKey: String?
    @State private var actionError = ""

    var body: some View {
        let summary = OrbAgentSoftware.softwareAttentionSummary(machines)
        let actions = OrbAgentSoftware.availableSoftwareUpdates(machines)
        let hasInstalls = actions.contains { !$0.row.installed }
        Section("Agent software") {
            DisclosureGroup(isExpanded: $expanded) {
                if !actionError.isEmpty {
                    Text(actionError).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    if !actions.isEmpty {
                        Button(busyKey == "__all__" ? "Queuing…" : (hasInstalls ? "Install & update all" : "Update all")) {
                            Task { await updateAll(actions) }
                        }
                        .disabled(busyKey != nil || refreshing)
                    }
                    Spacer()
                    Button(refreshing ? "Checking…" : "Check versions") {
                        Task { await refresh(force: true) }
                    }
                    .font(.caption)
                    .disabled(refreshing || busyKey != nil)
                }
                if machines.isEmpty && refreshing {
                    ProgressView()
                }
                ForEach(machines) { machine in
                    DisclosureGroup {
                        if let err = machine.error, !err.isEmpty {
                            Text(err).font(.caption).foregroundStyle(.secondary)
                        }
                        if let inv = machine.inventory {
                            ForEach(inv.components) { row in
                                componentRow(machine: machine, inv: inv, row: row)
                            }
                            LabeledContent(inv.runtime.name, value: inv.runtime.restart_required ? "Restart required" : inv.runtime.version)
                                .font(.caption)
                                .foregroundStyle(inv.runtime.restart_required ? .orange : .secondary)
                        }
                    } label: {
                        HStack {
                            Text(machine.name)
                            Spacer()
                            Text(machineSubtitle(machine))
                                .font(.caption)
                                .foregroundStyle(machineNeedsAttention(machine) ? .orange : .secondary)
                        }
                    }
                }
            } label: {
                HStack {
                    Text("Versions and readiness")
                    Spacer()
                    Text(summary.isEmpty ? (machines.isEmpty ? (refreshing ? "Checking…" : "") : "All ready") : summary)
                        .font(.caption)
                        .foregroundStyle(summary.isEmpty ? Color.secondary : Color.orange)
                }
            }
        }
        .task(id: reloadToken) {
            await refresh(force: false)
        }
    }

    @ViewBuilder
    private func componentRow(machine: OrbSoftwareMachine, inv: OrbSoftwareInventory, row: OrbSoftwareComponent) -> some View {
        let job = OrbAgentSoftware.activeJob(in: inv, for: row)
        let pending = job?.state == "queued" || job?.state == "installing"
        let status = OrbAgentSoftware.componentStatus(row, job: job)
        let actionable = !pending && (OrbAgentSoftware.canInstallSoftware(row) || OrbAgentSoftware.canUpdateSoftware(row))
        let rowKey = "\(machine.id):\(row.id)"
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(row.name).font(.subheadline)
                Text(OrbAgentSoftware.displayVersion(row.version))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(status.label)
                    .font(.caption)
                    .foregroundStyle(status.tone == .failed ? .red : status.tone == .attention ? .orange : .secondary)
            }
            if let detail = row.ready_detail, !detail.isEmpty, (!row.installed || row.ready == false) {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            if let err = job?.error, !err.isEmpty {
                Text(err).font(.caption2).foregroundStyle(.red)
            }
            if machine.online && (machine.error ?? "").isEmpty {
                HStack(spacing: 12) {
                    if job?.state == "queued", let jobID = job?.id {
                        Button("Cancel") { Task { await cancelJob(machineID: machine.id, jobID: jobID, key: rowKey) } }
                            .font(.caption)
                            .disabled(busyKey != nil)
                    }
                    if actionable {
                        Button(busyKey == rowKey ? "Queuing…" : (job?.state == "failed" ? "Retry" : (row.installed ? "Update" : "Install"))) {
                            Task { await queueAction(machineID: machine.id, row: row, key: rowKey) }
                        }
                        .font(.caption.weight(.medium))
                        .disabled(busyKey != nil)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func machineNeedsAttention(_ machine: OrbSoftwareMachine) -> Bool {
        guard let inv = machine.inventory else { return false }
        if inv.runtime.restart_required { return true }
        return inv.components.contains { !$0.installed || $0.ready == false || OrbAgentSoftware.newer($0.latest, $0.version) }
    }

    private func machineSubtitle(_ machine: OrbSoftwareMachine) -> String {
        if let err = machine.error, !err.isEmpty { return err }
        if !machine.online { return "Offline" }
        guard let inv = machine.inventory else { return "Checking…" }
        let installedCount = inv.components.filter(\.installed).count
        let singleSummary = OrbAgentSoftware.softwareAttentionSummary([machine])
        return singleSummary.isEmpty ? "\(installedCount)/\(inv.components.count) ready" : singleSummary
    }

    private func refresh(force: Bool) async {
        guard !refreshing, client.current else { return }
        refreshing = true
        defer { refreshing = false }
        var targets: [OrbSoftwareMachine] = [OrbSoftwareMachine(id: "core", name: "Core", online: true)]
        for node in nodes where !OrbManaged.isManagedNode(node) {
            let id = node["id"].text
            guard !id.isEmpty else { continue }
            targets.append(OrbSoftwareMachine(id: id, name: OrbManaged.nodeTitle(node), online: node["status"].text == "online"))
        }
        let previous = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, $0) })
        let activeClient = client
        let loaded = await withTaskGroup(of: (Int, OrbSoftwareMachine).self) { group in
            for (idx, target) in targets.enumerated() {
                let old = previous[target.id]
                group.addTask {
                    guard target.online else {
                        return (idx, OrbSoftwareMachine(id: target.id, name: target.name, online: false, inventory: old?.inventory, error: "Offline"))
                    }
                    let suffix = target.id == "core" ? "" : "&node=\(OrbCore.escape(target.id))"
                    do {
                        let json = try await activeClient.call("/api/software?force=\(force ? "true" : "false")\(suffix)")
                        let inv = try await MainActor.run { try OrbAgentSoftware.decode(json) }
                        return (idx, OrbSoftwareMachine(id: target.id, name: target.name, online: true, inventory: inv, error: nil))
                    } catch {
                        return (idx, OrbSoftwareMachine(id: target.id, name: target.name, online: true, inventory: old?.inventory, error: "Inventory unavailable"))
                    }
                }
            }
            var pairs: [(Int, OrbSoftwareMachine)] = []
            for await item in group { pairs.append(item) }
            return pairs.sorted { $0.0 < $1.0 }.map(\.1)
        }
        guard client.current else { return }
        machines = loaded
    }

    private func queueAction(machineID: String, row: OrbSoftwareComponent, key: String) async {
        guard busyKey == nil, let latest = row.latest else { return }
        busyKey = key; actionError = ""
        defer { busyKey = nil }
        let suffix = machineID == "core" ? "" : "?node=\(OrbCore.escape(machineID))"
        let body: OrbJSON = .object([
            "component": .string(row.id),
            "version": .string(latest),
            "path": .string(row.path ?? "")
        ])
        do {
            _ = try await client.call("/api/software/updates\(suffix)", method: "POST", body: body)
            await refresh(force: false)
        } catch is CancellationError {}
        catch { actionError = error.localizedDescription }
    }

    private func cancelJob(machineID: String, jobID: String, key: String) async {
        guard busyKey == nil else { return }
        busyKey = key; actionError = ""
        defer { busyKey = nil }
        let suffix = machineID == "core" ? "" : "?node=\(OrbCore.escape(machineID))"
        do {
            _ = try await client.call("/api/software/updates/cancel\(suffix)", method: "POST", body: .object(["id": .string(jobID)]))
            await refresh(force: false)
        } catch is CancellationError {}
        catch { actionError = error.localizedDescription }
    }

    private func updateAll(_ items: [(machine: OrbSoftwareMachine, row: OrbSoftwareComponent)]) async {
        guard busyKey == nil else { return }
        busyKey = "__all__"; actionError = ""
        defer { busyKey = nil }
        var failures: [String] = []
        for item in items {
            guard let latest = item.row.latest else { continue }
            let suffix = item.machine.id == "core" ? "" : "?node=\(OrbCore.escape(item.machine.id))"
            let body: OrbJSON = .object([
                "component": .string(item.row.id),
                "version": .string(latest),
                "path": .string(item.row.path ?? "")
            ])
            do {
                _ = try await client.call("/api/software/updates\(suffix)", method: "POST", body: body)
            } catch {
                failures.append("\(item.machine.name) · \(item.row.name)")
            }
        }
        await refresh(force: false)
        if !failures.isEmpty {
            actionError = "Could not queue: \(failures.joined(separator: ", "))"
        }
    }
}
