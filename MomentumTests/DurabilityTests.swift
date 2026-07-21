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
        await store.finishWorkout(distanceM: 500, durationS: 120, elevationGainM: 10)

        // Finished → marker cleared, nothing pending, aggregates final.
        #expect(ActiveWorkoutMarker.pendingID == nil)
        #expect(WorkoutRecovery.pendingWorkout(in: container.mainContext) == nil)
        let all = try container.mainContext.fetch(FetchDescriptor<Workout>())
        let finished = all.first { $0.id == id }
        #expect(finished?.gps?.distanceM == 500)
        #expect(finished?.durationS == 120)
        // 500 m in 120 s ⇒ 240 s/km. This call used to hand in a `smoothedPaceSPerKm: 300` that
        // disagreed with its own distance and duration, and nothing asserted on it — which is
        // precisely how the store came to persist the live EMA unnoticed.
        #expect(finished?.gps?.avgPaceSPerKm == 240.0)
        ActiveWorkoutMarker.clear()
    }

    @Test func heartRateReadingsPersistDurablyAndAverageAttaches() async throws {
        ActiveWorkoutMarker.clear()
        let container = try makeContainer()
        let store = GPSWorkoutStore(modelContainer: container)
        let start = Date(timeIntervalSinceReferenceDate: 0)

        await store.beginWorkout(type: .run, startedAt: start)
        for (i, bpm) in [120, 140, 160].enumerated() {
            await store.persistHeartRate(t: start.addingTimeInterval(Double(i) * 5), bpm: bpm)
        }
        await store.persistHeartRate(t: start, bpm: 0)   // a zero reading is dropped, not stored

        // Durable mid-capture, exactly like GPS samples: visible from a fresh read.
        let pending = try #require(WorkoutRecovery.pendingWorkout(in: container.mainContext))
        #expect(pending.gps?.hrSamples.count == 3)
        #expect(pending.gps?.hrSamples.map(\.bpm).sorted() == [120, 140, 160])

        await store.attachHR(140)
        await store.finishWorkout(distanceM: 1000, durationS: 300, elevationGainM: 0)
        let all = try container.mainContext.fetch(FetchDescriptor<Workout>())
        #expect(all.first { $0.id == pending.id }?.gps?.avgHR == 140)
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
        await store.beginWorkout(type: .strength, startedAt: start)
        let rowId = UUID()
        await store.persistExercise(rowId: rowId, catalogExerciseId: exId, order: 0, supersetGroup: nil)
        await store.persistSetComplete(rowId: rowId, setId: UUID(), setIndex: 0, weightKg: 60, reps: 8, rpe: 8, type: .working)
        await store.persistSetComplete(rowId: rowId, setId: UUID(), setIndex: 1, weightKg: 60, reps: 8, rpe: 8.5, type: .working)

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

    /// The headline regression: the finish path stores total ÷ total, not the live EMA. Read back
    /// through a SEPARATE context so this proves persistence, not an in-memory value.
    @Test func finishStoresTheTrueAverageNotTheLiveEMA() async throws {
        ActiveWorkoutMarker.clear()
        let container = try makeContainer()
        let store = GPSWorkoutStore(modelContainer: container)
        await store.beginWorkout(type: .run, startedAt: Date(timeIntervalSinceReferenceDate: 0))
        // 10.1 km in 51:00 — the "walked the last minute" shape.
        await store.finishWorkout(distanceM: 10_100, durationS: 3060, elevationGainM: 0)

        let fresh = ModelContext(container)
        let w = try #require(try fresh.fetch(FetchDescriptor<Workout>()).first)
        let pace = try #require(w.gps?.avgPaceSPerKm)
        #expect(abs(pace - 302.970297) < 1e-4)
        ActiveWorkoutMarker.clear()
    }

    /// Walk and hike fall into the same branch as running and were storing the EMA too.
    @Test func walksAndHikesTakeThePaceBranch() async throws {
        for type in [WorkoutType.walk, .hike] {
            ActiveWorkoutMarker.clear()
            let container = try makeContainer()
            let store = GPSWorkoutStore(modelContainer: container)
            await store.beginWorkout(type: type, startedAt: Date(timeIntervalSinceReferenceDate: 0))
            await store.finishWorkout(distanceM: 3000, durationS: 2400, elevationGainM: 0)
            let all = try container.mainContext.fetch(FetchDescriptor<Workout>())
            #expect(all.first?.gps?.avgPaceSPerKm == 800.0, "\(type) should store 800 s/km")
        }
        ActiveWorkoutMarker.clear()
    }

    @Test func cyclingStoresSpeedAndLeavesPaceZero() async throws {
        ActiveWorkoutMarker.clear()
        let container = try makeContainer()
        let store = GPSWorkoutStore(modelContainer: container)
        await store.beginWorkout(type: .ride, startedAt: Date(timeIntervalSinceReferenceDate: 0))
        await store.finishWorkout(distanceM: 20_000, durationS: 2400, elevationGainM: 0)
        let all = try container.mainContext.fetch(FetchDescriptor<Workout>())
        let gps = try #require(all.first?.gps)
        #expect(abs(gps.avgSpeedMS - 8.3333333) < 1e-6)
        #expect(gps.avgPaceSPerKm == 0)
        ActiveWorkoutMarker.clear()
    }

    /// A never-locked run must not persist infinity into a field that is synced and exported.
    @Test func zeroDistanceFinishStoresZeroNotInfinity() async throws {
        ActiveWorkoutMarker.clear()
        let container = try makeContainer()
        let store = GPSWorkoutStore(modelContainer: container)
        await store.beginWorkout(type: .run, startedAt: Date(timeIntervalSinceReferenceDate: 0))
        await store.finishWorkout(distanceM: 0, durationS: 600, elevationGainM: 0)
        let all = try container.mainContext.fetch(FetchDescriptor<Workout>())
        let pace = try #require(all.first?.gps?.avgPaceSPerKm)
        #expect(pace == 0 && pace.isFinite)
        ActiveWorkoutMarker.clear()
    }
}
