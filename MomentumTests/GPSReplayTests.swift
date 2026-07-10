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

    /// §13.11: "pace never jumps >30 s/km between 1s updates at steady effort." Drive a straight leg
    /// at a steady ~2.5 m/s with one fix per second and realistic GPS position noise — the noise makes
    /// the *instantaneous* pace swing well past 30 s/km between samples, so this only passes because
    /// the EMA (α=0.2) keeps the *smoothed* pace continuous.
    @Test func smoothedPaceNeverJumpsMoreThan30sPerKmAtSteadyEffort() {
        var p = GPSProcessor(config: .forType(.run))
        // Deterministic per-step lengths around 2.5m (all clear the 2m movement gate). Instantaneous
        // pace = 1000/step ⇒ ranges ~345–455 s/km, i.e. ~110 s/km swings sample-to-sample.
        let stepLengths = [2.2, 2.8, 2.3, 2.7, 2.5, 2.1, 2.9, 2.4]
        var east = 0.0, t = 0.0
        _ = p.ingest(fix(eastM: 0, northM: 0, t: t))   // anchor

        var prevSmoothed: Double?
        var maxInstJump = 0.0, prevInst: Double?
        var maxSmoothedJump = 0.0
        for i in 0..<80 {
            let step = stepLengths[i % stepLengths.count]
            east += step; t += 1   // one fix per second
            guard case .accepted(let added) = p.ingest(fix(eastM: east, northM: 0, t: t)), added > 0
            else { continue }

            let inst = 1000.0 / step   // s/km implied by this 1s step
            if let pi = prevInst { maxInstJump = max(maxInstJump, abs(inst - pi)) }
            prevInst = inst

            if let prev = prevSmoothed {
                let jump = abs(p.smoothedPaceSPerKm - prev)
                maxSmoothedJump = max(maxSmoothedJump, jump)
                #expect(jump <= 30, "smoothed pace jumped \(jump) s/km between 1s updates")
            }
            prevSmoothed = p.smoothedPaceSPerKm
        }
        // The test is only meaningful if the raw signal actually swung past the bar the EMA enforces.
        #expect(maxInstJump > 30, "instantaneous swing \(maxInstJump) — noise too small to be a real test")
        #expect(maxSmoothedJump > 0, "smoothed pace never moved")
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
