import Foundation

/// Estimates a runner's current baseline from recent runs intentionally recorded in Momentum or
/// restored through Momentum account sync (ENDURANCE-FOCUS §4). Apple Health never supplies these
/// samples. Pure + deterministic.
///
/// Doctrine: training runs are not races, so the pace estimate is deliberately conservative — we take
/// the best sustained effort at face value (no all-out bonus). A slightly slow seed self-corrects in
/// the first calibration weeks; a fast one causes every easy run to feel hard and erodes trust.
enum BaselineEstimator {

    /// One historical Momentum run, projected into plain values by the caller.
    struct RunSample: Sendable {
        let date: Date
        let distanceM: Double
        let durationS: Double
        var paceSPerKm: Double? {
            guard distanceM > 0, durationS > 0 else { return nil }
            return durationS / (distanceM / 1000)
        }
    }

    /// How much history backs the estimate — low confidence starts the plan conservative and lets the
    /// first weeks calibrate (ENDURANCE-FOCUS §4 "baseline confidence").
    enum Confidence: String, Sendable { case high, medium, low }

    struct RunningBaseline: Sendable {
        /// Estimated current 5K pace (s/km), Riegel'd from the best sustained recent effort.
        let p5kSPerKm: Double
        /// Average weekly running volume over the window (meters).
        let weeklyVolumeM: Double
        let longestRunM: Double
        let runsPerWeek: Double
        let runCount: Int
        let confidence: Confidence
    }

    /// Window of history considered "current fitness".
    static let windowDays = 56          // 8 weeks
    /// Minimum runs to say anything at all.
    static let minRuns = 3

    /// Sanity gates — drop walks mislabelled as runs and GPS junk.
    private static let paceRange: ClosedRange<Double> = 150...720   // 2:30–12:00 /km
    private static let minDistanceM = 1_000.0

    static func estimate(from samples: [RunSample], now: Date = Date()) -> RunningBaseline? {
        let cutoff = now.addingTimeInterval(-Double(windowDays) * 86_400)
        let runs = samples.filter { run in
            guard run.date >= cutoff, run.date <= now, run.distanceM >= minDistanceM,
                  let pace = run.paceSPerKm else { return false }
            return paceRange.contains(pace)
        }
        guard runs.count >= minRuns else { return nil }

        let weeks = Double(windowDays) / 7.0
        let totalM = runs.reduce(0) { $0 + $1.distanceM }
        let weeklyM = totalM / weeks
        let longestM = runs.map(\.distanceM).max() ?? 0
        let perWeek = Double(runs.count) / weeks

        // Best sustained effort: fastest pace over runs of ≥ 3 km (short bursts overestimate fitness),
        // falling back to the fastest overall if nothing is that long. Riegel it to a 5K pace.
        let sustained = runs.filter { $0.distanceM >= 3_000 }
        let best = (sustained.isEmpty ? runs : sustained)
            .min { ($0.paceSPerKm ?? .infinity) < ($1.paceSPerKm ?? .infinity) }
        guard let bestRun = best, bestRun.paceSPerKm != nil else { return nil }
        let p5k = PlanEngine.riegelP5k(distanceM: bestRun.distanceM, timeS: bestRun.durationS)

        let confidence: Confidence = runs.count >= 12 ? .high : runs.count >= 6 ? .medium : .low
        return RunningBaseline(p5kSPerKm: p5k, weeklyVolumeM: weeklyM, longestRunM: longestM,
                               runsPerWeek: perWeek, runCount: runs.count, confidence: confidence)
    }
}
