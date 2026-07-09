import Foundation

/// Personalized five-zone heart-rate model (ENDURANCE-FOCUS §10) — the backbone of pro-grade
/// prescription and analysis. Uses **Karvonen** (heart-rate reserve) when we know the athlete's
/// resting HR (far more individual than %max); falls back to %max otherwise. Pure + deterministic.
enum HRZones {
    struct Zone: Sendable, Equatable, Identifiable {
        let index: Int                 // 1…5
        let name: String
        let purpose: String
        let bpm: ClosedRange<Int>
        var id: Int { index }
        var label: String { "Z\(index)" }
    }

    /// Zone floors as fractions of HR reserve (Karvonen) or max HR — the classic 50/60/70/80/90 model.
    private static let floors: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9]
    private static let names = ["Recovery", "Easy", "Aerobic", "Threshold", "Max"]
    private static let purposes = [
        "Active recovery — barely trying",
        "Conversational — where the engine is built",
        "Steady — comfortably hard, marathon effort",
        "Hard — the redline you can hold ~an hour",
        "Very hard — intervals and finishing kicks",
    ]

    /// The athlete's five zones. Karvonen (`restingHR` known): floor = rest + f·(max − rest);
    /// otherwise %max: floor = f·max. Returns nil when maxHR is missing/nonsense.
    static func zones(maxHR: Int, restingHR: Int? = nil) -> [Zone]? {
        guard maxHR > 100 else { return nil }
        let rest = restingHR.flatMap { $0 > 25 && $0 < maxHR ? Double($0) : nil }
        func floorBPM(_ f: Double) -> Int {
            if let rest { return Int((rest + f * (Double(maxHR) - rest)).rounded()) }
            return Int((f * Double(maxHR)).rounded())
        }
        var out: [Zone] = []
        for i in 0..<5 {
            let lo = floorBPM(floors[i])
            let hi = i == 4 ? maxHR : floorBPM(floors[i + 1]) - 1
            guard hi >= lo else { return nil }
            out.append(Zone(index: i + 1, name: names[i], purpose: purposes[i], bpm: lo...hi))
        }
        return out
    }

    /// The zone a run type is meant to live in — pace targets get an HR anchor too.
    static func zoneIndex(for runType: RunType) -> Int {
        switch runType {
        case .recovery:                       1
        case .easy, .long, .freeRun:          2
        case .fartlek, .strides, .progression: 3
        case .tempo:                          4
        case .intervals, .hills, .race:       5
        }
    }

    /// "Z2 · 128–141 bpm" for a session row, when we know the athlete's zones.
    static func target(for runType: RunType, maxHR: Int?, restingHR: Int?) -> String? {
        guard let maxHR, let zones = zones(maxHR: maxHR, restingHR: restingHR) else { return nil }
        let z = zones[zoneIndex(for: runType) - 1]
        return "\(z.label) · \(z.bpm.lowerBound)–\(z.bpm.upperBound) bpm"
    }
}
