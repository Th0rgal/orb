import SwiftUI

struct OrbConversation: View {
    let missionID: String?
    let project: String
    let folder: String
    @State private var id: String?
    @State private var loading = true
    @State private var visibleCount = 20
    @State private var followsLatest = true
    @State private var userScrolling = false
    @State private var atBottom = true
    @State private var openedAtLatest = false
    @State private var mission: OrbJSON = .null
    @State private var execution: OrbJSON = .null
    @State private var text = ""
    @State private var error = ""
    @State private var busy = false
    @State private var unavailable = false
    @State private var selection = OrbSelection()
    @State private var showSelection = false
    @State private var showContext = false
    @State private var rename = false
    @State private var moving = false
    @State private var destinationProject = ""
    @State private var destinationFolder = ""
    @State private var title = ""
    @State private var attachments: [OrbAttachment] = []
    @State private var preview: OrbPreviewFile?
    @State private var events: [StoredEvent] = []
    @State private var queued: [OrbJSON] = []
    @State private var mode = "Message"
    @State private var refreshing = false
    @State private var lastRefresh = Date.distantPast
    @State private var stream: Task<Void, Never>?
    @State private var liveText = ""
    @State private var answered: Set<String> = []
    @FocusState private var composerFocused: Bool
    @Environment(\.scenePhase) private var phase
    private let api = OrbCore.shared
    private var draftKey: String { "draft:\(missionID ?? "new:\(project):\(folder)")" }
    private var pendingKey: String { draftKey + ":pending" }
    private var turns: [OrbJSON] { execution["turns"].items }
    private var isCloud: Bool { execution != .null || !mission["cloud"]["provider"].text.isEmpty || (id == nil && selection.cloud) }
    static let workingPhases: Set<String> = ["queued", "submitting", "running", "cancel_requested"]
    private var working: Bool { isCloud ? turns.contains { Self.workingPhases.contains($0["phase"].text) } : ["active", "pending"].contains(mission["status"].text) }
    /// Same wording as the desktop: the step, then how long Orb has seen it working.
    private func progress(at now: Date) -> String {
        let turn = turns.first { Self.workingPhases.contains($0["phase"].text) }
        let key = turn?["key"].text ?? "local:\(id ?? "")"
        let started = OrbWorkClock.start(key)
        let seconds = max(0, Int(now.timeIntervalSince(started)))
        let provider = ["chatgpt": "ChatGPT", "cursor_cloud": "Cursor Cloud", "grok_bot": "Grok Bot"][execution["selection"]["provider"].text] ?? "the service"
        let label: String
        if let turn {
            switch turn["phase"].text {
            case "cancel_requested": label = "Stopping…"
            case "queued": label = "Queued…"
            case "submitting": label = turn["detail"].text.isEmpty ? "Opening \(provider)…" : turn["detail"].text
            default: label = !turn["result"].text.isEmpty ? "Writing…" : (turn["detail"].text.isEmpty ? "Thinking…" : turn["detail"].text)
            }
        } else { label = "Working…" }
        return "\(label) · \(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
    /// Only the latest ChatGPT answer becomes an interactive quiz, like the desktop.
    private func quiz(for item: (String, String, String)) -> OrbQuizData? {
        guard isCloud, execution["selection"]["provider"].text == "chatgpt", let last = turns.last, item.0 == last["key"].text + ":a", !Self.workingPhases.contains(last["phase"].text) else { return nil }
        return OrbQuizData.parse(item.2)
    }
    /// Sends quiz answers through the normal, idempotent send path; the typed draft is restored after.
    private func sendReply(_ reply: String) async -> Bool {
        // Retrying the same answers reuses the saved request and its message id.
        if let pending = OrbDisk.read(pendingKey, as: OrbPending.self), pending.body["content"].text != reply {
            error = "Another message is still being confirmed. Send it before answering the quiz."
            return false
        }
        let draft = text; text = reply
        // Acceptance, not the refresh that follows, decides whether the quiz was sent.
        let sent = await send()
        // The quiz keeps its own answers; what was being typed survives every outcome.
        text = draft
        return sent
    }
    private var cloudBlocked: Bool { isCloud && turns.contains { ["submission_uncertain", "incompatible", "reconnect_required"].contains($0["phase"].text) } }
    private var status: String { (turns.last?["phase"].text ?? mission["status"].text).replacingOccurrences(of: "_", with: " ") }
    private var history: [(String, String, String)] {
        if isCloud { return turns.flatMap { turn in [(turn["key"].text + ":u", "user", turn["prompt"].text), (turn["key"].text + ":a", "assistant", turn["result"].text)].filter { !$0.2.isEmpty } } }
        return mission["history"].items.enumerated().map { (String($0.offset), $0.element["role"].text, $0.element["content"].text) }
    }
    var body: some View {
        ScrollViewReader { scroll in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if unavailable { ContentUnavailableView("Available on your Mac", systemImage: "laptopcomputer", description: Text("This conversation runs locally in Orb and cannot be controlled from iOS.")) }
                else {
                    if loading && missionID != nil && mission == .null { ProgressView("Loading conversation…").frame(maxWidth: .infinity) }
                    if missionID == nil && id == nil { VStack(alignment: .leading, spacing: 8) { Text("What would you like to work on?").font(.title2); Text(folder.isEmpty ? project : "\(project) / \(folder)").font(.subheadline).foregroundStyle(.secondary) }.padding(.top, 20) }
                    if history.count > visibleCount {
                        Button("Load earlier messages") {
                            let anchor = history.suffix(visibleCount).first?.0
                            followsLatest = false
                            visibleCount += 20
                            Task { @MainActor in
                                await Task.yield()
                                if let anchor { scroll.scrollTo(anchor, anchor: .top) }
                            }
                        }.font(.subheadline).frame(maxWidth: .infinity).accessibilityIdentifier("load-earlier")
                    }
                    ForEach(Array(history.suffix(visibleCount)), id: \.0) { item in
                        if item.1 == "user" {
                            let images = OrbMessageImages.parse(item.2)
                            HStack { Spacer(minLength: 42); VStack(alignment: .leading, spacing: 10) {
                                if !images.paths.isEmpty { OrbImageStrip(images: images, missionID: id) }
                                if !images.text.isEmpty { Text(images.text).textSelection(.enabled) }
                            }.padding(18).background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 26)) }.id(item.0)
                        } else if let quiz = quiz(for: item) {
                            VStack(alignment: .leading, spacing: 16) {
                                if !quiz.before.isEmpty { OrbRichText(source: quiz.before) }
                                OrbQuiz(quiz: quiz, disabled: busy || cloudBlocked || working) { reply in await sendReply(reply) }
                                if !quiz.after.isEmpty { OrbRichText(source: quiz.after) }
                            }.frame(maxWidth: .infinity, alignment: .leading).id(item.0)
                        } else { OrbRichText(source: item.2, onArtifact: { path in Task { await download(path.replacingOccurrences(of: "sandbox:", with: "")) } }).frame(maxWidth: .infinity, alignment: .leading).id(item.0) }
                    }
                    ForEach(turns.indices, id: \.self) { index in
                        let turn = turns[index]
                        if !turn["detail"].text.isEmpty && !Self.workingPhases.contains(turn["phase"].text) { Text(turn["detail"].text).font(.footnote).foregroundStyle(.secondary) }
                        ForEach(turn["branches"].items.indices, id: \.self) { branchIndex in
                            if let url = safeURL(turn["branches"].items[branchIndex]["prUrl"].text) { Link("View pull request", destination: url) }
                        }
                        ForEach(turn["artifacts"].items.indices, id: \.self) { artifactIndex in
                            let artifact = turn["artifacts"].items[artifactIndex]
                            Button { Task { await download(artifact["path"].text) } } label: { Label(artifact["path"].text.components(separatedBy: "/").last ?? "File", systemImage: "doc") }
                        }
                    }
                    if working && !liveText.isEmpty { OrbRichText(source: liveText) }
                    ForEach(events.filter { event in
                        event.eventType == "tool_call" && ["ui_native_request", "AskUserQuestion", "question"].contains(event.toolName ?? "") && !answered.contains(event.toolCallId ?? "") && !events.contains(where: { $0.eventType == "tool_result" && $0.toolCallId == event.toolCallId })
                    }) { event in
                        if let data = event.content.data(using: .utf8), let request = try? JSONDecoder().decode(OrbJSON.self, from: data) {
                            OrbQuestion(event: event, request: request) { answered.insert(event.toolCallId ?? "") }
                        }
                    }
                    if !events.isEmpty {
                        DisclosureGroup("Activity") {
                            ForEach(events.filter { ["tool_call", "tool_result", "goal_status", "goal_iteration"].contains($0.eventType) }.suffix(30)) { event in
                                VStack(alignment: .leading) { Text(event.toolName ?? event.eventType).font(.caption).foregroundStyle(.secondary); Text(String(event.content.prefix(1200))).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.padding(.vertical, 4)
                            }
                        }
                    }
                    if !queued.isEmpty {
                        DisclosureGroup("\(queued.count) queued") {
                            ForEach(queued.indices, id: \.self) { index in
                                HStack { Text(queued[index]["content"].text); Spacer(); Button("Remove") { Task { await removeQueued(queued[index]["id"].text) } } }
                            }
                        }
                    }
                    if !working && ["failed", "blocked", "interrupted", "cancelled", "reconnect required", "submission uncertain", "incompatible", "waiting user"].contains(status), turns.last?["detail"].text.isEmpty != false {
                        Label(status == "waiting user" ? "Waiting for your reply" : status.capitalized, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.subheadline)
                    }
                    if working { TimelineView(.periodic(from: .now, by: 1)) { context in HStack { ProgressView(); Text(progress(at: context.date)).foregroundStyle(.secondary).monospacedDigit() } }.accessibilityIdentifier("agent-working") }
                }
                if !error.isEmpty { OrbNotice(message: error) }
                Color.clear.frame(height: 1).id("conversation-bottom").accessibilityIdentifier("conversation-bottom")
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom)
        .onScrollPhaseChange { _, phase in
            userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            if userScrolling { followsLatest = atBottom }
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height + geometry.contentInsets.bottom - 32
        } action: { _, value in
            atBottom = value
            // WebKit layout is not a user scroll: keep following while math/images resize.
            if userScrolling { followsLatest = value }
        }
        .onScrollGeometryChange(for: CGSize.self) { geometry in
            CGSize(width: geometry.containerSize.height, height: geometry.contentSize.height)
        } action: { _, _ in
            if followsLatest {
                Task { @MainActor in
                    await Task.yield()
                    if followsLatest { scroll.scrollTo("conversation-bottom", anchor: .bottom) }
                }
            }
        }
        // A local conversation has no turn ids: restart its clock for each turn.
        .onChange(of: working) { _, now in if !now { OrbWorkClock.stop("local:\(id ?? "")") } }
        .onChange(of: history.last?.0) { _, _ in
            if !openedAtLatest || followsLatest {
                scroll.scrollTo("conversation-bottom", anchor: .bottom)
                openedAtLatest = true
            }
        }
        .background(OrbStyle.background)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(mission["title"].text.isEmpty ? (missionID == nil ? "New agent" : "Conversation") : mission["title"].text)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Menu {
                if id != nil && !unavailable {
                    Section { Text(selection.label); if !status.isEmpty { Text(status.capitalized) } }
                    Button("Rename") { title = mission["title"].text; rename = true }
                    Button("Move") { destinationProject = mission["project"].text; destinationFolder = OrbRow(mission).folder; moving = true }
                    Button("Archive") { Task { await mutate(["status": .string("acknowledged")]) } }.disabled(working)
                    if working && (!isCloud || selection.canCancel) { Button("Stop", role: .destructive) { Task { await cancel() } } }
                    if let url = safeURL(execution["external_url"].text) { Link("Open in service", destination: url) }
                }
                if !project.isEmpty { Button("Project context") { showContext = true } }
            } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Conversation actions") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { if !unavailable { composer.padding(.top, 6).background(OrbStyle.background.ignoresSafeArea(edges: .bottom)) } }
        .sheet(item: $preview) { OrbPreviewSheet(file: $0) }
        .sheet(isPresented: $showSelection) { OrbAgentPicker(selection: $selection, existing: id != nil) }
        .sheet(isPresented: $showContext) { NavigationStack { OrbDocuments(project: project, path: "").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showContext = false } } } } }
        .alert("Rename conversation", isPresented: $rename) { TextField("Title", text: $title); Button("Save") { Task { await mutate(["title": .string(title)]) } }; Button("Cancel", role: .cancel) {} }
        .sheet(isPresented: $moving) {
            NavigationStack {
                Form {
                    if !error.isEmpty { OrbNotice(message: error) }
                    TextField("Project slug", text: $destinationProject).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Folder", text: $destinationFolder).textInputAutocapitalization(.never).autocorrectionDisabled()
                }.navigationTitle("Move conversation").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("Cancel") { moving = false } }
                        ToolbarItem(placement: .topBarTrailing) { Button("Move") { Task { await move() } }.disabled(destinationProject.trimmingCharacters(in: .whitespaces).isEmpty) }
                    }
            }
        }
        .task {
            id = missionID
            text = OrbDisk.read(draftKey, as: String.self) ?? ""
            attachments = OrbDisk.read(draftKey + ":files", as: [OrbAttachment].self) ?? []
            if OrbDisk.read(pendingKey, as: OrbPending.self) != nil { error = "An earlier send needs verification. Retry sends the same request without creating a new identity." }
            if let id { mission = OrbReadCache.read("mission:\(id)") ?? .null; execution = OrbReadCache.read("cloud:\(id)") ?? .null; if execution != .null { selection.restore(execution["selection"]) } }
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
                if phase == .active { await refresh(force: working) }
            }
        }
        .onChange(of: text) { _, value in do { try OrbDisk.save(value, key: draftKey) } catch { self.error = "Could not save draft: \(error.localizedDescription)" } }
        .onChange(of: attachments) { _, value in do { try OrbDisk.save(value, key: draftKey + ":files") } catch { self.error = "Could not save attachments: \(error.localizedDescription)" } }
        .onDisappear { stream?.cancel(); stream = nil }
        .onChange(of: phase) { _, value in
            if value == .active { Task { await refresh(force: true) } }
            else { stream?.cancel(); stream = nil }
        }
    }
    }
    private var modeQuery: String? {
        guard !isCloud, selection.backend == "codex",
              let token = text.split(whereSeparator: { $0.isWhitespace }).last,
              token.hasPrefix("@") else { return nil }
        let query = String(token.dropFirst()).lowercased()
        return ["message", "plan", "goal"].contains(where: { $0.hasPrefix(query) }) ? query : nil
    }
    private func chooseMode(_ value: String) {
        if let range = text.range(of: "@", options: .backwards) { text.removeSubrange(range.lowerBound...) }
        mode = value
        composerFocused = true
    }
    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose a mode").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
            ForEach(["Message", "Plan", "Goal"].filter { modeQuery?.isEmpty != false || $0.lowercased().hasPrefix(modeQuery ?? "") }, id: \.self) { value in
                Button { chooseMode(value) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: value == "Goal" ? "target" : value == "Plan" ? "list.bullet.clipboard" : "bubble.left").frame(width: 24)
                        Text(value)
                        Spacer()
                        if mode == value { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                    }.padding(12).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("mode-option-" + value.lowercased())
            }
        }.padding(6).background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(OrbStyle.border)).padding(.bottom, 8)
            .accessibilityElement(children: .contain).accessibilityIdentifier("mode-picker")
    }
    private var composer: some View {
        VStack(spacing: 0) {
            if modeQuery != nil { modePicker }
            composerInput
        }.padding(.horizontal, 12).padding(.bottom, 6)
    }
    private var composerInput: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !attachments.isEmpty { OrbAttachments(files: $attachments, error: $error, canAdd: false) }
            if mode != "Message" && !isCloud && selection.backend == "codex" {
                Button { mode = "Message" } label: { Label(mode, systemImage: "xmark.circle.fill").font(.caption).padding(.horizontal, 8).padding(.vertical, 4).background(.white.opacity(0.08), in: Capsule()) }.accessibilityLabel("Clear " + mode + " mode")
            }
            TextField(id == nil ? "Plan, ask, build…" : "Follow up…", text: $text, axis: .vertical).lineLimit(1...6).font(.body).padding(.horizontal, 4).padding(.top, 6).focused($composerFocused).disabled(busy).accessibilityIdentifier("composer")
            HStack {
                if !project.isEmpty && !isCloud {
                    OrbAttachments(files: $attachments, error: $error, showMode: selection.backend == "codex" ? {
                        if modeQuery == nil { text += (text.isEmpty || text.last?.isWhitespace == true ? "" : " ") + "@" }
                        composerFocused = true
                    } : nil, showFiles: false)
                }
                Button { composerFocused = false; showSelection = true } label: { HStack(spacing: 6) { Image(systemName: selection.cloud ? "cloud" : "terminal"); Text(selection.model.isEmpty ? selection.label : selection.model); Image(systemName: "chevron.down").font(.caption2) }.font(.subheadline).foregroundStyle(.secondary).lineLimit(1).frame(minHeight: 44) }.accessibilityLabel("Agent and model: \(selection.label)").accessibilityIdentifier("agent-selection")
                Spacer()
                Button { Task { await send() } } label: { Image(systemName: "arrow.up").font(.headline).frame(width: 44, height: 44).background(.white.opacity(0.15), in: Circle()) }.disabled(busy || cloudBlocked || modeQuery != nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("Send message")
            }
        }.padding(.horizontal, 12).padding(.vertical, 8).background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: 24)).overlay(RoundedRectangle(cornerRadius: 24).stroke(OrbStyle.border)).accessibilityElement(children: .contain).accessibilityIdentifier("conversation-composer")
    }
    private func refresh(force: Bool = false) async {
        guard let id, !refreshing else { return }
        if !force && !working && Date().timeIntervalSince(lastRefresh) < 30 { return }
        refreshing = true; defer { refreshing = false; loading = false }
        do {
            let value = try await OrbReadCache.conversation(id, force: force)
            mission = value
            unavailable = !OrbRow(value).mobile
            guard !unavailable else { return }
            if OrbRow(value).cloud && execution == .null {
                do {
                    execution = try await OrbReadCache.cloud(id, force: force)
                    selection.restore(execution["selection"])
                } catch let e as OrbHTTPError where e.status == 404 { selection.backend = value["backend"].text; selection.model = value["model_override"].text }
            } else if OrbRow(value).cloud { execution = try await OrbReadCache.cloud(id, force: force) }
            if !OrbRow(value).cloud {
                if stream == nil && phase == .active {
                    stream = APIService.shared.streamControl(missionId: id, sinceSeq: events.last?.sequence, preferWebSocket: false) { type, data in
                        if type == "text_delta", let delta = data["delta"] as? String ?? data["content"] as? String { liveText += delta }
                        if ["assistant_message", "mission_status_changed"].contains(type) { Task { await refresh(force: true) } }
                    }
                }
                if !working { liveText = "" }
                selection.backend = value["backend"].text
                selection.node = value["remote_node_id"].text
                if selection.model.isEmpty { selection.model = value["model_override"].text }
                let batch = try await APIService.shared.getMissionEventsWithMeta(id: id, limit: 200, sinceSeq: events.last?.sequence)
                let unique = Dictionary((events + batch.events).map { ($0.sequence, $0) }, uniquingKeysWith: { old, _ in old })
                events = unique.values.sorted { $0.sequence < $1.sequence }
                queued = try await api.call("/api/control/queue").items.filter { $0["mission_id"].text == id }
            } else {
                let accounts = try await api.call("/api/cloud/accounts").items
                let account = accounts.first { $0["id"].text == execution["selection"]["account"].text && $0["provider"].text == execution["selection"]["provider"].text }
                selection.canCancel = account?["capabilities"]["cancel"].flag ?? false
            }
            if execution != .null { try OrbDisk.save(execution, key: "cloud:\(id)") }
            try OrbDisk.save(value, key: "mission:\(id)")
            lastRefresh = Date()
        } catch {
            if mission == .null { mission = OrbDisk.read("mission:\(id)", as: OrbJSON.self) ?? .null }
            self.error = "Connection unavailable. Last observed state is preserved. \(error.localizedDescription)"
        }
    }
    /// True once Core accepted the request, even if the refresh that follows fails.
    @discardableResult private func send() async -> Bool {
        guard !busy, !cloudBlocked else { return false }; busy = true; defer { busy = false }
        do {
            guard !isCloud || attachments.isEmpty else { throw OrbHTTPError(status: 400, detail: "This cloud service does not support attachments. Remove the files before sending.") }
            try OrbDisk.save(attachments, key: draftKey + ":files")
            let pending: OrbPending
            if let saved = OrbDisk.read(pendingKey, as: OrbPending.self) { pending = saved }
            else {
                var uploaded: [OrbJSON] = []
                var prompt = text
                if !isCloud && selection.backend == "codex" && mode != "Message" { prompt = "/" + mode.lowercased() + " " + prompt }
                for file in attachments {
                    let receipt = try await api.call("/api/uploads", method: "POST", body: .object(["node_id": .string(selection.node.isEmpty ? "core" : selection.node), "name": .string(file.name), "data_base64": .string(file.data.base64EncodedString())]))
                    guard !receipt["path"].text.isEmpty else { throw URLError(.cannotParseResponse) }
                    uploaded.append(.object(["kind": .string("file"), "path": receipt["path"]]))
                    prompt += "\n[Uploaded: " + receipt["path"].text + "]"
                }
                var body: [String: OrbJSON]
                if let id {
                    body = ["mission_id": .string(id), "content": .string(prompt), "client_message_id": .string(UUID().uuidString)]
                    if !uploaded.isEmpty { body["attachments"] = .array(uploaded) }
                    if !mission["track"].text.isEmpty && mission["remote_node_id"].text.isEmpty {
                        body["continue_identity"] = .object(["project": mission["project"], "track": mission["track"], "github_pr": mission["github_pr"]])
                    }
                    if isCloud { body["cloud_model"] = .string(selection.model); body["cloud_model_params"] = selection.params }
                    if !isCloud && !selection.model.isEmpty && selection.model != mission["model_override"].text {
                        guard !working else { throw OrbHTTPError(status: 409, detail: "Wait for this turn to finish before changing its model.") }
                        _ = try await api.call("/api/control/missions/\(OrbCore.escape(id))/settings", method: "PATCH", body: .object(["model_override": .string(selection.model)]))
                    }
                    pending = OrbPending(path: "/api/control/message", body: .object(body))
                } else {
                    try selection.validate()
                    body = ["title": .string(String(text.prefix(100))), "prompt": .string(prompt), "project": .string(project), "tags": .array(folder.isEmpty ? [] : [.string("orb-folder:\(folder)")]), "idempotency_key": .string(UUID().uuidString)]
                    if !uploaded.isEmpty { body["attachments"] = .array(uploaded) }
                    if selection.cloud { body["cloud"] = selection.wire }
                    else { body["backend"] = .string(selection.backend); body["model_override"] = .string(selection.model); if !selection.node.isEmpty { body["remote_node_id"] = .string(selection.node) } }
                    pending = OrbPending(path: "/api/control/missions", body: .object(body))
                }
                try OrbDisk.save(pending, key: pendingKey)
            }
            let result = try await api.call(pending.path, method: "POST", body: pending.body)
            if pending.path == "/api/control/message" {
                guard !result["id"].text.isEmpty, result["message_accepted"] != .bool(false), result["queued"] != .null else { throw OrbHTTPError(status: 409, detail: "Core has not confirmed acceptance. The saved request is retained.") }
            }
            if id == nil { guard !result["id"].text.isEmpty else { throw URLError(.cannotParseResponse) }; id = result["id"].text }
            OrbReadCache.invalidate("project:\(project)")
            OrbDisk.remove(pendingKey); attachments = []; OrbDisk.remove(draftKey + ":files"); text = ""; error = ""; followsLatest = true; openedAtLatest = false; await refresh(force: true)
            return true
        } catch {
            if let http = error as? OrbHTTPError, [400, 422].contains(http.status) { OrbDisk.remove(pendingKey) }
            self.error = "Message kept. \(error.localizedDescription)"
            return false
        }
    }
    private func move() async {
        guard let id, !destinationProject.isEmpty else { return }
        var tags = mission["tags"].items.filter { !$0.text.hasPrefix("orb-folder:") }
        if !destinationFolder.isEmpty { tags.append(.string("orb-folder:" + destinationFolder)) }
        do { _ = try await api.call("/api/control/missions/\(OrbCore.escape(id))/project", method: "POST", body: .object(["project": .string(destinationProject), "tags": .array(tags)])); moving = false; OrbReadCache.invalidate("project:\(project)"); OrbReadCache.invalidate("project:\(destinationProject)"); await refresh(force: true) }
        catch { self.error = error.localizedDescription }
    }
    private func mutate(_ fields: [String: OrbJSON]) async {
        guard let id else { return }
        do { _ = try await api.call("/api/control/missions/\(OrbCore.escape(id))/\(fields["title"] != nil ? "title" : "status")", method: "POST", body: .object(fields)); OrbReadCache.invalidate("project:\(project)"); await refresh(force: true) } catch { self.error = error.localizedDescription }
    }
    private func cancel() async {
        guard let id else { return }
        do { _ = try await api.call("/api/control/missions/\(OrbCore.escape(id))/\(isCloud ? "cloud/cancel" : "cancel")", method: "POST"); await refresh(force: true) } catch { self.error = error.localizedDescription }
    }
    private func removeQueued(_ message: String) async {
        do { _ = try await api.call("/api/control/queue/\(OrbCore.escape(message))", method: "DELETE"); await refresh(force: true) } catch { self.error = error.localizedDescription }
    }
    private func safeURL(_ value: String) -> URL? { guard let url = URL(string: value), url.scheme == "https", url.user == nil, url.password == nil else { return nil }; return url }
    private func download(_ path: String) async {
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

struct OrbSelection {
    var provider = "agent", account = "", backend = "", model = "", node = "", repository = "", gitRef = ""
    var params: OrbJSON = .array([])
    var canCancel = false
    var cloud: Bool { provider != "agent" }
    var label: String { [cloud ? ["chatgpt": "ChatGPT", "cursor_cloud": "Cursor Cloud", "grok_bot": "Grok Bot"][provider] ?? provider : backend.isEmpty ? "Choose agent" : OrbStyle.serviceName(backend), model].filter { !$0.isEmpty }.joined(separator: " · ") }
    var wire: OrbJSON {
        var value: [String: OrbJSON] = ["provider": .string(provider), "account": .string(account)]
        if !model.isEmpty { value["model"] = .string(model); value["model_params"] = params }
        if !repository.isEmpty { value["repository"] = .string(repository) }
        if !gitRef.isEmpty { value["git_ref"] = .string(gitRef) }
        return .object(value)
    }
    mutating func restore(_ value: OrbJSON) { provider = value["provider"].text; account = value["account"].text; model = value["model"].text; params = value["model_params"] == .null ? .array([]) : value["model_params"]; repository = value["repository"].text; gitRef = value["git_ref"].text }
    func validate() throws {
        if cloud && account.isEmpty || !cloud && backend.isEmpty { throw OrbHTTPError(status: 400, detail: "Choose an available agent and account.") }
        if provider == "cursor_cloud" && (repository.isEmpty || gitRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { throw OrbHTTPError(status: 400, detail: "Choose a repository and Git reference for Cursor Cloud.") }
    }
}

struct OrbAgentPicker: View {
    @Binding var selection: OrbSelection
    let existing: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [OrbJSON] = []
    @State private var models: [OrbJSON] = []
    @State private var backends: [OrbJSON] = []
    @State private var nodes: [OrbJSON] = []
    @State private var repos: [OrbJSON] = []
    @State private var error = ""
    private let api = OrbCore.shared
    var body: some View {
        NavigationStack {
            Form {
                if !error.isEmpty { OrbNotice(message: error) }
                if !existing {
                    Picker("Service", selection: $selection.provider) {
                        Text("Agent").tag("agent"); Text("ChatGPT").tag("chatgpt"); Text("Cursor Cloud").tag("cursor_cloud"); Text("Grok Bot").tag("grok_bot")
                    }.accessibilityIdentifier("picker.service")
                }
                if selection.cloud {
                    Picker("Account", selection: $selection.account) {
                        Text("Choose account").tag("")
                        ForEach(accounts.filter { $0["provider"].text == selection.provider }.indices, id: \.self) { index in
                            let account = accounts.filter { $0["provider"].text == selection.provider }[index]
                            Text(account["label"].text.isEmpty ? account["id"].text : account["label"].text).tag(account["id"].text).disabled(!account["available"].flag)
                        }
                    }.disabled(existing).accessibilityIdentifier("picker.account")
                    if selection.provider == "cursor_cloud" && !existing {
                        Picker("Repository", selection: $selection.repository) { Text("Choose repository").tag(""); ForEach(repos.indices, id: \.self) { Text(repos[$0]["url"].text).tag(repos[$0]["url"].text) } }.accessibilityIdentifier("picker.repository")
                        TextField("Git reference (required)", text: $selection.gitRef).accessibilityIdentifier("picker.git-ref").textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } else {
                    Picker("Harness", selection: $selection.backend) { Text("Choose harness").tag(""); ForEach(backends.indices, id: \.self) { Text(backends[$0]["name"].text.isEmpty ? backends[$0]["id"].text : backends[$0]["name"].text).tag(backends[$0]["id"].text) } }.disabled(existing).accessibilityIdentifier("picker.harness")
                    if !existing { Picker("Machine", selection: $selection.node) { Text("Core").tag(""); ForEach(nodes.indices, id: \.self) { Text(nodes[$0]["name"].text.isEmpty ? nodes[$0]["id"].text : nodes[$0]["name"].text).tag(nodes[$0]["id"].text) } } }
                }
                if selection.provider != "grok_bot" { Picker("Model", selection: $selection.model) {
                    Text("Service default").tag("")
                    ForEach(models.indices, id: \.self) { index in
                        let model = models[index]
                        Text(model["displayName"].text.isEmpty ? (model["label"].text.isEmpty ? model["id"].text : model["label"].text) : model["displayName"].text).tag(model["id"].text.isEmpty ? model["value"].text : model["id"].text)
                    }
                }.accessibilityIdentifier("picker.model") }
                if let model = models.first(where: { $0["id"].text == selection.model }), model["variants"].items.count > 1 {
                    let variants = model["variants"].items
                    Picker("Configuration", selection: Binding(get: { variants.firstIndex(where: { $0["params"] == selection.params }) ?? 0 }, set: { selection.params = variants[$0]["params"] })) {
                        ForEach(variants.indices, id: \.self) { index in
                            Text(variants[index]["displayName"].text.isEmpty ? variants[index]["params"].items.map { $0["value"].text }.joined(separator: " · ") : variants[index]["displayName"].text).tag(index)
                        }
                    }
                }
                if existing && selection.provider != "grok_bot" { Text("Model changes apply to the next message.").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("Agent settings").navigationBarTitleDisplayMode(.inline).scrollDismissesKeyboard(.interactively).toolbar { Button("Done") { dismiss() } }
            .task { await load() }
            .onChange(of: selection.provider) { _, _ in selection.account = ""; selection.model = ""; selection.params = .array([]); Task { await load() } }
            .onChange(of: selection.backend) { _, _ in Task { await loadModels() } }
            .onChange(of: selection.model) { _, _ in selection.params = models.first(where: { $0["id"].text == selection.model })?["variants"].items.first?["params"] ?? .array([]) }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    private func load() async {
        do {
            if selection.cloud { accounts = try await api.call("/api/cloud/accounts").items }
            else {
                let response = try await api.call("/api/backends")
                // ChatGPT browser sessions belong to Cloud agent, not a local harness.
                backends = (response.items.isEmpty ? response["backends"].items : response.items)
                    .filter { $0["id"].text != "chatgpt_ui" }
                if !existing && selection.backend == "chatgpt_ui" {
                    selection.backend = ""; selection.model = ""; selection.params = .array([])
                }
                let fleet = try await api.call("/api/remote-nodes"); nodes = fleet["nodes"].items
            }
            await loadModels(); error = ""
        } catch { self.error = error.localizedDescription }
    }
    private func loadModels() async {
        let provider = selection.provider, backend = selection.backend
        do {
            if selection.cloud {
                guard provider != "grok_bot" else { models = []; return }
                let value = try await api.call("/api/cloud/\(provider == "chatgpt" ? "chatgpt" : "cursor")/options")
                guard selection.provider == provider else { return }
                models = value["models"]["items"].items; repos = value["repositories"]["items"].items
            } else {
                let value = try await api.call("/api/providers/backend-models")
                guard selection.backend == backend && selection.provider == provider else { return }
                models = value["backends"][backend].items
            }
        } catch { self.error = error.localizedDescription }
    }
}

/// Cloud turns carry no timestamps; time each from when this device first saw it working.
@MainActor enum OrbWorkClock {
    private static var starts: [String: Date] = [:]
    static func start(_ key: String) -> Date { if let date = starts[key] { return date }; let now = Date(); starts[key] = now; return now }
    static func stop(_ key: String) { starts[key] = nil }
}
