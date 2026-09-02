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
        Button(action: onTap) {
            content()
                .frame(width: width, height: width * 4 / 3)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.55), lineWidth: 1))
                .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
        }
        // A real ButtonStyle provides touch-down feedback without adding a competing gesture.
        // The old zero-distance DragGesture could win recognition and swallow the button action.
        .buttonStyle(PostMediaThumbPressStyle())
        .accessibilityLabel(label)
        .accessibilityHint("Switches with the cover")
    }
}

private struct PostMediaThumbPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.76),
                       value: configuration.isPressed)
    }
}
