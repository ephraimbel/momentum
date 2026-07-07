import SwiftUI

/// R4 surfacing on the Plan page: a race-day projection + a pace-insight line. The race projection is a
/// goal/achievement signal, so it earns a soft iridescent edge; the pace insight is calm monochrome.

/// Projected finish for the athlete's goal race, from current fitness — with a countdown and the honest
/// "flat course, good day" caveat.
struct RacePredictionCard: View {
    let raceDistanceM: Double
    let raceDate: Date?
    let p5kSPerKm: Double
    var distanceUnit: DistanceUnit = .auto
    var now: Date = Date()

    var body: some View {
        if let finish = RacePredictor.finishTimeS(raceDistanceM: raceDistanceM, p5kSPerKm: p5kSPerKm) {
            let pace = RacePredictor.projectedPaceSPerKm(raceDistanceM: raceDistanceM, p5kSPerKm: p5kSPerKm)
            let days = RacePredictor.daysUntil(raceDate: raceDate, from: now)
            let label = RacePredictor.label(forRaceM: raceDistanceM)
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack {
                    Text("RACE PROJECTION").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                        .foregroundStyle(Theme.inkTertiary)
                    Spacer()
                    Text(label).font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                    Text(Formatters.duration(s: finish)).font(.display(34, weight: .black)).monospacedDigit()
                        .foregroundStyle(Theme.ink)
                    if let pace {
                        Text("~\(Formatters.pace(secPerKm: pace, unit: distanceUnit))")
                            .font(.rounded(Theme.FontSize.body, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    Spacer()
                }
                HStack(spacing: Theme.Space.sm) {
                    if let days {
                        Label(days == 0 ? "Race day" : "\(days) day\(days == 1 ? "" : "s") to go",
                              systemImage: "flag.checkered")
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                    }
                    Spacer()
                    Text("flat course, good day").font(.rounded(Theme.FontSize.label, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            .padding(Theme.Space.md).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(IridescentMaterial().opacity(0.5), lineWidth: 1))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Projected \(label) finish \(Formatters.duration(s: finish))"
                                + (days.map { ", \($0) days to go" } ?? ""))
        }
    }
}

/// A single calm line reading the athlete's recent quality-session pacing (Pace Insights).
struct PaceInsightCard: View {
    let result: PaceInsights.Result

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: icon).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.headline).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                Text(result.detail).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(result.headline). \(result.detail)")
    }

    private var icon: String {
        switch result.verdict {
        case .monitoring: "hourglass"
        case .onPoint:    "target"
        case .ahead:      "arrow.up.forward"
        case .review:     "dial.medium"
        case .variable:   "waveform.path"
        }
    }
}
