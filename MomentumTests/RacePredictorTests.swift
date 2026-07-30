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
        #expect(RacePredictor.label(forRaceM: 50000) == "Ultra")
    }

    // MARK: The endurance tax — predictions past ~3 h stop pretending pain doesn't exist

    @Test func ultraPredictionsCarryTheEnduranceTax() {
        // A 25:00-5K athlete. Raw Riegel says a 50K is barely slower per km than a marathon —
        // the exact "9:59-pace ultra" absurdity: no glycogen wall, no impact damage, no long day.
        let naive50K = 1500 * pow(50_000.0 / 5_000.0, RacePredictor.riegelExponent)
        let corrected = RacePredictor.finishTimeS(raceDistanceM: 50_000, p5kSPerKm: 300)!
        #expect(corrected > naive50K * 1.05, "50K prediction must be taxed well past raw Riegel")

        // And the marathon → 50K pace gap is a real gap, not a rounding error.
        let marathonPace = RacePredictor.projectedPaceSPerKm(raceDistanceM: 42_195, p5kSPerKm: 300)!
        let ultraPace = RacePredictor.projectedPaceSPerKm(raceDistanceM: 50_000, p5kSPerKm: 300)!
        #expect(ultraPace > marathonPace * 1.03)
    }

    @Test func subThreeHourPredictionsAreUntouched() {
        // The validated envelope stays pure Riegel: a ~1:55 half and a 2:48 marathon (17:30-5K
        // athlete) sit under the 3 h horizon and predict exactly as before.
        let half = RacePredictor.finishTimeS(raceDistanceM: 21_097, p5kSPerKm: 300)!
        #expect(abs(half - 1500 * pow(21_097.0 / 5_000.0, 1.06)) < 0.5)
        let eliteMarathon = RacePredictor.finishTimeS(raceDistanceM: 42_195, p5kSPerKm: 210)!
        #expect(abs(eliteMarathon - 210 * 5 * pow(42_195.0 / 5_000.0, 1.06)) < 0.5)
        #expect(eliteMarathon < 3 * 3600)
    }
}
