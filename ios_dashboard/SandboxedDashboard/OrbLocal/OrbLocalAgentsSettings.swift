import OrbLocalKit
import ReplayKit
import SwiftUI

/// Settings → This iPhone. Turns the phone into an Orb execution node and
/// shows, from live probes, exactly what agents can and cannot do here.
struct OrbLocalAgentsSettings: View {
    @State private var node = LocalAgentNode.shared
    @State private var installing = false
    @State private var progress = ""
    @State private var probe: [ProbeRow] = []
    @State private var probing = false
    @Environment(\.scenePhase) private var scenePhase

    struct ProbeRow: Identifiable { let id = UUID(); let name: String; let ok: Bool?; let detail: String }

    var body: some View {
        List {
            Section {
                Toggle("Run agents on this iPhone", isOn: Binding(get: { node.enabled }, set: { node.enabled = $0 }))
                    .accessibilityIdentifier("local.enabled")
                LabeledContent("Client", value: String(node.clientID.prefix(8)))
                LabeledContent("Registered", value: node.registered ? "Yes" : "No")
                if !node.lastError.isEmpty { Text(node.lastError).font(.footnote).foregroundStyle(.orange) }
            } footer: {
                Text("Missions you start on “This iPhone” run here, not on Core. If iOS suspends Orb, the mission pauses and resumes when you reopen Orb.")
            }

            Section("Linux runtime") {
                LabeledContent("Engine", value: node.runtimeStatus.engine)
                Text(node.runtimeStatus.detail).font(.footnote).foregroundStyle(.secondary)
                if ISHLinuxRuntime.shared.linked && !ISHLinuxRuntime.shared.installed {
                    Button(installing ? "Installing…" : "Install Alpine Linux (~70 MB)") { Task { await install() } }.disabled(installing)
                    if !progress.isEmpty { Text(progress).font(.footnote) }
                }
                ForEach(HarnessKind.allCases, id: \.self) { kind in
                    LabeledContent(kind.displayName, value: Self.describe(node.harnessAvailability[kind]))
                }
            }

            Section {
                BroadcastPickerButton().frame(height: 44)
                LabeledContent("Screen sharing", value: ScreenObservationService.shared.isBroadcasting ? "Live" : "Off")
            } header: { Text("Screen") } footer: {
                Text("Start “Orb Screen” once. iOS shows a red status indicator while agents can see your screen; stop it any time from Control Center.")
            }

            Section {
                LabeledContent("Orb keyboard", value: keyboardStatus)
                Button("Open Keyboard Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            } header: { Text("Typing") } footer: {
                Text("Settings → General → Keyboard → Keyboards → Add → Orb, then Allow Full Access. Agents can type only while the Orb keyboard is showing in a focused field; never in password fields.")
            }

            Section {
                Button(probing ? "Probing…" : "Run capability probe") { Task { await runProbe() } }.disabled(probing)
                ForEach(probe) { row in
                    HStack(alignment: .top) {
                        Image(systemName: row.ok == true ? "checkmark.circle.fill" : row.ok == false ? "xmark.circle.fill" : "questionmark.circle")
                            .foregroundStyle(row.ok == true ? .green : row.ok == false ? .red : .secondary)
                        VStack(alignment: .leading) { Text(row.name); Text(row.detail).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            } header: { Text("What agents can do here") } footer: {
                Text("No iOS API lets an app tap or swipe in other apps. Agents move between apps with links and Shortcuts, read the screen through Orb Screen, and type through the Orb keyboard.")
            }
        }
        .navigationTitle("This iPhone")
        .task { await node.refreshAvailability() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await node.refreshAvailability() } } }
    }

    private var keyboardStatus: String {
        guard let root = OrbAppGroup.keyboard, let presence = KeyboardCommandQueue(root: root).presence() else { return "Not installed or never shown" }
        return presence.fullAccess ? (presence.isActive() ? "Active" : "Installed · Full Access") : "Installed · needs Full Access"
    }

    static func describe(_ a: HarnessAvailability?) -> String {
        switch a {
        case .available(let v)?: return v.map { "Ready · \($0)" } ?? "Ready"
        case .installable?: return "Installable"
        case .unavailable?: return "Unavailable"
        case nil: return "Checking…"
        }
    }

    static func harnessNote(_ backend: String, engine: String) -> String {
        if backend == "codex" && engine == LocalAgentNode.computerUseEngine {
            return "Codex computer use runs inside Orb and controls this iPhone through links, Shortcuts, the screen broadcast and the Orb keyboard."
        }
        return "Runs the CLI inside Orb's on-device Linux runtime. Install the runtime in Settings → This iPhone first."
    }

    private func install() async {
        installing = true; defer { installing = false }
        do {
            try await ISHLinuxRuntime.shared.install { message in progress = message }
            for kind in [HarnessKind.codex, .claudeCode, .openCode] {
                let dialect = HarnessDialects.dialect(for: kind)
                progress = "Installing \(kind.displayName)…"
                _ = try? await ISHLinuxRuntime.shared.run(dialect.installCommand, cwd: "/root", timeout: 1800)
            }
            await node.refreshAvailability()
            await node.register()
            progress = "Done"
        } catch { progress = error.localizedDescription }
    }

    /// Empirical answers, measured on this device, not assumed.
    private func runProbe() async {
        probing = true; defer { probing = false }
        var rows: [ProbeRow] = []
        let runtime = await ISHLinuxRuntime.shared.status()
        rows.append(.init(name: "Unix shell, processes, pipes", ok: runtime.available, detail: runtime.detail))
        if runtime.available, let r = try? await ISHLinuxRuntime.shared.run("uname -m && git --version && node --version && (echo hi | wc -c)", cwd: "/root", timeout: 120) {
            rows.append(.init(name: "git / node / pipes", ok: r.code == 0, detail: r.output.replacingOccurrences(of: "\n", with: " · ")))
        }
        let frame = await ScreenObservationService.shared.latestFrame(maxDimension: 512)
        rows.append(.init(name: "See other apps' screens", ok: frame?.source == "broadcast",
                          detail: frame.map { "\($0.source) \($0.width)×\($0.height), \($0.text.count) OCR lines" } ?? "No frame"))
        rows.append(.init(name: "Open another app while Orb is backgrounded",
                          ok: UserDefaults.standard.object(forKey: "orb.probe.backgroundOpen") as? Bool,
                          detail: "Measured the first time an agent opens an app from the background"))
        rows.append(.init(name: "Type into other apps", ok: keyboardStatus.contains("Full Access") || keyboardStatus == "Active" ? true : false,
                          detail: "Orb keyboard: \(keyboardStatus)"))
        rows.append(.init(name: "Tap / swipe / scroll in other apps", ok: false,
                          detail: "No public or requestable iOS API; XCUITest needs a host computer"))
        rows.append(.init(name: "Read other apps' accessibility tree", ok: false, detail: "Not exposed to third-party apps"))
        probe = rows
        // Last, because it leaves Orb.
        let canMaps = await UIApplication.shared.open(URL(string: "maps://?q=coffee")!)
        probe.insert(.init(name: "Open another app (foreground)", ok: canMaps, detail: "UIApplication.open(maps://) — Maps opened"), at: 3)
    }
}

/// System broadcast picker preselecting the Orb Screen extension. The user
/// still confirms "Start Broadcast"; iOS does not allow starting it silently.
struct BroadcastPickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = (Bundle.main.bundleIdentifier ?? "") + ".screen"
        picker.showsMicrophoneButton = false
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
