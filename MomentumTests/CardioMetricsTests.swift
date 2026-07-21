import Testing
import Foundation
@testable import Momentum

struct CardioMetricsTests {
    /// Steady effort: a sample every `stepM` meters at `speedMS`.
    func steady(totalM: Double, stepM: Double, speedMS: Double) -> [CardioMetrics.SamplePoint] {
        var out: [CardioMetrics.SamplePoint] = []
        var d = 0.0
        while d <= totalM + 1e-6 {
            out.append(.init(t: d / speedMS, cumulativeM: d))
            d += stepM
        }
        return out
    }

    @Test func fastestWindowSteady() {
        let s = steady(totalM: 2000, stepM: 100, speedMS: 5) // 5 m/s → 1km in 200s
        let t = CardioMetrics.fastestWindow(s, distanceM: 1000)
        #expect(t != nil)
        #expect(abs((t ?? 0) - 200) < 0.001)
    }

    @Test func fastestWindowTooShort() {
        let s = steady(totalM: 500, stepM: 100, speedMS: 5)
        #expect(CardioMetrics.fastestWindow(s, distanceM: 1000) == nil)
    }

    @Test func fastestWindowFindsQuickestSegment() {
        // First 1000m slow (4 m/s = 250s), next 1000m fast (8 m/s = 125s).
        var pts: [CardioMetrics.SamplePoint] = []
        var d = 0.0, t = 0.0
        while d < 1000 { pts.append(.init(t: t, cumulativeM: d)); d += 100; t += 100/4 }
        while d <= 2000 { pts.append(.init(t: t, cumulativeM: d)); d += 100; t += 100/8 }
        let best = CardioMetrics.fastestWindow(pts, distanceM: 1000)
        #expect(best != nil)
        #expect(abs((best ?? 0) - 125) < 0.5)
    }

    @Test func splitsClose() {
        let s = steady(totalM: 2500, stepM: 100, speedMS: 5)
        let splits = CardioMetrics.splits(s, unitMeters: 1000)
        #expect(splits.count == 3)
        #expect(splits[0].isPartial == false)
        #expect(abs(splits[0].durationS - 200) < 0.001)
        #expect(splits[2].isPartial == true)
        #expect(abs(splits[2].distanceM - 500) < 0.5)
    }

    // MARK: - Average pace / speed
    //
    // These pin the ONE definition. Expected values are hardcoded literals, never expressed with the
    // operators under test — `3060 / 10.1` would pass for any implementation that made the same
    // mistake as the code.

    @Test func steadyRunAveragesExactly() {
        // 8 km in 45:00 ⇒ 337.5 s/km. The case the EMA also got right; it must not move.
        #expect(CardioMetrics.averagePaceSPerKm(distanceM: 8000, durationS: 2700) == 337.5)
    }

    /// The motivating case: the athlete walks the last minute before reaching for Finish. The EMA
    /// followed the walk; the average must not.
    @Test func endingOnAWalkDoesNotDragTheAverage() {
        let pace = CardioMetrics.averagePaceSPerKm(distanceM: 10_100, durationS: 3060)
        #expect(abs(pace - 302.970297) < 1e-5)
    }

    /// The opposite direction, and the dangerous one: a hard finish made the EMA read FASTER than
    /// the athlete ever averaged, which fabricates fitness rather than merely losing it.
    @Test func aFastFinishDoesNotFlatterTheAverage() {
        let pace = CardioMetrics.averagePaceSPerKm(distanceM: 6216.2, durationS: 1980)
        #expect(abs(pace - 318.52) < 0.01)
    }

    @Test func degenerateInputIsZeroAndFinite() {
        for (d, t) in [(0.0, 1800.0), (5000.0, 0.0), (0.0, 0.0), (-5.0, 100.0)] {
            let pace = CardioMetrics.averagePaceSPerKm(distanceM: d, durationS: t)
            let speed = CardioMetrics.averageSpeedMS(distanceM: d, durationS: t)
            #expect(pace == 0 && pace.isFinite)
            #expect(speed == 0 && speed.isFinite)
        }
    }

    @Test func paceAndSpeedAreReciprocal() {
        let d = 20_000.0, t = 2400.0
        let pace = CardioMetrics.averagePaceSPerKm(distanceM: d, durationS: t)
        let speed = CardioMetrics.averageSpeedMS(distanceM: d, durationS: t)
        #expect(abs(speed - 8.3333333) < 1e-6)
        #expect(abs(pace * speed - 1000) < 1e-9)
    }
}
