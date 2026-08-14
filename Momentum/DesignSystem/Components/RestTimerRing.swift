import SwiftUI

/// The auto rest-timer ring (PRD §4.4, §6.2): a depleting ring with a subtle iridescent edge,
/// counting down the exercise's rest. Pulses at zero. The countdown source-of-truth lives in the
/// view model; this view renders `progress` (1 → 0) and the remaining-time label.
struct RestTimerRing: View {
    var progress: Double             // 1 (full) → 0 (done)
    var remainingText: String
    var isComplete: Bool
    /// Freeze the iridescent edge (no 30 fps mesh) — for scrolling/occluded hosts, same contract
    /// as `MuscleMapView.forceStatic`.
    var isStatic: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Theme.hairline, lineWidth: 8)
            IridescentView(intensity: 0.9, isStatic: isStatic)
                .mask {
                    Circle()
                        .trim(from: 0, to: max(0.0001, min(1, progress)))
                        .stroke(style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            Text(remainingText)
                .font(.display(Theme.FontSize.headline, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
        }
        .scaleEffect(isComplete && !reduceMotion ? 1.06 : 1.0)
        .animation(Motion.lively, value: isComplete)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        RestTimerRing(progress: 0.4, remainingText: "0:48", isComplete: false)
            .frame(width: 120, height: 120)
    }
}
