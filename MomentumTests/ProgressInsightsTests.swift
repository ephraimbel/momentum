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

    @Test func firstWeekBigLoadIsNotToldToRest() {
        // Brand-new athlete, five hard days of history and nothing older. The un-normalized
        // ÷4 chronic divisor read this as ACWR ≈ 4 → "rest" — a false alarm for exactly the
        // athlete we should be encouraging. With history-normalized chronic, ratio ≈ 1.
        let ws = (0..<5).map { run(daysAgo: $0, minutes: 60) }
        let i = ProgressInsights(workouts: ws)
        #expect(i.status != .overreaching)
        #expect(i.recommendation != .rest && i.recommendation != .ease)
    }

    @Test func steadyLoadHolds() {
        // Three runs a week for ~4 weeks. No run lands exactly on the 7-day acute cutoff —
        // a day-7 workout sits on the boundary and flips in/out with calendar-vs-interval
        // rounding, which is boundary flakiness, not training signal.
        let days = [1, 3, 5, 8, 10, 12, 15, 17, 19, 22, 24, 26]
        let i = ProgressInsights(workouts: days.map { run(daysAgo: $0, minutes: 40) })
        #expect(i.acwr > 0.8)
        #expect(i.recommendation == .hold)
    }

    @Test func weeklyPaceIsDistanceWeightedAndRunningOnly() {
        func pacedRun(daysAgo: Int, distanceM: Double, durationS: Double) -> Workout {
            let w = Workout(); w.type = .run
            w.startedAt = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
            w.durationS = durationS
            let g = GPSDetail(); g.distanceM = distanceM; w.gps = g
            return w
        }
        let strength = Workout()                       // must NOT affect running pace
        strength.type = .strength
        strength.startedAt = Date().addingTimeInterval(-86_400); strength.durationS = 3600

        // This week: 5 km in 1500 s (300/km) + 5 km in 1700 s (340/km).
        // Distance-weighted = (1500+1700) / 10 km = 320 s/km.
        let i = ProgressInsights(workouts: [
            pacedRun(daysAgo: 1, distanceM: 5000, durationS: 1500),
            pacedRun(daysAgo: 2, distanceM: 5000, durationS: 1700),
            strength,
        ])
        #expect(abs(i.weeks.last!.avgPaceSPerKm - 320) < 0.5)
    }

    @Test func eightWeekSeriesIsProduced() {
        let i = ProgressInsights(workouts: [run(daysAgo: 2, minutes: 40)])
        #expect(i.weeks.count == 8)
        #expect(i.weeks.last!.load > 0)   // recent workout lands in the latest (rolling 7-day) bar
    }

    /// The Trends range picker: `weeksBack` sizes the weekly series (1M ≈ 5, 3M ≈ 13). The most
    /// recent bar stays the rolling 7-day window regardless of range.
    @Test func weeksBackSizesTheSeries() {
        let ws = [run(daysAgo: 2, minutes: 40)]
        #expect(ProgressInsights(workouts: ws, weeksBack: 5).weeks.count == 5)
        #expect(ProgressInsights(workouts: ws, weeksBack: 13).weeks.count == 13)
        // A degenerate window still produces at least the current week (no crash, no empty series).
        #expect(ProgressInsights(workouts: ws, weeksBack: 0).weeks.count == 1)
        for weeks in [5, 13, 26] {
            #expect(ProgressInsights(workouts: ws, weeksBack: weeks).weeks.last!.load > 0)
        }
    }

    /// Widening the window must never change the coaching verdict — ACWR and the trend percentages
    /// always read the most recent weeks, so 1M and 3M agree on status/recommendation/ACWR.
    @Test func verdictIsIndependentOfRange() {
        var ws = [run(daysAgo: 20, minutes: 30)]
        ws += (0..<4).map { run(daysAgo: $0, minutes: 60) }
        let short = ProgressInsights(workouts: ws, weeksBack: 5)
        let long = ProgressInsights(workouts: ws, weeksBack: 13)
        #expect(short.acwr == long.acwr)
        #expect(short.status == long.status)
        #expect(short.recommendation == long.recommendation)
        #expect(short.loadTrendPct == long.loadTrendPct)
        #expect(short.weeks.last!.load == long.weeks.last!.load)
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
        #expect(plan.sessions[0].targetDistanceM == 4500)   // -15% (5000→4250), snapped to a clean 4.5 km
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

    // MARK: The 120-day query bound (PlanProposalCard)

    /// `PlanProposalCard` reads a 120-day slice instead of the whole log. That is only legitimate if
    /// it changes nothing: the acute window is 7 days, the chronic window 28, and the chronic
    /// divisor saturates at 4 weeks of history — so a workout older than 120 days cannot move
    /// `recommendation`. Three years of history, sliced, must agree with the full set.
    @Test func recommendationIsUnchangedByThe120DayBound() {
        // Three years of steady training, plus a recent block that decides the verdict.
        var all: [Workout] = (0..<156).map { run(daysAgo: 7 * $0 + 200, minutes: 45) }
        all += [run(daysAgo: 2, minutes: 60), run(daysAgo: 5, minutes: 50),
                run(daysAgo: 9, minutes: 55), run(daysAgo: 16, minutes: 45),
                run(daysAgo: 23, minutes: 40), run(daysAgo: 30, minutes: 40)]

        let cutoff = Calendar.current.date(byAdding: .day, value: -120, to: Date())!
        let bounded = all.filter { $0.startedAt >= cutoff }

        #expect(bounded.count < all.count)   // the bound is actually cutting something
        #expect(ProgressInsights(workouts: bounded).recommendation
                == ProgressInsights(workouts: all).recommendation)
        #expect(ProgressInsights(workouts: bounded).status
                == ProgressInsights(workouts: all).status)
    }

    /// The same equivalence for a brand-new athlete, whose entire history is inside the window —
    /// the case where the chronic divisor has NOT saturated and a wrong bound would show up.
    @Test func the120DayBoundIsAlsoIdenticalForANewAthlete() {
        let all = [run(daysAgo: 1, minutes: 30), run(daysAgo: 4, minutes: 35),
                   run(daysAgo: 8, minutes: 30)]
        let cutoff = Calendar.current.date(byAdding: .day, value: -120, to: Date())!
        let bounded = all.filter { $0.startedAt >= cutoff }

        #expect(bounded.count == all.count)
        #expect(ProgressInsights(workouts: bounded).acwr == ProgressInsights(workouts: all).acwr)
        #expect(ProgressInsights(workouts: bounded).recommendation
                == ProgressInsights(workouts: all).recommendation)
    }

}
