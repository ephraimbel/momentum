import Testing
import Foundation
@testable import Momentum

/// Daniels/VDOT pace zones — checked against Daniels' published tables (the VDOT-50 row is the
/// canonical anchor: ~19:57 5K) and the structural invariants every prescription must hold.
struct DanielsPacesTests {

    // MARK: VDOT derivation

    @Test func vdotMatchesDanielsTable() {
        // 19:57–20:00 5K ≈ VDOT 50 in the published tables (p5k ≈ 240 s/km).
        #expect(abs(DanielsPaces.vdot(p5kSPerKm: 240) - 49.8) < 0.5)
        // 25:00 5K ≈ VDOT 38.3.
        #expect(abs(DanielsPaces.vdot(p5kSPerKm: 300) - 38.3) < 0.5)
        // Faster 5K → higher VDOT, strictly.
        #expect(DanielsPaces.vdot(p5kSPerKm: 240) > DanielsPaces.vdot(p5kSPerKm: 300))
    }

    @Test func vdotSelfConsistentWithRaceEstimator() {
        // Deriving VDOT from p5k must agree with the estimator fed the same 5K effort.
        let fromPace = DanielsPaces.vdot(p5kSPerKm: 270)
        let fromRace = VO2maxEstimator.fromRace(distanceM: 5000, timeS: 270 * 5)!
        #expect(abs(fromPace - fromRace) < 0.01)
    }

    // MARK: The VDOT-50 golden row (Daniels' published training paces for a 20:00 5K runner)

    @Test func vdot50PacesMatchPublishedTable() {
        let p5k = 240.0
        // T ≈ 4:15/km in Daniels' table (we derive it as one-hour-race intensity).
        #expect(abs(DanielsPaces.trainingPace(.tempo, p5kSPerKm: p5k) - 254) <= 2)
        // I ≈ 93 s per 400 m in the table → ~230–233 s/km.
        let i400 = DanielsPaces.trainingPace(.intervals, p5kSPerKm: p5k) * 0.4
        #expect(abs(i400 - 92.5) <= 1.5)
        // E lands inside Daniels' published easy band for VDOT 50 (5:06–5:37/km).
        let easy = DanielsPaces.trainingPace(.easy, p5kSPerKm: p5k)
        #expect(easy >= 306 && easy <= 337)
        // M ≈ 4:31/km (a VDOT-50 marathon is ~3:10–3:11).
        #expect(abs(DanielsPaces.marathonPaceSPerKm(p5kSPerKm: p5k) - 271) <= 4)
    }

    // MARK: Race prediction (powers the M zone)

    @Test func racePaceSlowsWithDistance() {
        let vdot = DanielsPaces.vdot(p5kSPerKm: 300)
        let p5 = DanielsPaces.racePaceSPerKm(distanceM: 5_000, vdot: vdot)!
        let p10 = DanielsPaces.racePaceSPerKm(distanceM: 10_000, vdot: vdot)!
        let pHalf = DanielsPaces.racePaceSPerKm(distanceM: 21_097, vdot: vdot)!
        let pFull = DanielsPaces.racePaceSPerKm(distanceM: 42_195, vdot: vdot)!
        #expect(p5 < p10 && p10 < pHalf && pHalf < pFull)
        // Round-tripping the 5K through the solver recovers the input pace.
        #expect(abs(p5 - 300) < 2)
        #expect(DanielsPaces.racePaceSPerKm(distanceM: 0, vdot: vdot) == nil)
    }

    @Test func marathonPaceSitsBetweenThresholdAndEasy() {
        for p5k in [200.0, 240, 300, 360, 420, 500] {
            let m = DanielsPaces.marathonPaceSPerKm(p5kSPerKm: p5k)
            #expect(m > DanielsPaces.trainingPace(.tempo, p5kSPerKm: p5k))
            #expect(m < DanielsPaces.trainingPace(.easy, p5kSPerKm: p5k))
        }
    }

    // MARK: Endurance correction — predictions past ~3 h, never the training zones

    @Test func fiftyKPredictionIsHonestlySlowerThanMarathon() {
        // The raw %max curve floors at 80% VO₂max, so an uncorrected 50K predicts barely slower
        // than marathon pace ("9:59-pace ultra"). The corrected prediction opens a real gap.
        // Relative, because the (4-hour) marathon prediction is corrected too: the 50K must sit a
        // real ≥3% slower per km than the marathon, not the rounding-error gap the raw curve gave.
        let marathon = DanielsPaces.racePaceSPerKm(distanceM: 42_195, p5kSPerKm: 300)
        let fiftyK = DanielsPaces.racePaceSPerKm(distanceM: 50_000, p5kSPerKm: 300)
        #expect(fiftyK >= marathon * 1.03, "50K pace \(fiftyK) vs marathon \(marathon) — gap too small")
    }

    @Test func enduranceCorrectionNeverTouchesShortRaces() {
        // Under the 3 h horizon the corrected wrapper equals the raw curve exactly.
        let vdot = DanielsPaces.vdot(p5kSPerKm: 300)
        let raw10K = DanielsPaces.racePaceSPerKm(distanceM: 10_000, vdot: vdot)!
        #expect(abs(DanielsPaces.racePaceSPerKm(distanceM: 10_000, p5kSPerKm: 300) - raw10K.rounded()) < 1)
        #expect(DanielsPaces.enduranceCorrected(raceTimeS: 2.9 * 3600) == 2.9 * 3600)
    }

    @Test func trainingZoneMarathonPaceStaysUncorrected() {
        // The M ZONE anchors progression thirds and must sit between T and E for every athlete —
        // it never takes the endurance tax (a slow athlete's corrected race pace can sit slower
        // than easy pace, which is honest for a PREDICTION and nonsense for a zone).
        let vdot = DanielsPaces.vdot(p5kSPerKm: 420)
        let rawM = DanielsPaces.racePaceSPerKm(distanceM: 42_195, vdot: vdot)!
        #expect(abs(DanielsPaces.marathonPaceSPerKm(p5kSPerKm: 420) - rawM.rounded()) < 1)
    }

    // MARK: Inversion (StructuredWorkoutBuilder's p5k recovery)

    @Test func p5kRecoveryRoundTrips() {
        for (type, p5k) in [(RunType.easy, 330.0), (.tempo, 280.0), (.intervals, 250.0), (.long, 400.0)] {
            let pace = DanielsPaces.trainingPace(type, p5kSPerKm: p5k)
            let recovered = DanielsPaces.p5kSPerKm(fromPace: pace, type: type)
            #expect(abs(recovered - p5k) < 2, "\(type) failed: \(recovered) vs \(p5k)")
        }
        // Race pace IS the 5K pace.
        #expect(DanielsPaces.p5kSPerKm(fromPace: 300, type: .race) == 300)
    }

    // MARK: Garbage in, safety out

    @Test func degenerateInputsStaySane() {
        for bad in [0.0, -50, .infinity, .nan, 5000] {
            let easy = DanielsPaces.trainingPace(.easy, p5kSPerKm: bad)
            #expect(easy.isFinite && easy >= 120 && easy <= 1200)
        }
        #expect(DanielsPaces.p5kSPerKm(fromPace: -1, type: .easy) == 330)
    }
}
