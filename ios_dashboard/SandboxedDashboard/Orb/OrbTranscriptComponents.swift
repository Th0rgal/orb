import SwiftUI
import UIKit

@MainActor enum OrbWorkClock {
    private static var starts: [String: Date] = [:]
    static func start(_ key: String) -> Date { if let date = starts[key] { return date }; let now = Date(); starts[key] = now; return now }
    static func stop(_ key: String) { starts[key] = nil }
}

/// Double-tapping anywhere in the conversation closes the keyboard. Messages
/// render through UIKit text and web views that swallow SwiftUI gestures, so
/// this is a window-level recognizer that never cancels their touches and
/// ignores double-taps inside the focused field (word selection).
struct OrbDoubleTapDismissesKeyboard: UIViewRepresentable {
    let active: Bool
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = Anchor()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.dismiss = dismiss
        context.coordinator.recognizer.isEnabled = active
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.recognizer.view?.removeGestureRecognizer(coordinator.recognizer)
    }

    final class Anchor: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let coordinator else { return }
            coordinator.recognizer.view?.removeGestureRecognizer(coordinator.recognizer)
            window?.addGestureRecognizer(coordinator.recognizer)
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var dismiss: () -> Void = {}
        lazy var recognizer: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(fire))
            recognizer.numberOfTapsRequired = 2
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            return recognizer
        }()

        @objc private func fire() { dismiss() }

        /// Scoped to the transcript: double taps on text inputs, controls, the navigation
        /// bar or a presented sheet keep their own meaning (word selection, buttons).
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            var insideScroll = false
            while let current = view {
                if current.isFirstResponder || current is UITextField || current is UITextView || current is UIControl
                    || current is UINavigationBar || current is UIToolbar { return false }
                if current is UIScrollView { insideScroll = true }
                if let controller = current.next as? UIViewController, controller.presentingViewController != nil { return false }
                view = current.superview
            }
            return insideScroll
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// Sends survive leaving the screen; a reopened conversation must not mistake
/// one still awaiting Core for a failed send.
@MainActor enum OrbSendsInFlight {
    static var keys: Set<String> = []
}

// MARK: - Shared message and composer components (conversation tab and /btw sheet)

/// The user's message bubble: right-aligned card, copy from the context menu.
struct OrbUserBubble<Content: View>: View {
    let copyText: String
    var pending = false
    @ViewBuilder let content: Content
    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(OrbStyle.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(pending ? OrbStyle.borderStrong : OrbStyle.border, lineWidth: 1)
                )
                .contextMenu {
                    if !copyText.isEmpty {
                        Button {
                            UIPasteboard.general.string = copyText
                            OrbHaptics.light()
                        } label: {
                            Label("Copy message", systemImage: "doc.on.doc")
                        }
                    }
                }
        }
    }
}

extension OrbUserBubble where Content == OrbUserBubbleText {
    /// A plain-text question bubble.
    init(text: String, pending: Bool = false) {
        self.init(copyText: text, pending: pending) { OrbUserBubbleText(text: text, pending: pending) }
    }
}

struct OrbUserBubbleText: View {
    let text: String
    var pending = false
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .orbShimmer(active: pending)
    }
}

/// An assistant answer: the shared Markdown renderer, then the copy button and
/// any extra controls (e.g. the remote log toggle).
struct OrbAssistantMessage<Trailing: View>: View {
    let text: String
    var timing: OrbTurnTiming? = nil
    var onArtifact: (String) -> Void = { _ in }
    @ViewBuilder let trailing: Trailing
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            OrbRichText(source: text, onArtifact: onArtifact)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = text
                    OrbHaptics.light()
                    withAnimation(.snappy(duration: 0.15)) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        withAnimation(.snappy(duration: 0.15)) { copied = false }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                        if copied {
                            Text("Copied")
                                .font(.caption2)
                        }
                    }
                    .foregroundStyle(copied ? OrbStyle.success : OrbStyle.textMuted)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Copied response" : "Copy response")
                if let timing { OrbTurnTimeLabel(timing: timing) }
                trailing
                Spacer()
            }
        }
    }
}

extension OrbAssistantMessage where Trailing == EmptyView {
    init(text: String, timing: OrbTurnTiming? = nil, onArtifact: @escaping (String) -> Void = { _ in }) {
        self.init(text: text, timing: timing, onArtifact: onArtifact) { EmptyView() }
    }
}

/// "6d ago" next to the copy button; long press shows the date and how long the turn worked.
/// Only this label redraws each minute.
struct OrbTurnTimeLabel: View {
    let timing: OrbTurnTiming
    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(OrbTurnTiming.ago(timing.completedAt, now: context.date))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(OrbStyle.textMuted)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .contextMenu {
            Text(OrbTurnTiming.absolute(timing.completedAt))
            if let worked = timing.workedSeconds { Text("Worked for \(OrbTurnTiming.workedFor(worked))") }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Completed \(OrbTurnTiming.absolute(timing.completedAt))" + (timing.workedSeconds.map { ", worked for \(OrbTurnTiming.workedFor($0))" } ?? ""))
        .accessibilityIdentifier("turn-time")
    }
}

/// The message composer: field, leading accessories (attachments, agent picker),
/// dictation, stop and send. The dictation capsule replaces it while recording.
struct OrbComposerBox<Top: View, Leading: View>: View {
    let placeholder: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let dictation: OrbDictation
    let busy: Bool
    let canSend: Bool
    var showStop = false
    var fieldIdentifier = "composer"
    var sendIdentifier = "composer.send"
    var sendLabel = "Send message"
    var stopLabel = "Stop agent"
    var containerIdentifier = "conversation-composer"
    let onSend: () -> Void
    var onStop: () -> Void = {}
    @ViewBuilder let top: Top
    @ViewBuilder let leading: Leading

    var body: some View {
        if dictation.active {
            OrbDictationCapsule(dictation: dictation)
        } else {
            box
        }
    }

    private var box: some View {
        VStack(alignment: .leading, spacing: 4) {
            top
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .font(.subheadline)
                .padding(.horizontal, 4)
                .padding(.top, 6)
                .focused(focused)
                .accessibilityIdentifier(fieldIdentifier)
            HStack(spacing: 5) {
                leading
                Spacer(minLength: 2)
                OrbDictationButton(dictation: dictation, text: $text, onStart: { focused.wrappedValue = false }, onComplete: { focused.wrappedValue = true })
                    .disabled(busy)
                if showStop { stopButton }
                sendButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: OrbStyle.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OrbStyle.panelRadius, style: .continuous).stroke(OrbStyle.borderStrong, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(containerIdentifier)
    }

    private var sendButton: some View {
        Button {
            OrbHaptics.light()
            onSend()
        } label: {
            ZStack {
                Circle()
                    .fill(canSend ? Color.white : Color.white.opacity(busy ? 0.12 : 0.06))
                    .frame(width: 32, height: 32)
                if busy {
                    ProgressView().controlSize(.small).tint(.white.opacity(0.85))
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(canSend ? OrbStyle.background : Color.white.opacity(0.25))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityIdentifier(sendIdentifier)
        .accessibilityLabel(busy ? "Sending message" : sendLabel)
        .accessibilityValue(busy ? "Sending" : canSend ? "Ready" : "Unavailable")
    }

    private var stopButton: some View {
        Button {
            OrbHaptics.light()
            onStop()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 30, height: 30)
                    .overlay(Circle().stroke(OrbStyle.borderStrong, lineWidth: 1))
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(stopLabel)
        .accessibilityIdentifier("composer.stop")
    }
}

/// The conversation's "…" menu. Driven by plain values and `Equatable`, so the 1 s
/// Working clock and 3 s polling do not rebuild it while a finger is on it (a rebuilt
/// toolbar menu could swallow the first tap).
struct OrbConversationMenu: View, Equatable {
    enum Action { case rename, move, reopen, archive, stop, sideQuestion, fork, clone, context }

    let hasMission: Bool
    let agentLabel: String
    let status: String
    let canReopen: Bool
    let reopenTitle: String
    let canArchive: Bool
    let working: Bool
    let canStop: Bool
    let externalURL: URL?
    let local: Bool
    let hasProject: Bool
    let perform: (Action) -> Void

    nonisolated static func == (l: Self, r: Self) -> Bool {
        l.hasMission == r.hasMission && l.agentLabel == r.agentLabel && l.status == r.status &&
        l.canReopen == r.canReopen && l.reopenTitle == r.reopenTitle && l.canArchive == r.canArchive &&
        l.working == r.working && l.canStop == r.canStop && l.externalURL == r.externalURL &&
        l.local == r.local && l.hasProject == r.hasProject
    }

    var body: some View {
        Menu {
            if hasMission {
                Section {
                    Text(agentLabel)
                    if !status.isEmpty { Text(status) }
                }
                Button { perform(.rename) } label: { Label("Rename", systemImage: "pencil") }
                Button { perform(.move) } label: { Label("Move", systemImage: "folder") }
                if canReopen {
                    Button { perform(.reopen) } label: { Label(reopenTitle, systemImage: "arrow.uturn.backward") }.disabled(working)
                }
                if canArchive {
                    Button { perform(.archive) } label: { Label("Archive", systemImage: "archivebox") }.disabled(working)
                }
                if canStop {
                    Button(role: .destructive) { perform(.stop) } label: { Label("Stop", systemImage: "stop.circle") }
                }
                if let externalURL {
                    Link(destination: externalURL) { Label("Open in service", systemImage: "arrow.up.right.square") }
                }
                if local {
                    Divider()
                    Button { perform(.sideQuestion) } label: { Label("Side question (/btw)", systemImage: "bubble.left.and.text.bubble.right") }
                    Button { perform(.fork) } label: { Label("Fork conversation", systemImage: "arrow.triangle.branch") }
                    Button { perform(.clone) } label: { Label("Clone", systemImage: "plus.square.on.square") }
                }
            }
            if hasProject { Button { perform(.context) } label: { Label("Project context", systemImage: "doc.text") } }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Conversation actions")
        .accessibilityIdentifier("conversation.menu")
    }
}

/// A question tool call (ui_native_request / AskUserQuestion / question) that has no
/// result yet, decoded once per event change instead of on every render.
struct OrbPendingQuestion: Identifiable {
    let event: StoredEvent
    let request: OrbJSON
    var id: Int64 { event.id }

    static let toolNames: Set<String> = ["ui_native_request", "AskUserQuestion", "question"]

    static func extract(_ events: [StoredEvent]) -> [OrbPendingQuestion] {
        let resolved = Set(events.lazy.filter { $0.eventType == "tool_result" }.map { $0.toolCallId ?? "" })
        return events.compactMap { event in
            guard event.eventType == "tool_call", toolNames.contains(event.toolName ?? ""),
                  !resolved.contains(event.toolCallId ?? ""),
                  let request = try? JSONDecoder().decode(OrbJSON.self, from: Data(event.content.utf8)) else { return nil }
            return OrbPendingQuestion(event: event, request: request)
        }
    }
}

/// Row titles and one-line summaries: one line normally, up to three at accessibility
/// text sizes, where a single line would truncate almost everything.
struct OrbAdaptiveLineLimit: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize
    var regular = 1
    var accessibility = 3
    func body(content: Content) -> some View {
        content.lineLimit(typeSize.isAccessibilitySize ? accessibility : regular)
    }
}

extension View {
    func orbAdaptiveLineLimit(_ regular: Int = 1, accessibility: Int = 3) -> some View {
        modifier(OrbAdaptiveLineLimit(regular: regular, accessibility: accessibility))
    }
}
