import SwiftUI

struct OrbMachinesSettings: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var client = OrbSettingsClient()
    @State private var nodes: [OrbJSON] = []
    @State private var fleetReady = false
    @State private var loading = false
    @State private var fleetError = ""
    @State private var busy = false
    @State private var computers: [OrbJSON] = []
    @State private var computersReady = false
    @State private var startedMission: String?
    @State private var managed: OrbManagedMachinesResponse?
    @State private var managedFetchedAt = Date.now
    @State private var managedBusy = false
    @State private var busyProvider: String?
    var body: some View {
        List {
            OrbSettingsError(message: fleetError)
            OrbComputersSection(computers: computers, ready: computersReady) { startedMission = $0 }
            if let providers = managed?.providers, !providers.isEmpty {
                OrbMachineProvidersSection(
                    providers: providers,
                    busyProvider: busyProvider,
                    onToggle: { pr, next in Task { await toggleProvider(pr, enabled: next) } },
                    onSave: { id, patch in try await saveProvider(id, patch: patch) }
                )
            }
            if let managed, managed.enabled {
                OrbManagedMachinesSection(response: managed, fetchedAt: managedFetchedAt, busy: managedBusy,
                                          onDestroy: { m in Task { await destroy(m) } },
                                          onExtend: { m in Task { await managedAction { _ = try await client.call("/api/managed-machines/\(OrbCore.escape(m.id))/extend", method: "POST", body: .object(["ttl_minutes": .number(60)])) } } },
                                          onStop: { m in Task { await managedAction { _ = try await client.call("/api/managed-machines/\(OrbCore.escape(m.id))/stop", method: "POST", body: .object([:])) } } },
                                          onResume: { m in Task { await managedAction { _ = try await client.call("/api/managed-machines/\(OrbCore.escape(m.id))/resume", method: "POST", body: .object([:])) } } },
                                          onCreate: { provider, size, ttl, allow24h in
                                              Task {
                                                  await managedAction {
                                                      var body: [String: OrbJSON] = ["size": .string(size), "ttl_minutes": .number(Double(ttl)), "wait": .bool(false)]
                                                      if let provider { body["provider"] = .string(provider) }
                                                      if allow24h { body["allow_24h_commitment"] = .bool(true) }
                                                      _ = try await client.call("/api/managed-machines", method: "POST", body: .object(body))
                                                  }
                                              }
                                          },
                                          onOpenMission: { startedMission = $0 })
            }
            Section("Fleet") {
                let fleetNodes = managed == nil ? nodes : nodes.filter { !OrbManaged.isManagedNode($0) }
                if loading && fleetNodes.isEmpty { ProgressView() }
                if fleetReady && fleetNodes.isEmpty { Text("No static fleet nodes registered.").foregroundStyle(.secondary) }
                ForEach(fleetNodes, id: \.selfID) { node in
                    DisclosureGroup {
                        LabeledContent("Status", value: node["status"].text)
                        LabeledContent("Active jobs", value: node["active_jobs"].display.isEmpty ? "Unavailable" : node["active_jobs"].display)
                        resource("Memory", total: node["mem_total_bytes"], available: node["mem_available_bytes"])
                        resource("Disk", total: node["disk_total_bytes"], available: node["disk_available_bytes"])
                        let sample = node["resource_history"].items.last ?? .null
                        if let cpu = sample["cpu"].number { LabeledContent("CPU", value: "\(Int(cpu))%") }
                        else if let cores = node["cpu_total"].number { LabeledContent("CPU", value: "\(Int(cores)) cores") }
                        if let gpu = sample["gpu"].number { LabeledContent("GPU", value: "\(Int(gpu))%") }
                        Button(node["cordoned"].flag ? "Allow new jobs" : "Pause new jobs") { Task { await toggle(node) } }
                            .disabled(busy || !fleetReady)
                    } label: {
                        VStack(alignment: .leading) {
                            HStack(spacing: 6) {
                                Text(OrbManaged.nodeTitle(node))
                                if OrbManaged.isManagedNode(node) {
                                    OrbManagedBadge()
                                    if let p = OrbManaged.nodeProvider(node), p != "boat" {
                                        Text(OrbManaged.providerLabel(p))
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            Text(node["status"].text + (node["cordoned"].flag ? " · New jobs paused" : "")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden).background(OrbStyle.background)
        .navigationTitle("Machines").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $startedMission) { OrbConversation(missionID: $0, project: "", folder: "") }
        .refreshable { await load() }
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading) }
        .task {
            await load()
            await Poller.run(every: .seconds(15), immediately: false, while: { scenePhase == .active }) { await load(); return true }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load() } } }
    }
    @ViewBuilder private func resource(_ title: String, total: OrbJSON, available: OrbJSON) -> some View {
        if let total = total.number, let available = available.number, total > 0 {
            LabeledContent(title, value: "\(((total - available) / 1073741824).formatted(.number.precision(.fractionLength(1)))) / \((total / 1073741824).formatted(.number.precision(.fractionLength(1)))) GiB")
        } else { LabeledContent(title, value: "Unavailable") }
    }
    private func load() async {
        guard !loading, client.current else { return }; loading = true
        defer { loading = false }
        // Computers are independent of the fleet: one failing never hides the other.
        if let value = try? await client.call("/api/control/client-computers") {
            computers = value["computers"].items; computersReady = true
        }
        await loadManaged()
        do {
            let value = try await client.call("/api/remote-nodes")
            nodes = value["nodes"].items; fleetReady = true; fleetError = ""
        } catch is CancellationError { return }
        catch { fleetReady = false; fleetError = "Fleet unavailable. \(error.localizedDescription)" }
    }
    /// Older backends (404/405) hide the section; other failures keep the last list.
    private func loadManaged() async {
        do {
            let value = try await client.call("/api/managed-machines")
            managed = try OrbManaged.decode(value); managedFetchedAt = .now
        } catch is CancellationError { return }
        catch where OrbManaged.isUnsupported(error) { managed = nil }
        catch { if managed != nil { fleetError = "Managed machines unavailable. \(OrbManaged.message(error))" } }
    }
    /// Optimistic: the row reads "Destroying…" at once; a failure restores it and shows the error.
    private func destroy(_ m: OrbManagedMachine) async {
        guard !managedBusy, let before = managed else { return }
        managedBusy = true; defer { managedBusy = false }
        managed = OrbManaged.markDestroying(before, id: m.id)
        do {
            _ = try await client.call("/api/managed-machines/\(OrbCore.escape(m.id))", method: "DELETE")
            fleetError = ""; await loadManaged()
        } catch is CancellationError {} catch { managed = before; fleetError = OrbManaged.message(error) }
    }
    private func managedAction(_ action: () async throws -> Void) async {
        guard !managedBusy else { return }; managedBusy = true; defer { managedBusy = false }
        do { try await action(); fleetError = ""; await loadManaged() }
        catch is CancellationError {} catch { fleetError = OrbManaged.message(error) }
    }
    /// Optimistic provider enable/disable toggle with rollback on failure.
    private func toggleProvider(_ pr: OrbManagedProviderInfo, enabled: Bool) async {
        guard busyProvider == nil, let before = managed else { return }
        busyProvider = pr.provider
        defer { busyProvider = nil }
        if var copy = managed, let idx = copy.providers?.firstIndex(where: { $0.provider == pr.provider }) {
            copy.providers?[idx].enabled = enabled
            managed = copy
        }
        do {
            _ = try await client.call("/api/managed-machines/providers/\(OrbCore.escape(pr.provider))", method: "PUT", body: .object(["enabled": .bool(enabled)]))
            fleetError = ""
            await loadManaged()
        } catch is CancellationError {}
        catch {
            managed = before
            fleetError = OrbManaged.message(error)
        }
    }
    private func saveProvider(_ id: String, patch: [String: OrbJSON]) async throws {
        _ = try await client.call("/api/managed-machines/providers/\(OrbCore.escape(id))", method: "PUT", body: .object(patch))
        fleetError = ""
        await loadManaged()
    }
    private func toggle(_ node: OrbJSON) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            _ = try await client.call("/api/nodes/\(OrbCore.escape(node["id"].text))/\(node["cordoned"].flag ? "uncordon" : "cordon")", method: "POST")
            await load()
        } catch is CancellationError {} catch { fleetError = error.localizedDescription }
    }
}

extension OrbJSON { var selfID: String { self["id"].text } }
