import Testing
@testable import Momentum

/// The five-zone HR model: Karvonen when resting HR is known, %max fallback, sane run-type anchors.
struct HRZonesTests {

    @Test func karvonenZonesUseHeartRateReserve() throws {
        // max 190, rest 50 → HRR 140. Z2 floor = 50 + 0.6·140 = 134; Z5 ceiling = max.
        let z = try #require(HRZones.zones(maxHR: 190, restingHR: 50))
        #expect(z.count == 5)
        #expect(z[0].bpm.lowerBound == 120)      // 50 + 0.5·140
        #expect(z[1].bpm.lowerBound == 134)
        #expect(z[4].bpm.upperBound == 190)
        // Contiguous, no gaps or overlaps.
        for i in 1..<5 { #expect(z[i].bpm.lowerBound == z[i - 1].bpm.upperBound + 1) }
    }

    @Test func percentMaxFallbackWhenRestingUnknown() throws {
        let z = try #require(HRZones.zones(maxHR: 180, restingHR: nil))
        #expect(z[0].bpm.lowerBound == 90)       // 0.5·180
        #expect(z[3].bpm.lowerBound == 144)      // 0.8·180
        #expect(z[4].bpm.upperBound == 180)
    }

    @Test func nonsenseInputsReturnNil() {
        #expect(HRZones.zones(maxHR: 80) == nil)                       // not a max HR
        #expect(HRZones.zones(maxHR: 190, restingHR: 15)?.count == 5)  // absurd rest ignored → %max path
    }

    @Test func runTypesAnchorToSensibleZones() {
        #expect(HRZones.zoneIndex(for: .recovery) == 1)
        #expect(HRZones.zoneIndex(for: .easy) == 2)
        #expect(HRZones.zoneIndex(for: .long) == 2)      // long runs are EASY — the classic mistake
        #expect(HRZones.zoneIndex(for: .tempo) == 4)
        #expect(HRZones.zoneIndex(for: .intervals) == 5)
    }

    @Test func sessionTargetReadsCleanly() throws {
        let t = try #require(HRZones.target(for: .easy, maxHR: 190, restingHR: 50))
        #expect(t.hasPrefix("Z2"))
        #expect(t.contains("bpm"))
        #expect(HRZones.target(for: .easy, maxHR: nil, restingHR: nil) == nil)
    }
}
