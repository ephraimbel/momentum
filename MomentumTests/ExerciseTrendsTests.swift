import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Per-lift e1RM progression series (PRD §4.8). One point per session (its top working set), sorted.
@MainActor
struct ExerciseTrendsTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    /// A strength workout `daysAgo`, logging `name` for the given working sets (weightKg, reps).
    private func session(_ ctx: ModelContext, name: String, daysAgo: Int, sets: [(Double, Int)]) -> Workout {
        let ex = Exercise(name: name, primaryMuscles: [.chest], equipment: .barbell, category: .compound)
        ctx.insert(ex)
        let w = Workout(); w.type = .strength
        w.startedAt = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        let row = WorkoutExercise(); row.exercise = ex
        row.sets = sets.map { kg, reps in
            let s = SetEntry(); s.weightKg = kg; s.reps = reps; s.isComplete = true; s.type = .working; return s
        }
        let strength = StrengthSession(); strength.exercises = [row]
        w.strength = strength
        ctx.insert(w)
        return w
    }

    @Test func buildsOnePointPerSessionOldestFirstWithTopSet() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        _ = session(ctx, name: "Bench", daysAgo: 14, sets: [(60, 5), (62, 5)])   // top: 62×5
        _ = session(ctx, name: "Bench", daysAgo: 0,  sets: [(70, 5)])            // 70×5
        _ = session(ctx, name: "Squat", daysAgo: 7,  sets: [(100, 5)])           // other lift — excluded
        try ctx.save()
        let workouts = (try ctx.fetch(FetchDescriptor<Workout>()))

        let series = ExerciseTrends.e1RMSeries(exerciseName: "Bench", in: workouts)
        #expect(series.count == 2)
        #expect(series.first!.date < series.last!.date)                          // oldest → newest
        #expect(abs(series[0].e1RM - StrengthMath.e1RM(weightKg: 62, reps: 5)) < 0.001)   // top set used
        #expect(abs(series[1].e1RM - StrengthMath.e1RM(weightKg: 70, reps: 5)) < 0.001)
        #expect(ExerciseTrends.gainPercent(series) > 0)                          // improved
    }

    @Test func ignoresWarmupsAndIncompleteSets() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let w = session(ctx, name: "Bench", daysAgo: 0, sets: [(80, 3)])
        // Add a heavier warmup + an incomplete set that must NOT count.
        let warm = SetEntry(); warm.weightKg = 100; warm.reps = 1; warm.isComplete = true; warm.type = .warmup
        let dnf = SetEntry(); dnf.weightKg = 120; dnf.reps = 1; dnf.isComplete = false; dnf.type = .working
        w.strength?.exercises.first?.sets.append(contentsOf: [warm, dnf])
        try ctx.save()

        let series = ExerciseTrends.e1RMSeries(exerciseName: "Bench", in: try ctx.fetch(FetchDescriptor<Workout>()))
        #expect(series.count == 1)
        #expect(abs(series[0].e1RM - StrengthMath.e1RM(weightKg: 80, reps: 3)) < 0.001)   // working set only
    }

    @Test func emptyWhenLiftNeverLogged() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        _ = session(ctx, name: "Bench", daysAgo: 0, sets: [(60, 5)])
        try ctx.save()
        #expect(ExerciseTrends.e1RMSeries(exerciseName: "Deadlift", in: try ctx.fetch(FetchDescriptor<Workout>())).isEmpty)
    }
}
