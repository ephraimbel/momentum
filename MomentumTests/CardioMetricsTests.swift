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
}
