import Testing
import Foundation
@testable import Momentum

/// Time-in-zones: correct bucketing, gap capping, and honest silence without data.
struct ZoneDistributionTests {
    private let zones = HRZones.zones(maxHR: 190, restingHR: 50)!   // Z2 = 134…146 etc.
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func series(_ pairs: [(offset: TimeInterval, bpm: Double)]) -> [(date: Date, bpm: Double)] {
        pairs.map { (t0.addingTimeInterval($0.offset), $0.bpm) }
    }

    @Test func bucketsTimeIntoTheRightZones() throws {
        // Realistic 5 s watch sampling: 60 s at Z2 (140), then 60 s at Z4 (165).
        var pairs: [(TimeInterval, Double)] = []
        for t in stride(from: 0.0, through: 55, by: 5) { pairs.append((t, 140)) }
        for t in stride(from: 60.0, through: 120, by: 5) { pairs.append((t, 165)) }
        let dist = try #require(ZoneDistribution.compute(samples: series(pairs), zones: zones))
        #expect(dist[1] == 60)                       // Z2
        #expect(dist[3] == 60)                       // Z4
        #expect(dist[0] == 0 && dist[2] == 0 && dist[4] == 0)
    }

    @Test func gapsAreCappedSoPausesDoNotInflate() throws {
        // A 10-minute gap (paused watch) only credits 15 s to the zone before it.
        let dist = try #require(ZoneDistribution.compute(
            samples: series([(0, 140), (600, 140), (610, 140)]), zones: zones))
        #expect(dist[1] == 15 + 10)
    }

    @Test func outOfRangeClampsToTheEdgeZones() {
        #expect(ZoneDistribution.zoneIndex(bpm: 60, zones: zones) == 0)     // below Z1 floor → Z1
        #expect(ZoneDistribution.zoneIndex(bpm: 250, zones: zones) == 4)    // above max → Z5
    }

    @Test func tooLittleDataSaysNothing() {
        #expect(ZoneDistribution.compute(samples: series([(0, 140)]), zones: zones) == nil)
        #expect(ZoneDistribution.compute(samples: [], zones: zones) == nil)
    }
}
