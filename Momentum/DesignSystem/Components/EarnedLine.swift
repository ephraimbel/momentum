import SwiftUI

/// The single self-relative "you got better" line under a post-workout hero — the earned competence
/// beat the summary leads with (research: competence is the top retention driver). Mirrors Today's
/// learned-line treatment: ink text in a faint-iridescent capsule (iridescence only ever marks
/// progress). Static — Reduce-Motion safe.
struct EarnedLine: View {
    let text: String
    var systemImage: String = "rosette"
    /// Whether this line actually marks progress. The accent rule is that iridescence is earned and
    /// nothing else wears it — so a line about turning up ("that's 3 this week") gets the same glass
    /// capsule with the accent withheld, rather than borrowing a personal best's clothes.
    var earned: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 13, weight: .bold))
                .foregroundStyle(earned ? Theme.ink : Theme.inkSecondary)
            // Wraps to two lines. The verdict this carries can be a full sentence — a first-ever run
            // reads "Your first one on the board. Everything after this has something to measure
            // against." — and `lineLimit(1)` truncated the one line that says what the run MEANT,
            // on every device and worse at large type. Two lines fits every current verdict; the
            // scale factor still catches an outlier at accessibility sizes.
            Text(text).font(.rounded(Theme.FontSize.body, weight: .semibold))
                .foregroundStyle(earned ? Theme.ink : Theme.inkSecondary)
                .lineLimit(2).minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, 9)
        .momentumGlass(iridescent: earned ? .line : nil)
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
