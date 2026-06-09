import Testing
@testable import Momentum

struct PlateCalculatorTests {
    let kg = PlateCalculator.kgPlates

    @Test func exactLoadKg() {
        let r = PlateCalculator.compute(target: 100, bar: 20, available: kg)
        #expect(r.isExact)
        // per side 40 = 25 + 15
        #expect(r.perSide == [.init(weight: 25, count: 1), .init(weight: 15, count: 1)])
    }

    @Test func usesSmallPlates() {
        let r = PlateCalculator.compute(target: 102.5, bar: 20, available: kg)
        #expect(r.isExact)
        // per side 41.25 = 25 + 15 + 1.25
        #expect(r.perSide == [.init(weight: 25, count: 1),
                              .init(weight: 15, count: 1),
                              .init(weight: 1.25, count: 1)])
    }

    @Test func reportsShortfall() {
        // per side 40.55 → loads 40, 0.55 short → 1.1 kg total short (PRD example)
        let r = PlateCalculator.compute(target: 101.1, bar: 20, available: kg)
        #expect(!r.isExact)
        #expect(r.totalShortfall == 1.1)
    }

    @Test func barOnly() {
        let r = PlateCalculator.compute(target: 20, bar: 20, available: kg)
        #expect(r.perSide.isEmpty)
        #expect(r.isExact)
    }

    @Test func multipleOfSamePlate() {
        // per side (140-20)/2 = 60 = 25 + 25 + 10
        let r = PlateCalculator.compute(target: 140, bar: 20, available: kg)
        #expect(r.perSide.first == .init(weight: 25, count: 2))
        #expect(r.isExact)
    }
}
