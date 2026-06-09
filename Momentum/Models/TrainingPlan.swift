import Foundation
import SwiftData

@Model
final class TrainingPlan {
    var id: UUID = UUID()
    var goal: Goal = Goal.generalFitness
    var disciplines: [String] = []
    var raceDate: Date?
    var p5kSPerKm: Double = 360       // calibrated running pace (if running)
    var createdAt: Date = Date()
    @Relationship(deleteRule: .cascade) var sessions: [PlannedSession] = []

    init() {}
}

/// A planned session uses its cardio fields **or** its `strengthTargets`, never both (§8.7).
@Model
final class PlannedSession {
    var id: UUID = UUID()
    var date: Date = Date()           // local day
    var discipline: Discipline = Discipline.running
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
