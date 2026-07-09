import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Pace Insights (running-excellence R4): the tracker's step-result recording, the deterministic
/// achieved-vs-prescribed classification, and the consent-gated pace easing. Pure fixtures — the
/// same numbers the card renders.
@MainActor
struct PaceInsightsTests {

    // MARK: Tracker records step results

    @Test func trackerRecordsResultsAsStepsComplete() {
        let session = StructuredWorkoutBuilder.intervals(reps: 2, repDistanceM: 400, intervalPaceSPerKm: 300)
        var t = StructuredRunTracker(steps: session.steps)

        // Warm-up (1000 m) crossed at 6:40 pace.
        t.advance(distanceM: 1000, elapsedS: 400)
        // Rep 1: 400 m in 118 s (295 s/km — on pace).
        t.advance(distanceM: 1400, elapsedS: 518)
        // Recovery (90 s timed) while jogging 150 m.
        t.advance(distanceM: 1550, elapsedS: 608)
        // Rep 2: 400 m in 126 s (315 s/km).
        t.advance(distanceM: 1950, elapsedS: 734)
        // Skip the cool-down early.
        t.skip(distanceM: 2100, elapsedS: 800)

        #expect(t.isComplete)
        #expect(t.results.count == 5)
        let reps = t.results.filter { $0.kind == "work" }
        #expect(reps.count == 2)
        #expect(abs((reps[0].achievedPaceSPerKm ?? 0) - 295) < 0.5)
        #expect(abs((reps[1].achievedPaceSPerKm ?? 0) - 315) < 0.5)
        #expect(t.results.last?.skipped == true)
        #expect(t.results.filter(\.skipped).count == 1)
    }

    @Test func stepResultsSurviveAJSONRoundTrip() throws {
        let result = StepResult(kind: "work", targetPaceSPerKm: 300, toleranceSPerKm: 12,
                                repIndex: 2, repTotal: 6, distanceM: 400, durationS: 121, skipped: false)
        let data = try JSONEncoder().encode([result])
        let back = try JSONDecoder().decode([StepResult].self, from: data)
        #expect(back == [result])
    }

    // MARK: Classification

    private func rep(_ i: Int, of n: Int = 4, target: Double = 300, achieved: Double) -> StepResult {
        StepResult(kind: "work", targetPaceSPerKm: target, toleranceSPerKm: 12,
                   repIndex: i, repTotal: n, distanceM: 400, durationS: achieved * 0.4, skipped: false)
    }

    @Test func withinToleranceIsOnPoint() {
        let a = PaceInsights.analyze([rep(1, achieved: 305), rep(2, achieved: 296),
                                      rep(3, achieved: 308), rep(4, achieved: 299)], unit: .metric)
        #expect(a?.verdict == .onPoint)
        #expect(a?.suggestsEasing == false)
        #expect(a?.reps.count == 4)
    }

    @Test func consistentlyFasterIsAhead() {
        let a = PaceInsights.analyze([rep(1, achieved: 282), rep(2, achieved: 280),
                                      rep(3, achieved: 285), rep(4, achieved: 283)], unit: .metric)
        #expect(a?.verdict == .ahead)
        #expect((a?.meanDeltaSPerKm ?? 0) < -12)
        #expect(a?.suggestsEasing == false)
    }

    @Test func consistentlySlowerIsReviewAndOffersEasing() {
        let a = PaceInsights.analyze([rep(1, achieved: 318), rep(2, achieved: 322),
                                      rep(3, achieved: 316), rep(4, achieved: 320)], unit: .metric)
        #expect(a?.verdict == .review)
        #expect(a?.suggestsEasing == true)
    }

    @Test func bigRepToRepSwingIsVariable() {
        let a = PaceInsights.analyze([rep(1, achieved: 275), rep(2, achieved: 300),
                                      rep(3, achieved: 322), rep(4, achieved: 290)], unit: .metric)
        #expect(a?.verdict == .variable)
        #expect(a?.suggestsEasing == false)
    }

    @Test func nothingReviewableReturnsNil() {
        // Only non-work / skipped / target-less steps → no card, no noise.
        let warmup = StepResult(kind: "warmup", targetPaceSPerKm: 380, toleranceSPerKm: 12,
                                repIndex: nil, repTotal: nil, distanceM: 1000, durationS: 400, skipped: false)
        var skipped = rep(1, achieved: 300); skipped.skipped = true
        let noTarget = StepResult(kind: "work", targetPaceSPerKm: nil, toleranceSPerKm: 12,
                                  repIndex: 1, repTotal: 2, distanceM: 400, durationS: 120, skipped: false)
        #expect(PaceInsights.analyze([warmup, skipped, noTarget], unit: .metric) == nil)
        #expect(PaceInsights.analyze([], unit: .metric) == nil)
    }

    @Test func pausedRepIsDiscardedNotClassified() {
        // A "rep" at walking-lost-GPS pace (2.5× target) must not poison the verdict.
        let a = PaceInsights.analyze([rep(1, achieved: 300), rep(2, achieved: 900)], unit: .metric)
        #expect(a?.reps.count == 1)
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
