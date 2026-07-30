import Testing
import Foundation
@testable import Momentum

/// The Podium outlook can only say what the feasibility verdict's own improvement model allows —
/// these pin that honesty (and the sandbagging/fantasy edge cases).
struct PodiumOutlookTests {

    @Test func reachableGoalIsTheTarget() {
        // ~25:00 5K fitness (300 s/km), marathon in 16 weeks, modest goal well within the cap.
        let now = PlanFeasibility.predictedFinishS(distanceM: RaceDistance.marathon.meters, p5kSPerKm: 300)
        let goal = now * 0.95   // 5% faster — inside `.some`'s 12% cycle cap
        let proj = PodiumOutlook.raceProjection(raceDistanceM: RaceDistance.marathon.meters, p5kSPerKm: 300,
                                                goalFinishTimeS: goal, experience: .some, weeks: 16)
        #expect(proj != nil)
        #expect(abs((proj?.builtS ?? 0) - goal) < 1)
        #expect(abs((proj?.nowS ?? 0) - now) < 1)
    }

    @Test func fantasyGoalGetsTheCappedAchievableNotTheDream() {
        let now = PlanFeasibility.predictedFinishS(distanceM: RaceDistance.marathon.meters, p5kSPerKm: 300)
        let dream = now * 0.6   // 40% faster — far beyond any cycle cap
        let proj = PodiumOutlook.raceProjection(raceDistanceM: RaceDistance.marathon.meters, p5kSPerKm: 300,
                                                goalFinishTimeS: dream, experience: .some, weeks: 16)
        // The outlook reads improvement at the Podium push (its only caller), so the honest floor is
        // `.some`'s cap scaled by that tier's factor — still a hard ceiling the dream sits far under.
        let cappedFloor = now * (1 - 0.15 * PlanIntensity.podium.improvementFactor)
        #expect((proj?.builtS ?? 0) > dream, "the outlook must not promise the dream")
        #expect((proj?.builtS ?? 0) >= cappedFloor - 1, "…and never more than the model's cap")
    }

    @Test func sandbaggedGoalNeverDragsTheOutlookBackward() {
        let now = PlanFeasibility.predictedFinishS(distanceM: RaceDistance.tenK.meters, p5kSPerKm: 300)
        let proj = PodiumOutlook.raceProjection(raceDistanceM: RaceDistance.tenK.meters, p5kSPerKm: 300,
                                                goalFinishTimeS: now * 1.4, experience: .some, weeks: 12)
        #expect((proj?.builtS ?? .infinity) <= (proj?.nowS ?? 0) + 0.001,
                "built must never be slower than today")
    }

    @Test func openBlockProjectsTheFiveKForward() {
        let proj = PodiumOutlook.fiveKProjection(p5kSPerKm: 300, experience: .some, weeks: 6)
        #expect(proj != nil)
        #expect(abs((proj?.nowS ?? 0) - 1500) < 0.001)                     // 25:00 today
        #expect((proj?.builtS ?? .infinity) < 1500)                        // moves forward
        #expect((proj?.builtS ?? 0) >= 1500 * (1 - 0.12) - 0.001)          // inside the cycle cap
    }

    @Test func newRunnersProjectMoreImprovementThanTrainedOnes() {
        let newer = PodiumOutlook.fiveKProjection(p5kSPerKm: 360, experience: .new, weeks: 10)
        let trained = PodiumOutlook.fiveKProjection(p5kSPerKm: 360, experience: .experienced, weeks: 10)
        let newGain = 1 - (newer!.builtS / newer!.nowS)
        let trainedGain = 1 - (trained!.builtS / trained!.nowS)
        #expect(newGain > trainedGain)
    }

    @Test func degenerateInputsDecline() {
        #expect(PodiumOutlook.raceProjection(raceDistanceM: 0, p5kSPerKm: 300, goalFinishTimeS: nil,
                                             experience: .some, weeks: 12) == nil)
        #expect(PodiumOutlook.fiveKProjection(p5kSPerKm: 0, experience: .some, weeks: 12) == nil)
        #expect(PodiumOutlook.fiveKProjection(p5kSPerKm: 300, experience: .some, weeks: 0) == nil)
    }
}
