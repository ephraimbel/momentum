import Foundation
import SwiftData

/// Looks up an exercise's most recent prior session so the logger can show ghosted previous
/// numbers and prefill (PRD §4.4 "previous numbers always visible", §22 prefill precedence).
/// Phase 1 scans recent strength workouts in memory; a keyed query/index can optimize later.
@MainActor
enum PreviousPerformance {
    struct PrevSet: Sendable { let weightKg: Double?; let reps: Int? }

    /// Completed sets (by set index) from the latest prior workout containing this exercise.
    static func lastSession(forExerciseId id: UUID, in context: ModelContext) -> [Int: PrevSet] {
        let workouts = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
        let strength = workouts
            .filter { $0.type.isStrengthStyle }
            .sorted { $0.startedAt > $1.startedAt }

        for workout in strength {
            guard let match = workout.strength?.exercises.first(where: { $0.exercise?.id == id }),
                  match.sets.contains(where: { $0.isComplete }) else { continue }
            var byIndex: [Int: PrevSet] = [:]
            for set in match.sets where set.isComplete {
                byIndex[set.index] = PrevSet(weightKg: set.weightKg, reps: set.reps)
            }
            return byIndex
        }
        return [:]
    }
}
