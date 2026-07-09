import Foundation

/// Heart-rate training zones (running-excellence R3). The standard 5-zone %-of-max model — Z1 recovery
/// through Z5 VO₂max — plus the in-zone distribution for the post-run breakdown. Pure + deterministic;
/// `maxHR` comes from `UserProfile` (Tanaka estimate at onboarding, or a measured value). No medical
/// claims — these are training-intensity bands, not diagnostics.
enum HeartRateZones {
    static let count = 5

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

    /// Fraction of samples spent in each of the 5 zones (sums to 1). Empty when there's no HR data.
    static func distribution(bpms: [Int], maxHR: Int) -> [Double] {
        guard maxHR > 0 else { return [] }
        var counts = [Int](repeating: 0, count: count)
        for b in bpms where b > 0 { counts[zone(forBpm: b, maxHR: maxHR) - 1] += 1 }
        let total = counts.reduce(0, +)
        guard total > 0 else { return [] }
        return counts.map { Double($0) / Double(total) }
    }

    /// Short name for a zone (1…5).
    static func label(_ zone: Int) -> String {
        switch zone {
        case 1: "Recovery"
        case 2: "Easy"
        case 3: "Tempo"
        case 4: "Threshold"
        default: "VO₂ max"
        }
    }

    /// The lower %maxHR bound of a zone — for axis ticks / "Z3 · 70%" labels.
    static func lowerBoundPct(_ zone: Int) -> Int {
        [50, 60, 70, 80, 90][max(0, min(4, zone - 1))]
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
