import SwiftUI
import UIKit
import AVFoundation

extension OrbConversation {
    /// User messages Core delivered: events (id = client_message_id) and stored history.
    var deliveredUserMessages: [OrbDeliveredMessage] {
        events.compactMap { e in
            guard e.eventType == "user_message", (e.metadata["queued"]?.value as? Bool) != true else { return nil }
            return OrbDeliveredMessage(id: (e.eventId?.isEmpty ?? true) ? nil : e.eventId, content: e.content, sequence: e.sequence)
        }
    }

    func detachLiveStream() {
        if let token = warmListenerToken, let targetId = id ?? missionID {
            OrbWarmSyncCoordinator.shared.detach(missionId: targetId, token: token)
        }
        warmListenerToken = nil
    }

    func attachLiveStreamIfNeeded() {
        guard warmListenerToken == nil, phase == .active, let id, !isCloud, !unavailable else { return }
        warmListenerToken = OrbWarmSyncCoordinator.shared.attach(
            missionId: id,
            sinceSeq: events.last?.sequence
        ) { type, data, stored in
            if type == "fido_sign_request" {
                FidoApprovalState.shared.handleSignRequest(data)
                return
            }
            if type == "text_delta" {
                live.applyTextDelta(data)
                return
            }
            if type == "text_op" {
                live.applyTextOp(data)
                return
            }
            if type == "user_message" {
                if (data["queued"] as? Bool) == true {
                    Task { await refresh(force: true) }
                    return
                }
                live.resetTurn()
            }
            if let stored {
                let epoch = live.streamEpoch
                events = Self.mergeStoredEvents(existing: events, incoming: [stored])
                if OrbConversationHistory.eventTypes.contains(stored.eventType),
                   case var .object(fields) = mission {
                    fields["history"] = .array(OrbConversationHistory.merge(fields["history"]?.items ?? [], events: [stored]))
                    mission = .object(fields)
                }
                if stored.eventType == "user_message",
                   let opt = optimisticPrompt,
                   Self.sameMessage(stored.content, opt) {
                    optimisticPrompt = nil
                }
                let nextFollowUps = followUps.reconciled(with: deliveredUserMessages)
                if nextFollowUps != followUps {
                    withAnimation(reduceMotion ? nil : .snappy(duration: OrbSendFlow.leaveSeconds)) {
                        followUps = nextFollowUps
                    }
                }
                rebuildWorkModel()
                rebuildHistory()
                live.reconcileStored(events, working: working, streamAdvanced: live.streamEpoch != epoch)
                return
            }
            if type == "mission_settings_updated" {
                let pendingLocalSettings = settingsSaveTask != nil || settingsSyncedGeneration < settingsSaveGeneration
                if !pendingLocalSettings, case var .object(fields) = mission {
                    if let backend = data["backend"] as? String, !backend.isEmpty { fields["backend"] = .string(backend) }
                    if data.keys.contains("model_override") {
                        fields["model_override"] = (data["model_override"] as? String).map(OrbJSON.string) ?? .null
                    }
                    if data.keys.contains("service_tier") {
                        fields["service_tier"] = (data["service_tier"] as? String).map(OrbJSON.string) ?? .null
                    }
                    if let updatedAt = data["updated_at"] as? String { fields["updated_at"] = .string(updatedAt) }
                    let updatedMission = OrbJSON.object(fields)
                    settingsRemoteRevision &+= 1
                    mission = updatedMission
                    OrbReadCache.saveMission(id, value: updatedMission)
                    if !OrbRow(updatedMission).cloud && !showSelection {
                        selection.backend = updatedMission["backend"].text
                        selection.model = updatedMission["model_override"].text
                        selection.serviceTier = OrbCodexSpeed.of(updatedMission)
                    }
                }
                return
            }
            if type == "mission_status_changed" {
                if let newStatus = data["status"] as? String, !newStatus.isEmpty,
                   case var .object(fields) = mission {
                    fields["status"] = .string(newStatus)
                    mission = .object(fields)
                    rebuildWorkModel()
                }
                Task { await refresh(force: true) }
                return
            }
            if type == "stream_lagged" || type == "disconnected" {
                if phase == .active {
                    Task { await refresh(force: true) }
                }
                return
            }
            if ["assistant_message", "assistant_message_canonical", "user_message", "tool_call", "tool_result", "thinking"].contains(type) {
                scheduleCoalescedRefresh()
            }
        }
    }
    /// instead of the full refresh (mission with 200 history messages, queue, events).
    /// Throttled, not debounced, so a busy turn still updates about once a second.
    func scheduleCoalescedRefresh() {
        guard eventRefreshTask == nil else { return }
        eventRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            eventRefreshTask = nil
            guard !Task.isCancelled else { return }
            await refreshEvents()
        }
    }

    /// A long turn starts far before the loaded tail (hundreds or thousands of tool events), so its
    /// user message and task list were missing: the Tasks card vanished on reopen. Fetch both
    /// the latest delivered `user_message` before `first` (even >400 tool calls back) and recent
    /// `tool_call` rows so the turn prompt and Tasks card always stay anchored.
    func hydrateTurnStart(_ id: String) async {
        guard let first = events.first?.sequence,
              first > 1,
              !events.contains(where: { $0.eventType == "user_message" && ($0.metadata["queued"]?.value as? Bool) != true }) else { return }
        async let usersReq = try? await OrbCore.shared.getMissionEventsWithMeta(id: id, types: ["user_message"], limit: 5, beforeSeq: first).events
        async let toolsReq = try? await OrbCore.shared.getMissionEventsWithMeta(id: id, types: ["tool_call"], limit: 400, beforeSeq: first).events
        let (users, tools) = await (usersReq, toolsReq)
        guard id == self.id else { return }
        let startUser = (users ?? []).last(where: { $0.eventType == "user_message" && ($0.metadata["queued"]?.value as? Bool) != true })
        let start = startUser?.sequence ?? 0
        var keep: [StoredEvent] = []
        if let startUser {
            keep.append(startUser)
        }
        for e in tools ?? [] where e.sequence >= start && OrbWorkModel.isTaskListTool(e.toolName) {
            keep.append(e)
        }
        guard !keep.isEmpty else { return }
        let unique = Dictionary((keep + events).map { ($0.sequence, $0) }, uniquingKeysWith: { _, new in new })
        events = unique.values.sorted { $0.sequence < $1.sequence }
    }

    /// Merges newly fetched events with existing events, keeping the newest row per sequence,
    /// deduplicating mutable `text_delta_latest` rows to the highest sequence, and bounding memory.
    static func mergeStoredEvents(existing: [StoredEvent], incoming: [StoredEvent]) -> [StoredEvent] {
        guard !incoming.isEmpty else { return existing }
        let unique = Dictionary((existing + incoming).map { ($0.sequence, $0) }, uniquingKeysWith: { _, new in new })
        var sorted = unique.values.sorted { $0.sequence < $1.sequence }
        if let latestDeltaSeq = sorted.last(where: { $0.eventType == "text_delta" && ($0.eventId == nil || $0.eventId?.isEmpty == true || $0.eventId == "text_delta_latest") })?.sequence {
            sorted.removeAll { $0.eventType == "text_delta" && ($0.eventId == nil || $0.eventId?.isEmpty == true || $0.eventId == "text_delta_latest") && $0.sequence < latestDeltaSeq }
        }
        if sorted.count > 600 {
            let tailStartSeq = sorted[sorted.count - 400].sequence
            let lastUserSeq = sorted.last(where: { $0.eventType == "user_message" && ($0.metadata["queued"]?.value as? Bool) != true })?.sequence ?? 0
            sorted = sorted.filter { e in
                e.sequence >= tailStartSeq || (e.sequence >= lastUserSeq && (e.eventType == "user_message" || OrbWorkModel.isTaskListTool(e.toolName)))
            }
        }
        return sorted
    }

    /// Catches up `events` to `X-Max-Sequence`. Note that `GET .../events?limit=150&since_seq=X`
    /// returns the oldest 150 rows strictly after `X`, whereas omitting `since_seq` returns the
    /// newest rows at the tail. When a reopened conversation lags by hundreds of tool events,
    /// bridge small gaps or jump to the tail so the live tool status and `text_delta_latest` are current.
    func fetchCaughtUpEvents(id: String, existing: [StoredEvent], initialBatch: MissionEventsResult? = nil) async -> [StoredEvent]? {
        let firstBatch: MissionEventsResult?
        if let initialBatch {
            firstBatch = initialBatch
        } else {
            firstBatch = try? await OrbCore.shared.getMissionEventsWithMeta(id: id, limit: 150, sinceSeq: existing.last?.sequence)
        }
        guard let batch = firstBatch, id == self.id, !Task.isCancelled else { return nil }
        var collected = batch.events
        if existing.last?.sequence != nil {
            let maxSeq = batch.maxSequence ?? 0
            var cursor = collected.last?.sequence ?? existing.last?.sequence ?? 0
            if cursor < maxSeq {
                if maxSeq - cursor <= 300 {
                    for _ in 0..<2 where cursor < maxSeq {
                        guard let more = try? await OrbCore.shared.getMissionEventsWithMeta(id: id, limit: 150, sinceSeq: cursor),
                              !more.events.isEmpty, id == self.id, !Task.isCancelled else { break }
                        collected.append(contentsOf: more.events)
                        cursor = more.events.last?.sequence ?? cursor
                    }
                }
                if cursor < maxSeq,
                   let tail = try? await OrbCore.shared.getMissionEventsWithMeta(id: id, limit: 200, sinceSeq: nil),
                   !tail.events.isEmpty, id == self.id, !Task.isCancelled {
                    collected.append(contentsOf: tail.events)
                }
            }
        }
        guard !collected.isEmpty || existing.isEmpty else { return nil }
        return Self.mergeStoredEvents(existing: existing, incoming: collected)
    }

    func refreshEvents() async {
        guard let id, !refreshing, !isCloud else { return }
        let epoch = live.streamEpoch
        guard let merged = await fetchCaughtUpEvents(id: id, existing: events),
              !merged.isEmpty, id == self.id else { return }
        events = merged
        await hydrateTurnStart(id)
        OrbReadCache.saveEvents(id, events: events)
        let nextFollowUps = followUps.reconciled(with: deliveredUserMessages)
        if nextFollowUps != followUps {
            withAnimation(reduceMotion ? nil : .snappy(duration: OrbSendFlow.leaveSeconds)) {
                followUps = nextFollowUps
            }
        }
        rebuildWorkModel()
        rebuildHistory()
        live.reconcileStored(events, working: working, streamAdvanced: live.streamEpoch != epoch)
    }

    /// Refreshes are coalesced, never dropped: a forced refresh requested while one
    /// runs (a user_message, assistant_message or status event) runs right after it,
    /// so the delivered queued message, the reply and the final status all land.
    func refresh(force: Bool = false) async {
        guard id != nil else { return }
        if refreshing { if force { refreshAgain = true }; return }
        var force = force
        repeat {
            refreshAgain = false
            await refreshOnce(force: force)
            force = true
        } while refreshAgain && !Task.isCancelled
    }

    func refreshOnce(force: Bool) async {
        defer { if !deferredSends.isEmpty { Task { await drainDeferredSends() } } }
        guard let id, !refreshing else { return }
        if !force && !working && Date().timeIntervalSince(lastRefresh) < 30 { return }
        refreshing = true; defer { refreshing = false; loading = false }
        do {
            let account = api.endpoint + (api.authToken ?? "")
            let knownCloud = mission != .null && OrbRow(mission).cloud
            let sinceSeq = events.last?.sequence
            let streamEpochBefore = live.streamEpoch
            let settingsGenBefore = settingsSaveGeneration
            let settingsRemoteRevBefore = settingsRemoteRevision
            async let valueTask = OrbReadCache.conversation(id, force: force)
            async let batchTask = knownCloud ? nil : (try? await OrbCore.shared.getMissionEventsWithMeta(id: id, limit: 150, sinceSeq: sinceSeq))
            let savedHistory = mission["history"].items
            let conversationCursor = savedHistory.allSatisfy { $0["sequence"].doubleValue != nil }
                ? savedHistory.compactMap { $0["sequence"].doubleValue }.max().map { Int64($0) } : nil
            async let conversationTask = knownCloud ? nil : (try? await OrbCore.shared.getMissionEventsWithMeta(id: id, types: OrbConversationHistory.eventTypes, limit: 400, sinceSeq: conversationCursor).events)
            let queueFetchedAt = Date()
            async let queueTask: OrbJSON = knownCloud ? .null : ((try? await api.call("/api/control/queue?mission_id=\(OrbCore.escape(id))")) ?? .null)

            var value = try await valueTask
            if value["history"].items.isEmpty && !mission["history"].items.isEmpty, case var .object(dict) = value {
                dict["history"] = mission["history"]
                value = .object(dict)
            }
            let conversation = await conversationTask
            guard !Task.isCancelled, id == self.id, account == api.endpoint + (api.authToken ?? "") else { return }
            if !knownCloud, case var .object(fields) = value {
                if let conversation, !conversation.isEmpty {
                    fields["history"] = .array(OrbConversationHistory.merge(conversationCursor == nil ? [] : savedHistory, events: conversation))
                } else if conversationCursor != nil {
                    fields["history"] = .array(savedHistory)
                }
                let fetchedTs = OrbDateCache.parse(fields["updated_at"]?.text ?? "")
                let currentTs = OrbDateCache.parse(mission["updated_at"].text)
                let pendingLocal = settingsSaveGeneration != settingsGenBefore || settingsSaveTask != nil
                let confirmedRemoteStale = settingsRemoteRevision != settingsRemoteRevBefore
                    || (!pendingLocal && fetchedTs != nil && currentTs != nil && fetchedTs! < currentTs!)
                let settingsStale = pendingLocal || confirmedRemoteStale
                if settingsStale {
                    fields["backend"] = mission["backend"]
                    fields["model_override"] = mission["model_override"]
                    fields["service_tier"] = mission["service_tier"]
                    fields["fast_mode"] = mission["fast_mode"]
                    if !mission["updated_at"].text.isEmpty { fields["updated_at"] = mission["updated_at"] }
                }
                value = .object(fields)
                if confirmedRemoteStale && settingsSaveTask == nil {
                    OrbReadCache.saveMission(id, value: value)
                }
            }
            if mission != value {
                mission = value
            }
            unavailable = !OrbRow(value).mobile
            guard !unavailable else {
                rebuildHistory()
                return
            }
            if OrbRow(value).cloud && execution == .null {
                do {
                    execution = try await OrbReadCache.cloud(id, force: force)
                    selection.restore(execution["selection"])
                } catch let e as OrbHTTPError where e.status == 404 { selection.backend = value["backend"].text; selection.model = value["model_override"].text }
            } else if OrbRow(value).cloud { execution = try await OrbReadCache.cloud(id, force: force) }
            if !OrbRow(value).cloud {
                if !showSelection && settingsSaveTask == nil && settingsSaveGeneration == settingsGenBefore && settingsRemoteRevision == settingsRemoteRevBefore {
                    selection.backend = value["backend"].text
                    selection.model = value["model_override"].text
                    selection.serviceTier = OrbCodexSpeed.of(value)
                    selection.permissionMode = OrbClaudePermissionMode.parse(value["permission_mode"].text).rawValue
                }
                selection.node = OrbContinuation.remoteNodeID(for: value) == "core" ? value["remote_node_id"].text : OrbContinuation.remoteNodeID(for: value)
                if selection.model.isEmpty { selection.model = value["model_override"].text; selection.serviceTier = OrbCodexSpeed.of(value) }
                if value["backend"].text == "codex", let cyber = try? await api.call("/api/control/missions/\(OrbCore.escape(id))/cyber"), OrbCyberAccess.modes.contains(cyber["mode"].text) {
                    selection.cyberMode = cyber["mode"].text
                }
                if let batch = await batchTask,
                   let merged = await fetchCaughtUpEvents(id: id, existing: events, initialBatch: batch) {
                    events = merged
                    await hydrateTurnStart(id)
                    OrbReadCache.saveEvents(id, events: events)
                    rebuildWorkModel()
                }
                OrbWarmSyncCoordinator.shared.markMissionSynced(id, lastSeq: events.last?.sequence)
                OrbWarmSyncCoordinator.shared.reconcile()
                live.reconcileStored(events, working: working, streamAdvanced: live.streamEpoch != streamEpochBefore)
                attachLiveStreamIfNeeded()
                let queueResp = await queueTask
                if queueResp != .null {
                    let rawItems: [OrbJSON] = {
                        if case .object = queueResp { return queueResp["items"].items }
                        return queueResp.items
                    }()
                    queued = rawItems.filter { $0["mission_id"].text == id }
                    let parsedQueue = OrbFollowUpQueue.parseResponse(queueResp, missionID: id)
                    let next = followUps.withServer(
                        parsedQueue.rows,
                        fetchedAt: queueFetchedAt,
                        lastSequence: sinceSeq,
                        incomingServerRev: parsedQueue.revision
                    ).reconciled(with: deliveredUserMessages)
                    if next != followUps { withAnimation(reduceMotion ? nil : .snappy(duration: OrbSendFlow.leaveSeconds)) { followUps = next } }
                }
                else {
                    let next = followUps.reconciled(with: deliveredUserMessages)
                    if next != followUps { withAnimation(reduceMotion ? nil : .snappy(duration: OrbSendFlow.leaveSeconds)) { followUps = next } }
                }
                if let current = handoff {
                    let job = value["remote_job"]
                    let ended = !job["finished_at"].text.isEmpty || !job["terminal_reason"].text.isEmpty
                    if handoffTracker.observe(current, status: value["status"].text, jobID: job["job_id"].text.isEmpty ? nil : job["job_id"].text, jobEnded: ended) {
                        handoff = nil
                        handoffTracker.reset()
                    }
                }
            } else {
                let accounts = (try? await OrbReadCache.cloudAccounts().items) ?? []
                let account = accounts.first { $0["id"].text == execution["selection"]["account"].text && $0["provider"].text == execution["selection"]["provider"].text }
                selection.canCancel = account?["capabilities"]["cancel"].flag ?? false
            }
            if let opt = optimisticPrompt {
                let inHistory = mission["history"].items.contains(where: { $0["role"].text == "user" && Self.sameMessage($0["content"].text, opt) })
                let inEvents = events.contains(where: { $0.eventType == "user_message" && Self.sameMessage($0.content, opt) })
                let inCloud = turns.contains(where: { Self.sameMessage($0["prompt"].text, opt) })
                let inQueue = queued.contains(where: { Self.sameMessage($0["content"].text, opt) })
                if inHistory || inEvents || inCloud || inQueue {
                    optimisticPrompt = nil
                }
            }
            rebuildHistory()
            if execution != .null { OrbDisk.saveAsync(execution, key: "cloud:\(id)") }
            OrbDisk.saveAsync(value, key: "mission:\(id)")
            lastRefresh = Date()
            // The connection is back: a refresh error must not outlive it.
            if error.hasPrefix(Self.connectionErrorPrefix) { error = "" }
        } catch is CancellationError {
            // A superseded refresh is not a connection problem; the next one reports.
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            if mission == .null {
                mission = OrbDisk.read("mission:\(id)", as: OrbJSON.self) ?? .null
                rebuildHistory()
            }
            self.error = Self.connectionErrorPrefix + " \(error.localizedDescription)"
        }
    }

    static let connectionErrorPrefix = "Connection unavailable. Last observed state is preserved."

    /// True once Core accepted the request, even if the refresh that follows fails.
    var canDeferSend: Bool {
        id != nil && !isCloud && attachments.isEmpty && editingQueuedID == nil && Self.btwQuestion(text) == nil
    }

    @discardableResult
    func requireCyberForFollowUp(_ content: String) async throws -> (mode: String, revision: String)? {
        guard !isCloud, id != nil, mission["backend"].text == "codex" else { return nil }
        return try await OrbCyberAccess.requireFollowUp(content, mission: mission, model: selection.model.isEmpty ? nil : selection.model, node: selection.node)
    }

    func validateSkillSelection(_ content: String) async -> String? {
        guard !isCloud, !OrbSkillSlash.skillTokens(content).isEmpty else { return nil }
        if skillItems.isEmpty && skillCatalogError == nil { await loadSkillCatalog() }
        if let err = skillCatalogError { return "\(err). Your draft is kept." }
        let harness = id != nil ? mission["backend"].text : selection.backend
        if let err = OrbSkillSlash.validateSkillSelection(content, harness: harness, available: availableSkillNames) {
            return "\(err). Your draft is kept."
        }
        return nil
    }

    @discardableResult func send() async -> Bool {
        guard !cloudBlocked else { return false }
        switch OrbSendFlow.tapAction(busy: busy, content: text, canQueue: canDeferSend) {
        case .ignore: if busy { return false }
        case .send: break
        case .deferToQueue:
            var content = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if supportsMode && mode != "Message" { content = "/" + mode.lowercased() + " " + content }
            if let skillErr = await validateSkillSelection(content) {
                self.error = skillErr
                return false
            }
            do { try await requireCyberForFollowUp(content) }
            catch {
                self.error = "Message kept. \(OrbCyberAccess.error(error))"
                return false
            }
            let clientID = UUID().uuidString
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                followUps = followUps.enqueue(clientID, content, lastSequence: events.last?.sequence)
                text = ""
                if supportsMode && mode != "Message" { mode = "Message" }
            }
            deferredSends.append((clientID, content))
            OrbUsageTelemetry.shared.trackAction(.queue, surface: "composer")
            Task { await drainDeferredSends() }
            return true
        }
        let sent = await sendNow()
        await drainDeferredSends()
        return sent
    }

    /// Posts follow-ups accepted while a send was in flight, in order, as queued follow-ups.
    /// Runs as soon as the in-flight POST returned (2xx or not), independently of the
    /// refresh that follows it; also retried by every refresh, so a tap is never stranded.
    func drainDeferredSends() async {
        guard let id, OrbSendFlow.canDrain(awaitingAck: awaitingAck, draining: draining, pending: deferredSends.count) else { return }
        draining = true; defer { draining = false }
        var posted = false
        while !deferredSends.isEmpty {
            let next = deferredSends.removeFirst()
            do {
                let cyber = try await requireCyberForFollowUp(next.content)
                var msgBody: [String: OrbJSON] = ["mission_id": .string(id), "content": .string(next.content), "client_message_id": .string(next.id), "queue_followup": .bool(true)]
                if let cyber {
                    msgBody["cyber_access"] = .string(cyber.mode)
                    if !cyber.revision.isEmpty { msgBody["cyber_revision"] = .string(cyber.revision) }
                }
                let result = try await api.call("/api/control/message", method: "POST", body: .object(msgBody))
                guard !result["id"].text.isEmpty, result["message_accepted"] != .bool(false) else { throw OrbHTTPError(status: 409, detail: "Core has not confirmed acceptance.") }
                followUps = followUps.posted(next.id, queued: result["queued"] == .bool(true))
                if result["queued"] != .bool(true) { localTurnStart = Date() }
                posted = true
            } catch {
                followUps = followUps.postFailed(next.id)
                if text.isEmpty { text = next.content }
                self.error = "Message kept. \(OrbCyberAccess.error(error))"
                for rest in deferredSends { followUps = followUps.postFailed(rest.id); text += (text.isEmpty ? "" : "\n") + rest.content }
                deferredSends.removeAll()
                return
            }
        }
        if posted { await refresh(force: true) }
    }

    @discardableResult func sendNow() async -> Bool {
        guard !busy, !cloudBlocked else { return false }
        if let id, !isCloud, let question = Self.btwQuestion(text) {
            sideQuestion = OrbSideQuestionRequest(parent: id, question: question)
            OrbUsageTelemetry.shared.trackAction(.btw, surface: "composer")
            text = ""
            return true
        }
        if let editing = editingQueuedID, id != nil {
            let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return false }
            await editQueued(editing, content: content)
            return true
        }
        busy = true; awaitingAck = true
        defer {
            busy = false
            if awaitingAck { awaitingAck = false; Task { await drainDeferredSends() } }
        }
        let clientID = UUID().uuidString
        // A follow-up during a turn shows at once as a queued row, not as a bubble that jumps away.
        let queueing = working && id != nil && !isCloud && attachments.isEmpty && OrbDisk.read(pendingKey, as: OrbPending.self) == nil
        let savedDraft = text
        let savedAttachments = attachments
        let savedMode = mode
        do {
            let mentionedContext = isCloud ? [] : OrbContextTagging.mentionedItems(in: text, items: contextItems)
            guard supportsAttachments || attachments.isEmpty else { throw OrbHTTPError(status: 400, detail: "This cloud service does not support attachments. Remove the files before sending.") }
            draftSaveTask?.cancel()
            OrbDisk.saveAsync(attachments, key: draftKey + ":files")
            let pending: OrbPending
            if let saved = OrbDisk.read(pendingKey, as: OrbPending.self) {
                pending = saved
                if !isCloud {
                    if saved.path == "/api/control/message" {
                        try await requireCyberForFollowUp(saved.body["content"].text)
                    } else if saved.body["backend"].text == "codex" {
                        let cyber = saved.body["cyber_access"].text
                        try await OrbCyberAccess.require(model: saved.body["model_override"].text, mode: cyber.isEmpty ? "automatic" : cyber, remote: !saved.body["remote_node_id"].text.isEmpty, goal: OrbCyberAccess.isGoal(saved.body["prompt"].text))
                    }
                }
                OrbUsageTelemetry.shared.trackAction(.messageResend, surface: "composer")
                optimisticPrompt = saved.body["content"].text.isEmpty ? saved.body["prompt"].text : saved.body["content"].text
                rebuildHistory()
            } else {
                let uploaded: [OrbJSON] = mentionedContext.map { OrbContextTagging.wireAttachment(for: $0) }
                // Core trims messages; send exactly what it will store so the
                // optimistic bubble is recognised and replaced, not shown twice.
                var prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if supportsMode && mode != "Message" { prompt = "/" + mode.lowercased() + " " + prompt }
                if let skillErr = await validateSkillSelection(prompt) {
                    self.error = skillErr
                    return false
                }
                if !isCloud && (id != nil ? mission["backend"].text : selection.backend) == "codex", let goalErr = OrbCyberAccess.emptyGoalError(prompt) { throw OrbHTTPError(status: 400, detail: goalErr) }
                if id == nil && !selection.cloud && !selection.nodePinnedByUser {
                    let fallback = api.isAdminUser ? "core" : ""
                    if api.isAdminUser && selection.backend == "opencode" && selection.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        selection.node = "core"
                    } else if let cached = OrbReadCache.read("catalog:agent") {
                        selection.node = OrbSelection.firstAvailableNodeID(cached["nodes"]["nodes"].items, backend: selection.backend, includeAdminNodes: api.isAdminUser) ?? fallback
                    }
                }
                if id == nil { try selection.validate() }
                let rawTargetNode = id != nil
                    ? (isCloud ? "core" : OrbContinuation.remoteNodeID(for: mission, fallback: selection.node))
                    : (selection.cloud || selection.node.isEmpty ? "core" : selection.node)
                let uploadTargetNode = OrbManaged.isAutoManagedTarget(rawTargetNode) ? "core" : rawTargetNode
                let goalRequest = OrbCyberAccess.isGoal(prompt)
                var followUpCyberAssertion: (mode: String, revision: String)? = nil
                if !isCloud && (id != nil ? mission["backend"].text : selection.backend) == "codex" {
                    let effectiveModel = id != nil && selection.model.isEmpty ? mission["model_override"].text : selection.model
                    let effectiveCyber: String
                    if let id {
                        let current = try await api.call("/api/control/missions/\(OrbCore.escape(id))/cyber")
                        guard OrbCyberAccess.modes.contains(current["mode"].text) else {
                            throw OrbHTTPError(status: 400, detail: "The backend did not return a Cyber selection. Your draft is kept.")
                        }
                        effectiveCyber = current["mode"].text
                        selection.cyberMode = effectiveCyber
                        followUpCyberAssertion = (mode: effectiveCyber, revision: current["revision"].text)
                    } else {
                        effectiveCyber = selection.cyberMode
                    }
                    try await OrbCyberAccess.require(model: effectiveModel, mode: effectiveCyber, remote: rawTargetNode != "core", goal: goalRequest)
                    if id == nil || selection.serviceTier != OrbCodexSpeed.of(mission) {
                        try await OrbCodexSpeed.require(model: effectiveModel, tier: selection.serviceTier, missionID: id)
                    }
                }
                if let id, !isCloud && !selection.model.isEmpty && selection.model != mission["model_override"].text {
                    guard !working || queueing else { throw OrbHTTPError(status: 409, detail: "Wait for this turn to finish before changing its model.") }
                }
                // Optimistic UI: show the user bubble immediately and clear composer text while sending.
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                    if queueing {
                        OrbUsageTelemetry.shared.trackAction(.queue, surface: "composer")
                        followUps = followUps.enqueue(clientID, prompt, lastSequence: events.last?.sequence)
                        text = ""
                    } else {
                        live.resetTurn()
                        optimisticPrompt = prompt
                        localTurnStart = Date()
                        text = ""
                        scroller.scrollToBottom()
                        rebuildHistory()
                    }
                }
                for file in attachments {
                    let receipt = try await api.call("/api/uploads", method: "POST", body: .object(["node_id": .string(uploadTargetNode), "name": .string(file.name), "data_base64": .string(file.data.base64EncodedString())]))
                    guard !receipt["path"].text.isEmpty else { throw URLError(.cannotParseResponse) }
                    prompt += "\n[Uploaded: " + receipt["path"].text + "]"
                }
                if !queueing {
                    optimisticPrompt = prompt
                    rebuildHistory()
                }
                var body: [String: OrbJSON]
                if let id {
                    body = ["mission_id": .string(id), "content": .string(prompt), "client_message_id": .string(clientID)]
                    if queueing { body["queue_followup"] = .bool(true) }
                    if let cyber = followUpCyberAssertion {
                        body["cyber_access"] = .string(cyber.mode)
                        if !cyber.revision.isEmpty { body["cyber_revision"] = .string(cyber.revision) }
                    }
                    if !uploaded.isEmpty { body["attachments"] = .array(uploaded) }
                    if let identity = OrbContinuation.identity(for: mission) {
                        body["continue_identity"] = identity
                    }
                    if isCloud { body["cloud_model"] = .string(selection.model); body["cloud_model_params"] = selection.params }
                    if let saveTask = settingsSaveTask { await saveTask.value }
                    if !isCloud && selection.model != mission["model_override"].text {
                        let updated = try await api.call("/api/control/missions/\(OrbCore.escape(id))/settings", method: "PATCH", body: .object(["model_override": .string(selection.model), "resume": .bool(false)]))
                        if updated != .null {
                            let merged = Self.mergeConfirmedSettings(updated, into: mission)
                            mission = merged
                            OrbReadCache.saveMission(id, value: merged)
                        }
                    }
                    if !isCloud && selection.backend == "codex" && selection.serviceTier != OrbCodexSpeed.of(mission) {
                        let updated = try await api.call("/api/control/missions/\(OrbCore.escape(id))/settings", method: "PATCH", body: .object(["service_tier": .string(selection.serviceTier), "resume": .bool(false)]))
                        if updated != .null {
                            let merged = Self.mergeConfirmedSettings(updated, into: mission)
                            mission = merged
                            OrbReadCache.saveMission(id, value: merged)
                        }
                    }
                    pending = OrbPending(path: "/api/control/message", body: .object(body))
                } else {
                    let normalizedFolder = OrbRow.normalizeFolder(folder)
                    body = [
                        "title": .string(OrbStyle.missionTitle(prompt)),
                        "prompt": .string(prompt),
                        "project": .string(project),
                        "folder": .string(normalizedFolder),
                        "tags": .array([]),
                        "idempotency_key": .string(UUID().uuidString),
                    ]
                    if !uploaded.isEmpty { body["attachments"] = .array(uploaded) }
                    if selection.cloud { body["cloud"] = selection.wire }
                    else if selection.backend == "codex" {
                        body["service_tier"] = .string(selection.serviceTier)
                        body["cyber_access"] = .string(selection.cyberMode)
                    }
                    if !selection.cloud {
                        body["backend"] = .string(selection.backend)
                        body["model_override"] = .string(selection.model)
                        if selection.backend == "claudecode" {
                            body["permission_mode"] = .string(selection.permissionMode)
                        }
                        if selection.worktreeMode != "auto" {
                            body["worktree_mode"] = .string(selection.worktreeMode)
                        }
                        if !selection.node.isEmpty && selection.node != "core" {
                            body["remote_node_id"] = .string(selection.node)
                            if selection.allow24hCommitment && OrbManaged.isAutoManagedTarget(selection.node) {
                                body["managed_allow_24h_commitment"] = .bool(true)
                            }
                        }
                    }
                    pending = OrbPending(path: "/api/control/missions", body: .object(body))
                }
                try OrbDisk.save(pending, key: pendingKey)
            }
            OrbSendsInFlight.keys.insert(pendingKey)
            defer { OrbSendsInFlight.keys.remove(pendingKey) }
            if pending.path == "/api/control/message", let id, !isCloud {
                let currentStatus = mission["status"].text
                if currentStatus == "paused" || currentStatus == "acknowledged" {
                    _ = try await api.call(
                        "/api/control/missions/\(OrbCore.escape(id))/status",
                        method: "POST",
                        body: .object(["status": .string("awaiting_user")])
                    )
                }
            }
            let result: OrbJSON
            do { result = try await api.call(pending.path, method: "POST", body: pending.body); awaitingAck = false }
            catch { awaitingAck = false; Task { await drainDeferredSends() }; throw error }
            // Acknowledged: follow-ups tapped meanwhile go out now, not after the refresh below.
            Task { await drainDeferredSends() }
            if pending.path == "/api/control/message" {
                guard !result["id"].text.isEmpty, result["message_accepted"] != .bool(false), result["queued"] != .null else { throw OrbHTTPError(status: 409, detail: "Core has not confirmed acceptance. The saved request is retained.") }
            }
            if id == nil { guard !result["id"].text.isEmpty else { throw URLError(.cannotParseResponse) }; id = result["id"].text }
            // A queued follow-up is not in the conversation yet; the queue drawer shows it.
            if pending.path == "/api/control/message" && result["queued"] == .bool(true) {
                optimisticPrompt = nil
                rebuildHistory()
            }
            if queueing {
                let queuedNow = result["queued"] == .bool(true)
                let receiptID = result["id"].text
                if receiptID.isEmpty || receiptID == clientID { followUps = followUps.posted(clientID, queued: queuedNow) }
                else {
                    followUps = followUps.postFailed(clientID)
                    if queuedNow { followUps = followUps.enqueue(receiptID, savedDraft.trimmingCharacters(in: .whitespacesAndNewlines), lastSequence: events.last?.sequence).posted(receiptID, queued: true) }
                }
            }
            if let id {
                OrbReadCache.invalidate("mission:\(id)")
            }
            OrbReadCache.invalidate("project:\(project)")
            OrbReadCache.invalidate("project:\(project):all")
            OrbDisk.remove(pendingKey)
            OrbDisk.remove(draftKey)
            attachments = []
            OrbDisk.remove(draftKey + ":files")
            error = ""
            scroller.scrollToBottom()
            await refresh(force: true)
            return true
        } catch {
            optimisticPrompt = nil
            if queueing { followUps = followUps.postFailed(clientID) }
            rebuildHistory()
            if text.isEmpty { text = savedDraft }
            attachments = savedAttachments
            mode = savedMode
            if let http = error as? OrbHTTPError, [400, 422].contains(http.status) { OrbDisk.remove(pendingKey) }
            self.error = "Message kept. \(OrbCyberAccess.error(error))"
            return false
        }
    }

    /// Waits for a send started by an earlier instance of this screen.
    func settleInFlightSend() async {
        while OrbSendsInFlight.keys.contains(pendingKey) {
            try? await Task.sleep(for: .milliseconds(300))
        }
        optimisticPrompt = nil
        if OrbDisk.read(pendingKey, as: OrbPending.self) != nil {
            error = "An earlier send needs verification. Retry sends the same request without creating a new identity."
        }
        rebuildHistory()
        await refresh(force: true)
    }

    func move(approvalPolicy: String = "check") async {
        guard let id, !destinationProject.isEmpty else { return }
        let normalizedFolder = OrbRow.normalizeFolder(destinationFolder)
        let opID = OrbHierarchy.allocateOpID()
        _ = OrbHierarchy.stageOptimisticPlacement(
            rootIDs: [id],
            project: destinationProject,
            folder: normalizedFolder,
            opID: opID
        )
        do {
            let committed = try await api.moveMissions(
                ids: [id],
                project: destinationProject,
                folder: normalizedFolder,
                approvalPolicy: approvalPolicy,
                clientOpID: opID
            )
            if let mine = committed.first(where: { $0.missionID == id }),
               case var .object(dict) = mission {
                dict["project"] = mine.project.map(OrbJSON.string) ?? .null
                dict["folder"] = .string(mine.folder)
                dict["placement_revision"] = .number(Double(mine.placementRevision))
                mission = .object(dict)
            }
            moving = false
            pendingMoveApproval = nil
            OrbUsageTelemetry.shared.trackAction(.sidebarMove, surface: "conversation")
            OrbReadCache.invalidate("project:\(project)")
            OrbReadCache.invalidate("project:\(project):all")
            OrbReadCache.invalidate("project:\(destinationProject)")
            OrbReadCache.invalidate("project:\(destinationProject):all")
            await refresh(force: true)
        } catch let confirmation as OrbApprovalTransferConfirmationError {
            _ = OrbHierarchy.rollbackOptimisticPlacement(missionIDs: [id], opID: opID)
            moving = false
            pendingMoveApproval = confirmation
        } catch {
            _ = OrbHierarchy.rollbackOptimisticPlacement(missionIDs: [id], opID: opID)
            self.error = error.localizedDescription
        }
    }
    func mutate(_ fields: [String: OrbJSON]) async {
        guard let id else { return }
        do {
            _ = try await api.call("/api/control/missions/\(OrbCore.escape(id))/\(fields["title"] != nil ? "title" : "status")", method: "POST", body: .object(fields))
            OrbReadCache.invalidate("project:\(project)")
            OrbReadCache.invalidate("project:\(project):all")
            await refresh(force: true)
        } catch { self.error = error.localizedDescription }
    }
    func cancel() async {
        guard let id else { return }
        handoff = nil
        do { _ = try await api.call("/api/control/missions/\(OrbCore.escape(id))/\(isCloud ? "cloud/cancel" : "cancel")", method: "POST"); await refresh(force: true) } catch { self.error = error.localizedDescription }
    }
    func removeQueued(_ message: String) async {
        if editingQueuedID == message { editingQueuedID = nil; text = "" }
        withAnimation(reduceMotion ? nil : .snappy(duration: OrbSendFlow.leaveSeconds)) { followUps = followUps.hide(message) }
        do { _ = try await api.call("/api/control/queue/\(OrbCore.escape(message))", method: "DELETE"); await refresh(force: true) }
        catch let e as OrbHTTPError where e.status == 404 { await refresh(force: true) }
        catch {
            followUps = followUps.unhide(message)
            self.error = error.localizedDescription
        }
    }

    func editQueued(_ queueID: String, content: String) async {
        guard let id else { return }
        if let skillErr = await validateSkillSelection(content) {
            self.error = skillErr
            return
        }
        do { try await requireCyberForFollowUp(content) }
        catch {
            self.error = "Message kept. \(OrbCyberAccess.error(error))"
            return
        }
        editingQueuedID = nil
        text = ""
        guard let before = followUps.row(queueID) else {
            error = "This message was already sent. Your edit was not applied."
            return
        }
        let wireContent = OrbMessagePresentation.replaceUserText(before.content, with: content)
        let expectedRev = followUps.expectedRevision(for: queueID)
        let staged = followUps.edit(queueID, wireContent, expectedServerRev: expectedRev)
        guard staged.edits[queueID] == wireContent else {
            error = "This message was already sent, so the edit was not applied."
            return
        }
        followUps = staged
        var patchFields: [String: OrbJSON] = ["content": .string(wireContent)]
        if let expectedRev { patchFields["expected_revision"] = .number(Double(expectedRev)) }
        var status: Int? = nil
        var errorDetail = ""
        do {
            _ = try await api.call("/api/control/queue/\(OrbCore.escape(queueID))", method: "PATCH", body: .object(patchFields))
            status = 200
        } catch let e as OrbHTTPError {
            status = e.status
            errorDetail = e.detail
        } catch {
            status = nil
        }
        switch OrbSendFlow.editOutcome(status: status) {
        case .edited:
            followUps = followUps.editConfirmed(queueID, wireContent, expectedServerRev: expectedRev)
            OrbUsageTelemetry.shared.trackAction(.messageEdit, surface: "queue")
        case .unsupported:
            followUps = followUps.editReverted(queueID)
            error = "This edit cannot be saved atomically. The queued messages have not been changed."
        case .alreadySent:
            followUps = followUps.editReverted(queueID)
            let isRevConflict = status == 409 && (errorDetail.localizedCaseInsensitiveContains("revision") || errorDetail.localizedCaseInsensitiveContains("stale"))
            error = isRevConflict
                ? "Queue changed on another client; refreshed queue before editing."
                : "This message was already sent, so the edit was not applied."
        case .failed:
            followUps = followUps.editReverted(queueID)
            error = "Couldn’t save the edit."
        }
        await refresh(force: true)
    }

    /// Send now: the row leaves and the bubble appears together; Core promotes the
    /// message (stop, then it next under the same id) or injects it live.
    func sendQueuedNow(_ queueID: String) async {
        guard let id, editingQueuedID == nil, let row = followUps.row(queueID), !row.sending else { return }
        do { try await requireCyberForFollowUp(row.content) }
        catch {
            self.error = "Couldn’t send now. \(OrbCyberAccess.error(error))"
            return
        }
        let started = OrbHandoff(id: queueID, at: Date())
        withAnimation(reduceMotion ? nil : .snappy(duration: OrbSendFlow.leaveSeconds)) {
            followUps = followUps.hide(queueID)
            live.resetTurn()
            optimisticPrompt = OrbMessagePresentation.parse(row.content).text.trimmingCharacters(in: .whitespacesAndNewlines)
            handoff = started
            handoffTracker.reset()
            scroller.scrollToBottom()
            rebuildHistory()
        }
        Task {
            try? await Task.sleep(for: .seconds(OrbHandoff.timeout))
            if handoff == started { handoff = nil }
        }
        do {
            let response = try await api.call("/api/control/queue/\(OrbCore.escape(queueID))/send-now?interrupt=true", method: "POST")
            switch OrbSendFlow.sendNowOutcome(response) {
            case .live: handoff = nil
            case .promoted: break
            case .fallback:
                // Older Core without promote: stop the turn, then send this message.
                _ = try? await api.call("/api/control/queue/\(OrbCore.escape(queueID))", method: "DELETE")
                _ = try? await api.call("/api/control/missions/\(OrbCore.escape(id))/cancel", method: "POST")
                let plainContent = OrbMessagePresentation.parse(row.content).text
                _ = try await api.call("/api/control/message", method: "POST", body: .object(["mission_id": .string(id), "content": .string(plainContent), "client_message_id": .string(UUID().uuidString)]))
            }
            OrbReadCache.invalidate("mission:\(id)")
            await refresh(force: true)
        } catch {
            withAnimation(reduceMotion ? nil : .snappy(duration: OrbSendFlow.leaveSeconds)) {
                followUps = followUps.unhide(queueID)
                optimisticPrompt = nil
                handoff = nil
                rebuildHistory()
            }
            self.error = "Couldn’t send now. \(error.localizedDescription)"
        }
    }

    func forceSlot() async {
        guard let id, !forcingSlot else { return }
        forcingSlot = true
        defer { forcingSlot = false }
        do {
            let updated = try await api.call("/api/control/missions/\(OrbCore.escape(id))/force-slot", method: "POST")
            if updated != .null {
                mission = updated
                OrbDisk.saveAsync(updated, key: "mission:\(id)")
            }
            OrbReadCache.invalidate("mission:\(id)")
            await refresh(force: true)
        } catch {
            self.error = "Couldn’t run immediately. \(error.localizedDescription)"
        }
    }

    private static func mergeConfirmedSettings(_ updated: OrbJSON, into current: OrbJSON, keepOptimisticSettings: Bool = false) -> OrbJSON {
        guard case var .object(base) = current else { return updated }
        guard case let .object(incoming) = updated else { return current }
        if base["history"]?.items.isEmpty ?? true, let hist = incoming["history"], !hist.items.isEmpty {
            base["history"] = hist
        }
        let settingsKeys = ["backend", "agent", "model_override", "model_effort", "fast_mode", "service_tier", "config_profile", "session_id"]
        if !keepOptimisticSettings {
            for k in settingsKeys {
                if let v = incoming[k] { base[k] = v }
            }
        }
        if let incomingTs = incoming["updated_at"]?.text, !incomingTs.isEmpty {
            let curDate = OrbDateCache.parse(base["updated_at"]?.text ?? "")
            let nextDate = OrbDateCache.parse(incomingTs)
            if curDate == nil || (nextDate != nil && nextDate! >= curDate!) {
                base["updated_at"] = .string(incomingTs)
            }
        }
        return .object(base)
    }

    func scheduleMissionSettingsSave() {
        guard let id, !isCloud else { return }
        let storedBackend = mission["backend"].text
        if !storedBackend.isEmpty && selection.backend != storedBackend { return }
        let currentModel = mission["model_override"].text
        let currentTier = OrbCodexSpeed.of(mission)
        if settingsSaveTask == nil && settingsSyncedGeneration == settingsSaveGeneration {
            confirmedSettingsBaseline = (model: currentModel, tier: currentTier)
        } else if confirmedSettingsBaseline == nil {
            confirmedSettingsBaseline = (model: currentModel, tier: currentTier)
        }
        let nextModel = selection.model
        let nextTier = selection.serviceTier
        let currentPermission = OrbClaudePermissionMode.parse(mission["permission_mode"].text).rawValue
        let nextPermission = selection.permissionMode
        let permissionChanged = selection.backend == "claudecode" && nextPermission != currentPermission
        if permissionChanged {
            if case var .object(fields) = mission {
                fields["permission_mode"] = .string(nextPermission)
                mission = .object(fields)
            }
            Task {
                do {
                    _ = try await api.call(
                        "/api/control/missions/\(OrbCore.escape(id))/permission-mode",
                        method: "POST",
                        body: .object(["permission_mode": .string(nextPermission)])
                    )
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        let modelChanged = nextModel != currentModel
        let tierChanged = selection.backend == "codex" && nextTier != currentTier
        guard modelChanged || tierChanged else { return }

        if case var .object(fields) = mission {
            if modelChanged {
                fields["model_override"] = nextModel.isEmpty ? .null : .string(nextModel)
            }
            if tierChanged {
                fields["service_tier"] = .string(nextTier)
            }
            mission = .object(fields)
        }
        settingsSaveGeneration &+= 1
        let gen = settingsSaveGeneration
        let priorTask = settingsSaveTask
        let task = Task {
            if let priorTask { await priorTask.value }
            defer {
                if gen > settingsSyncedGeneration { settingsSyncedGeneration = gen }
                if settingsSaveGeneration == gen {
                    settingsSaveTask = nil
                    confirmedSettingsBaseline = nil
                }
            }
            do {
                let confirmed = confirmedSettingsBaseline ?? (model: currentModel, tier: currentTier)
                var patch: [String: OrbJSON] = ["resume": .bool(false)]
                if modelChanged || nextModel != confirmed.model { patch["model_override"] = .string(nextModel) }
                if selection.backend == "codex" && (tierChanged || nextTier != confirmed.tier) {
                    try await OrbCodexSpeed.require(model: nextModel.isEmpty ? confirmed.model : nextModel, tier: nextTier, missionID: id)
                    patch["service_tier"] = .string(nextTier)
                }
                let updated = try await api.call("/api/control/missions/\(OrbCore.escape(id))/settings", method: "PATCH", body: .object(patch))
                if updated != .null, self.id == id {
                    confirmedSettingsBaseline = (model: updated["model_override"].text, tier: OrbCodexSpeed.of(updated))
                    let confirmedForCache = Self.mergeConfirmedSettings(updated, into: mission)
                    OrbReadCache.saveMission(id, value: confirmedForCache)
                    mission = Self.mergeConfirmedSettings(updated, into: mission, keepOptimisticSettings: settingsSaveGeneration != gen)
                }
            } catch {
                if self.id == id {
                    if settingsSaveGeneration == gen {
                        let fallback = confirmedSettingsBaseline ?? (model: currentModel, tier: currentTier)
                        selection.model = fallback.model
                        selection.serviceTier = fallback.tier
                        if case var .object(fields) = mission {
                            fields["model_override"] = fallback.model.isEmpty ? .null : .string(fallback.model)
                            if selection.backend == "codex" { fields["service_tier"] = .string(fallback.tier) }
                            let reverted = OrbJSON.object(fields)
                            mission = reverted
                            OrbReadCache.saveMission(id, value: reverted)
                        }
                    }
                    self.error = error.localizedDescription
                }
            }
        }
        settingsSaveTask = task
    }

    func safeURL(_ value: String) -> URL? { guard let url = URL(string: value), url.scheme == "https", url.user == nil, url.password == nil else { return nil }; return url }

    func openWorkspaceOrArtifact(_ rawLink: String) async {
        if rawLink.hasPrefix("file:///") {
            guard let url = URL(string: rawLink) else { return }
            await downloadWorkspaceFile(url.path)
        } else if rawLink.hasPrefix("/srv/") || rawLink.hasPrefix("/Users/") || rawLink.hasPrefix("/root/") || rawLink.hasPrefix("/workspace/") || rawLink.hasPrefix("/home/") || rawLink.hasPrefix("/var/") || rawLink.hasPrefix("/tmp/") {
            let cleanPath = rawLink.components(separatedBy: "#").first ?? rawLink
            await downloadWorkspaceFile(cleanPath)
        } else {
            await download(rawLink.replacingOccurrences(of: "sandbox:", with: ""))
        }
    }

    func downloadWorkspaceFile(_ path: String) async {
        let token = OrbCore.shared.authToken ?? ""
        var candidates: [[URLQueryItem]] = []
        if let id { candidates.append([.init(name: "path", value: path), .init(name: "mission_id", value: id)]) }
        candidates.append([.init(name: "path", value: path)])
        for query in candidates {
            var components = URLComponents(string: OrbCore.shared.endpoint + "/api/fs/download")
            components?.queryItems = query
            guard let url = components?.url else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (tempFile, response) = try? await URLSession.shared.download(for: request) else { continue }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                try? FileManager.default.removeItem(at: tempFile)
                continue
            }
            let name = path.components(separatedBy: "/").last ?? "file"
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let dest = directory.appendingPathComponent(["", ".", ".."].contains(name) ? "file" : name)
            try? FileManager.default.moveItem(at: tempFile, to: dest)
            preview = OrbPreviewFile(url: dest)
            return
        }
        error = "File preview unavailable for \(path.components(separatedBy: "/").last ?? path)."
    }

    func download(_ path: String) async {
        guard let id else { return }
        do {
            let result = try await api.call("/api/control/missions/\(OrbCore.escape(id))/cloud/artifact?path=\(OrbCore.escape(path))")
            if let url = safeURL(result["url"].text) { await UIApplication.shared.open(url) }
            else if let data = Data(base64Encoded: result["content_base64"].text), data.count <= 50 * 1024 * 1024 {
                let name = (result["name"].text.isEmpty ? path : result["name"].text).components(separatedBy: "/").last ?? "artifact"
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(["", ".", ".."].contains(name) ? "artifact" : name)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); preview = OrbPreviewFile(url: url)
            } else { error = "Artifact download unavailable." }
        } catch { self.error = error.localizedDescription }
    }
}
