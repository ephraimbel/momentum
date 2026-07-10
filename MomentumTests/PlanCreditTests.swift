import Testing
@testable import Momentum

/// The magnitude-aware plan-credit matcher: a free workout only completes a planned session it
/// plausibly fulfills — the guard against a recovery jog silently deleting the week's long run.
struct PlanCreditTests {

    @Test func shortJogNeverCreditsLongRun() {
        // 1 km jog vs a 15 km long run — the headline bug this engine exists to prevent.
        let match = PlanCredit.bestMatch(distanceM: 1_000, durationS: 360,
                                         candidates: [.init(targetDistanceM: 15_000)])
        #expect(match == nil)
    }

    @Test func fulfilledPrescriptionCredits() {
        // 14 km of a 15 km prescription is that session, done.
        let match = PlanCredit.bestMatch(distanceM: 14_000, durationS: 4_800,
                                         candidates: [.init(targetDistanceM: 15_000)])
        #expect(match == 0)
    }

    @Test func overDeliveryStillCredits() {
        // Running further than prescribed always counts.
        let match = PlanCredit.bestMatch(distanceM: 8_000, durationS: 2_400,
                                         candidates: [.init(targetDistanceM: 5_000)])
        #expect(match == 0)
    }

    @Test func closestFitWinsAcrossTwoSessions() {
        // Easy 5k at index 0, long 15k at index 1 — a 14 km run belongs to the long run even though
        // the easy session comes first in the day.
        let candidates: [PlanCredit.Candidate] = [.init(targetDistanceM: 5_000),
                                                  .init(targetDistanceM: 15_000)]
        #expect(PlanCredit.bestMatch(distanceM: 14_000, durationS: 4_800, candidates: candidates) == 1)
        // …and a 5 km run belongs to the easy session, leaving the long run open.
        #expect(PlanCredit.bestMatch(distanceM: 5_200, durationS: 1_800, candidates: candidates) == 0)
    }

    @Test func durationTargetUsedWhenNoDistance() {
        // A cross-training swap (40 min ride) is credited by time.
        let candidates: [PlanCredit.Candidate] = [.init(targetDurationS: 2_400)]
        #expect(PlanCredit.bestMatch(distanceM: 0, durationS: 2_300, candidates: candidates) == 0)
        #expect(PlanCredit.bestMatch(distanceM: 0, durationS: 600, candidates: candidates) == nil)
    }

    @Test func untargetedSessionIsTheFallback() {
        // A strength day carries no distance/duration target — any real workout satisfies it, but
        // only when no targeted session fits better.
        let candidates: [PlanCredit.Candidate] = [.init(), .init(targetDistanceM: 5_000)]
        #expect(PlanCredit.bestMatch(distanceM: 5_000, durationS: 1_800, candidates: candidates) == 1)
        #expect(PlanCredit.bestMatch(distanceM: 1_000, durationS: 900, candidates: candidates) == 0)
    }

    @Test func boundaryAtSeventyPercent() {
        let c: [PlanCredit.Candidate] = [.init(targetDistanceM: 10_000)]
        #expect(PlanCredit.bestMatch(distanceM: 7_000, durationS: 0, candidates: c) == 0)
        #expect(PlanCredit.bestMatch(distanceM: 6_900, durationS: 0, candidates: c) == nil)
    }
}
