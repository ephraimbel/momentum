import Foundation

/// The polarized-training check (ENDURANCE-FOCUS §12): what fraction of recent running was actually
/// easy? Elite practice — and the research behind it — lands near **80/20 easy:hard**; the classic
/// self-coached mistake is drifting into the grey middle (every run "kind of hard"). Pure + tested.
enum IntensityMix {
    enum Verdict: String, Sendable {
        case polarized       // ≥ ~75% easy — the sweet spot
        case grey            // 60–75% easy — drifting hard
        case tooHard         // < 60% easy — the engine never gets built
    }

    struct Mix: Sendable, Equatable {
        let easyCount: Int
        let hardCount: Int
        let easyFraction: Double     // 0…1
        let verdict: Verdict

        var blurb: String {
            switch verdict {
            case .polarized: "Right in the polarized sweet spot — easy days are building your engine."
            case .grey:      "Drifting toward the grey zone. Make the easy days truly easy."
            case .tooHard:   "Most runs are hard — easy running is where the aerobic engine gets built."
            }
        }
    }

    /// One analyzed run: its average pace, and (when it came from the plan) whether it was prescribed
    /// as quality — the prescription outranks the pace read.
    struct RunInput: Sendable {
        let paceSPerKm: Double
        let plannedQuality: Bool?
    }

    /// Minimum runs before the split means anything.
    static let minRuns = 4
    /// Pace gate: faster than p5k + 50 s/km reads as a hard effort (easy runs live in the E zone,
    /// slower than this at every VDOT; threshold/interval work is always faster).
    static let hardOffsetSPerKm = 50.0

    static func analyze(runs: [RunInput], p5kSPerKm: Double) -> Mix? {
        let valid = runs.filter { $0.paceSPerKm > 0 }
        guard valid.count >= minRuns, p5kSPerKm > 0 else { return nil }
        let hardGate = p5kSPerKm + hardOffsetSPerKm
        let hard = valid.filter { $0.plannedQuality ?? ($0.paceSPerKm < hardGate) }.count
        let easy = valid.count - hard
        let frac = Double(easy) / Double(valid.count)
        let verdict: Verdict = frac >= 0.75 ? .polarized : frac >= 0.60 ? .grey : .tooHard
        return Mix(easyCount: easy, hardCount: hard, easyFraction: frac, verdict: verdict)
    }
}
