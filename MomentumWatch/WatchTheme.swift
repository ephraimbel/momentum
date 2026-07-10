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
    static let control = Color.white.opacity(0.16)   // round control-button backing

    /// The earned-progress accent (periwinkle — the phone's `route` colour). Used on the primary
    /// metric, rings, and live route.
    static let accent = Color(red: 0.72, green: 0.75, blue: 1.0)
    /// Heart-rate metric colour.
    static let heart = Color(red: 1.0, green: 0.42, blue: 0.52)
    /// Active-energy metric colour.
    static let energy = Color(red: 1.0, green: 0.72, blue: 0.42)

    /// Iridescent gradient for progress surfaces (rings, goal fills, rest timer) on watchOS.
    static var iridescent: LinearGradient {
        LinearGradient(colors: [
            Color(red: 0.72, green: 0.75, blue: 1.0),
            Color(red: 0.80, green: 0.70, blue: 1.0),
            Color(red: 0.78, green: 0.94, blue: 0.88)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
