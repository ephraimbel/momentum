import SwiftUI

/// The session's own visual — route map, muscle map, sport glyph — as a small tappable card in the
/// bottom-left of a post, sitting directly above the byline.
///
/// **Why this exists (owner call 2026-08-29, from a Strava post the owner pointed at).** A post
/// used to force an either/or: the generated visual was page one and the athlete's photo paged
/// behind it, unless they flipped "Photo as cover", which then buried the route. One of the two
/// was always hidden behind a swipe nobody was told about. Now the photo is always the hero and
/// the visual is always here — both present, no toggle, nothing hidden.
///
/// Deliberately small and quiet: it is an accent on someone's photograph, not a second hero. The
/// hairline and the soft drop are what keep it legible over a bright sky or a dark night shot
/// without putting a scrim over the photograph itself.
struct PostMediaThumb<Content: View>: View {
    @ViewBuilder let content: () -> Content
    let onTap: () -> Void

    /// 3:4, matching the grid tile's aspect — the same object the athlete already recognises.
    /// 70, not 62: a route fills its frame, but a muscle map draws TWO figures and at 62 they were
    /// too small to read as a body at all.
    private let width: CGFloat = 70

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false

    var body: some View {
        Button(action: { Haptics.light(); onTap() }) {
            content()
                .frame(width: width, height: width * 4 / 3)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.55), lineWidth: 1))
                .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
                .scaleEffect(pressed ? 0.94 : 1)
                .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.7), value: pressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in pressed = true }
            .onEnded { _ in pressed = false })
        .accessibilityLabel("Route map")
        .accessibilityHint("Opens it full screen")
    }
}

/// The thumbnail's tap target, full screen — the visual on the app's own ground with one Done.
/// A sheet rather than a page in the swipe deck: it is a detour off the photos, not one of them.
struct PostMediaFullScreen<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content()
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Theme.surface))
                            .overlay(Circle().stroke(Theme.hairline))
                    }
                    .accessibilityLabel("Close")
                }
                Spacer()
            }
            .padding(Theme.Space.md)
        }
    }
}
