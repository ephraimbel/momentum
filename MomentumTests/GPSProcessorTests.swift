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
