import Testing
@testable import Momentum

/// Pace Insights classifier (running-excellence R4) — pure, no-shame verdicts on quality-session pacing.
struct PaceInsightsTests {

    private func run(target: Double, achieved: Double) -> PaceInsights.QualityRun {
        PaceInsights.QualityRun(targetPaceSPerKm: target, achievedPaceSPerKm: achieved)
    }

    @Test func needsTwoRunsBeforeSayingAnything() {
        #expect(PaceInsights.evaluate([]).verdict == .monitoring)
        #expect(PaceInsights.evaluate([run(target: 300, achieved: 288)]).verdict == .monitoring)
    }

    @Test func consistentlyFasterIsAhead() {
        let r = PaceInsights.evaluate([run(target: 300, achieved: 288), run(target: 300, achieved: 286)])
        #expect(r.verdict == .ahead)
    }

    @Test func consistentlySlowerIsReview() {
        let r = PaceInsights.evaluate([run(target: 300, achieved: 313), run(target: 300, achieved: 311)])
        #expect(r.verdict == .review)
    }

    @Test func onTargetIsOnPoint() {
        let r = PaceInsights.evaluate([run(target: 300, achieved: 302), run(target: 300, achieved: 297)])
        #expect(r.verdict == .onPoint)
    }

    @Test func wideSwingsAreVariable() {
        // Spread of 40 s/km (−20 … +20) reads as inconsistent, regardless of a ~0 mean.
        let r = PaceInsights.evaluate([run(target: 300, achieved: 280), run(target: 300, achieved: 320)])
        #expect(r.verdict == .variable)
    }

    @Test func invalidRunsAreIgnored() {
        // One valid + one zero-target (dropped) → only one valid → monitoring.
        let r = PaceInsights.evaluate([run(target: 0, achieved: 288), run(target: 300, achieved: 288)])
        #expect(r.verdict == .monitoring)
    }
}
