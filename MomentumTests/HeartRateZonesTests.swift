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

    @Test func distributionIsFractionPerZone() {
        // Two Z1, one Z3, one Z5.
        let dist = HeartRateZones.distribution(bpms: [100, 100, 150, 195], maxHR: 200)
        #expect(dist == [0.5, 0.0, 0.25, 0.0, 0.25])
        #expect(abs(dist.reduce(0, +) - 1.0) < 1e-9)
    }

    @Test func distributionEmptyWithoutData() {
        #expect(HeartRateZones.distribution(bpms: [], maxHR: 200).isEmpty)
        #expect(HeartRateZones.distribution(bpms: [150], maxHR: 0).isEmpty)   // no max → can't band
        #expect(HeartRateZones.distribution(bpms: [0, 0], maxHR: 200).isEmpty) // no valid samples
    }

    @Test func labelsAndBoundsCoverAllZones() {
        #expect(HeartRateZones.label(1) == "Recovery")
        #expect(HeartRateZones.label(5) == "VO₂ max")
        #expect(HeartRateZones.lowerBoundPct(1) == 50)
        #expect(HeartRateZones.lowerBoundPct(5) == 90)
    }

    @Test func meanIgnoresZerosAndRounds() {
        #expect(RunSignals.mean([150, 160, 170]) == 160)
        #expect(RunSignals.mean([0, 180]) == 180)          // zeros (no reading) skipped
        #expect(RunSignals.mean([]) == nil)
        #expect(RunSignals.mean([0, 0]) == nil)
        #expect(RunSignals.mean([100, 101]) == 101)        // 100.5 → 101 (round half up)
    }
}
