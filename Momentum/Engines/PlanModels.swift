import Foundation

/// Pure value types produced by `PlanEngine` (PRD §9). Kept free of SwiftData so generation is
/// unit-testable; `PlanPersistence` maps these onto `TrainingPlan`/`PlannedSession` models.

/// A lightweight catalog snapshot the engine selects strength exercises from.
struct ExerciseCatalogItem: Sendable, Equatable {
    let name: String
    let primaryMuscles: [MuscleGroup]
    let secondaryMuscles: [MuscleGroup]
    let equipment: EquipmentType
    let category: ExerciseCategory
    let defaultRestS: Double
    /// How the exercise is measured. The engine MUST see this: without it the catalog looked
    /// rep-shaped all the way down, so `scheme(…)` happily prescribed "3 × 10–15" for a plank.
    /// `selectExercise` now uses it to auto-prescribe rep-countable exercises ONLY.
    var trackingMode: TrackingMode = .weightReps
}

/// Optional calibration seeds gathered in onboarding (§26).
struct CalibrationSeed: Sendable, Equatable {
    /// A recent run effort over any known distance → Riegel-seeded 5k pace (most precise).
    var recentRun: (distanceM: Double, timeS: Double)?
    /// A self-reported "by feel" 5k-pace estimate (s/km) for athletes with no recent time to enter.
    var estimatedP5kSPerKm: Double?
    /// Known lift e1RMs by exercise name (kg).
    var lifts: [String: Double] = [:]

    // The athlete state (2026-09-03, `AthleteStateEngine`): three reads derived from the athlete's
    // own logged runs, each optional so a seed without evidence generates exactly what it always
    // did. `PlanService` fills them on every (re)generation; onboarding never sets them.
    /// Observed threshold pace (s/km): what the athlete has actually held for about an hour.
    /// Anchors the steady/threshold family; easy stays derived from the 5K.
    var thresholdSPerKm: Double?
    /// The athlete's own Riegel fatigue exponent for race predictions. Nil = population 1.06.
    var riegelExponent: Double?
    /// How the athlete holds up late in long runs — shapes long-run growth, never its caps.
    var durability: DurabilitySignal?

    static let none = CalibrationSeed()

    // Equatable can't synthesize for the tuple; compare fields explicitly.
    static func == (a: CalibrationSeed, b: CalibrationSeed) -> Bool {
        a.recentRun?.distanceM == b.recentRun?.distanceM
            && a.recentRun?.timeS == b.recentRun?.timeS
            && a.estimatedP5kSPerKm == b.estimatedP5kSPerKm
            && a.lifts == b.lifts
            && a.thresholdSPerKm == b.thresholdSPerKm
            && a.riegelExponent == b.riegelExponent
            && a.durability == b.durability
    }
}

struct GeneratedExercise: Sendable, Equatable {
    var exerciseName: String
    var targetSets: Int
    var repLow: Int
    var repHigh: Int
    var targetRPE: Double?
    var targetPctRM: Double?
    var progression: String   // "linear" | "double" | "percent" | "rpe"
}

struct GeneratedSession: Sendable, Equatable {
    var dayOffset: Int        // 0…6 within the week
    var discipline: Discipline
    var runType: RunType?
    var targetDistanceM: Double?
    var targetDurationS: Double?
    var targetPaceSPerKm: Double?
    var intervals: String?
    var strengthLabel: String?
    var strengthTargets: [GeneratedExercise] = []
    var rationale: String?

    /// Recovery-scheduling classifiers (§9.3).
    var isHardLowerLift: Bool = false
    var isHardRun: Bool = false   // intervals/tempo/race
}

struct GeneratedWeek: Sendable, Equatable {
    var index: Int            // 0-based
    var isDeload: Bool
    var isTaper: Bool
    /// Macrocycle phase (base → build → peak → taper, deloads = recovery) — computed at generation
    /// so persistence and the Plan page never re-derive it.
    var phase: PlanPhase = .build
    var sessions: [GeneratedSession]

    /// Total prescribed running TRAINING distance for the week (meters) — for progression and
    /// recent-to-usual-load invariants. The race session is deliberately excluded: it is the objective the ramp
    /// delivers you to, not ramp load to govern (nothing trains after it — race week is cleared).
    var runVolumeM: Double {
        sessions.filter { ($0.discipline == .running || $0.discipline == .walking) && $0.runType != .race }
            .reduce(0) { $0 + ($1.targetDistanceM ?? 0) }
    }

    /// The same number for whichever endurance sport the plan is built on — running, walking or
    /// cycling. The legacy-named load governor and the cutback passes run on THIS (2026-08-30): a cyclist's
    /// plan is a plan too, and reading it through `runVolumeM` reported zero for every week, so
    /// the progression governor and the "a down week goes down" rule both quietly did nothing. A plan
    /// only ever carries one cardio discipline, so this never mixes sports.
    var trainingVolumeM: Double {
        sessions.filter { $0.discipline != .strength && $0.runType != .race }
            .reduce(0) { $0 + ($1.targetDistanceM ?? 0) }
    }
}

struct GeneratedPlan: Sendable, Equatable {
    var p5kSPerKm: Double
    /// The pace goal-pace sessions are set at (s/km): the athlete's goal, honesty-capped by the
    /// improvement model. nil without a goal time. Persisted so recalibration never re-stamps it.
    var goalRacePaceSPerKm: Double? = nil
    /// The athlete-state reads the plan was built with (see `CalibrationSeed`), carried so the
    /// persisted plan can re-derive paces the same way and explain where they came from.
    var thresholdSPerKm: Double? = nil
    var riegelExponent: Double? = nil
    var durability: DurabilitySignal? = nil
    var weeks: [GeneratedWeek]
}
