import Testing
import Foundation
@testable import Momentum

/// R5 performance-physiology engines: VO₂max, Fitness/Fatigue/Form, and Grade-Adjusted Pace. All pure
/// and checked against textbook values.
struct RunningScienceTests {

    // MARK: VO2max

    @Test func vdotFromRaceMatchesDanielsTable() {
        // A 20:00 5k is ≈ VDOT 49–50 in Daniels' tables.
        let vdot = VO2maxEstimator.fromRace(distanceM: 5000, timeS: 1200)!
        #expect(vdot > 48 && vdot < 51)
        #expect(VO2maxEstimator.fromRace(distanceM: 0, timeS: 1200) == nil)
        #expect(VO2maxEstimator.fromRace(distanceM: 5000, timeS: 0) == nil)
    }

    // MARK: Fitness / Fatigue / Form

    @Test func steadyTrainingConvergesToZeroForm() {
        // Constant daily load → CTL and ATL both converge to it → Form ≈ 0.
        let p = FitnessFreshness.current(dailyLoads: Array(repeating: 100, count: 300))!
        #expect(abs(p.ctl - 100) < 1 && abs(p.atl - 100) < 1)
        #expect(abs(p.tsb) < 1)
    }

    @Test func taperFreshensAndSpikeFatigues() {
        // Build fitness, then rest → fatigue sheds faster than fitness → positive Form (fresh).
        let taper = FitnessFreshness.current(dailyLoads: Array(repeating: 100, count: 60) + Array(repeating: 0, count: 10))!
        #expect(taper.tsb > 0)
        // A hard recent block spikes fatigue above fitness → negative Form.
        let spike = FitnessFreshness.current(dailyLoads: Array(repeating: 50, count: 60) + Array(repeating: 200, count: 3))!
        #expect(spike.tsb < 0)
        #expect(FitnessFreshness.current(dailyLoads: []) == nil)
    }

    @Test func formLabelsAcrossBands() {
        #expect(FitnessFreshness.formLabel(-30) == "Deep in the work")
        #expect(FitnessFreshness.formLabel(0) == "Balanced")
        #expect(FitnessFreshness.formLabel(15) == "Fresh")
        #expect(FitnessFreshness.formLabel(30) == "Peaked")
    }

    // MARK: Grade-Adjusted Pace

    @Test func flatGradeIsUnchanged() {
        #expect(abs(GradeAdjustedPace.costRatio(grade: 0) - 1.0) < 1e-9)
        #expect(GradeAdjustedPace.adjustedPaceSPerKm(paceSPerKm: 360, grade: 0) == 360)
    }

    @Test func uphillGivesFasterEquivalentDownhillSlower() {
        // 6:00/km up a 10% grade is a much harder effort → a faster flat-equivalent.
        let up = GradeAdjustedPace.adjustedPaceSPerKm(paceSPerKm: 360, grade: 0.10)!
        #expect(up < 360 && up > 200)
        let down = GradeAdjustedPace.adjustedPaceSPerKm(paceSPerKm: 360, grade: -0.10)!
        #expect(down > 360)
        #expect(GradeAdjustedPace.adjustedPaceSPerKm(paceSPerKm: 0, grade: 0.05) == nil)
    }

    @Test func runGAPBlendsSegmentsByDistance() {
        // Two flat km → GAP equals the flat pace.
        let flat = GradeAdjustedPace.runGAPSPerKm([(1000, 360, 0), (1000, 360, 0)])!
        #expect(abs(flat - 360) < 0.001)
        #expect(GradeAdjustedPace.runGAPSPerKm([]) == nil)
    }
}
