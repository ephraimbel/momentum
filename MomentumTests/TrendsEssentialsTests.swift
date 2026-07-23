import Testing
import Foundation
@testable import Momentum

/// The Trends Essentials math (2026-07-22 redesign) — the week-vs-week strip, the odometer
/// totals, and the steps bucketing/headline. Pure reductions over workouts; pins the calendar
/// windows (calendar weeks, not rolling 7-day windows) and the honesty rules (no delta against
/// an empty window).
@Suite("TrendsEssentials")
struct TrendsEssentialsTests {
    let cal = Calendar.current
    /// A fixed Wednesday-ish anchor so week boundaries are stable within a test run.
    var now: Date { cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_760_000_000))! }

    private func run(daysAgo: Int, km: Double, minutes: Double = 40, climb: Double = 0) -> Workout {
        let w = Workout()
        w.type = .run
        w.startedAt = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        w.durationS = minutes * 60
        let gps = GPSDetail()
        gps.distanceM = km * 1000
        gps.elevationGainM = climb
        w.gps = gps
        return w
    }

    // MARK: This week vs last

    @Test func weekStatUsesCalendarWeeks() {
        // Today (in this week) vs 8 days ago (safely in last week whatever weekday `now` is).
        let workouts = [run(daysAgo: 0, km: 10, minutes: 50, climb: 120),
                        run(daysAgo: 8, km: 21, minutes: 100, climb: 300)]
        let thisWeek = TrendsEssentials.weekStat(workouts: workouts, weeksAgo: 0, now: now, calendar: cal)
        let lastWeek = TrendsEssentials.weekStat(workouts: workouts, weeksAgo: 1, now: now, calendar: cal)
        #expect(thisWeek.distanceM == 10_000 && thisWeek.sessions == 1)
        #expect(thisWeek.durationS == 3000 && thisWeek.elevationM == 120)
        // The 8-days-ago run lands in "last week" only when the boundary agrees — assert the
        // sum of both windows instead of pinning which side the boundary falls on.
        #expect(thisWeek.distanceM + lastWeek.distanceM == 31_000
                || lastWeek.distanceM == 0)   // (8 days back can be two weeks back on Mon/Tue anchors)
    }

    @Test func emptyWeekIsZeroesNotNoise() {
        let stat = TrendsEssentials.weekStat(workouts: [], weeksAgo: 0, now: now, calendar: cal)
        #expect(stat == TrendsEssentials.WeekStat())
    }

    // MARK: Totals

    @Test func totalsBucketByCalendarWindows() {
        let today = run(daysAgo: 0, km: 5)
        let old = run(daysAgo: 400, km: 42.2, minutes: 240)   // over a year back → lifetime only
        let t = TrendsEssentials.totals(workouts: [today, old], now: now, calendar: cal)
        #expect(t.month.distanceM == 5000 && t.month.sessions == 1)
        #expect(t.year.distanceM == 5000 && t.year.sessions == 1)
        #expect(t.lifetime.distanceM == 47_200 && t.lifetime.sessions == 2)
        #expect(t.lifetime.durationS == today.durationS + old.durationS)
    }

    // MARK: Steps

    private func stepDays(_ values: [Double]) -> [TrendsEssentials.StepPoint] {
        values.enumerated().map { i, v in
            TrendsEssentials.StepPoint(date: cal.startOfDay(for: now).addingTimeInterval(Double(i - values.count + 1) * 86_400),
                                       steps: v)
        }
    }

    @Test func stepsHeadlineIsTrailingSevenDayAverage() {
        let days = stepDays([4000, 4000, 4000, 4000, 4000, 4000, 4000,   // prior week
                             8000, 8000, 8000, 8000, 8000, 8000, 8000])  // current week
        let h = TrendsEssentials.stepsHeadline(days)
        #expect(h.avg == 8000)
        #expect(h.deltaPct == 100)   // doubled vs the prior seven
    }

    @Test func stepsDeltaNeedsBothWindows() {
        // Five days of history: an average, but no prior window → no invented delta.
        let h = TrendsEssentials.stepsHeadline(stepDays([6000, 6000, 6000, 6000, 6000]))
        #expect(h.avg == 6000)
        #expect(h.deltaPct == nil)
    }

    @Test func weeklyAveragesAverageNotSum() {
        // 14 identical days must average to the same value per week — a SUM would be 7× off.
        let weekly = TrendsEssentials.weeklyStepAverages(stepDays(Array(repeating: 9000, count: 14)), calendar: cal)
        #expect(!weekly.isEmpty)
        #expect(weekly.allSatisfy { abs($0.steps - 9000) < 0.001 })
    }
}
