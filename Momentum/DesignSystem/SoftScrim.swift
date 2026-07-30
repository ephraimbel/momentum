import SwiftUI

/// A scrim that actually FADES. A plain two-stop `background → clear` LinearGradient has a
/// visible terminal edge over contrasting media — the eye catches the derivative discontinuity
/// where the fade stops, and over a dark basemap the white haze "ends in a line" (owner report,
/// 2026-07-29). These stops approximate an ease-out falloff, so the final perceptible step is
/// below notice on any canvas. One scrim language for every full-bleed page (community pager,
/// saved-route detail, the profile's immersive pager).
enum SoftScrim {
    static func top(_ base: Color, peak: Double = 0.92) -> LinearGradient {
        LinearGradient(stops: [
            .init(color: base.opacity(peak), location: 0),
            .init(color: base.opacity(peak * 0.62), location: 0.30),
            .init(color: base.opacity(peak * 0.32), location: 0.55),
            .init(color: base.opacity(peak * 0.12), location: 0.78),
            .init(color: base.opacity(peak * 0.03), location: 0.92),
            .init(color: base.opacity(0), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    static func bottom(_ base: Color, peak: Double = 0.94) -> LinearGradient {
        LinearGradient(stops: [
            .init(color: base.opacity(0), location: 0),
            .init(color: base.opacity(peak * 0.03), location: 0.08),
            .init(color: base.opacity(peak * 0.12), location: 0.22),
            .init(color: base.opacity(peak * 0.32), location: 0.45),
            .init(color: base.opacity(peak * 0.62), location: 0.70),
            .init(color: base.opacity(peak), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}
