import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Verifies the ACWR training-status logic that drives the Progress coach (PRD §9).
@MainActor
struct ProgressInsightsTests {
    private func run(daysAgo: Int, minutes: Double) -> Workout {
        let w = Workout()
        w.type = .run
        w.startedAt = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        w.durationS = minutes * 60
        return w
    }

    @Test func emptyHistoryIsGettingStarted() {
        let i = ProgressInsights(workouts: [])
        #expect(!i.hasData)
        #expect(i.status == .starting)
        #expect(i.recommendation == .start)
    }

    @Test func loadSpikeRecommendsEasingOrRest() {
        var ws = [run(daysAgo: 20, minutes: 30)]                 // small chronic base
        ws += (0..<4).map { run(daysAgo: $0, minutes: 60) }      // big acute week
        let i = ProgressInsights(workouts: ws)
        #expect(i.acwr > 1.5)
        #expect(i.recommendation == .ease || i.recommendation == .rest)
        #expect(i.status == .overreaching)
    }

    @Test func steadyLoadHolds() {
        let ws = stride(from: 1, through: 27, by: 3).map { run(daysAgo: $0, minutes: 40) }
        let i = ProgressInsights(workouts: ws)
        #expect(i.acwr > 0.8)
        #expect(i.recommendation == .hold)
    }

    @Test func eightWeekSeriesIsProduced() {
        let i = ProgressInsights(workouts: [run(daysAgo: 2, minutes: 40)])
        #expect(i.weeks.count == 8)
        #expect(i.weeks.last!.load > 0)   // recent workout lands in the latest (rolling 7-day) bar
    }

    /// The latest bar is a rolling 7-day window ending now, so a recent workout always shows there —
    /// regardless of weekday (the old calendar-week bucket left it empty early in the week).
    @Test func latestBarIsRollingSevenDays() {
        #expect(ProgressInsights(workouts: [run(daysAgo: 6, minutes: 30)]).weeks.last!.load > 0)

        let older = ProgressInsights(workouts: [run(daysAgo: 8, minutes: 30)])
        #expect(older.weeks.last!.load == 0)                          // outside the last 7 days…
        #expect(older.weeks.dropLast().contains { $0.load > 0 })      // …but still in an earlier bar
    }

    // MARK: applying a recommendation to the plan

    private func inMemoryContainer() -> ModelContainer {
        try! ModelContainer(
            for: TrainingPlan.self, PlannedSession.self, PlannedExercise.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func futureRun(in ctx: ModelContext, distanceM: Double) -> TrainingPlan {
        let plan = TrainingPlan()
        plan.p5kSPerKm = 300
        let s = PlannedSession()
        s.date = Date().addingTimeInterval(2 * 86_400)
        s.discipline = .running
        s.runType = .intervals
        s.targetDistanceM = distanceM
        s.targetPaceSPerKm = 300
        s.status = .planned
        plan.sessions = [s]
        ctx.insert(plan)
        return plan
    }

    @Test func increaseScalesFutureUpAndKeepsHardWork() {
        let container = inMemoryContainer()
        let plan = futureRun(in: container.mainContext, distanceM: 5000)
        let changed = PlanCoaching.apply(.increase, to: plan, in: container.mainContext)
        #expect(changed == 1)
        #expect(plan.sessions[0].targetDistanceM == 5500)   // +10%
        #expect(plan.sessions[0].runType == .intervals)     // intensity preserved
    }

    @Test func easeScalesDownAndSoftensIntensity() {
        let container = inMemoryContainer()
        let plan = futureRun(in: container.mainContext, distanceM: 5000)
        PlanCoaching.apply(.ease, to: plan, in: container.mainContext)
        #expect(plan.sessions[0].targetDistanceM == 4250)   // -15%
        #expect(plan.sessions[0].runType == .easy)          // hard work softened
        #expect(plan.sessions[0].intervals == nil)
    }

    @Test func restConvertsNextSessionToRecovery() {
        let container = inMemoryContainer()
        let plan = futureRun(in: container.mainContext, distanceM: 8000)
        PlanCoaching.apply(.rest, to: plan, in: container.mainContext)
        #expect(plan.sessions[0].runType == .recovery)
        #expect(plan.sessions[0].targetDistanceM! <= 3200)
    }

    @Test func holdLeavesPlanUntouched() {
        let container = inMemoryContainer()
        let plan = futureRun(in: container.mainContext, distanceM: 5000)
        let changed = PlanCoaching.apply(.hold, to: plan, in: container.mainContext)
        #expect(changed == 0)
        #expect(plan.sessions[0].targetDistanceM == 5000)
    }
}
