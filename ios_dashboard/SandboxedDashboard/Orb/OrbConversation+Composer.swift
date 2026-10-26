import SwiftUI
import UIKit
import AVFoundation

extension OrbConversation {
    var activeAtMentionQuery: String? {
        guard !isCloud, !effectiveProjectSlug.isEmpty else { return nil }
        guard let active = OrbContextTagging.activeAtQuery(text) else { return nil }
        if dismissedAtToken == active.query { return nil }
        return active.query
    }

    var effectiveContextFolder: String {
        if !contextBrowseFolder.isEmpty { return contextBrowseFolder }
        guard let q = activeAtMentionQuery else { return "" }
        return OrbContextTagging.folderPrefixFromQuery(items: contextItems, query: q) ?? ""
    }

    var filteredContextItems: [OrbContextItem] {
        guard let query = activeAtMentionQuery else { return [] }
        return OrbContextTagging.filterItems(contextItems, query: query, browseFolder: contextBrowseFolder)
    }

    var mentionedContextItems: [OrbContextItem] {
        OrbContextTagging.mentionedItems(in: text, items: contextItems)
    }

    var modeQuery: String? {
        guard supportsMode else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") && !trimmed.contains(" ") {
            let query = String(trimmed.dropFirst()).lowercased()
            if ["message", "plan", "goal"].contains(where: { $0.hasPrefix(query) }) { return query }
        }
        return nil
    }

    func chooseMode(_ value: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") && !trimmed.contains(" ") {
            text = ""
        } else if let range = text.range(of: "@", options: .backwards) {
            text.removeSubrange(range.lowerBound...)
        }
        withAnimation(.snappy(duration: 0.18)) {
            mode = value
        }
        OrbHaptics.selection()
        composerFocused = true
    }

    func pickContextItem(_ item: OrbContextItem) {
        contextBrowseFolder = ""
        dismissedAtToken = nil
        text = OrbContextTagging.insertMention(in: text, item: item)
        OrbHaptics.selection()
        composerFocused = true
    }

    func openContextFolder(_ folder: String) {
        let clean = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        contextBrowseFolder = clean
        text = OrbContextTagging.setFolderQuery(in: text, folder: clean)
        OrbHaptics.selection()
        composerFocused = true
    }

    func navigateBackContextFolder() {
        let current = effectiveContextFolder
        let parent = current.contains("/") ? String(current[..<current.lastIndex(of: "/")!]) : ""
        contextBrowseFolder = parent
        text = OrbContextTagging.setFolderQuery(in: text, folder: parent)
        OrbHaptics.selection()
    }

    var contextMentionPicker: some View {
        let items = filteredContextItems
        let currentFolder = effectiveContextFolder
        let folderRows = items.filter { $0.section == .folders }
        let fileRows = items.filter { $0.section == .files }

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if !currentFolder.isEmpty {
                    Button {
                        navigateBackContextFolder()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .semibold))
                            Text("\(currentFolder)/")
                                .font(.system(.caption, design: .monospaced, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        .foregroundStyle(.primary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        let folderItem = OrbContextItem(
                            id: "context:\(effectiveProjectSlug):\(currentFolder)",
                            kind: .context,
                            section: .folders,
                            path: currentFolder,
                            label: "\(currentFolder)/",
                            project: effectiveProjectSlug
                        )
                        pickContextItem(folderItem)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 11))
                            Text("Tag folder")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: "at")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OrbStyle.textSecondary)
                    Text("PROJECT CONTEXT")
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(OrbStyle.textMuted)
                    Spacer()
                    Button {
                        showContext = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 11))
                            Text("Manage")
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(OrbStyle.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            if items.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(OrbStyle.textMuted)
                    Text(contextItems.isEmpty ? "No project context files yet. Tap Manage to add files." : "No matching context files or folders.")
                        .font(.caption)
                        .foregroundStyle(OrbStyle.textMuted)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if !folderRows.isEmpty {
                            Text("FOLDERS")
                                .font(.system(.caption2, weight: .semibold))
                                .foregroundStyle(OrbStyle.textMuted)
                                .padding(.horizontal, 10)
                                .padding(.top, 4)
                                .padding(.bottom, 2)
                            ForEach(folderRows) { item in
                                HStack(spacing: 6) {
                                    Button {
                                        openContextFolder(item.path)
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "folder.fill")
                                                .font(.system(size: 13))
                                                .foregroundStyle(OrbStyle.textSecondary)
                                                .frame(width: 20)
                                            Text(item.label)
                                                .font(.system(.footnote, design: .monospaced))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(OrbStyle.textMuted)
                                        }
                                        .padding(.vertical, 7)
                                        .padding(.leading, 10)
                                        .padding(.trailing, 6)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        pickContextItem(item)
                                    } label: {
                                        Text("Tag")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(OrbStyle.textSecondary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.white.opacity(0.07), in: Capsule())
                                            .overlay(Capsule().stroke(OrbStyle.border))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.trailing, 8)
                                }
                                .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .accessibilityIdentifier("context-item-\(item.path)")
                            }
                        }
                        if !fileRows.isEmpty {
                            Text("FILES")
                                .font(.system(.caption2, weight: .semibold))
                                .foregroundStyle(OrbStyle.textMuted)
                                .padding(.horizontal, 10)
                                .padding(.top, folderRows.isEmpty ? 4 : 6)
                                .padding(.bottom, 2)
                            ForEach(fileRows) { item in
                                Button {
                                    pickContextItem(item)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "doc.text")
                                            .font(.system(size: 13))
                                            .foregroundStyle(OrbStyle.textSecondary)
                                            .frame(width: 20)
                                        Text(item.label)
                                            .font(.system(.footnote, design: .monospaced))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("context-item-\(item.path)")
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                }
                .frame(maxHeight: 210)
            }
        }
        .padding(4)
        .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: OrbStyle.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OrbStyle.panelRadius, style: .continuous).stroke(OrbStyle.borderStrong))
        .padding(.bottom, 6)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("context-mention-picker")
    }

    var modePicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("MODES")
                .font(.system(.caption2, weight: .semibold))
                .foregroundStyle(OrbStyle.textMuted)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(["Message", "Plan", "Goal"].filter { modeQuery?.isEmpty != false || $0.lowercased().hasPrefix(modeQuery ?? "") }, id: \.self) { value in
                let subtitle = value == "Goal" ? "Keep iterating until this objective is met" : (value == "Plan" ? "Plan before making changes" : "Standard conversation turn")
                Button { chooseMode(value) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: value == "Goal" ? "target" : value == "Plan" ? "list.bullet.clipboard" : "bubble.left")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(mode == value ? .primary : OrbStyle.textSecondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(value)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(OrbStyle.textMuted)
                        }
                        Spacer()
                        if mode == value {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(mode == value ? Color.white.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mode-option-" + value.lowercased())
            }
        }
        .padding(6)
        .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: OrbStyle.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OrbStyle.panelRadius, style: .continuous).stroke(OrbStyle.borderStrong))
        .padding(.bottom, 6)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mode-picker")
    }

    var queuedDrawer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { queueExpanded.toggle() }
                OrbHaptics.selection()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(OrbStyle.textMuted)
                        .rotationEffect(.degrees(queueExpanded ? 90 : 0))
                    Text("\(followUps.count) Queued")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(OrbStyle.textSecondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if queueExpanded {
                ForEach(followUps.rows) { row in
                    queuedRow(row)
                        .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom)))
                }
            }
            if editingQueuedID != nil {
                HStack {
                    Text("Editing queued message").font(.caption2).foregroundStyle(OrbStyle.textSecondary)
                    Spacer()
                    Button("Cancel") { editingQueuedID = nil; text = "" }
                        .font(.caption2.weight(.semibold))
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(OrbStyle.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(OrbStyle.border))
        .padding(.bottom, 6)
        .animation(reduceMotion ? nil : .snappy(duration: OrbSendFlow.leaveSeconds), value: followUps.rows)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("orb.followUpQueue")
    }

    /// One compact line: text, then edit / send now / remove. The action area is
    /// always reserved so a row does not change size from "sending" to "queued".
    func queuedRow(_ row: OrbQueuedRow) -> some View {
        let editing = editingQueuedID == row.id
        let enabled = !row.sending && editingQueuedID == nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Text(row.content.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.caption)
                    .foregroundStyle(editing ? OrbStyle.textMuted : .primary.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if editing {
                    Text("Editing").font(.caption2).foregroundStyle(OrbStyle.textMuted).padding(.horizontal, 6)
                } else {
                    queueAction("pencil", label: "Edit queued message", enabled: enabled) {
                        editingQueuedID = row.id
                        text = row.content
                        composerFocused = true
                    }
                    queueAction("arrow.up", label: "Send now", enabled: enabled) {
                        OrbHaptics.light()
                        Task { await sendQueuedNow(row.id) }
                    }
                    queueAction("trash", label: "Remove queued message", enabled: !row.sending) {
                        OrbHaptics.light()
                        Task { await removeQueued(row.id) }
                    }
                }
            }
            if let error = row.queueError {
                Text("Delivery paused · \(error)").font(.caption2).foregroundStyle(OrbStyle.warning).lineLimit(1)
            }
        }
        .padding(.vertical, 1)
        .opacity(row.sending ? 0.75 : 1)
    }

    func queueAction(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(enabled ? OrbStyle.textSecondary : OrbStyle.textMuted.opacity(0.4))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    var canSend: Bool {
        (!busy || canDeferSend) && !cloudBlocked && modeQuery == nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var composer: some View {
        VStack(spacing: 0) {
            if activeAtMentionQuery != nil {
                contextMentionPicker
            } else if modeQuery != nil {
                modePicker
            }
            if followUps.count > 0 || editingQueuedID != nil { queuedDrawer }
            composerInput
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    var composerInput: some View {
        OrbComposerBox(
            placeholder: id == nil ? (mode == "Goal" ? "Describe the goal objective…" : mode == "Plan" ? "What should we plan?" : "Plan, ask, build… (@ for context)") : (working ? "Queue a follow-up…" : "Follow up… (@ for context)"),
            text: $text,
            focused: $composerFocused,
            dictation: dictation,
            busy: busy,
            canSend: canSend,
            showStop: working && (!isCloud || selection.canCancel),
            onSend: { Task { await send() } },
            onStop: { Task { await cancel() } }
        ) {
            if !attachments.isEmpty { OrbAttachments(files: $attachments, error: $error, canAdd: false) }
            let mentioned = mentionedContextItems
            if (mode != "Message" && supportsMode) || !mentioned.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if mode != "Message" && supportsMode {
                            Button {
                                withAnimation(.snappy(duration: 0.18)) { mode = "Message" }
                                OrbHaptics.selection()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: mode == "Goal" ? "target" : "list.bullet.clipboard")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(mode)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(OrbStyle.textSecondary)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(.white.opacity(0.09), in: Capsule())
                                .overlay(Capsule().stroke(OrbStyle.borderStrong))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear " + mode + " mode")
                        }
                        ForEach(mentioned) { item in
                            HStack(spacing: 4) {
                                Image(systemName: item.section == .folders ? "folder.fill" : "doc.text")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(OrbStyle.textSecondary)
                                Text(item.label)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.primary.opacity(0.9))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(Color.white.opacity(0.07), in: Capsule())
                            .overlay(Capsule().stroke(OrbStyle.border))
                        }
                    }
                    .padding(.top, 2)
                }
            }
        } leading: {
            if !effectiveProjectSlug.isEmpty && supportsAttachments {
                OrbAttachments(
                    files: $attachments,
                    error: $error,
                    showContextMention: {
                        if activeAtMentionQuery == nil {
                            text += (text.isEmpty || text.last?.isWhitespace == true ? "" : " ") + "@"
                        }
                        composerFocused = true
                    },
                    showMode: supportsMode ? {
                        if modeQuery == nil {
                            text = "/"
                        }
                        composerFocused = true
                    } : nil,
                    showFiles: false
                )
            }
            Button {
                composerFocused = false
                showSelection = true
            } label: {
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: selection.primaryIcon)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(selection.needsAgentSelection ? .white : OrbStyle.textSecondary)
                        Text(selection.primaryPillLabel)
                            .font(.caption.weight(selection.needsAgentSelection ? .semibold : .medium))
                            .foregroundStyle(selection.needsAgentSelection ? .white : OrbStyle.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(OrbStyle.textMuted)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5.5)
                    .background(
                        selection.needsAgentSelection ? Color.white.opacity(0.09) : Color.white.opacity(0.05),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().stroke(
                            selection.needsAgentSelection ? OrbStyle.borderStrong : OrbStyle.border,
                            lineWidth: 1
                        )
                    )

                    if let nodeBadge = selection.machinePillLabel {
                        HStack(spacing: 3.5) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(OrbStyle.textMuted)
                            Text(nodeBadge)
                                .font(.system(.caption, weight: .medium))
                                .foregroundStyle(OrbStyle.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.04), in: Capsule())
                        .overlay(Capsule().stroke(OrbStyle.border, lineWidth: 1))
                    }
                }
                .frame(minHeight: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Agent and model: \(selection.label)")
            .accessibilityIdentifier("agent-selection")
        }
    }

}
