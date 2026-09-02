import Testing
import Foundation
import SwiftData
@testable import Momentum

/// The self-coached contract (owner call 2026-07-30): the athlete writes their own weeks and the
/// coach NEVER prescribes or rewrites inside their plan — while every no-shame scheduling behavior
/// (rolling a missed session forward) keeps working. Each guard is pinned here so a future
/// adaptation feature can't quietly start editing a plan the athlete took over.
@MainActor
struct SelfCoachedPlanTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func selfCoachedPlan(_ ctx: ModelContext) -> TrainingPlan {
        let plan = TrainingPlan()
        plan.isSelfCoached = true
        plan.p5kSPerKm = 300
        ctx.insert(plan)
        return plan
    }

    private func hardRun(distanceM: Double = 5_000, paceSPerKm: Double = 280) -> Workout {
        let w = Workout(); w.type = .run
        w.durationS = distanceM / 1000 * paceSPerKm
        w.perceivedEffort = 9
        let gps = GPSDetail(); gps.distanceM = distanceM; gps.avgPaceSPerKm = paceSPerKm
        w.gps = gps
        return w
    }

    // MARK: The coach stands down

    @Test func pacesAreNeverRecalibrated() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let plan = selfCoachedPlan(ctx)
        // A run fast enough that a coached plan would bank recalibration evidence.
        let run = hardRun()
        ctx.insert(run)
        #expect(PlanCoaching.recalibratePaces(from: run, plan: plan, in: ctx) == nil)
        #expect(plan.p5kSPerKm == 300)
        #expect(plan.pendingP5kSPerKm == nil)
    }

    @Test func loadIsNeverAutoAdapted() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let plan = selfCoachedPlan(ctx)
        // A pile of recent hard work that would trip the protective ease on a coached plan.
        var workouts: [Workout] = []
        for daysAgo in 0..<6 {
            let w = hardRun(distanceM: 15_000)
            w.startedAt = Date().addingTimeInterval(Double(-daysAgo) * 86_400)
            ctx.insert(w); workouts.append(w)
        }
        #expect(PlanCoaching.autoAdapt(plan, workouts: workouts, in: ctx) == nil)
        #expect(PlanCoaching.adaptToEffort(hardRun(), plan: plan, in: ctx) == nil)
        #expect(PlanCoaching.proposeAdjustment(plan, workouts: workouts) == nil)
    }

    // MARK: No-shame scheduling still works

    @Test func missedSessionsStillRollForwardWithoutARebuildWeek() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let plan = selfCoachedPlan(ctx)
        let cal = Calendar.current
        // Four of THEIR OWN sessions, all past-due — enough to trip a coached plan's rebuild week.
        for daysAgo in 1...4 {
            let s = PlannedSession()
            s.date = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: Date()))!
            s.discipline = .running; s.runType = .easy
            s.targetDistanceM = 8_000; s.targetPaceSPerKm = 360
            s.status = .planned
            plan.sessions.append(s); ctx.insert(s)
        }
        try ctx.save()
        PlanCoaching.reconcileMissed(plan, today: Date(), in: ctx)
        // Every session moved forward (no-shame scheduling keeps working)…
        let today = cal.startOfDay(for: Date())
        #expect(plan.sessions.allSatisfy { $0.date >= today })
        // …but nothing was REWRITTEN: no 70% rebuild-week scaling, no easy-conversion, no pace edit.
        #expect(plan.sessions.allSatisfy { $0.targetDistanceM == 8_000 })
        #expect(plan.sessions.allSatisfy { $0.targetPaceSPerKm == 360 })
        #expect(plan.lastAdaptedAt == nil)
    }

    // MARK: The way back

    @Test func buildingACoachedPlanClearsSelfCoached() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = UserProfile()
        profile.disciplines = [Discipline.running.rawValue]
        ctx.insert(profile)
        let old = selfCoachedPlan(ctx)
        profile.plan = old
        try ctx.save()

        let generated = PlanEngine.generate(
            profile: PlanInputs(disciplines: [.running], goal: .generalFitness, daysPerWeek: 3,
                                equipment: .bodyweight, sessionMinutes: 45, raceDate: nil,
                                runningExperience: .some, liftingExperience: .new),
            catalog: [], startDate: Date())
        ctx.autosaveEnabled = false
        let rebuilt = try PlanService.stagePersist(generated, for: profile, startDate: Date(), in: ctx)
        _ = try RunningPlanBackfill.prepareAfterLegacyPlanMutation(in: ctx)
        try ctx.save()
        #expect(!rebuilt.isSelfCoached, "a freshly built coached plan must not inherit self-coached")
        #expect(profile.plan?.isSelfCoached == false)
    }
}
