import Foundation

/// Pure cardio calculations (PRD §21): split closing and fastest-window PR scanning.
/// Operates on accepted samples reduced to `(elapsed time, cumulative distance)`.
enum CardioMetrics {
    struct SamplePoint: Equatable, Sendable {
        let t: TimeInterval      // seconds since start
        let cumulativeM: Double  // cumulative accepted distance
    }

    struct SplitResult: Equatable, Sendable {
        let index: Int
        let distanceM: Double
        let durationS: TimeInterval
        let isPartial: Bool
    }

    /// Fastest contiguous time to cover `distanceM`, scanning windows that end at each sample
    /// with linear interpolation of the start point. Returns nil if the activity is too short.
    /// O(n) via a monotonic start pointer (cumulative distance is non-decreasing).
    static func fastestWindow(_ samples: [SamplePoint], distanceM: Double) -> TimeInterval? {
        guard distanceM > 0, let last = samples.last, last.cumulativeM >= distanceM,
              samples.count >= 2 else { return nil }

        var best = TimeInterval.infinity
        var i = 0
        for j in 0..<samples.count {
            let targetStart = samples[j].cumulativeM - distanceM
            if targetStart < 0 { continue }
            while i + 1 < samples.count && samples[i + 1].cumulativeM <= targetStart { i += 1 }

            let tStart: TimeInterval
            if samples[i].cumulativeM >= targetStart || i + 1 >= samples.count {
                tStart = samples[i].t
            } else {
                let d0 = samples[i].cumulativeM, d1 = samples[i + 1].cumulativeM
                let frac = d1 > d0 ? (targetStart - d0) / (d1 - d0) : 0
                tStart = samples[i].t + frac * (samples[i + 1].t - samples[i].t)
            }
            best = min(best, samples[j].t - tStart)
        }
        return best.isFinite ? best : nil
    }

    /// Close one split per whole display unit (km or mi), interpolating time at each boundary;
    /// the final fractional segment is `isPartial`. HR/cadence/elev per split: TODO (Phase 1).
    static func splits(_ samples: [SamplePoint], unitMeters: Double) -> [SplitResult] {
        guard unitMeters > 0, samples.count >= 2,
              let first = samples.first, let last = samples.last else { return [] }

        var result: [SplitResult] = []
        var nextBoundary = unitMeters
        var prevBoundaryTime = first.t
        var idx = 0

        for k in 1..<samples.count {
            let a = samples[k - 1], b = samples[k]
            while b.cumulativeM >= nextBoundary {
                let d0 = a.cumulativeM, d1 = b.cumulativeM
                let frac = d1 > d0 ? (nextBoundary - d0) / (d1 - d0) : 0
                let tBoundary = a.t + frac * (b.t - a.t)
                result.append(SplitResult(index: idx, distanceM: unitMeters,
                                          durationS: tBoundary - prevBoundaryTime, isPartial: false))
                idx += 1
                prevBoundaryTime = tBoundary
                nextBoundary += unitMeters
            }
        }

        let remaining = last.cumulativeM - Double(idx) * unitMeters
        if remaining > 1 { // ignore sub-meter tail
            result.append(SplitResult(index: idx, distanceM: remaining,
                                      durationS: last.t - prevBoundaryTime, isPartial: true))
        }
        return result
    }
}
