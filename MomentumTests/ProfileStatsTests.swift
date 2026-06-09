import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Verifies profile aggregation (streak, totals, PR shelves) from a fixture history.
@MainActor
struct ProfileStatsTests {

    func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    @Test func aggregatesStreakTotalsAndPRs() throws {
        let container = try makeContainer()
        let ctx = container.mainContext

        // Strength workout: Bench 80×5 (e1RM 93.33), 30 min.
        let bench = Exercise(name: "Bench", primaryMuscles: [.chest], equipment: .barbell, category: .compound)
        ctx.insert(bench)
        let sw = Workout(); sw.type = .strength; sw.startedAt = Date(); sw.durationS = 1800
        let session = StrengthSession(); session.totalVolumeKg = 800; session.totalSets = 2
        let row = WorkoutExercise(); row.exercise = bench
        let set = SetEntry(); set.weightKg = 80; set.reps = 5; set.isComplete = true; set.type = .working
        row.sets = [set]; session.exercises = [row]; sw.strength = session
        ctx.insert(sw)

        // Run workout: 5 km, 25 min.
        let rw = Workout(); rw.type = .run; rw.startedAt = Date(); rw.durationS = 1500
        let gps = GPSDetail(); gps.distanceM = 5000; rw.gps = gps
        ctx.insert(rw)
        try ctx.save()

        let stats = ProfileStats(workouts: [sw, rw])
        #expect(stats.totalWorkouts == 2)
        #expect(stats.totalVolumeKg == 800)
        #expect(stats.totalDistanceM == 5000)
        #expect(stats.longestRunM == 5000)
        #expect(stats.currentStreak == 1)              // both qualify today
        #expect(stats.strengthPRs.first?.name == "Bench")
        #expect(abs((stats.strengthPRs.first?.e1RMKg ?? 0) - 93.333) < 0.01)
    }

    @Test func emptyHistoryIsCalm() {
        let stats = ProfileStats(workouts: [])
        #expect(stats.currentStreak == 0)
        #expect(stats.totalWorkouts == 0)
        #expect(stats.strengthPRs.isEmpty)
    }
}
