import SwiftUI

/// The ring around an athlete's face — the app's one presence signal (owner call 2026-08-27).
///
/// Quiet ink by default; **animated iridescence the moment they've posted**, the same earned
/// treatment the podium card and the progress ring wear. Turning up is progress, so this is a
/// legitimate place for iridescence under the earned-accent rule — it marks a session that
/// happened, never decoration.
///
/// Meaning never rides on the ring alone: every call site carries it in the accessibility label
/// too ("… posted today"), because iridescence is invisible to VoiceOver and to anyone who
/// cannot separate the two states by color.
///
/// Reduce Motion holds the sweep at a fixed angle, so the iridescence stays and only the rotation
/// stops — never a strobe. Pass `isStatic` from a host that scrolls hard or renders many rings at
/// once — same contract as `ProgressRing.isStatic` and `MuscleMapView.forceStatic`.
struct PresenceRing<Content: View>: View {
    /// Posted inside the presence window (24h at every current call site).
    let active: Bool
    /// The active stroke. A story/presence ring is a state indicator, so it must still read at a
    /// glance when the avatar is small or the page is bright.
    var lineWidth: CGFloat = 4
    /// Canvas gap between the photo and the ring — what makes it read as a ring rather than a
    /// border painted onto the image.
    var gap: CGFloat = 3
    var isStatic: Bool = false
    /// Seconds per rotation. Slow on purpose: iridescence must never strobe (CLAUDE.md).
    var loop: Double = 6
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var frozen: Bool { isStatic || reduceMotion }

    var body: some View {
        content()
            .padding(gap)
            .background(Circle().fill(Theme.background))
            .overlay { ring }
    }

    @ViewBuilder private var ring: some View {
        if active {
            // A slowly ROTATING angular sweep of the iridescent palette, not the mesh.
            // `IridescentView` carries a 6pt blur that is right for a 12pt progress ring and
            // erases a 2.5pt one — masked to a face ring it washed out to a faint halo.
            // `IridescentMaterial` (the podium border) is the opposite problem: crisp but static.
            // An angular sweep is both, and it is the palette's established second form
            // (the pre-iOS-18 iridescence fallback), so it stays on-brand.
            ZStack {
                // Static bloom: only the angular stroke needs timeline updates. Keeping blur out of
                // the animated subtree avoids recomputing seven offscreen blur passes per frame in
                // the Following tray.
                Circle()
                    .strokeBorder(Theme.purple.opacity(0.28), lineWidth: lineWidth + 1)
                    .blur(radius: 2.5)

                // The sweep takes six seconds per turn, so 15fps is visually continuous while
                // halving the feed header's timeline/GPU work versus the former 30fps loop.
                TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: frozen)) { context in
                    let turn = frozen ? 0 : context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: loop) / loop
                    // Presence is painted outright, not used as a translucent wash, so it needs
                    // the palette's brand-depth stops. The former pastel stroke was actually
                    // quieter than the inactive ink ring on a white profile.
                    Circle()
                        .strokeBorder(
                            AngularGradient(colors: Theme.iridescentDeep + [Theme.iridescentDeep[0]],
                                            center: .center,
                                            angle: .degrees(turn * 360)),
                            lineWidth: lineWidth)
                        .shadow(color: Theme.purple.opacity(0.35), radius: 4)
                }
            }
            .allowsHitTesting(false)
        } else {
            // Inactive is deliberately quiet. Keeping it thinner than the posted state makes the
            // meaning legible even without color and gives the iridescent ring room to announce
            // genuinely new work.
            Circle().strokeBorder(Theme.ink.opacity(0.5), lineWidth: max(1.25, lineWidth * 0.42))
                .allowsHitTesting(false)
        }
    }
}
