import SwiftUI
import SwiftData

/// Post-run time-in-zones (ENDURANCE-FOCUS §12) — the workout's heart-rate series from Apple Health
/// (Watch/Garmin runs carry one) bucketed into the athlete's five zones. Renders nothing when there's
/// no HR data or no zones — honest silence over an empty chart.
struct TimeInZonesCard: View {
    let workout: Workout

    @Query private var profiles: [UserProfile]
    @Environment(Services.self) private var services
    @State private var distribution: [TimeInterval]?

    private var zones: [HRZones.Zone]? {
        guard let maxHR = profiles.first?.maxHR else { return nil }
        return HRZones.zones(maxHR: maxHR, restingHR: profiles.first?.restingHR)
    }

    var body: some View {
        ZStack {
            // A zero-size anchor so the `.task` below always runs — lifecycle modifiers never fire on
            // an empty view, and the card starts empty until the HR series loads (the classic trap).
            Color.clear.frame(width: 0, height: 0)
            if let zones, let dist = distribution {
                let total = dist.reduce(0, +)
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text("TIME IN ZONES")
                        .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                        .foregroundStyle(Theme.inkTertiary)
                    VStack(spacing: Theme.Space.sm) {
                        ForEach(zones) { z in
                            let secs = dist[z.index - 1]
                            HStack(spacing: Theme.Space.md) {
                                Text(z.label)
                                    .font(.rounded(Theme.FontSize.caption, weight: .black)).monospacedDigit()
                                    .foregroundStyle(z.index >= 4 ? Theme.background : Theme.ink)
                                    .frame(width: 34, height: 24)
                                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Theme.ink.opacity(0.06 + 0.18 * Double(z.index))))
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Theme.ink.opacity(0.10 + 0.16 * Double(z.index)))
                                        .frame(width: max(secs > 0 ? 6 : 0, geo.size.width * (total > 0 ? secs / total : 0)))
                                        .frame(maxHeight: .infinity, alignment: .center)
                                }
                                .frame(height: 14)
                                Text(secs > 0 ? Formatters.duration(s: secs) : "—")
                                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(secs > 0 ? Theme.inkSecondary : Theme.inkTertiary)
                                    .frame(width: 56, alignment: .trailing)
                            }
                        }
                    }
                    Text("From your heart-rate data · zones personalized to you")
                        .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.md)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(a11ySummary(zones: zones, dist: dist))
                .id("timeInZones")
            }
        }
        .task {
            guard distribution == nil, let zones else {
                #if DEBUG
                print("[zones] no zones — maxHR=\(String(describing: profiles.first?.maxHR))")
                #endif
                return
            }
            let end = workout.startedAt.addingTimeInterval(max(workout.elapsedS, workout.durationS))
            let series = await services.health.heartRateSeries(start: workout.startedAt, end: end)
            distribution = ZoneDistribution.compute(samples: series, zones: zones)
            #if DEBUG
            print("[zones] series=\(series.count) dist=\(distribution?.map { Int($0) } ?? [])")
            #endif
        }
    }

    private func a11ySummary(zones: [HRZones.Zone], dist: [TimeInterval]) -> String {
        let parts = zones.compactMap { z -> String? in
            let secs = dist[z.index - 1]
            return secs > 0 ? "\(z.label) \(Formatters.duration(s: secs))" : nil
        }
        return "Time in heart-rate zones: \(parts.joined(separator: ", "))"
    }
}
