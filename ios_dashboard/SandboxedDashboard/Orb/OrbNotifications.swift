import BackgroundTasks
import Foundation
import os
@preconcurrency import UserNotifications
import SwiftUI

/// Deep-link target when the operator taps an Inbox notification or `orb://inbox/<mission-id>`.
struct OrbInboxFocusRequest: Equatable, Sendable {
    let missionID: String
    let expandPeek: Bool
    let openReply: Bool
    let token: UUID

    init(missionID: String, expandPeek: Bool = true, openReply: Bool = false, token: UUID = UUID()) {
        self.missionID = missionID
        self.expandPeek = expandPeek
        self.openReply = openReply
        self.token = token
    }

    static func parse(url: URL) -> OrbInboxFocusRequest? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "orb" || scheme == "sandboxed" else { return nil }
        var parts = url.pathComponents.filter { $0 != "/" }
        if let host = url.host, !host.isEmpty {
            parts.insert(host, at: 0)
        }
        guard let first = parts.first?.lowercased(), first == "inbox" else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryMission = components?.queryItems?.first(where: { $0.name == "mission" || $0.name == "id" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathMission = parts.count >= 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let missionID = (pathMission?.isEmpty == false ? pathMission : queryMission) ?? ""
        let expandPeek = components?.queryItems?.first(where: { $0.name == "peek" })?.value != "0"
        let openReply = components?.queryItems?.first(where: { $0.name == "reply" })?.value == "1"
        return OrbInboxFocusRequest(missionID: missionID, expandPeek: expandPeek, openReply: openReply)
    }

    var deepLinkURL: URL? {
        guard !missionID.isEmpty else { return URL(string: "orb://inbox") }
        var components = URLComponents()
        components.scheme = "orb"
        components.host = "inbox"
        let escaped = missionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? missionID
        components.path = "/" + escaped
        var items: [URLQueryItem] = [URLQueryItem(name: "peek", value: expandPeek ? "1" : "0")]
        if openReply {
            items.append(URLQueryItem(name: "reply", value: "1"))
        }
        components.queryItems = items
        return components.url
    }
}

/// Formatted notification payload for a hybrid mission that finished or needs operator input.
struct OrbNotificationPayload: Equatable, Sendable {
    let identifier: String
    let missionID: String
    let projectSlug: String
    let projectTitle: String
    let categoryIdentifier: String
    let title: String
    let subtitle: String
    let body: String
    let isUrgent: Bool
    let signature: String
    let callID: String?
    let toolName: String?
    let primaryOptionPayload: OrbJSON?
    let secondaryOptionPayload: OrbJSON?
    let primaryOptionLabel: String?
    let secondaryOptionLabel: String?

    static func notificationIdentifier(for missionID: String) -> String {
        "orb.inbox.mission.\(missionID)"
    }

    /// "Verity / Verity · Done": skip the project when the conversation has its name.
    static func lead(project: String, headline: String, status: String) -> [String] {
        let sameName = project.caseInsensitiveCompare(headline) == .orderedSame || project.isEmpty
        return sameName ? [status] : [project, status]
    }

    @MainActor
    static func build(from item: OrbInboxItem) -> OrbNotificationPayload? {
        guard item.unread, item.category == .needsYou || item.category == .ready else { return nil }

        // Like ChatGPT and Claude: the conversation is the title, why it needs you is the
        // second line. No emoji or internal labels ("AI Summary") competing for the 2 lines a banner shows.
        let status: String = {
            if let interaction = item.interaction {
                switch interaction.kind {
                case "permission": return "Needs approval"
                case "plan": return "Plan to review"
                default: return "Question for you"
                }
            }
            switch item.row.state {
            case "blocked": return "Blocked"
            case "failed", "not_feasible": return "Failed"
            case "awaiting_user", "waiting_user": return "Waiting for you"
            case "completed", "succeeded": return "Done"
            default: return item.badge
            }
        }()

        let title = item.headline

        var subtitleParts = lead(project: item.projectTitle, headline: item.headline, status: status)
        if !item.machine.isEmpty {
            subtitleParts.append(item.machine)
        }
        if let receipt = item.workReceipt, !receipt.isEmpty {
            subtitleParts.append(receipt)
        }
        let subtitle = subtitleParts.joined(separator: " · ")

        var bodyLines: [String] = []
        if let digest = item.aiOverview, !digest.outcome.isEmpty, item.interaction == nil {
            bodyLines.append(digest.outcome)
            if let decision = digest.decision, !decision.isEmpty {
                bodyLines.append("To decide: \(decision)")
            } else if let unresolved = digest.unresolved, !unresolved.isEmpty {
                bodyLines.append("Open: \(unresolved)")
            }
        } else {
            bodyLines.append(item.summary)
            if let cmd = item.interaction?.commandPreview, !cmd.isEmpty {
                bodyLines.append("$ \(cmd)")
            }
            if let digest = item.aiOverview, !digest.outcome.isEmpty, digest.outcome != item.summary {
                bodyLines.append("AI Summary: \(digest.outcome)")
            }
        }

        if let cs = item.childSummary, cs.failed > 0, let firstFailed = cs.failedChildren.first {
            bodyLines.append("\(cs.failed) \(cs.failed == 1 ? "track" : "tracks") failed: \(firstFailed.title)")
        }

        let body = bodyLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        let isUrgent = item.category == .needsYou || item.attention
        let hasQuickApproval = item.interaction != nil && !(item.interaction?.options.isEmpty ?? true)
        let categoryIdentifier = hasQuickApproval
            ? OrbNotificationCenter.categoryInteractiveApproval
            : (item.canRetry ? OrbNotificationCenter.categoryInboxRetryable : OrbNotificationCenter.categoryInboxReady)

        let digestStamp = item.aiOverview?.sourceRevision ?? ""
        let callID = item.interaction?.callID
        let signature = "\(item.row.state)|\(item.updatedAt)|\(callID ?? "")|\(digestStamp)"

        let opts = item.interaction?.options ?? []
        let primaryOpt = opts.first(where: \.isPrimary) ?? opts.first
        let secondaryOpt = opts.dropFirst().first

        return OrbNotificationPayload(
            identifier: notificationIdentifier(for: item.id),
            missionID: item.id,
            projectSlug: item.projectSlug,
            projectTitle: item.projectTitle,
            categoryIdentifier: categoryIdentifier,
            title: title,
            subtitle: subtitle,
            body: body.isEmpty ? "Open Inbox to review the agent response." : body,
            isUrgent: isUrgent,
            signature: signature,
            callID: callID,
            toolName: item.interaction?.toolName,
            primaryOptionPayload: primaryOpt?.payload,
            secondaryOptionPayload: secondaryOpt?.payload,
            primaryOptionLabel: primaryOpt?.label,
            secondaryOptionLabel: secondaryOpt?.label
        )
    }
}

@MainActor
@Observable
final class OrbNotificationCenter: NSObject, @unchecked Sendable {
    static let shared = OrbNotificationCenter()

    static let categoryInteractiveApproval = "ORB_INBOX_APPROVAL"
    static let categoryInboxReady = "ORB_INBOX_READY"
    static let categoryInboxRetryable = "ORB_INBOX_RETRYABLE"

    static let actionApprove = "ORB_ACTION_APPROVE"
    static let actionDecline = "ORB_ACTION_DECLINE"
    static let actionReply = "ORB_ACTION_REPLY"
    static let actionDone = "ORB_ACTION_DONE"
    static let actionRetry = "ORB_ACTION_RETRY"

    private let enabledKey = "orb.notifications.enabled.v1"
    private let signaturesKey = "orb.notifications.signatures.v1"
    private let seededAccountsKey = "orb.notifications.seededAccounts.v1"

    var pendingFocus: OrbInboxFocusRequest?
    /// Unread "needs you" + "ready" items from the last reconcile: the same number as
    /// the app icon badge and the Inbox, so the home tab can't disagree (it showed 0 vs 5).
    var unreadCount: Int?
    var authorizationStatus: UNAuthorizationStatus = .notDetermined

    var notificationsEnabled: Bool {
        didSet {
            guard notificationsEnabled != oldValue else { return }
            UserDefaults.standard.set(notificationsEnabled, forKey: enabledKey)
            if notificationsEnabled {
                Task { await requestAuthorizationIfNeeded() }
            } else {
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            }
        }
    }

    private var deliveredSignatures: [String: String] = [:]
    private var seededAccounts: Set<String> = []
    private var didRegisterCategories = false
    private var backgroundLoopTask: Task<Void, Never>?

    private override init() {
        if UserDefaults.standard.object(forKey: enabledKey) == nil {
            self.notificationsEnabled = true
        } else {
            self.notificationsEnabled = UserDefaults.standard.bool(forKey: enabledKey)
        }
        self.deliveredSignatures = (UserDefaults.standard.dictionary(forKey: signaturesKey) as? [String: String]) ?? [:]
        self.seededAccounts = Set(UserDefaults.standard.stringArray(forKey: seededAccountsKey) ?? [])
        super.init()
    }

    func start() {
        guard !didRegisterCategories else { return }
        didRegisterCategories = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        registerCategories(on: center)
        Task {
            await refreshAuthorizationStatus()
            if notificationsEnabled && authorizationStatus == .notDetermined {
                await requestAuthorizationIfNeeded()
            }
        }
        startMonitorLoop()
    }

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
        guard settings.authorizationStatus == .notDetermined else { return }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            Log.notifications.notice("notification authorization granted=\(granted)")
        } catch {
            Log.error(.notifications, "requestAuthorization", error)
        }
        await refreshAuthorizationStatus()
    }

    func focusInbox(missionID: String, expandPeek: Bool = true, openReply: Bool = false) {
        pendingFocus = OrbInboxFocusRequest(
            missionID: missionID,
            expandPeek: expandPeek,
            openReply: openReply
        )
    }

    func consumeFocus() -> OrbInboxFocusRequest? {
        let req = pendingFocus
        pendingFocus = nil
        return req
    }

    private func registerCategories(on center: UNUserNotificationCenter) {
        let approveAction = UNNotificationAction(
            identifier: Self.actionApprove,
            title: "Approve",
            options: [.authenticationRequired]
        )
        let declineAction = UNNotificationAction(
            identifier: Self.actionDecline,
            title: "Decline / Revise",
            options: [.authenticationRequired]
        )
        let replyAction = UNTextInputNotificationAction(
            identifier: Self.actionReply,
            title: "Reply…",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Send instructions or answer…"
        )
        let doneAction = UNNotificationAction(
            identifier: Self.actionDone,
            title: "Mark Done",
            options: []
        )
        let retryAction = UNNotificationAction(
            identifier: Self.actionRetry,
            title: "Retry / Resume",
            options: []
        )

        let approvalCategory = UNNotificationCategory(
            identifier: Self.categoryInteractiveApproval,
            actions: [approveAction, replyAction, declineAction, doneAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let readyCategory = UNNotificationCategory(
            identifier: Self.categoryInboxReady,
            actions: [replyAction, doneAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let retryCategory = UNNotificationCategory(
            identifier: Self.categoryInboxRetryable,
            actions: [retryAction, replyAction, doneAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        center.setNotificationCategories([approvalCategory, readyCategory, retryCategory])
    }

    /// Reconcile system notifications and app badge with the current Inbox state.
    func reconcile(
        needsYou: [OrbInboxItem],
        ready: [OrbInboxItem],
        working: [OrbInboxItem]
    ) {
        let actionable = needsYou + ready
        let unreadItems = actionable.filter(\.unread)
        UNUserNotificationCenter.current().setBadgeCount(unreadItems.count) { _ in }
        if unreadCount != unreadItems.count { unreadCount = unreadItems.count }
        OrbFleetActivityController.shared.reconcile(
            account: OrbInboxAccount.current,
            needsYou: needsYou,
            ready: ready,
            working: working
        )

        guard notificationsEnabled else { return }

        let account = OrbInboxAccount.current
        guard !account.isEmpty, !OrbCore.shared.endpoint.isEmpty else { return }

        let center = UNUserNotificationCenter.current()
        let activeUnreadIDs = Set(unreadItems.map { OrbNotificationPayload.notificationIdentifier(for: $0.id) })

        // Auto-dismiss notifications for missions that were read/archived on PC or mobile, or resumed into working.
        var identifiersToDismiss: [String] = []
        for (missionID, _) in deliveredSignatures {
            let notifID = OrbNotificationPayload.notificationIdentifier(for: missionID)
            if !activeUnreadIDs.contains(notifID) {
                identifiersToDismiss.append(notifID)
            }
        }
        if !identifiersToDismiss.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: identifiersToDismiss)
            center.removePendingNotificationRequests(withIdentifiers: identifiersToDismiss)
            for item in working {
                deliveredSignatures.removeValue(forKey: item.id)
            }
            for item in actionable where !item.unread {
                deliveredSignatures.removeValue(forKey: item.id)
            }
            persistSignatures()
        }

        // First sync on a fresh install/account seeds existing unread items silently so we don't spam historical missions,
        // while still updating when an AI summary arrives or a new turn finishes.
        let isFirstSeed = !seededAccounts.contains(account)
        if isFirstSeed {
            seededAccounts.insert(account)
            UserDefaults.standard.set(Array(seededAccounts), forKey: seededAccountsKey)
            for item in unreadItems {
                if let payload = OrbNotificationPayload.build(from: item) {
                    deliveredSignatures[item.id] = payload.signature
                }
            }
            persistSignatures()
            return
        }

        for item in unreadItems.prefix(8) {
            guard let payload = OrbNotificationPayload.build(from: item) else { continue }
            let previousSig = deliveredSignatures[item.id]
            guard previousSig != payload.signature else { continue }

            // If we only gained the AI Overview summary on top of an already-notified turn, update the notification silently.
            let wasAlreadyNotifiedForTurn = previousSig?.hasPrefix("\(item.row.state)|\(item.updatedAt)|") == true
            deliveredSignatures[item.id] = payload.signature
            persistSignatures()
            scheduleNotification(payload, silentUpdate: wasAlreadyNotifiedForTurn)
        }
    }

    private func persistSignatures() {
        if deliveredSignatures.count > 200 {
            let keysToKeep = Array(deliveredSignatures.keys.suffix(120))
            deliveredSignatures = deliveredSignatures.filter { keysToKeep.contains($0.key) }
        }
        UserDefaults.standard.set(deliveredSignatures, forKey: signaturesKey)
    }

    private func scheduleNotification(_ payload: OrbNotificationPayload, silentUpdate: Bool) {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.subtitle = payload.subtitle
        content.body = payload.body
        content.categoryIdentifier = payload.categoryIdentifier
        content.threadIdentifier = "orb.project.\(payload.projectSlug)"
        content.summaryArgument = payload.projectTitle
        if !silentUpdate {
            content.sound = .default
        }
        // A summary landing on an already-announced turn updates the card without
        // presenting it again. (.timeSensitive needs an entitlement Orb doesn't have yet.)
        content.interruptionLevel = silentUpdate ? .passive : (payload.isUrgent ? .timeSensitive : .active)

        var userInfo: [String: Any] = [
            "mission_id": payload.missionID,
            "project_slug": payload.projectSlug,
            "url": payload.missionID.isEmpty ? "orb://inbox" : "orb://inbox/\(OrbCore.escape(payload.missionID))?peek=1",
        ]
        if let callID = payload.callID { userInfo["call_id"] = callID }
        if let toolName = payload.toolName { userInfo["tool_name"] = toolName }
        if let primary = payload.primaryOptionPayload,
           let data = try? JSONEncoder().encode(primary),
           let str = String(data: data, encoding: .utf8) {
            userInfo["primary_payload"] = str
        }
        if let secondary = payload.secondaryOptionPayload,
           let data = try? JSONEncoder().encode(secondary),
           let str = String(data: data, encoding: .utf8) {
            userInfo["secondary_payload"] = str
        }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: payload.identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Global monitor so hybrid PC-launched missions are tracked even when the user is on the Projects tab or backgrounded.
    private func startMonitorLoop() {
        backgroundLoopTask?.cancel()
        backgroundLoopTask = Task { @MainActor in
            var first = true
            while !Task.isCancelled {
                // Poll at launch too: a finished mission shouldn't wait 15 s to show up.
                if !first { try? await Task.sleep(for: .seconds(15)) }
                first = false
                guard !Task.isCancelled,
                      APIService.shared.isConfigured,
                      APIService.shared.isAuthenticated,
                      !APIService.shared.authSessionExpired else { continue }
                await pollHybridMissionsOnce()
            }
        }
    }

    func pollHybridMissionsOnce() async {
        await OrbSharedInboxState.shared.refresh()
        guard let rawMissions = await Log.attempt(.notifications, "hybrid missions poll", { try await OrbCore.shared.call("/api/control/missions?limit=100&all=true") }) else { return }
        OrbReadCache.seedFromGlobalMissions(rawMissions.items)
        OrbDisk.saveAsync(rawMissions, key: "inbox:missions")
        let rows = rawMissions.items.map { OrbRow($0) }.filter(\.mobile)
        let cachedProjects = OrbDisk.read("projects", as: OrbJSON.self)?["projects"].items
            .filter { !["archived", "deleted"].contains($0["status"].text) }
            .map { OrbRow($0, project: true) } ?? []

        var eventsByMission: [String: [StoredEvent]] = [:]
        let candidates = rows.filter {
            [
                "awaiting_user", "waiting_user", "blocked", "failed", "not_feasible",
                "completed", "succeeded", "paused", "interrupted",
            ].contains($0.state) && !OrbInboxModel.isSubagent(row: $0, includeAutonomous: OrbInboxSettings.shared.includeAutonomous)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
        .prefix(8)

        for (idx, row) in candidates.enumerated() {
            var events = OrbReadCache.readEvents(row.id)
            if events.isEmpty && OrbMissionUnreadStore.shared.isUnread(row: row) && idx < 4 {
                if let batch = try? await APIService.shared.getMissionEventsWithMeta(id: row.id, limit: 120, sinceSeq: nil) {
                    OrbReadCache.saveEvents(row.id, events: batch.events)
                    events = batch.events
                }
            }
            eventsByMission[row.id] = events
            if OrbMissionUnreadStore.shared.isUnread(row: row) {
                OrbInboxDigestStore.shared.request(row: row, events: events, priority: idx)
            }
        }

        let sections = OrbInboxModel.buildSections(
            missions: rows,
            projects: cachedProjects,
            eventsByMission: eventsByMission
        )
        reconcile(needsYou: sections.needsYou, ready: sections.ready, working: sections.working)
    }
}

extension OrbNotificationCenter: UNUserNotificationCenterDelegate {
    // Completion-handler forms, finished on the main thread: with the async
    // forms iOS calls the hidden completion on a background thread, and
    // UIKit's snapshot update then aborts with "Call must be made on main thread".
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Called once, on main: safe to carry across despite not being Sendable.
        nonisolated(unsafe) let done = completionHandler
        let missionID = (notification.request.content.userInfo["mission_id"] as? String) ?? ""
        DispatchQueue.main.async {
            MainActor.assumeIsolated { done(OrbOnScreen.presentation(missionID: missionID)) }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let missionID = (userInfo["mission_id"] as? String) ?? ""
        let callID = userInfo["call_id"] as? String
        let toolName = userInfo["tool_name"] as? String
        let primaryJSON = userInfo["primary_payload"] as? String
        let secondaryJSON = userInfo["secondary_payload"] as? String
        let actionID = response.actionIdentifier
        let replyText = (response as? UNTextInputNotificationResponse)?.userText
        let isFailure = userInfo["failed_reply"] != nil

        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor in
            // Finish the action (e.g. Done/Approve while backgrounded) before
            // telling iOS we're done, which may suspend the app; still on main.
            defer { done() }
            if isFailure {
                if !missionID.isEmpty { self.focusInbox(missionID: missionID, expandPeek: true, openReply: true) }
                return
            }
            await self.handleNotificationAction(
                actionID: actionID,
                missionID: missionID,
                callID: callID,
                toolName: toolName,
                primaryJSON: primaryJSON,
                secondaryJSON: secondaryJSON,
                replyText: replyText
            )
        }
    }

    @MainActor
    private func handleNotificationAction(
        actionID: String,
        missionID: String,
        callID: String?,
        toolName: String?,
        primaryJSON: String?,
        secondaryJSON: String?,
        replyText: String?
    ) async {
        guard !missionID.isEmpty else {
            focusInbox(missionID: "", expandPeek: false)
            return
        }

        switch actionID {
        case Self.actionDone:
            if await performAction("Mark done", missionID: missionID, call: {
                _ = try await OrbCore.shared.call(
                    "/api/control/missions/\(OrbCore.escape(missionID))/status",
                    method: "POST",
                    body: .object(["status": .string("acknowledged")])
                )
            }) {
                OrbMissionUnreadStore.shared.markRead(id: missionID)
            }
            await pollHybridMissionsOnce()

        case Self.actionApprove, Self.actionDecline:
            let approving = actionID == Self.actionApprove
            if let callID, let toolName, let json = approving ? primaryJSON : secondaryJSON,
               let data = json.data(using: .utf8),
               let payload = try? JSONDecoder().decode(OrbJSON.self, from: data) {
                if await performAction(approving ? "Approve" : "Decline", missionID: missionID, call: {
                    _ = try await OrbCore.shared.call(
                        "/api/control/tool_result",
                        method: "POST",
                        body: .object([
                            "tool_call_id": .string(callID),
                            "name": .string(toolName),
                            "result": payload,
                        ])
                    )
                }) {
                    OrbMissionUnreadStore.shared.markRead(id: missionID)
                }
                await pollHybridMissionsOnce()
            } else {
                focusInbox(missionID: missionID, expandPeek: true, openReply: !approving)
            }

        case Self.actionRetry:
            if await performAction("Retry", missionID: missionID, call: {
                try await self.sendMessage(missionID: missionID, content: "Continue from where you left off.")
            }) {
                OrbMissionUnreadStore.shared.markRead(id: missionID)
            }
            await pollHybridMissionsOnce()

        case Self.actionReply:
            let trimmed = (replyText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if await performAction("Reply", missionID: missionID, text: trimmed, call: {
                    try await self.sendMessage(missionID: missionID, content: trimmed)
                }) {
                    OrbMissionUnreadStore.shared.markRead(id: missionID)
                }
                await pollHybridMissionsOnce()
            } else {
                focusInbox(missionID: missionID, expandPeek: true, openReply: true)
            }

        case UNNotificationDismissActionIdentifier:
            break

        default:
            // Default tap on the notification banner: open Inbox directly on this mission card with AI summary expanded!
            focusInbox(missionID: missionID, expandPeek: true)
        }
    }
}

extension OrbNotificationCenter {
    static let categoryActionFailed = "ORB_ACTION_FAILED"

    fileprivate func sendMessage(missionID: String, content: String) async throws {
        _ = try await OrbCore.shared.call(
            "/api/control/message",
            method: "POST",
            body: .object([
                "mission_id": .string(missionID),
                "content": .string(content),
                "queue_followup": .bool(true),
                "client_message_id": .string(UUID().uuidString.lowercased()),
            ])
        )
    }

    /// Runs a notification quick action. On failure the error is logged and a
    /// "not sent" notification is posted (carrying the reply text) so nothing is lost silently.
    fileprivate func performAction(_ label: String, missionID: String, text: String? = nil, call: () async throws -> Void) async -> Bool {
        do {
            try await call()
            return true
        } catch {
            Log.error(.notifications, "notification action \(label)", path: missionID, error)
            Self.postActionFailure(label: label, missionID: missionID, text: text, error: error)
            return false
        }
    }

    static func failureContent(label: String, missionID: String, text: String?, error: Error) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = label == "Reply" ? "Reply not sent" : "\(label) failed"
        var lines: [String] = []
        if let text, !text.isEmpty { lines.append("\u{201C}\(text)\u{201D}") }
        lines.append(error.localizedDescription)
        lines.append("Tap to open the conversation and try again.")
        content.body = lines.joined(separator: "\n")
        content.sound = .default
        content.categoryIdentifier = categoryActionFailed
        content.userInfo = [
            "mission_id": missionID,
            "url": "orb://inbox/\(OrbCore.escape(missionID))?peek=1&reply=1",
            "failed_reply": text ?? "",
        ]
        return content
    }

    static func postActionFailure(label: String, missionID: String, text: String?, error: Error) {
        let content = failureContent(label: label, missionID: missionID, text: text, error: error)
        let request = UNNotificationRequest(identifier: "orb.action.failed.\(missionID).\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { addError in
            if let addError { Log.notifications.error("Could not post failure notification: \(addError.localizedDescription, privacy: .public)") }
        }
    }
}

/// What the user is looking at right now. A banner for an item already on screen
/// (the Inbox, or that conversation) is noise: it stays in Notification Center only.
@MainActor enum OrbOnScreen {
    static var inboxVisible = false
    private static var openMissions: [String: Int] = [:]
    static func opened(_ id: String) { openMissions[id, default: 0] += 1 }
    static func closed(_ id: String) {
        guard let count = openMissions[id] else { return }
        openMissions[id] = count > 1 ? count - 1 : nil
    }
    static func presentation(missionID: String) -> UNNotificationPresentationOptions {
        let visible = inboxVisible || (!missionID.isEmpty && openMissions[missionID] != nil)
        return visible ? [.list, .badge] : [.banner, .list, .sound, .badge]
    }
}

/// The Inbox poll only runs while Orb is on screen, so "done" and "needs you"
/// alerts and the fleet Live Activity froze as soon as the phone locked. iOS
/// grants opportunistic refreshes (roughly every 15 min or more, at its
/// discretion); each one runs the same poll, then asks for the next.
enum OrbBackgroundRefresh {
    static let identifier = "md.thomas.openagent.dashboard.inbox-refresh"
    static let interval: TimeInterval = 15 * 60

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Simulator and Background App Refresh disabled both land here.
            Task { @MainActor in Log.error(.background, "BGTaskScheduler.submit", error) }
        }
    }

    @MainActor static func run() async {
        schedule()
        OrbDiagnosticsClock.lastBackgroundRefresh = Date()
        Log.background.notice("background refresh started")
        guard APIService.shared.isConfigured, APIService.shared.isAuthenticated,
              !APIService.shared.authSessionExpired else { return }
        await OrbNotificationCenter.shared.pollHybridMissionsOnce()
    }
}
