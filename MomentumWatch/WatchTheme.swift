import SwiftUI

/// Minimal watch design tokens — true-black canvas, white ink, one iridescent accent for live
/// progress (mirrors the phone's "iridescence is earned" rule, PRD §5). Kept self-contained so the
/// watch target shares only platform-agnostic logic from the phone, never its iOS-specific views.
enum WatchTheme {
    static let bg = Color.black
    static let ink = Color.white
    static let inkSecondary = Color.white.opacity(0.6)
    static let surface = Color.white.opacity(0.10)

    /// The earned-progress accent. A soft oil-slick gradient; used on rings, live route, PRs.
    static let accent = Color(red: 0.62, green: 0.55, blue: 0.95)

    /// Iridescent gradient for progress surfaces (rings, goal fills) on watchOS.
    static var iridescent: LinearGradient {
        LinearGradient(colors: [
            Color(red: 0.55, green: 0.78, blue: 0.95),
            Color(red: 0.72, green: 0.60, blue: 0.95),
            Color(red: 0.95, green: 0.70, blue: 0.82)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
