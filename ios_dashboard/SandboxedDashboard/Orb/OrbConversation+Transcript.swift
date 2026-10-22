import SwiftUI
import UIKit
import AVFoundation

extension OrbConversation {
    var completedPlanTurnKey: String? {
        guard !working, !isCloud, pendingQuestionEvents.isEmpty else { return nil }
        guard let lastUserIdx = history.lastIndex(where: { $0.1 == "user" }) else { return nil }
        let userItem = history[lastUserIdx]
        let presentation = OrbMessagePresentation.parse(userItem.2)
        let images = OrbMessageImages.parse(presentation.text)
        guard OrbStyle.planObjective(images.text) != nil else { return nil }
        let hasAssistantReply = history[(lastUserIdx + 1)...].contains(where: { $0.1 == "assistant" && !$0.2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        guard hasAssistantReply else { return nil }
        let key = "plan-review:\(userItem.0)"
        guard !answered.contains(key) else { return nil }
        return key
    }

    @ViewBuilder
    func completedPlanReviewCard(key: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OrbStyle.textSecondary)
                Text("Review the plan")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            HStack(spacing: 8) {
                Button {
                    OrbHaptics.selection()
                    answered.insert(key)
                    mode = "Message"
                    Task { _ = await sendReply("Proceed with implementing the plan.") }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                        Text("Implement plan")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(OrbStyle.background)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityIdentifier("plan.implement")

                Button {
                    OrbHaptics.selection()
                    answered.insert(key)
                    mode = "Plan"
                    composerFocused = true
                } label: {
                    Text("Request changes")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.07), in: Capsule())
                        .overlay(Capsule().stroke(OrbStyle.borderStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityIdentifier("plan.requestChanges")

                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: OrbStyle.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OrbStyle.panelRadius, style: .continuous).stroke(OrbStyle.borderStrong, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plan-review-card")
    }

    @ViewBuilder
    func conversationContent(scroll: ScrollViewProxy) -> some View {
        if loading && missionID != nil && mission == .null {
            conversationLoadingSkeletons
        }
        if missionID == nil && id == nil && optimisticPrompt == nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("What would you like to work on?")
                    .font(.title3.weight(.semibold))
                Text(folder.isEmpty ? project : "\(project) / \(folder)")
                    .font(.footnote)
                    .foregroundStyle(OrbStyle.textSecondary)
            }
            .padding(.top, 16)
        }
        if history.count > visibleCount {
            Button("Load earlier messages") {
                let anchor = history.suffix(visibleCount).first?.0
                scroller.pinned = false
                visibleCount += 20
                Task { @MainActor in
                    await Task.yield()
                    if let anchor { scroll.scrollTo(anchor, anchor: .top) }
                }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(OrbStyle.textSecondary)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.03), in: Capsule())
            .overlay(Capsule().stroke(OrbStyle.border))
            .accessibilityIdentifier("load-earlier")
        }
        ForEach(Array(history.suffix(visibleCount)), id: \.0) { item in
            messageHistoryRow(item: item)
        }
        ForEach(turns.indices, id: \.self) { index in
            turnSummaryRow(turn: turns[index])
        }
        if !transcript.orchestration.isEmpty {
            OrbOrchestrationCards(refs: transcript.orchestration, project: project)
        }
        if !workModel.todos.isEmpty {
            OrbMissionTasksCard(todos: workModel.todos, ended: !working)
        }
        if working {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                OrbWorkFold(
                    model: workModel,
                    working: true,
                    headline: workModel.liveHeadline(fallback: baseStepLabel()),
                    elapsed: elapsedClock(at: context.date),
                    accessibilityStatus: progress(at: context.date)
                )
            }
        } else if !workModel.isEmpty {
            OrbWorkFold(
                model: workModel,
                working: false,
                headline: workModel.liveHeadline(fallback: baseStepLabel()),
                elapsed: "",
                accessibilityStatus: ""
            )
        }
        if !working && !isCloud {
            turnChangesCard
        }
        if working && !visibleLiveText.isEmpty {
            OrbMessageWithFiles(text: visibleLiveText, streaming: true, onArtifact: { path in
                Task { await openWorkspaceOrArtifact(path) }
            })
            .transition(.opacity)
        }
        ForEach(pendingQuestions) { question in
            OrbQuestion(event: question.event, request: question.request) { answered.insert(question.event.toolCallId ?? "") }
        }
        if let planKey = completedPlanTurnKey {
            completedPlanReviewCard(key: planKey)
        }
        if !working && ["failed", "blocked", "interrupted", "cancelled", "reconnect required", "submission uncertain", "incompatible", "waiting user"].contains(status), turns.last?["detail"].text.isEmpty != false {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                Text(status == "waiting user" ? "Waiting for your reply" : status.capitalized)
                    .font(.footnote.weight(.medium))
            }
            .foregroundStyle(OrbStyle.warning)
            .padding(.vertical, 2)
        }
    }

    /// Files edited in this conversation and its pull request, like the desktop's Changes.
    @ViewBuilder
    var turnChangesCard: some View {
        let pr = OrbTurnSummary.prLink(mission["github_pr"].text)
        if !changedFiles.isEmpty || pr != nil {
            OrbChangesCard(files: changedFiles, pr: pr)
        }
    }

    var conversationLoadingSkeletons: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer(minLength: 80)
                Text("User message prompt placeholder line")
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(OrbStyle.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Assistant response heading placeholder")
                    .font(.headline)
                Text("First line of assistant markdown response with technical details and context.")
                    .font(.subheadline)
                Text("Second line of assistant response placeholder.")
                    .font(.subheadline)
            }
            .padding(.vertical, 4)
        }
        .redacted(reason: .placeholder)
        .orbShimmer(active: true)
        .padding(.top, 12)
        .allowsHitTesting(false)
        .accessibilityLabel("Loading conversation")
    }

    var pendingQuestions: [OrbPendingQuestion] {
        openQuestions.filter { !answered.contains($0.event.toolCallId ?? "") }
    }
    var pendingQuestionEvents: [StoredEvent] { pendingQuestions.map(\.event) }

    @ViewBuilder
    func messageHistoryRow(item: (String, String, String)) -> some View {
        if item.1 == "user" {
            let presentation = OrbMessagePresentation.parse(item.2)
            if let wake = OrbBackgroundWake.parse(presentation.text) {
                backgroundWakeRow(itemID: item.0, wake: wake)
            } else {
                let images = OrbMessageImages.parse(presentation.text)
                let goalObj = OrbStyle.goalObjective(images.text)
                let planObj = goalObj == nil ? OrbStyle.planObjective(images.text) : nil
                let displayBody = goalObj ?? planObj ?? images.text
                let isPendingTurn = working && item.0 == lastUserItemID
                OrbUserBubble(copyText: displayBody, pending: isPendingTurn) {
                    if !images.paths.isEmpty { OrbImageStrip(images: images, missionID: id) }
                    if goalObj != nil || planObj != nil || presentation.attached {
                        HStack(spacing: 6) {
                            if goalObj != nil {
                                HStack(spacing: 4) {
                                    Image(systemName: "target")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text("Goal")
                                        .font(.caption2.weight(.semibold))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                .foregroundStyle(.primary.opacity(0.9))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.1), in: Capsule())
                            } else if planObj != nil {
                                HStack(spacing: 4) {
                                    Image(systemName: "list.bullet.clipboard")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text("Plan")
                                        .font(.caption2.weight(.semibold))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                .foregroundStyle(.primary.opacity(0.9))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.1), in: Capsule())
                            }
                            if presentation.attached {
                                HStack(spacing: 4) {
                                    Image(systemName: "paperclip")
                                        .font(.system(size: 10, weight: .medium))
                                    Text("Attached context")
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                .foregroundStyle(OrbStyle.textSecondary)
                            }
                        }
                    }
                    if !displayBody.isEmpty {
                        let isLongUserMsg = displayBody.count > 4000 && !expandedUserMessageIDs.contains(item.0)
                        let shownUserText = isLongUserMsg ? String(displayBody.prefix(4000)) + "…" : displayBody
                        Text(shownUserText)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .orbShimmer(active: isPendingTurn)
                        if isLongUserMsg {
                            Button {
                                withAnimation(.snappy(duration: 0.18)) {
                                    _ = expandedUserMessageIDs.insert(item.0)
                                }
                            } label: {
                                Text("Show full message")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(OrbStyle.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .id(item.0)
            }
        } else if let quiz = quiz(for: item) {
            VStack(alignment: .leading, spacing: 12) {
                if !quiz.before.isEmpty { OrbRichText(source: quiz.before) }
                OrbQuiz(quiz: quiz, disabled: busy || cloudBlocked || working) { reply in await sendReply(reply) }
                if !quiz.after.isEmpty { OrbRichText(source: quiz.after) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(item.0)
        } else {
            let parsedRemote = OrbRemoteLog.parse(item.2)
            VStack(alignment: .leading, spacing: 4) {
                OrbAssistantMessage(text: parsedRemote.text, timing: transcript.turnTimings[item.0], onArtifact: { path in
                    Task { await openWorkspaceOrArtifact(path) }
                }) {
                    if parsedRemote.details != nil {
                        Button {
                            withAnimation(.snappy(duration: 0.18)) {
                                if !expandedLogIDs.insert(item.0).inserted {
                                    expandedLogIDs.remove(item.0)
                                }
                            }
                            OrbHaptics.selection()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .semibold))
                                    .rotationEffect(.degrees(expandedLogIDs.contains(item.0) ? 90 : 0))
                                Text("Remote log")
                                    .font(.caption2)
                            }
                            .foregroundStyle(OrbStyle.textMuted)
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let details = parsedRemote.details, expandedLogIDs.contains(item.0) {
                    ScrollView {
                        Text(details.prefix(8000))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(OrbStyle.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    .padding(8)
                    .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(OrbStyle.border))
                }
            }
            .id(item.0)
        }
    }

    @ViewBuilder
    func backgroundWakeRow(itemID: String, wake: OrbBackgroundWake) -> some View {
        let isExpanded = expandedLogIDs.contains(itemID)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    if !expandedLogIDs.insert(itemID).inserted {
                        expandedLogIDs.remove(itemID)
                    }
                }
                OrbHaptics.selection()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: wake.killed ? "xmark.octagon" : "terminal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(wake.killed ? OrbStyle.warning : OrbStyle.textMuted)
                    Text(wake.killed ? "Background task stopped" : "Background task finished")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(OrbStyle.textSecondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(wake.command)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(OrbStyle.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(OrbStyle.textMuted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Task \(wake.task) · \(wake.command)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(OrbStyle.textMuted)
                    if !wake.output.isEmpty {
                        ScrollView {
                            Text(wake.output.prefix(4000))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(OrbStyle.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                    }
                    if !wake.note.isEmpty {
                        Text(wake.note)
                            .font(.caption2)
                            .foregroundStyle(OrbStyle.textMuted)
                    }
                }
                .padding(8)
                .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(OrbStyle.border))
            }
        }
        .id(itemID)
    }

    @ViewBuilder
    func turnSummaryRow(turn: OrbJSON) -> some View {
        if !turn["detail"].text.isEmpty && !Self.workingPhases.contains(turn["phase"].text) {
            Text(turn["detail"].text)
                .font(.footnote)
                .foregroundStyle(OrbStyle.textSecondary)
        }
        ForEach(turn["branches"].items.indices, id: \.self) { branchIndex in
            if let url = safeURL(turn["branches"].items[branchIndex]["prUrl"].text) {
                Link(destination: url) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.pull")
                            .font(.caption)
                        Text("View pull request")
                            .font(.footnote.weight(.medium))
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(OrbStyle.surface, in: Capsule())
                    .overlay(Capsule().stroke(OrbStyle.border))
                }
            }
        }
        ForEach(turn["artifacts"].items.indices, id: \.self) { artifactIndex in
            let artifact = turn["artifacts"].items[artifactIndex]
            Button {
                Task { await download(artifact["path"].text) }
            } label: {
                Label(artifact["path"].text.components(separatedBy: "/").last ?? "File", systemImage: "doc")
                    .font(.footnote)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(OrbStyle.surface, in: Capsule())
                    .overlay(Capsule().stroke(OrbStyle.border))
            }
            .buttonStyle(.plain)
        }
    }


}
