import Testing
import Foundation
@testable import Momentum

/// Race-time projection via Riegel (running-excellence R4). Deterministic + inverse of the plan
/// engine's P5k seeding.
struct RacePredictorTests {

    @Test func projectsFinishTimeByRiegel() {
        // A 25:00 5k runner (300 s/km). At exactly 5 km the projection is the 5k time itself.
        #expect(RacePredictor.finishTimeS(raceDistanceM: 5000, p5kSPerKm: 300) == 1500)
        // 10k = 1500·2^1.06 ≈ 3127 s (a touch slower than 2×5k, as endurance demands).
        let tenK = RacePredictor.finishTimeS(raceDistanceM: 10000, p5kSPerKm: 300)!
        #expect(abs(tenK - 3127) < 2)
        // Longer races are progressively slower per km — the model's whole point.
        let half = RacePredictor.finishTimeS(raceDistanceM: 21097, p5kSPerKm: 300)!
        #expect(half > 6800 && half < 7000)   // ~1:55
    }

    @Test func projectedPaceIsFinishOverDistance() {
        let pace = RacePredictor.projectedPaceSPerKm(raceDistanceM: 10000, p5kSPerKm: 300)!
        #expect(abs(pace - 312.7) < 1)        // slower than 5k pace of 300
    }

    @Test func rejectsBadInput() {
        #expect(RacePredictor.finishTimeS(raceDistanceM: 0, p5kSPerKm: 300) == nil)
        #expect(RacePredictor.finishTimeS(raceDistanceM: 5000, p5kSPerKm: 0) == nil)
    }

    @Test func daysUntilCountsWholeDaysAndDropsPast() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_700_000_000)     // 2023-11-14
        let race = now.addingTimeInterval(10 * 86400)
        #expect(RacePredictor.daysUntil(raceDate: race, from: now, calendar: cal) == 10)
        #expect(RacePredictor.daysUntil(raceDate: now.addingTimeInterval(-5 * 86400), from: now, calendar: cal) == nil)
        #expect(RacePredictor.daysUntil(raceDate: nil, from: now, calendar: cal) == nil)
    }

    @Test func labelsRaceDistances() {
        #expect(RacePredictor.label(forRaceM: 5000) == "5K")
        #expect(RacePredictor.label(forRaceM: 10000) == "10K")
        #expect(RacePredictor.label(forRaceM: 21097) == "Half")
        #expect(RacePredictor.label(forRaceM: 42195) == "Marathon")
    }
}
