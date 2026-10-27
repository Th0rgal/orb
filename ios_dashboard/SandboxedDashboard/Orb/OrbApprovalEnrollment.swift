import SwiftUI

// MARK: - Approval device enrollment prompt

/// Asks the user to enroll this iPhone as an approval device when Core
/// requires device signatures (`warn` or `enforce`) and this phone's Secure
/// Enclave key is not on `GET /api/approvals/devices`. Without it, protected
/// actions such as exiting Fleet Bunker Mode cannot be signed from the phone.
/// Dismissing hides the prompt until Core's approval mode changes.
@MainActor
@Observable
final class OrbApprovalEnrollmentMonitor {
    static let shared = OrbApprovalEnrollmentMonitor()
    /// Run on the Core host; Core deletes the file when a device uses it.
    static let codeCommand =
        "ssh agent-core 'umask 077; head -c 12 /dev/urandom | base64 | tr -dc A-Za-z0-9 | tee /root/.sandboxed-sh/approval_enrollment_code; echo'"

    private(set) var mode = ""
    private(set) var enrolled = true
    private(set) var dismissedMode: String?
    var sheetRequested = false
    private var endpoint = ""

    var showsPrompt: Bool {
        Self.shouldPrompt(mode: mode, enrolled: enrolled, dismissedMode: dismissedMode)
    }

    /// Prompt only where Core asks for signatures and this key is not enrolled.
    nonisolated static func shouldPrompt(mode: String, enrolled: Bool, dismissedMode: String?) -> Bool {
        guard mode == "warn" || mode == "enforce" else { return false }
        return !enrolled && dismissedMode != mode
    }

    nonisolated static func isEnrolled(publicKey: String?, devices: [OrbJSON]) -> Bool {
        guard let publicKey, !publicKey.isEmpty else { return false }
        return devices.contains { $0["public_key"].text == publicKey }
    }

    private var dismissKey: String { "orb.approvalEnrollPromptDismissed.\(endpoint)" }

    func refresh() async {
        let current = OrbCore.shared.endpoint
        if current != endpoint {
            endpoint = current
            mode = ""
            enrolled = true
            dismissedMode = UserDefaults.standard.string(forKey: dismissKey)
        }
        guard let d = await Log.attempt(.network, "approval devices", { try await OrbCore.shared.call("/api/approvals/devices") }),
              current == OrbCore.shared.endpoint else { return }
        mode = d["mode"].text
        enrolled = Self.isEnrolled(publicKey: OrbApprovalKey.publicKey, devices: d["devices"].items)
    }

    func dismiss() {
        dismissedMode = mode
        UserDefaults.standard.set(mode, forKey: dismissKey)
    }

    func markEnrolled() { enrolled = true }
}

struct OrbApprovalEnrollmentBanner: View {
    @State private var monitor = OrbApprovalEnrollmentMonitor.shared

    var body: some View {
        if monitor.showsPrompt {
            HStack(spacing: 10) {
                Button { monitor.sheetRequested = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: OrbBiometric.name == "Touch ID" ? "touchid" : "faceid")
                            .foregroundStyle(OrbStyle.success)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enroll this iPhone for approvals").font(.footnote.weight(.semibold))
                            Text("Approve protected actions, like exiting Bunker Mode, with \(OrbBiometric.name).")
                                .font(.caption).foregroundStyle(OrbStyle.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.approval-enroll")
                Button { monitor.dismiss() } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(OrbStyle.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("home.approval-enroll.dismiss")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(OrbStyle.elevated, in: RoundedRectangle(cornerRadius: OrbStyle.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: OrbStyle.panelRadius).stroke(OrbStyle.borderStrong))
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
}

/// Explains the one-time code and enrolls this phone's key with it.
struct OrbApprovalEnrollmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var monitor = OrbApprovalEnrollmentMonitor.shared
    @State private var code = ""
    @State private var enrolling = false
    @State private var error = ""

    private var trimmed: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            List {
                OrbSettingsError(message: error)
                Section {
                    Text("Core accepts protected actions (secrets, privileged access, exiting Bunker Mode) only when an enrolled device signs them. This iPhone keeps its key in the Secure Enclave and signs after \(OrbBiometric.name).")
                        .font(.subheadline)
                }
                Section {
                    Text("Enrolling needs a one-time code. Create it on the Core host; Core deletes it once a device uses it.")
                        .font(.footnote)
                    Text(OrbApprovalEnrollmentMonitor.codeCommand)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = OrbApprovalEnrollmentMonitor.codeCommand
                        OrbHaptics.success()
                    } label: { Label("Copy command", systemImage: "doc.on.doc") }
                } header: { Text("One-time code") }
                Section {
                    TextField("One-time code from the Core host", text: $code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("approval-enroll.code")
                    Button {
                        Task { await enroll() }
                    } label: {
                        Label("Enroll this iPhone (\(OrbBiometric.name))", systemImage: OrbBiometric.name == "Touch ID" ? "touchid" : "faceid")
                    }
                    .disabled(enrolling || (monitor.mode == "enforce" && trimmed.count < 8))
                    .accessibilityIdentifier("approval-enroll.submit")
                }
            }
            .scrollContentBackground(.hidden).background(OrbStyle.background)
            .navigationTitle("Approval device").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
    }

    private func enroll() async {
        enrolling = true
        defer { enrolling = false }
        do {
            try await OrbApprovalKey.enroll(code: trimmed)
            code = ""
            OrbHaptics.success()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        await monitor.refresh()
    }
}
