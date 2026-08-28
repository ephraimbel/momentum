import SwiftUI

/// The ring around an athlete's face — the app's one presence signal (owner call 2026-08-27).
///
/// Quiet ink by default; **animated iridescence the moment they've posted**, the same earned
/// treatment the podium card and the progress ring wear. Turning up is progress, so this is a
/// legitimate place for iridescence under the earned-accent rule — it marks a session that
/// happened, never decoration.
///
/// Meaning never rides on the ring alone: every call site carries it in the accessibility label
/// too ("… trained today"), because iridescence is invisible to VoiceOver and to anyone who
/// cannot separate the two states by color.
///
/// Reduce Motion holds the sweep at a fixed angle, so the iridescence stays and only the rotation
/// stops — never a strobe. Pass `isStatic` from a host that scrolls hard or renders many rings at
/// once — same contract as `ProgressRing.isStatic` and `MuscleMapView.forceStatic`.
struct PresenceRing<Content: View>: View {
    /// Posted / trained inside the presence window (24h at every current call site).
    let active: Bool
    var lineWidth: CGFloat = 3
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
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: frozen)) { context in
                let turn = frozen ? 0 : context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: loop) / loop
                Circle()
                    .strokeBorder(
                        AngularGradient(colors: Theme.iridescent + [Theme.iridescent[0]],
                                        center: .center,
                                        angle: .degrees(turn * 360)),
                        lineWidth: lineWidth)
                    .shadow(color: Theme.iridescent[0].opacity(0.6), radius: 5)
            }
            .allowsHitTesting(false)
        } else {
            Circle().strokeBorder(Theme.ink, lineWidth: lineWidth)
                .allowsHitTesting(false)
        }
    }
}
