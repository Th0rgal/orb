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

    /// Tool and thinking events only add events: fetch those since the last sequence
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

    /// A long turn starts far before the loaded tail (hundreds of tool events), so its
    /// user message and task list were missing: the Tasks card vanished on reopen. Fetch
    /// only the turn's start and its task-list calls (small tool-call rows, no results).
    func hydrateTurnStart(_ id: String) async {
        guard let first = events.first?.sequence, first > 1, !events.contains(where: { $0.eventType == "user_message" }) else { return }
        guard let older = try? await OrbCore.shared.getMissionEventsWithMeta(id: id, types: ["user_message", "tool_call"], limit: 400, beforeSeq: first).events,
              id == self.id else { return }
        let start = older.last(where: { $0.eventType == "user_message" })?.sequence ?? 0
        let keep = older.filter { e in
            e.sequence >= start && (e.eventType == "user_message" || OrbWorkModel.isTaskListTool(e.toolName))
        }
        guard !keep.isEmpty else { return }
        let unique = Dictionary((keep + events).map { ($0.sequence, $0) }, uniquingKeysWith: { _, new in new })
        events = unique.values.sorted { $0.sequence < $1.sequence }
    }

    func refreshEvents() async {
        guard let id, !refreshing, !isCloud else { return }
        guard let batch = try? await OrbCore.shared.getMissionEventsWithMeta(id: id, limit: 150, sinceSeq: events.last?.sequence),
              !batch.events.isEmpty, id == self.id else { return }
        let unique = Dictionary((events + batch.events).map { ($0.sequence, $0) }, uniquingKeysWith: { old, _ in old })
        events = unique.values.sorted { $0.sequence < $1.sequence }
        OrbReadCache.saveEvents(id, events: events)
        rebuildWorkModel()
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
            let knownCloud = mission != .null && OrbRow(mission).cloud
            let sinceSeq = events.last?.sequence
            async let valueTask = OrbReadCache.conversation(id, force: force)
            async let batchTask = knownCloud ? nil : (try? await OrbCore.shared.getMissionEventsWithMeta(id: id, limit: 150, sinceSeq: sinceSeq))
            let queueFetchedAt = Date()
            async let queueTask: OrbJSON = knownCloud ? .null : ((try? await api.call("/api/control/queue")) ?? .null)

            var value = try await valueTask
            if value["history"].items.isEmpty && !mission["history"].items.isEmpty, case var .object(dict) = value {
                dict["history"] = mission["history"]
                value = .object(dict)
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
                if stream == nil && phase == .active {
                    let token = UUID()
                    streamToken = token
                    let inner = OrbCore.shared.streamControl(missionId: id, sinceSeq: events.last?.sequence, preferWebSocket: false) { type, data in
                        if type == "fido_sign_request" { FidoApprovalState.shared.handleSignRequest(data); return }
                        if type == "text_delta", let delta = data["delta"] as? String ?? data["content"] as? String {
                            liveText += delta
                        } else if type == "text_op" {
                            let op = data["op"] as? String ?? ""
                            let content = data["content"] as? String ?? ""
                            if op == "append" { liveText += content }
                            else if op == "replace" { liveText = content }
                        }
                        if ["assistant_message", "mission_status_changed", "user_message"].contains(type) {
                            Task { await refresh(force: true) }
                        } else if ["tool_call", "tool_result", "thinking"].contains(type) {
                            scheduleCoalescedRefresh()
                        }
                    }
                    // The SSE task ends when Core closes or idles the stream. Forget it so the
                    // next refresh reconnects; a stale non-nil handle stopped all live updates.
                    stream = Task {
                        await withTaskCancellationHandler { await inner.value } onCancel: { inner.cancel() }
                        guard !Task.isCancelled else { return }
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled, streamToken == token else { return }
                        stream = nil
                        if phase == .active { await refresh(force: true) }
                    }
                }
                if !working { liveText = "" }
                selection.backend = value["backend"].text
                selection.node = value["remote_node_id"].text
                if selection.model.isEmpty { selection.model = value["model_override"].text; selection.serviceTier = OrbCodexSpeed.of(value) }
                if let batch = await batchTask, (!batch.events.isEmpty || events.isEmpty) {
                    let unique = Dictionary((events + batch.events).map { ($0.sequence, $0) }, uniquingKeysWith: { old, _ in old })
                    events = unique.values.sorted { $0.sequence < $1.sequence }
                    await hydrateTurnStart(id)
                    OrbReadCache.saveEvents(id, events: events)
                    rebuildWorkModel()
                }
                let queueResp = await queueTask
                if queueResp != .null {
                    queued = queueResp.items.filter { $0["mission_id"].text == id }
                    let next = followUps.withServer(OrbFollowUpQueue.parse(queueResp.items, missionID: id), fetchedAt: queueFetchedAt, lastSequence: sinceSeq)
                        .reconciled(with: deliveredUserMessages)
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

    @discardableResult func send() async -> Bool {
        guard !cloudBlocked else { return false }
        switch OrbSendFlow.tapAction(busy: busy, content: text, canQueue: canDeferSend) {
        case .ignore: if busy { return false }
        case .send: break
        case .deferToQueue:
            let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let clientID = UUID().uuidString
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                followUps = followUps.enqueue(clientID, content, lastSequence: events.last?.sequence)
                text = ""
            }
            deferredSends.append((clientID, content))
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
                let result = try await api.call("/api/control/message", method: "POST", body: .object(["mission_id": .string(id), "content": .string(next.content), "client_message_id": .string(next.id), "queue_followup": .bool(true)]))
                guard !result["id"].text.isEmpty, result["message_accepted"] != .bool(false) else { throw OrbHTTPError(status: 409, detail: "Core has not confirmed acceptance.") }
                followUps = followUps.posted(next.id, queued: result["queued"] == .bool(true))
                if result["queued"] != .bool(true) { localTurnStart = Date() }
                posted = true
            } catch {
                followUps = followUps.postFailed(next.id)
                if text.isEmpty { text = next.content }
                self.error = "Message kept. \(error.localizedDescription)"
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
            guard !isCloud || attachments.isEmpty else { throw OrbHTTPError(status: 400, detail: "This cloud service does not support attachments. Remove the files before sending.") }
            draftSaveTask?.cancel()
            OrbDisk.saveAsync(attachments, key: draftKey + ":files")
            let pending: OrbPending
            if let saved = OrbDisk.read(pendingKey, as: OrbPending.self) {
                pending = saved
                optimisticPrompt = saved.body["content"].text.isEmpty ? saved.body["prompt"].text : saved.body["content"].text
                rebuildHistory()
            } else {
                var uploaded: [OrbJSON] = mentionedContext.map { OrbContextTagging.wireAttachment(for: $0) }
                // Core trims messages; send exactly what it will store so the
                // optimistic bubble is recognised and replaced, not shown twice.
                var prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if supportsMode && mode != "Message" { prompt = "/" + mode.lowercased() + " " + prompt }
                // Optimistic UI: show the user bubble immediately and clear composer text while sending.
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                    if queueing {
                        followUps = followUps.enqueue(clientID, prompt, lastSequence: events.last?.sequence)
                        text = ""
                    } else {
                        optimisticPrompt = prompt
                        localTurnStart = Date()
                        text = ""
                        scroller.scrollToBottom()
                        rebuildHistory()
                    }
                }
                for file in attachments {
                    let receipt = try await api.call("/api/uploads", method: "POST", body: .object(["node_id": .string(selection.node.isEmpty ? "core" : selection.node), "name": .string(file.name), "data_base64": .string(file.data.base64EncodedString())]))
                    guard !receipt["path"].text.isEmpty else { throw URLError(.cannotParseResponse) }
                    uploaded.append(.object(["kind": .string("file"), "path": receipt["path"]]))
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
                    if !uploaded.isEmpty { body["attachments"] = .array(uploaded) }
                    if let identity = OrbContinuation.identity(for: mission) {
                        body["continue_identity"] = identity
                    }
                    if isCloud { body["cloud_model"] = .string(selection.model); body["cloud_model_params"] = selection.params }
                    if !isCloud && !selection.model.isEmpty && selection.model != mission["model_override"].text {
                        guard !working || optimisticPrompt != nil || queueing else { throw OrbHTTPError(status: 409, detail: "Wait for this turn to finish before changing its model.") }
                        _ = try await api.call("/api/control/missions/\(OrbCore.escape(id))/settings", method: "PATCH", body: .object(["model_override": .string(selection.model)]))
                    }
                    if !isCloud && selection.backend == "codex" && selection.serviceTier != OrbCodexSpeed.of(mission) {
                        try await OrbCodexSpeed.require(model: selection.model.isEmpty ? mission["model_override"].text : selection.model, tier: selection.serviceTier, missionID: id)
                        _ = try await api.call("/api/control/missions/\(OrbCore.escape(id))/settings", method: "PATCH", body: .object(["service_tier": .string(selection.serviceTier)]))
                    }
                    pending = OrbPending(path: "/api/control/message", body: .object(body))
                } else {
                    try selection.validate()
                    body = ["title": .string(OrbStyle.missionTitle(prompt)), "prompt": .string(prompt), "project": .string(project), "tags": .array(folder.isEmpty ? [] : [.string("orb-folder:\(folder)")]), "idempotency_key": .string(UUID().uuidString)]
                    if !uploaded.isEmpty { body["attachments"] = .array(uploaded) }
                    if selection.cloud { body["cloud"] = selection.wire }
                    else if selection.backend == "codex" { try await OrbCodexSpeed.require(model: selection.model, tier: selection.serviceTier); body["service_tier"] = .string(selection.serviceTier) }
                    if !selection.cloud { body["backend"] = .string(selection.backend); body["model_override"] = .string(selection.model); if !selection.node.isEmpty && selection.node != "core" { body["remote_node_id"] = .string(selection.node) } }
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
            self.error = "Message kept. \(error.localizedDescription)"
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

    func move() async {
        guard let id, !destinationProject.isEmpty else { return }
        var tags = mission["tags"].items.filter { !$0.text.hasPrefix("orb-folder:") }
        if !destinationFolder.isEmpty { tags.append(.string("orb-folder:" + destinationFolder)) }
        do {
            _ = try await api.call("/api/control/missions/\(OrbCore.escape(id))/project", method: "POST", body: .object(["project": .string(destinationProject), "tags": .array(tags)]))
            moving = false
            OrbReadCache.invalidate("project:\(project)")
            OrbReadCache.invalidate("project:\(project):all")
            OrbReadCache.invalidate("project:\(destinationProject)")
            OrbReadCache.invalidate("project:\(destinationProject):all")
            await refresh(force: true)
        } catch { self.error = error.localizedDescription }
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

    /// Edit in place via PATCH (same id and position); replace on 404/405 (older Core).
    func editQueued(_ queueID: String, content: String) async {
        guard let id else { return }
        editingQueuedID = nil
        text = ""
        guard followUps.row(queueID) != nil else {
            error = "This message was already sent. Your edit was not applied."
            return
        }
        followUps = followUps.edit(queueID, content)
        var status: Int? = nil
        do {
            _ = try await api.call("/api/control/queue/\(OrbCore.escape(queueID))", method: "PATCH", body: .object(["content": .string(content)]))
            status = 200
        } catch let e as OrbHTTPError { status = e.status } catch { status = nil }
        switch OrbSendFlow.editOutcome(status: status) {
        case .edited:
            followUps = followUps.editConfirmed(queueID, content)
        case .unsupported:
            followUps = followUps.editReverted(queueID).hide(queueID)
            _ = try? await api.call("/api/control/queue/\(OrbCore.escape(queueID))", method: "DELETE")
            let clientID = UUID().uuidString
            followUps = followUps.enqueue(clientID, content, lastSequence: events.last?.sequence)
            do {
                let result = try await api.call("/api/control/message", method: "POST", body: .object(["mission_id": .string(id), "content": .string(content), "client_message_id": .string(clientID), "queue_followup": .bool(true)]))
                followUps = followUps.posted(clientID, queued: result["queued"] == .bool(true))
            } catch {
                followUps = followUps.postFailed(clientID)
                text = content
                self.error = "Couldn’t save the edit. Your text is back in the composer."
            }
        case .alreadySent:
            followUps = followUps.editReverted(queueID)
            error = "This message was already sent, so the edit was not applied."
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
        let started = OrbHandoff(id: queueID, at: Date())
        withAnimation(reduceMotion ? nil : .snappy(duration: OrbSendFlow.leaveSeconds)) {
            followUps = followUps.hide(queueID)
            optimisticPrompt = row.content.trimmingCharacters(in: .whitespacesAndNewlines)
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
                _ = try await api.call("/api/control/message", method: "POST", body: .object(["mission_id": .string(id), "content": .string(row.content), "client_message_id": .string(UUID().uuidString)]))
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
