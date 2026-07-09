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

    /// A natural noun for a run type, for coaching copy ("your easy run felt tough").
    static func sessionNoun(_ rt: RunType) -> String {
        switch rt {
        case .easy: "easy run"
        case .recovery: "recovery run"
        case .long: "long run"
        case .tempo: "tempo"
        case .intervals: "speed session"
        case .fartlek: "fartlek"
        case .hills: "hill session"
        case .strides: "strides session"
        case .progression: "progression run"
        case .race: "race"
        case .freeRun: "run"
        }
    }

    /// No-shame narration for an applied adaptation, naming the session that triggered it (nil for
    /// none/headroom, which change nothing).
    static func note(for outcome: Outcome, runType: RunType? = nil, rpe: Int? = nil) -> (headline: String, detail: String)? {
        let session = runType.map(sessionNoun) ?? "session"
        switch outcome {
        case .ease:
            let effort = rpe.map { " (you rated it \($0)/10)" } ?? ""
            return ("That one took it out of you",
                    "Your \(session) felt harder than it should have\(effort), so I eased your next few sessions to let you absorb it. No streak lost.")
        case .recover:
            let effort = rpe.map { "an honest \($0)/10" } ?? "tough"
            return ("Banking some recovery",
                    "Your \(session) felt like \(effort) today — that's your body asking for rest, so your next session is now a recovery day.")
        case .none, .headroom:
            return nil
        }
    }
}
