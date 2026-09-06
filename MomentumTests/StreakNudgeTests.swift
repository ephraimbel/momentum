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

/// The first-run nudge (2026-09-06): only an athlete with no workouts yet, on a day with an undone
/// planned run — the streak nudge cannot reach them, and the first days are where trials go dark.
struct FirstRunNudgeTests {

    @Test func nudgesANewAthleteWithARunWaiting() {
        #expect(FirstRunNudge.shouldNudge(totalWorkouts: 0, hasPlannedRunToday: true, hasWorkedOutToday: false))
    }

    @Test func neverAfterTheFirstWorkoutOrWithoutARunOrOnceTheyHaveTrained() {
        #expect(!FirstRunNudge.shouldNudge(totalWorkouts: 1, hasPlannedRunToday: true, hasWorkedOutToday: false))
        #expect(!FirstRunNudge.shouldNudge(totalWorkouts: 0, hasPlannedRunToday: false, hasWorkedOutToday: false))
        #expect(!FirstRunNudge.shouldNudge(totalWorkouts: 0, hasPlannedRunToday: true, hasWorkedOutToday: true))
    }
}
