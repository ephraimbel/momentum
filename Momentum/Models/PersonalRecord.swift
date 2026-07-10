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

    /// Persist the records a finished workout earned onto the athlete's PR shelf (the "PRs" stat
    /// and future record surfaces read `profile.prs`). Call with the SAME context the hits were
    /// detected in; dedupes per (type, exercise) against the workout so a re-save can't double-log.
    @MainActor
    static func persist(_ entries: [(type: PRType, value: Double, exercise: Exercise?)],
                        workout: Workout, in context: ModelContext) {
        guard !entries.isEmpty,
              let profile = ((try? context.fetch(FetchDescriptor<UserProfile>())) ?? []).first
        else { return }
        for entry in entries {
            let already = profile.prs.contains {
                $0.type == entry.type && $0.workout?.id == workout.id && $0.exercise?.id == entry.exercise?.id
            }
            guard !already else { continue }
            let pr = PersonalRecord(type: entry.type, value: entry.value,
                                    achievedAt: workout.startedAt, exercise: entry.exercise, workout: workout)
            profile.prs.append(pr)
        }
        try? context.save()
    }
}
