import Testing
import Foundation
@testable import Momentum

/// The route rungs of `RunVerdict` — what a run meant *for this route*, which is the comparison a
/// runner actually makes and the one the engine could not make until `RouteMatch` existed.
///
/// The bar every case here holds the engine to: it may never claim more than the evidence supports,
/// and it may never hand a slower run back as a deficit. The clock is on screen directly above this
/// line; repeating it in words is not honesty.
struct RunVerdictRouteTests {

    private static let day0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func run(_ daysAgo: Double, km: Double, minutes: Double, hr: Int? = nil) -> RunVerdict.Run {
        RunVerdict.Run(date: Self.day0.addingTimeInterval(-daysAgo * 24 * 3600),
                       distanceM: km * 1000, durationS: minutes * 60, avgHR: hr)
    }

    private func route(_ priors: [RunVerdict.Run], isLoop: Bool = true) -> RunVerdict.RouteContext {
        RunVerdict.RouteContext(priors: priors, isLoop: isLoop)
    }

    private func line(_ today: RunVerdict.Run, _ ctx: RunVerdict.RouteContext,
                      unit: DistanceUnit = .metric) -> RunVerdict.Verdict? {
        RunVerdict.verdict(for: today, priors: ctx.priors, route: ctx, unit: unit)
    }

    // MARK: Rung 1 — the route best

    @Test func fastestEverOnThisRouteLeadsAndIsEarned() {
        let today = run(0, km: 8, minutes: 40)
        let v = line(today, route([run(7, km: 8, minutes: 44), run(14, km: 8, minutes: 42)]))
        #expect(v?.text == "Fastest you've run this loop.")
        #expect(v?.tone == .earned)
    }

    @Test func aPointToPointRouteIsCalledARouteNotALoop() {
        let today = run(0, km: 8, minutes: 40)
        let v = line(today, route([run(7, km: 8, minutes: 44), run(14, km: 8, minutes: 42)], isLoop: false))
        #expect(v?.text == "Fastest you've run this route.")
    }

    @Test func theBestOfTwoOutingsIsNotCalledARouteBest() {
        // One prior is not a route you know, it is a route you have been on twice. The engine drops
        // to the plain comparison rather than crowning a coin flip.
        let today = run(0, km: 8, minutes: 40)
        let v = line(today, route([run(7, km: 8, minutes: 44)]))
        #expect(v?.text.contains("Fastest you've run") == false)
        #expect(v?.text == "Second time on this loop. 30s/km faster than last time.")
    }

    // MARK: Rung 2 — the podium

    @Test func secondFastestOnTheRouteIsNamedOnceThereIsAFieldOfFour() {
        let priors = [run(7, km: 8, minutes: 38), run(14, km: 8, minutes: 44), run(21, km: 8, minutes: 45)]
        #expect(line(run(0, km: 8, minutes: 40), route(priors))?.text == "Your 2nd-fastest on this loop.")
    }

    @Test func thirdFastestIsNamedOnceThereIsAFieldOfSix() {
        let priors = [run(7, km: 8, minutes: 38), run(14, km: 8, minutes: 39), run(21, km: 8, minutes: 44),
                      run(28, km: 8, minutes: 45), run(35, km: 8, minutes: 46)]
        #expect(line(run(0, km: 8, minutes: 40), route(priors))?.text == "Your 3rd-fastest on this loop.")
    }

    @Test func aPodiumPlacingNeedsAFieldToPlaceIn() {
        // Second of two is just a roundabout way of saying slower, so it is never claimed.
        #expect(line(run(0, km: 8, minutes: 42), route([run(7, km: 8, minutes: 40)]))?
            .text.contains("fastest") == false)
        // Nor is third of four, where more of the field is ahead of you than behind.
        let shallow = [run(7, km: 8, minutes: 38), run(14, km: 8, minutes: 39), run(21, km: 8, minutes: 50)]
        #expect(line(run(0, km: 8, minutes: 40), route(shallow))?.text.contains("fastest") == false)
    }

    // MARK: Rung 3 — faster than last time here

    @Test func aClearGainOnTheLastOutingIsReported() {
        let priors = [run(7, km: 8, minutes: 44), run(14, km: 8, minutes: 36), run(21, km: 8, minutes: 37)]
        let v = line(run(0, km: 8, minutes: 42), route(priors))
        #expect(v?.text == "Fourth time on this loop. 15s/km faster than last time.")
        #expect(v?.tone == .gain)
    }

    @Test func theGainIsPhrasedInTheUnitOnScreen() {
        let priors = [run(7, km: 8, minutes: 44), run(14, km: 8, minutes: 36), run(21, km: 8, minutes: 37)]
        let v = line(run(0, km: 8, minutes: 42), route(priors), unit: .imperial)
        #expect(v?.text == "Fourth time on this loop. 24s/mi faster than last time.")
    }

    @Test func aGainInsideTheNoiseFloorIsNotClaimed() {
        // Two seconds a kilometre is a traffic light, not fitness.
        let priors = [run(7, km: 8, minutes: 40.2), run(14, km: 8, minutes: 36), run(21, km: 8, minutes: 37)]
        #expect(line(run(0, km: 8, minutes: 40), route(priors))?.text.contains("faster than last time") == false)
    }

    // MARK: Rung 4 — the same road at a lower heart rate

    @Test func sameRoadLowerHeartRateIsTheHonestReadOnARunThatWasNotFaster() {
        let priors = [run(7, km: 8, minutes: 40, hr: 158), run(14, km: 8, minutes: 36, hr: 165),
                      run(21, km: 8, minutes: 37, hr: 163)]
        let v = line(run(0, km: 8, minutes: 40.8, hr: 150), route(priors))
        #expect(v?.text == "Fourth time on this loop, at 8 fewer beats than last time.")
        #expect(v?.tone == .gain)
    }

    @Test func anEasyDayIsNotDressedUpAsEfficiency() {
        // Much slower with a lower heart rate is a recovery run, not a fitter engine. Claiming it
        // would be flattery the athlete can feel.
        let priors = [run(7, km: 8, minutes: 40, hr: 158), run(14, km: 8, minutes: 36, hr: 165),
                      run(21, km: 8, minutes: 37, hr: 163)]
        let v = line(run(0, km: 8, minutes: 48, hr: 132), route(priors))
        #expect(v?.text.contains("fewer beats") == false)
    }

    @Test func aHeartRateDropInsideNormalVariationIsNotClaimed() {
        let priors = [run(7, km: 8, minutes: 40, hr: 158), run(14, km: 8, minutes: 36, hr: 165),
                      run(21, km: 8, minutes: 37, hr: 163)]
        #expect(line(run(0, km: 8, minutes: 40.5, hr: 156), route(priors))?.text.contains("fewer beats") == false)
    }

    @Test func missingHeartRateSimplyDropsTheRungRatherThanTheVerdict() {
        let priors = [run(7, km: 8, minutes: 40), run(14, km: 8, minutes: 36), run(21, km: 8, minutes: 37)]
        let v = line(run(0, km: 8, minutes: 40.5), route(priors))
        #expect(v != nil)
        #expect(v?.text.contains("fewer beats") == false)
    }

    // MARK: Rung 5 — within touching distance of the best

    @Test func closeToTheRouteBestIsWorthSaying() {
        // Off the podium (four earlier outings were quicker) but a hair off the best of them.
        let priors = [run(7, km: 8, minutes: 40), run(14, km: 8, minutes: 40.2),
                      run(21, km: 8, minutes: 40.4), run(28, km: 8, minutes: 40.5)]
        let v = line(run(0, km: 8, minutes: 40.7), route(priors))
        #expect(v?.text == "Fifth time on this loop. Within 5s/km of your best here.")
        #expect(v?.tone == .steady)
    }

    // MARK: Rung 6 — the bare fact, which is never a rebuke

    @Test func aSlowerRunGetsTheRepetitionAndNoDeficit() {
        let priors = [run(7, km: 8, minutes: 38), run(14, km: 8, minutes: 36), run(21, km: 8, minutes: 37)]
        let v = line(run(0, km: 8, minutes: 46), route(priors))
        #expect(v?.text == "Fourth time on this loop.")
        #expect(v?.tone == .steady)
        for word in ["slower", "off your", "behind", "down on"] {
            #expect(v?.text.lowercased().contains(word) == false)
        }
    }

    // MARK: Counting

    @Test func theOutingIsCountedInWordsThenDigits() {
        func plain(_ priorCount: Int) -> String? {
            // All priors far faster, so every case lands on the bare repetition rung.
            let priors = (1...priorCount).map { run(Double($0) * 7, km: 8, minutes: 30) }
            return line(run(0, km: 8, minutes: 46), route(priors))?.text
        }
        #expect(plain(1) == "Second time on this loop.")
        #expect(plain(8) == "Ninth time on this loop.")
        #expect(plain(19) == "Twentieth time on this loop.")
        #expect(plain(20) == "21st time on this loop.")
        #expect(plain(21) == "22nd time on this loop.")
        #expect(plain(22) == "23rd time on this loop.")
        #expect(plain(23) == "24th time on this loop.")
        #expect(plain(110) == "111th time on this loop.")   // the teens exception
    }

    // MARK: Precedence and safety

    @Test func theRouteLadderOutranksTheDistanceLadder() {
        // Same ground is a test; same distance is a coincidence. A run that would read as a
        // distance PR must still be judged against the route when one is known.
        let today = run(0, km: 8, minutes: 42)
        let distancePriors = [run(7, km: 8, minutes: 50), run(14, km: 8, minutes: 52)]
        #expect(RunVerdict.verdict(for: today, priors: distancePriors, unit: .metric)?.text
                == "Your fastest at this distance.")
        let routePriors = [run(3, km: 8, minutes: 38), run(10, km: 8, minutes: 37), run(17, km: 8, minutes: 39)]
        #expect(RunVerdict.verdict(for: today, priors: distancePriors + routePriors,
                                   route: route(routePriors), unit: .metric)?.text
                == "Fourth time on this loop.")
    }

    @Test func routePriorsDatedAfterTheRunAreIgnored() {
        let today = run(0, km: 8, minutes: 40)
        let future = RunVerdict.Run(date: Self.day0.addingTimeInterval(3600), distanceM: 8_000, durationS: 2_000)
        // Only the future run "matches" the route, so the ladder has nothing and falls through.
        let v = RunVerdict.verdict(for: today, priors: [], route: route([future]), unit: .metric)
        #expect(v?.text == "Your first one on the board. Everything after this has something to measure against.")
    }

    @Test func anEmptyRouteContextFallsThroughToTheDistanceLadder() {
        let today = run(0, km: 10, minutes: 50)
        let priors = [run(7, km: 10, minutes: 55), run(14, km: 10, minutes: 52)]
        #expect(RunVerdict.verdict(for: today, priors: priors, route: route([]), unit: .metric)?.text
                == "Your fastest at this distance.")
    }

    @Test func aRunWithNoPaceSaysNothingAtAll() {
        let broken = RunVerdict.Run(date: Self.day0, distanceM: 0, durationS: 0)
        #expect(RunVerdict.verdict(for: broken, priors: [], route: route([run(7, km: 8, minutes: 40)]),
                                   unit: .metric) == nil)
    }

    // MARK: What survives being reopened in December

    @Test func routeVerdictsAreTimelessAndTheWeeklyCountIsNot() {
        let priors = [run(7, km: 8, minutes: 44), run(14, km: 8, minutes: 42)]
        #expect(line(run(0, km: 8, minutes: 40), route(priors))?.isTimeless == true)
        #expect(line(run(0, km: 8, minutes: 60), route(priors))?.isTimeless == true)

        // The consistency fallback is the one line that expires.
        let weekly = RunVerdict.verdict(for: run(0, km: 5, minutes: 40),
                                        priors: [run(2, km: 12, minutes: 60)], unit: .metric)
        #expect(weekly?.isTimeless == false)
        #expect(RunVerdict.verdict(for: run(0, km: 10, minutes: 50),
                                   priors: [run(7, km: 10, minutes: 55)], unit: .metric)?.isTimeless == true)
    }

    // MARK: Voice

    @MainActor
    @Test func everyRouteVerdictSpeaksLikeACoach() {
        let ladders: [[RunVerdict.Run]] = [
            [run(7, km: 8, minutes: 44), run(14, km: 8, minutes: 42)],
            [run(7, km: 8, minutes: 38), run(14, km: 8, minutes: 44), run(21, km: 8, minutes: 45)],
            [run(7, km: 8, minutes: 44, hr: 160), run(14, km: 8, minutes: 36, hr: 166), run(21, km: 8, minutes: 37, hr: 164)],
            [run(7, km: 8, minutes: 30)],
        ]
        let todays = [run(0, km: 8, minutes: 40, hr: 150), run(0, km: 8, minutes: 46, hr: 148),
                      run(0, km: 8, minutes: 36, hr: 170)]
        for (i, priors) in ladders.enumerated() {
            for (j, today) in todays.enumerated() {
                for isLoop in [true, false] {
                    for unit in [DistanceUnit.metric, .imperial] {
                        guard let v = line(today, route(priors, isLoop: isLoop), unit: unit) else { continue }
                        CoachVoiceTests.assertCoachVoice(v.text, "RunVerdict.route[\(i)][\(j)](\(unit))")
                    }
                }
            }
        }
    }
}
