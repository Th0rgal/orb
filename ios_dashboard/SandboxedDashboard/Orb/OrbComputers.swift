import SwiftUI

/// Orb desktop computers linked to this account (`/api/control/client-computers`).
/// An online computer can be asked to start a mission; it runs there exactly as
/// if it had been started on that computer, and streams back to every client.
struct OrbComputersSection: View {
    let computers: [OrbJSON]
    let ready: Bool
    let onStarted: (String) -> Void
    @State private var starting: StartTarget?

    var body: some View {
        Section {
            if ready && computers.isEmpty {
                Text("No computers connected. Open Orb on a Mac signed in to this account.")
                    .foregroundStyle(.secondary)
            }
            ForEach(computers, id: \.computerID) { computer in
                HStack {
                    Circle()
                        .fill(computer["online"].flag ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text(computer["name"].text.isEmpty ? "Computer" : computer["name"].text)
                        Text(computer["online"].flag ? "Online" : "Offline · missions paused")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if computer["online"].flag {
                        Button("Start") { starting = StartTarget(id: computer.computerID, computer: computer) }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Start a mission on \(computer["name"].text)")
                    }
                }
            }
        } header: {
            Text("Computers")
        } footer: {
            Text("Missions started here run on that computer with its local agents.")
        }
        .sheet(item: $starting) { target in
            OrbRemoteStartSheet(computer: target.computer) { missionID in
                starting = nil
                onStarted(missionID)
            }
        }
    }
}

/// Prompt + harness/model picker for a start on one computer.
struct OrbRemoteStartSheet: View {
    let computer: OrbJSON
    let onStarted: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var client = OrbSettingsClient()
    @State private var prompt = ""
    @State private var backend = ""
    @State private var model = ""
    @State private var busy = false
    @State private var error = ""

    private var harnesses: [OrbJSON] { computer["harnesses"].items }
    private var models: [OrbJSON] {
        harnesses.first { $0["backend"].text == backend }?["models"].items ?? []
    }

    var body: some View {
        NavigationStack {
            Form {
                OrbSettingsError(message: error)
                Section("Prompt") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 120)
                        .accessibilityLabel("Prompt")
                }
                Section("Agent") {
                    if harnesses.isEmpty {
                        Text("This computer has not reported its local agents yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Harness", selection: $backend) {
                            ForEach(harnesses, id: \.backendID) { h in
                                Text(h["name"].text.isEmpty ? h["backend"].text : h["name"].text).tag(h["backend"].text)
                            }
                        }
                        if !models.isEmpty {
                            Picker("Model", selection: $model) {
                                ForEach(models, id: \.modelID) { m in
                                    Text(m["label"].text.isEmpty ? m["value"].text : m["label"].text).tag(m["value"].text)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(computer["name"].text.isEmpty ? "Start on computer" : "Start on \(computer["name"].text)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("Start") { Task { await start() } }
                            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || backend.isEmpty)
                    }
                }
            }
            .onAppear {
                if backend.isEmpty { backend = harnesses.first?["backend"].text ?? "" }
                if model.isEmpty { model = models.first?["value"].text ?? "" }
            }
            .onChange(of: backend) { _, _ in model = models.first?["value"].text ?? "" }
        }
        .interactiveDismissDisabled(busy)
    }

    private func start() async {
        guard !busy else { return }
        busy = true; error = ""
        defer { busy = false }
        var body: [String: OrbJSON] = [
            "prompt": .string(prompt),
            "backend": .string(backend),
        ]
        if !model.isEmpty { body["model_override"] = .string(model) }
        do {
            let id = OrbCore.escape(computer["client_id"].text)
            let result = try await client.call("/api/control/client-computers/\(id)/missions", method: "POST", body: .object(body))
            let missionID = result["mission_id"].text
            if missionID.isEmpty { error = "The computer did not return a mission." } else { onStarted(missionID) }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct StartTarget: Identifiable {
    let id: String
    let computer: OrbJSON
}

extension OrbJSON {
    var computerID: String { self["client_id"].text }
    var backendID: String { self["backend"].text }
    var modelID: String { self["value"].text }
}
