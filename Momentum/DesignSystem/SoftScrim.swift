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
        // Nine stops, not six (owner report 2026-08-20: pulling back from the screen, the old
        // ramp read as "a sharp line in the middle of the page"). The onset eases in with a
        // near-zero slope so no starting edge exists, the middle rises swiftly — the scrim is
        // SHORT now, and the text stack needs real coverage fast — and the landing flattens
        // into the peak so no terminal edge exists either.
        LinearGradient(stops: [
            .init(color: base.opacity(0), location: 0),
            .init(color: base.opacity(peak * 0.01), location: 0.05),
            .init(color: base.opacity(peak * 0.05), location: 0.11),
            .init(color: base.opacity(peak * 0.16), location: 0.19),
            .init(color: base.opacity(peak * 0.38), location: 0.29),
            .init(color: base.opacity(peak * 0.62), location: 0.41),
            .init(color: base.opacity(peak * 0.82), location: 0.56),
            .init(color: base.opacity(peak * 0.95), location: 0.76),
            .init(color: base.opacity(peak), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}
