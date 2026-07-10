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
}

/// Optional calibration seeds gathered in onboarding (§26).
struct CalibrationSeed: Sendable, Equatable {
    /// A recent run effort over any known distance → Riegel-seeded 5k pace (most precise).
    var recentRun: (distanceM: Double, timeS: Double)?
    /// A self-reported "by feel" 5k-pace estimate (s/km) for athletes with no recent time to enter.
    var estimatedP5kSPerKm: Double?
    /// Known lift e1RMs by exercise name (kg).
    var lifts: [String: Double] = [:]

    static let none = CalibrationSeed()

    // Equatable can't synthesize for the tuple; compare fields explicitly.
    static func == (a: CalibrationSeed, b: CalibrationSeed) -> Bool {
        a.recentRun?.distanceM == b.recentRun?.distanceM
            && a.recentRun?.timeS == b.recentRun?.timeS
            && a.estimatedP5kSPerKm == b.estimatedP5kSPerKm
            && a.lifts == b.lifts
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

    /// Total prescribed running distance for the week (meters) — for the ≤10%/wk invariant.
    var runVolumeM: Double {
        sessions.filter { $0.discipline == .running || $0.discipline == .walking }
            .reduce(0) { $0 + ($1.targetDistanceM ?? 0) }
    }
}

struct GeneratedPlan: Sendable, Equatable {
    var p5kSPerKm: Double
    var weeks: [GeneratedWeek]
}
