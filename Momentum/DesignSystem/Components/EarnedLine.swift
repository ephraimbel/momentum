import SwiftUI

/// The single self-relative "you got better" line under a post-workout hero — the earned competence
/// beat the summary leads with (research: competence is the top retention driver). Mirrors Today's
/// learned-line treatment: ink text in a faint-iridescent capsule (iridescence only ever marks
/// progress). Static — Reduce-Motion safe.
struct EarnedLine: View {
    let text: String
    var systemImage: String = "rosette"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.ink)
            Text(text).font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, 9)
        .momentumGlass(iridescent: .line)
        .accessibilityElement(children: .combine)
    }
}

/// The "earned share" CTA — a quiet outline pill that surfaces in the post-workout reveal only when
/// there's a win worth sharing (a PR/achievement). Opens the monochrome share composer.
struct EarnedShareButton: View {
    let workout: Workout
    var weightUnit: WeightUnit = .default()
    var distanceUnit: DistanceUnit = .auto
    var title: String = "Share"
    @State private var showing = false

    var body: some View {
        Button { Haptics.light(); showing = true } label: {
            Label(title, systemImage: "square.and.arrow.up")
                .font(.rounded(Theme.FontSize.body, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, Theme.Space.lg).padding(.vertical, 12)
                .background(Capsule().stroke(Theme.ink, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) {
            ShareCardView(workout: workout, weightUnit: weightUnit, distanceUnit: distanceUnit)
        }
    }
}
