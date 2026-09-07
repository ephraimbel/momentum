import Foundation

/// **The** rule that turns accepted, Kalman-filtered fixes into distance — shared by the live
/// `GPSProcessor` and the finished-run replay (`GPSDetail.routePoints`), so the two can never
/// disagree by construction rather than by discipline.
///
/// Why it is Doppler-first. Summing the chords between 1 Hz positions inflates: perpendicular jitter
/// adds path length that never cancels, and the Kalman filter removes only part of it. Measured on
/// this engine with time-correlated GPS error (the realistic kind), the chord sum read +2% long at a
/// reported accuracy of 3 m, +5% at 5 m and +10% at 8 m on a dead-straight run, worse on a city
/// grid, and +27% for a walker — miles long and pace flatteringly fast, every run. Tuning cannot fix
/// it (`GPSTuningSweepTests`): a longer chord or a stiffer filter buys straight-line accuracy by
/// cutting corners. The device's own speed reading is a *scalar* — there is no path to rectify and
/// no corner to cut — so integrating it over time measures −0.3%…+0.9% on the same fixtures at every
/// noise level, and follows a bend exactly. This is what a running watch does with its speed and
/// stride sensors; the phone has the speed.
///
/// The guards, each one a failure that would otherwise be silent:
/// - **Corroboration.** Speed is integrated only once the filtered position has moved at least
///   `minMovementGateM` from the anchor. Positional jitter under the gate holds the anchor (as it
///   always did), and a speed reading with a frozen position accrues nothing.
/// - **The chord cap.** Integrated distance never exceeds `chordCapFactor × chord + chordCapSlackM`.
///   A stuck or bogus speed with a barely-moving position is bounded by what the position can
///   corroborate; at running speeds the cap is far above a real step and never binds.
/// - **Gaps.** Past `dopplerMaxGapS` between counted fixes (a tunnel, a suspended app) the two
///   endpoint speeds say nothing about the span, so the chord is used — the honest floor.
/// - **No speed.** A negative `speedMS` is CoreLocation's "unknown" (canopy, cold re-acquire). The
///   chord behind the movement gate takes over, exactly the pre-Doppler behaviour.
///
/// Stationary and paused fixes rebase the anchor and accrue nothing; that judgement (the Doppler
/// stationary guard, the pause) belongs to the caller, which knows the discipline's thresholds.
struct GPSDistanceRule: Equatable, Sendable {
    struct Config: Equatable, Sendable {
        /// Positional movement required before anything accrues (chord or integrated speed).
        var minMovementGateM: Double
        /// Longest span the endpoint speeds are trusted to describe.
        var dopplerMaxGapS: Double = 30
        /// Integrated speed is capped at `factor × chord + slack`.
        var chordCapFactor: Double = 2
        var chordCapSlackM: Double = 2
    }

    /// The last counted position, with the time and speed the next span is measured against.
    struct Anchor: Equatable, Sendable {
        var lat: Double, lon: Double
        var t: Date
        /// Device-reported speed at the anchor; negative = unknown.
        var speedMS: Double
    }

    let config: Config
    private(set) var anchor: Anchor?
    private(set) var distanceM: Double = 0
    /// What the chord-only method would have measured — kept for on-device comparison against the
    /// integrated headline, never shown to the athlete.
    private(set) var chordOnlyDistanceM: Double = 0

    init(config: Config) { self.config = config }

    /// Rebase without accruing: a paused span, or a fix the device reports as not covering ground.
    mutating func rebase(lat: Double, lon: Double, t: Date, speedMS: Double) {
        anchor = Anchor(lat: lat, lon: lon, t: t, speedMS: speedMS)
    }

    /// A moving, accepted, filtered fix. Returns the metres added (0 while the anchor holds).
    /// `chordM` is the great-circle distance from the anchor, computed by the caller so both the
    /// rule and the caller share one geodesic.
    mutating func step(lat: Double, lon: Double, t: Date, speedMS: Double) -> Double {
        guard let a = anchor else {
            anchor = Anchor(lat: lat, lon: lon, t: t, speedMS: speedMS)
            return 0
        }
        let chord = Geo.distance(lat1: a.lat, lon1: a.lon, lat2: lat, lon2: lon)
        // The anchor holds until the position corroborates movement — jitter never accrues, by
        // either method, and a frozen position can't be talked into distance by a speed figure.
        guard chord >= config.minMovementGateM else { return 0 }
        var added = chord
        let dt = t.timeIntervalSince(a.t)
        if speedMS >= 0, a.speedMS >= 0, dt > 0, dt <= config.dopplerMaxGapS {
            let integrated = 0.5 * (a.speedMS + speedMS) * dt   // trapezoid over the span
            added = min(integrated, config.chordCapFactor * chord + config.chordCapSlackM)
        }
        distanceM += added
        chordOnlyDistanceM += chord
        anchor = Anchor(lat: lat, lon: lon, t: t, speedMS: speedMS)
        return added
    }
}
