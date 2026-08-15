import Foundation
import SwiftData

/// Seeds a small curated exercise set so the strength logger has data in Phase 0.
/// The full ~150–300 catalog (PRD §13.7) lands in Phase 1, gated on the licensing decision (§16).
enum ExerciseLibrarySeed {
    static let version = 1

    // NOTE (perf audit 2026-08-13): a UserDefaults stamp fast-path was tried here and REVERTED —
    // the stamp outlives the store (quarantine-recreated stores would never reseed, and it leaks
    // across in-memory test containers). The walk below is ~50 tiny rows; it is not the
    // container-init cost that matters.
    @MainActor
    static func seedIfNeeded(into context: ModelContext) {
        // Count shared-library entries (filtering in memory avoids a #Predicate keypath that
        // isn't Sendable under strict concurrency). At first launch the store is empty anyway.
        let all = (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
        guard all.contains(where: { !$0.isCustom }) == false else {
            dedupe(all, in: context)
            topUp(in: context)
            return
        }

        for ex in curated { context.insert(ex) }
        try? context.save()
    }

    /// Insert curated exercises the store is missing.
    ///
    /// `seedIfNeeded` only plants the library when the store has NO shared rows, so on every
    /// existing install a newly-curated exercise would never arrive — the seed would be skipped
    /// forever and the addition would silently only reach fresh installs. Runs after `dedupe`, so
    /// legacy names have already been canonicalized and this can't resurrect a renamed row as a
    /// "missing" one. Matches on name, never touches the user's custom exercises.
    @MainActor
    private static func topUp(in context: ModelContext) {
        let existing = Set(((try? context.fetch(FetchDescriptor<Exercise>())) ?? [])
            .filter { !$0.isCustom }.map(\.name))
        let missing = curated.filter { !existing.contains($0.name) }
        guard !missing.isEmpty else { return }
        for ex in missing { context.insert(ex) }
        try? context.save()
    }

    /// Canonical names for shared rows an earlier seed created under a different name.
    private static let renames = ["Back Squat": "Barbell Back Squat"]

    /// Self-heal stores that picked up duplicate library rows (an early DemoSeed inserted its
    /// own copies of four lifts, so "Barbell Bench Press" listed twice in the exercise search).
    /// Same-name shared rows merge into one survivor — preferring the curated row, which carries
    /// instructions and a real rest prescription — with workout history, PRs, and plan targets
    /// re-pointed before the extras are deleted. Custom exercises are the user's; never touched.
    @MainActor
    private static func dedupe(_ all: [Exercise], in context: ModelContext) {
        var byName: [String: [Exercise]] = [:]
        for ex in all where !ex.isCustom {
            byName[renames[ex.name] ?? ex.name, default: []].append(ex)
        }
        var healed = false
        for (canonical, group) in byName {
            // A legacy-named row with nothing to merge into just takes its canonical name.
            if group.count == 1 {
                if group[0].name != canonical { group[0].name = canonical; healed = true }
                continue
            }
            let survivor = group.first { !$0.instructions.isEmpty }
                ?? group.first { $0.defaultRestS != 120 }
                ?? group[0]
            survivor.name = canonical
            let dupeIds = Set(group.filter { $0 !== survivor }.map(\.id))
            reassign(dupeIds, to: survivor, in: context)
            for dupe in group where dupe !== survivor { context.delete(dupe) }
            healed = true
        }
        if healed { try? context.save() }
    }

    @MainActor
    private static func reassign(_ dupeIds: Set<UUID>, to survivor: Exercise, in context: ModelContext) {
        for row in (try? context.fetch(FetchDescriptor<WorkoutExercise>())) ?? []
        where row.exercise.map({ dupeIds.contains($0.id) }) == true {
            row.exercise = survivor
        }
        for pr in (try? context.fetch(FetchDescriptor<PersonalRecord>())) ?? []
        where pr.exercise.map({ dupeIds.contains($0.id) }) == true {
            pr.exercise = survivor
        }
        for target in (try? context.fetch(FetchDescriptor<PlannedExercise>())) ?? []
        where target.exercise.map({ dupeIds.contains($0.id) }) == true {
            target.exercise = survivor
        }
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
            // Core work the plan can actually PRESCRIBE and the athlete can actually progress.
            // Plank stays in the library (people do planks, and they should be able to log one),
            // but a hold has no rep count, so the planner reaches for these first — reps give
            // the progression machinery something to push on week to week.
            Exercise(name: "Hanging Knee Raise", primaryMuscles: [.core],
                     secondaryMuscles: [.forearms], equipment: .bodyweight,
                     category: .isolation, trackingMode: .repsOnly, defaultRestS: 60),
            // The floor alternative — no bar needed, so athletes training at home still get a
            // rep-counted core exercise instead of falling through to the plank.
            Exercise(name: "Lying Leg Raise", primaryMuscles: [.core],
                     equipment: .bodyweight, category: .isolation,
                     trackingMode: .repsOnly, defaultRestS: 60),
            Exercise(name: "Plank", primaryMuscles: [.core],
                     equipment: .bodyweight, category: .isolation,
                     trackingMode: .time, defaultRestS: 60),
            // The countable forearms option. Without it the Pull day's forearm slot had only
            // Farmer's Carry to reach for — a distance carry, which the planner now refuses —
            // and the slot would silently go empty.
            Exercise(name: "Dumbbell Wrist Curl", primaryMuscles: [.forearms],
                     equipment: .dumbbell, category: .isolation,
                     trackingMode: .weightReps, defaultRestS: 60),
            // Loggable by hand, never auto-prescribed: a carry is measured in distance/time and
            // the set logger records reps × weight. Same arrangement as Plank above.
            Exercise(name: "Farmer's Carry", primaryMuscles: [.forearms, .core],
                     secondaryMuscles: [.fullBody], equipment: .dumbbell,
                     category: .compound, trackingMode: .distance, defaultRestS: 90),
        ]
    }
}

/// Resolve a spoken/typed exercise name against the library BEFORE minting a custom row.
/// "bench press", "Squats", and "pull ups" must find "Barbell Bench Press", "Barbell Back
/// Squat", and "Pull-Up" — the old exact-match-only lookup quietly created a duplicate custom
/// exercise per utterance, which is how doubles crept into the search. Matching stays
/// deterministic: exact, then normalized, then a singular retry, then a short alias table of
/// unambiguous gym shorthand. Anything that still misses really is a new exercise.
enum ExerciseNameMatch {

    static func find(_ name: String, in library: [Exercise]) -> Exercise? {
        if let exact = library.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return exact
        }
        // Shared rows win a normalized-key collision with a same-named custom (the custom is
        // reachable by its exact name; the canonical row is what shorthand should land on).
        var byKey: [String: Exercise] = [:]
        for ex in library {
            let k = normalize(ex.name)
            if byKey[k] == nil || (byKey[k]?.isCustom == true && !ex.isCustom) { byKey[k] = ex }
        }
        for candidate in variants(of: normalize(name)) {
            if let hit = byKey[candidate] { return hit }
            if let canonical = aliases[candidate], let hit = byKey[normalize(canonical)] { return hit }
        }
        return nil
    }

    /// Lowercase letters/digits only: "Pull-Up" → "pullup", "Farmer's Carry" → "farmerscarry".
    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The key itself, then singular retries — "squats" → "squat", "legpresses" → "legpress".
    private static func variants(of key: String) -> [String] {
        var out = [key]
        if key.hasSuffix("es"), key.count > 4 { out.append(String(key.dropLast(2))) }
        if key.hasSuffix("s"), key.count > 3 { out.append(String(key.dropLast())) }
        return out
    }

    /// Unambiguous shorthand only — every value is a curated catalog name (pinned by test).
    /// Deliberately absent: "chin up" (different grip ≠ Pull-Up), "incline bench" (barbell ≠
    /// our dumbbell incline), "barbell curl" / "hammer curl" (distinct movements) — those
    /// stay custom rather than silently becoming a lift the athlete didn't do.
    static let aliases: [String: String] = [
        "bench": "Barbell Bench Press", "benchpress": "Barbell Bench Press",
        "flatbench": "Barbell Bench Press",
        "squat": "Barbell Back Squat", "backsquat": "Barbell Back Squat",
        "deadlift": "Barbell Deadlift",
        "ohp": "Overhead Press", "militarypress": "Overhead Press", "strictpress": "Overhead Press",
        "shoulderpress": "Dumbbell Shoulder Press",
        "row": "Barbell Row", "bentoverrow": "Barbell Row",
        "cablerow": "Seated Cable Row", "seatedrow": "Seated Cable Row",
        "pulldown": "Lat Pulldown",
        "rdl": "Romanian Deadlift",
        "curl": "Dumbbell Curl", "bicepcurl": "Dumbbell Curl", "bicepscurl": "Dumbbell Curl",
        "pushdown": "Triceps Pushdown", "triceppushdown": "Triceps Pushdown",
        "cablepushdown": "Triceps Pushdown",
        "sideraise": "Lateral Raise", "sidelateralraise": "Lateral Raise",
        "hamstringcurl": "Leg Curl",
        "farmerswalk": "Farmer's Carry", "farmerwalk": "Farmer's Carry",
        "farmercarry": "Farmer's Carry",
    ]
}
