import Foundation

/// Post-run RPE → plan adaptation (running-excellence; Runna's RPE loop, but automatic and no-shame).
/// Compares how hard a session *felt* (the athlete's 1–10 perceived effort) against how hard it was
/// *prescribed* to feel, and turns a clear mismatch into a plan nudge: a session that felt far harder
/// than it should signals fatigue (ease the block); a hard session that felt easy signals freshness
/// (headroom — informational only, since raising load is never automatic, PRD §9.4).
///
/// Pure + deterministic; `PlanCoaching.adaptToEffort` applies the decision.
enum EffortAdaptation {
    enum Outcome: Equatable, Sendable { case none, ease, recover, headroom }

    /// How hard each run type is *meant* to feel on the 1–10 RPE scale.
    static func expectedRPE(_ type: RunType) -> Int {
        switch type {
        case .recovery: 3
        case .easy, .freeRun, .strides: 4
        case .long: 5
        case .progression: 6
        case .tempo, .fartlek, .hills: 7
        case .intervals: 8
        case .race: 9
        }
    }

    /// Judge a finished run's effort. Needs both an RPE and a prescribed run type.
    static func judge(rpe: Int?, runType: RunType?) -> Outcome {
        guard let rpe, rpe > 0, let type = runType else { return .none }
        let expected = expectedRPE(type)
        // A low-effort day (easy / recovery / long) that felt brutal is the clearest fatigue signal.
        if !type.isQuality, rpe >= 8 { return .recover }
        if rpe - expected >= 3 { return .ease }                       // notably harder than prescribed
        // A hard-prescribed session that felt easy → genuine freshness / headroom (informational).
        if type.isQuality, rpe <= expected - 3, rpe <= 5 { return .headroom }
        return .none
    }

    /// No-shame narration for an applied adaptation (nil for none/headroom, which change nothing).
    static func note(for outcome: Outcome) -> (headline: String, detail: String)? {
        switch outcome {
        case .ease:
            return ("That one took it out of you",
                    "It felt harder than it should have, so I eased your next few sessions to let you absorb it. No streak lost.")
        case .recover:
            return ("Banking some recovery",
                    "An easy day that feels tough is your body asking for rest — your next session is now a recovery day.")
        case .none, .headroom:
            return nil
        }
    }
}
