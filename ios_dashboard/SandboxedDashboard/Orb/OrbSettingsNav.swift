import CryptoKit
import SwiftUI

/// Settings navigation shared with Orb desktop (`orb/src/settingsNav.ts`) and
/// Android (`SettingsNav.kt`): five sections with the same ids, names and
/// subtitles, checked against `shared/orb-spec/fixtures/settings-nav.json`.
/// Pages a phone cannot show (Local agents) are left out; phone-only pages
/// (Providers, Machines, Dictation) sit in the section they belong to.
enum OrbSettingsSection: String, CaseIterable, Identifiable {
    case account, models, agents, security, notifications
    var id: String { rawValue }
    var label: String {
        switch self {
        case .account: "Account"
        case .models: "Models"
        case .agents: "Agents"
        case .security: "Security"
        case .notifications: "Notifications"
        }
    }
    var subtitle: String {
        switch self {
        case .account: "Your server connection, connected accounts and how Orb looks."
        case .models: "Fallback order, provider health, usage over time and API keys."
        case .agents: "What agents know and can do, the Assistant, and the agents on this computer."
        case .security: "Who can approve risky actions, Fleet Bunker Mode, privileged access and secrets."
        case .notifications: "What reaches your Inbox and when Orb tells you."
        }
    }
    var systemImage: String {
        switch self {
        case .account: "person.crop.circle"
        case .models: "cube"
        case .agents: "square.stack.3d.up"
        case .security: "lock.shield"
        case .notifications: "bell"
        }
    }
    /// Page ids and labels; ids shared with desktop keep desktop's label.
    var pages: [(id: String, label: String)] {
        switch self {
        case .account: [("settings", "Account"), ("dictation", "Dictation"), ("debug", "Advanced")]
        case .models: [("routing", "Fallback Chains"), ("providers", "Providers"), ("usage-settings", "Usage"), ("routing-keys", "API Keys")]
        case .agents: [("skills-settings", "Skills"), ("hermes-settings", "Assistant"), ("btw-settings", "Quick questions (/btw)"), ("machines", "Machines")]
        case .security: [("security-settings", "Access"), ("mission-access", "Mission access"), ("bitwarden-settings", "Secrets vault")]
        case .notifications: [("inbox-settings", "Notifications")]
        }
    }

    /// Sections that need the user (sidebar attention dot).
    static func attention(bunkerActive: Bool, deviceEnrolled: Bool, quotaExhausted: Bool) -> Set<OrbSettingsSection> {
        var out = Set<OrbSettingsSection>()
        if bunkerActive || !deviceEnrolled { out.insert(.security) }
        if quotaExhausted { out.insert(.models) }
        return out
    }
}

struct OrbSettingsHome: View {
    let onBackendChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var client = OrbSettingsClient()
    @State private var deviceEnrolled = true
    @State private var quotaExhausted = false
    private var attention: Set<OrbSettingsSection> {
        OrbSettingsSection.attention(bunkerActive: OrbPrivilegeAccessMonitor.shared.bunkerState > 0, deviceEnrolled: deviceEnrolled, quotaExhausted: quotaExhausted)
    }
    var body: some View {
        NavigationStack {
            List(OrbSettingsSection.allCases) { section in
                NavigationLink { page(section) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: section.systemImage).frame(width: 24).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.label)
                            Text(section.subtitle).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if attention.contains(section) {
                            Circle().fill(.red).frame(width: 8, height: 8).accessibilityLabel("Needs attention")
                        }
                    }
                }
                .accessibilityIdentifier("settings.\(section.rawValue)")
            }
            .scrollContentBackground(.hidden).background(OrbStyle.background)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await loadAttention() }
        }
        .id(OrbCore.shared.connectionGeneration)
        .presentationDetents([.large]).presentationDragIndicator(.visible)
    }

    private func page(_ section: OrbSettingsSection) -> some View {
        List {
            Section {
                ForEach(section.pages, id: \.id) { p in
                    NavigationLink { destination(p.id) } label: { Text(p.label) }
                        .accessibilityIdentifier(p.id == "settings" ? "settings.backend" : "settings.\(p.id)")
                }
            } header: { Text(section.subtitle).textCase(nil) }
        }
        .scrollContentBackground(.hidden).background(OrbStyle.background)
        .navigationTitle(section.label).navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func destination(_ id: String) -> some View {
        switch id {
        case "settings": SetupSheet(onComplete: onBackendChanged, allowsDismissal: true, embedded: true)
        case "dictation": OrbDictationSettingsView()
        case "debug": OrbDebugInfoView()
        case "routing": OrbRoutingSettings()
        case "providers": OrbProvidersSettings()
        case "routing-keys": OrbProxyKeysSettings()
        case "usage-settings": OrbUsageSettings()
        case "skills-settings": OrbSkillsSettings()
        case "hermes-settings": OrbHermesSettings()
        case "btw-settings": OrbBtwSettingsView()
        case "machines": OrbMachinesSettings()
        case "security-settings": OrbPrivilegeAccessList().navigationTitle("Access").navigationBarTitleDisplayMode(.inline)
        case "mission-access": OrbMissionAccessList().navigationTitle("Mission access").navigationBarTitleDisplayMode(.inline)
        case "bitwarden-settings": OrbBitwardenSettings()
        default: OrbInboxSettingsView()
        }
    }

    private func loadAttention() async {
        await OrbPrivilegeAccessMonitor.shared.refresh()
        if let d = try? await client.call("/api/approvals/devices") {
            let mine = OrbApprovalKey.publicKey
            deviceEnrolled = !SecureEnclave.isAvailable || OrbApprovalEnrollmentMonitor.isEnrolled(publicKey: mine, devices: d["devices"].items)
        }
        if let usage = try? await client.call("/api/ai/providers/usage")["entries"], case .object(let entries) = usage {
            quotaExhausted = entries.values.contains { OrbProviderQuota.quotaStatus(OrbProviderQuota.windows($0))?.level == .exhausted }
        }
    }
}
