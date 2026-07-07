import Testing
import Foundation
@testable import Momentum

/// The live-run pause/resume state machine (PRD §8.3). Auto-pause is a convenience; a manual Resume
/// must always win — including while standing still.
struct GPSTrackingEngineTests {

    private func fix(_ t0: Date, _ dt: Double, speed: Double, lat: Double) -> GPSProcessor.Fix {
        GPSProcessor.Fix(t: t0.addingTimeInterval(dt), lat: lat, lon: 0, accuracyM: 5, speedMS: speed, altitudeM: 0)
    }

    @Test func manualResumeAlwaysWorksEvenStandingStill() async {
        let engine = GPSTrackingEngine(type: .run)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        await engine.begin(now: t0)
        func ingest(_ dt: Double, speed: Double, lat: Double) async {
            await engine.ingest(fix(t0, dt, speed: speed, lat: lat), now: t0.addingTimeInterval(dt))
        }
        // Move, then stand still past the auto-pause window → auto-paused.
        await ingest(0, speed: 3, lat: 37.0)
        await ingest(1, speed: 0, lat: 37.0)
        await ingest(7, speed: 0, lat: 37.0)
        #expect(await engine.snapshot().state == .autoPaused)

        // THE BUG: tapping Resume while still standing still must resume — and *stay* resumed on the next
        // stationary fix (not instantly re-auto-pause).
        await engine.resume()
        #expect(await engine.snapshot().state == .tracking)
        await ingest(9, speed: 0, lat: 37.0)
        #expect(await engine.snapshot().state == .tracking)

        // Once genuinely moving again, normal auto-pause returns: move, then stop → auto-paused.
        await ingest(11, speed: 3, lat: 37.001)
        await ingest(12, speed: 0, lat: 37.001)
        await ingest(18, speed: 0, lat: 37.001)
        #expect(await engine.snapshot().state == .autoPaused)
    }

    @Test func manualPauseStaysStickyThroughMovingFixes() async {
        let engine = GPSTrackingEngine(type: .run)
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        await engine.begin(now: t0)
        await engine.ingest(fix(t0, 0, speed: 3, lat: 37), now: t0)
        await engine.pause()
        #expect(await engine.snapshot().state == .paused)
        // A manual pause is sticky — moving fixes must not auto-resume it.
        await engine.ingest(fix(t0, 1, speed: 3, lat: 37.001), now: t0.addingTimeInterval(1))
        #expect(await engine.snapshot().state == .paused)
        await engine.resume()
        #expect(await engine.snapshot().state == .tracking)
    }
}
