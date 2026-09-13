import Foundation

/// Pure GPS sample processing (PRD §8.3) — accept gate, Doppler-first distance (`GPSDistanceRule`),
/// speed-smoothed current pace, and auto-pause detection. Extracted from the actor so it can be
/// unit-tested against recorded traces with no CoreLocation dependency. **Constants here are
/// authoritative.**
struct GPSProcessor {

    struct Fix: Equatable, Sendable {
        let t: Date
        let lat: Double
        let lon: Double
        let accuracyM: Double
        let speedMS: Double   // device-reported; may be < 0 when invalid
        let altitudeM: Double
    }

    struct Config: Sendable {
        var minAccuracyM = 25.0               // PRD §22 accept gate — documented, unchanged.
        /// Backstop ceiling on the speed implied by two consecutive fixes, used **only when the device
        /// reports no valid Doppler speed** (cold start / tunnel). When Doppler is present the accept
        /// gate trusts it instead (see `acceptable`), so real fast movement is never rejected — this cap
        /// just bounds position-only jumps. Discipline-specific: a runner never sustains a bike descent.
        var maxImpliedSpeedMS: Double
        /// Doppler cross-check margin. A positional jump implying more than the device-reported speed
        /// (`Fix.speedMS`, carrier-phase derived and largely independent of position error) plus this
        /// margin is treated as a GPS spike — the guard that catches jumps slipping under the hard cap
        /// because fixes arrived seconds apart.
        var outlierSpeedMarginMS: Double
        /// Positional movement required before distance accrues — jitter under it holds the anchor.
        /// Also the corroboration gate for integrated speed (see `GPSDistanceRule`).
        var minMovementGateM = 2.0
        /// Time constant of the current-pace smoother. Pace follows the device's speed reading (a
        /// steady, unbiased signal) through a 6 s exponential average: at 1 Hz that is ~8 s/km RMS
        /// around a steady effort against ~50 s/km for the old per-fix position-delta EMA, with a
        /// worst 1 s jump of ~15 s/km instead of ~150. Short enough to show a surge within a few
        /// strides; long enough that the number on the screen stops flickering.
        var paceTimeConstantS = 6.0
        var autoPauseSpeedMS: Double
        var autoPauseSecs: Double
        /// Kalman process-noise (σ_a) for the real-time position filter (see `GPSKalmanFilter`).
        var accelNoiseMS2 = 0.6
        /// GPS altitude wobbles ±3–5 m even standing still — accruing every positive tick
        /// over-counted a flat run's climb badly (caught on-device 2026-07-23). Gain now accrues
        /// only once a climb clears this threshold from its valley anchor; real rolling hills
        /// (each ≥ this) still count in full.
        var elevationGainThresholdM = 3.0

        /// How far the device's speed reading may be believed against the filtered chords (see
        /// `GPSDistanceRule`). The chord sum inflates by an amount that depends on how far a stride
        /// carries between fixes: a little at running and riding speeds, a lot for a walker. The
        /// band brackets the inverse of that inflation; a reading outside it is not believed, and
        /// position carries the run.
        var speedTrustBand: ClosedRange<Double> = 0.90...1.15

        /// Discipline-specific accept-gate + auto-pause thresholds (§8.3).
        static func forType(_ type: WorkoutType) -> Config {
            switch type.discipline {
            case .cycling:   // all bike variants — allow fast descents (~80 km/h) but reject teleports
                return Config(maxImpliedSpeedMS: 22.0, outlierSpeedMarginMS: 8.0,
                              autoPauseSpeedMS: 1.0, autoPauseSecs: 5.0, accelNoiseMS2: 1.2,
                              speedTrustBand: 0.90...1.15)
            case .walking:   // walk / hike — slow, so a tight cap sharply cleans the trace
                return Config(maxImpliedSpeedMS: 4.5, outlierSpeedMarginMS: 4.0,
                              autoPauseSpeedMS: 0.5, autoPauseSecs: 4.0, accelNoiseMS2: 0.3,
                              speedTrustBand: 0.62...1.15)
            default:         // run / trail run (and any other foot sport routed to a GPS capture)
                return Config(maxImpliedSpeedMS: 8.0, outlierSpeedMarginMS: 5.0,
                              autoPauseSpeedMS: 0.5, autoPauseSecs: 4.0, accelNoiseMS2: 0.6,
                              speedTrustBand: 0.90...1.15)
            }
        }
    }

    enum Result: Equatable {
        case rejected
        case accepted(distanceAddedM: Double)
    }

    let config: Config
    private(set) var anchor: Fix?
    /// Altitude of the current climb's base (the last valley, or where the last counted climb
    /// topped out). Elevation hysteresis measures every ascent from here — see Config.
    private var climbAnchorAltM: Double?
    /// EMA-smoothed altitude — the hysteresis runs on THIS, not raw altitude. Alternating GPS
    /// jitter spans up to twice its amplitude trough-to-peak, which beats any sane threshold;
    /// smoothing first collapses it to a fraction while a real climb passes through in full.
    private var smoothedAltM: Double?
    /// The most recent ACCEPTED fix, including micro-moves that never advance `anchor`. This is the
    /// accept gate's time reference: `anchor` freezes while the athlete stands still (its timestamp
    /// goes stale), and a stale reference dilutes the implied-speed test — after a 60 s traffic
    /// light an 80 m GPS spike reads as a lazy 1.3 m/s and sails through. Measured against the fix
    /// from one second ago, the same spike reads as 80 m/s and is rejected.
    private var lastAccepted: Fix?
    var distanceM: Double { distance.distanceM }
    private(set) var elevationGainM: Double = 0
    /// Smoothed pace in seconds per km (0 until first movement). Derived from `smoothedSpeedMS`.
    private(set) var smoothedPaceSPerKm: Double = 0
    /// Exponentially smoothed speed (m/s), the quantity actually averaged: averaging speeds and
    /// inverting is correct; averaging paces over-weights the slow samples.
    private var smoothedSpeedMS: Double = 0
    private var belowSpeedSince: Date?
    /// The distance rule (Doppler-first, chord fallback) shared with the finished-run replay.
    private var distance: GPSDistanceRule
    /// True when the last ingested fix was accepted AND counted as movement — not paused, not
    /// Doppler-stationary. The engine uses it to decide whether the fix may extend the live route.
    private(set) var lastFixWasMoving = false

    /// Real-time Kalman filter (§8.3): corrects each accepted fix before it feeds the route + distance.
    private var kalman: GPSKalmanFilter
    /// The latest fix's Kalman-corrected position — the point the live route polyline should draw.
    private(set) var filteredLat = 0.0
    private(set) var filteredLon = 0.0

    /// What the pre-Doppler chord sum would have read for this run — for on-device comparison only.
    var chordOnlyDistanceM: Double { distance.chordOnlyDistanceM }
    /// How much the device's speed reading was believed this run, and where it was contradicted.
    var accuracyReport: GPSDistanceRule.Report { distance.report }
    /// Whether the device's speed reading is currently believed (see `GPSDistanceRule`).
    var speedTrusted: Bool { distance.speedTrusted }

    init(config: Config) {
        self.config = config
        self.kalman = GPSKalmanFilter(config: GPSKalmanFilter.Config(accelNoiseMS2: config.accelNoiseMS2))
        self.distance = GPSDistanceRule(config: Self.distanceConfig(config))
    }

    /// The distance rule's configuration for a discipline — one place, so the replay builds the same.
    static func distanceConfig(_ config: Config) -> GPSDistanceRule.Config {
        var c = GPSDistanceRule.Config(minMovementGateM: config.minMovementGateM)
        c.trustBand = config.speedTrustBand
        return c
    }

    /// Accept iff accuracy ∈ (0, minAccuracy], strictly newer than the anchor, and the implied speed
    /// from the anchor is consistent with real movement (not a GPS jump).
    ///
    /// The speed test is **Doppler-first**. `Fix.speedMS` is carrier-phase derived and largely
    /// independent of position error, so when it's valid we trust it: a position jump consistent with
    /// how fast you're actually going is real movement *at any pace* — a fast descent, a sprint, the
    /// user's car — and must be kept so the trace follows smoothly instead of freezing then bridging the
    /// gap with a straight line. A jump that far exceeds the reported speed is a lateral spike, rejected.
    /// The discipline hard cap (`maxImpliedSpeedMS`) only applies as a backstop when there's no valid
    /// Doppler speed to check against (cold start, tunnel), where the position delta is all we have.
    static func acceptable(_ fix: Fix, previous: Fix?, config: Config) -> Bool {
        guard fix.accuracyM > 0, fix.accuracyM <= config.minAccuracyM else { return false }
        guard let prev = previous else { return true }
        guard fix.t > prev.t else { return false }
        let dt = fix.t.timeIntervalSince(prev.t)
        let d = Geo.distance(lat1: prev.lat, lon1: prev.lon, lat2: fix.lat, lon2: fix.lon)
        let implied = dt > 0 ? d / dt : .infinity
        if fix.speedMS >= 0 {
            return implied <= fix.speedMS + config.outlierSpeedMarginMS
        }
        return implied <= config.maxImpliedSpeedMS
    }

    /// Process a raw fix. Distance is measured from a stable anchor and only accrues once movement
    /// clears `minMovementGate`, so positional jitter doesn't inflate distance.
    ///
    /// `paused: true` (the athlete's manual Pause) keeps the gate and Kalman filter warm — the map
    /// dot still follows them and the first post-resume fix can't spike-reject against a stale
    /// reference — but accrues NOTHING: no distance, no elevation, no pace. The anchors rebase to
    /// the paused position so, on resume, movement measures only itself (the coffee-run detour
    /// contributes zero, exactly like Strava's pause).
    mutating func ingest(_ fix: Fix, paused: Bool = false) -> Result {
        guard Self.acceptable(fix, previous: lastAccepted ?? anchor, config: config) else { return .rejected }
        // How long since the device last spoke to us — the pace smoother's clock. Measured against
        // the last ACCEPTED fix (paused or stationary ones included), not the distance anchor: while
        // a slow walker's anchor holds for several fixes, each 1 s speed reading is still one second
        // of evidence, not three.
        let sinceLastFixS = lastAccepted.map { fix.t.timeIntervalSince($0.t) } ?? 0
        lastAccepted = fix

        // Kalman-correct the accepted position. Distance and the route polyline are measured off this
        // filtered track, not the raw fix — the accept gate above still runs against the raw anchor so
        // its tested outlier behaviour is unchanged.
        let f = kalman.process(t: fix.t, lat: fix.lat, lon: fix.lon, accuracyM: fix.accuracyM)
        filteredLat = f.lat
        filteredLon = f.lon

        if paused {
            lastFixWasMoving = false
            anchor = fix
            distance.rebase(lat: f.lat, lon: f.lon, t: fix.t, speedMS: fix.speedMS)
            // manual pause: the detour's altitude is not ours
            climbAnchorAltM = nil
            smoothedAltM = nil
            return .accepted(distanceAddedM: 0)
        }

        // Distance: the shared position-first rule (see `GPSDistanceRule` for why). It also owns
        // the stationary judgement: standing at a light (caught on-device 2026-07-23) position
        // wander routinely clears the 2 m gate, and a TRUSTED below-auto-pause reading is what
        // says "not covering ground". A reading the positions have been contradicting cannot
        // discard the span (the 2026-09-12 hole: a phone reading half the true speed).
        let outcome = distance.advance(lat: f.lat, lon: f.lon, t: fix.t, speedMS: fix.speedMS,
                                       accuracyM: fix.accuracyM, stationaryBelowMS: config.autoPauseSpeedMS)
        switch outcome {
        case .seeded:
            lastFixWasMoving = true
            anchor = fix
            accrueClimb(fix.altitudeM)   // seeds the smoother + climb anchor, accrues nothing
            return .accepted(distanceAddedM: 0)
        case .stationaryHold:
            lastFixWasMoving = false
            anchor = fix
            return .accepted(distanceAddedM: 0)
        case .heldUnderGate:
            lastFixWasMoving = true
        case .moved:
            lastFixWasMoving = true
        }

        // Current pace follows the device's speed reading once the rule has EARNED trust in it
        // (provisional trust is enough to integrate under the cap, not enough to put a number on
        // the screen), smoothed over `paceTimeConstantS`; otherwise it follows the positional
        // speed over the trailing pace window. Updated on every moving fix (not only when the
        // anchor advances), so the number keeps breathing at 1 Hz while a slow walker's anchor holds.
        // Until three seconds of positions exist there is nothing positional to show, and a
        // provisional reading for three seconds is harmless where a blank cell is not.
        let positional = distance.positionalSpeedMS
        let believeReading = fix.speedMS >= config.autoPauseSpeedMS
            && distance.speedTrusted && (distance.speedEstablished || positional == nil)
        let sample: Double? = believeReading ? fix.speedMS : positional
        if let sample, sample > 0, sinceLastFixS > 0 {
            let alpha = 1 - exp(-sinceLastFixS / config.paceTimeConstantS)
            smoothedSpeedMS = smoothedSpeedMS == 0 ? sample : smoothedSpeedMS + alpha * (sample - smoothedSpeedMS)
            smoothedPaceSPerKm = smoothedSpeedMS > 0 ? 1000 / smoothedSpeedMS : 0
        }

        guard case let .moved(added) = outcome, added > 0 else { return .accepted(distanceAddedM: 0) }
        accrueClimb(fix.altitudeM)
        anchor = fix
        return .accepted(distanceAddedM: added)
    }

    /// Smoothed hysteresis elevation gain: altitude is EMA-smoothed, then ascents count once the
    /// smoothed track clears the threshold from the valley anchor; descents pull the anchor down
    /// so the NEXT climb measures from its true base. Flat-run jitter accrues zero (the fix for
    /// phantom climb); real climbs pass through the EMA at full magnitude, just a few fixes late.
    private mutating func accrueClimb(_ altitudeM: Double) {
        let alpha = 0.3
        let smoothed = smoothedAltM.map { $0 + alpha * (altitudeM - $0) } ?? altitudeM
        smoothedAltM = smoothed
        guard let base = climbAnchorAltM else {
            climbAnchorAltM = smoothed
            return
        }
        if smoothed >= base + config.elevationGainThresholdM {
            elevationGainM += smoothed - base
            climbAnchorAltM = smoothed
        } else if smoothed < base {
            climbAnchorAltM = smoothed
        }
    }

    /// Returns true once speed has stayed below the threshold for `autoPauseSecs`. Resume is
    /// hysteresis-gated: while already auto-paused (`currentlyPaused`), clearing requires 1.5× the
    /// pause threshold — a walker hovering right at the boundary would otherwise flap the
    /// "Auto-paused" banner (and its voice cue) on and off every few seconds.
    mutating func shouldAutoPause(speedMS: Double, now: Date, currentlyPaused: Bool = false) -> Bool {
        if currentlyPaused {
            if speedMS >= config.autoPauseSpeedMS * 1.5 {
                belowSpeedSince = nil
                return false
            }
            return true
        }
        if speedMS < config.autoPauseSpeedMS {
            if let since = belowSpeedSince {
                return now.timeIntervalSince(since) >= config.autoPauseSecs
            }
            belowSpeedSince = now
            return false
        } else {
            belowSpeedSince = nil
            return false
        }
    }
}
