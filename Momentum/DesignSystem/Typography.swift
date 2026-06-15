import SwiftUI

/// Typography (PRD §5.3). The brand now runs on two bundled open-source faces (both OFL,
/// registered via `UIAppFonts` — no SDK):
///
///  • **Space Grotesk** — the display face for hero numbers, screen titles, and the wordmark.
///    Derived from a monospace, it reads *smart, engineered, and strong* without the aggression
///    of a condensed athletic face. Its default figures are tabular — ideal for live metrics.
///  • **Inter** — the UI workhorse for every label, button, and body line. Neutral and
///    ultra-legible on screen, it disappears so the iridescent accent stays the hero.
///
/// Everything routes through the two helpers below, so the entire app retypes from this one file.
/// (Call-site names are kept for stability: `rounded` is historical — it now returns Inter, not
/// SF Rounded. Pair with `.monospacedDigit()` on any live/logged numeral, per §18.)
extension Font {
    /// Big, characterful display — wordmark, hero numbers, screen titles. → Space Grotesk.
    /// Scales with Dynamic Type (PRD §13.4), anchored to the nearest text style so proportions hold.
    /// At the default size it renders exactly at `size` (no change for default users); the app caps
    /// the overall scale at `.xxLarge` (see `MomentumApp`) so fixed layouts never break.
    static func display(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .custom(BrandFont.spaceGrotesk(for: weight), size: size, relativeTo: brandTextStyle(for: size))
    }

    /// Clean UI text — buttons, card titles, labels, body. → Inter. Scales with Dynamic Type.
    static func rounded(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .custom(BrandFont.inter(for: weight), size: size, relativeTo: brandTextStyle(for: size))
    }
}

/// The system text style whose base (Large) size is nearest `size` — the Dynamic Type anchor so a
/// custom face scales by the same ratio the OS would scale that style.
private func brandTextStyle(for size: CGFloat) -> Font.TextStyle {
    switch size {
    case 30...:      .largeTitle    // 34 — hero numbers + big titles
    case 24..<30:    .title         // 28
    case 21..<24:    .title2        // 22
    case 19..<21:    .title3        // 20
    case 16.5..<19:  .body          // 17
    case 15..<16.5:  .callout       // 16
    case 13.5..<15:  .subheadline   // 15
    case 12..<13.5:  .footnote      // 13
    case 11..<12:    .caption       // 12
    default:         .caption2      // 11
    }
}

/// Maps a SwiftUI `Font.Weight` to the PostScript name of the matching bundled static instance.
/// Custom fonts don't synthesize weights, so we pick the nearest cut we actually ship.
enum BrandFont {
    /// Space Grotesk ships Regular/Medium/Bold; Bold (700) is its heaviest, so heavier
    /// requests clamp to Bold. Its strength comes from form, not from a black weight.
    static func spaceGrotesk(for weight: Font.Weight) -> String {
        switch weight {
        case .black, .heavy, .bold, .semibold: "SpaceGrotesk-Bold"
        case .medium:                          "SpaceGrotesk-Medium"
        default:                               "SpaceGrotesk-Regular"
        }
    }

    /// Inter ships Regular/Medium/SemiBold/Bold; heavier requests clamp to Bold.
    static func inter(for weight: Font.Weight) -> String {
        switch weight {
        case .black, .heavy, .bold: "Inter-Bold"
        case .semibold:             "Inter-SemiBold"
        case .medium:               "Inter-Medium"
        default:                    "Inter-Regular"
        }
    }
}
