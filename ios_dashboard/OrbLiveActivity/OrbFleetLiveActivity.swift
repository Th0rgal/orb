import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen first (iPhone 13 mini has no Dynamic Island): counters, a
/// stacked progress bar and the next mission waiting for the user. Every
/// surface opens the Inbox.
struct OrbFleetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OrbFleetActivityAttributes.self) { context in
            FleetLockScreen(state: context.state, stale: context.isStale)
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(OrbFleetActivityLink.inbox)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    FleetMark().padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    FleetCounters(state: state, compact: true)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        FleetBar(state: state)
                        if let next = NextItem(state: state) { next }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                FleetMark(size: 18)
            } compactTrailing: {
                if state.waiting > 0 {
                    Label("\(state.waiting)", systemImage: "hand.raised.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(FleetTone.waiting)
                } else {
                    Text("\(state.running)")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(FleetTone.running)
                }
            } minimal: {
                Image(systemName: state.waiting > 0 ? "hand.raised.fill" : (state.allDone ? "checkmark" : "circle.dotted"))
                    .foregroundStyle(state.waiting > 0 ? FleetTone.waiting : (state.allDone ? FleetTone.done : FleetTone.running))
            }
            .widgetURL(OrbFleetActivityLink.inbox)
            .keylineTint(FleetTone.running)
        }
    }
}

enum FleetTone {
    static let done = Color(red: 0.204, green: 0.780, blue: 0.349)     // systemGreen
    static let running = Color(red: 0.039, green: 0.518, blue: 1.0)    // systemBlue
    static let waiting = Color(red: 1.0, green: 0.584, blue: 0.0)      // systemOrange
    static let failed = Color(red: 1.0, green: 0.231, blue: 0.188)     // systemRed
}

private struct FleetLockScreen: View {
    let state: OrbFleetActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                FleetMark()
                Text(state.allDone ? "Tout est terminé" : "Flotte Orb")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                Spacer(minLength: 4)
                FleetCounters(state: state, compact: false)
            }
            FleetBar(state: state)
            if let next = NextItem(state: state) {
                next
            } else {
                HStack(spacing: 6) {
                    Image(systemName: state.allDone ? "checkmark.seal.fill" : "sparkles")
                        .foregroundStyle(state.allDone ? FleetTone.done : FleetTone.running)
                    Text(state.allDone ? "\(state.done) missions terminées · rien ne t’attend" : "Rien ne t’attend · les agents travaillent")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(state.updatedAt, style: .relative)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .font(.footnote)
                .lineLimit(1)
            }
        }
        .padding(16)
        .opacity(stale ? 0.55 : 1)
    }
}

private struct FleetMark: View {
    var size: CGFloat = 22
    var body: some View {
        Image("OrbMark")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

/// Done · running · waiting (· failed when any), SF Symbols with tinted digits.
private struct FleetCounters: View {
    let state: OrbFleetActivityAttributes.ContentState
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            counter(state.done, "checkmark.circle.fill", FleetTone.done)
            counter(state.running, "arrow.triangle.2.circlepath", FleetTone.running)
            counter(state.waiting, "hand.raised.fill", FleetTone.waiting)
            if state.failed > 0 {
                counter(state.failed, "exclamationmark.triangle.fill", FleetTone.failed)
            }
        }
    }

    private func counter(_ value: Int, _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .foregroundStyle(tint)
            Text("\(value)")
                .font(.system(compact ? .caption : .subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
        }
        .opacity(value == 0 ? 0.45 : 1)
    }
}

/// One capsule split by share of done / running / waiting / failed.
private struct FleetBar: View {
    let state: OrbFleetActivityAttributes.ContentState

    var body: some View {
        GeometryReader { geo in
            let total = max(state.total, 1)
            let parts: [(Int, Color)] = [
                (state.done, FleetTone.done),
                (state.running, FleetTone.running),
                (state.waiting, FleetTone.waiting),
                (state.failed, FleetTone.failed),
            ].filter { $0.0 > 0 }
            let gap: CGFloat = 2
            let usable = geo.size.width - gap * CGFloat(max(parts.count - 1, 0))
            HStack(spacing: gap) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Capsule(style: .continuous)
                        .fill(part.1.gradient)
                        .frame(width: max(usable * CGFloat(part.0) / CGFloat(total), 6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Capsule(style: .continuous).fill(.quaternary))
        }
        .frame(height: 6)
    }
}

/// The mission waiting longest for the user, as a tappable row.
private struct NextItem: View {
    let title: String
    let detail: String
    let since: Date?

    init?(state: OrbFleetActivityAttributes.ContentState) {
        guard let title = state.nextTitle, !title.isEmpty else { return nil }
        self.title = title
        self.detail = [state.nextProject, state.nextReason]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
        self.since = state.nextSince
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(FleetTone.waiting.opacity(0.18))
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FleetTone.waiting)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let since {
                Text(since, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: 56, alignment: .trailing)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

#Preview("Lock Screen", as: .content, using: OrbFleetActivityAttributes(account: "preview")) {
    OrbFleetLiveActivity()
} contentStates: {
    OrbFleetActivityAttributes.ContentState(done: 5, running: 3, waiting: 2, failed: 0, nextTitle: "Verity solidity_import", nextProject: "Verity", nextReason: "Approuver un appel d’outil", nextSince: .now.addingTimeInterval(-720), updatedAt: .now)
    OrbFleetActivityAttributes.ContentState(done: 9, running: 0, waiting: 0, failed: 0, updatedAt: .now)
}
