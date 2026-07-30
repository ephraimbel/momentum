import Testing
import Foundation
@testable import Momentum

/// The rating-prompt gate. Guideline 5.6.3 got the app rejected for asking during onboarding, so the
/// contract here is exact: never before real engagement, and never more than once.
struct AppReviewTests {

    /// An isolated defaults suite per test — never touch `.standard`.
    private func suite(_ name: String = #function) -> UserDefaults {
        let d = UserDefaults(suiteName: "AppReviewTests.\(name)")!
        AppReview.reset(defaults: d)
        return d
    }

    @Test func doesNotAskBeforeTheEngagementThreshold() {
        let d = suite()
        for _ in 0..<(AppReview.engagementThreshold - 1) {
            AppReview.recordWorkoutSaved(defaults: d)
            #expect(!AppReview.shouldRequestReview(defaults: d))
        }
    }

    @Test func asksExactlyOnceAtTheThreshold() {
        let d = suite()
        for _ in 0..<AppReview.engagementThreshold { AppReview.recordWorkoutSaved(defaults: d) }
        #expect(AppReview.shouldRequestReview(defaults: d), "the threshold save should open the ask")
        // Every subsequent check — and every subsequent save — must stay silent.
        #expect(!AppReview.shouldRequestReview(defaults: d))
        AppReview.recordWorkoutSaved(defaults: d)
        #expect(!AppReview.shouldRequestReview(defaults: d))
    }

    /// iOS may decline to show the prompt, but we must never re-ask: the latch fires on our REQUEST,
    /// not on whether the system honoured it.
    @Test func neverAsksTwiceEvenIfTheSystemShowedNothing() {
        let d = suite()
        for _ in 0..<10 { AppReview.recordWorkoutSaved(defaults: d) }
        var asks = 0
        for _ in 0..<10 where AppReview.shouldRequestReview(defaults: d) { asks += 1 }
        #expect(asks == 1)
    }

    /// A brand-new athlete — the first-launch / onboarding case Apple flagged — is never asked.
    @Test func aFreshInstallIsNeverAsked() {
        let d = suite()
        #expect(!AppReview.shouldRequestReview(defaults: d))
    }

    /// Discards and imports simply don't call `recordWorkoutSaved`, so a user who records and throws
    /// away workouts never crosses the bar. Modelled here by never counting.
    @Test func withoutRecordedSavesTheGateStaysClosed() {
        let d = suite()
        for _ in 0..<20 { _ = AppReview.shouldRequestReview(defaults: d) }
        #expect(!AppReview.shouldRequestReview(defaults: d))
    }
}
