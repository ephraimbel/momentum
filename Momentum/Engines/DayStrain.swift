import Foundation

/// Daily strain 0–100 (Recovery Hub plan §4.3) — how much load today put on the body: every
/// workout folded through the canonical `TrainingLoad`, plus the everyday movement (steps, or
/// active energy when no step source exists) the legs still had to absorb. Raw load is scaled
/// against chronic fitness (`FitnessFreshness` CTL) through a **saturating curve**, so the same
/// session reads lower as the athlete's base grows — "this used to be a hard day for you".
/// Pure + deterministic; the AI narrates it — no medical claims.
///
/// Naming note: `RecoveryModel.strain` (Foster weekly load × monotony) is a different, internal
/// quantity that never renders under this name — the UI word "Strain" is only ever this engine.
@MainActor
struct DayStrain {
    /// Strain bands — there is no bad band; Peak is a deliberately big day, not a scolding.
    enum Band: String, Sendable {
        case light = "Light"
        case moderate = "Moderate"
        case hard = "Hard"
        case peak = "Peak"
    }

    let score: Int            // 0–100; saturates, never cliffs
    let band: Band
    let workoutLoad: Double   // Σ TrainingLoad.session over today's workouts (Foster units)
    let ambientLoad: Double   // non-workout movement in the same units, walking-HR adjusted

    /// - Parameters:
    ///   - workoutsToday: candidate workouts — only those whose `startedAt` lands on today's
    ///     local day (by `calendar.startOfDay`, the shipped bucketing convention) count, so a
    ///     23:50 run never leaks into tomorrow.
    ///   - ambientSteps: non-workout steps (the service nets out workout windows, clamps ≥ 0).
    ///   - ambientActiveKcal: fallback when no step source exists — never summed with steps
    ///     (they'd be the same movement counted twice).
    ///   - walkingHRAvg: today's everyday-movement heart rate, read against `walkingHRBaseline`
    ///     — the same steps cost more on a fatigued body. Bounded to ±15%: a whisper, not a pillar.
    ///   - chronicLoad: FitnessFreshness CTL — the daily load the athlete is adapted to absorb.
    init(workoutsToday: [Workout],
         ambientSteps: Double? = nil,
         ambientActiveKcal: Double? = nil,
         walkingHRAvg: Double? = nil,
         walkingHRBaseline: HealthBaselines.Baseline? = nil,
         chronicLoad: Double,
         now: Date = Date(),
         calendar: Calendar = .current) {
        // Workout half — day-bucketed through the one canonical session-load formula.
        let today = calendar.startOfDay(for: now)
        workoutLoad = workoutsToday
            .filter { calendar.startOfDay(for: $0.startedAt) == today }
            .reduce(0) { $0 + TrainingLoad.session($1) }

        // Ambient half — steps primary (≈10 load per 1000), active energy only as the fallback.
        let base: Double
        if let steps = ambientSteps {
            base = max(0, steps) / 1_000 * 10
        } else if let kcal = ambientActiveKcal {
            base = max(0, kcal) * 0.25
        } else {
            base = 0
        }
        // Walking-HR nudge: elevated everyday HR marks the movement as costlier; suppressed as
        // cheaper. Missing reading or unlearned baseline → no nudge, never a guess.
        var multiplier = 1.0
        if let avg = walkingHRAvg, let baseline = walkingHRBaseline, baseline.mean > 0.000_1 {
            multiplier = min(max(avg / baseline.mean, 0.9), 1.15)
        }
        ambientLoad = base * multiplier

        // Saturating curve against chronic fitness: raw = reference → 46, 2× → 71, 3× → 85.
        // Scale-free by design — the identical session scores lower as CTL grows. The cold-start
        // floor (30) keeps a week-one athlete's every jog from reading Peak.
        let raw = workoutLoad + ambientLoad
        let reference = max(chronicLoad, 30)
        score = Int((100 * (1 - exp(-raw / (1.6 * reference)))).rounded())
        band = Self.band(score)
    }

    /// Band cuts: 0–24 light · 25–49 moderate · 50–74 hard · 75+ peak.
    static func band(_ score: Int) -> Band {
        switch score {
        case 75...:   .peak
        case 50..<75: .hard
        case 25..<50: .moderate
        default:      .light
        }
    }
}
