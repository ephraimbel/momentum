import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Cold-launch recovery: the marker + persisted data must come back as a finishable workout, an
/// empty husk must sweep silently, and finalize must derive durations from evidence, not the clock.
/// Serialized: the ActiveWorkoutMarker lives in UserDefaults, which parallel tests would race.
@Suite(.serialized)
@MainActor
struct WorkoutRecoveryTests {

    func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func seedInterruptedStrength(_ ctx: ModelContext, startedAt: Date) throws -> Workout {
        let w = Workout()
        w.type = .strength
        w.startedAt = startedAt
        let session = StrengthSession()
        w.strength = session
        let row = WorkoutExercise()
        let ex = Exercise(); ex.name = "Back Squat"
        ctx.insert(ex)
        row.exercise = ex
        session.exercises.append(row)
        for i in 0..<3 {
            let set = SetEntry()
            set.index = i
            set.weightKg = 100
            set.reps = 5
            set.type = .working
            set.isComplete = true
            set.completedAt = startedAt.addingTimeInterval(Double(i + 1) * 180)
            row.sets.append(set)
        }
        ctx.insert(w)
        try ctx.save()
        ActiveWorkoutMarker.set(w.id)
        return w
    }

    @Test func interruptedStrengthSessionIsOfferedAndFinalized() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let start = Date(timeIntervalSinceNow: -3_600)
        let w = try seedInterruptedStrength(ctx, startedAt: start)

        // Launch check surfaces it (real sets were logged).
        let pending = WorkoutRecovery.checkOnLaunch(in: ctx)
        #expect(pending?.id == w.id)

        // Finalize reconstructs the aggregates finishWorkout never wrote.
        WorkoutRecovery.finalizePending(in: ctx)
        #expect(w.strength?.totalSets == 3)
        #expect(w.strength?.totalVolumeKg == 1_500)          // 3 × 100 kg × 5
        #expect(abs(w.durationS - 540) < 1)                  // last set at +9 min, not "now"
        #expect(ActiveWorkoutMarker.pendingID == nil)
    }

    @Test func emptyHuskIsSweptSilently() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let w = Workout()
        w.type = .run
        w.gps = GPSDetail()                                   // armed, but zero samples
        ctx.insert(w)
        try ctx.save()
        ActiveWorkoutMarker.set(w.id)

        #expect(WorkoutRecovery.checkOnLaunch(in: ctx) == nil)
        #expect(ActiveWorkoutMarker.pendingID == nil)
        let remaining = (try? ctx.fetch(FetchDescriptor<Workout>())) ?? []
        #expect(remaining.isEmpty)                            // the husk is gone, not a 0:00 ghost
    }

    @Test func staleMarkerWithoutWorkoutClears() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        ActiveWorkoutMarker.set(UUID())                       // marker outlived its workout
        #expect(WorkoutRecovery.checkOnLaunch(in: ctx) == nil)
        #expect(ActiveWorkoutMarker.pendingID == nil)
    }

    @Test func discardPendingDeletesAndClears() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        _ = try seedInterruptedStrength(ctx, startedAt: Date(timeIntervalSinceNow: -600))
        WorkoutRecovery.discardPending(in: ctx)
        #expect(ActiveWorkoutMarker.pendingID == nil)
        let remaining = (try? ctx.fetch(FetchDescriptor<Workout>())) ?? []
        #expect(remaining.isEmpty)
    }
}
