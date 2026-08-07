import Testing
@testable import Momentum

struct StreakCalculatorTests {

    @Test func consecutiveDays() {
        #expect(StreakCalculator.currentStreak(countingDays: [10, 9, 8], today: 10) == 3)
    }

    @Test func todaySlippedIsForgiven() {
        // today (11) missed, but yesterday counted → streak survives.
        #expect(StreakCalculator.currentStreak(countingDays: [10, 9, 8], today: 11) == 3)
    }

    @Test func twoConsecutiveMissesReset() {
        // Both gap days fully elapsed (today = 13, days 11+12 empty) → grace exhausted, reset.
        #expect(StreakCalculator.currentStreak(countingDays: [10, 9, 8], today: 13) == 0)
    }

    @Test func emptyTodayIsPendingNotMissed() {
        // Yesterday (11) was the single forgiven slip; today (12) isn't over. The streak must
        // NOT read 0 at midnight and pop back after the afternoon run — today is pending.
        #expect(StreakCalculator.currentStreak(countingDays: [10, 9, 8], today: 12) == 3)
        // …and if today's workout lands, the streak continues through the forgiven gap.
        #expect(StreakCalculator.currentStreak(countingDays: [12, 10, 9, 8], today: 12) == 4)
    }

    @Test func singleGapForgivenMidStreak() {
        #expect(StreakCalculator.currentStreak(countingDays: [10, 8, 7], today: 10) == 3)
        #expect(StreakCalculator.currentStreak(countingDays: [10, 8, 6], today: 10) == 3)
    }

    @Test func gapOfTwoBreaks() {
        #expect(StreakCalculator.currentStreak(countingDays: [10, 7], today: 10) == 1)
    }

    @Test func longestWithForgivenGaps() {
        #expect(StreakCalculator.longestStreak(countingDays: [1, 2, 3, 5, 6]) == 5)
        #expect(StreakCalculator.longestStreak(countingDays: [1, 2, 5, 6]) == 2)
    }

    // MARK: Planned rest days (the other half of "a day counts")

    @Test func plannedRestDaysAreTheGapsInThePlan() {
        // Sessions on days 10 and 12, today is 13 → only 11 is deliberate rest. Day 13 is past
        // the plan's last session — nothing is prescribing rest there.
        #expect(StreakCalculator.plannedRestDays(sessionDays: [10, 12], today: 13) == [11])
        // Mid-plan (today 11, next session tomorrow) the gap still counts as rest.
        #expect(StreakCalculator.plannedRestDays(sessionDays: [10, 12], today: 11) == [11])
    }

    @Test func finishedPlanStopsFeedingTheStreak() {
        // Plan ended on day 4; weeks later the flame must not still be climbing on free
        // "rest days" — the streak-grows-forever-on-inactivity bug.
        #expect(StreakCalculator.plannedRestDays(sessionDays: [0, 2, 4], today: 30) == [1, 3])
    }

    @Test func futurePlanContributesNoRestDays() {
        #expect(StreakCalculator.plannedRestDays(sessionDays: [20, 22], today: 13).isEmpty)
    }

    @Test func backToBackPlannedRestPreservesStreak() {
        // A 5-day/week plan resting Sat+Sun: workouts Mon–Fri (days 0–4), sessions scheduled those
        // same days, weekend empty. On Monday (day 7) the streak must NOT have reset.
        let workoutDays: Set<Int> = [0, 1, 2, 3, 4, 7]
        let rest = StreakCalculator.plannedRestDays(sessionDays: [0, 1, 2, 3, 4, 7], today: 7)
        #expect(rest == [5, 6])
        let streak = StreakCalculator.currentStreak(countingDays: workoutDays.union(rest), today: 7)
        #expect(streak == 8)
        // Without the rest days the same athlete would read 1 — the bug this fixes.
        #expect(StreakCalculator.currentStreak(countingDays: workoutDays, today: 7) == 1)
    }

    @Test func workoutFloors() {
        #expect(StreakCalculator.workoutQualifies(type: .run, distanceM: 900, activeSeconds: 200))
        #expect(!StreakCalculator.workoutQualifies(type: .run, distanceM: 500, activeSeconds: 100))
        #expect(StreakCalculator.workoutQualifies(type: .strength, distanceM: 0, activeSeconds: 600))
        #expect(!StreakCalculator.workoutQualifies(type: .strength, distanceM: 0, activeSeconds: 120))
    }
}
