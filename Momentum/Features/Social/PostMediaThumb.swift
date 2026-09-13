import SwiftUI

/// The post's alternate media — route/body when photos lead, or the current photo when the workout
/// visual leads — as a small tappable card above the byline.
///
/// **Why this exists (owner call 2026-08-29, from a Strava post the owner pointed at).** A post
/// never opens a separate viewer. It is the second half of an in-place cover swap: tap the card and
/// it becomes the full post canvas while the former canvas moves into this exact rectangle.
///
/// Deliberately small and quiet: it is an accent on someone's photograph, not a second hero. The
/// hairline and the soft drop are what keep it legible over a bright sky or a dark night shot
/// without putting a scrim over the photograph itself.
struct PostMediaThumb<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    let onTap: () -> Void

    init(label: String = "Workout visual", @ViewBuilder content: @escaping () -> Content,
         onTap: @escaping () -> Void) {
        self.label = label
        self.content = content
        self.onTap = onTap
    }

    /// 3:4, matching the grid tile's aspect — the same object the athlete already recognises.
    /// 70, not 62: a route fills its frame, but a muscle map draws TWO figures and at 62 they were
    /// too small to read as a body at all.
    private let width: CGFloat = 70

    var body: some View {
        // The swap owner emits one selection haptic. Firing a second generic haptic here made a
        // single tap feel like a double registration on real hardware.
        //
        // `mapSafeTap`, not a `Button` (2026-09-12): when the route is the hero this card sits
        // over a LIVE Mapbox canvas, and a plain Button there intermittently loses its tap to the
        // map's UIKit recognizers (the same miss measured on the like control). The house
        // map-safe tap claims the touch first and carries its own press feedback — the earlier
        // "Button + zero-distance drag" combination that could swallow the action is not this.
        content()
            .frame(width: width, height: width * 4 / 3)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.55), lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
            .mapSafeTap(label, action: onTap)
            .accessibilityHint("Switches with the cover")
    }
}
