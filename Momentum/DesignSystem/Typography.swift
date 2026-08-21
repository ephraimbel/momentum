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
        .custom(BrandFont.spaceGrotesk(for: weight), size: size,
                relativeTo: BrandFont.textStyle(for: size))
    }

    /// Clean UI text — buttons, card titles, labels, body. → Inter.
    static func rounded(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .custom(BrandFont.inter(for: weight), size: size,
                relativeTo: BrandFont.textStyle(for: size))
    }

    /// Elegant serif that harmonizes with the serif **momentum** wordmark logo — used for brand
    /// taglines (e.g. "keep moving" under the wordmark). → system serif (New York); no bundled serif
    /// ships, and New York is the closest system match to the rounded-serif logo.
    ///
    /// **This one does not scale with Dynamic Type yet**, and unlike the two above it can't be fixed
    /// here: `.system(size:weight:design:)` has no `relativeTo:` companion, and the alternative —
    /// `.system(.title, design: .serif)` — snaps every call site to a text style's default size,
    /// which would visibly resize the paywall headline and the sheet titles. Closing it means either
    /// bundling a serif face (then it routes through `.custom` like the others) or moving its 17 call
    /// sites onto `@ScaledMetric`. Tracked as the remaining Dynamic Type gap.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

/// Maps a SwiftUI `Font.Weight` to the PostScript name of the matching bundled static instance.
/// Custom fonts don't synthesize weights, so we pick the nearest cut we actually ship.
enum BrandFont {

    /// The text style a given point size scales against.
    ///
    /// `Font.custom(_:size:)` — the form both helpers used until 2026-08-21 — produces a font that
    /// is **frozen** at that point size and ignores the athlete's text-size setting entirely. Since
    /// every label in the app routes through `display`/`rounded`, that meant no text anywhere
    /// responded to Dynamic Type, at any setting. `relativeTo:` is what makes a custom face scale,
    /// and it needs a text style to scale *against*.
    ///
    /// The buckets are the system styles' own default sizes (caption2 11 … largeTitle 34), so each
    /// size scales in the proportion Apple already tuned for text of that role, and a size at its
    /// bucket's default renders byte-identical to before at the standard setting. Sizes above
    /// largeTitle (hero numerals) ride `.largeTitle`, the slowest-growing style — exactly right for
    /// numbers that are already the biggest thing on screen.
    static func textStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<11.5: .caption2      // 11
        case ..<12.5: .caption       // 12
        case ..<14:   .footnote      // 13
        case ..<15.5: .subheadline   // 15
        case ..<16.5: .callout       // 16
        case ..<18.5: .body          // 17
        case ..<21:   .title3        // 20
        case ..<25:   .title2        // 22
        case ..<31:   .title         // 28
        default:      .largeTitle    // 34+
        }
    }

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
