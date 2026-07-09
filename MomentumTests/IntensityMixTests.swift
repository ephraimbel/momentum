import Testing
@testable import Momentum

/// The 80/20 polarized check — prescription outranks pace; too little data says nothing.
struct IntensityMixTests {
    private func easy(_ p: Double = 380) -> IntensityMix.RunInput { .init(paceSPerKm: p, plannedQuality: nil) }
    private func hard(_ p: Double = 320) -> IntensityMix.RunInput { .init(paceSPerKm: p, plannedQuality: nil) }

    @Test func polarizedWeekReadsAsSweetSpot() throws {
        // p5k 300 → hard gate 350. Eight easy (380) + two hard (320) = 80% easy.
        let mix = try #require(IntensityMix.analyze(runs: Array(repeating: easy(), count: 8) + [hard(), hard()],
                                                    p5kSPerKm: 300))
        #expect(mix.verdict == .polarized)
        #expect(abs(mix.easyFraction - 0.8) < 0.001)
        #expect(mix.hardCount == 2)
    }

    @Test func everyRunKindOfHardIsCalledOut() throws {
        // The classic mistake: six runs, all at 330 against a 300 p5k (faster than the 350 gate).
        let mix = try #require(IntensityMix.analyze(runs: Array(repeating: hard(330), count: 6), p5kSPerKm: 300))
        #expect(mix.verdict == .tooHard)
        #expect(mix.easyCount == 0)
    }

    @Test func greyZoneSitsBetween() throws {
        // 7 easy + 3 hard = 70% easy → grey.
        let mix = try #require(IntensityMix.analyze(runs: Array(repeating: easy(), count: 7) + Array(repeating: hard(), count: 3),
                                                    p5kSPerKm: 300))
        #expect(mix.verdict == .grey)
    }

    @Test func prescriptionOutranksPace() throws {
        // A slow-paced session that was PRESCRIBED as quality (hills in wind, trail reps) counts hard.
        let prescribed = IntensityMix.RunInput(paceSPerKm: 400, plannedQuality: true)
        let mix = try #require(IntensityMix.analyze(
            runs: Array(repeating: easy(), count: 4) + [prescribed], p5kSPerKm: 300))
        #expect(mix.hardCount == 1)
        // And an easy-prescribed run that drifted fast still counts easy (the plan said easy).
        let drifted = IntensityMix.RunInput(paceSPerKm: 330, plannedQuality: false)
        let mix2 = try #require(IntensityMix.analyze(
            runs: Array(repeating: easy(), count: 4) + [drifted], p5kSPerKm: 300))
        #expect(mix2.hardCount == 0)
    }

    @Test func tooFewRunsSaysNothing() {
        #expect(IntensityMix.analyze(runs: [easy(), hard(), easy()], p5kSPerKm: 300) == nil)
        #expect(IntensityMix.analyze(runs: Array(repeating: easy(), count: 6), p5kSPerKm: 0) == nil)
    }
}
