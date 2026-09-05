import Foundation
import Testing
@testable import Momentum

@MainActor
struct MotionPresentationTests {
    @Test func coachNavigationWaitsForTheCoverAndIsConsumedOnce() {
        let coach = CoachPresenter()
        coach.open()
        coach.navigate(.planSettings)

        #expect(!coach.isPresented)
        #expect(coach.consumeNavigation() == nil)
        #expect(coach.pendingNav == .planSettings)
        #expect(coach.consumeNavigation(afterDismissal: true) == .planSettings)
        #expect(coach.consumeNavigation(afterDismissal: true) == nil)
    }

    @Test func notificationNavigationDoesNotNeedACoachDismissal() {
        let coach = CoachPresenter()
        coach.navigate(.viewProgress)
        #expect(coach.consumeNavigation() == .viewProgress)
        #expect(coach.consumeNavigation() == nil)
    }

    @Test func repeatedRequestsDuringDismissalStayDeferred() {
        let coach = CoachPresenter()
        coach.open()
        coach.navigate(.viewPlanWeek)
        coach.navigate(.planSettings)
        #expect(coach.consumeNavigation() == nil)
        #expect(coach.consumeNavigation(afterDismissal: true) == .planSettings)
    }

    @Test func reopeningCoachCancelsAnOldDestination() {
        let coach = CoachPresenter()
        coach.open()
        coach.navigate(.planSettings)
        coach.open()
        #expect(coach.consumeNavigation(afterDismissal: true) == nil)
        #expect(coach.isPresented)
    }

    @Test func readingAnEntranceDoesNotSpendIt() {
        let id = "motion-test-\(UUID())"
        #expect(!RevealOnce.contains(id))
        #expect(!RevealOnce.contains(id))
        #expect(RevealOnce.claim(id))
        #expect(RevealOnce.contains(id))
        #expect(!RevealOnce.claim(id))
    }

    @Test func suspendingCoachCancelsPendingNavigation() {
        let coach = CoachPresenter()
        coach.open()
        coach.navigate(.planSettings)
        coach.isSuspended = true
        #expect(coach.consumeNavigation(afterDismissal: true) == nil)
    }
}
