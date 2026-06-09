import Foundation
import SwiftData

/// Seeds a small curated exercise set so the strength logger has data in Phase 0.
/// The full ~150–300 catalog (PRD §13.7) lands in Phase 1, gated on the licensing decision (§16).
enum ExerciseLibrarySeed {
    static let version = 1

    @MainActor
    static func seedIfNeeded(into context: ModelContext) {
        // Count shared-library entries (filtering in memory avoids a #Predicate keypath that
        // isn't Sendable under strict concurrency). At first launch the store is empty anyway.
        let all = (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
        guard all.contains(where: { !$0.isCustom }) == false else { return }

        for ex in curated { context.insert(ex) }
        try? context.save()
    }

    static var curated: [Exercise] {
        [
            Exercise(name: "Barbell Back Squat", primaryMuscles: [.quads],
                     secondaryMuscles: [.glutes, .hamstrings, .core], equipment: .barbell,
                     category: .compound, defaultRestS: 150,
                     instructions: "Brace, sit between your hips, drive through mid-foot."),
            Exercise(name: "Barbell Deadlift", primaryMuscles: [.hamstrings, .glutes],
                     secondaryMuscles: [.back, .core, .forearms], equipment: .barbell,
                     category: .compound, defaultRestS: 180,
                     instructions: "Neutral spine, push the floor away, lock out tall."),
            Exercise(name: "Barbell Bench Press", primaryMuscles: [.chest],
                     secondaryMuscles: [.triceps, .shoulders], equipment: .barbell,
                     category: .compound, defaultRestS: 150,
                     instructions: "Retract shoulder blades, bar to mid-chest, drive up."),
            Exercise(name: "Overhead Press", primaryMuscles: [.shoulders],
                     secondaryMuscles: [.triceps, .core], equipment: .barbell,
                     category: .compound, defaultRestS: 150),
            Exercise(name: "Barbell Row", primaryMuscles: [.back],
                     secondaryMuscles: [.biceps, .forearms], equipment: .barbell,
                     category: .compound, defaultRestS: 150),
            Exercise(name: "Pull-Up", primaryMuscles: [.back],
                     secondaryMuscles: [.biceps, .forearms], equipment: .bodyweight,
                     category: .compound, trackingMode: .repsOnly, defaultRestS: 120),
            Exercise(name: "Incline Dumbbell Press", primaryMuscles: [.chest],
                     secondaryMuscles: [.shoulders, .triceps], equipment: .dumbbell,
                     category: .compound, defaultRestS: 120),
            Exercise(name: "Dumbbell Shoulder Press", primaryMuscles: [.shoulders],
                     secondaryMuscles: [.triceps], equipment: .dumbbell,
                     category: .compound, defaultRestS: 120),
            Exercise(name: "Romanian Deadlift", primaryMuscles: [.hamstrings],
                     secondaryMuscles: [.glutes, .back], equipment: .barbell,
                     category: .compound, defaultRestS: 150),
            Exercise(name: "Leg Press", primaryMuscles: [.quads],
                     secondaryMuscles: [.glutes], equipment: .machine,
                     category: .compound, defaultRestS: 120),
            Exercise(name: "Lat Pulldown", primaryMuscles: [.back],
                     secondaryMuscles: [.biceps], equipment: .cable,
                     category: .compound, defaultRestS: 90),
            Exercise(name: "Seated Cable Row", primaryMuscles: [.back],
                     secondaryMuscles: [.biceps, .forearms], equipment: .cable,
                     category: .compound, defaultRestS: 90),
            Exercise(name: "Dumbbell Curl", primaryMuscles: [.biceps],
                     secondaryMuscles: [.forearms], equipment: .dumbbell,
                     category: .isolation, defaultRestS: 75),
            Exercise(name: "Triceps Pushdown", primaryMuscles: [.triceps],
                     equipment: .cable, category: .isolation, defaultRestS: 75),
            Exercise(name: "Lateral Raise", primaryMuscles: [.shoulders],
                     equipment: .dumbbell, category: .isolation, defaultRestS: 60),
            Exercise(name: "Leg Curl", primaryMuscles: [.hamstrings],
                     equipment: .machine, category: .isolation, defaultRestS: 75),
            Exercise(name: "Leg Extension", primaryMuscles: [.quads],
                     equipment: .machine, category: .isolation, defaultRestS: 75),
            Exercise(name: "Calf Raise", primaryMuscles: [.calves],
                     equipment: .machine, category: .isolation, defaultRestS: 60),
            Exercise(name: "Plank", primaryMuscles: [.core],
                     equipment: .bodyweight, category: .isolation,
                     trackingMode: .time, defaultRestS: 60),
            Exercise(name: "Farmer's Carry", primaryMuscles: [.forearms, .core],
                     secondaryMuscles: [.fullBody], equipment: .dumbbell,
                     category: .compound, trackingMode: .distance, defaultRestS: 90),
        ]
    }
}
