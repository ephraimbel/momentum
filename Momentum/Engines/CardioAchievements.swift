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
        // Typed record info so the save flow can persist a PersonalRecord (nil = display-only).
        var prType: PRType? = nil
        var value: Double = 0
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
                            detail: Formatters.distance(meters: gps.distanceM, unit: distanceUnit),
                            prType: workout.type == .run ? .longestRun : nil, value: gps.distanceM))
        }

        // Fastest benchmark windows — a RUNNING record only (a ride covers these distances far
        // faster and would corrupt the run PRs), and only distances actually covered.
        if workout.type == .run, gps.distanceM >= 1_000 {   // shorter than the smallest benchmark → skip the scan
            // `GPSDetail.routePoints` — the same engine-consistent replay the splits and the record
            // book use. A raw haversine walk over the stored fixes (what this used to do) runs long
            // by GPS jitter, so every benchmark window closed early and the "PR" was minutes fast.
            let pts = gps.samplePoints(type: workout.type)
            // Reduce each prior run ONCE. The comparison below runs over six benchmark distances,
            // and deriving the points inside that loop replayed every previous run's samples six
            // times — cheap-ish as a raw walk, but the replay is a Kalman pass over every fix, and
            // this whole pass is main-actor work in the summary's `.task`. One pass per run.
            let priorPoints: [(distanceM: Double, points: [CardioMetrics.SamplePoint])] =
                prior.compactMap { w in
                    guard let g = w.gps, g.distanceM >= 1_000 else { return nil }
                    return (g.distanceM, g.samplePoints(type: w.type))
                }
            for (meters, name) in [(1000.0, "1K"), (5000.0, "5K"), (10000.0, "10K"),
                                   (21_097.5, "half"), (42_195.0, "marathon"), (50_000.0, "50K")] {
                guard gps.distanceM >= meters, let cur = CardioMetrics.fastestWindow(pts, distanceM: meters) else { continue }
                let priorBest = priorPoints.compactMap { prior -> TimeInterval? in
                    guard prior.distanceM >= meters else { return nil }
                    return CardioMetrics.fastestWindow(prior.points, distanceM: meters)
                }.min()
                if let pb = priorBest, cur < pb - 0.5 {   // at least half a second faster
                    let prType: PRType? = switch meters {
                    case 1000: .fastest1k
                    case 5000: .fastest5k
                    case 10000: .fastest10k
                    case 21_097.5: .fastestHalf
                    case 42_195.0: .fastestMarathon
                    case 50_000.0: .fastest50k
                    default: nil
                    }
                    hits.append(Hit(label: "Fastest \(name)", detail: Formatters.duration(s: cur),
                                    prType: prType, value: cur))
                }
            }
        }

        // Longest time ever (last — least shareable of the wins).
        let priorMaxDur = prior.map(\.durationS).max() ?? 0
        if workout.durationS > priorMaxDur + 1 {
            hits.append(Hit(label: "Longest time", detail: Formatters.duration(s: workout.durationS),
                            prType: .longestDuration, value: workout.durationS))
        }
        return hits
    }

    /// Whether this is the athlete's first-ever GPS workout of its discipline — the case where
    /// `detect` makes no "you got better" claim (empty prior), yet the run's own bests must still
    /// SEED the record book (mirrors `StrengthPRs` recording the first lift off a 0 baseline).
    static func isFirstOfType(_ workout: Workout, in context: ModelContext) -> Bool {
        let all = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
        return !all.contains { $0.type == workout.type && $0.startedAt < workout.startedAt && $0.gps != nil }
    }

}
