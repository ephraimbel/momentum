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

    // MARK: Spacing (base 4pt)
    enum Space {
        static let xs = 4.0, sm = 8.0, md = 16.0, lg = 24.0, xl = 32.0, xxl = 48.0
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
}
