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
        #expect(StreakCalculator.currentStreak(countingDays: [10, 9, 8], today: 12) == 0)
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

    @Test func weeksActiveThreshold() {
        // week 0 = days 0..6 (three days), week 1 = days 7..13 (two days)
        #expect(StreakCalculator.weeksActive(countingDays: [0, 1, 2, 7, 8], daysPerWeek: 3) == 1)
    }

    // MARK: Planned rest days (the other half of "a day counts")

    @Test func plannedRestDaysAreTheGapsInThePlan() {
        // Sessions on days 10 and 12, today is 13 → 11 and 13 are deliberate rest.
        #expect(StreakCalculator.plannedRestDays(sessionDays: [10, 12], today: 13) == [11, 13])
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
