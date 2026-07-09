import Foundation

/// Time-in-zones for a finished workout (ENDURANCE-FOCUS §12): heart-rate samples (from HealthKit —
/// Watch/Garmin runs carry a full series) bucketed into the athlete's five zones. Pure + tested.
enum ZoneDistribution {
    /// A sample's time credit runs to the next sample, capped so pauses/gaps don't inflate a zone.
    static let maxGapS: TimeInterval = 15

    /// Seconds in each of the five zones (index 0 = Z1). nil when there's nothing to distribute
    /// (fewer than 2 samples, or no zones).
    static func compute(samples: [(date: Date, bpm: Double)], zones: [HRZones.Zone]) -> [TimeInterval]? {
        guard samples.count >= 2, zones.count == 5 else { return nil }
        let sorted = samples.sorted { $0.date < $1.date }
        var out = [TimeInterval](repeating: 0, count: 5)
        for i in 0..<(sorted.count - 1) {
            let dt = min(sorted[i + 1].date.timeIntervalSince(sorted[i].date), maxGapS)
            guard dt > 0 else { continue }
            out[zoneIndex(bpm: sorted[i].bpm, zones: zones)] += dt
        }
        return out.contains(where: { $0 > 0 }) ? out : nil
    }

    /// Which zone a bpm falls in (0-based). Below Z1 clamps to Z1 (warmup drift), above Z5 to Z5.
    static func zoneIndex(bpm: Double, zones: [HRZones.Zone]) -> Int {
        for (i, z) in zones.enumerated() where Int(bpm.rounded()) <= z.bpm.upperBound {
            return i
        }
        return 4
    }
}
