import Testing
import Foundation
@testable import Momentum

/// Clean prescription distances — a coach writes "4 miles" / "a 5K", never "3.73 miles". Verifies
/// the snap lands on the round value in each unit, race sessions land on the exact race distance,
/// and the perturbation is always small (safety-preserving).
struct RunRoundingTests {

    private let mi = Formatters.metersPerMile

    @Test func imperialSnapsToHalfMiles() {
        // 6000 m = 3.73 mi → the coach says "3.5 mi" (nearest 0.5) — clean, not "3.73".
        #expect(RunRounding.snap(meters: 6000, unit: .imperial) == (3.5 * mi))
        // 3.2 mi → 3.0; 5.4 mi → 5.5; 2.1 mi → 2.0.
        #expect(RunRounding.snap(meters: 3.2 * mi, unit: .imperial) == 3.0 * mi)
        #expect(RunRounding.snap(meters: 5.4 * mi, unit: .imperial) == 5.5 * mi)
        #expect(RunRounding.snap(meters: 2.1 * mi, unit: .imperial) == 2.0 * mi)
    }

    @Test func metricSnapsToHalfKilometers() {
        #expect(RunRounding.snap(meters: 6480, unit: .metric) == 6500)   // 6.48 → 6.5
        #expect(RunRounding.snap(meters: 5240, unit: .metric) == 5000)   // 5.24 → 5.0
        #expect(RunRounding.snap(meters: 8000, unit: .metric) == 8000)   // already clean
    }

    @Test func longRunsSnapToWholeUnits() {
        // ≥10 units → whole-number milestones ("16 mi", "20 km"), no half-unit clutter.
        #expect(RunRounding.snap(meters: 15.7 * mi, unit: .imperial) == 16.0 * mi)
        #expect(RunRounding.snap(meters: 19_880, unit: .metric) == 20_000)   // 19.88 km → 20
        #expect(RunRounding.snap(meters: 32_400, unit: .metric) == 32_000)   // marathon long
    }

    @Test func raceSessionsSnapToTheExactRaceDistance() {
        // The race is the race — canonical distances, not rounded miles.
        #expect(RunRounding.snap(meters: 5100, unit: .imperial, isRace: true) == 5000)
        #expect(RunRounding.snap(meters: 21_500, unit: .metric, isRace: true) == 21_097.5)
        #expect(RunRounding.snap(meters: 41_000, unit: .imperial, isRace: true) == 42_195)
        #expect(RunRounding.snap(meters: 49_000, unit: .metric, isRace: true) == 50_000)
    }

    @Test func snappingIsAlwaysSmallAndNeverZero() {
        // Snap moves a distance by less than one full unit, and never to nothing — so volume/ACWR
        // are barely perturbed and no run vanishes.
        for m in stride(from: 800.0, through: 42_000, by: 137) {
            for unit in [DistanceUnit.metric, .imperial] {
                let s = RunRounding.snap(meters: m, unit: unit)
                let perUnit = unit == .imperial ? mi : 1000.0
                #expect(s > 0)
                #expect(abs(s - m) <= perUnit, "snap moved \(m) too far in \(unit): \(s)")
            }
        }
    }

    @Test func degenerateInputsPassThrough() {
        #expect(RunRounding.snap(meters: 0, unit: .metric) == 0)
        #expect(RunRounding.snap(meters: -5, unit: .metric) == -5)
    }
}
