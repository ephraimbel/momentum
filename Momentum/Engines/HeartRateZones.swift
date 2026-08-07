import Foundation

/// Heart-rate training zones (running-excellence R3). The standard 5-zone %-of-max model — Z1 recovery
/// through Z5 VO₂max. Pure + deterministic; `maxHR` comes from `UserProfile` (Tanaka estimate at
/// onboarding, or a measured value). No medical claims — these are training-intensity bands, not
/// diagnostics. (The in-zone distribution/label/bounds helpers were superseded by
/// `ZoneDistribution.compute` and deleted on the 2026-08-06 dead-code pass.)
enum HeartRateZones {
    /// The zone (1…5) for a heart rate, by percentage of max. Below Z1's floor still reads as Z1.
    static func zone(forBpm bpm: Int, maxHR: Int) -> Int {
        guard maxHR > 0, bpm > 0 else { return 1 }
        switch Double(bpm) / Double(maxHR) {
        case ..<0.60: return 1
        case ..<0.70: return 2
        case ..<0.80: return 3
        case ..<0.90: return 4
        default:      return 5
        }
    }
}

/// Small aggregators for hardware run signals (cadence, HR) sampled once a second during a run.
enum RunSignals {
    /// Rounded mean of the positive readings; nil when there are none (motion-less run / simulator).
    static func mean(_ values: [Int]) -> Int? {
        let v = values.filter { $0 > 0 }
        guard !v.isEmpty else { return nil }
        return Int((Double(v.reduce(0, +)) / Double(v.count)).rounded())
    }
}
