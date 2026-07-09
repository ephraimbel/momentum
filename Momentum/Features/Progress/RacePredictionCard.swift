import SwiftUI

/// "Projected races" — surfaces what the engine already knows (running-excellence R4). Shows Riegel
/// finish-time projections for 5K/10K/half/marathon from current fitness; the athlete's goal distance
/// earns the iridescent accent. Renders nothing when there's no running fitness to project from.
struct RacePredictionCard: View {
    let predictions: [RacePredictor.Prediction]
    var goalMeters: Double? = nil
    var distanceUnit: DistanceUnit = .auto

    private var goalDistance: RaceDistance? { goalMeters.map { RaceDistance.nearest(toMeters: $0) } }

    var body: some View {
        if !predictions.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                header
                VStack(spacing: 0) {
                    ForEach(Array(predictions.enumerated()), id: \.element.id) { i, p in
                        if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                        row(p)
                    }
                }
                Text("Flat-course estimate from your current fitness — terrain, weather, and fueling shift the day.")
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
            }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "flag.checkered").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.ink)
            Text("PROJECTED RACES").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
        }
    }

    private func row(_ p: RacePredictor.Prediction) -> some View {
        let isGoal = p.distance == goalDistance
        return HStack(spacing: Theme.Space.sm) {
            Text(p.distance.label).font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
            if isGoal {
                Text("GOAL").font(.rounded(9, weight: .bold)).tracking(0.8).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background { Capsule().fill(IridescentMaterial()).opacity(Theme.IridescentOpacity.badge.value) }
            }
            Spacer(minLength: Theme.Space.sm)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Formatters.duration(s: p.timeS))
                    .font(.display(20, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                Text(Formatters.pace(secPerKm: p.paceSPerKm, unit: distanceUnit))
                    .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(.vertical, Theme.Space.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(p.distance.label)\(isGoal ? ", your goal" : ""): projected \(Formatters.duration(s: p.timeS))")
    }
}
