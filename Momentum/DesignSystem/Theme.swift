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
    /// Validation + failure states the athlete has to act on (a refused sign-in, a rejected form).
    /// Aliases the readiness ramp's warm sienna ON PURPOSE: the brand has no alarm red anywhere,
    /// and that hue is already tuned for legibility on both the light canvas and the warm charcoal.
    /// Named separately so form errors don't reach across into the health palette for a colour.
    static let warning = Color("readinessStrained")
    /// THE map trace — one color on every map, light or dark (owner call 2026-08-19): the brand
    /// purple, so the line you're drawing is unmistakably "happening now". Asset-backed but the
    /// same #7C63F0 in both appearances; snapshots, tiles, live maps and the puck all draw it.
    static let route = Color("route")
    /// The light Pro/marketing lavender the route color USED to be (#C9BCF9 / #D6CCFB) — PRO
    /// badges, locked chips, the rating pill, paywall glyphs. Kept separate so the Pro-gating
    /// look survives the trace going brand-purple; pairs with `inkOnFixedLight` text.
    static let proLavender = Color("proLavender")
    static let success = Color(hex: "34C759")  // "done" affordance (logged set ✓) — the one green accent
    /// The brand lavender (rebrand "Lavender Glass", 2026-08-16) — promoted from Pro-only to THE
    /// interactive accent: the global tint (links, toggles, pickers, selected tab icon), the
    /// segmented selection pill, and still the Pro/marketing surface. Scarcity is the discipline:
    /// if you can tap it or it's happening now, it may be lavender — decoration never is.
    /// Asset-backed: #7C63F0 light, brightening to #9D8BF5 on the dark charcoal (the board's
    /// continuity rule — labels on lavender fills stay white in both modes).
    static let purple = Color("purple")
    /// Lavender's quiet fill (asset-backed: #F1EDFE light / #332E4A dark) — selected fills and
    /// brand chips (plan phase chips). Small fields only, never large washes.
    static let purpleTint = Color("purpleTint")
    /// Lavender at text strength (asset-backed: #5A43C7 light / #B4A6F8 dark) — labels sitting
    /// on `purpleTint`, where the brand hex itself falls short of small-text contrast.
    static let purpleDeep = Color("purpleDeep")
    static let like = Color(hex: "FF375F")     // warm rose — the social "like" heart (the one warm accent a feed earns)
    /// Ink for text drawn over a canvas that is deliberately LIGHT in **both** appearances — today
    /// that means route snapshots, which render on a clean light canvas whatever the athlete's
    /// appearance setting (decision 2026-07-24). `Theme.ink` there would flip to near-white in dark
    /// mode and disappear. Same value as light-mode `ink`; not a general-purpose token — reach for
    /// it only on fixed-appearance surfaces.
    static let inkOnFixedLight = Color(hex: "16151A")

    /// The quiet inset fill under glyph discs, steppers and unit tracks — a hair off the canvas
    /// in light, a hair ABOVE it in dark (a fixed light grey there was a bright blob).
    static let tintedField = Color("tintedField")

    // MARK: Spacing (base 4pt)
    enum Space {
        static let xxs = 2.0, xs = 4.0, sm = 8.0, md = 16.0, lg = 24.0, xl = 32.0, xxl = 48.0
        static let chipV = 6.0   // capsule/chip vertical padding (PRBadge, gps pill, set row)
        static let pillV = 10.0  // selector/teaser/coach pill vertical padding
    }

    // MARK: Radius
    enum Radius {
        // The radius law (rebrand "Lavender Glass", 2026-08-16): pills are capsules, sheets 22,
        // cards 14, small chips 8 — nothing in between.
        static let chip = 8.0, card = 14.0, sheet = 22.0
    }

    // MARK: Type sizes (pt; hero/live numerals must use .monospacedDigit())
    enum FontSize {
        static let heroNumber = 64.0, title = 30.0, headline = 22.0
        static let body = 17.0, caption = 13.0, label = 11.0
    }

    // MARK: Iridescent stops — the lavender-led AURORA (rebrand "Lavender Glass", 2026-08-16;
    // retuned from the old holographic set: mint/peach out, the family now orbits the brand
    // lavender). Same law as ever: earned-only, used at ~0.3–0.6 opacity, soft/blurred.
    static let iridescent: [Color] = [
        Color(hex: "C9BCF9"), // lavender — the lead
        Color(hex: "B8D4F7"), // sky
        Color(hex: "F3CDE4"), // rose
        Color(hex: "CBBDF8"), // violet — the live-route accent ([3])
        Color(hex: "EBD9F4"), // orchid ice
    ]

    // MARK: Iridescent opacity — the earned accent is soft; these name the levels that were
    // scattered as raw literals (0.16–0.55) across the app so every surface tints consistently.
    enum IridescentOpacity: Double {
        // Once a full scale (0.16–0.55); every level but the earned-line capsule fell out of use
        // as surfaces migrated to their own tokens (dead-code sweep 2026-08-20). Grows back one
        // named case at a time when a surface actually tints.
        case line = 0.20    // earned-line capsule
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

        // MARK: Readiness band ramp (hero ring, week dots, Trends strip) — softened to the
        // Oura-grade semantic trio in the rebrand ("Lavender Glass", 2026-08-16; supersedes the
        // 2026-07-16 electric "almost glowing" set — rings still glow via the same-color shadow,
        // the hue itself now speaks calmly). Ring/dot MARKS only — numerals and band words stay
        // monochrome ink — and red never appears (no-shame): the low bands stay warm, never alarm.
        // Asset-backed: each band lifts in dark mode per the board (5CBA85 / E0A63C / DB9363 /
        // E07A6C) so marks stay legible on the charcoal without turning neon.
        static let readinessReady    = Color("readinessReady")     // ready — settled sage
        static let readinessModerate = Color("readinessModerate")  // watch — quiet amber
        static let readinessStrained = Color("readinessStrained")  // ease — warm sienna
        static let readinessDepleted = Color("readinessDepleted")  // hold — soft coral, never alarm red

        /// The bright mark color for a readiness band. Primed maps to the electric green too —
        /// its ring fill stays the earned iridescent mesh (§6); this colors its glow and dots.
        static func readinessColor(_ band: RecoveryModel.Readiness) -> Color {
            switch band {
            case .primed, .ready: readinessReady
            case .moderate:       readinessModerate
            case .strained:       readinessStrained
            case .depleted:       readinessDepleted
            }
        }

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
