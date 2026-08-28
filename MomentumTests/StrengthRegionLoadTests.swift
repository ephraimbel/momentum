import Testing
import Foundation
@testable import Momentum

/// The muscle-load wheel's numbers (2026-08-28): six regions in wheel order, volume shared across
/// the muscles a set works (never double-counted), sets credited the muscle-map way — so the wheel
/// and the body figure agree on where the load sits.
struct StrengthRegionLoadTests {
    typealias E = StrengthTrends.RegionEntry
    typealias R = StrengthTrends.BodyRegion

    @Test func wheelOrderIsBevelsClockwiseFromTheTop() {
        #expect(R.allCases == [.chest, .back, .legs, .shoulders, .core, .arms])
        #expect(R.of(.biceps) == .arms && R.of(.triceps) == .arms && R.of(.forearms) == .arms)
        #expect(R.of(.quads) == .legs && R.of(.glutes) == .legs && R.of(.calves) == .legs && R.of(.hamstrings) == .legs)
        #expect(R.of(.fullBody) == nil)
    }

    @Test func volumeIsSharedNeverDoubleCounted() {
        // Bench: chest primary, triceps + shoulders secondary. 1000 kg moved over 4 sets.
        let loads = StrengthTrends.regionLoads(entries: [
            E(primary: [.chest], secondary: [.triceps, .shoulders], volumeKg: 1000, workingSets: 4)
        ])
        let byRegion = Dictionary(uniqueKeysWithValues: loads.map { ($0.region, $0) })
        #expect(loads.count == 6)
        #expect(abs(loads.reduce(0) { $0 + $1.volumeKg } - 1000) < 0.001)          // sums to what was moved
        #expect(abs((byRegion[.chest]?.volumeKg ?? 0) - 500) < 0.001)               // 1.0 / (1 + 0.5 + 0.5)
        #expect(abs((byRegion[.arms]?.volumeKg ?? 0) - 250) < 0.001)
        #expect(abs((byRegion[.shoulders]?.volumeKg ?? 0) - 250) < 0.001)
        #expect(byRegion[.legs]?.volumeKg == 0)
        // Sets: primary 1.0, secondary 0.5 — the muscle map's own rule.
        #expect(abs((byRegion[.chest]?.sets ?? 0) - 4) < 0.001)
        #expect(abs((byRegion[.arms]?.sets ?? 0) - 2) < 0.001)
    }

    @Test func fullBodySpreadsAcrossTheWheel() {
        let loads = StrengthTrends.regionLoads(entries: [
            E(primary: [.fullBody], secondary: [], volumeKg: 600, workingSets: 6)
        ])
        #expect(loads.allSatisfy { abs($0.volumeKg - 100) < 0.001 })
        #expect(loads.allSatisfy { abs($0.sets - 1) < 0.001 })
    }

    @Test func legsLeadWhenTheSquatsAreHeavy() {
        let loads = StrengthTrends.regionLoads(entries: [
            E(primary: [.quads, .glutes], secondary: [.hamstrings, .core], volumeKg: 4000, workingSets: 5),
            E(primary: [.chest], secondary: [.triceps], volumeKg: 900, workingSets: 3),
        ])
        let top = loads.max { $0.volumeKg < $1.volumeKg }
        #expect(top?.region == .legs)
        #expect(loads.first { $0.region == .core }?.volumeKg ?? 0 > 0)   // secondary credit still lands
    }
}
