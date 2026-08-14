import SwiftUI

/// A progress ring that fills from a gray track (empty) to iridescent (complete) — PRD §5.2.
/// The filled arc is the only colored element; the track stays monochrome.
struct ProgressRing: View {
    var progress: Double                 // 0...1
    var lineWidth: CGFloat = 12
    /// Freeze the iridescent fill (no 30 fps mesh) — pass from any scrolling/occluded host, same
    /// contract as `MuscleMapView.forceStatic` (perf audit 2026-08-13).
    var isStatic: Bool = false

    // A two-tone version of this — ink for the portion already banked, iridescence for the part just
    // earned — was tried and removed. Iridescence is deliberately soft on white, so beside an ink arc
    // the earned segment was indistinguishable from the empty track: the one thing the ring existed
    // to celebrate read as a gap. One legible arc, with the caller animating it from where the week
    // stood to where it stands now, carries the same meaning as growth.
    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.hairline, lineWidth: lineWidth)
            IridescentView(intensity: 0.95, isStatic: isStatic)
                .mask {
                    Circle()
                        .trim(from: 0, to: max(0.0001, min(1, progress)))
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
