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
    static let like = Color(hex: "FF375F")     // warm rose — the social "like" heart (the one warm accent a feed earns)

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

// MARK: - Health domain palette (Recovery Hub, docs/RECOVERY-HUB-PLAN.md §6)
// Doctrine: ink draws, pastel breathes, iridescence is earned. Each health domain owns exactly
// ONE pastel *wash* (backgrounds only: fills 10–14%, band ribbons 12%, ring tracks 20–25%) and
// one *ink* (every mark: lines, dots, bars, ring fills). Structure, text, axes, numerals stay
// monochrome — text never wears a data color. The two-step is load-bearing: raw pastels fail as
// chart marks (contrast vs white as low as 1.09:1, gray under CVD); the ink set passes lightness,
// chroma, CVD separation ≥ 16 ΔE, and ≥ 3:1 contrast on BOTH the light surface and dark #1E1D1B.
extension Theme {
    enum Health {
        // MARK: Domain pairs — same hex in light and dark (inks are validated for both surfaces;
        // washes warm via `darkWashOpacity` + glow, never by re-anodizing the base color).

        /// Sleep — periwinkle.
        static let sleepWash = Color(hex: "B8C0FF")
        static let sleepInk  = Color(hex: "5B6BD6")

        /// Recovery / readiness — mint.
        static let recoveryWash = Color(hex: "C8FFE0")
        static let recoveryInk  = Color(hex: "2E9E6B")

        /// Strain / load — peach.
        static let strainWash = Color(hex: "FFD8C2")
        static let strainInk  = Color(hex: "C96F3B")

        /// Vitals (HRV / resting HR / respiratory) — ice.
        static let vitalsWash = Color(hex: "C2F0FF")
        static let vitalsInk  = Color(hex: "1E90C0")

        /// Temperature / illness-watch — lilac + words, never red.
        static let temperatureWash = Color(hex: "E6C2FF")
        static let temperatureInk  = Color(hex: "9A5BD6")

        // MARK: Wash opacity — the standard fill level; call sites pick per §6's usage table
        // (fills 10–14%, ribbons 12%, tracks 20–25%) with these as the default fill.

        /// Standard wash fill opacity on the light surface.
        static let washOpacity = 0.12
        /// Standard wash fill opacity in dark mode (#1E1D1B / #2A2926): washes warm to 14–16%,
        /// paired with a soft same-tint glow — `shadow(color: wash.opacity(0.20), radius: 12)` —
        /// warm, never neon. Inks are unchanged between modes.
        static let darkWashOpacity = 0.16

        // MARK: Sleep-stage depth ramp — single-hue periwinkle, deepest stage darkest
        // (SleepCard stage bar; Awake renders as `Theme.hairline`, not a ramp step).
        static let sleepDeep = Color(hex: "5B6BD6")  // deep — the body shift
        static let sleepCore = Color(hex: "8F9BFF")  // core — knits the cycles
        static let sleepREM  = Color(hex: "B8C0FF")  // REM — the brain shift

        // Never: pastel text, pastel chart lines, ink backgrounds, or two domain tints on one
        // chart — BalanceCard's mint+peach is the sole sanctioned pairing (legend + shape-coded
        // end markers). Multi-hue only where a recognized convention demands it (MetricColor.zones).
    }
}
