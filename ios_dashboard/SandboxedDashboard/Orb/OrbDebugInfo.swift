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

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
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
                if ring.entries.isEmpty {
                    Text("No errors recorded since launch.").foregroundStyle(OrbStyle.textSecondary)
                }
                ForEach(ring.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(entry.category.rawValue).font(.caption.weight(.semibold))
                            if let status = entry.status { Text("HTTP \(status)").font(.caption.monospacedDigit()).foregroundStyle(OrbStyle.error) }
                            Spacer()
                            Text(entry.time, style: .time).font(.caption).foregroundStyle(OrbStyle.textMuted)
                        }
                        Text(entry.path).font(.caption.monospaced()).lineLimit(2)
                        Text(entry.message).font(.caption).foregroundStyle(OrbStyle.textSecondary).lineLimit(3)
                    }
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
        .task {
            await OrbNotificationCenter.shared.refreshAuthorizationStatus()
            notificationStatus = OrbNotificationCenter.shared.authorizationStatus
        }
    }
}
