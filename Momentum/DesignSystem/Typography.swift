import SwiftUI

/// Typography (PRD §5.3). The brand face is a bold, rounded display look (à la the "Cadence"
/// wordmark) — approximated natively with SF Rounded at heavy/black weights. To use the exact
/// licensed face, bundle the `.ttf`, register it in Info.plist (UIAppFonts), and change the two
/// helpers below to `.custom(...)` — every call site updates for free.
extension Font {
    /// Big, characterful display — wordmark, hero numbers, screen titles.
    static func display(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Friendly rounded UI text — buttons, card titles, labels.
    static func rounded(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}
