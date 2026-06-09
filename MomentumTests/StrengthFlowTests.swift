import Testing
import Foundation
import SwiftData
@testable import Momentum

/// End-to-end integration of the strength logging loop: ViewModel → engine actor → durable store.
/// Verifies the slice works without UI automation. Serialized (shares the recovery marker).
@Suite(.serialized)
@MainActor
struct StrengthFlowTests {

    func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    @Test func fullLoggingLoopPersists() async throws {
        ActiveWorkoutMarker.clear()
        let container = try makeContainer()
        let squat = Exercise(name: "Squat", primaryMuscles: [.quads], equipment: .barbell, category: .compound)
        container.mainContext.insert(squat)
        try container.mainContext.save()

        let vm = StrengthViewModel(container: container, weightUnit: .kg)
        await vm.start()
        #expect(vm.workoutId != nil)

        await vm.addExercise(squat)
        #expect(vm.exercises.count == 1)
        let row = try #require(vm.exercises.first)
        #expect(row.sets.count == 1) // first set auto-added

        // Log two sets.
        let firstSet = try #require(row.sets.first)
        vm.drafts[firstSet.id] = .init(weight: "100", reps: "5", rpe: "8")
        await vm.completeSet(rowId: row.id, setId: firstSet.id)
        #expect(vm.restEndsAt != nil)          // rest timer started

        await vm.addSet(rowId: row.id)
        let secondSet = try #require(vm.exercises.first?.sets.last)
        vm.drafts[secondSet.id] = .init(weight: "100", reps: "5", rpe: "9")
        await vm.completeSet(rowId: row.id, setId: secondSet.id)

        #expect(vm.completedSetCount == 2)
        #expect(vm.liveVolumeKg == 1000)       // 100×5 + 100×5

        let id = await vm.finish()
        #expect(id != nil)

        let all = try container.mainContext.fetch(FetchDescriptor<Workout>())
        let workout = all.first { $0.id == id }
        #expect(workout?.strength?.totalVolumeKg == 1000)
        #expect(workout?.strength?.totalSets == 2)
        #expect(workout?.strength?.exercises.first?.exercise?.name == "Squat")
        #expect(ActiveWorkoutMarker.pendingID == nil)  // finished → marker cleared
        ActiveWorkoutMarker.clear()
    }

    @Test func prefillFromPreviousSession() async throws {
        ActiveWorkoutMarker.clear()
        let container = try makeContainer()
        let bench = Exercise(name: "Bench", primaryMuscles: [.chest], equipment: .barbell, category: .compound)
        container.mainContext.insert(bench)
        try container.mainContext.save()

        // Session 1: log one set at 80×8.
        let vm1 = StrengthViewModel(container: container, weightUnit: .kg)
        await vm1.start()
        await vm1.addExercise(bench)
        let s1 = try #require(vm1.exercises.first?.sets.first)
        vm1.drafts[s1.id] = .init(weight: "80", reps: "8", rpe: "8")
        await vm1.completeSet(rowId: vm1.exercises[0].id, setId: s1.id)
        _ = await vm1.finish()

        // Session 2: adding the same exercise should ghost + prefill from last session.
        let vm2 = StrengthViewModel(container: container, weightUnit: .kg)
        await vm2.start()
        await vm2.addExercise(bench)
        let row = try #require(vm2.exercises.first)
        #expect(vm2.ghost(rowId: row.id, setIndex: 0) == "80 × 8")
        let draft = try #require(vm2.drafts[row.sets[0].id])
        #expect(draft.weight == "80")
        #expect(draft.reps == "8")
        _ = await vm2.finish()
        ActiveWorkoutMarker.clear()
    }
}
