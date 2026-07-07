import Testing
@testable import Momentum

/// VO₂max fitness-rating norms — age/sex-banded buckets so a number reads as good vs bad. Pure.
struct VO2maxNormsTests {

    @Test func ratesAgainstAgeAndSexNorms() {
        // Man under 30 — cut points [38, 44, 51, 56].
        #expect(VO2maxNorms.rating(vo2: 35, age: 25, male: true) == .poor)
        #expect(VO2maxNorms.rating(vo2: 48, age: 25, male: true) == .good)
        #expect(VO2maxNorms.rating(vo2: 60, age: 25, male: true) == .superior)
        // The same VO₂max rates better at an older age (lower cut points).
        #expect(VO2maxNorms.rating(vo2: 40, age: 25, male: true) == .fair)
        #expect(VO2maxNorms.rating(vo2: 40, age: 55, male: true) == .good)
        // Women's cut points are lower, so 40 rates 'good' under 30.
        #expect(VO2maxNorms.rating(vo2: 40, age: 25, male: false) == .good)
    }

    @Test func positionClampsAndRisesWithFitness() {
        #expect(VO2maxNorms.position(vo2: 10, age: 30, male: true) == 0)   // pins to floor
        #expect(VO2maxNorms.position(vo2: 90, age: 30, male: true) == 1)   // pins to ceiling
        #expect(VO2maxNorms.position(vo2: 50, age: 30, male: true) > VO2maxNorms.position(vo2: 40, age: 30, male: true))
    }
}
