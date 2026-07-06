import Foundation

/// Real-time GPS Kalman filter (PRD §8.3 — Stage 2 of the tracing pipeline, ahead of the display
/// smoothing in `RouteSmoothing`).
///
/// The accept gate in `GPSProcessor` *rejects* gross outliers; this *corrects* the fixes that pass.
/// A constant-velocity Kalman filter estimates position **and** velocity, then fuses each incoming
/// fix weighted by its reported accuracy: a loose ±20m fix nudges the estimate a little, a tight ±4m
/// fix a lot. Two wins over raw fixes:
///  - **Smoother, more accurate line + distance.** The estimate rides the true path instead of the
///    stair-stepping of raw points, so accumulated distance is measured off a cleaner track.
///  - **Keeps moving through weak signal.** Between fixes the model coasts along the last estimated
///    velocity (the predict step), so a momentary GPS gap doesn't freeze the trace — the next fix
///    simply snaps the estimate back, because a long gap inflates the covariance until the filter
///    trusts the fresh measurement almost fully.
///
/// The model has no cross-axis coupling — a diagonal process noise means the x and y axes are
/// **independent and identical**, so the 4-state (x, y, vx, vy) constant-velocity filter decouples
/// exactly into two 2-state (position, velocity) filters. That is what `Axis` below is: the same math
/// as a full matrix Kalman, but without a matrix library.
///
/// Pure and Core-Location-free so it can be unit-tested against recorded traces and reused off the
/// main actor. Causal (forward-only), so replaying the same accepted samples offline yields the exact
/// same track as the live run — the finished route matches what the athlete watched being drawn.
struct GPSKalmanFilter {

    struct Config: Sendable {
        /// Assumed acceleration noise σ_a (m/s²) — the one tuning knob. Larger = the filter trusts
        /// measurements more and reacts faster (less lag on turns); smaller = smoother but laggier.
        /// Scaled by discipline: cyclists change speed and corner faster than walkers.
        var accelNoiseMS2: Double
        /// Accuracy is clamped into this band before use as measurement noise, so a spuriously tiny
        /// `horizontalAccuracy` can't make the filter overtrust one fix, nor a huge one ignore it.
        var minAccuracyM = 3.0
        var maxAccuracyM = 50.0

        static func forType(_ type: WorkoutType) -> Config {
            switch type.discipline {
            case .cycling: return Config(accelNoiseMS2: 1.2)
            case .walking: return Config(accelNoiseMS2: 0.3)
            default:       return Config(accelNoiseMS2: 0.6)   // run / trail run
            }
        }
    }

    /// One decoupled position/velocity axis. State `[p, v]`; covariance `P` is the symmetric 2×2
    /// `[[p00, p01], [p10, p11]]`. `p10 == p01` throughout, so we carry it once as `p01`.
    private struct Axis {
        var p: Double        // position estimate (metres, local frame)
        var v: Double = 0    // velocity estimate (m/s)
        var p00: Double      // Var(position)
        var p01: Double = 0  // Cov(position, velocity)
        var p11: Double      // Var(velocity)

        /// Constant-velocity prediction over `dt` seconds with white-noise-acceleration process
        /// noise: `p += v·dt`, then `P = F P Fᵀ + Q`.
        mutating func predict(dt: Double, accelVar: Double) {
            p += v * dt
            // F = [[1, dt], [0, 1]] ⇒ symmetric F P Fᵀ:
            let np00 = p00 + 2 * dt * p01 + dt * dt * p11
            let np01 = p01 + dt * p11
            let np11 = p11
            // Q = σ_a² · [[dt⁴/4, dt³/2], [dt³/2, dt²]]
            let dt2 = dt * dt, dt3 = dt2 * dt, dt4 = dt3 * dt
            p00 = np00 + accelVar * dt4 / 4
            p01 = np01 + accelVar * dt3 / 2
            p11 = np11 + accelVar * dt2
        }

        /// Fuse a position measurement `z` with variance `r` (H = [1, 0]).
        mutating func update(z: Double, r: Double) {
            let s = p00 + r                 // innovation variance
            let k0 = p00 / s, k1 = p01 / s  // Kalman gain
            let y = z - p                   // innovation
            p += k0 * y
            v += k1 * y
            // P = (I − K H) P, evaluated with the pre-update covariance.
            let op00 = p00, op01 = p01
            p00 = (1 - k0) * op00
            p01 = (1 - k0) * op01
            p11 = p11 - k1 * op01
        }
    }

    let config: Config

    // Local planar frame anchored at the first fix, so estimates stay in small metre-scale numbers.
    private static let mPerDegLat = 111_320.0
    private var mPerDegLon = 111_320.0
    private var refLat = 0.0, refLon = 0.0
    private var x: Axis?
    private var y: Axis?
    private var lastT: Date?

    /// Numeric-safety ceiling on the inter-fix interval (guards `dt⁴` in the process noise). It must
    /// stay large: a real gap *should* inflate the covariance so the filter trusts the fresh fix and
    /// snaps to it — clamping `dt` low instead makes the estimate lag after a gap. The output is always
    /// post-update, so a large `dt` never leaves the extrapolated position on screen.
    private static let maxPredictDt = 60.0

    init(config: Config) { self.config = config }

    /// Ingest one accepted fix; returns the filtered (lat, lon). The first fix seeds the filter at the
    /// measurement with zero velocity.
    mutating func process(t: Date, lat: Double, lon: Double, accuracyM: Double) -> (lat: Double, lon: Double) {
        let r = pow(min(config.maxAccuracyM, max(config.minAccuracyM, accuracyM)), 2)

        guard var ax = x, var ay = y else {
            refLat = lat
            refLon = lon
            mPerDegLon = Self.mPerDegLat * cos(lat * .pi / 180)
            // Seed: position = measurement (variance r); velocity unknown (broad prior).
            let seedVelVar = 100.0   // σ_v ≈ 10 m/s prior
            x = Axis(p: 0, p00: r, p11: seedVelVar)
            y = Axis(p: 0, p00: r, p11: seedVelVar)
            lastT = t
            return (lat, lon)
        }

        let dt = min(Self.maxPredictDt, max(0, t.timeIntervalSince(lastT ?? t)))
        let accelVar = config.accelNoiseMS2 * config.accelNoiseMS2
        if dt > 0 {
            ax.predict(dt: dt, accelVar: accelVar)
            ay.predict(dt: dt, accelVar: accelVar)
        }
        // Project the measurement into the local metre frame, fuse, unproject.
        ax.update(z: (lon - refLon) * mPerDegLon, r: r)
        ay.update(z: (lat - refLat) * Self.mPerDegLat, r: r)
        x = ax
        y = ay
        lastT = t
        return (lat: refLat + ay.p / Self.mPerDegLat,
                lon: refLon + ax.p / mPerDegLon)
    }

    /// Batch-filter an ordered set of accepted samples — used at replay time to rebuild a finished
    /// route's geometry identically to how it was captured live.
    static func smooth(_ samples: [(t: Date, lat: Double, lon: Double, accuracyM: Double)],
                       config: Config) -> [(lat: Double, lon: Double)] {
        var filter = GPSKalmanFilter(config: config)
        return samples.map { filter.process(t: $0.t, lat: $0.lat, lon: $0.lon, accuracyM: $0.accuracyM) }
    }
}
