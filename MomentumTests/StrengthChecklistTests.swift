import Testing
import Foundation
import SwiftData
@testable import Momentum

/// The planned-lift checklist (2026-07-23): a planned session preloads as one-tap targets, the
/// first typed weight flows forward through the exercise, untouched prefill never auto-logs,
/// and finishing an exercise raises the auto-advance signal. These pins are the contract the
/// "go down the list and check it off" flow makes.
@MainActor
struct StrengthChecklistTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    /// A planned session: bench (barbell, 4×8–12 RPE 8) then pushups (reps-only, 3×10).
    private func plannedSession(in ctx: ModelContext) -> (PlannedSession, bench: Exercise, pushups: Exercise) {
        let bench = Exercise(name: "Bench Press", primaryMuscles: [.chest],
                             equipment: .barbell, category: .compound)
        let pushups = Exercise(name: "Pushups", primaryMuscles: [.chest],
                               equipment: .bodyweight, category: .compound, trackingMode: .repsOnly)
        ctx.insert(bench)
        ctx.insert(pushups)
        let session = PlannedSession()
        session.discipline = .strength
        let pe1 = PlannedExercise()
        pe1.order = 0; pe1.exercise = bench
        pe1.targetSets = 3; pe1.targetRepLow = 8; pe1.targetRepHigh = 12
        pe1.progression = "double"; pe1.targetRPE = 8
        let pe2 = PlannedExercise()
        pe2.order = 1; pe2.exercise = pushups
        pe2.targetSets = 2; pe2.targetRepLow = 10; pe2.targetRepHigh = 10
        session.strengthTargets = [pe1, pe2]
        ctx.insert(session)
        try? ctx.save()
        return (session, bench, pushups)
    }

    @Test func plannedSessionPreloadsAsChecklist() async throws {
        let container = try makeContainer()
        let (session, _, _) = plannedSession(in: container.mainContext)
        let vm = StrengthViewModel(container: container, weightUnit: .lb)
        await vm.start()
        await vm.loadPlanned(session)

        #expect(vm.exercises.count == 2)
        #expect(vm.exercises[0].sets.count == 3)   // prescribed set count, pre-created
        #expect(vm.exercises[1].sets.count == 2)
        // Every set arrives with its target reps — the row reads as a checklist, not a form.
        for set in vm.exercises[0].sets {
            #expect(vm.drafts[set.id]?.reps == "8")
        }
        // The header line speaks the plan's ask.
        #expect(vm.prescriptionLine(rowId: vm.exercises[0].id) == "3 sets · 8–12 reps · RPE 8")
        #expect(vm.prescriptionLine(rowId: vm.exercises[1].id) == "2 sets · 10 reps")
        // Weighted vs reps-only drives the needs-weight gate.
        #expect(vm.weightExpected(rowId: vm.exercises[0].id))
        #expect(!vm.weightExpected(rowId: vm.exercises[1].id))
    }

    @Test func firstLoggedWeightFlowsForward() async throws {
        let container = try makeContainer()
        let (session, _, _) = plannedSession(in: container.mainContext)
        let vm = StrengthViewModel(container: container, weightUnit: .lb)
        await vm.start()
        await vm.loadPlanned(session)

        let bench = vm.exercises[0]
        // Fresh athlete: no history, so weights start empty (the parser never invents one).
        for set in bench.sets { #expect((vm.drafts[set.id]?.weight ?? "").isEmpty) }

        // Type the weight ONCE on set 1 and check it off…
        vm.drafts[bench.sets[0].id]?.weight = "135"
        await vm.completeSet(rowId: bench.id, setId: bench.sets[0].id)

        // …and the rest of the exercise becomes pure check-off.
        for set in vm.exercises[0].sets.dropFirst() {
            #expect(vm.drafts[set.id]?.weight == "135")
        }
    }

    @Test func untouchedPrefillNeverAutoLogs() async throws {
        let container = try makeContainer()
        let (session, _, _) = plannedSession(in: container.mainContext)
        let vm = StrengthViewModel(container: container, weightUnit: .lb)
        await vm.start()
        await vm.loadPlanned(session)

        // All 5 sets sit prefilled with target reps — but none were touched, so Finish has
        // nothing to offer to bulk-log (an unchecked target is work NOT done).
        #expect(vm.pendingEditedSets.isEmpty)

        // The athlete types into one set but never checks it — that one IS worth asking about.
        let benchSet = vm.exercises[0].sets[1]
        vm.drafts[benchSet.id]?.weight = "135"
        vm.markEdited(benchSet.id)
        #expect(vm.pendingEditedSets.count == 1)
        #expect(vm.pendingEditedSets.first?.setId == benchSet.id)
    }

    @Test func warmupSetsSlotAboveAndStayOutOfVolume() async throws {
        let container = try makeContainer()
        let (session, _, _) = plannedSession(in: container.mainContext)
        let vm = StrengthViewModel(container: container, weightUnit: .lb)
        await vm.start()
        await vm.loadPlanned(session)

        let bench = vm.exercises[0]
        await vm.addWarmupSet(rowId: bench.id)
        await vm.addWarmupSet(rowId: bench.id)

        let sets = vm.exercises[0].sets
        #expect(sets.count == 5)                       // 2 warm-ups + 3 prescribed working
        #expect(sets[0].type == .warmup)               // prep work sits at the top…
        #expect(sets[1].type == .warmup)
        #expect(sets[2].type == .working)              // …working sets follow, reindexed
        #expect(sets.map(\.index) == [0, 1, 2, 3, 4])

        // A checked warm-up never counts toward working volume.
        vm.drafts[sets[0].id] = .init(weight: "95", reps: "5", rpe: "")
        await vm.completeSet(rowId: bench.id, setId: sets[0].id)
        #expect(vm.liveVolumeKg == 0)
    }

    @Test func warmupWeightNeverBecomesTheWorkingPrescription() async throws {
        let container = try makeContainer()
        let (session, _, _) = plannedSession(in: container.mainContext)
        let vm = StrengthViewModel(container: container, weightUnit: .lb)
        await vm.start()
        await vm.loadPlanned(session)

        let bench = vm.exercises[0]
        await vm.addWarmupSet(rowId: bench.id)
        let warmup = vm.exercises[0].sets[0]

        // Logging the 95 lb warm-up must not flow into the empty working sets…
        vm.drafts[warmup.id] = .init(weight: "95", reps: "5", rpe: "")
        await vm.completeSet(rowId: bench.id, setId: warmup.id)
        for set in vm.exercises[0].sets where set.type == .working {
            #expect((vm.drafts[set.id]?.weight ?? "").isEmpty)
        }

        // …while the first WORKING weight still flows through the working sets only.
        let firstWorking = vm.exercises[0].sets.first(where: { $0.type == .working })!
        vm.drafts[firstWorking.id]?.weight = "135"
        await vm.completeSet(rowId: bench.id, setId: firstWorking.id)
        for set in vm.exercises[0].sets where set.type == .working && set.id != firstWorking.id {
            #expect(vm.drafts[set.id]?.weight == "135")
        }
        #expect(vm.drafts[warmup.id]?.weight == "95")   // the warm-up keeps its own number
    }

    // MARK: Supersets

    @Test func pairingGroupsAndMovesThePartnerAdjacent() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (session, _, _) = plannedSession(in: ctx)
        let curls = Exercise(name: "Curls", primaryMuscles: [.biceps],
                             equipment: .dumbbell, category: .isolation)
        ctx.insert(curls)
        let vm = StrengthViewModel(container: container, weightUnit: .lb)
        await vm.start()
        await vm.loadPlanned(session)   // bench, pushups

        // Pair BENCH (first) with curls — curls must land right after bench, both grouped.
        await vm.pairSuperset(anchor: vm.exercises[0].id, with: curls)
        #expect(vm.exercises.map(\.name) == ["Bench Press", "Curls", "Pushups"])
        #expect(vm.exercises[0].supersetGroup != nil)
        #expect(vm.exercises[0].supersetGroup == vm.exercises[1].supersetGroup)
        #expect(vm.exercises[2].supersetGroup == nil)

        // Unlink restores standalone exercises (order untouched — no surprise moves).
        await vm.unlinkSuperset(rowId: vm.exercises[0].id)
        #expect(vm.exercises.allSatisfy { $0.supersetGroup == nil })
        #expect(vm.exercises.map(\.name) == ["Bench Press", "Curls", "Pushups"])
    }

    @Test func supersetRestComesAfterTheRoundNotEachSet() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (session, _, _) = plannedSession(in: ctx)
        let rows = Exercise(name: "Barbell Row", primaryMuscles: [.back],
                            equipment: .barbell, category: .compound)
        ctx.insert(rows)
        let vm = StrengthViewModel(container: container, weightUnit: .lb)
        await vm.start()
        await vm.loadPlanned(session)
        await vm.pairSuperset(anchor: vm.exercises[0].id, with: rows)
        // The partner arrives with one set — bring it to two so rounds line up (bench has 3).
        await vm.addSet(rowId: vm.exercises[1].id)

        let bench = vm.exercises[0], row = vm.exercises[1]
        vm.drafts[bench.sets[0].id] = .init(weight: "135", reps: "8", rpe: "")
        vm.drafts[row.sets[0].id] = .init(weight: "95", reps: "8", rpe: "")

        // A1: bench set 1 — mid-round, the next move is the row set. NO rest.
        await vm.completeSet(rowId: bench.id, setId: bench.sets[0].id)
        #expect(vm.restEndsAt == nil)
        // A2: row set 1 — the round is done. Rest fires.
        await vm.completeSet(rowId: row.id, setId: row.sets[0].id)
        #expect(vm.restEndsAt != nil)

        // Starting round 2 mid-rest stands the ring down (the athlete chose to move).
        await vm.completeSet(rowId: bench.id, setId: vm.exercises[0].sets[1].id)
        #expect(vm.restEndsAt == nil)

        // Bench set 3 has no round partner (row only has 2 sets) — the unpaired extra set
        // rests normally, and bench finishing alone raises NO advance signal.
        await vm.completeSet(rowId: bench.id, setId: vm.exercises[0].sets[2].id)
        #expect(vm.restEndsAt != nil)
        #expect(vm.lastCompletedRowId == nil)   // bench done, row still open

        // Row set 2 lands — now the PAIR is done. Advance fires.
        await vm.completeSet(rowId: row.id, setId: vm.exercises[1].sets[1].id)
        #expect(vm.lastCompletedRowId == row.id)
    }

    @Test func supersetSuggestionsAreAntagonistsNotInSession() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (session, _, _) = plannedSession(in: ctx)   // bench (chest) + pushups (chest) in session
        // Catalog: a back exercise (bench's antagonist), a triceps one (NOT chest's antagonist),
        // and a second back option on different equipment.
        let rows = Exercise(name: "Barbell Row", primaryMuscles: [.back],
                            equipment: .barbell, category: .compound)
        let pulldown = Exercise(name: "Lat Pulldown", primaryMuscles: [.back],
                                equipment: .cable, category: .compound)
        let pushdown = Exercise(name: "Pushdown", primaryMuscles: [.triceps],
                                equipment: .cable, category: .isolation)
        ctx.insert(rows); ctx.insert(pulldown); ctx.insert(pushdown)
        try? ctx.save()

        let vm = StrengthViewModel(container: container, weightUnit: .lb)
        await vm.start()
        await vm.loadPlanned(session)

        let bench = vm.exercises[0]
        let names = vm.supersetSuggestions(for: bench.id).map(\.name)
        #expect(names.contains("Barbell Row"))          // chest → back, the classic pair
        #expect(names.contains("Lat Pulldown"))
        #expect(!names.contains("Pushdown"))            // triceps isn't chest's antagonist
        #expect(!names.contains("Pushups"))             // already in the session
        // Same equipment as the anchor (barbell bench → barbell row) ranks first.
        #expect(names.first == "Barbell Row")

        // The one-tap link list is the OTHER standalone session exercises.
        #expect(vm.supersetLinkCandidates(for: bench.id).map(\.name) == ["Pushups"])
    }

    @Test func suggestionsNeverShareAMuscleWithTheAnchor() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        // Anchor: a squat hitting quads AND glutes.
        let squat = Exercise(name: "Barbell Back Squat", primaryMuscles: [.quads, .glutes],
                             equipment: .barbell, category: .compound)
        // Leg curl (hamstrings only) is the classic partner; a near-duplicate squat and a
        // deadlift that SHARES the glutes must both be excluded — "opposite" means opposite.
        let legCurl = Exercise(name: "Leg Curl", primaryMuscles: [.hamstrings],
                               equipment: .machine, category: .isolation)
        let frontSquat = Exercise(name: "Front Squat", primaryMuscles: [.quads],
                                  equipment: .barbell, category: .compound)
        let deadlift = Exercise(name: "Barbell Deadlift", primaryMuscles: [.hamstrings, .glutes],
                                equipment: .barbell, category: .compound)
        for e in [squat, legCurl, frontSquat, deadlift] { ctx.insert(e) }
        try? ctx.save()

        let vm = StrengthViewModel(container: container, weightUnit: .lb)
        await vm.start()
        await vm.addExercise(squat)
        let names = vm.supersetSuggestions(for: vm.exercises[0].id).map(\.name)
        #expect(names == ["Leg Curl"])
    }

    @Test func supersetRoundRestsForTheLongerPrescription() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        // Bench asks 150s between sets; curls only 75s. Finishing the round on the CURL must
        // still buy the bench its full recovery — the round rests for the longer prescription.
        let bench = Exercise(name: "Bench Press", primaryMuscles: [.chest],
                             equipment: .barbell, category: .compound, defaultRestS: 150)
        let curls = Exercise(name: "Curls", primaryMuscles: [.biceps],
                             equipment: .dumbbell, category: .isolation, defaultRestS: 75)
        ctx.insert(bench); ctx.insert(curls)
        try? ctx.save()

        let vm = StrengthViewModel(container: container, weightUnit: .lb)
        await vm.start()
        await vm.addExercise(bench)
        await vm.pairSuperset(anchor: vm.exercises[0].id, with: curls)

        let b = vm.exercises[0], c = vm.exercises[1]
        vm.drafts[b.sets[0].id] = .init(weight: "135", reps: "8", rpe: "")
        vm.drafts[c.sets[0].id] = .init(weight: "25", reps: "12", rpe: "")

        // Mid-round: no rest, and the partner's open set is surfaced for the view to scroll to.
        await vm.completeSet(rowId: b.id, setId: b.sets[0].id)
        #expect(vm.restEndsAt == nil)
        #expect(vm.roundNextSetId == c.sets[0].id)
        // Round closes on the 75s curl — the ring still runs the bench's 150s.
        await vm.completeSet(rowId: c.id, setId: c.sets[0].id)
        #expect(vm.roundNextSetId == nil)
        #expect(vm.restTotal == 150)
    }

    @Test func suggestionsRespectTheAthletesEquipment() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        // A bodyweight-only athlete must never be pitched a barbell partner.
        let profile = UserProfile()
        profile.equipment = .bodyweight
        ctx.insert(profile)
        let pushups = Exercise(name: "Pushups", primaryMuscles: [.chest],
                               equipment: .bodyweight, category: .compound, trackingMode: .repsOnly)
        let rows = Exercise(name: "Barbell Row", primaryMuscles: [.back],
                            equipment: .barbell, category: .compound)
        let invertedRow = Exercise(name: "Inverted Row", primaryMuscles: [.back],
                                   equipment: .bodyweight, category: .compound, trackingMode: .repsOnly)
        for e in [pushups, rows, invertedRow] { ctx.insert(e) }
        try? ctx.save()

        let vm = StrengthViewModel(container: container, weightUnit: .lb)
        await vm.start()
        await vm.addExercise(pushups)
        let names = vm.supersetSuggestions(for: vm.exercises[0].id).map(\.name)
        #expect(names == ["Inverted Row"])   // the barbell row never appears
    }

    @Test func unlinkedExercisesRestNormallyAgain() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (session, _, _) = plannedSession(in: ctx)
        let rows = Exercise(name: "Barbell Row", primaryMuscles: [.back],
                            equipment: .barbell, category: .compound)
        ctx.insert(rows)
        let vm = StrengthViewModel(container: container, weightUnit: .lb)
        await vm.start()
        await vm.loadPlanned(session)
        await vm.pairSuperset(anchor: vm.exercises[0].id, with: rows)
        await vm.unlinkSuperset(rowId: vm.exercises[0].id)

        let bench = vm.exercises[0]
        vm.drafts[bench.sets[0].id] = .init(weight: "135", reps: "8", rpe: "")
        await vm.completeSet(rowId: bench.id, setId: bench.sets[0].id)
        #expect(vm.restEndsAt != nil)   // standalone again: per-set rest is back
    }

    @Test func finishingAnExerciseRaisesTheAdvanceSignal() async throws {
        let container = try makeContainer()
        let (session, _, _) = plannedSession(in: container.mainContext)
        let vm = StrengthViewModel(container: container, weightUnit: .lb)
        await vm.start()
        await vm.loadPlanned(session)

        let bench = vm.exercises[0]
        vm.drafts[bench.sets[0].id]?.weight = "135"
        for set in bench.sets {
            #expect(vm.lastCompletedRowId == nil)   // no signal until the LAST set lands
            await vm.completeSet(rowId: bench.id, setId: set.id)
        }
        #expect(vm.isRowComplete(bench.id))
        #expect(vm.lastCompletedRowId == bench.id)          // the auto-advance beat
        #expect(vm.firstIncompleteRowId == vm.exercises[1].id)   // …and where it scrolls to

        // Un-logging re-opens the exercise and withdraws the signal.
        await vm.uncompleteSet(rowId: bench.id, setId: bench.sets[0].id)
        #expect(!vm.isRowComplete(bench.id))
        #expect(vm.lastCompletedRowId == nil)
    }
}

/// The shared exercise library must list each movement exactly ONCE — a user found "Barbell
/// Bench Press" twice and both "Back Squat" and "Barbell Back Squat" (the early DemoSeed
/// inserted its own copies of four lifts). These pin the self-heal in ExerciseLibrarySeed:
/// duplicates merge into the curated row with history/PRs/plan targets re-pointed, legacy
/// names take their canonical form, and custom exercises are never touched.
@MainActor
struct ExerciseLibrarySeedTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    @Test func duplicateLibraryRowsMergeIntoTheCuratedOne() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let curated = Exercise(name: "Barbell Bench Press", primaryMuscles: [.chest],
                               equipment: .barbell, category: .compound, defaultRestS: 150,
                               instructions: "Retract shoulder blades, bar to mid-chest, drive up.")
        let dupe = Exercise(name: "Barbell Bench Press", primaryMuscles: [.chest],
                            equipment: .barbell, category: .compound)
        ctx.insert(curated); ctx.insert(dupe)
        // History, a PR, and a plan target all hang off the DUPLICATE row.
        let row = WorkoutExercise(); row.exercise = dupe; ctx.insert(row)
        let pr = PersonalRecord(type: .bestE1RM, value: 100, exercise: dupe); ctx.insert(pr)
        let target = PlannedExercise(); target.exercise = dupe; ctx.insert(target)
        try ctx.save()

        ExerciseLibrarySeed.seedIfNeeded(into: ctx)

        let remaining = try ctx.fetch(FetchDescriptor<Exercise>())
            .filter { $0.name == "Barbell Bench Press" }
        #expect(remaining.count == 1)
        #expect(remaining.first?.instructions.isEmpty == false)   // the curated row survived
        #expect(row.exercise?.id == remaining.first?.id)
        #expect(pr.exercise?.id == remaining.first?.id)
        #expect(target.exercise?.id == remaining.first?.id)
    }

    @Test func legacyBackSquatMergesUnderItsCanonicalName() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let curated = Exercise(name: "Barbell Back Squat", primaryMuscles: [.quads],
                               equipment: .barbell, category: .compound, defaultRestS: 150,
                               instructions: "Brace, sit between your hips, drive through mid-foot.")
        let legacy = Exercise(name: "Back Squat", primaryMuscles: [.quads, .glutes],
                              equipment: .barbell, category: .compound)
        ctx.insert(curated); ctx.insert(legacy)
        let row = WorkoutExercise(); row.exercise = legacy; ctx.insert(row)
        try ctx.save()

        ExerciseLibrarySeed.seedIfNeeded(into: ctx)

        let names = try ctx.fetch(FetchDescriptor<Exercise>()).map(\.name)
        #expect(!names.contains("Back Squat"))
        #expect(names.filter { $0 == "Barbell Back Squat" }.count == 1)
        #expect(row.exercise?.id == curated.id)   // squat history rides along
    }

    @Test func aLoneLegacyNameIsRenamedInPlace() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let legacy = Exercise(name: "Back Squat", primaryMuscles: [.quads, .glutes],
                              equipment: .barbell, category: .compound)
        ctx.insert(legacy)
        try ctx.save()

        ExerciseLibrarySeed.seedIfNeeded(into: ctx)
        #expect(legacy.name == "Barbell Back Squat")
    }

    @Test func curatedCatalogListsEveryMovementOnce() {
        // Guards the catalog as it grows toward the full Phase-1 library: two rows that
        // normalize to the same key ("Pull-Up"/"Pull Up") would double-list in search.
        let keys = ExerciseLibrarySeed.curated.map { ExerciseNameMatch.normalize($0.name) }
        #expect(Set(keys).count == keys.count)
    }

    @Test func everyAliasPointsAtARealCatalogRow() {
        // A rename in the curated list must not orphan its shorthand.
        let names = Set(ExerciseLibrarySeed.curated.map(\.name))
        for canonical in ExerciseNameMatch.aliases.values {
            #expect(names.contains(canonical), "alias target \(canonical) missing from catalog")
        }
    }

    @Test func spokenShorthandFindsTheLibraryRowNotANewCustom() {
        let lib = ExerciseLibrarySeed.curated
        let pins: [(spoken: String, canonical: String)] = [
            ("bench press", "Barbell Bench Press"),
            ("Squats", "Barbell Back Squat"),
            ("pull ups", "Pull-Up"),
            ("RDL", "Romanian Deadlift"),
            ("curls", "Dumbbell Curl"),
            ("lat pulldowns", "Lat Pulldown"),
            ("leg presses", "Leg Press"),
            ("rows", "Barbell Row"),
            ("OHP", "Overhead Press"),
            ("farmers walk", "Farmer's Carry"),
        ]
        for pin in pins {
            #expect(ExerciseNameMatch.find(pin.spoken, in: lib)?.name == pin.canonical,
                    "\(pin.spoken) should resolve to \(pin.canonical)")
        }
    }

    @Test func ambiguousMovementsStayCustom() {
        // A chin-up is not a pull-up and an incline barbell bench is not our dumbbell incline —
        // resolving those would log a lift the athlete didn't do. They stay custom.
        let lib = ExerciseLibrarySeed.curated
        for spoken in ["chin ups", "incline bench", "hammer curls"] {
            #expect(ExerciseNameMatch.find(spoken, in: lib) == nil, "\(spoken) must not resolve")
        }
    }

    @Test func anExactlyNamedCustomBeatsTheAliasTable() {
        // The athlete's own "RDL" row is theirs — shorthand lands on it, not the library row.
        var lib = ExerciseLibrarySeed.curated
        let custom = Exercise(name: "RDL", primaryMuscles: [.hamstrings],
                              equipment: .barbell, category: .compound, isCustom: true)
        lib.append(custom)
        #expect(ExerciseNameMatch.find("rdl", in: lib)?.id == custom.id)
    }

    @Test func customExercisesAreNeverMerged() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let shared = Exercise(name: "Barbell Bench Press", primaryMuscles: [.chest],
                              equipment: .barbell, category: .compound, defaultRestS: 150)
        // The athlete's own variant under the same name is THEIRS — never absorbed.
        let custom = Exercise(name: "Barbell Bench Press", primaryMuscles: [.chest],
                              equipment: .barbell, category: .compound, isCustom: true)
        ctx.insert(shared); ctx.insert(custom)
        try ctx.save()

        ExerciseLibrarySeed.seedIfNeeded(into: ctx)

        let remaining = try ctx.fetch(FetchDescriptor<Exercise>())
            .filter { $0.name == "Barbell Bench Press" }
        #expect(remaining.count == 2)
        #expect(remaining.contains { $0.isCustom })
    }
}
