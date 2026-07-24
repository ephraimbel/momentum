import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Manually-added workouts must be first-class — queryable and counted, so they show in History and
/// Progress exactly like a captured session.
@MainActor
struct LogWorkoutBuilderTests {

    func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    @Test func manualCardioIsQueryableAndMeasured() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        // A 5 km treadmill run in 25:00.
        let run = LogWorkoutBuilder.make(type: .run, date: Date(), durationS: 1500, distanceM: 5000,
                                         indoor: true, effort: 6, note: "felt good",
                                         exercises: [], resolveExercise: { _ in Exercise() })
        ctx.insert(run); try ctx.save()

        let all = try ctx.fetch(FetchDescriptor<Workout>())
        #expect(all.count == 1)                       // fetchable → appears in the unfiltered History/Progress query
        let w = try #require(all.first)
        #expect(w.type == .run)
        #expect(w.gps?.distanceM == 5000)             // distance drives History stats + Trends mileage
        #expect(abs((w.gps?.avgPaceSPerKm ?? 0) - 300) < 0.001)   // 1500s / 5km = 300 s/km
        #expect(w.perceivedEffort == 6)
        #expect(w.note.contains("Treadmill") && w.note.contains("felt good"))
        #expect(ProfileStats(workouts: all).totalWorkouts == 1)   // counted in Progress
    }

    @Test func treadmillLogClosesTodaysPlannedRun() throws {
        // The Today plan card's "I ran this on a treadmill" flow: logging an indoor run against
        // today's prescription must credit the plan, exactly like a tracked run — otherwise the
        // planned session stays open forever for anyone who runs indoors.
        let container = try makeContainer(); let ctx = container.mainContext
        let session = PlannedSession()
        session.date = Calendar.current.startOfDay(for: Date())
        session.discipline = .running
        session.status = .planned
        session.targetDistanceM = 6 * Formatters.metersPerMile      // the prescribed distance
        let profile = UserProfile(); let plan = TrainingPlan()
        ctx.insert(profile); ctx.insert(plan); ctx.insert(session)
        plan.sessions = [session]; profile.plan = plan
        try ctx.save()

        // Built exactly as the treadmill quick-log builds it: indoor, the planned distance, a time.
        let run = LogWorkoutBuilder.make(type: .run, date: Date(), durationS: 4320,
                                         distanceM: session.targetDistanceM ?? 0,
                                         indoor: true, effort: nil, note: "",
                                         exercises: [], resolveExercise: { _ in Exercise() })
        ctx.insert(run); try ctx.save()

        #expect(PlanCoaching.creditWorkout(run, to: plan, in: ctx) != nil)
        #expect(session.status == .completed)                       // today's plan closes
        #expect(session.completedWorkout?.id == run.id)
        #expect(run.note.contains("Treadmill"))                     // logged as the indoor run it was
    }

    @Test func manualStrengthTotalsVolumeAndSets() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let sets = [LogWorkoutBuilder.SetInput(reps: 5, weightKg: 100),
                    LogWorkoutBuilder.SetInput(reps: 5, weightKg: 100)]
        let lift = LogWorkoutBuilder.make(type: .strength, date: Date(), durationS: 3000, distanceM: 0,
                                          indoor: false, effort: nil, note: "",
                                          exercises: [.init(name: "Back Squat", sets: sets)],
                                          resolveExercise: { name in
                                              let e = Exercise(); e.name = name; e.isCustom = true; ctx.insert(e); return e
                                          })
        ctx.insert(lift); try ctx.save()

        let all = try ctx.fetch(FetchDescriptor<Workout>())
        #expect(all.count == 1)
        let s = try #require(all.first?.strength)
        #expect(s.exercises.count == 1)
        #expect(s.totalSets == 2)
        #expect(s.totalVolumeKg == 1000)              // 5×100 + 5×100 — feeds Trends volume
        #expect(s.exercises.first?.exercise?.name == "Back Squat")
        #expect(s.exercises.first?.sets.allSatisfy { $0.isComplete && $0.type == .working } == true)
        #expect(ProfileStats(workouts: all).totalWorkouts == 1)
    }
}
