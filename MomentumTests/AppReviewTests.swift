import Testing
import Foundation
@testable import Momentum

/// The rating-prompt gate for the IN-APP cards. Never before real engagement, never past Apple's
/// own three-per-year ceiling, never twice in the same few days, never again once the athlete has
/// rated.
///
/// Onboarding's `.review` beat (2026-09-05) does not come through `shouldRequestReview` at all —
/// it raises the sheet on arrival and tells this ledger a slot is gone via `recordOnboardingAsk`.
/// That is the ONE sanctioned bypass and it is a debit, not a claim: see the tests at the bottom.
struct AppReviewTests {

    /// An isolated defaults suite per test — never touch `.standard`.
    private func suite(_ name: String = #function) -> UserDefaults {
        let d = UserDefaults(suiteName: "AppReviewTests.\(name)")!
        AppReview.reset(defaults: d)
        return d
    }

    /// Clock helper: far enough ahead that the spacing rule never masks what a test is asserting.
    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + Double(n) * 86_400) }

    /// A brand-new athlete — the first-launch / onboarding case Apple flagged — is never asked.
    @Test func aFreshInstallIsNeverAsked() {
        let d = suite()
        #expect(!AppReview.shouldRequestReview(defaults: d, now: day(0)))
    }

    /// Discards do not call `recordWorkoutSaved`, so a user who records and throws away workouts
    /// never crosses the bar. Modelled here by never counting.
    @Test func withoutRecordedActivityTheGateStaysClosed() {
        let d = suite()
        for i in 0..<20 { _ = AppReview.shouldRequestReview(defaults: d, now: day(i * 10)) }
        #expect(!AppReview.shouldRequestReview(defaults: d, now: day(500)))
    }

    /// The first save opens the first ask, and the same save can't open a second.
    @Test func theFirstSavedWorkoutOpensTheFirstAsk() {
        let d = suite()
        AppReview.recordWorkoutSaved(defaults: d)
        #expect(AppReview.shouldRequestReview(defaults: d, now: day(0)))
        #expect(!AppReview.shouldRequestReview(defaults: d, now: day(0)))
    }

    /// Three chances, at the 1st, 5th and 15th — then silence forever.
    @Test func asksAtEachMilestoneAndThenStops() {
        let d = suite()
        var asks = 0
        for n in 1...40 {
            AppReview.recordWorkoutSaved(defaults: d)
            if AppReview.shouldRequestReview(defaults: d, now: day(n * 10)) { asks += 1 }
        }
        #expect(asks == AppReview.milestones.count, "expected one ask per milestone, got \(asks)")
        #expect(!AppReview.shouldRequestReview(defaults: d, now: day(9_000)))
    }

    /// Meals are their own core loop: an athlete who never records a workout reaches exactly the
    /// same three moments by logging food.
    @Test func mealsReachTheSameMilestones() {
        let d = suite()
        var asks = 0
        for n in 1...40 {
            AppReview.recordMealLogged(defaults: d)
            if AppReview.shouldRequestReview(defaults: d, now: day(n * 10)) { asks += 1 }
        }
        #expect(asks == AppReview.milestones.count)
    }

    /// A milestone is cleared by WHICHEVER stream gets there first — the two counts are alternative
    /// routes to the same moment, not additive, so mixed use never buys extra asks.
    @Test func eitherStreamClearsAMilestoneAndTheCapIsShared() {
        let d = suite()
        var asks = 0
        for n in 1...40 {
            AppReview.recordWorkoutSaved(defaults: d)
            AppReview.recordMealLogged(defaults: d)
            if AppReview.shouldRequestReview(defaults: d, now: day(n * 10)) { asks += 1 }
        }
        #expect(asks == AppReview.milestones.count, "mixed use must not exceed the shared cap")
    }

    /// Two milestones landing the same afternoon must not stack two cards.
    @Test func doesNotAskTwiceInsideTheSpacingWindow() {
        let d = suite()
        AppReview.recordWorkoutSaved(defaults: d)
        #expect(AppReview.shouldRequestReview(defaults: d, now: day(0)))
        for _ in 0..<5 { AppReview.recordMealLogged(defaults: d) }
        #expect(!AppReview.shouldRequestReview(defaults: d, now: day(1)),
                "a second card the next day is the nag pattern the cap exists to prevent")
        #expect(AppReview.shouldRequestReview(defaults: d, now: day(10)),
                "once the window has passed, the earned milestone still stands")
    }

    /// Apple never reports whether a review was written, so tapping "Rate momentum" is the signal —
    /// and it is terminal.
    @Test func ratingStopsEveryFutureAsk() {
        let d = suite()
        AppReview.recordWorkoutSaved(defaults: d)
        #expect(AppReview.shouldRequestReview(defaults: d, now: day(0)))
        AppReview.recordRated(defaults: d)
        for n in 1...40 {
            AppReview.recordWorkoutSaved(defaults: d)
            AppReview.recordMealLogged(defaults: d)
            #expect(!AppReview.shouldRequestReview(defaults: d, now: day(n * 10)),
                    "asked again after the athlete rated")
        }
    }

    /// Installs carrying the old once-ever latch are counted as having spent ONE ask, so they get
    /// the 5th and 15th milestones back without anyone exceeding three cards.
    @Test func aLegacyAskedInstallResumesAtTheSecondMilestone() {
        let d = suite()
        d.set(true, forKey: "com.momentum.review.asked.v1")
        AppReview.recordWorkoutSaved(defaults: d)
        #expect(!AppReview.shouldRequestReview(defaults: d, now: day(0)),
                "the 1st-item milestone was already spent before the upgrade")
        for _ in 0..<4 { AppReview.recordWorkoutSaved(defaults: d) }   // now at 5
        #expect(AppReview.shouldRequestReview(defaults: d, now: day(10)))
        var asks = 1
        for n in 1...40 {
            AppReview.recordWorkoutSaved(defaults: d)
            if AppReview.shouldRequestReview(defaults: d, now: day(20 + n * 10)) { asks += 1 }
        }
        #expect(asks == AppReview.maxAsks - 1, "a legacy install gets the two remaining chances")
    }

    // MARK: The onboarding beat's debit

    @Test func revisitingOnboardingDoesNotSpendLaterReviewOpportunities() {
        let d = suite()
        AppReview.recordOnboardingAsk(defaults: d, now: day(0))
        AppReview.recordOnboardingAsk(defaults: d, now: day(0))
        AppReview.recordOnboardingAsk(defaults: d, now: day(1))
        AppReview.recordOnboardingAsk(defaults: d, now: day(2))
        #expect(d.integer(forKey: "com.momentum.review.asks.v2") == 1)
        #expect(d.object(forKey: "com.momentum.review.lastAsk.v2") as? Date == day(0))
        for _ in 0..<5 { AppReview.recordWorkoutSaved(defaults: d) }
        #expect(AppReview.shouldRequestReview(defaults: d, now: day(3)),
                "returning to onboarding must not consume or postpone the fifth-item opportunity")
    }

    /// The beat spends one slot, so the athlete is NOT asked again the first time they save a
    /// workout — the cards resume at the 5th logged item.
    @Test func theOnboardingAskSpendsOneSlotAndPushesTheCardsToTheNextMilestone() {
        let d = suite()
        AppReview.recordOnboardingAsk(defaults: d, now: day(0))
        AppReview.recordWorkoutSaved(defaults: d)
        #expect(!AppReview.shouldRequestReview(defaults: d, now: day(9)),
                "the 1st-item card would be a second ask in a week")
        for _ in 0..<4 { AppReview.recordWorkoutSaved(defaults: d) }   // now at 5
        #expect(AppReview.shouldRequestReview(defaults: d, now: day(9)),
                "the 5th-item card is still owed")
    }

    /// Never more than Apple's three, counting the onboarding one.
    @Test func theOnboardingAskCountsAgainstTheThreePerYearCeiling() {
        let d = suite()
        AppReview.recordOnboardingAsk(defaults: d, now: day(0))
        var asks = 1
        for n in 1...60 {
            AppReview.recordWorkoutSaved(defaults: d)
            AppReview.recordMealLogged(defaults: d)
            if AppReview.shouldRequestReview(defaults: d, now: day(n * 10)) { asks += 1 }
        }
        #expect(asks == AppReview.maxAsks)
    }

    /// It records an ASK, never a rating: iOS reports nothing about what happened in the sheet, so
    /// latching `rated` here would silence the two remaining cards on a guess.
    @Test func theOnboardingAskNeverClaimsTheAthleteRated() {
        let d = suite()
        AppReview.recordOnboardingAsk(defaults: d, now: day(0))
        for _ in 0..<5 { AppReview.recordWorkoutSaved(defaults: d) }
        #expect(AppReview.shouldRequestReview(defaults: d, now: day(30)),
                "a spent slot must not read as a completed review")
    }

    /// An athlete who already rated in a previous version is not debited by reaching the beat.
    @Test func theOnboardingAskIsANoOpOnceTheAthleteHasRated() {
        let d = suite()
        AppReview.recordRated(defaults: d)
        AppReview.recordOnboardingAsk(defaults: d, now: day(0))
        #expect(d.object(forKey: "com.momentum.review.lastAsk.v2") == nil)
    }
}
