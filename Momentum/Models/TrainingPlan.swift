import Foundation
import SwiftData

@Model
final class TrainingPlan {
    var id: UUID = UUID()
    /// The athlete's own name for this block ("Austin Marathon") — shown as the Plan page title and
    /// stamped on plan sessions surfacing elsewhere (Today's banner), so plan work is unmistakable.
    /// Empty = unnamed; UI falls back to "Plan". Survives rebuilds (PlanService.persist carries it).
    var name: String = ""
    var goal: Goal = Goal.generalFitness
    var disciplines: [String] = []
    var raceDate: Date?
    var p5kSPerKm: Double = 360       // calibrated running pace (if running)
    var createdAt: Date = Date()
    var lastAdaptedAt: Date?          // last automatic load adaptation — gates auto-adapt to ≤1/week
    /// Set while the plan is paused (travel/illness — CoachActions): future sessions were shifted past
    /// this date and `reconcileMissed` stands down until it passes. Cleared by resume.
    var pausedUntil: Date?
    /// Rolling-block counter for open-ended plans (no race): 0 for the first block, +1 on each
    /// renewal (`PlanService.renewBlock`). Ignored for dated-race plans — they run one continuous
    /// macrocycle to race day. Additive: a plan stored before this field decodes as block 0.
    var blockIndex: Int = 0
    /// Macrocycle phase per plan week (PlanPhase raw values, index = weeks from the first session) —
    /// the Plan page reads as a coached block: Base → Build → Recovery → Taper.
    var weekPhases: [String] = []
    @Relationship(deleteRule: .cascade) var sessions: [PlannedSession] = []

    init() {}
}

/// A planned session uses its cardio fields **or** its `strengthTargets`, never both (§8.7).
@Model
final class PlannedSession {
    var id: UUID = UUID()
    var date: Date = Date()           // local day
    var discipline: Discipline = Discipline.running
    /// The precise sport (WorkoutType rawValue) when the athlete planned a specific one — swim, row,
    /// yoga, tennis, etc. `discipline` stays the coaching/analytics bucket; this carries the exact
    /// activity for display + matching. `nil` for AI-prescribed run/ride/walk/strength sessions.
    var sportType: String?
    var runType: RunType?
    var targetDistanceM: Double?
    var targetDurationS: Double?
    var targetPaceSPerKm: Double?
    var intervals: String?            // human-readable, e.g. "6x400m @ I"
    @Relationship(deleteRule: .cascade) var strengthTargets: [PlannedExercise] = []
    var status: SessionStatus = SessionStatus.planned
    var rationale: String?
    var completedWorkout: Workout?

    init() {}
}

extension PlannedSession {
    /// The exact planned sport, if one was chosen (else nil → falls back to `discipline` for display).
    var workoutType: WorkoutType? { sportType.flatMap(WorkoutType.init(rawValue:)) }
}

@Model
final class PlannedExercise {
    var order: Int = 0
    var exercise: Exercise?
    var targetSets: Int = 3
    var targetRepLow: Int = 8
    var targetRepHigh: Int = 12
    var targetRPE: Double?
    var targetPctRM: Double?          // % of e1RM (strength-focus)
    var progression: String = "double" // "linear" | "double" | "rpe" | "percent"

    init() {}
}
