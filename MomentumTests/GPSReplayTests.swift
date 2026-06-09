import Testing
import Foundation
@testable import Momentum

/// Replay harness (PRD §13.9): drive the pure `GPSProcessor` with a synthetic trace of a known
/// geometry and assert distance accuracy within ±2% (the §13.11 acceptance bar). Real recorded
/// device traces can be dropped into the same harness later for field validation.
struct GPSReplayTests {
    let lat0 = 37.0
    let lon0 = -122.0
    var mPerDegLat: Double { 111_320.0 }
    var mPerDegLon: Double { 111_320.0 * cos(lat0 * .pi / 180) }

    func fix(eastM: Double, northM: Double, t: Double, acc: Double = 5, speed: Double = 2.5) -> GPSProcessor.Fix {
        GPSProcessor.Fix(
            t: Date(timeIntervalSinceReferenceDate: t),
            lat: lat0 + northM / mPerDegLat,
            lon: lon0 + eastM / mPerDegLon,
            accuracyM: acc, speedMS: speed, altitudeM: 0
        )
    }

    /// Walk a straight leg in ~5m steps at 2.5 m/s (one sample every 2s).
    func leg(from: (e: Double, n: Double), to: (e: Double, n: Double),
             startT: inout Double, into out: inout [GPSProcessor.Fix]) {
        let dE = to.e - from.e, dN = to.n - from.n
        let length = (dE * dE + dN * dN).squareRoot()
        let steps = max(1, Int(length / 5))
        for i in 1...steps {
            let f = Double(i) / Double(steps)
            startT += 2
            out.append(fix(eastM: from.e + dE * f, northM: from.n + dN * f, t: startT))
        }
    }

    /// A 250m × 250m square loop ⇒ ~1000m perimeter.
    func squareLoop() -> [GPSProcessor.Fix] {
        var out: [GPSProcessor.Fix] = []
        var t = 0.0
        out.append(fix(eastM: 0, northM: 0, t: t))
        leg(from: (0, 0), to: (250, 0), startT: &t, into: &out)
        leg(from: (250, 0), to: (250, 250), startT: &t, into: &out)
        leg(from: (250, 250), to: (0, 250), startT: &t, into: &out)
        leg(from: (0, 250), to: (0, 0), startT: &t, into: &out)
        return out
    }

    @Test func distanceWithinTwoPercent() {
        var p = GPSProcessor(config: .forType(.run))
        for f in squareLoop() { _ = p.ingest(f) }
        let error = abs(p.distanceM - 1000) / 1000
        #expect(error < 0.02, "distance \(p.distanceM)m vs 1000m → \(error * 100)% off")
    }

    @Test func rejectsNoiseWithoutCorruptingDistance() {
        var p = GPSProcessor(config: .forType(.run))
        var trace = squareLoop()
        // Splice in garbage: a low-accuracy fix and a teleport jump (both must be rejected).
        trace.insert(fix(eastM: 125, northM: 0, t: 1, acc: 80), at: 25)        // poor accuracy
        trace.insert(fix(eastM: 50_000, northM: 50_000, t: 2, acc: 5), at: 26) // GPS jump
        for f in trace { _ = p.ingest(f) }
        let error = abs(p.distanceM - 1000) / 1000
        #expect(error < 0.02, "noisy distance \(p.distanceM)m vs 1000m → \(error * 100)% off")
    }
}
