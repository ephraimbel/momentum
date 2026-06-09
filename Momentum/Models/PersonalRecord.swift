import Foundation
import SwiftData

/// A personal record across disciplines (PRD §8.7). `value` units depend on `type`:
/// seconds (times) / meters (distances) / kg (weight, e1RM) / kg·reps (volume).
@Model
final class PersonalRecord {
    var type: PRType = PRType.fastest5k
    var value: Double = 0
    var repContext: Int?            // for repMax
    var achievedAt: Date = Date()
    var exercise: Exercise?         // for strength PRs
    var workout: Workout?

    init() {}

    init(type: PRType, value: Double, repContext: Int? = nil,
         achievedAt: Date = Date(), exercise: Exercise? = nil, workout: Workout? = nil) {
        self.type = type
        self.value = value
        self.repContext = repContext
        self.achievedAt = achievedAt
        self.exercise = exercise
        self.workout = workout
    }
}
