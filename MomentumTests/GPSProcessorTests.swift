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

    /// The reported freeze-then-straight-line bug: real movement ABOVE the discipline hard cap (a fast
    /// descent / the car test) must be kept when the Doppler speed confirms it — otherwise the trace
    /// stalls and bridges the gap with a straight line. ~28 m/s (100 km/h), above the 22 m/s bike cap.
    @Test func acceptsRealMovementAboveHardCapWhenDopplerConfirms() {
        let cycleConfig = GPSProcessor.Config.forType(.ride)
        let prev = fix(0, 0, acc: 8, t: 0)
        let fast = fix(0.000252, 0, acc: 8, speed: 28, t: 1)   // ~28 m over 1s, Doppler agrees
        #expect(GPSProcessor.acceptable(fast, previous: prev, config: cycleConfig))
    }

    /// …but a jump that far exceeds the Doppler speed is still a lateral spike, even at high speed.
    @Test func rejectsSpikeExceedingDopplerAtSpeed() {
        let cycleConfig = GPSProcessor.Config.forType(.ride)
        let prev = fix(0, 0, acc: 8, t: 0)
        let spike = fix(0.000486, 0, acc: 8, speed: 20, t: 1)  // ~54 m/s implied, reported 20 ⇒ spike
        #expect(!GPSProcessor.acceptable(spike, previous: prev, config: cycleConfig))
    }

    /// End-to-end: a fast ride (~25 m/s, one fix/second, Doppler agreeing) accrues the trace
    /// continuously — every fix accepted, no rejection gap that would freeze then straight-line-bridge.
    @Test func fastRideAccumulatesWithoutGaps() {
        var p = GPSProcessor(config: .forType(.ride))
        var accepted = 0
        for i in 0...5 {
            let r = p.ingest(fix(0.000225 * Double(i), 0, acc: 8, speed: 25, t: Double(i)))  // ~25 m/step
            if case .accepted = r { accepted += 1 }
        }
        #expect(accepted == 6)          // every fix kept (no freeze)
        #expect(p.distanceM > 100)      // ~125 m of trace accrued smoothly
    }

    /// With no valid Doppler speed (cold start / tunnel), the discipline hard cap is the only guard.
    @Test func hardCapAppliesWhenNoDopplerSpeed() {
        let prev = fix(0, 0, acc: 8, t: 0)
        let overCap = fix(0.0001, 0, acc: 8, speed: -1, t: 1)   // ~11.1 m/s > 8 run cap ⇒ reject
        #expect(!GPSProcessor.acceptable(overCap, previous: prev, config: runConfig))
        let underCap = fix(0.00006, 0, acc: 8, speed: -1, t: 1) // ~6.7 m/s < 8 run cap ⇒ accept
        #expect(GPSProcessor.acceptable(underCap, previous: prev, config: runConfig))
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

    /// Resume hysteresis: once auto-paused, hovering just above the pause threshold must NOT flap
    /// the banner — clearing requires 1.5× threshold (walk: 0.5 → 0.75 m/s).
    @Test func autoPauseResumeRequiresHysteresisMargin() {
        var p = GPSProcessor(config: GPSProcessor.Config.forType(.walk))
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        #expect(p.shouldAutoPause(speedMS: 0.55, now: t0, currentlyPaused: true) == true)   // stays paused
        #expect(p.shouldAutoPause(speedMS: 0.80, now: t0.addingTimeInterval(1), currentlyPaused: true) == false)
    }

    /// The stale-anchor hole: standing at a light freezes `anchor.t`, so a later spike's implied
    /// speed was diluted by the long dt and slipped through. The gate must reference the LAST
    /// accepted fix (seconds old), which reads the same spike as ~40 m/s and rejects it.
    @Test func spikeAfterLongStationaryWaitIsRejected() {
        var p = GPSProcessor(config: runConfig)
        // Establish the anchor, then stand still for 60 s of accepted micro-move jitter (speed ~0,
        // sub-2m wobble never advances the anchor).
        _ = p.ingest(fix(30.0, -97.0, acc: 5, speed: 0, t: 0))
        for t in stride(from: 1.0, through: 60.0, by: 1.0) {
            let r = p.ingest(fix(30.0 + 0.000005, -97.0, acc: 5, speed: 0, t: t))
            #expect(r != .rejected)
        }
        let before = p.distanceM
        // A 40 m lateral spike one second later, device speed still 0. Against the stale anchor
        // this implied a lazy 0.7 m/s and was accepted; against the last fix it's ~40 m/s.
        let spike = p.ingest(fix(30.0, -97.0 + 0.00042, acc: 5, speed: 0, t: 61))
        #expect(spike == .rejected)
        #expect(p.distanceM == before)   // no phantom spur, no phantom distance
    }

    /// Manual pause (Strava semantics): the paused walk keeps the filter warm — the map dot follows —
    /// but accrues NOTHING (no distance/elevation/pace, `distanceAddedM == 0` so the engine appends no
    /// route point), and the anchors rebase so post-resume movement measures only itself.
    @Test func manualPauseAccruesNothingButKeepsTheDotWarm() {
        var p = GPSProcessor(config: runConfig)
        var lat = 30.0
        _ = p.ingest(fix(lat, -97.0, acc: 5, speed: 5, t: 0))
        for t in stride(from: 1.0, through: 5.0, by: 1.0) {          // running north, ~4.4m per fix
            lat += 0.00004
            #expect(p.ingest(fix(lat, -97.0, acc: 5, speed: 5, t: t)) != .rejected)
        }
        let runningDistance = p.distanceM
        #expect(runningDistance > 12)                                 // ~22m accrued while running

        // Paused: walk another ~44m north over 10 fixes. Dot must follow; nothing may accrue.
        for t in stride(from: 6.0, through: 15.0, by: 1.0) {
            lat += 0.00004
            let r = p.ingest(fix(lat, -97.0, acc: 5, speed: 5, t: t), paused: true)
            #expect(r == .accepted(distanceAddedM: 0))                // never a route-worthy move
        }
        #expect(p.distanceM == runningDistance)                       // the paused walk contributed zero
        #expect(abs(p.filteredLat - lat) < 0.0001)                    // filter tracked the walk (dot follows)

        // Resume: measured from the PAUSED position — never spike-rejected, and only the ~4.4m of
        // real post-resume movement counts (never the 44m walked while paused).
        lat += 0.00004
        let resumed = p.ingest(fix(lat, -97.0, acc: 5, speed: 5, t: 16))
        #expect(resumed != .rejected)
        #expect(p.distanceM - runningDistance < 8)
    }

    // MARK: On-device accuracy fixes (2026-07-23 demo-video recording)

    @Test func stationaryDopplerWanderAddsNoDistance() {
        // Standing at a light: Doppler reads ~0 while position wanders 3–4m per fix — every
        // wander clears the 2m movement gate, so meters used to accrue while covering none.
        var p = GPSProcessor(config: runConfig)
        _ = p.ingest(fix(30.0, -97.0, acc: 5, speed: 3, t: 0))
        var lat = 30.0 + 0.00003
        _ = p.ingest(fix(lat, -97.0, acc: 5, speed: 3, t: 1))
        let moving = p.distanceM
        // 20 fixes of pure wander, Doppler pinned at 0.1 m/s (genuinely stopped).
        for t in stride(from: 2.0, through: 21.0, by: 1.0) {
            lat += (Int(t) % 2 == 0 ? 0.00003 : -0.00003)   // ±3.3m oscillation
            _ = p.ingest(fix(lat, -97.0, acc: 5, speed: 0.1, t: t))
        }
        #expect(p.distanceM == moving)   // the light cost zero meters
        // Moving again accrues normally, measured from the rebased anchor (the Kalman needs a
        // couple of fixes to trust motion again after standing still — correct, not a bug).
        for t in stride(from: 22.0, through: 24.0, by: 1.0) {
            lat += 0.00004
            _ = p.ingest(fix(lat, -97.0, acc: 5, speed: 3, t: t))
        }
        #expect(p.distanceM > moving)
    }

    @Test func unknownDopplerNeverTriggersStationaryGuard() {
        // A negative speed is "unknown", not "stopped" — position-only movement must still count
        // (canopy, urban canyon), same doctrine as the engine's auto-pause.
        var p = GPSProcessor(config: runConfig)
        _ = p.ingest(fix(30.0, -97.0, acc: 5, speed: -1, t: 0))
        _ = p.ingest(fix(30.00005, -97.0, acc: 5, speed: -1, t: 2))
        #expect(p.distanceM > 4)
    }

    @Test func elevationJitterAccruesNothing() {
        // Flat run, altitude wobbling ±2m — the old per-fix accrual booked every positive tick.
        var p = GPSProcessor(config: runConfig)
        var lat = 30.0
        for (i, t) in stride(from: 0.0, through: 20.0, by: 1.0).enumerated() {
            lat += 0.00004
            let alt = 100.0 + (i % 2 == 0 ? 2.0 : -2.0)
            _ = p.ingest(.init(t: Date(timeIntervalSinceReferenceDate: t), lat: lat, lon: -97.0,
                               accuracyM: 5, speedMS: 3, altitudeM: alt))
        }
        #expect(p.elevationGainM == 0)
    }

    @Test func realClimbCountsFromTheValley() {
        // A 12m ascent, a descent, then a second 6m climb — both count, the descent rebasing the
        // anchor so climb two measures from its own base. Plateaus let the altitude EMA converge;
        // each top can hold back at most one sub-threshold (<3m) residual, so 18m of real climb
        // must book at least 12m and never more than 18.
        var p = GPSProcessor(config: runConfig)
        var lat = 30.0
        var t = 0.0
        func step(_ alt: Double, times: Int = 1) {
            for _ in 0..<times {
                lat += 0.00004
                _ = p.ingest(.init(t: Date(timeIntervalSinceReferenceDate: t), lat: lat, lon: -97.0,
                                   accuracyM: 5, speedMS: 3, altitudeM: alt))
                t += 1
            }
        }
        for alt in stride(from: 100.0, through: 112.0, by: 2.0) { step(alt) }   // +12
        step(112, times: 10)                                                    // summit plateau
        for alt in stride(from: 112.0, through: 104.0, by: -2.0) { step(alt) }  // descent (rebases)
        step(104, times: 10)                                                    // valley plateau
        for alt in stride(from: 104.0, through: 110.0, by: 2.0) { step(alt) }   // +6
        step(110, times: 10)                                                    // final plateau
        #expect(p.elevationGainM >= 12 && p.elevationGainM <= 18)
        // And a flat continuation adds nothing further.
        let settled = p.elevationGainM
        step(110, times: 10)
        #expect(p.elevationGainM == settled)
    }

    // MARK: Doppler-first distance (2026-09-06) — the headline no longer sums the filtered path

    /// Time-correlated GPS error, the kind a phone actually produces (AR(1), τ ≈ 15 s). Independent
    /// noise flatters the chord sum; this does not.
    private struct Wobble {
        var state: UInt32 = 20_260_906
        mutating func next() -> Double { state = 1_664_525 &* state &+ 1_013_904_223; return (Double(state) + 1) / 4_294_967_297.0 }
        mutating func gauss() -> Double { let u1 = next(), u2 = next(); return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2) }
    }
    private let lat0 = 37.0, lon0 = -122.0
    private var mLat: Double { 111_320.0 }
    private var mLon: Double { 111_320.0 * cos(lat0 * .pi / 180) }

    /// A steady straight run at `speed`, one fix per second, σ metres of correlated position error,
    /// and a device speed reading wobbling ±`dopplerSigma`.
    private func noisyRun(seconds: Int, speed: Double, sigma: Double, dopplerSigma: Double = 0.25,
                          doppler: Bool = true) -> [GPSProcessor.Fix] {
        var rng = Wobble()
        let a = exp(-1.0 / 15.0), inn = sigma * (1 - a * a).squareRoot()
        var ex = sigma * rng.gauss(), ey = sigma * rng.gauss()
        return (0..<seconds).map { i in
            ex = a * ex + inn * rng.gauss(); ey = a * ey + inn * rng.gauss()
            let along = Double(i) * speed
            return GPSProcessor.Fix(t: Date(timeIntervalSinceReferenceDate: Double(i)),
                                    lat: lat0 + (along + ey) / mLat, lon: lon0 + ex / mLon,
                                    accuracyM: sigma,
                                    speedMS: doppler ? max(0, speed + dopplerSigma * rng.gauss()) : -1,
                                    altitudeM: 0)
        }
    }

    /// THE fix. At a reported accuracy of 5 m the chord sum ran ~5% long on a straight and worse on a
    /// grid — miles long, pace flatteringly fast, every run. Integrating the device's speed holds the
    /// headline inside 1% on the same fixes, and the retained chord-only figure proves the fixture is
    /// in the regime that used to break.
    @Test(arguments: [3.0, 5.0, 8.0])
    func dopplerIntegrationHoldsTheHeadlineUnderCorrelatedNoise(sigma: Double) {
        var p = GPSProcessor(config: runConfig)
        for f in noisyRun(seconds: 1000, speed: 3.0, sigma: sigma) { _ = p.ingest(f) }
        let truth = 999 * 3.0
        #expect(abs(p.distanceM - truth) / truth < 0.012, "σ=\(sigma): headline \(p.distanceM)m vs \(truth)m")
        #expect(p.chordOnlyDistanceM > truth * 1.02, "σ=\(sigma): chord sum \(p.chordOnlyDistanceM)m should still inflate — fixture not exercising the defect")
    }

    /// A walker is where the chord sum was worst (+27% measured at 1.2 m/s, jitter being a large
    /// fraction of each step). The same rule holds them inside 3%.
    @Test func aSlowWalkerIsNotInflated() {
        var p = GPSProcessor(config: .forType(.walk))
        for f in noisyRun(seconds: 1200, speed: 1.2, sigma: 5) { _ = p.ingest(f) }
        let truth = 1199 * 1.2
        #expect(abs(p.distanceM - truth) / truth < 0.03, "walker \(p.distanceM)m vs \(truth)m")
    }

    /// Without a speed reading the chord fallback carries the run — and still measures it (not zero,
    /// not the old raw-walk inflation either: the Kalman + gate stay).
    @Test func withoutASpeedReadingTheChordFallbackStillMeasuresTheRun() {
        var p = GPSProcessor(config: runConfig)
        for f in noisyRun(seconds: 600, speed: 3.0, sigma: 3, doppler: false) { _ = p.ingest(f) }
        let truth = 599 * 3.0
        #expect(p.distanceM > truth * 0.98 && p.distanceM < truth * 1.06, "fallback \(p.distanceM)m vs \(truth)m")
    }

    /// Speed is integrated only once the POSITION has moved past the gate: a frozen position with a
    /// confident speed reading accrues nothing, so jitter can't be talked into distance.
    @Test func speedIsOnlyTrustedWhenThePositionCorroboratesMovement() {
        var p = GPSProcessor(config: runConfig)
        _ = p.ingest(fix(0, 0, acc: 5, speed: 3, t: 0))
        for i in 1...10 {   // ~0.5 m wander, device insisting on 3 m/s
            _ = p.ingest(fix(0.0000045 * Double(i % 2), 0, acc: 5, speed: 3, t: Double(i)))
        }
        #expect(p.distanceM == 0)
    }

    /// A stuck or bogus speed is bounded by what the position supports (`2 × chord + 2 m`), so one
    /// bad reading can't add tens of metres; a real stride's reading sits far under the cap.
    @Test func aBogusSpeedIsCappedByWhatThePositionSupports() {
        var p = GPSProcessor(config: runConfig)
        _ = p.ingest(fix(0, 0, acc: 5, speed: 3, t: 0))
        // 2.5 m of real movement in 1 s, device claiming 20 m/s: trapezoid says 11.5 m, cap says 7 m.
        guard case let .accepted(added) = p.ingest(fix(0.0000225, 0, acc: 5, speed: 20, t: 1)) else {
            Issue.record("expected accepted"); return
        }
        #expect(added <= 2 * 2.5 + 2 + 0.05)
        #expect(added >= 2.5 - 0.05)
        // A genuine stride: reading and position agree, nothing is capped.
        var q = GPSProcessor(config: runConfig)
        _ = q.ingest(fix(0, 0, acc: 5, speed: 3, t: 0))
        guard case let .accepted(stride) = q.ingest(fix(0.000027, 0, acc: 5, speed: 3, t: 1)) else {
            Issue.record("expected accepted"); return
        }
        #expect(abs(stride - 3.0) < 0.05)
    }

    /// Past 30 s between counted fixes the endpoint speeds say nothing about the gap — the chord is
    /// the honest floor (`accumulatesDistance` above is the 60 s case; this is the boundary).
    @Test func aLongGapFallsBackToTheChord() {
        var p = GPSProcessor(config: runConfig)
        _ = p.ingest(fix(0, 0, acc: 5, speed: 3, t: 0))
        // 29 s, 60 m apart (~2.07 m/s implied; device says 3): integrated → 87 m, but capped at 2·60+2.
        guard case let .accepted(inside) = p.ingest(fix(0.00054, 0, acc: 5, speed: 3, t: 29)) else { Issue.record("accepted"); return }
        #expect(inside > 60.5 && inside <= 122.1)
        var q = GPSProcessor(config: runConfig)
        _ = q.ingest(fix(0, 0, acc: 5, speed: 3, t: 0))
        guard case let .accepted(outside) = q.ingest(fix(0.00054, 0, acc: 5, speed: 3, t: 31)) else { Issue.record("accepted"); return }
        #expect(abs(outside - 60.0) < 0.5, "past the gap the chord is used: \(outside)m")
    }

    // MARK: Current pace follows the speed reading

    /// The number on the screen: on a steady effort with real jitter it now holds within ~25 s/km of
    /// the truth and never jumps more than 30 s/km between seconds (it used to swing ±150).
    @Test func currentPaceFollowsTheSpeedReadingAndStaysSteady() {
        var p = GPSProcessor(config: runConfig)
        var prev: Double?
        var worst = 0.0, offAfterWarmup = 0.0
        for (i, f) in noisyRun(seconds: 300, speed: 3.0, sigma: 5).enumerated() {
            _ = p.ingest(f)
            let pace = p.smoothedPaceSPerKm
            if i > 30 {
                offAfterWarmup = max(offAfterWarmup, abs(pace - 1000 / 3.0))
                if let prev { worst = max(worst, abs(pace - prev)) }
            }
            prev = pace
        }
        #expect(offAfterWarmup < 25, "pace strayed \(offAfterWarmup) s/km from a steady 5:33")
        #expect(worst < 30, "pace jumped \(worst) s/km between seconds")
    }

    /// A surge shows within a few strides: from 3.0 to 4.5 m/s the smoothed pace crosses halfway to
    /// the new value inside ~5 s (the 6 s time constant), so an interval's start is felt, not lagged.
    @Test func currentPaceReactsToASurgeWithinSeconds() {
        var p = GPSProcessor(config: runConfig)
        var t = 0.0, along = 0.0
        func go(_ speed: Double, _ seconds: Int) {
            for _ in 0..<seconds { t += 1; along += speed
                _ = p.ingest(GPSProcessor.Fix(t: Date(timeIntervalSinceReferenceDate: t), lat: lat0 + along / mLat, lon: lon0,
                                              accuracyM: 5, speedMS: speed, altitudeM: 0)) }
        }
        go(3.0, 60)
        #expect(abs(p.smoothedPaceSPerKm - 1000 / 3.0) < 2)
        go(4.5, 5)
        let halfway = 1000 / ((3.0 + 4.5) / 2)
        #expect(p.smoothedPaceSPerKm < halfway, "after 5 s of surging pace should be past halfway: \(p.smoothedPaceSPerKm)")
        go(4.5, 25)
        #expect(abs(p.smoothedPaceSPerKm - 1000 / 4.5) < 3)
    }

    /// Without a speed reading pace falls back to the distance the rule accrued over the span it
    /// covered — the pre-Doppler behaviour, smoothed the same way.
    @Test func currentPaceFallsBackToChordSpeedWithoutDoppler() {
        var p = GPSProcessor(config: runConfig)
        for f in noisyRun(seconds: 120, speed: 3.0, sigma: 0.5, doppler: false) { _ = p.ingest(f) }
        #expect(abs(p.smoothedPaceSPerKm - 1000 / 3.0) < 15, "fallback pace \(p.smoothedPaceSPerKm) vs 333")
    }
}
