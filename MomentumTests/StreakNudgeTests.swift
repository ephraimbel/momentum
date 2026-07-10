import Testing
@testable import Momentum

/// The streak-protection nudge decision (PRD §24): only a real streak (≥3) at risk — a planned day
/// not yet trained. Never guilt, never for a non-streak.
struct StreakNudgeTests {

    @Test func nudgesWhenRealStreakAtRiskOnPlannedDay() {
        #expect(StreakNudge.shouldNudge(streak: 3, isPlannedDay: true, hasWorkedOutToday: false))
        #expect(StreakNudge.shouldNudge(streak: 9, isPlannedDay: true, hasWorkedOutToday: false))
    }

    @Test func neverNudgesWithoutARealStreak() {
        #expect(!StreakNudge.shouldNudge(streak: 2, isPlannedDay: true, hasWorkedOutToday: false))
        #expect(!StreakNudge.shouldNudge(streak: 0, isPlannedDay: true, hasWorkedOutToday: false))
    }

    @Test func neverNudgesOnRestDayOrAfterTraining() {
        #expect(!StreakNudge.shouldNudge(streak: 5, isPlannedDay: false, hasWorkedOutToday: false))  // rest day
        #expect(!StreakNudge.shouldNudge(streak: 5, isPlannedDay: true, hasWorkedOutToday: true))    // already trained
    }
}
