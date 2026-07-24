import Testing
import Foundation
@testable import Momentum

/// Pins the clean-pace prescription rules (RunRounding.snapPace): a coach writes "8:30/mi",
/// never "8:24/mi". Easy-family paces land on :15 boundaries, quality/race paces on :05, in the
/// athlete's own display unit — mile runners get clean mile paces, km runners clean km paces.
struct PaceSnappingTests {

    private let sPerMileFactor = Formatters.metersPerMile / 1_000.0   // s/km → s/mi

    private func perMile(_ sPerKm: Double) -> Double { sPerKm * sPerMileFactor }

    @Test func qualityPacesSnapToFiveSecondsPerMile() {
        // The 8:24/mi sighting that started this — a tempo snaps to 8:25/mi.
        let raw = (8 * 60 + 24.0) / sPerMileFactor
        let snapped = RunRounding.snapPace(sPerKm: raw, unit: .imperial, type: .tempo)
        #expect(abs(perMile(snapped) - (8 * 60 + 25)) < 0.01)
    }

    @Test func easyPacesSnapToFifteenSecondsPerMile() {
        // 9:07/mi easy reads like a spreadsheet; the coach writes 9:00.
        let raw = (9 * 60 + 7.0) / sPerMileFactor
        let snapped = RunRounding.snapPace(sPerKm: raw, unit: .imperial, type: .easy)
        #expect(abs(perMile(snapped) - (9 * 60)) < 0.01)
        // 8:38/mi long run → 8:45.
        let long = (8 * 60 + 38.0) / sPerMileFactor
        #expect(abs(perMile(RunRounding.snapPace(sPerKm: long, unit: .imperial, type: .long)) - (8 * 60 + 45)) < 0.01)
    }

    @Test func metricAthletesGetCleanKmPaces() {
        // 5:13/km intervals → 5:15/km; 6:08/km long → 6:15/km.
        #expect(abs(RunRounding.snapPace(sPerKm: 313, unit: .metric, type: .intervals) - 315) < 0.01)
        #expect(abs(RunRounding.snapPace(sPerKm: 368, unit: .metric, type: .long) - 375) < 0.01)
    }

    @Test func alreadyCleanPacesAreUntouched() {
        #expect(RunRounding.snapPace(sPerKm: 300, unit: .metric, type: .tempo) == 300)
        let clean = (8 * 60 + 30.0) / sPerMileFactor
        #expect(abs(perMile(RunRounding.snapPace(sPerKm: clean, unit: .imperial, type: .easy)) - (8 * 60 + 30)) < 0.01)
    }

    @Test func snapRespectsTheGlobalPaceFloor() {
        // Snapping can never produce something faster than the engine's 2:00/km floor.
        #expect(RunRounding.snapPace(sPerKm: 121, unit: .metric, type: .intervals) >= 120)
        #expect(RunRounding.snapPace(sPerKm: 0, unit: .metric, type: .easy) == 0)   // degenerate passthrough
    }

    @Test func raceCountsAsQualityPrecision() {
        // Race pace is a real prescription — 5s grid, not the easy 15s one.
        let raw = 341.0   // 5:41/km
        #expect(abs(RunRounding.snapPace(sPerKm: raw, unit: .metric, type: .race) - 340) < 0.01)
    }
}
