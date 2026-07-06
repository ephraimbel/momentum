import Foundation

/// Pure GPS sample processing (PRD §8.3) — accept gate, distance accumulation against a stable
/// anchor, pace EMA, and auto-pause detection. Extracted from the actor so it can be unit-tested
/// against recorded traces with no CoreLocation dependency. **Constants here are authoritative.**
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
        /// Hard ceiling on the speed implied by two consecutive accepted fixes. Discipline-specific:
        /// a runner never sustains a cyclist's descent, so a foot-sport cap catches the ~8–15m
        /// lateral spikes ("trace cuts across a building") that a generic 12 m/s cap let through.
        var maxImpliedSpeedMS: Double
        /// Doppler cross-check margin. A positional jump implying more than the device-reported speed
        /// (`Fix.speedMS`, carrier-phase derived and largely independent of position error) plus this
        /// margin is treated as a GPS spike — the guard that catches jumps slipping under the hard cap
        /// because fixes arrived seconds apart.
        var outlierSpeedMarginMS: Double
        var minMovementGateM = 2.0
        var paceEmaAlpha = 0.2
        var autoPauseSpeedMS: Double
        var autoPauseSecs: Double
        /// Kalman process-noise (σ_a) for the real-time position filter (see `GPSKalmanFilter`).
        var accelNoiseMS2 = 0.6

        /// Discipline-specific accept-gate + auto-pause thresholds (§8.3).
        static func forType(_ type: WorkoutType) -> Config {
            switch type.discipline {
            case .cycling:   // all bike variants — allow fast descents (~80 km/h) but reject teleports
                return Config(maxImpliedSpeedMS: 22.0, outlierSpeedMarginMS: 8.0,
                              autoPauseSpeedMS: 1.0, autoPauseSecs: 5.0, accelNoiseMS2: 1.2)
            case .walking:   // walk / hike — slow, so a tight cap sharply cleans the trace
                return Config(maxImpliedSpeedMS: 4.5, outlierSpeedMarginMS: 4.0,
                              autoPauseSpeedMS: 0.5, autoPauseSecs: 4.0, accelNoiseMS2: 0.3)
            default:         // run / trail run (and any other foot sport routed to a GPS capture)
                return Config(maxImpliedSpeedMS: 8.0, outlierSpeedMarginMS: 5.0,
                              autoPauseSpeedMS: 0.5, autoPauseSecs: 4.0, accelNoiseMS2: 0.6)
            }
        }
    }

    enum Result: Equatable {
        case rejected
        case accepted(distanceAddedM: Double)
    }

    let config: Config
    private(set) var anchor: Fix?
    private(set) var distanceM: Double = 0
    private(set) var elevationGainM: Double = 0
    /// EMA-smoothed pace in seconds per km (0 until first movement).
    private(set) var smoothedPaceSPerKm: Double = 0
    private var belowSpeedSince: Date?

    /// Real-time Kalman filter (§8.3): corrects each accepted fix before it feeds the route + distance.
    private var kalman: GPSKalmanFilter
    /// The latest fix's Kalman-corrected position — the point the live route polyline should draw.
    private(set) var filteredLat = 0.0
    private(set) var filteredLon = 0.0
    /// Filtered position of the last point distance was measured from (advances only past the move gate).
    private var distAnchorLat = 0.0
    private var distAnchorLon = 0.0

    init(config: Config) {
        self.config = config
        self.kalman = GPSKalmanFilter(config: GPSKalmanFilter.Config(accelNoiseMS2: config.accelNoiseMS2))
    }

    /// Accept iff accuracy ∈ (0, minAccuracy], strictly newer than the anchor, and the implied speed
    /// from the anchor clears **two** gates that together reject GPS jumps:
    ///   1. a hard discipline cap (`maxImpliedSpeedMS`) — nobody on foot/bike sustains beyond it; and
    ///   2. a Doppler cross-check — a jump implying far more than the device-reported speed is a spike
    ///      even when it sneaks under the hard cap because fixes arrived seconds apart.
    static func acceptable(_ fix: Fix, previous: Fix?, config: Config) -> Bool {
        guard fix.accuracyM > 0, fix.accuracyM <= config.minAccuracyM else { return false }
        guard let prev = previous else { return true }
        guard fix.t > prev.t else { return false }
        let dt = fix.t.timeIntervalSince(prev.t)
        let d = Geo.distance(lat1: prev.lat, lon1: prev.lon, lat2: fix.lat, lon2: fix.lon)
        let implied = dt > 0 ? d / dt : .infinity
        guard implied <= config.maxImpliedSpeedMS else { return false }
        // Doppler cross-check (only when the device reports a valid speed): the position moved far
        // faster than the athlete is actually going → a lateral GPS spike, not real movement.
        if fix.speedMS >= 0, implied > fix.speedMS + config.outlierSpeedMarginMS { return false }
        return true
    }

    /// Process a raw fix. Distance is measured from a stable anchor and only accrues once movement
    /// clears `minMovementGate`, so positional jitter doesn't inflate distance.
    mutating func ingest(_ fix: Fix) -> Result {
        guard Self.acceptable(fix, previous: anchor, config: config) else { return .rejected }

        // Kalman-correct the accepted position. Distance and the route polyline are measured off this
        // filtered track, not the raw fix — the accept gate above still runs against the raw anchor so
        // its tested outlier behaviour is unchanged.
        let f = kalman.process(t: fix.t, lat: fix.lat, lon: fix.lon, accuracyM: fix.accuracyM)
        filteredLat = f.lat
        filteredLon = f.lon

        guard let prev = anchor else {
            anchor = fix
            distAnchorLat = f.lat
            distAnchorLon = f.lon
            return .accepted(distanceAddedM: 0)
        }

        let d = Geo.distance(lat1: distAnchorLat, lon1: distAnchorLon, lat2: f.lat, lon2: f.lon)
        guard d >= config.minMovementGateM else {
            return .accepted(distanceAddedM: 0) // micro-move: keep the distance anchor stable
        }

        distanceM += d
        if fix.altitudeM > prev.altitudeM {
            elevationGainM += fix.altitudeM - prev.altitudeM
        }
        let dt = fix.t.timeIntervalSince(prev.t)
        if dt > 0 {
            let instPaceSPerKm = (dt / d) * 1000
            smoothedPaceSPerKm = smoothedPaceSPerKm == 0
                ? instPaceSPerKm
                : config.paceEmaAlpha * instPaceSPerKm + (1 - config.paceEmaAlpha) * smoothedPaceSPerKm
        }
        anchor = fix
        distAnchorLat = f.lat
        distAnchorLon = f.lon
        return .accepted(distanceAddedM: d)
    }

    /// Returns true once speed has stayed below the threshold for `autoPauseSecs`.
    mutating func shouldAutoPause(speedMS: Double, now: Date) -> Bool {
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
