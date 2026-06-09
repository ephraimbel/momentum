import Foundation
import SwiftData

@Model
final class StrengthSession {
    var totalVolumeKg: Double = 0
    var totalSets: Int = 0
    @Relationship(deleteRule: .cascade) var exercises: [WorkoutExercise] = []

    init() {}
}

@Model
final class WorkoutExercise {
    var order: Int = 0
    var supersetGroup: Int?         // nil = standalone
    var note: String = ""
    var exercise: Exercise?         // catalog/custom ref
    @Relationship(deleteRule: .cascade) var sets: [SetEntry] = []

    init() {}
}

/// Durability: every completed set persists immediately and is **never deleted on edit**.
@Model
final class SetEntry {
    var index: Int = 0
    var weightKg: Double?           // weightReps mode
    var reps: Int?
    var durationS: Double?          // time mode
    var distanceM: Double?          // distance mode (carries)
    var rpe: Double?                // 6–10, optional
    var type: SetType = SetType.working
    var isComplete: Bool = false
    var restS: Double = 120

    init() {}
}
