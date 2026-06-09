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
        var minAccuracyM = 25.0
        var maxImpliedSpeedMS = 12.0
        var minMovementGateM = 2.0
        var paceEmaAlpha = 0.2
        var autoPauseSpeedMS: Double
        var autoPauseSecs: Double

        /// Discipline-specific auto-pause thresholds (§8.3).
        static func forType(_ type: WorkoutType) -> Config {
            switch type {
            case .ride:
                return Config(autoPauseSpeedMS: 1.0, autoPauseSecs: 5.0)
            default: // run/walk/hike
                return Config(autoPauseSpeedMS: 0.5, autoPauseSecs: 4.0)
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

    init(config: Config) { self.config = config }

    /// Accept iff accuracy ∈ (0, minAccuracy], strictly newer than the anchor, and implied speed
    /// from the anchor ≤ maxImpliedSpeed (rejects GPS jumps).
    static func acceptable(_ fix: Fix, previous: Fix?, config: Config) -> Bool {
        guard fix.accuracyM > 0, fix.accuracyM <= config.minAccuracyM else { return false }
        guard let prev = previous else { return true }
        guard fix.t > prev.t else { return false }
        let dt = fix.t.timeIntervalSince(prev.t)
        let d = Geo.distance(lat1: prev.lat, lon1: prev.lon, lat2: fix.lat, lon2: fix.lon)
        let implied = dt > 0 ? d / dt : .infinity
        return implied <= config.maxImpliedSpeedMS
    }

    /// Process a raw fix. Distance is measured from a stable anchor and only accrues once movement
    /// clears `minMovementGate`, so positional jitter doesn't inflate distance.
    mutating func ingest(_ fix: Fix) -> Result {
        guard Self.acceptable(fix, previous: anchor, config: config) else { return .rejected }

        guard let prev = anchor else {
            anchor = fix
            return .accepted(distanceAddedM: 0)
        }

        let d = Geo.distance(lat1: prev.lat, lon1: prev.lon, lat2: fix.lat, lon2: fix.lon)
        guard d >= config.minMovementGateM else {
            return .accepted(distanceAddedM: 0) // micro-move: keep anchor stable
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
