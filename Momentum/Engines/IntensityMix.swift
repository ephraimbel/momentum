import Foundation

/// Describes what fraction of recent running was easy versus quality work (ENDURANCE-FOCUS §12).
/// The 80% marker is a familiar reference, not a universal prescription: event, phase, training age,
/// and classification method all change the appropriate distribution. Pure + tested.
enum IntensityMix {
    enum Verdict: String, Sendable {
        case polarized       // ≥ ~75% easy — mostly easy
        case grey            // 60–75% easy — mixed intensity
        case tooHard         // < 60% easy — hard work dominates the sample
    }

    struct Mix: Sendable, Equatable {
        let easyCount: Int
        let hardCount: Int
        let easyFraction: Double     // 0…1
        let verdict: Verdict

        var blurb: String {
            switch verdict {
            case .polarized: "Most of your running is easy, with quality kept deliberate."
            case .grey:      "Your recent mix is more even. Check that easy days still feel genuinely easy."
            case .tooHard:   "Hard work dominates this sample. Review the block before adding more intensity."
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
