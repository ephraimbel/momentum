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
    static func display(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .custom(BrandFont.spaceGrotesk(for: weight), size: size)
    }

    /// Clean UI text — buttons, card titles, labels, body. → Inter.
    static func rounded(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .custom(BrandFont.inter(for: weight), size: size)
    }

    /// Elegant serif that harmonizes with the serif **momentum** wordmark logo — used for brand
    /// taglines (e.g. "keep moving" under the wordmark). → system serif (New York); no bundled serif
    /// ships, and New York is the closest system match to the rounded-serif logo.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
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
