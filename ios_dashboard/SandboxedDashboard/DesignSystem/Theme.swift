//
//  Theme.swift
//  SandboxedDashboard
//
//  Native-first, quiet confidence theme tokens
//  "Quiet Luxury + Liquid Glass" - Dark-first, Vercel/shadcn inspired
//

import SwiftUI

enum Theme {
    
    // MARK: - Surfaces
    // Deep charcoal backgrounds - avoid pure black for quiet luxury feel
    
    /// Primary background: #121214 - deep charcoal, not pure black
    static let backgroundPrimary = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.071, green: 0.071, blue: 0.078, alpha: 1.0)
                : UIColor.systemBackground
        }
    )
    
    /// Secondary/elevated background: #1C1C1E - iOS system secondary background
    static let backgroundSecondary = Color(uiColor: .secondarySystemBackground)
    
    /// Tertiary background: #2C2C2E - for nested elements
    static let backgroundTertiary = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 1.0)
                : UIColor.tertiarySystemBackground
        }
    )
    
    /// Card surface: subtle elevation from background
    static let card = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
                : UIColor.secondarySystemBackground
        }
    )
    
    /// Elevated card: for nested or interactive elements
    static let cardElevated = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 1.0)
                : UIColor.tertiarySystemBackground
        }
    )
    
    /// Subtle divider/hairline
    static let hairline = Color(uiColor: .separator)
    
    /// Border color with low opacity
    static let border = Color.white.opacity(0.06)
    static let borderElevated = Color.white.opacity(0.08)
    static let borderSubtle = Color.white.opacity(0.04)

    // MARK: - Accent
    // Single accent color for primary actions - indigo per style guide
    static let accent = Color.indigo
    static let accentLight = Color(red: 0.388, green: 0.4, blue: 0.945)

    // MARK: - Semantic Colors
    static let success = Color(red: 0.133, green: 0.773, blue: 0.369)  // #22C55E
    static let warning = Color(red: 0.918, green: 0.702, blue: 0.031)  // #EAB308
    static let error = Color(red: 0.937, green: 0.267, blue: 0.267)    // #EF4444
    static let info = Color(red: 0.231, green: 0.510, blue: 0.965)     // #3B82F6

    // MARK: - Text
    // Use semantic colors for proper dark/light mode support
    static let textPrimary = Color(uiColor: .label)
    static let textSecondary = Color(uiColor: .secondaryLabel)
    static let textTertiary = Color(uiColor: .tertiaryLabel)
    /// Semantic quaternary tone instead of raw white-at-40%: participates in
    /// vibrancy on materials and tracks Increase Contrast, which a fixed
    /// opacity never does (HIG: prefer semantic label colors).
    static let textMuted = Color(uiColor: .quaternaryLabel)
    
    // MARK: - Typography Helpers
    
    static func metric(_ value: Double) -> Text {
        Text(value, format: .number.precision(.fractionLength(0)))
            .monospacedDigit()
    }
    
    static func metric(_ value: Int) -> Text {
        Text("\(value)")
            .monospacedDigit()
    }
}

// MARK: - Polish Layer
// Mirrors the web dashboard's --surface-sheen / --canvas-glow treatment:
// a faint top-edge light catch on raised surfaces and a soft vignette on
// the canvas. Subtle by design — visible as "quality", not as an effect.

extension Theme {
    /// Top-edge light catch for raised surfaces (cards, composer, pills).
    static let surfaceSheen = LinearGradient(
        stops: [
            .init(color: Color.white.opacity(0.07), location: 0),
            .init(color: Color.white.opacity(0.02), location: 0.18),
            .init(color: .clear, location: 0.45)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Hairline used on raised surfaces; brighter on the top edge.
    static let edgeHighlight = LinearGradient(
        colors: [Color.white.opacity(0.12), Color.white.opacity(0.04)],
        startPoint: .top,
        endPoint: .bottom
    )
}

private struct SurfaceSheen: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.surfaceSheen)
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.edgeHighlight, lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
    }
}

extension View {
    /// Apply the polish-layer sheen + edge highlight to a rounded surface.
    /// Call after the surface's own background/clip so the sheen sits on top.
    func surfaceSheen(cornerRadius: CGFloat = 14) -> some View {
        modifier(SurfaceSheen(cornerRadius: cornerRadius))
    }
}

// MARK: - View Extensions

extension View {
    /// Apply the primary background
    func themeBackground() -> some View {
        background(Theme.backgroundPrimary.ignoresSafeArea())
    }

    /// Card style with subtle elevation
    func themeCard() -> some View {
        self
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    
    /// Elevated card style
    func themeCardElevated() -> some View {
        self
            .background(Theme.cardElevated)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    
    /// Apply subtle border
    func themeBorder() -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}

// MARK: - Button Styles

struct GlassButtonStyle: ButtonStyle {
    var isProminent: Bool = false
    
    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if isProminent {
            configuration.label
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                )
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
        } else {
            configuration.label
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.15), lineWidth: 0.5)
                )
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
        }
    }
}

struct GlassProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(
                LinearGradient(
                    colors: [Theme.accent, Theme.accent.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Theme.accent.opacity(0.3), radius: 12, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static var glass: GlassButtonStyle { GlassButtonStyle() }
    static var glassProminent: GlassButtonStyle { GlassButtonStyle(isProminent: true) }
}

// MARK: - Haptics

/// The app's one haptics vocabulary (matches the ChatGPT/Claude conventions):
/// selection for pickers, pills and folds; light impact for sends and copies;
/// success/error for completed or failed actions.
@MainActor
enum OrbHaptics {
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}
