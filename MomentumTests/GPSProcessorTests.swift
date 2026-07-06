import Testing
import Foundation
@testable import Momentum

struct GPSProcessorTests {
    let runConfig = GPSProcessor.Config.forType(.run)

    func fix(_ lat: Double, _ lon: Double, acc: Double, speed: Double = 3, t: TimeInterval) -> GPSProcessor.Fix {
        .init(t: Date(timeIntervalSinceReferenceDate: t), lat: lat, lon: lon,
              accuracyM: acc, speedMS: speed, altitudeM: 0)
    }

    @Test func rejectsPoorAccuracy() {
        #expect(!GPSProcessor.acceptable(fix(0, 0, acc: 30, t: 0), previous: nil, config: runConfig))
        #expect(!GPSProcessor.acceptable(fix(0, 0, acc: 0, t: 0), previous: nil, config: runConfig))
    }

    @Test func acceptsFirstGoodFix() {
        #expect(GPSProcessor.acceptable(fix(0, 0, acc: 10, t: 0), previous: nil, config: runConfig))
    }

    @Test func rejectsGPSJump() {
        let prev = fix(0, 0, acc: 10, t: 0)
        // ~111m north in 1s ⇒ ~111 m/s ⇒ jump
        let jump = fix(0.001, 0, acc: 10, t: 1)
        #expect(!GPSProcessor.acceptable(jump, previous: prev, config: runConfig))
    }

    /// The core "cuts across a building" bug: an ~11m lateral spike delivered 1s after the anchor
    /// implies ~11 m/s. It slipped under the old generic 12 m/s cap; the tighter 8 m/s run cap rejects
    /// it. (0.0001° lat ≈ 11.1m.)
    @Test func rejectsSubTwelveRunSpike() {
        let prev = fix(0, 0, acc: 8, t: 0)
        let spike = fix(0.0001, 0, acc: 8, speed: 3, t: 1)   // 11.1m/1s ≈ 11.1 m/s
        #expect(!GPSProcessor.acceptable(spike, previous: prev, config: runConfig))
    }

    /// Doppler cross-check: a jump that stays under the hard cap because fixes arrived seconds apart is
    /// still rejected when it far exceeds the device-reported speed. ~28m over 4s ≈ 7 m/s (< 8 cap) but
    /// the runner's Doppler speed is 1 m/s ⇒ spike (7 > 1 + 5 margin).
    @Test func dopplerCrossCheckRejectsSlowGapSpike() {
        let prev = fix(0, 0, acc: 8, t: 0)
        let spike = fix(0.00025, 0, acc: 8, speed: 1, t: 4)   // 27.8m/4s ≈ 6.95 m/s, reported 1 m/s
        #expect(!GPSProcessor.acceptable(spike, previous: prev, config: runConfig))
    }

    /// A genuinely fast (but real) run stride is still accepted — the guards must not freeze the trace.
    /// ~6.7m over 1s ≈ 6.7 m/s with the Doppler speed agreeing.
    @Test func acceptsFastButRealRunStride() {
        let prev = fix(0, 0, acc: 8, t: 0)
        let stride = fix(0.00006, 0, acc: 8, speed: 6.5, t: 1)   // 6.67m/1s, reported 6.5 m/s
        #expect(GPSProcessor.acceptable(stride, previous: prev, config: runConfig))
    }

    /// A cyclist descending at ~18 m/s (65 km/h) must be accepted — the old shared 12 m/s cap wrongly
    /// rejected legit fast riding; the cycling cap is 22 m/s.
    @Test func acceptsFastCyclingDescent() {
        let cycleConfig = GPSProcessor.Config.forType(.ride)
        let prev = fix(0, 0, acc: 8, t: 0)
        let fast = fix(0.000162, 0, acc: 8, speed: 18, t: 1)   // ~18 m/s, reported 18 m/s
        #expect(GPSProcessor.acceptable(fast, previous: prev, config: cycleConfig))
    }

    @Test func accumulatesDistance() {
        var p = GPSProcessor(config: runConfig)
        _ = p.ingest(fix(0, 0, acc: 10, t: 0))
        // 0.001° latitude ≈ 111m over 60s ⇒ ~1.85 m/s (accepted)
        let r = p.ingest(fix(0.001, 0, acc: 10, t: 60))
        if case let .accepted(added) = r {
            #expect(abs(added - 111.19) < 1.0)
            #expect(abs(p.distanceM - 111.19) < 1.0)
        } else {
            Issue.record("expected accepted")
        }
    }

    @Test func microMoveDoesNotAccrue() {
        var p = GPSProcessor(config: runConfig)
        _ = p.ingest(fix(0, 0, acc: 10, t: 0))
        // ~0.5m move (< 2m gate)
        let r = p.ingest(fix(0.0000045, 0, acc: 10, t: 5))
        #expect(r == .accepted(distanceAddedM: 0))
        #expect(p.distanceM == 0)
    }

    @Test func autoPauseAfterThreshold() {
        var p = GPSProcessor(config: runConfig)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        #expect(p.shouldAutoPause(speedMS: 0.2, now: t0) == false)        // arms the timer
        #expect(p.shouldAutoPause(speedMS: 0.2, now: t0.addingTimeInterval(4)) == true)
    }

    @Test func movementClearsAutoPause() {
        var p = GPSProcessor(config: runConfig)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        _ = p.shouldAutoPause(speedMS: 0.2, now: t0)
        #expect(p.shouldAutoPause(speedMS: 2.0, now: t0.addingTimeInterval(4)) == false)
    }
}
