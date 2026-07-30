import Testing
import Foundation
@testable import Momentum

/// The honesty engine — the thing generic plan apps skip. Verifies we tell the truth about whether a
/// goal fits the calendar, and recommend the right aggression.
struct PlanFeasibilityTests {

    @Test func noRaceGivesARollingPlan() {
        let f = PlanFeasibility.assess(raceDistanceM: nil, goalFinishTimeS: nil, currentP5kSPerKm: 330,
                                       currentWeeklyVolumeM: 20_000, weeksAvailable: 0, experience: .some)
        #expect(f.verdict == .noRace)
        #expect(f.options.isEmpty)
    }

    @Test func comfortableMarathonBuildIsOnTrack() {
        // A trained runner, 60 km/wk, 20 weeks out — plenty of room.
        let f = PlanFeasibility.assess(raceDistanceM: RaceDistance.marathon.meters, goalFinishTimeS: nil,
                                       currentP5kSPerKm: 300, currentWeeklyVolumeM: 60_000,
                                       weeksAvailable: 20, experience: .experienced)
        #expect(f.verdict == .onTrack)
        #expect(f.weeksNeeded <= f.weeksAvailable)
    }

    @Test func marathonInSixWeeksFromLowBaseIsTooShort() {
        // A near-beginner cannot safely build a marathon in 6 weeks — we say so and offer alternatives.
        let f = PlanFeasibility.assess(raceDistanceM: RaceDistance.marathon.meters, goalFinishTimeS: nil,
                                       currentP5kSPerKm: nil, currentWeeklyVolumeM: 15_000,
                                       weeksAvailable: 6, experience: .new)
        #expect(f.verdict == .tooShort)
        #expect(f.weeksNeeded > f.weeksAvailable)
        #expect(!f.options.isEmpty)                                  // honest paths forward
        #expect(f.recommended == .aggressive)                       // if they insist, push — but flagged
        #expect(f.options.contains { $0.localizedCaseInsensitiveContains("later") })
        #expect(f.options.contains { $0.localizedCaseInsensitiveContains("half") })
    }

    // MARK: Frequency honesty (days/week is a real constraint, not a preference)

    @Test func twoDaysTowardAMarathonIsCalledOut() {
        // The calendar is generous — the WEEK is the problem. 2 days vs a 4-day floor → tooShort,
        // with "add days" as the first move and no misdirected "move your race later".
        let f = PlanFeasibility.assess(raceDistanceM: RaceDistance.marathon.meters, goalFinishTimeS: nil,
                                       currentP5kSPerKm: 300, currentWeeklyVolumeM: 60_000,
                                       weeksAvailable: 20, experience: .experienced, daysPerWeek: 2)
        #expect(f.verdict == .tooShort)
        #expect(f.headline.contains("2 days"))
        #expect(f.options.first?.localizedCaseInsensitiveContains("4 days") == true)
        #expect(!f.options.contains { $0.localizedCaseInsensitiveContains("later") })   // calendar isn't the constraint
    }

    @Test func oneDayUnderTheFloorTightensTheVerdict() {
        // 3 days toward a marathon (floor 4): comfortable calendar → .tight, with the day named
        // as the cheapest fix — and the recommendation does NOT jump to aggressive (pushing
        // harder on fewer days doesn't close a frequency gap).
        let f = PlanFeasibility.assess(raceDistanceM: RaceDistance.marathon.meters, goalFinishTimeS: nil,
                                       currentP5kSPerKm: 300, currentWeeklyVolumeM: 60_000,
                                       weeksAvailable: 20, experience: .experienced, daysPerWeek: 3)
        #expect(f.verdict == .tight)
        #expect(f.recommended == .balanced)
        #expect(f.options.first?.localizedCaseInsensitiveContains("4") == true)
        #expect(f.detail.localizedCaseInsensitiveContains("3 days"))
    }

    @Test func enoughDaysLeavesTheVerdictAlone() {
        let base = PlanFeasibility.assess(raceDistanceM: RaceDistance.marathon.meters, goalFinishTimeS: nil,
                                          currentP5kSPerKm: 300, currentWeeklyVolumeM: 60_000,
                                          weeksAvailable: 20, experience: .experienced)
        let four = PlanFeasibility.assess(raceDistanceM: RaceDistance.marathon.meters, goalFinishTimeS: nil,
                                          currentP5kSPerKm: 300, currentWeeklyVolumeM: 60_000,
                                          weeksAvailable: 20, experience: .experienced, daysPerWeek: 4)
        #expect(base.verdict == .onTrack)
        #expect(four.verdict == .onTrack)
        #expect(four.headline == base.headline)
        // 5K floor is 3 — a 3-day 5K build is honest work, no note.
        let fiveK = PlanFeasibility.assess(raceDistanceM: RaceDistance.fiveK.meters, goalFinishTimeS: nil,
                                           currentP5kSPerKm: 300, currentWeeklyVolumeM: 30_000,
                                           weeksAvailable: 12, experience: .some, daysPerWeek: 3)
        #expect(fiveK.verdict == .onTrack)
    }

    @Test func ultraFrequencyFloorIsFive() {
        #expect(PlanFeasibility.minimumEffectiveDays(forDistanceM: RaceDistance.fiftyK.meters) == 5)
        let f = PlanFeasibility.assess(raceDistanceM: RaceDistance.fiftyK.meters, goalFinishTimeS: nil,
                                       currentP5kSPerKm: 280, currentWeeklyVolumeM: 70_000,
                                       weeksAvailable: 24, experience: .experienced, daysPerWeek: 3)
        #expect(f.verdict == .tooShort)   // two under the floor is maintenance, not an ultra build
    }

    @Test func noRaceIgnoresDays() {
        let f = PlanFeasibility.assess(raceDistanceM: nil, goalFinishTimeS: nil, currentP5kSPerKm: 330,
                                       currentWeeklyVolumeM: 20_000, weeksAvailable: 0,
                                       experience: .some, daysPerWeek: 2)
        #expect(f.verdict == .noRace)
        #expect(f.options.isEmpty)
    }

    @Test func fantasyGoalTimeIsCalledOutWithARealisticTarget() throws {
        // Current 5K ≈ 25:00; asking for 18:00 in 12 weeks isn't realistic — offer a real target.
        let f = PlanFeasibility.assess(raceDistanceM: RaceDistance.fiveK.meters, goalFinishTimeS: 1080,
                                       currentP5kSPerKm: 300, currentWeeklyVolumeM: 30_000,
                                       weeksAvailable: 12, experience: .some)
        #expect(f.verdict == .tooShort)
        let realistic = try #require(f.realisticFinishS)
        // Achievable time is faster than current (some improvement) but nowhere near the fantasy goal.
        #expect(realistic < 1500)          // faster than the current 25:00
        #expect(realistic > 1080)          // but not the fantasy 18:00
        #expect(f.options.contains { $0.localizedCaseInsensitiveContains("realistic") })
    }

    @Test func closeButBehindIsTight() {
        // Half from 25 km/wk with 13 weeks — needs ~15; within 80%, so it's "tight", favor aggressive.
        let f = PlanFeasibility.assess(raceDistanceM: RaceDistance.half.meters, goalFinishTimeS: nil,
                                       currentP5kSPerKm: 300, currentWeeklyVolumeM: 25_000,
                                       weeksAvailable: 13, experience: .some)
        #expect(f.verdict == .tight)
        #expect(f.recommended == .aggressive)
    }

    @Test func beginnerWithLotsOfRoomIsEasedIn() {
        let f = PlanFeasibility.assess(raceDistanceM: RaceDistance.fiveK.meters, goalFinishTimeS: nil,
                                       currentP5kSPerKm: nil, currentWeeklyVolumeM: 10_000,
                                       weeksAvailable: 16, experience: .new)
        #expect(f.verdict == .onTrack)
        #expect(f.recommended == .gentle)          // no reason to rush a new runner
    }

    @Test func riegelPredictionIsSane() {
        // 5:00/km → 5K in exactly 25:00.
        #expect(abs(PlanFeasibility.predictedFinishS(distanceM: 5_000, p5kSPerKm: 300) - 1500) < 0.5)
        // Marathon predicted slower per km than the 5K pace (fatigue), landing near a 4-hour range.
        let marathon = PlanFeasibility.predictedFinishS(distanceM: RaceDistance.marathon.meters, p5kSPerKm: 300)
        #expect(marathon > 3.5 * 3600 && marathon < 4.5 * 3600)
    }

    @Test func aThirtyMinuteMarathonPRIn12WeeksIsDoableOnceThePushIsHardEnough() {
        // The athlete's exact ask: a ~4:00 marathon → ~3:30 (a ~12.5% jump) with 12 weeks. Honest at
        // Balanced — that rate of gain isn't a stroll — but a real, DOABLE goal the moment they
        // commit to pushing. "How hard do you want to push" has to move the verdict; 12 weeks IS
        // enough when the training ramps faster.
        let p5k = 300.0
        let now = PlanFeasibility.predictedFinishS(distanceM: RaceDistance.marathon.meters, p5kSPerKm: p5k)
        let goal = now * 0.875   // ~12.5% faster — the 4:00 → 3:30 kind of jump
        func verdict(_ push: PlanIntensity) -> PlanFeasibility.Verdict {
            PlanFeasibility.assess(raceDistanceM: RaceDistance.marathon.meters, goalFinishTimeS: goal,
                                   currentP5kSPerKm: p5k, currentWeeklyVolumeM: 45_000, weeksAvailable: 12,
                                   experience: .some, daysPerWeek: 5, intensity: push).verdict
        }
        #expect(verdict(.balanced) == .tooShort)        // we won't pretend at a moderate push…
        #expect(verdict(.aggressive) != .tooShort)       // …but pushing harder makes it reachable
        #expect(verdict(.podium) != .tooShort)
        // The honest nudge for a stretch goal is Aggressive — never Podium (a commitment, not advice).
        let f = PlanFeasibility.assess(raceDistanceM: RaceDistance.marathon.meters, goalFinishTimeS: goal,
                                       currentP5kSPerKm: p5k, currentWeeklyVolumeM: 45_000, weeksAvailable: 12,
                                       experience: .some, daysPerWeek: 5)
        #expect(f.recommended == .aggressive)
    }

    @Test func aRealRaceTimeIsNotReTaxedIntoImpossibility() {
        // A marathoner enters their actual 4:00 marathon. The "now" must honor it — not round-trip it
        // through a 5K-equivalent pace and re-apply the endurance tax, which paints them ~4:11 and
        // turns a real 3:30 push into "impossible."
        let fourHours = 4.0 * 3_600
        let goal = 3.5 * 3_600   // 3:30
        let p5k = PlanEngine.riegelP5k(distanceM: RaceDistance.marathon.meters, timeS: fourHours)  // the lossy value
        func assess(honoringRealTime: Bool) -> PlanFeasibility {
            PlanFeasibility.assess(raceDistanceM: RaceDistance.marathon.meters, goalFinishTimeS: goal,
                                   currentP5kSPerKm: p5k, currentWeeklyVolumeM: 45_000, weeksAvailable: 12,
                                   experience: .some, daysPerWeek: 5, intensity: .aggressive,
                                   currentRaceTimeS: honoringRealTime ? fourHours : nil)
        }
        let honest = assess(honoringRealTime: true)
        let roundTripped = assess(honoringRealTime: false)
        #expect(honest.weeksNeeded < roundTripped.weeksNeeded)   // the re-tax needlessly inflates the ask
        #expect(honest.verdict != .tooShort)                     // their real 3:30-off-4:00 is doable, pushed
    }

    @Test func intensityTiersRampInOrder() {
        #expect(PlanIntensity.gentle.weeklyRamp < PlanIntensity.balanced.weeklyRamp)
        #expect(PlanIntensity.balanced.weeklyRamp < PlanIntensity.aggressive.weeklyRamp)
        #expect(PlanIntensity.aggressive.riskNote != nil)   // aggressive is honest about the tradeoff
        #expect(PlanIntensity.balanced.riskNote == nil)
    }
}
