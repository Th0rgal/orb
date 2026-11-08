import ActivityKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

struct OrbZipBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Settings → Debug info: what to paste into a bug report, plus server workspace GC & backup/restore.
struct OrbDebugInfoView: View {
    @State private var ring = ErrorRing.shared
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var copied = false
    @State private var cleared = false
    @State private var selectedError: OrbActivityDetailItem?
    @State private var cleanupLoaded = false
    @State private var cleanupEnabled = false
    @State private var cleanupBaseEnabled = false
    @State private var cleanupRawDays: Int?
    @State private var cleanupDays = String(OrbBackupArchive.defaultCleanupRetentionDays)
    @State private var cleanupDaysEdited = false
    @State private var cleanupDirty = false
    @State private var cleanupSaving = false
    @State private var cleanupSaveSeq = 0
    @State private var cleanupNotice: String?
    @State private var cleanupError: String?
    @State private var backupBusy = false
    @State private var exportDoc: OrbZipBackupDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var pendingRestore: (name: String, data: Data)?
    @State private var backupNotice: String?
    @State private var backupError: String?

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
            if OrbCore.shared.isConfigured && (OrbCore.shared.isAuthenticated || !OrbCore.shared.authRequired) && OrbCore.shared.isAdminUser {
                workspaceCleanupSection
                backupRestoreSection
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
        .fileExporter(
            isPresented: $showExporter,
            document: exportDoc,
            contentType: .zip,
            defaultFilename: "orb-backup-\(ISO8601DateFormatter().string(from: Date()).prefix(10)).zip"
        ) { result in
            if case .failure(let err) = result {
                backupError = err.localizedDescription
            } else {
                backupNotice = "Saved backup archive."
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    pendingRestore = (name: url.lastPathComponent, data: data)
                } catch {
                    backupError = error.localizedDescription
                }
            case .failure(let err):
                backupError = err.localizedDescription
            }
        }
        .alert(
            "Restore backup archive?",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 && !backupBusy { pendingRestore = nil } })
        ) {
            Button("Restore", role: .destructive) { Task { await confirmRestore() } }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("Restoring \(pendingRestore?.name ?? "this archive") overwrites server settings, provider credentials, and workspaces stored in the backup.")
        }
        .task(id: "\(OrbCore.shared.endpoint)|\(OrbInboxAccount.current)") {
            cleanupSaveSeq += 1
            cleanupSaving = false
            cleanupLoaded = false
            cleanupDaysEdited = false
            cleanupDirty = false
            cleanupError = nil
            cleanupNotice = nil
            _ = try? await OrbCore.shared.checkHealth()
            await OrbNotificationCenter.shared.refreshAuthorizationStatus()
            notificationStatus = OrbNotificationCenter.shared.authorizationStatus
            if OrbCore.shared.isAdminUser {
                await loadCleanupSettings()
            }
        }
    }

    @ViewBuilder
    private var workspaceCleanupSection: some View {
        Section {
            Toggle("Terminal workspace retention sweep", isOn: Binding(
                get: { cleanupEnabled },
                set: { cleanupEnabled = $0; cleanupDirty = true; cleanupNotice = nil }
            ))
            .disabled(!cleanupLoaded || cleanupSaving)
            HStack {
                Text("Completed retention (days)")
                Spacer()
                TextField("1", text: Binding(
                    get: { cleanupDays },
                    set: { cleanupDays = $0; cleanupDaysEdited = true; cleanupDirty = true; cleanupNotice = nil }
                ))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .disabled(!cleanupLoaded || cleanupSaving)
            }
            Button(cleanupSaving ? "Saving…" : "Save cleanup policy") {
                Task { await saveCleanupSettings() }
            }
            .disabled(!cleanupLoaded || cleanupSaving || !cleanupDirty)
            if let cleanupNotice {
                Text(cleanupNotice).font(.footnote).foregroundStyle(OrbStyle.success)
            }
            if let cleanupError {
                Text(cleanupError).font(.footnote).foregroundStyle(OrbStyle.error)
            }
        } header: {
            Text("Workspace cleanup")
        } footer: {
            Text("Audits terminal mission workspaces past retention (1–365 days, default 1). Resumable, failed, and unmatched directories are always kept.")
        }
    }

    @ViewBuilder
    private var backupRestoreSection: some View {
        Section {
            Button(backupBusy ? "Working…" : "Download backup (.zip)") {
                Task { await downloadBackup() }
            }
            .disabled(backupBusy)
            .accessibilityIdentifier("debug.backup-download")

            Button("Restore from backup…", role: .destructive) {
                backupError = nil
                backupNotice = nil
                showImporter = true
            }
            .disabled(backupBusy)
            .accessibilityIdentifier("debug.backup-restore")

            if let backupNotice {
                Text(backupNotice).font(.footnote).foregroundStyle(OrbStyle.success)
            }
            if let backupError {
                Text(backupError).font(.footnote).foregroundStyle(OrbStyle.error)
            }
        } header: {
            Text("Backup & restore")
        } footer: {
            Text("Exports or restores server configuration, credentials, and workspace metadata. Requires device approval when enforced.")
        }
    }

    private func loadCleanupSettings() async {
        guard OrbCore.shared.isConfigured else { return }
        let scopeKey = "\(OrbCore.shared.endpoint)|\(OrbInboxAccount.current)"
        do {
            let s = try await OrbCore.shared.call("/api/settings")
            guard "\(OrbCore.shared.endpoint)|\(OrbInboxAccount.current)" == scopeKey else { return }
            if !cleanupDirty {
                let isOn = s["auto_cleanup_enabled"].flag
                let configuredDays = s["auto_cleanup_days"].number.flatMap { Int(exactly: $0) }.flatMap { $0 >= 1 ? $0 : nil }
                cleanupEnabled = isOn
                cleanupBaseEnabled = isOn
                cleanupRawDays = configuredDays
                cleanupDays = String(OrbBackupArchive.effectiveCleanupDays(s["auto_cleanup_days"].number))
                cleanupDaysEdited = false
            }
            cleanupLoaded = true
        } catch is CancellationError {} catch {}
    }

    private func saveCleanupSettings() async {
        let days: Int
        switch OrbBackupArchive.parseCleanupDays(cleanupDays) {
        case .success(let d):
            days = d
        case .failure(let err):
            cleanupError = err.localizedDescription
            return
        }
        let includeDays = cleanupDaysEdited || cleanupRawDays != nil
        if !includeDays, cleanupEnabled == cleanupBaseEnabled {
            cleanupDirty = false
            return
        }
        let scopeKey = "\(OrbCore.shared.endpoint)|\(OrbInboxAccount.current)"
        cleanupSaveSeq += 1
        let seq = cleanupSaveSeq
        cleanupSaving = true
        cleanupError = nil
        cleanupNotice = nil
        defer {
            if cleanupSaveSeq == seq, "\(OrbCore.shared.endpoint)|\(OrbInboxAccount.current)" == scopeKey {
                cleanupSaving = false
            }
        }
        do {
            var payload: [String: OrbJSON] = [
                "auto_cleanup_enabled": .bool(cleanupEnabled)
            ]
            if includeDays {
                payload["auto_cleanup_days"] = .number(Double(days))
            }
            let updated = try await OrbCore.shared.call(
                "/api/settings",
                method: "PUT",
                body: .object(payload)
            )
            guard cleanupSaveSeq == seq, "\(OrbCore.shared.endpoint)|\(OrbInboxAccount.current)" == scopeKey else { return }
            let isOn = updated["auto_cleanup_enabled"].flag
            let nextRawDays = updated["auto_cleanup_days"].number.flatMap { Int(exactly: $0) }.flatMap { $0 >= 1 ? $0 : nil }
                ?? (includeDays ? days : nil)
            cleanupEnabled = isOn
            cleanupBaseEnabled = isOn
            cleanupRawDays = nextRawDays
            cleanupDays = String(OrbBackupArchive.effectiveCleanupDays(nextRawDays.map(Double.init)))
            cleanupDaysEdited = false
            cleanupDirty = false
            cleanupNotice = "Saved workspace cleanup policy."
        } catch {
            if cleanupSaveSeq == seq, "\(OrbCore.shared.endpoint)|\(OrbInboxAccount.current)" == scopeKey {
                cleanupError = error.localizedDescription
            }
        }
    }

    private func downloadBackup() async {
        backupBusy = true
        backupError = nil
        backupNotice = nil
        defer { backupBusy = false }
        do {
            let bytes = try await OrbApprovalKey.signedCallData("/api/settings/backup", summary: "Download settings backup")
            guard !bytes.isEmpty else {
                backupError = "Core returned an empty backup archive."
                return
            }
            exportDoc = OrbZipBackupDocument(data: bytes)
            showExporter = true
        } catch {
            if let msg = OrbBiometric.friendlyError(error) {
                backupError = msg
            }
        }
    }

    private func confirmRestore() async {
        guard let target = pendingRestore else { return }
        backupBusy = true
        backupError = nil
        backupNotice = nil
        defer { backupBusy = false }
        do {
            let payload = OrbBackupArchive.buildRestoreMultipart(zipData: target.data, filename: target.name)
            let res = try await OrbApprovalKey.signedCallRaw(
                "/api/settings/restore",
                method: "POST",
                rawBody: payload.body,
                contentType: payload.contentType,
                summary: "Restore settings backup"
            )
            pendingRestore = nil
            let outcome = OrbBackupArchive.interpretRestoreResponse(res)
            if outcome.ok {
                backupNotice = outcome.message
                await loadCleanupSettings()
            } else {
                backupError = outcome.message
            }
        } catch {
            if let msg = OrbBiometric.friendlyError(error) {
                backupError = msg
            }
        }
    }
}
