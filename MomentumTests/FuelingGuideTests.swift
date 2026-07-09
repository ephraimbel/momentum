import Testing
@testable import Momentum

/// Fueling, not dieting: the evidence-based thresholds, and the honest floor (short runs need nothing).
struct FuelingGuideTests {

    @Test func underAnHourNeedsNothing() {
        let g = FuelingGuide.guidance(durationS: 45 * 60)
        #expect(g.carbsPerHour == nil)
        #expect(g.headline == "No fuel needed")
    }

    @Test func longRunGetsTheThirtyToSixtyRange() {
        let g = FuelingGuide.guidance(durationS: 95 * 60)
        #expect(g.carbsPerHour == 30...60)
        #expect(g.during.contains("30–60 g"))
        #expect(g.during.contains("practice"))            // training runs teach race day
    }

    @Test func marathonLengthGetsTheHighRangeAndGutTraining() {
        let g = FuelingGuide.guidance(durationS: 3.5 * 3600)
        #expect(g.carbsPerHour == 60...90)
        #expect(g.during.contains("gut is trainable"))
        // Race framing switches from practicing to executing.
        let race = FuelingGuide.guidance(durationS: 3.5 * 3600, isRace: true)
        #expect(race.during.contains("starting early"))
        #expect(!race.during.contains("trainable"))
    }

    @Test func boundariesLandOnTheRightSide() {
        #expect(FuelingGuide.guidance(durationS: 59 * 60).carbsPerHour == nil)
        #expect(FuelingGuide.guidance(durationS: 60 * 60).carbsPerHour == 30...60)
        #expect(FuelingGuide.guidance(durationS: 150 * 60).carbsPerHour == 60...90)
    }

    @Test func durationEstimateFallsBackFromExplicitToDerived() {
        #expect(FuelingGuide.estimatedDurationS(distanceM: nil, paceSPerKm: nil, durationS: 3_600) == 3_600)
        // 16 km at 6:00/km → 96 min.
        #expect(FuelingGuide.estimatedDurationS(distanceM: 16_000, paceSPerKm: 360, durationS: nil) == 5_760)
        #expect(FuelingGuide.estimatedDurationS(distanceM: nil, paceSPerKm: 360, durationS: nil) == nil)
    }
}
