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

    @Test func intensityTiersRampInOrder() {
        #expect(PlanIntensity.gentle.weeklyRamp < PlanIntensity.balanced.weeklyRamp)
        #expect(PlanIntensity.balanced.weeklyRamp < PlanIntensity.aggressive.weeklyRamp)
        #expect(PlanIntensity.aggressive.riskNote != nil)   // aggressive is honest about the tradeoff
        #expect(PlanIntensity.balanced.riskNote == nil)
    }
}
