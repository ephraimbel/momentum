import Foundation

/// **The** rule that turns accepted, Kalman-filtered fixes into distance — shared by the live
/// `GPSProcessor` and the finished-run replay (`RouteReplay.routePoints`), so the two can never
/// disagree by construction rather than by discipline.
///
/// Position is the ground truth; the device's speed reading is a corroborated helper.
///
/// Why the speed reading is used at all: summing the chords between 1 Hz positions inflates.
/// Perpendicular jitter adds path length that never cancels and the Kalman filter removes only part
/// of it — measured on this engine, +2% at a reported accuracy of 3 m, +5% at 5 m, +10% at 8 m on a
/// dead-straight run, and +27% for a walker. The device's speed is a scalar with no path to rectify,
/// so integrating it over time measures the same fixtures within 1%.
///
/// Why it is never trusted on its own (2026-09-12): a real run put the phone's speed reading at
/// about HALF the athlete's true speed for the whole session. With speed as the primary signal every
/// number the athlete saw read 2× slow at once — current pace, average pace, miles, the coach's
/// nudges, and the long-term record — while Strava, which measures from positions, was right. So:
/// - **The trust window.** Speed is integrated only while its integral over the last
///   `trustWindowS` agrees with the filtered chord sum within `trustBand` (Σintegrated / Σchord). A
///   device that reads low or high by more than the chord inflation it is meant to remove is simply
///   not believed, and every span falls back to the chord — right within a few percent, never off by
///   half. Trust is re-evaluated continuously, so a reading that recovers is used again.
/// - **The chord cap.** Even a trusted reading never adds more than `chordCapFactor × chord +
///   chordCapSlackM` on one span, so a single wild sample cannot double a stride. There is no
///   per-span floor on purpose: per-second chords are noisy (2.5 m one second, 5 m the next), and a
///   floor pulled up on every jittery span, quietly re-inflating an accurate device by the very
///   amount the reading exists to remove. A systematically low reading is the window's job.
/// - **Stationary needs both witnesses.** A speed reading under the stationary threshold rebases the
///   anchor (standing at a light, position wander must accrue nothing) only while the reading is
///   trusted AND the position's NET displacement over the trailing window says the athlete has
///   stopped (standing-still jitter nets a metre or two in ten seconds; a walker nets twelve).
///   Otherwise "stopped" from a device whose position is still covering ground is a contradiction,
///   and the chord is counted — the hole that used to discard every span a zero-speed fix landed
///   on. A stationary reading at the anchor also voids the next trapezoid (its half-zero average is
///   not a measurement of that span), so one bad sample cannot poison the window either.
/// - **Corroboration, gap and no-speed guards** as before: nothing accrues until the filtered
///   position moves `minMovementGateM`; past `dopplerMaxGapS` the endpoint speeds say nothing and
///   the chord is used; a negative speed is CoreLocation's "unknown" and the chord carries the span.
///
/// The rule also reports a positional speed over the trailing `paceWindowS`, which is what current
/// pace follows whenever the device's reading is not trusted.
struct GPSDistanceRule: Equatable, Sendable {
    struct Config: Equatable, Sendable {
        /// Positional movement required before anything accrues (chord or integrated speed).
        var minMovementGateM: Double
        /// Longest span the endpoint speeds are trusted to describe.
        var dopplerMaxGapS: Double = 30
        /// Integrated speed is capped at `factor × chord + slack`.
        var chordCapFactor: Double = 2
        var chordCapSlackM: Double = 2
        /// Σintegrated / Σchord over the trust window inside which the reading is believed. The true
        /// ratio for an accurate device is the inverse of the chord inflation at this discipline's
        /// speed (~0.94–0.99 running, ~0.85 walking), so the band is discipline-tuned by the caller.
        /// The upper edge is deliberately looser than the lower: Kalman-lagged chords under-read a
        /// tight bend by up to ~10% (a 400 m track's turns), and there the speed integral is the
        /// one that is right; a fused speed reading high by that much is not a fault seen in the field.
        var trustBand: ClosedRange<Double> = 0.90...1.15
        /// The lower edge relaxes with the reported accuracy: the chord inflation the reading is
        /// meant to remove grows with position noise (+1% at 3 m, +5% at 5 m, +10% at 8 m on a
        /// straight), so an accurate reading sits further under 1.0 the worse the fix. Per metre of
        /// mean reported accuracy above `trustAccuracyBaseM`, floored at `trustLowerFloor`.
        var trustAccuracyBaseM: Double = 3
        var trustLowerSlopePerM: Double = 0.03
        var trustLowerFloor: Double = 0.6
        /// Long enough that a 30 s excursion of correlated position noise (which swings a window's
        /// chord sum by ±15% at a reported 5 m) cannot flip an accurate reading in and out of
        /// trust; short enough that a reading which goes bad is disbelieved within about a minute.
        var trustWindowS: Double = 90
        /// Hysteresis: an established reading is dropped only once the ratio leaves the band by
        /// this margin, and re-admitted only once it is back inside the band proper — so a good
        /// device sitting near an edge does not flicker between the reading and positional pace.
        var trustExitMargin: Double = 0.08
        /// Seconds of speed-bearing spans required before the window may veto the reading; below
        /// it the reading is provisional (believed, but still held inside the chord band).
        var trustMinEvidenceS: Double = 8
        /// Trailing span the positional speed is measured over.
        var paceWindowS: Double = 10
        /// A stationary reading is honoured only while the net displacement speed over the trailing
        /// `paceWindowS` is under this multiple of the stationary threshold: the position has to
        /// agree the athlete stopped. Net displacement, not path length, because standing-still
        /// jitter has path length but no direction.
        var stationaryPositionalFactor: Double = 2
    }

    /// The last counted position, with the time and speed the next span is measured against.
    struct Anchor: Equatable, Sendable {
        var lat: Double, lon: Double
        var t: Date
        /// Device-reported speed at the anchor; negative = unknown.
        var speedMS: Double
    }

    /// What one fix did to the running total.
    enum Outcome: Equatable, Sendable {
        /// The first counted fix: the anchor is set, nothing accrues.
        case seeded
        /// The position has not cleared the movement gate; the anchor holds (or, on a stationary
        /// reading, re-seats on the standing position). Nothing accrues.
        case heldUnderGate
        /// A trusted stationary reading with the position past the gate: standing-still wander,
        /// re-anchored and not counted.
        case stationaryHold
        /// Ground covered: `addedM` joined the total.
        case moved(addedM: Double)
    }

    /// One counted span, kept for the trust and pace windows.
    private struct Span: Equatable, Sendable {
        let t: Date
        let dt: Double
        let chordM: Double
        /// The trapezoid of the endpoint speeds, nil when either endpoint had no valid reading.
        let integratedM: Double?
        /// The fix's reported horizontal accuracy, for the adaptive lower edge.
        let accuracyM: Double
    }

    /// Per-run diagnostics: how much the speed reading was believed and where it disagreed.
    struct Report: Equatable, Sendable {
        var spans = 0
        var spansWithSpeed = 0
        var spansSpeedUsed = 0
        /// Stationary readings the position contradicted while the reading was untrusted.
        var stationaryContradictions = 0
        var stationaryHolds = 0
        var distanceM = 0.0
        var chordOnlyDistanceM = 0.0
        var dopplerOnlyDistanceM = 0.0
        /// Σintegrated / Σchord over every speed-bearing span of the run (1.0 = perfect agreement,
        /// below the chord inflation = the device read low).
        var dopplerToChordRatio: Double { dopplerChordBaseM > 0 ? dopplerSumM / dopplerChordBaseM : 0 }
        fileprivate var dopplerSumM = 0.0
        fileprivate var dopplerChordBaseM = 0.0
    }

    let config: Config
    private(set) var anchor: Anchor?
    private(set) var distanceM: Double = 0
    /// What the chord-only method would have measured — kept for on-device comparison against the
    /// headline, never shown to the athlete.
    private(set) var chordOnlyDistanceM: Double = 0
    /// What speed integration alone would have measured (chord where no reading existed).
    private(set) var dopplerOnlyDistanceM: Double = 0
    /// Whether the device's speed reading is currently believed. Provisional (true) until the
    /// window holds `trustMinEvidenceS` of evidence, then the band decides.
    private(set) var speedTrusted = true
    /// Trust the window has actually EARNED: enough evidence, and inside the band. Integration may
    /// run on provisional trust (the cap bounds it), but discarding ground on a "stopped" reading
    /// may not — a sensor that has not yet proven itself does not get to erase a stride.
    private(set) var speedEstablished = false
    private(set) var report = Report()
    private var window: [Span] = []
    /// Every filtered position seen past the seed, counted or not, over the trailing pace window —
    /// the witness for net displacement, deliberately independent of what was counted so a hold
    /// can never talk itself into the next one.
    private var trail: [TrailPoint] = []
    private struct TrailPoint: Equatable, Sendable { let t: Date; let lat: Double; let lon: Double }

    init(config: Config) { self.config = config }

    /// Rebase without accruing: a paused span. The trust window is kept — a pause is not evidence
    /// about the sensor either way.
    mutating func rebase(lat: Double, lon: Double, t: Date, speedMS: Double) {
        anchor = Anchor(lat: lat, lon: lon, t: t, speedMS: speedMS)
        trail.removeAll()
    }

    /// Ground speed from positions alone over the trailing `paceWindowS`, nil until three seconds of
    /// counted spans exist. This is the pace signal whenever the device's reading is not trusted.
    var positionalSpeedMS: Double? {
        guard let last = window.last else { return nil }
        var meters = 0.0, seconds = 0.0
        for span in window.reversed() where last.t.timeIntervalSince(span.t) <= config.paceWindowS {
            meters += span.chordM
            seconds += span.dt
        }
        guard seconds >= 3, meters > 0 else { return nil }
        return meters / seconds
    }

    /// How fast the position has moved AS THE CROW FLIES over the trailing pace window, nil until
    /// the window holds three seconds. Standing still reads near zero however much the fixes jitter.
    var netDisplacementSpeedMS: Double? {
        guard let first = trail.first, let last = trail.last else { return nil }
        let seconds = last.t.timeIntervalSince(first.t)
        guard seconds >= 3 else { return nil }
        return Geo.distance(lat1: first.lat, lon1: first.lon, lat2: last.lat, lon2: last.lon) / seconds
    }

    /// An accepted, filtered fix that is not paused. `stationaryBelowMS` is the discipline's
    /// "not covering ground" threshold for the device's reading.
    mutating func advance(lat: Double, lon: Double, t: Date, speedMS: Double, accuracyM: Double = 5,
                          stationaryBelowMS: Double) -> Outcome {
        let stationaryReading = speedMS >= 0 && speedMS < stationaryBelowMS
        trail.append(TrailPoint(t: t, lat: lat, lon: lon))
        let horizon = config.paceWindowS
        if let first = trail.first, t.timeIntervalSince(first.t) > horizon {
            trail.removeAll { t.timeIntervalSince($0.t) > horizon }
        }
        guard let a = anchor else {
            anchor = Anchor(lat: lat, lon: lon, t: t, speedMS: speedMS)
            return .seeded
        }
        let chord = Geo.distance(lat1: a.lat, lon1: a.lon, lat2: lat, lon2: lon)
        let dt = t.timeIntervalSince(a.t)
        // The anchor holds until the position corroborates movement — jitter never accrues, by
        // either method, and a frozen position can't be talked into distance by a speed figure.
        // A stationary reading re-seats the anchor on the standing position, so a slow drift while
        // stopped can't creep past the gate one wobble at a time — and records the standing
        // second as zero ground, so the positional speed decays honestly toward a stop.
        guard chord >= config.minMovementGateM else {
            // Only a reading that has earned trust may re-seat the anchor: a slow walker's partial
            // stride under the gate is real ground waiting to clear it, and an unproven "stopped"
            // must not erase it (a device reading half a walker's speed sat under the threshold a
            // third of the time, and lost a third of the walk this way).
            if stationaryReading, speedEstablished {
                anchor = Anchor(lat: lat, lon: lon, t: t, speedMS: speedMS)
                window.append(Span(t: t, dt: dt, chordM: 0, integratedM: nil, accuracyM: accuracyM))
                refreshTrust(at: t)
            }
            return .heldUnderGate
        }
        refreshTrust(at: t)
        if stationaryReading {
            let net = netDisplacementSpeedMS ?? 0
            if speedTrusted, net < config.stationaryPositionalFactor * stationaryBelowMS {
                // Every witness agrees the athlete is standing: the reading says so, it has been
                // right about speed, and the position is going nowhere. The wander past the gate
                // is jitter, not distance.
                report.stationaryHolds += 1
                anchor = Anchor(lat: lat, lon: lon, t: t, speedMS: speedMS)
                window.append(Span(t: t, dt: dt, chordM: 0, integratedM: nil, accuracyM: accuracyM))
                return .stationaryHold
            }
            // The device says stopped while the position is still covering ground (or the device
            // has been wrong lately): the position wins, and this reading is not used for the span.
            report.stationaryContradictions += 1
        }

        var integrated: Double?
        // A stationary reading at either end is not a measurement of the span (half of zero and
        // the true speed is nobody's speed), so such a span carries no speed evidence at all.
        let anchorStationary = a.speedMS >= 0 && a.speedMS < stationaryBelowMS
        if !stationaryReading, !anchorStationary, speedMS >= 0, a.speedMS >= 0, dt > 0, dt <= config.dopplerMaxGapS {
            integrated = 0.5 * (a.speedMS + speedMS) * dt   // trapezoid over the span
        }
        window.append(Span(t: t, dt: dt, chordM: chord, integratedM: integrated, accuracyM: accuracyM))
        refreshTrust(at: t, aging: true)

        var added = chord
        if let integrated, speedTrusted {
            added = min(integrated, config.chordCapFactor * chord + config.chordCapSlackM)
            report.spansSpeedUsed += 1
        }
        distanceM += added
        chordOnlyDistanceM += chord
        dopplerOnlyDistanceM += integrated ?? chord
        report.spans += 1
        if let integrated {
            report.spansWithSpeed += 1
            report.dopplerSumM += integrated
            report.dopplerChordBaseM += chord
        }
        report.distanceM = distanceM
        report.chordOnlyDistanceM = chordOnlyDistanceM
        report.dopplerOnlyDistanceM = dopplerOnlyDistanceM
        anchor = Anchor(lat: lat, lon: lon, t: t, speedMS: speedMS)
        return .moved(addedM: added)
    }

    /// Σintegrated / Σchord over the current trust window, nil while there is no speed-bearing
    /// evidence in it. Diagnostics: the number the trust band is judging.
    var trustRatio: Double? {
        var integratedM = 0.0, chordM = 0.0
        for span in window { if let i = span.integratedM { integratedM += i; chordM += span.chordM } }
        return chordM > 0 ? integratedM / chordM : nil
    }

    /// Re-decide whether the reading is believed. `aging` ages the window to `trustWindowS` — done
    /// only when ground was covered, so trust earned on the move is KEPT through a stop: a red
    /// light longer than the window must not lapse the sensor back to "unproven" and let jitter
    /// past the gate be counted. Evidence ages by movement, not by the clock.
    private mutating func refreshTrust(at t: Date, aging: Bool = false) {
        if aging {
            let horizon = config.trustWindowS
            let stale = window.first.map { t.timeIntervalSince($0.t) > horizon } ?? false
            if stale { window.removeAll { t.timeIntervalSince($0.t) > horizon } }
        }
        var evidenceS = 0.0, integratedM = 0.0, chordM = 0.0, accuracySumM = 0.0
        for span in window {
            guard let i = span.integratedM else { continue }
            evidenceS += span.dt
            integratedM += i
            chordM += span.chordM
            accuracySumM += span.accuracyM * span.dt
        }
        guard evidenceS >= config.trustMinEvidenceS, chordM > 0 else {
            speedTrusted = true   // provisional: nothing yet says the reading is wrong
            speedEstablished = false
            return
        }
        let meanAccuracyM = accuracySumM / evidenceS
        let lower = max(config.trustLowerFloor,
                        config.trustBand.lowerBound
                            - config.trustLowerSlopePerM * max(0, meanAccuracyM - config.trustAccuracyBaseM))
        let ratio = integratedM / chordM
        let upper = config.trustBand.upperBound
        if speedEstablished {
            speedTrusted = ratio >= lower - config.trustExitMargin && ratio <= upper + config.trustExitMargin
        } else {
            speedTrusted = ratio >= lower && ratio <= upper
        }
        speedEstablished = speedTrusted
    }
}
