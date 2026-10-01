import SwiftUI

struct OrbSSHAddress: Codable, Identifiable, Equatable {
    var id = ""
    var revision = 0
    var name = ""
    var host = ""
    var user = "ubuntu"
    var port = 22
    var note = ""
    var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 200
        && !host.isEmpty && host.count <= 253 && !host.hasPrefix("-")
        && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-:[]_".contains($0)) }
        && !user.isEmpty && user.count <= 128 && !user.hasPrefix("-")
        && user.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        && (1...65535).contains(port) && note.count <= 2000
    }
    var body: OrbJSON { .object(["name": .string(name), "host": .string(host), "user": .string(user), "port": .number(Double(port)), "note": .string(note), "revision": .number(Double(revision))]) }
}

struct OrbMachinesSettings: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var client = OrbSettingsClient()
    @State private var nodes: [OrbJSON] = []
    @State private var addresses: [OrbSSHAddress] = []
    @State private var ready = false
    @State private var fleetReady = false
    @State private var loading = false
    @State private var error = ""
    @State private var fleetError = ""
    @State private var editing: OrbSSHAddress?
    @State private var busy = false
    private let path = "/api/settings/ssh-hosts"
    private var cacheKey: String { "orb.sshHosts:" + client.endpoint }
    var body: some View {
        List {
            OrbSettingsError(message: fleetError)
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
            OrbSettingsError(message: error)
            Section {
                ForEach(addresses) { address in
                    Button { editing = address } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(address.name).foregroundStyle(.primary)
                            Text("\(address.user)@\(address.host):\(address.port)").font(.caption).foregroundStyle(.secondary)
                            if !address.note.isEmpty { Text(address.note).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.disabled(!ready).accessibilityIdentifier("ssh.\(address.id)")
                }
                if ready && addresses.isEmpty { Text("No SSH addresses yet.").foregroundStyle(.secondary) }
                Button("Add SSH address", systemImage: "plus") { editing = OrbSSHAddress() }.disabled(!ready)
                    .accessibilityIdentifier("ssh.add")
            } header: { Text("SSH address book") } footer: { Text("Shared with Orb desktop through this backend. An address does not register an execution node.") }
        }
        .scrollContentBackground(.hidden).background(OrbStyle.background)
        .navigationTitle("Machines").navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading) }
        .task {
            if let data = UserDefaults.standard.data(forKey: cacheKey), let cached = try? JSONDecoder().decode([OrbSSHAddress].self, from: data) { addresses = cached }
            await load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
                if scenePhase == .active { await load() }
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load() } } }
        .sheet(item: $editing) { address in OrbSSHAddressEditor(address: address, client: client) { Task { await load() } } }
    }
    @ViewBuilder private func resource(_ title: String, total: OrbJSON, available: OrbJSON) -> some View {
        if let total = total.number, let available = available.number, total > 0 {
            LabeledContent(title, value: "\(((total - available) / 1073741824).formatted(.number.precision(.fractionLength(1)))) / \((total / 1073741824).formatted(.number.precision(.fractionLength(1)))) GiB")
        } else { LabeledContent(title, value: "Unavailable") }
    }
    private func load() async {
        guard !loading, client.current else { return }; loading = true
        defer { loading = false }
        do {
            let value = try await client.call("/api/remote-nodes")
            nodes = value["nodes"].items; fleetReady = true; fleetError = ""
        } catch is CancellationError { return }
        catch { fleetReady = false; fleetError = "Fleet unavailable. \(error.localizedDescription)" }
        do {
            let value = try await client.call(path)
            addresses = try JSONDecoder().decode([OrbSSHAddress].self, from: JSONEncoder().encode(value))
            ready = true; error = ""
            UserDefaults.standard.set(try JSONEncoder().encode(addresses), forKey: cacheKey)
        } catch is CancellationError { return }
        catch let failure as OrbHTTPError where failure.status == 404 { ready = false; error = "Update this backend to use the shared SSH address book." }
        catch { ready = false; self.error = "Could not refresh SSH addresses. The last snapshot is read-only. \(error.localizedDescription)" }
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

struct OrbSSHAddressEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var address: OrbSSHAddress
    let client: OrbSettingsClient
    let onSaved: () -> Void
    @State private var busy = false
    @State private var error = ""
    @State private var conflict = false
    @State private var confirmDelete = false
    var body: some View {
        NavigationStack {
            Form {
                OrbSettingsError(message: error)
                if conflict { Button("Close and reload") { onSaved(); dismiss() } }
                Section {
                    TextField("Name", text: $address.name).accessibilityIdentifier("ssh.name")
                    TextField("Host", text: $address.host).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("ssh.host")
                    TextField("User", text: $address.user).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port", value: $address.port, format: .number.grouping(.never)).keyboardType(.numberPad)
                    TextField("Note", text: $address.note, axis: .vertical)
                }.disabled(busy || conflict)
                if !address.id.isEmpty { Section { Button("Delete address", role: .destructive) { confirmDelete = true }.disabled(busy || conflict) } }
            }
            .navigationTitle(address.id.isEmpty ? "Add SSH address" : "SSH address").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save(delete: false) } }.disabled(!address.valid || busy || conflict) }
            }
            .confirmationDialog("Delete this address from all connected devices?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await save(delete: true) } }
            }
        }.interactiveDismissDisabled(busy)
    }
    private func save(delete: Bool) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let base = "/api/settings/ssh-hosts"
        let path = address.id.isEmpty ? base : base + "/" + OrbCore.escape(address.id)
        do {
            _ = try await client.call(delete ? path + "?revision=\(address.revision)" : path, method: delete ? "DELETE" : address.id.isEmpty ? "POST" : "PUT", body: delete ? nil : address.body)
            onSaved(); dismiss()
        } catch is CancellationError { error = "Backend changed. Close and reopen this page."; conflict = true }
        catch let failure as OrbHTTPError where [404,409].contains(failure.status) { error = "This address changed or was removed. Reload before editing."; conflict = true }
        catch { self.error = error.localizedDescription }
    }
}
