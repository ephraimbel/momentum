import SwiftUI

/// Minimal watch design tokens — true-black canvas, white ink, a soft iridescent accent for live
/// progress (mirrors the phone's "iridescence is earned" rule, PRD §5). Kept self-contained so the
/// watch target shares only platform-agnostic logic from the phone, never its iOS-specific views.
enum WatchTheme {
    static let bg = Color.black
    static let ink = Color.white
    static let inkSecondary = Color.white.opacity(0.55)
    static let inkTertiary = Color.white.opacity(0.4)
    static let surface = Color.white.opacity(0.10)
    static let surfaceStrong = Color.white.opacity(0.14)
    static let control = Color.white.opacity(0.16)   // round control-button backing

    /// The earned-progress accent (periwinkle — the phone's `route` colour). Used on the primary
    /// metric, rings, and live route.
    static let accent = Color(red: 0.72, green: 0.75, blue: 1.0)
    /// Heart-rate metric colour.
    static let heart = Color(red: 1.0, green: 0.42, blue: 0.52)
    /// Active-energy metric colour.
    static let energy = Color(red: 1.0, green: 0.72, blue: 0.42)

    /// The five HR-zone colours (Z1…Z5) — the Garmin/COROS convention (cool → hot) tuned to sit on
    /// true black. Functional colour, not brand iridescence: zones are information, not achievement.
    static let zones: [Color] = [
        Color(red: 0.62, green: 0.66, blue: 0.74),   // Z1 recovery — slate
        Color(red: 0.42, green: 0.66, blue: 1.0),    // Z2 easy — blue
        Color(red: 0.36, green: 0.85, blue: 0.58),   // Z3 aerobic — green
        Color(red: 1.0, green: 0.66, blue: 0.32),    // Z4 threshold — orange
        Color(red: 1.0, green: 0.36, blue: 0.42),    // Z5 max — red
    ]

    static func zone(_ index: Int) -> Color {
        zones[max(0, min(zones.count - 1, index - 1))]
    }

    /// Iridescent gradient for progress surfaces (rings, goal fills, rest timer) on watchOS.
    static var iridescent: LinearGradient {
        LinearGradient(colors: [
            Color(red: 0.72, green: 0.75, blue: 1.0),
            Color(red: 0.80, green: 0.70, blue: 1.0),
            Color(red: 0.78, green: 0.94, blue: 0.88)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Angular variant for rings — the sweep reads as motion around the dial.
    static var iridescentAngular: AngularGradient {
        AngularGradient(colors: [
            Color(red: 0.72, green: 0.75, blue: 1.0),
            Color(red: 0.80, green: 0.70, blue: 1.0),
            Color(red: 0.78, green: 0.94, blue: 0.88),
            Color(red: 0.72, green: 0.75, blue: 1.0)
        ], center: .center, startAngle: .degrees(-90), endAngle: .degrees(270))
    }
}
