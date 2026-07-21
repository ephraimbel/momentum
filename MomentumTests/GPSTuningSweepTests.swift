import Testing
import Foundation
@testable import Momentum

/// A two-sided parameter sweep for the distance headline.
///
/// `GPSReplayTests.headlineInflationAtHighNoiseIsAKnownBreach` records that the headline runs +2.08%
/// long at σ = 1.5 m/axis. Two knobs can pull that down, and they fail in OPPOSITE directions, which
/// is the whole reason this is a sweep and not a guess:
///
///  - `accelNoiseMS2` (Kalman σ_a) — smaller filters harder, so straight-line jitter shrinks, but the
///    estimate lags and starts cutting corners.
///  - `minMovementGateM` — the gate is ANCHOR-HOLD: below it the anchor stays put and the distance is
///    not discarded, it accumulates into a longer leg. Inflation per leg goes as perp²/(2·along), so
///    longer legs suppress it quadratically at no cost in real distance — on a STRAIGHT. On a curve a
///    long leg chords the arc and under-reports.
///
/// So a candidate is only good if it lowers straight-line inflation WITHOUT under-reporting a curve.
/// Optimising either number alone produces a worse app than shipping the known breach.
struct GPSTuningSweepTests {

    let lat0 = 37.0
    let lon0 = -122.0
    var mPerDegLat: Double { 111_320.0 }
    var mPerDegLon: Double { 111_320.0 * cos(lat0 * .pi / 180) }

    struct Seeded {
        var state: UInt32
        mutating func next() -> Double {
            state = 1_664_525 &* state &+ 1_013_904_223
            return (Double(state) + 1) / 4_294_967_297.0
        }
        mutating func gauss(sigma: Double) -> Double {
            let u1 = next(), u2 = next()
            return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    private func fix(eastM: Double, northM: Double, t: Double, speed: Double,
                     rng: inout Seeded, sigma: Double) -> GPSProcessor.Fix {
        GPSProcessor.Fix(
            t: Date(timeIntervalSinceReferenceDate: t),
            lat: lat0 + (northM + rng.gauss(sigma: sigma)) / mPerDegLat,
            lon: lon0 + (eastM + rng.gauss(sigma: sigma)) / mPerDegLon,
            accuracyM: 5, speedMS: speed, altitudeM: 0)
    }

    /// Dead-straight, the inflation case.
    func straight(trueM: Double, stepM: Double, sigma: Double, seed: UInt32 = 20_260_721) -> [GPSProcessor.Fix] {
        var rng = Seeded(state: seed)
        return (0...Int(trueM / stepM)).map { i in
            fix(eastM: 0, northM: Double(i) * stepM, t: Double(i), speed: stepM, rng: &rng, sigma: sigma)
        }
    }

    /// A closed circle of known circumference — the curve-fidelity case. Any candidate that chords
    /// the arc shows up here as a DEFICIT, which is the failure mode straight-line tuning hides.
    func circle(circumferenceM: Double, stepM: Double, sigma: Double, seed: UInt32 = 991) -> [GPSProcessor.Fix] {
        var rng = Seeded(state: seed)
        let r = circumferenceM / (2 * .pi)
        let n = Int(circumferenceM / stepM)
        return (0...n).map { i in
            let theta = 2 * .pi * Double(i) / Double(n)
            return fix(eastM: r * cos(theta), northM: r * sin(theta),
                       t: Double(i) * (stepM / 2.9), speed: 2.9, rng: &rng, sigma: sigma)
        }
    }

    private func measure(_ fixes: [GPSProcessor.Fix], accel: Double, gate: Double) -> Double {
        var c = GPSProcessor.Config.forType(.run)
        c.accelNoiseMS2 = accel
        c.minMovementGateM = gate
        var p = GPSProcessor(config: c)
        for f in fixes { _ = p.ingest(f) }
        return p.distanceM
    }

    /// THE RESULT OF THE SWEEP, pinned so it can't be re-litigated by feel.
    ///
    /// Measured trade-off (8 km straight vs a 200 m circle ≈ a 400 m track bend, σ = 1.5 m/axis):
    ///
    ///     accel  straight   c200      CHORD40(σ0)
    ///     0.60   +2.08%     +4.19%    -4.96%     ← shipped
    ///     0.40   +1.46%     +5.47%    -9.23%
    ///     0.20   +0.72%     +8.87%    -13.75%
    ///     0.15   +0.52%    +10.23%    -14.64%
    ///
    /// It is MONOTONIC in both directions: everything that buys straight-line accuracy pays for it in
    /// turns, and vice versa. Raising `minMovementGateM` is worse still — at gate 5 the noiseless
    /// 40 m circle goes to -17.70%, trading a +2% straight error for a -18% turn error.
    ///
    /// So the shipped pair is the best available point in this two-parameter space, and the σ = 1.5
    /// straight-line breach recorded in `GPSReplayTests` CANNOT be fixed by tuning. The cause is the
    /// constant-velocity Kalman model itself: on a sustained turn `p += v·dt` predicts off the arc
    /// tangentially and the update drags it back, and that zigzag adds length. Filtering harder makes
    /// the prediction dominate, which is exactly why tighter settings degrade curves.
    ///
    /// A real fix is a curvature-aware motion model, not a different constant.
    ///
    /// CAVEAT on the fixtures: a continuous circle is a worst case. Real routes are mostly straight
    /// with intermittent turns, so field error sits somewhere between the straight and circle columns.
    /// These numbers rank the options honestly; they are not a prediction of a specific run.
    @Test func tighteningTheFilterTradesStraightAccuracyForTurnAccuracy() {
        let straight15 = { (a: Double) in
            abs(self.measure(self.straight(trueM: 8000, stepM: 2.9641, sigma: 1.5), accel: a, gate: 2.0) - 8000) / 8000
        }
        let bend = { (a: Double) in
            abs(self.measure(self.circle(circumferenceM: 200, stepM: 2.9, sigma: 1.5), accel: a, gate: 2.0) - 200) / 200
        }
        // Straights improve as the filter tightens...
        #expect(straight15(0.20) < straight15(0.60), "tighter filtering should reduce straight-line inflation")
        // ...and turns get worse by more than the straight gains. This is the whole finding.
        #expect(bend(0.20) > bend(0.60), "tighter filtering should worsen the bend — if not, re-run the sweep")
        #expect(bend(0.20) - bend(0.60) > straight15(0.60) - straight15(0.20),
                "the turn penalty should exceed the straight gain, which is why 0.60 stays")
    }

    /// A longer move gate chords tight turns. Pins why `minMovementGateM` stays at 2.0.
    @Test func aLongerMoveGateChordsTightTurns() {
        let tight = { (g: Double) in
            self.measure(self.circle(circumferenceM: 40, stepM: 2.9, sigma: 0), accel: 0.6, gate: g)
        }
        #expect(tight(5.0) < tight(2.0), "a longer gate should under-report a tight circle")
        #expect((40 - tight(5.0)) / 40 > 0.10, "gate 5 should lose >10% of a 40 m circle — the reason it isn't shipped")
    }

    /// DIAGNOSTIC — kept, disabled. Flip `.disabled` off to reprint the grid when revisiting the
    /// motion model; it is the harness, not a claim.
    @Test(.disabled("diagnostic — enable to reprint the tuning grid"))
    func sweepDiagnostic() {
        // Shortlist from the full grid, plus the current setting as the control.
        // Gate HELD at the shipped 2.0. The wider sweep showed a longer gate buys straight-line
        // accuracy by chording tight turns — a 40 m circle went from -4.96% to -17.70% at gate 5.
        // Trading a +2% straight error for a -18% turn error is a worse app, so the filter is the
        // only lever left and this isolates it.
        let candidates: [(Double, Double)] = [
            (0.60, 2.0), (0.50, 2.0), (0.40, 2.0), (0.30, 2.0), (0.20, 2.0), (0.15, 2.0),
        ]

        var rows: [String] = ["accel gate | str1.5 | str2.0 | c1000 | c200 | c100 | CHORD100(σ0) | CHORD40(σ0) | loop(σ0)"]
        for (a, g) in candidates {
            let s15 = measure(straight(trueM: 8000, stepM: 2.9641, sigma: 1.5), accel: a, gate: g)
            let s20 = measure(straight(trueM: 8000, stepM: 2.9641, sigma: 2.0), accel: a, gate: g)
            let c1000 = measure(circle(circumferenceM: 1000, stepM: 2.9, sigma: 1.5), accel: a, gate: g)
            let c200 = measure(circle(circumferenceM: 200, stepM: 2.9, sigma: 1.5), accel: a, gate: g)
            let c100 = measure(circle(circumferenceM: 100, stepM: 2.9, sigma: 1.5), accel: a, gate: g)
            // NOISELESS tight curves isolate pure chording — the cost of a longer gate with no jitter
            // to hide it. This is the number that says whether a bigger gate eats real distance.
            let ch100 = measure(circle(circumferenceM: 100, stepM: 2.9, sigma: 0), accel: a, gate: g)
            let ch40 = measure(circle(circumferenceM: 40, stepM: 2.9, sigma: 0), accel: a, gate: g)
            // Existing published regression fixture, noiseless 1000 m square.
            let loop = measure(squareLoopFixes(), accel: a, gate: g)
            func pct(_ got: Double, _ truth: Double) -> String {
                String(format: "%+6.2f%%", (got - truth) / truth * 100)
            }
            rows.append("\(String(format: "%.2f", a))  \(String(format: "%.1f", g))  | "
                + "\(pct(s15, 8000)) | \(pct(s20, 8000)) | \(pct(c1000, 1000)) | "
                + "\(pct(c200, 200)) | \(pct(c100, 100)) | \(pct(ch100, 100)) | "
                + "\(pct(ch40, 40)) | \(pct(loop, 1000))")
        }
        let table = rows.joined(separator: "\nSWEEP ")
        #expect(Bool(false), "SWEEP \(table)")
    }

    /// The existing published fixture geometry: a noiseless 250 m square, 5 m steps at 0.5 Hz.
    func squareLoopFixes() -> [GPSProcessor.Fix] {
        var rng = Seeded(state: 1)
        var out: [GPSProcessor.Fix] = []
        var t = 0.0
        let corners: [(Double, Double)] = [(0, 0), (250, 0), (250, 250), (0, 250), (0, 0)]
        out.append(fix(eastM: 0, northM: 0, t: 0, speed: 2.5, rng: &rng, sigma: 0))
        for (from, to) in zip(corners, corners.dropFirst()) {
            let dE = to.0 - from.0, dN = to.1 - from.1
            let steps = max(1, Int((dE * dE + dN * dN).squareRoot() / 5))
            for i in 1...steps {
                let f = Double(i) / Double(steps)
                t += 2
                out.append(fix(eastM: from.0 + dE * f, northM: from.1 + dN * f,
                               t: t, speed: 2.5, rng: &rng, sigma: 0))
            }
        }
        return out
    }
}
