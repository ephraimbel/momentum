import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Durability + recovery (PRD §8.3/§8.4, §13.11). Writes through the real `@ModelActor` stores
/// into an in-memory container, then reads back via a *separate* context — the closest proxy to
/// force-quit recovery without a device: it proves captures are persisted eagerly, not held in
/// engine memory. Serialized because the recovery marker uses shared `UserDefaults`.
@Suite(.serialized)
@MainActor
struct DurabilityTests {

    func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }

    @Test func gpsCapturePersistsAndRecovers() async throws {
        ActiveWorkoutMarker.clear()
        let container = try makeContainer()
        let store = GPSWorkoutStore(modelContainer: container)
        let start = Date(timeIntervalSinceReferenceDate: 0)

        await store.beginWorkout(type: .run, startedAt: start)
        for i in 0..<10 {
            await store.persistSample(
                .init(t: start.addingTimeInterval(Double(i)), lat: 37, lon: -122,
                      accuracyM: 5, speedMS: 2.5, altitudeM: 0),
                accepted: true)
        }
        await store.checkpoint(distanceM: 500, durationS: 120, elevationGainM: 10)

        // Simulate relaunch mid-capture: marker is set and data is durable in a fresh read.
        #expect(ActiveWorkoutMarker.pendingID != nil)
        let pending = WorkoutRecovery.pendingWorkout(in: container.mainContext)
        #expect(pending != nil)
        #expect(pending?.type == .run)
        #expect(pending?.gps?.samples.count == 10)

        let id = try #require(pending?.id)
        await store.finishWorkout(distanceM: 500, durationS: 120,
                                  elevationGainM: 10, smoothedPaceSPerKm: 300)

        // Finished → marker cleared, nothing pending, aggregates final.
        #expect(ActiveWorkoutMarker.pendingID == nil)
        #expect(WorkoutRecovery.pendingWorkout(in: container.mainContext) == nil)
        let all = try container.mainContext.fetch(FetchDescriptor<Workout>())
        let finished = all.first { $0.id == id }
        #expect(finished?.gps?.distanceM == 500)
        #expect(finished?.durationS == 120)
        ActiveWorkoutMarker.clear()
    }

    @Test func strengthCapturePersistsSetsAndRecovers() async throws {
        ActiveWorkoutMarker.clear()
        let container = try makeContainer()
        let ex = Exercise(name: "Bench", primaryMuscles: [.chest], equipment: .barbell, category: .compound)
        container.mainContext.insert(ex)
        try container.mainContext.save()
        let exId = ex.id

        let store = StrengthWorkoutStore(modelContainer: container)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        await store.beginWorkout(startedAt: start)
        let rowId = UUID()
        await store.persistExercise(rowId: rowId, catalogExerciseId: exId, order: 0, supersetGroup: nil)
        await store.persistSetComplete(rowId: rowId, setIndex: 0, weightKg: 60, reps: 8, rpe: 8, type: .working)
        await store.persistSetComplete(rowId: rowId, setIndex: 1, weightKg: 60, reps: 8, rpe: 8.5, type: .working)

        let pending = WorkoutRecovery.pendingWorkout(in: container.mainContext)
        #expect(pending?.strength?.exercises.count == 1)
        #expect(pending?.strength?.exercises.first?.sets.count == 2)
        #expect(pending?.strength?.exercises.first?.exercise?.name == "Bench")

        await store.finishWorkout(totalVolumeKg: 960, totalSets: 2, durationS: 600)
        #expect(ActiveWorkoutMarker.pendingID == nil)

        let all = try container.mainContext.fetch(FetchDescriptor<Workout>())
        #expect(all.first?.strength?.totalVolumeKg == 960)
        ActiveWorkoutMarker.clear()
    }
}
