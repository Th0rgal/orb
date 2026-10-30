import ActivityKit
import SwiftUI
import UIKit
@preconcurrency import UserNotifications

/// Settings → Debug info: what to paste into a bug report.
struct OrbDebugInfoView: View {
    @State private var ring = ErrorRing.shared
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var copied = false
    @State private var cleared = false
    @State private var selectedError: OrbActivityDetailItem?

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// `/api/health` reports the Core version; older servers may omit it.
    nonisolated static func describeBackend(_ version: String?) -> String {
        guard let version, !version.isEmpty else { return "Unknown" }
        return version
    }

    private var liveActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    private var activeLiveActivities: Int { Activity<OrbFleetActivityAttributes>.activities.count }

    static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "Not asked"
        case .denied: "Denied"
        case .authorized: "Allowed"
        case .provisional: "Provisional"
        case .ephemeral: "Ephemeral"
        @unknown default: "Unknown"
        }
    }

    private var lastRefresh: String {
        OrbDiagnosticsClock.lastBackgroundRefresh.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "Never"
    }

    private var account: String {
        let scope = OrbInboxAccount.current
        // Show the subject, never the opaque token hash in full.
        if let range = scope.range(of: "subject:") { return String(scope[range.upperBound...]) }
        return scope.isEmpty ? "Signed out" : String(scope.suffix(12))
    }

    var diagnostics: String {
        var lines = [
            "Orb \(Self.version)",
            "iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)",
            "Endpoint: \(OrbCore.shared.endpoint)",
            "Core: \(Self.describeBackend(OrbCore.shared.backendVersion))",
            "Account: \(account)",
            "Notifications: \(Self.describe(notificationStatus)) (in-app \(OrbNotificationCenter.shared.notificationsEnabled ? "on" : "off"))",
            "Live Activities: \(liveActivitiesEnabled ? "enabled" : "disabled"), \(activeLiveActivities) active",
            "Last background refresh: \(lastRefresh)",
            "Errors (\(ring.entries.count)):",
        ]
        let formatter = ISO8601DateFormatter()
        for entry in ring.entries.reversed() {
            lines.append("  \(formatter.string(from: entry.time)) [\(entry.category.rawValue)] \(entry.path)\(entry.status.map { " HTTP \($0)" } ?? "") \(entry.message)")
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        List {
            Section("App") {
                LabeledContent("Version", value: Self.version).accessibilityIdentifier("debug.version")
                LabeledContent("Endpoint", value: OrbCore.shared.endpoint.isEmpty ? "Not configured" : OrbCore.shared.endpoint)
                LabeledContent("Core version", value: Self.describeBackend(OrbCore.shared.backendVersion)).accessibilityIdentifier("debug.backendVersion")
                LabeledContent("Account", value: account)
            }
            Section("System") {
                LabeledContent("Notifications", value: Self.describe(notificationStatus))
                LabeledContent("Live Activities", value: liveActivitiesEnabled ? "Enabled (\(activeLiveActivities) active)" : "Disabled")
                LabeledContent("Last background refresh", value: lastRefresh)
            }
            Section {
                Button(copied ? "Copied" : "Copy diagnostics") {
                    UIPasteboard.general.string = diagnostics
                    copied = true
                }
                .accessibilityIdentifier("debug.copy")
                Button(cleared ? "Caches cleared" : "Clear caches", role: .destructive) {
                    OrbReadCache.clearAll()
                    cleared = true
                }
                .accessibilityIdentifier("debug.clear-caches")
            }
            Section {
                let coalesced = OrbActivityCompaction.coalesceErrors(
                    ring.entries.reversed().map { entry in
                        OrbActivityCompaction.ErrorInput(
                            category: entry.category.rawValue,
                            summary: entry.status.map { "HTTP \($0)" } ?? entry.path,
                            detail: "\(entry.path)\n\(entry.message)",
                            at: entry.time.timeIntervalSince1970
                        )
                    }
                )
                if coalesced.isEmpty {
                    Text("No errors recorded since launch.").foregroundStyle(OrbStyle.textSecondary)
                }
                ForEach(coalesced) { item in
                    let parts = item.detail.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    let pathLine = parts.first ?? ""
                    let msgLine = parts.count > 1 ? parts[1] : ""
                    Button {
                        selectedError = OrbActivityDetailItem(
                            title: "\(item.category) · \(item.summary)" + (item.count > 1 ? " (×\(item.count))" : ""),
                            subtitle: Date(timeIntervalSince1970: item.at).formatted(date: .abbreviated, time: .standard),
                            body: item.detail
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.category).font(.caption.weight(.semibold))
                                if item.summary.hasPrefix("HTTP ") {
                                    Text(item.summary).font(.caption.monospacedDigit()).foregroundStyle(OrbStyle.error)
                                }
                                if item.count > 1 {
                                    Text("×\(item.count)")
                                        .font(.caption2.weight(.bold).monospacedDigit())
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.white.opacity(0.10), in: Capsule())
                                }
                                Spacer()
                                Text(Date(timeIntervalSince1970: item.at), style: .time)
                                    .font(.caption)
                                    .foregroundStyle(OrbStyle.textMuted)
                            }
                            if !pathLine.isEmpty {
                                Text(pathLine).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            }
                            if !msgLine.isEmpty {
                                Text(msgLine).font(.caption).foregroundStyle(OrbStyle.textSecondary).lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack {
                    Text("Recent errors (\(ring.entries.count)/\(ErrorRing.capacity))")
                    Spacer()
                    if !ring.entries.isEmpty { Button("Clear") { ring.clear() }.font(.caption) }
                }
            }
        }
        .scrollContentBackground(.hidden).background(OrbStyle.background)
        .navigationTitle("Debug info").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedError) { item in
            OrbActivityDetailSheet(item: item)
        }
        .task {
            _ = try? await OrbCore.shared.checkHealth()
            await OrbNotificationCenter.shared.refreshAuthorizationStatus()
            notificationStatus = OrbNotificationCenter.shared.authorizationStatus
        }
    }
}
