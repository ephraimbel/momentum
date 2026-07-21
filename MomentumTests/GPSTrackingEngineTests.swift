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

    /// Movement during a manual pause must not enter the run: the live route and distance freeze
    /// (the trace never draws the paused walk), while the dot (`tip`) keeps following the athlete.
    /// On resume, recording picks up from the paused position — only post-resume movement counts.
    @Test func manualPauseFreezesRouteAndDistanceButTipFollows() async {
        let engine = GPSTrackingEngine(type: .run)
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        await engine.begin(now: t0)
        // Run north for 5 fixes (~4.4m each) — route and distance accrue.
        var lat = 37.0
        for dt in stride(from: 0.0, through: 4.0, by: 1.0) {
            await engine.ingest(fix(t0, dt, speed: 5, lat: lat), now: t0.addingTimeInterval(dt))
            lat += 0.00004
        }
        let before = await engine.snapshot()
        #expect(before.route.count >= 4)
        #expect(before.distanceM > 12)

        // Pause, then keep walking (~44m over 10 fixes).
        await engine.pause()
        for dt in stride(from: 5.0, through: 14.0, by: 1.0) {
            await engine.ingest(fix(t0, dt, speed: 5, lat: lat), now: t0.addingTimeInterval(dt))
            lat += 0.00004
        }
        let paused = await engine.snapshot()
        #expect(paused.route.count == before.route.count)     // trace never draws the paused walk
        #expect(paused.distanceM == before.distanceM)         // distance frozen
        if let tip = paused.tip {
            #expect(abs(tip.lat - lat) < 0.0002)              // but the dot kept following
        } else {
            Issue.record("tip missing while paused")
        }

        // Resume → the very next moving fix records again, measured from the paused position.
        await engine.resume()
        await engine.ingest(fix(t0, 15, speed: 5, lat: lat), now: t0.addingTimeInterval(15))
        let resumed = await engine.snapshot()
        #expect(resumed.route.count == before.route.count + 1)
        let delta = resumed.distanceM - before.distanceM
        #expect(delta > 0 && delta < 8)                        // ~4.4m, never the 44m paused walk
    }

    /// CoreLocation reports a NEGATIVE `speed` when it has no valid Doppler measurement — under
    /// canopy, in an urban canyon, on a cold re-acquire. That sentinel used to be clamped with
    /// `max(0, ...)` into a confident "stationary", so a runner under trees was auto-paused while
    /// still moving: the clock froze, position-only fixes kept adding distance, and the finished run
    /// came back short on time and fast on pace.
    @Test func invalidDopplerSpeedDoesNotLatchAutoPause() async {
        let engine = GPSTrackingEngine(type: .run)
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        await engine.begin(now: t0)
        func ingest(_ dt: Double, speed: Double, lat: Double) async {
            await engine.ingest(fix(t0, dt, speed: speed, lat: lat), now: t0.addingTimeInterval(dt))
        }
        // Running normally.
        for i in 0..<10 {
            await ingest(Double(i), speed: 3, lat: 37.0 + Double(i) * 0.000027)
        }
        #expect(await engine.snapshot().state == .tracking)

        // Signal degrades: speed unknown, but the athlete is demonstrably still covering ground.
        for i in 10..<25 {
            await ingest(Double(i), speed: -1, lat: 37.0 + Double(i) * 0.000027)
        }
        #expect(await engine.snapshot().state == .tracking,
                "an unknown speed is not evidence of stopping — this auto-paused before the fix")
    }

    /// The guard must not break real auto-pause: a genuine, measured zero still pauses.
    @Test func aMeasuredZeroSpeedStillAutoPauses() async {
        let engine = GPSTrackingEngine(type: .run)
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        await engine.begin(now: t0)
        func ingest(_ dt: Double, speed: Double, lat: Double) async {
            await engine.ingest(fix(t0, dt, speed: speed, lat: lat), now: t0.addingTimeInterval(dt))
        }
        await ingest(0, speed: 3, lat: 37.0)
        await ingest(1, speed: 0, lat: 37.0)
        await ingest(7, speed: 0, lat: 37.0)
        #expect(await engine.snapshot().state == .autoPaused)
    }
}
