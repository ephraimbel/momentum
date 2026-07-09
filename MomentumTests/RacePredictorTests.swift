import Testing
import Foundation
@testable import Momentum

/// Verifies the Riegel race-time projector (running-excellence R4).
struct RacePredictorTests {

    @Test func projectsAllDistancesFromP5k() {
        // 240 s/km 5k pace → an exact 20:00 5k, longer races extrapolated by Riegel (^1.06).
        let p = RacePredictor.predictions(p5kSPerKm: 240)
        #expect(p.count == 4)
        #expect(p.first?.distance == .fiveK)
        #expect(abs((p.first?.timeS ?? 0) - 1200) < 0.5)          // 5 km = 5 × 240 s

        // Pace slows monotonically with distance (endurance fatigue), never speeds up.
        let paces = p.map(\.paceSPerKm)
        #expect(zip(paces, paces.dropFirst()).allSatisfy { $0 < $1 })
        #expect((p.last?.distance) == .marathon)
        #expect((p.last?.paceSPerKm ?? 0) > 240)                  // marathon pace slower than 5k pace

        // 10k should land near the Riegel value (~41:42 for a 20:00 5k), well over 2×5k.
        let tenK = p.first(where: { $0.distance == .tenK })?.timeS ?? 0
        #expect(tenK > 2400 && tenK < 2600)
    }

    @Test func fallsBackAndGuardsBadInput() {
        // Prefers the athlete-model proxy; falls back to the plan pace.
        #expect(RacePredictor.predictions(p5kEquivSPerKm: 300, planP5kSPerKm: 360).first?.timeS == 1500)
        #expect(RacePredictor.predictions(p5kEquivSPerKm: nil, planP5kSPerKm: 360).first?.timeS == 1800)
        // No fitness at all → nothing to project.
        #expect(RacePredictor.predictions(p5kEquivSPerKm: nil, planP5kSPerKm: nil).isEmpty)
        #expect(RacePredictor.predictions(p5kSPerKm: 0).isEmpty)
    }
}
