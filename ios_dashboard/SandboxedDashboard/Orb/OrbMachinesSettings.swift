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
    var body: some View {
        List {
            OrbSettingsError(message: fleetError)
            OrbComputersSection(computers: computers, ready: computersReady) { startedMission = $0 }
            Section("Fleet") {
                if loading && nodes.isEmpty { ProgressView() }
                if fleetReady && nodes.isEmpty { Text("No remote nodes registered.").foregroundStyle(.secondary) }
                ForEach(nodes, id: \.selfID) { node in
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
                            Text(node["id"].text)
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
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
                if scenePhase == .active { await load() }
            }
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
        do {
            let value = try await client.call("/api/remote-nodes")
            nodes = value["nodes"].items; fleetReady = true; fleetError = ""
        } catch is CancellationError { return }
        catch { fleetReady = false; fleetError = "Fleet unavailable. \(error.localizedDescription)" }
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
