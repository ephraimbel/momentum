import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Session pace review (running-excellence R4): the deterministic verdict on ONE guided run's
/// recorded reps, and the consent-gated pace easing it can offer. Pure fixtures — the same numbers
/// the summary card renders.
@MainActor
struct SessionPaceReviewTests {

    private func rep(_ i: Int, of n: Int = 4, target: Double = 300, achieved: Double,
                     distanceM: Double = 400) -> RepResult {
        RepResult(repIndex: i, repTotal: n, title: nil, targetPaceSPerKm: target,
                  achievedPaceSPerKm: achieved, distanceM: distanceM, durationS: achieved * distanceM / 1000)
    }

    @Test func withinToleranceIsOnPoint() {
        let a = SessionPaceReview.analyze([rep(1, achieved: 305), rep(2, achieved: 296),
                                           rep(3, achieved: 308), rep(4, achieved: 299)], unit: .metric)
        #expect(a?.verdict == .onPoint)
        #expect(a?.suggestsEasing == false)
        #expect(a?.repsReviewed == 4)
    }

    @Test func consistentlyFasterIsAhead() {
        let a = SessionPaceReview.analyze([rep(1, achieved: 282), rep(2, achieved: 280),
                                           rep(3, achieved: 285), rep(4, achieved: 283)], unit: .metric)
        #expect(a?.verdict == .ahead)
        #expect((a?.meanDeltaSPerKm ?? 0) < -12)
        #expect(a?.suggestsEasing == false)
    }

    @Test func consistentlySlowerIsReviewAndOffersEasing() {
        let a = SessionPaceReview.analyze([rep(1, achieved: 318), rep(2, achieved: 322),
                                           rep(3, achieved: 316), rep(4, achieved: 320)], unit: .metric)
        #expect(a?.verdict == .review)
        #expect(a?.suggestsEasing == true)
    }

    @Test func bigRepToRepSwingIsVariable() {
        let a = SessionPaceReview.analyze([rep(1, achieved: 275), rep(2, achieved: 300),
                                           rep(3, achieved: 322), rep(4, achieved: 290)], unit: .metric)
        #expect(a?.verdict == .variable)
        #expect(a?.suggestsEasing == false)
    }

    @Test func nothingReviewableReturnsNil() {
        // Target-less reps (run-walk "by feel") and instant-skip slivers → no card, no noise.
        let noTarget = RepResult(repIndex: 1, repTotal: 2, title: nil, targetPaceSPerKm: nil,
                                 achievedPaceSPerKm: 300, distanceM: 400, durationS: 120)
        let sliver = rep(2, achieved: 300, distanceM: 8)
        #expect(SessionPaceReview.analyze([noTarget, sliver], unit: .metric) == nil)
        #expect(SessionPaceReview.analyze([], unit: .metric) == nil)
    }

    @Test func pausedRepIsDiscardedNotClassified() {
        // A "rep" at walking-lost-GPS pace (2.5× target) must not poison the verdict.
        let a = SessionPaceReview.analyze([rep(1, achieved: 300), rep(2, achieved: 900)], unit: .metric)
        #expect(a?.repsReviewed == 1)
        #expect(a?.verdict == .onPoint)
    }

    // MARK: Consent-gated easing

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    @Test func easingBumpsP5kTwoPercentAndRederivesFuturePaces() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = UserProfile(); ctx.insert(profile)
        let plan = TrainingPlan(); ctx.insert(plan)
        profile.plan = plan
        plan.p5kSPerKm = 300

        let future = PlannedSession()
        future.date = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        future.discipline = .running
        future.runType = .tempo
        future.status = .planned
        future.targetPaceSPerKm = PlanEngine.pace(.tempo, p5k: 300)
        ctx.insert(future)
        let past = PlannedSession()
        past.date = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
        past.discipline = .running
        past.runType = .intervals
        past.status = .completed
        past.targetPaceSPerKm = PlanEngine.pace(.intervals, p5k: 300)
        ctx.insert(past)
        plan.sessions = [future, past]
        try ctx.save()

        let updated = PlanCoaching.easeQualityPaces(plan, in: ctx)

        #expect(updated == 1)                                    // history untouched
        #expect(abs(plan.p5kSPerKm - 306) < 0.01)                // +2%, bounded
        #expect(abs((future.targetPaceSPerKm ?? 0) - PlanEngine.pace(.tempo, p5k: 306)) < 0.01)
        #expect(abs((past.targetPaceSPerKm ?? 0) - PlanEngine.pace(.intervals, p5k: 300)) < 0.01)
    }

    @Test func easingWithNothingUpcomingChangesNothing() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let plan = TrainingPlan(); ctx.insert(plan)
        plan.p5kSPerKm = 300
        try ctx.save()
        #expect(PlanCoaching.easeQualityPaces(plan, in: ctx) == 0)
        #expect(abs(plan.p5kSPerKm - 300) < 0.01)                // p5k held — no silent drift
    }
}
