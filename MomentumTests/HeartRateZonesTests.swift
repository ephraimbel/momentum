import Testing
import Foundation
@testable import Momentum

/// Heart-rate zones + run-signal aggregation (running-excellence R3). Pure %-of-max banding.
struct HeartRateZonesTests {

    @Test func zonesBandByPercentOfMax() {
        let maxHR = 200
        #expect(HeartRateZones.zone(forBpm: 100, maxHR: maxHR) == 1)   // 50%
        #expect(HeartRateZones.zone(forBpm: 130, maxHR: maxHR) == 2)   // 65%
        #expect(HeartRateZones.zone(forBpm: 150, maxHR: maxHR) == 3)   // 75%
        #expect(HeartRateZones.zone(forBpm: 170, maxHR: maxHR) == 4)   // 85%
        #expect(HeartRateZones.zone(forBpm: 195, maxHR: maxHR) == 5)   // 97.5%
        // Just under / over the Z1→Z2 line (60% = 120 bpm).
        #expect(HeartRateZones.zone(forBpm: 119, maxHR: maxHR) == 1)
        #expect(HeartRateZones.zone(forBpm: 121, maxHR: maxHR) == 2)
    }

    @Test func zonesDefendAgainstBadInput() {
        #expect(HeartRateZones.zone(forBpm: 0, maxHR: 200) == 1)
        #expect(HeartRateZones.zone(forBpm: 150, maxHR: 0) == 1)
    }

    @Test func meanIgnoresZerosAndRounds() {
        #expect(RunSignals.mean([150, 160, 170]) == 160)
        #expect(RunSignals.mean([0, 180]) == 180)          // zeros (no reading) skipped
        #expect(RunSignals.mean([]) == nil)
        #expect(RunSignals.mean([0, 0]) == nil)
        #expect(RunSignals.mean([100, 101]) == 101)        // 100.5 → 101 (round half up)
    }
}
