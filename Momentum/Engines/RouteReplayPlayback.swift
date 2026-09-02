import Foundation

/// Pure, deterministic playback geometry for the route-replay experience.
///
/// The map always draws the best available finished route (Mapbox-matched when present). The
/// canonical `GPSDetail.routePoints` reduction supplies the athlete's real moving-time shape, so a
/// fast opening kilometre, a slow climb, and a stop all advance the marker at the same relative
/// moments they happened. Shared posts deliberately carry no timestamps; those fall back to a
/// uniform trip along their already privacy-trimmed route.
struct RouteReplayTimeline: Sendable {
    struct Keyframe: Sendable, Equatable {
        let movingTimeS: Double
        let routeProgress: Double
    }

    struct State: Sendable, Equatable {
        let coordinate: GeoPoint
        /// Fraction of the route geometry revealed, 0...1.
        let routeProgress: Double
        /// Direction of travel, degrees clockwise from true north.
        let bearing: Double
    }

    let geometry: [GeoPoint]
    let keyframes: [Keyframe]
    let workoutDurationS: Double
    let totalDistanceM: Double
    let playbackDurationS: Double

    private let geometryDistanceM: [Double]
    private let geometryTotalM: Double

    var isPlayable: Bool { geometry.count > 1 && geometryTotalM > 0 }

    init(geometry: [GeoPoint], routePoints: [GPSDetail.RoutePoint] = [],
         workoutDurationS: Double, totalDistanceM: Double) {
        // Reject corrupt coordinates at the render boundary. A single malformed synced point must
        // not poison the whole replay or ask Mapbox to frame NaN/invalid latitude values.
        var clean: [GeoPoint] = []
        clean.reserveCapacity(geometry.count)
        for point in geometry where point.lat.isFinite && point.lon.isFinite
            && (-90...90).contains(point.lat) && (-180...180).contains(point.lon) {
            if clean.last != point { clean.append(point) }
        }
        self.geometry = clean

        var cumulative = Array(repeating: 0.0, count: clean.count)
        if clean.count > 1 {
            for index in 1..<clean.count {
                cumulative[index] = cumulative[index - 1] + clean[index - 1].distance(to: clean[index])
            }
        }
        geometryDistanceM = cumulative
        geometryTotalM = cumulative.last ?? 0
        self.workoutDurationS = max(0, workoutDurationS.isFinite ? workoutDurationS : 0)
        self.totalDistanceM = max(0, totalDistanceM.isFinite ? totalDistanceM : 0)
        playbackDurationS = Self.condensedDuration(for: workoutDurationS)

        let usable = routePoints.filter {
            $0.t.isFinite && $0.cumulativeM.isFinite && $0.t >= 0 && $0.cumulativeM >= 0
        }
        let sourceDuration = usable.last?.t ?? 0
        let sourceDistance = usable.last?.cumulativeM ?? 0
        if sourceDuration > 0, sourceDistance > 0 {
            var frames: [Keyframe] = [.init(movingTimeS: 0, routeProgress: 0)]
            frames.reserveCapacity(usable.count + 2)
            for point in usable {
                let time = min(sourceDuration, max(frames.last?.movingTimeS ?? 0, point.t))
                let progress = min(1, max(frames.last?.routeProgress ?? 0,
                                          point.cumulativeM / sourceDistance))
                if time > (frames.last?.movingTimeS ?? -1) {
                    frames.append(.init(movingTimeS: time, routeProgress: progress))
                } else if frames.indices.contains(frames.count - 1) {
                    frames[frames.count - 1] = .init(movingTimeS: time, routeProgress: progress)
                }
            }
            if frames.last?.movingTimeS != sourceDuration || frames.last?.routeProgress != 1 {
                frames.append(.init(movingTimeS: sourceDuration, routeProgress: 1))
            }
            keyframes = frames
        } else {
            keyframes = []
        }
    }

    /// Turns a workout into a watchable story: 30 minutes takes 10 seconds, a 90-minute long run
    /// takes 30, and very short/long sessions stay within those humane bounds.
    static func condensedDuration(for workoutDurationS: Double) -> Double {
        guard workoutDurationS.isFinite, workoutDurationS > 0 else { return 12 }
        return min(30, max(10, workoutDurationS / 180))
    }

    /// Map a normalized playback clock to the recorded route. `playbackProgress` is moving time,
    /// while the returned fraction is distance along the displayed geometry.
    func routeProgress(at playbackProgress: Double) -> Double {
        let p = Self.clamp(playbackProgress)
        guard let last = keyframes.last, last.movingTimeS > 0 else { return p }
        let target = p * last.movingTimeS
        guard target > 0 else { return 0 }
        guard target < last.movingTimeS else { return 1 }

        var low = 0
        var high = keyframes.count - 1
        while low < high {
            let mid = (low + high) / 2
            if keyframes[mid].movingTimeS < target { low = mid + 1 } else { high = mid }
        }
        let upper = keyframes[low]
        let lower = keyframes[max(0, low - 1)]
        let span = upper.movingTimeS - lower.movingTimeS
        guard span > 0 else { return upper.routeProgress }
        let local = (target - lower.movingTimeS) / span
        return Self.clamp(lower.routeProgress + (upper.routeProgress - lower.routeProgress) * local)
    }

    func state(at playbackProgress: Double) -> State? {
        guard isPlayable else { return nil }
        let routeProgress = routeProgress(at: playbackProgress)
        let currentCoordinate = coordinate(atRouteProgress: routeProgress)
        // Look a few metres ahead for a stable camera bearing. On a short trace, 0.2% of the
        // geometry is still enough to avoid rotating on sub-pixel GPS noise.
        let lookAhead = max(0.002, min(0.02, 8 / max(geometryTotalM, 1)))
        let next = coordinate(atRouteProgress: min(1, routeProgress + lookAhead))
        let previous = routeProgress >= 1
            ? coordinate(atRouteProgress: max(0, routeProgress - lookAhead)) : currentCoordinate
        let bearing = RouteDeviation.bearing(
            from: previous, to: routeProgress >= 1 ? currentCoordinate : next)
        return State(coordinate: currentCoordinate, routeProgress: routeProgress, bearing: bearing)
    }

    func elapsedTime(at playbackProgress: Double) -> Double {
        Self.clamp(playbackProgress) * workoutDurationS
    }

    func distance(at playbackProgress: Double) -> Double {
        routeProgress(at: playbackProgress) * totalDistanceM
    }

    private func coordinate(atRouteProgress progress: Double) -> GeoPoint {
        guard let first = geometry.first else { return GeoPoint(lat: 0, lon: 0) }
        guard geometry.count > 1, geometryTotalM > 0 else { return first }
        let target = Self.clamp(progress) * geometryTotalM
        if target <= 0 { return first }
        if target >= geometryTotalM { return geometry[geometry.count - 1] }

        var low = 1
        var high = geometryDistanceM.count - 1
        while low < high {
            let mid = (low + high) / 2
            if geometryDistanceM[mid] < target { low = mid + 1 } else { high = mid }
        }
        let upperIndex = low
        let lowerIndex = upperIndex - 1
        let lowerDistance = geometryDistanceM[lowerIndex]
        let span = geometryDistanceM[upperIndex] - lowerDistance
        guard span > 0 else { return geometry[upperIndex] }
        let local = (target - lowerDistance) / span
        let a = geometry[lowerIndex]
        let b = geometry[upperIndex]
        return GeoPoint(lat: a.lat + (b.lat - a.lat) * local,
                        lon: a.lon + (b.lon - a.lon) * local)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}
