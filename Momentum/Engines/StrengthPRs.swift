import Foundation
import SwiftData

/// Detects strength PRs for a finished workout by comparing it against prior sessions (PRD §22).
/// Display-only for Phase 1; persisting `PersonalRecord` rows is wired in the analytics pass.
@MainActor
enum StrengthPRs {
    struct Hit: Identifiable {
        let id = UUID()
        let exerciseName: String
        let label: String      // e.g. "e1RM PR", "Heaviest"
        let detail: String     // e.g. "84 kg"
    }

    static func detect(for workout: Workout, weightUnit: WeightUnit, in context: ModelContext) -> [Hit] {
        guard let session = workout.strength else { return [] }

        // Historical bests per exercise id from strictly-earlier strength workouts.
        let all = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
        let prior = all.filter { $0.type.isStrengthStyle && $0.startedAt < workout.startedAt }
        var bestE1RM: [UUID: Double] = [:]
        var bestWeight: [UUID: Double] = [:]
        for w in prior {
            for row in w.strength?.exercises ?? [] {
                guard let exId = row.exercise?.id else { continue }
                for set in row.sets where set.isComplete && set.type == .working {
                    guard let weight = set.weightKg, let reps = set.reps else { continue }
                    bestE1RM[exId] = max(bestE1RM[exId] ?? 0, StrengthMath.e1RM(weightKg: weight, reps: reps))
                    bestWeight[exId] = max(bestWeight[exId] ?? 0, weight)
                }
            }
        }

        var hits: [Hit] = []
        for row in session.exercises {
            guard let ex = row.exercise else { continue }
            let working = row.sets.compactMap { s -> StrengthMath.WorkingSet? in
                guard s.isComplete, s.type == .working, let w = s.weightKg, let r = s.reps else { return nil }
                return .init(weightKg: w, reps: r)
            }
            guard !working.isEmpty else { continue }

            let e1rm = StrengthMath.bestE1RM(working)
            let heaviest = StrengthMath.heaviestWeight(working)

            if e1rm > (bestE1RM[ex.id] ?? 0) + 0.01 {
                hits.append(Hit(exerciseName: ex.name, label: "e1RM PR",
                                detail: weightString(kg: e1rm, unit: weightUnit)))
            }
            if heaviest > (bestWeight[ex.id] ?? 0) + 0.01 {
                hits.append(Hit(exerciseName: ex.name, label: "Heaviest",
                                detail: weightString(kg: heaviest, unit: weightUnit)))
            }
        }
        return hits
    }

    private static func weightString(kg: Double, unit: WeightUnit) -> String {
        Formatters.weight(kg: kg, unit: unit)
    }
}
