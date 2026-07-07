import SwiftUI

/// Design tokens (PRD §18). Base UI is monochrome (asset-catalog backed, light/dark per §5.1);
/// the iridescent palette is the *earned* accent — used only by progress/achievement surfaces.
enum Theme {
    // MARK: Color (asset-catalog backed)
    static let ink = Color("ink")
    static let inkSecondary = Color("inkSecondary")
    static let inkTertiary = Color("inkTertiary")
    static let surface = Color("surface")
    static let background = Color("background")
    static let hairline = Color("hairline")
    static let route = Color("route")          // brightest live element
    static let success = Color(hex: "34C759")  // "done" affordance (logged set ✓) — the one green accent
    static let purple = Color(hex: "7C63F0")   // brand violet — the Pro/marketing accent (paywall, PRO badge)

    // MARK: Spacing (base 4pt)
    enum Space {
        static let xxs = 2.0, xs = 4.0, sm = 8.0, md = 16.0, lg = 24.0, xl = 32.0, xxl = 48.0
        static let chipV = 6.0   // capsule/chip vertical padding (PRBadge, gps pill, set row)
        static let pillV = 10.0  // selector/teaser/coach pill vertical padding
    }

    // MARK: Radius
    enum Radius {
        static let chip = 8.0, card = 14.0, sheet = 28.0
    }

    // MARK: Type sizes (pt; hero/live numerals must use .monospacedDigit())
    enum FontSize {
        static let heroNumber = 64.0, title = 30.0, headline = 22.0
        static let body = 17.0, caption = 13.0, label = 11.0
    }

    // MARK: Iridescent stops (low-sat holographic) — used at ~0.3–0.6 opacity, soft/blurred
    static let iridescent: [Color] = [
        Color(hex: "B8C0FF"), // periwinkle
        Color(hex: "C8FFE0"), // mint
        Color(hex: "FFD8C2"), // peach
        Color(hex: "E6C2FF"), // lilac
        Color(hex: "C2F0FF"), // ice
    ]

    // MARK: Iridescent opacity — the earned accent is soft; these name the levels that were
    // scattered as raw literals (0.16–0.55) across the app so every surface tints consistently.
    enum IridescentOpacity: Double {
        case faint = 0.16   // completed plan-session tint
        case soft  = 0.18   // ambient pill backings (learning teaser)
        case line  = 0.20   // earned-line capsule
        case chip  = 0.22   // live chips (streak alive, coach)
        case glyph = 0.25   // small glyph fills / chart area
        case badge = 0.30   // icon-circle backings (plan/confirm glyphs)
        case card  = 0.32   // earned cards (identity, learned beliefs)
        case hero  = 0.55   // hero status fills (ACWR band)
        var value: Double { rawValue }
    }
}

// MARK: - Elevation
// Light mode is the hero aesthetic (forced `.light`), so a single light-tuned shadow pair
// reads cleanly: a quiet lift for resting cards, a deeper one for floating chrome/sheets.
struct ShadowToken { let color: Color; let radius: CGFloat; let y: CGFloat }

extension Theme {
    enum Elevation {
        static let card  = ShadowToken(color: .black.opacity(0.05), radius: 8,  y: 2)
        static let float = ShadowToken(color: .black.opacity(0.10), radius: 18, y: 6)
    }
}

extension View {
    /// Apply a named elevation shadow (see `Theme.Elevation`).
    func elevation(_ token: ShadowToken) -> some View {
        shadow(color: token.color, radius: token.radius, y: token.y)
    }
}
