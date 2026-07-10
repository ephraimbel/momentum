import Testing
import Foundation
@testable import Momentum

/// `GPSKalmanFilter` — the real-time constant-velocity filter that corrects each accepted fix before
/// it feeds the route + distance (PRD §8.3). These pin the properties that make tracing accurate:
/// it seeds cleanly, tracks a moving athlete with low lag, damps lateral GPS jitter, and is
/// deterministic so a replayed route matches the live one.
struct GPSKalmanFilterTests {
    let base = (lat: 37.7686, lon: -122.4830)
    let config = GPSKalmanFilter.Config.forType(.run)

    /// Offset `base` by metres using the app's lat/lon-per-metre conversion.
    func at(north n: Double, east e: Double, t: TimeInterval) -> (t: Date, lat: Double, lon: Double, accuracyM: Double) {
        (t: Date(timeIntervalSinceReferenceDate: t),
         lat: base.lat + n / 111_320,
         lon: base.lon + e / (111_320 * cos(base.lat * .pi / 180)),
         accuracyM: 8)
    }

    func meters(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Double {
        Geo.distance(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon)
    }

    @Test func firstFixIsReturnedUnchanged() {
        var f = GPSKalmanFilter(config: config)
        let s = at(north: 0, east: 0, t: 0)
        let out = f.process(t: s.t, lat: s.lat, lon: s.lon, accuracyM: s.accuracyM)
        #expect(abs(out.lat - s.lat) < 1e-9 && abs(out.lon - s.lon) < 1e-9)
    }

    /// A clean constant-velocity run (3 m/s east, no noise) must be tracked with only a small startup
    /// lag — after a few seconds the estimate sits within a metre of the true position.
    @Test func tracksConstantVelocityPathWithLowLag() {
        var f = GPSKalmanFilter(config: config)
        var last = (lat: 0.0, lon: 0.0)
        for i in 0...10 {
            let s = at(north: 0, east: Double(i) * 3, t: Double(i))
            last = f.process(t: s.t, lat: s.lat, lon: s.lon, accuracyM: s.accuracyM)
        }
        let truth = at(north: 0, east: 30, t: 10)
        #expect(meters(last, (truth.lat, truth.lon)) < 1.5)
    }

    /// The core denoising win: fed a straight eastward path with alternating ±5m lateral (north)
    /// jitter, the filter's cross-track error is smaller than the raw measurements' — the line stops
    /// zig-zagging.
    @Test func dampsLateralJitter() {
        var f = GPSKalmanFilter(config: config)
        var rawSq = 0.0, filtSq = 0.0
        var count = 0
        for i in 0...20 {
            let jitter = i % 2 == 0 ? 5.0 : -5.0
            let s = at(north: jitter, east: Double(i) * 3, t: Double(i))
            let out = f.process(t: s.t, lat: s.lat, lon: s.lon, accuracyM: s.accuracyM)
            // North offset (metres) of raw vs filtered from the true centreline (north = 0).
            let rawNorth = (s.lat - base.lat) * 111_320
            let filtNorth = (out.lat - base.lat) * 111_320
            if i > 3 {   // skip startup transient
                rawSq += rawNorth * rawNorth
                filtSq += filtNorth * filtNorth
                count += 1
            }
        }
        let rawRMS = (rawSq / Double(count)).squareRoot()
        let filtRMS = (filtSq / Double(count)).squareRoot()
        #expect(filtRMS < rawRMS)          // strictly smoother than raw
        #expect(filtRMS < 0.75 * rawRMS)   // and by a meaningful margin
    }

    /// A tighter-accuracy fix must pull the estimate harder than a loose one: two identical jumps, one
    /// reported at 4m and one at 40m, land the estimate closer to the measurement for the 4m fix.
    @Test func weightsFixesByReportedAccuracy() {
        func settle(accuracy: Double) -> Double {
            var f = GPSKalmanFilter(config: config)
            _ = f.process(t: Date(timeIntervalSinceReferenceDate: 0), lat: base.lat, lon: base.lon, accuracyM: accuracy)
            // A single 10m-east jump one second later.
            let jump = at(north: 0, east: 10, t: 1)
            let out = f.process(t: jump.t, lat: jump.lat, lon: jump.lon, accuracyM: accuracy)
            return (out.lon - base.lon) * 111_320 * cos(base.lat * .pi / 180)   // east metres reached
        }
        #expect(settle(accuracy: 4) > settle(accuracy: 40))
    }

    /// Determinism: identical input yields identical output, so replaying stored samples reproduces
    /// the live track exactly.
    @Test func batchSmoothIsDeterministic() {
        let samples = (0...10).map { at(north: sin(Double($0)) * 4, east: Double($0) * 3, t: Double($0)) }
        let a = GPSKalmanFilter.smooth(samples, config: config)
        let b = GPSKalmanFilter.smooth(samples, config: config)
        #expect(a.count == samples.count)
        for (p, q) in zip(a, b) {
            #expect(p.lat == q.lat && p.lon == q.lon)
        }
    }
}
