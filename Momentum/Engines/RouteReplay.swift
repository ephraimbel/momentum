import Foundation
import CoreLocation

/// Rebuilds a finished workout's display route from its persisted samples, applying the **same**
/// real-time Kalman filter the live run used (`GPSKalmanFilter`). Because that filter is causal,
/// replaying the stored accepted samples reproduces the exact track the athlete watched being drawn —
/// so the summary, history, share card, and profile art all show one consistent, smoothed route (§8.3,
/// §8.5). Distance is untouched: it's the value the engine accumulated live and persisted on the row.
extension GPSDetail {

    /// The best available route geometry: the Mapbox map-matched track when present (§8.5), otherwise
    /// the accepted samples Kalman-corrected into route coordinates. Pass the workout's discipline so
    /// the filter tunes to it (cyclists change speed faster than walkers); defaults to running. Feed
    /// the result to `RouteSmoothing.smooth` for the final display spline.
    func routeCoordinates(type: WorkoutType = .run) -> [CLLocationCoordinate2D] {
        if let matched = matchedCoordinates, matched.count > 1 { return matched }
        let accepted = samples.filter(\.accepted).sorted { $0.t < $1.t }
        guard accepted.count > 1 else {
            return accepted.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        }
        let input = accepted.map { (t: $0.t, lat: $0.lat, lon: $0.lon, accuracyM: $0.accuracyM) }
        return GPSKalmanFilter.smooth(input, config: .forType(type))
            .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    /// The stored Mapbox map-matched route (JSON `[[lat, lon]]`), or nil if matching never ran or was
    /// discarded below the confidence gate.
    private var matchedCoordinates: [CLLocationCoordinate2D]? {
        guard let data = matchedRouteData,
              let pairs = try? JSONDecoder().decode([[Double]].self, from: data), pairs.count > 1 else { return nil }
        return pairs.compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
    }

    // MARK: - The canonical reduction (splits · charts · records)

    /// One replayed sample: moving seconds and engine-consistent cumulative distance, plus the raw
    /// per-fix readings the charts draw.
    struct RoutePoint: Sendable, Equatable {
        /// Seconds of MOVING time since the first accepted fix — pauses excluded, exactly like the
        /// clock that produced `Workout.durationS`.
        let t: TimeInterval
        /// Cumulative distance measured the way the engine measured it live.
        let cumulativeM: Double
        let altitudeM: Double
        /// Device-reported (Doppler) speed for this fix; negative when the device had none.
        let speedMS: Double
    }

    /// **The** reduction of a finished workout's samples to `(moving time, cumulative distance)`.
    ///
    /// This is a faithful replay of `GPSProcessor`: the stored fixes run back through the identical
    /// causal Kalman filter, distance accrues between *filtered* positions behind the same 2 m
    /// movement gate, Doppler-stationary fixes accrue nothing, and paused spans advance neither
    /// metres nor seconds. So the totals it produces agree with `distanceM`/`durationS` on the row.
    ///
    /// It exists because four sites — the splits list, the pace/elevation charts, the achievement
    /// badges, and the record book — each summed raw haversine hops between raw fixes instead. GPS
    /// jitter makes that sum 3–40% longer than the run actually was, so splits contradicted the
    /// headline, and `fastestWindow` reached "5 km" hundreds of metres early: on a noisy trace it
    /// recorded a 5K PR minutes faster than the athlete ran, and `RecordsBook.beats` then kept that
    /// phantom forever, locking out every genuine record behind it. One definition, one answer.
    func routePoints(type: WorkoutType = .run) -> [RoutePoint] {
        // Paused fixes stay in the Kalman input (the live filter processed them too — it keeps the
        // estimate warm so the first post-resume fix isn't a spike) but contribute nothing below.
        let usable = samples.filter { $0.accepted || $0.pausedSpan }.sorted { $0.t < $1.t }
        guard usable.count > 1 else { return [] }

        let config = GPSProcessor.Config.forType(type)
        // Apply the Doppler-stationary rule only when this trace actually carries speed. Live
        // CoreLocation fixes do (negative when unknown), but a replay reads stored rows of unknown
        // provenance — a source that never populated `speedMS` leaves it at 0, which would read as
        // "stationary for the entire run" and silently reduce the whole thing to zero distance.
        // Without speed the 2 m movement gate below stands on its own, exactly as it did before
        // Doppler was introduced.
        let hasSpeedSignal = usable.contains { $0.speedMS > 0 }
        let filtered = GPSKalmanFilter.smooth(
            usable.map { (t: $0.t, lat: $0.lat, lon: $0.lon, accuracyM: $0.accuracyM) },
            config: .forType(type))

        var points: [RoutePoint] = []
        points.reserveCapacity(usable.count)
        var cumulativeM = 0.0
        var movingS = 0.0
        var anchor: (lat: Double, lon: Double)?
        var previousT: Date?

        for (sample, position) in zip(usable, filtered) {
            // A pause rebases the distance anchor and freezes the clock — the walk to the coffee
            // shop contributes neither metres nor seconds, exactly as it did live.
            guard !sample.pausedSpan else {
                anchor = position
                previousT = sample.t
                continue
            }
            // Time accrues across every gap between two live fixes, INCLUDING a signal dropout:
            // the athlete kept running through the tunnel and the headline clock kept counting.
            if let previousT { movingS += max(0, sample.t.timeIntervalSince(previousT)) }
            previousT = sample.t

            guard let last = anchor else {
                anchor = position
                points.append(RoutePoint(t: movingS, cumulativeM: cumulativeM,
                                         altitudeM: sample.altitudeM, speedMS: sample.speedMS))
                continue
            }
            // Doppler says "not covering ground" → rebase and accrue nothing, so standing at a red
            // light can't wander its way into distance (the engine's on-device fix, 2026-07-23).
            let stationary = hasSpeedSignal && sample.speedMS >= 0 && sample.speedMS < config.autoPauseSpeedMS
            if !stationary {
                let d = Geo.distance(lat1: last.lat, lon1: last.lon, lat2: position.lat, lon2: position.lon)
                if d >= config.minMovementGateM {
                    cumulativeM += d
                    anchor = position
                }
            } else {
                anchor = position
            }
            points.append(RoutePoint(t: movingS, cumulativeM: cumulativeM,
                                     altitudeM: sample.altitudeM, speedMS: sample.speedMS))
        }
        return points
    }

    /// The replay reduced to what `CardioMetrics` consumes (splits, fastest-window records).
    func samplePoints(type: WorkoutType = .run) -> [CardioMetrics.SamplePoint] {
        routePoints(type: type).map { .init(t: $0.t, cumulativeM: $0.cumulativeM) }
    }

    /// Whole-kilometre splits — the canonical SI form persisted on the row at finish. Display
    /// surfaces re-split per the athlete's unit; anything that reasons about the *shape* of a run
    /// (the AI read, the coach's negative-split call) reads these.
    func kilometreSplits(type: WorkoutType = .run) -> [CardioMetrics.SplitResult] {
        CardioMetrics.splits(samplePoints(type: type), unitMeters: 1000)
    }

    /// Persisted splits when the row has them, else computed from the samples. Runs recorded before
    /// splits were persisted — and imported ones, which have no samples at all — still answer.
    func splitResults(type: WorkoutType = .run) -> [CardioMetrics.SplitResult] {
        if !splits.isEmpty {
            return splits.sorted { $0.index < $1.index }
                .map { .init(index: $0.index, distanceM: $0.distanceM,
                             durationS: $0.durationS, isPartial: $0.isPartial) }
        }
        return kilometreSplits(type: type)
    }
}
