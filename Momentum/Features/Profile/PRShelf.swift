import SwiftUI

/// The trophy case — lifetime bests as earned-iridescent chips in a horizontal shelf (Strava's PR
/// shelf, leaner). Iridescence is earned here: each chip marks a genuine achievement. Strength e1RM
/// PRs lead, plus the longest run and longest session when present.
struct PRShelf: View {
    let strengthPRs: [(name: String, e1RMKg: Double)]
    var longestRunM: Double = 0
    var longestDurationS: Double = 0
    var weightUnit: WeightUnit = .default()
    var distanceUnit: DistanceUnit = .auto

    private struct Trophy: Identifiable {
        let icon: String
        let value: String
        let label: String
        var id: String { label }
    }

    private var trophies: [Trophy] {
        var out: [Trophy] = []
        if longestRunM > 0 {
            out.append(.init(icon: "figure.run",
                             value: Formatters.distance(meters: longestRunM, unit: distanceUnit),
                             label: "Longest run"))
        }
        if longestDurationS > 0 {
            out.append(.init(icon: "clock.fill",
                             value: Formatters.duration(s: longestDurationS),
                             label: "Longest session"))
        }
        for pr in strengthPRs {
            out.append(.init(icon: "dumbbell.fill",
                             value: Formatters.weight(kg: pr.e1RMKg, unit: weightUnit),
                             label: pr.name))
        }
        return out
    }

    var body: some View {
        if !trophies.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(trophies) { chip($0) }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func chip(_ trophy: Trophy) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: trophy.icon)
                .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
            Spacer(minLength: 0)
            Text(trophy.value)
                .font(.display(19, weight: .black)).monospacedDigit()
                .foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.7)
            Text(trophy.label.uppercased())
                .font(.rounded(Theme.FontSize.label, weight: .semibold)).tracking(0.5)
                .foregroundStyle(Theme.inkSecondary).lineLimit(1)
        }
        .frame(width: 138, height: 96, alignment: .leading)
        .padding(Theme.Space.md)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(IridescentMaterial()).opacity(Theme.IridescentOpacity.card.value)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(trophy.label): \(trophy.value)")
    }
}
