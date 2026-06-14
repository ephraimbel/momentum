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

    // MARK: Pace recalibration (P1 — the adaptive loop for runners)

    /// A future easy running session whose pace targets the given p5k.
    private func futureEasyRun(in ctx: ModelContext, p5k: Double) -> PlannedSession {
        let s = PlannedSession()
        s.date = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        s.discipline = .running
        s.runType = .easy
        s.status = .planned
        s.targetDistanceM = 6000
        s.targetPaceSPerKm = PlanEngine.pace(.easy, p5k: p5k)
        return s
    }

    private func run(in ctx: ModelContext, distanceM: Double, durationS: Double, rpe: Int? = nil) -> Workout {
        let w = Workout()
        w.type = .run
        w.startedAt = Date()
        w.durationS = durationS
        w.perceivedEffort = rpe
        let g = GPSDetail(); g.distanceM = distanceM
        w.gps = g
        ctx.insert(w)
        return w
    }

    @Test func fasterRunLowersP5kAndReDerivesFuturePaces() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let future = futureEasyRun(in: ctx, p5k: 322)
        let plan = makePlan(in: ctx, sessions: [future]); plan.p5kSPerKm = 322

        // A hard 5k in 1600 s ⇒ ~320 s/km equivalent (within the 3% bound of 322).
        let w = run(in: ctx, distanceM: 5000, durationS: 1600, rpe: 8)
        let rec = PlanCoaching.recalibratePaces(from: w, plan: plan, in: ctx)

        #expect(rec != nil)
        #expect(abs(plan.p5kSPerKm - 320) < 1)                              // lowered to the equivalent
        #expect(rec?.sessionsUpdated == 1)
        #expect(abs((future.targetPaceSPerKm ?? 0) - PlanEngine.pace(.easy, p5k: 320)) < 1)  // future pace re-derived
    }

    @Test func bigImprovementIsCappedAtThreePercent() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let future = futureEasyRun(in: ctx, p5k: 360)
        let plan = makePlan(in: ctx, sessions: [future]); plan.p5kSPerKm = 360

        // A blazing 5k in 1500 s ⇒ 300 s/km equivalent, but a single run may only drop p5k ~3%.
        let w = run(in: ctx, distanceM: 5000, durationS: 1500, rpe: 9)
        _ = PlanCoaching.recalibratePaces(from: w, plan: plan, in: ctx)

        #expect(abs(plan.p5kSPerKm - 360 * 0.97) < 1)   // 349.2, not 300
    }

    @Test func easyRunDoesNotChangePaces() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let future = futureEasyRun(in: ctx, p5k: 330)
        let plan = makePlan(in: ctx, sessions: [future]); plan.p5kSPerKm = 330

        // 8 km at easy pace (410 s/km), no reported effort, no planned quality ⇒ not a fitness signal.
        let w = run(in: ctx, distanceM: 8000, durationS: 8 * 410, rpe: nil)
        let rec = PlanCoaching.recalibratePaces(from: w, plan: plan, in: ctx)

        #expect(rec == nil)
        #expect(plan.p5kSPerKm == 330)                  // unchanged
    }

    @Test func slowHardEffortNeverRaisesPaces() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let future = futureEasyRun(in: ctx, p5k: 300)
        let plan = makePlan(in: ctx, sessions: [future]); plan.p5kSPerKm = 300

        // A hard run (RPE 8) but slow (5k in 1700 s ⇒ 340 equivalent, slower than the stored 300).
        let w = run(in: ctx, distanceM: 5000, durationS: 1700, rpe: 8)
        let rec = PlanCoaching.recalibratePaces(from: w, plan: plan, in: ctx)

        #expect(rec == nil)
        #expect(plan.p5kSPerKm == 300)                  // a bad day never slows you down (no-shame)
    }

    // MARK: Auto-adaptive load (P3 — ACWR ease/rest, never auto-increase, ≤1/week)

    private func loggedWorkout(in ctx: ModelContext, daysAgo: Int, minutes: Double = 60, rpe: Int = 6) -> Workout {
        let w = Workout()
        w.type = .run
        w.startedAt = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        w.durationS = minutes * 60
        w.perceivedEffort = rpe
        let g = GPSDetail(); g.distanceM = 5000; w.gps = g
        ctx.insert(w)
        return w
    }

    /// 10 equal sessions weighted so the acute:chronic ratio lands ~1.6 ⇒ "ease".
    private func overreachingHistory(in ctx: ModelContext) {
        for d in [0, 2, 4, 6] { _ = loggedWorkout(in: ctx, daysAgo: d) }       // acute (last 7d)
        for d in [10, 12, 14, 18, 22, 26] { _ = loggedWorkout(in: ctx, daysAgo: d) }  // chronic-only
    }

    @Test func autoEasesWhenOverreaching() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        overreachingHistory(in: ctx)

        let future = PlannedSession()
        future.date = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        future.discipline = .running; future.runType = .tempo; future.status = .planned
        future.targetDistanceM = 8000; future.targetPaceSPerKm = 320
        let plan = makePlan(in: ctx, sessions: [future]); plan.p5kSPerKm = 330

        let workouts = (try? ctx.fetch(FetchDescriptor<Workout>())) ?? []
        let rec = PlanCoaching.autoAdapt(plan, workouts: workouts, in: ctx)

        #expect(rec == .ease)
        #expect(plan.lastAdaptedAt != nil)
        #expect(future.runType == .easy)                  // hard work softened (no-shame)
        #expect((future.targetDistanceM ?? 0) < 8000)     // volume eased
    }

    @Test func autoAdaptGatedToOncePerWeek() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        overreachingHistory(in: ctx)
        let future = PlannedSession()
        future.date = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        future.discipline = .running; future.runType = .easy; future.status = .planned
        future.targetDistanceM = 8000; future.targetPaceSPerKm = 400
        let plan = makePlan(in: ctx, sessions: [future]); plan.p5kSPerKm = 330
        let workouts = (try? ctx.fetch(FetchDescriptor<Workout>())) ?? []

        #expect(PlanCoaching.autoAdapt(plan, workouts: workouts, in: ctx) == .ease)
        #expect(PlanCoaching.autoAdapt(plan, workouts: workouts, in: ctx) == nil)   // gated, no compounding
    }

    @Test func autoAdaptNeverIncreasesLoad() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        // Low acute:chronic (~0.67) ⇒ the rec would be .increase — which auto-adapt declines to apply.
        _ = loggedWorkout(in: ctx, daysAgo: 3)
        for d in [10, 14, 18, 22, 26] { _ = loggedWorkout(in: ctx, daysAgo: d) }
        let future = PlannedSession()
        future.date = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        future.discipline = .running; future.runType = .easy; future.status = .planned
        future.targetDistanceM = 6000
        let plan = makePlan(in: ctx, sessions: [future]); plan.p5kSPerKm = 330
        let workouts = (try? ctx.fetch(FetchDescriptor<Workout>())) ?? []

        #expect(PlanCoaching.autoAdapt(plan, workouts: workouts, in: ctx) == nil)
        #expect(plan.lastAdaptedAt == nil)
        #expect(future.targetDistanceM == 6000)            // untouched — never auto-increases
    }

    // MARK: Next-workout reminders (P4 — the "updates" half)

    @Test func reminderPayloadsCoverUpcomingSessionsOnly() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        let far = cal.date(byAdding: .day, value: 9, to: today)!

        let run = PlannedSession()
        run.date = tomorrow; run.discipline = .running; run.runType = .easy
        run.status = .planned; run.targetDistanceM = 8000; run.targetPaceSPerKm = 370
        let doneToday = PlannedSession()
        doneToday.date = today; doneToday.discipline = .strength; doneToday.status = .completed
        let farRun = PlannedSession()
        farRun.date = far; farRun.discipline = .running; farRun.runType = .long; farRun.status = .planned
        let plan = makePlan(in: ctx, sessions: [run, doneToday, farRun])

        let payloads = NotificationService.reminderPayloads(for: plan, now: today, hour: 7, minute: 30)

        #expect(payloads.count == 1)                                     // completed + far-future excluded
        #expect(payloads.first?.id == "momentum.session.\(run.id.uuidString)")
        #expect(payloads.first?.title == "Run day")
        #expect(payloads.first?.body == PlanCoaching.brief(for: run))    // carries the current prescription
        #expect(payloads.first?.fireComponents.hour == 7)
        #expect(payloads.first?.fireComponents.minute == 30)
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
