import SwiftUI

/// Scroll metrics for a chat transcript, shared by the conversation and the /btw sheet.
struct OrbScrollMetrics: Equatable {
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    var contentHeight: CGFloat = 0
    var contentWidth: CGFloat = 0
    var visibleHeight: CGFloat = 0
    var containerWidth: CGFloat = 0
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    var visibleRect: CGRect = .zero

    /// Largest offset the transcript can scroll to. `containerSize` already excludes
    /// the content insets (navigation bar, composer, keyboard), so the bounds are
    /// `visibleHeight + topInset + bottomInset` tall.
    var maxOffsetY: CGFloat { max(-topInset, contentHeight - visibleHeight - topInset) }
    var distanceFromBottom: CGFloat { max(0, maxOffsetY - offsetY) }
    var scrollable: Bool { contentHeight > visibleHeight + 24 }
    /// 0 at the top, 1 at the bottom.
    var progress: CGFloat {
        let range = maxOffsetY + topInset
        guard range > 0 else { return 1 }
        return min(1, max(0, (offsetY + topInset) / range))
    }

    init() {}
    init(_ geometry: ScrollGeometry) {
        offsetX = geometry.contentOffset.x
        offsetY = geometry.contentOffset.y
        contentHeight = geometry.contentSize.height
        contentWidth = geometry.contentSize.width
        visibleHeight = geometry.containerSize.height
        containerWidth = geometry.containerSize.width
        topInset = geometry.contentInsets.top
        bottomInset = geometry.contentInsets.bottom
        visibleRect = geometry.visibleRect
    }
}

/// Scroll state of one transcript. `pinned` means "follow the latest message":
/// new content, a growing streaming answer, the keyboard or a rotation keep the
/// bottom in view. Dragging away unpins; reaching the bottom again re-pins.
@MainActor @Observable
final class OrbTranscriptScroller {
    var position = ScrollPosition(edge: .bottom)
    var pinned = true
    var metrics = OrbScrollMetrics()
    var interacting = false
    var maxHorizontalOffset: CGFloat = 0

    /// Distance from the bottom that still counts as "at the latest message".
    static let pinTolerance: CGFloat = 40
    /// The jump pill only appears once the latest message is clearly out of view.
    static let pillThreshold: CGFloat = 160

    var showsJumpToLatest: Bool { !pinned && metrics.scrollable && metrics.distanceFromBottom > Self.pillThreshold }

    func scrollToBottom(animated: Bool = false) {
        pinned = true
        if animated { withAnimation(.snappy(duration: 0.25)) { position.scrollTo(edge: .bottom) } }
        else { position.scrollTo(edge: .bottom) }
    }

    /// Fraction 0 (top) ... 1 (bottom) of the scrollable range.
    func scroll(toProgress progress: CGFloat) {
        let m = metrics
        let clamped = min(1, max(0, progress))
        // `ScrollPosition` y is measured from the top of the content (inset-adjusted).
        if clamped >= 0.999 { scrollToBottom(); return }
        pinned = false
        position.scrollTo(y: clamped * (m.maxOffsetY + m.topInset))
    }

    func update(_ value: OrbScrollMetrics) {
        let old = metrics
        metrics = value
        maxHorizontalOffset = max(maxHorizontalOffset, abs(value.offsetX))
        if interacting {
            if value.distanceFromBottom <= 2 { pinned = true }
            return
        }
        // Content grew (new message, streaming, late rich-text layout) or the viewport
        // shrank (keyboard): keep the latest message in view while pinned.
        if pinned && value.distanceFromBottom > 1 &&
            (value.contentHeight != old.contentHeight || value.visibleHeight != old.visibleHeight ||
             value.bottomInset != old.bottomInset || value.distanceFromBottom > old.distanceFromBottom + 0.5 || old.contentHeight == 0) {
            position.scrollTo(edge: .bottom)
        }
    }

    func phaseChanged(_ phase: ScrollPhase) {
        switch phase {
        case .tracking, .interacting:
            interacting = true
            pinned = false
        case .decelerating:
            interacting = true
        case .idle, .animating:
            interacting = false
            if metrics.distanceFromBottom <= Self.pinTolerance { pinned = true }
        @unknown default:
            interacting = false
        }
    }
}

/// The vertical chat transcript used by the conversation and the /btw sheet:
/// bottom anchored, never scrolls sideways, jump-to-latest pill and a
/// draggable fast-scroll thumb in place of the system indicator.
struct OrbTranscriptScrollView<Content: View>: View {
    let identifier: String
    @Bindable var scroller: OrbTranscriptScroller
    var working = false
    /// When set, a double tap on the transcript runs it (the conversation hides the keyboard).
    var onDoubleTap: (() -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            content
                .containerRelativeFrame(.horizontal)
        }
        .scrollPosition($scroller.position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(scroller.pinned ? .bottom : .top, for: .sizeChanges)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollIndicators(.hidden)
        .background(OrbHorizontalScrollLock())
        .background(OrbDoubleTapDismissesKeyboard(active: onDoubleTap != nil) { onDoubleTap?() })
        .onScrollGeometryChange(for: OrbScrollMetrics.self) { OrbScrollMetrics($0) } action: { _, value in
            scroller.update(value)
        }
        .onScrollPhaseChange { _, phase in scroller.phaseChanged(phase) }
        .overlay(alignment: .trailing) {
            OrbFastScrollThumb(identifier: identifier, scroller: scroller)
        }
        .overlay(alignment: .bottom) {
            if scroller.showsJumpToLatest {
                OrbJumpToLatestPill(identifier: identifier, working: working) { scroller.scrollToBottom(animated: true) }
                    .padding(.bottom, 10)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: scroller.showsJumpToLatest)
        #if DEBUG
        .overlay(alignment: .topLeading) {
            OrbScrollProbe(identifier: identifier + ".scrollProbe", metrics: scroller.metrics, maxHorizontal: scroller.maxHorizontalOffset)
        }
        #endif
    }
}

/// Centered "latest" pill, like the ChatGPT and Claude apps.
struct OrbJumpToLatestPill: View {
    let identifier: String
    var working = false
    let action: () -> Void

    var body: some View {
        Button {
            OrbHaptics.selection()
            action()
        } label: {
            HStack(spacing: 6) {
                if working { OrbRunningDots(size: 10) }
                Image(systemName: "arrow.down")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(.primary)
            .frame(minWidth: 40, minHeight: 40)
            .padding(.horizontal, working ? 10 : 0)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(OrbStyle.borderStrong))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(working ? "Scroll to latest message, agent is working" : "Scroll to latest message")
        .accessibilityIdentifier(identifier + ".jumpToLatest")
    }
}

/// A scroll indicator that becomes a grabbable thumb: thin while scrolling, wide
/// when touched, and dragging it scrubs through the whole transcript.
struct OrbFastScrollThumb: View {
    let identifier: String
    let scroller: OrbTranscriptScroller
    @State private var visible = false
    @State private var dragging = false
    @State private var grabOffset: CGFloat = 0
    @State private var hideTask: Task<Void, Never>?

    private static let minThumb: CGFloat = 44
    /// UI tests pass `-orb_slow_thumb_fade` because XCUITest's idle waits outlast the fade.
    private static let hideDelay: Duration = ProcessInfo.processInfo.arguments.contains("-orb_slow_thumb_fade") ? .seconds(10) : .seconds(2.5)

    var body: some View {
        GeometryReader { geo in
            let m = scroller.metrics
            let track = max(1, geo.size.height - 16)
            let ratio = m.contentHeight > 0 ? min(1, m.visibleHeight / m.contentHeight) : 1
            let thumb = max(Self.minThumb, track * ratio)
            let y = 8 + (track - thumb) * m.progress
            if m.scrollable && (visible || dragging) {
                Capsule()
                    .fill(Color.white.opacity(dragging ? 0.75 : 0.45))
                    .frame(width: dragging ? 8 : 4, height: thumb)
                    .frame(width: 28, height: thumb, alignment: .trailing)
                    .padding(.trailing, 3)
                    .contentShape(Rectangle())
                    .position(x: geo.size.width - 17, y: y + thumb / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("orb.thumbTrack"))
                            .onChanged { value in
                                if !dragging {
                                    dragging = true
                                    grabOffset = value.startLocation.y - (y + thumb / 2)
                                    scroller.pinned = false
                                    OrbHaptics.light()
                                }
                                let center = value.location.y - grabOffset
                                let progress = (center - 8 - thumb / 2) / max(1, track - thumb)
                                scroller.scroll(toProgress: progress)
                            }
                            .onEnded { _ in
                                dragging = false
                                if scroller.metrics.distanceFromBottom <= OrbTranscriptScroller.pinTolerance { scroller.pinned = true }
                                scheduleHide()
                            }
                    )
                    .transition(.opacity)
                    .accessibilityElement()
                    .accessibilityLabel("Scroll position")
                    .accessibilityValue("\(Int((m.progress * 100).rounded())) percent")
                    .accessibilityIdentifier(identifier + ".scrollThumb")
                    .accessibilityAdjustableAction { direction in
                        let step: CGFloat = direction == .increment ? 0.1 : -0.1
                        scroller.pinned = false
                        scroller.scroll(toProgress: m.progress + step)
                    }
            }
        }
        .coordinateSpace(.named("orb.thumbTrack"))
        .frame(width: 34)
        .animation(.easeOut(duration: 0.18), value: visible)
        .animation(.snappy(duration: 0.15), value: dragging)
        .onChange(of: scroller.metrics.offsetY) { _, _ in
            guard scroller.interacting || dragging else { return }
            visible = true
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: Self.hideDelay)
            guard !Task.isCancelled, !dragging else { return }
            visible = false
        }
    }
}

/// SwiftUI has no switch for it: stop the enclosing UIScrollView from ever moving
/// sideways (directional lock, no horizontal bounce).
struct OrbHorizontalScrollLock: UIViewRepresentable {
    /// The UIScrollView backing the SwiftUI ScrollView this view is a background of
    /// (an ancestor, or a sibling of one of its ancestors).
    static func transcriptScrollView(near view: UIView) -> UIScrollView? {
        var current = view.superview
        while let node = current {
            if let scroll = node as? UIScrollView, !(scroll is UITextView) { return scroll }
            if let scroll = node.subviews.lazy.compactMap({ $0 as? UIScrollView }).first(where: { !($0 is UITextView) }) { return scroll }
            current = node.superview
        }
        return nil
    }

    func makeUIView(context: Context) -> UIView { Probe() }
    func updateUIView(_ uiView: UIView, context: Context) { (uiView as? Probe)?.lock() }

    final class Probe: UIView {
        override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { fatalError() }
        override func didMoveToWindow() { super.didMoveToWindow(); lock() }
        func lock() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scroll = OrbHorizontalScrollLock.transcriptScrollView(near: self) else { return }
                scroll.alwaysBounceHorizontal = false
                scroll.isDirectionalLockEnabled = true
            }
        }
    }
}

#if DEBUG
/// DEBUG-only accessibility element so UI tests can read real scroll offsets.
/// Value: "x=<offsetX>;maxX=<largest |offsetX| seen>;fromBottom=<pt>;progress=<0...1>;contentW=<pt>;containerW=<pt>".
struct OrbScrollProbe: View {
    let identifier: String
    let metrics: OrbScrollMetrics
    let maxHorizontal: CGFloat

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityIdentifier(identifier)
            .accessibilityLabel("scroll probe")
            .accessibilityValue(String(format: "x=%.1f;maxX=%.1f;fromBottom=%.1f;progress=%.3f;contentW=%.1f;containerW=%.1f",
                                       metrics.offsetX, maxHorizontal, metrics.distanceFromBottom, metrics.progress,
                                       metrics.contentWidth, metrics.containerWidth)
                                + String(format: ";raw=off%.0f,contentH%.0f,containerH%.0f,inT%.0f,inB%.0f,vis%.0f-%.0f", metrics.offsetY, metrics.contentHeight, metrics.visibleHeight, metrics.topInset, metrics.bottomInset, metrics.visibleRect.minY, metrics.visibleRect.maxY))
    }
}
#endif
