import Foundation
import SwiftData

/// Detects cross-session cardio achievements for a finished workout — the "you got better" facts
/// that headline the post-workout moment (PRD §22, §8.7). Deterministic + local: compares against
/// strictly-earlier workouts of the SAME type, so we never over-claim. Display-only for now
/// (persisting `PersonalRecord` rows is the analytics pass); mirrors `StrengthPRs`.
@MainActor
enum CardioAchievements {
    struct Hit: Identifiable {
        let id = UUID()
        let label: String    // e.g. "Longest run", "Fastest 5K"
        let detail: String   // e.g. "8.42 km", "24:18"
    }

    /// Returns achievements in headline priority order (the first is the competence line).
    static func detect(for workout: Workout, distanceUnit: DistanceUnit, in context: ModelContext) -> [Hit] {
        guard workout.type.isStrengthStyle == false, let gps = workout.gps, gps.distanceM > 0 else { return [] }

        let all = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
        let prior = all.filter { $0.type == workout.type && $0.startedAt < workout.startedAt && $0.gps != nil }
        guard !prior.isEmpty else { return [] }   // no claims on the first session of a type

        var hits: [Hit] = []

        // Longest distance ever (a milestone — leads when present).
        let priorMaxDist = prior.compactMap { $0.gps?.distanceM }.max() ?? 0
        if gps.distanceM > priorMaxDist + 1 {     // >1 m beyond the prior best
            hits.append(Hit(label: "Longest \(workout.type.title.lowercased())",
                            detail: Formatters.distance(meters: gps.distanceM, unit: distanceUnit)))
        }

        // Fastest benchmark windows — only meaningful for run/ride, and only distances actually covered.
        if workout.type == .run || workout.type == .ride {
            let pts = samplePoints(gps)
            for (meters, name) in [(1000.0, "1K"), (5000.0, "5K"), (10000.0, "10K")] {
                guard gps.distanceM >= meters, let cur = CardioMetrics.fastestWindow(pts, distanceM: meters) else { continue }
                let priorBest = prior.compactMap { w -> TimeInterval? in
                    guard let g = w.gps, g.distanceM >= meters else { return nil }
                    return CardioMetrics.fastestWindow(samplePoints(g), distanceM: meters)
                }.min()
                if let pb = priorBest, cur < pb - 0.5 {   // at least half a second faster
                    hits.append(Hit(label: "Fastest \(name)", detail: Formatters.duration(s: cur)))
                }
            }
        }

        // Longest time ever (last — least shareable of the wins).
        let priorMaxDur = prior.map(\.durationS).max() ?? 0
        if workout.durationS > priorMaxDur + 1 {
            hits.append(Hit(label: "Longest time", detail: Formatters.duration(s: workout.durationS)))
        }
        return hits
    }

    /// Reduce accepted GPS samples to `(elapsed, cumulative distance)` — matches the summary's reducer.
    private static func samplePoints(_ gps: GPSDetail) -> [CardioMetrics.SamplePoint] {
        let accepted = gps.samples.filter(\.accepted).sorted { $0.t < $1.t }
        guard let first = accepted.first else { return [] }
        var pts: [CardioMetrics.SamplePoint] = []
        var cumulative = 0.0
        var prev: LocationSample?
        for s in accepted {
            if let p = prev { cumulative += Geo.distance(lat1: p.lat, lon1: p.lon, lat2: s.lat, lon2: s.lon) }
            pts.append(.init(t: s.t.timeIntervalSince(first.t), cumulativeM: cumulative))
            prev = s
        }
        return pts
    }
}
