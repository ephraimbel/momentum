import Foundation

/// The canonical **session training load** (PRD §4.8, §9) — Foster's session-RPE method:
/// `duration(min) × perceived effort (1–10)`, with a distance-based fallback when duration is
/// missing. Single source of truth shared by `ProgressInsights` (ACWR), `AthleteModelEngine`, and
/// `RecoveryModel`, so the number can never diverge between surfaces.
enum TrainingLoad {
    static func session(_ w: Workout) -> Double {
        let minutes = w.durationS / 60
        let intensity = Double(w.perceivedEffort ?? defaultIntensity(w.type))
        if minutes > 0 { return minutes * intensity }
        if let d = w.gps?.distanceM, d > 0 { return (d / 1000) * 6 }
        return 0
    }

    /// Per-discipline default RPE when the athlete didn't log one.
    static func defaultIntensity(_ type: WorkoutType) -> Int {
        switch type {
        case .run, .trailRun: 7
        case .ride, .mountainBikeRide, .gravelRide, .eBikeRide: 6
        case .hike: 6
        case .walk: 4
        case .strength, .crossfit, .hiit: 6
        case .tennis, .soccer, .basketball: 6
        case .golf, .yoga, .pilates: 3
        case .other: 5
        }
    }
}
