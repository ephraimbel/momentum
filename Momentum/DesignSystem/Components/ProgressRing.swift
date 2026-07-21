import SwiftUI

/// A progress ring that fills from a gray track (empty) to iridescent (complete) — PRD §5.2.
/// The filled arc is the only colored element; the track stays monochrome.
struct ProgressRing: View {
    var progress: Double                 // 0...1
    /// The portion already banked BEFORE whatever this ring is currently reporting, drawn in ink.
    ///
    /// Two things fall out of separating it. The ring keeps visual body instead of being a hairline
    /// circle with a speck on it — a first run of the week lights maybe 4% of the circumference, and
    /// a near-empty ring at the celebration is a flatter moment than the dishonest full sweep this
    /// replaced. And the iridescent arc then marks *only* what was just earned, which is exactly the
    /// accent rule: ink for what you'd already done, iridescence for what you just added.
    var baseline: Double = 0
    var lineWidth: CGFloat = 12

    var body: some View {
        let base = max(0, min(1, baseline))
        let end = max(base, min(1, progress))
        ZStack {
            Circle()
                .stroke(Theme.hairline, lineWidth: lineWidth)
            if base > 0.001 {
                Circle()
                    .trim(from: 0, to: base)
                    // Quiet on purpose. At full ink the banked week out-shouted the iridescent arc
                    // beside it — iridescence is soft on white, so the loudest thing on the ring
                    // became what the athlete had ALREADY done rather than what they just added.
                    .stroke(Theme.inkTertiary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            IridescentView(intensity: 0.95)
                .mask {
                    Circle()
                        .trim(from: base, to: max(base + 0.0001, end))
                        .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
        }
        // Fill timing is the caller's to choose (a slow build vs. a quick reveal), so the ring
        // animates only when the caller mutates `progress` inside its own `withAnimation`.
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        ProgressRing(progress: 0.7).frame(width: 160, height: 160).padding()
    }
}
