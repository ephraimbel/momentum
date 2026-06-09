import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Verifies plan crediting and no-shame adaptation (PRD §4.7, §9.4).
@MainActor
struct PlanCoachingTests {

    /// Build an in-memory container (retained by the caller so it doesn't dealloc mid-test).
    func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func makePlan(in ctx: ModelContext, sessions: [PlannedSession]) -> TrainingPlan {
        let profile = UserProfile()
        let plan = TrainingPlan()
        ctx.insert(profile)
        ctx.insert(plan)
        for s in sessions { ctx.insert(s) }
        plan.sessions = sessions
        profile.plan = plan
        try? ctx.save()
        return plan
    }

    @Test func creditsMatchingWorkoutToToday() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let session = PlannedSession()
        session.date = Calendar.current.startOfDay(for: Date())
        session.discipline = .strength
        session.status = .planned
        let plan = makePlan(in: ctx, sessions: [session])

        let workout = Workout()
        workout.type = .strength
        workout.startedAt = Date()
        ctx.insert(workout)

        let credited = PlanCoaching.creditWorkout(workout, to: plan, in: ctx)
        #expect(credited != nil)
        #expect(session.status == .completed)
        #expect(session.completedWorkout?.id == workout.id)
    }

    @Test func doesNotCreditWrongDiscipline() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let session = PlannedSession()
        session.date = Calendar.current.startOfDay(for: Date())
        session.discipline = .running
        session.status = .planned
        let plan = makePlan(in: ctx, sessions: [session])

        let workout = Workout(); workout.type = .strength; workout.startedAt = Date()
        ctx.insert(workout)
        #expect(PlanCoaching.creditWorkout(workout, to: plan, in: ctx) == nil)
        #expect(session.status == .planned)
    }

    @Test func missedSessionMovesNeverFails() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
        let session = PlannedSession()
        session.date = yesterday
        session.discipline = .running
        session.status = .planned
        let plan = makePlan(in: ctx, sessions: [session])

        PlanCoaching.reconcileMissed(plan, today: Date(), in: ctx)

        #expect(session.status == .moved)                         // never a red miss
        #expect(session.rationale != nil)
        #expect(cal.startOfDay(for: session.date) >= cal.startOfDay(for: Date()))
    }
}
