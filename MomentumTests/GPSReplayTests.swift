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

/// Step 0 of the GPS-truth work: prove the HEADLINE holds its ±2% bar under realistic position
/// noise, before anything downstream is rebuilt to trust or redistribute it.
///
/// `distanceWithinTwoPercent` above drives `squareLoop()` — noiseless, dead-straight, 5 m steps at
/// 0.5 Hz. Nothing in the repo demonstrated the bar held at 1 Hz with real jitter, which is exactly
/// the regime where a raw-haversine walk inflates. These fixtures close that gap and double as the
/// generator the splits/elevation work needs.
extension GPSReplayTests {

    /// Seeded LCG — the system RNG would make every noise fixture a lottery. (Numerical Recipes
    /// constants; full period 2^32.)
    struct Seeded {
        var state: UInt32
        mutating func next() -> Double {          // uniform in (0,1)
            state = 1_664_525 &* state &+ 1_013_904_223
            return (Double(state) + 1) / 4_294_967_297.0
        }
        /// Box–Muller. Gaussian, NOT bounded uniform: it is the tail excursions that matter, and a
        /// bounded generator can make a threshold arithmetically unreachable — a fixture that then
        /// passes for any algorithm at all.
        mutating func gauss(sigma: Double) -> Double {
            let u1 = next(), u2 = next()
            return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    /// A dead-straight northward walk of known true length, with independent Gaussian noise on both
    /// axes. `speedMS` carries the TRUE speed so the Doppler-first accept gate behaves as in the field.
    func noisyStraight(trueM: Double, stepM: Double, sigmaM: Double, hz: Double,
                       seed: UInt32 = 20_260_721) -> [GPSProcessor.Fix] {
        var rng = Seeded(state: seed)
        var out: [GPSProcessor.Fix] = []
        let legs = Int(trueM / stepM)
        let dt = 1 / hz
        for i in 0...legs {
            let alongM = Double(i) * stepM
            out.append(GPSProcessor.Fix(
                t: Date(timeIntervalSinceReferenceDate: Double(i) * dt),
                lat: lat0 + (alongM + rng.gauss(sigma: sigmaM)) / mPerDegLat,
                lon: lon0 + rng.gauss(sigma: sigmaM) / mPerDegLon,
                accuracyM: 5, speedMS: stepM * hz, altitudeM: 0))
        }
        return out
    }

    /// The raw per-sample haversine walk — what splits, PRs and the AI read currently do, and the
    /// measurement this whole body of work exists to stop trusting. Kept here as the control.
    func rawHaversineWalk(_ fixes: [GPSProcessor.Fix]) -> Double {
        var total = 0.0
        for (a, b) in zip(fixes, fixes.dropFirst()) {
            total += Geo.distance(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon)
        }
        return total
    }

    /// THE gate for everything downstream: the Kalman + 2 m move-gate headline stays inside ±2% at
    /// 1 Hz with realistic jitter, while the raw walk over the SAME fixes inflates well past it.
    /// If this ever fails, `GPSProcessor` must be fixed before any consumer is rebuilt on top of it.
    @Test(arguments: [0.5, 1.0])
    func distanceHoldsTwoPercentUnderRealisticNoise(sigma: Double) {
        let fixes = noisyStraight(trueM: 8000, stepM: 2.9641, sigmaM: sigma, hz: 1)
        // No pre-filter: `ingest` already gates internally against `lastAccepted ?? anchor`, which
        // is exactly what the live engine relies on.
        var p = GPSProcessor(config: .forType(.run))
        for f in fixes { _ = p.ingest(f) }
        let error = abs(p.distanceM - 8000) / 8000
        #expect(error < 0.02, "σ=\(sigma): headline \(p.distanceM)m vs 8000m → \(error * 100)% off")
    }

    /// CHARACTERISATION OF A KNOWN DEFECT — not an endorsement.
    ///
    /// Measured inflation of `GPSProcessor.distanceM` over a dead-straight 8 km at 1 Hz, with
    /// independent Gaussian position noise:
    ///
    ///     σ = 0.5 m → 8008.8 m  (+0.11%)
    ///     σ = 1.0 m → 8070.5 m  (+0.88%)
    ///     σ = 1.5 m → 8166.4 m  (+2.08%)   ← breaches the §13.11 ±2% bar
    ///
    /// The error is ONE-DIRECTIONAL (always long) and grows roughly with σ², because perpendicular
    /// jitter adds path length that can never cancel. σ = 1.5 m/axis is not a pathological figure —
    /// consumer GPS with clear sky view sits near 3–5 m CEP, i.e. σ ≈ 2–3 m/axis, and canopy or urban
    /// canyon is worse. Caveat in the other direction: real GNSS error is strongly time-correlated,
    /// so independent noise is a WORST case for this particular mode and true inflation is likely
    /// lower than these numbers.
    ///
    /// This test exists so the breach is recorded rather than discovered later, and so it fails
    /// loudly if it gets worse. **When `GPSProcessor` is tightened, this test should start failing —
    /// delete it then, and extend the parameterised bar above to 1.5.**
    @Test func headlineInflationAtHighNoiseIsAKnownBreach() {
        let fixes = noisyStraight(trueM: 8000, stepM: 2.9641, sigmaM: 1.5, hz: 1)
        var p = GPSProcessor(config: .forType(.run))
        for f in fixes { _ = p.ingest(f) }
        let error = (p.distanceM - 8000) / 8000
        #expect(error > 0, "inflation is one-directional — a negative error means the model changed")
        #expect(error > 0.02, "σ=1.5 no longer breaches ±2% (\(error * 100)%) — tighten the bar and delete this test")
        #expect(error < 0.035, "inflation got materially WORSE: \(error * 100)%")
    }

    /// The fixture is genuinely in the buggy regime — otherwise the test above proves nothing about
    /// the defect. At σ=1.0 the raw walk should inflate by roughly 12%.
    @Test func rawHaversineWalkInflatesOnTheSameFixes() {
        let fixes = noisyStraight(trueM: 8000, stepM: 2.9641, sigmaM: 1.0, hz: 1)
        var p = GPSProcessor(config: .forType(.run))
        for f in fixes { _ = p.ingest(f) }
        let raw = rawHaversineWalk(fixes)
        #expect(raw > 8640, "raw walk \(raw)m should inflate >8% over 8000m — fixture isn't exercising the bug")
        #expect(raw > p.distanceM * 1.05, "raw \(raw)m vs headline \(p.distanceM)m — the gap IS the bug")
    }
}
