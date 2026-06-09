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

    @Test func workoutFloors() {
        #expect(StreakCalculator.workoutQualifies(type: .run, distanceM: 900, activeSeconds: 200))
        #expect(!StreakCalculator.workoutQualifies(type: .run, distanceM: 500, activeSeconds: 100))
        #expect(StreakCalculator.workoutQualifies(type: .strength, distanceM: 0, activeSeconds: 600))
        #expect(!StreakCalculator.workoutQualifies(type: .strength, distanceM: 0, activeSeconds: 120))
    }
}
