import Foundation

/// Post-session pace review (running-excellence R4) — the coach layer that reads a structured run's
/// achieved-vs-prescribed step results and renders a verdict, Runna-style: On point / Ahead /
/// Review / Variable. Pure + deterministic — the numbers and classification are rules; any AI only
/// ever narrates the same decision. No-shame by design: "Review" reads as "let's make the targets
/// honest", never as failure.
enum PaceInsights {

    enum Verdict: String, Sendable {
        case onPoint = "On point"
        case ahead = "Ahead"
        case review = "Review"
        case variable = "Variable"
    }

    /// One reviewed work step: what was asked vs what was run.
    struct RepLine: Identifiable, Equatable, Sendable {
        let id: Int
        /// "Rep 3/6", "Tempo", "Work" — mirrors the live banner's label.
        let label: String
        let targetSPerKm: Double
        let achievedSPerKm: Double
        var deltaSPerKm: Double { achievedSPerKm - targetSPerKm }
    }

    struct Analysis: Equatable, Sendable {
        let verdict: Verdict
        let headline: String
        let detail: String
        let reps: [RepLine]
        /// Mean achieved−target across reviewed steps (s/km; negative = faster than prescribed).
        let meanDeltaSPerKm: Double
        /// True when the verdict earns the consent-gated "ease future paces" offer.
        let suggestsEasing: Bool
    }

    /// Review a structured run's recorded steps. Returns nil when there's nothing meaningful to
    /// review (no work steps with both a target and a sane achieved pace) — no card, no noise.
    static func analyze(_ results: [StepResult], unit: DistanceUnit = .auto) -> Analysis? {
        let work = results.filter { $0.kind == WorkoutStep.Kind.work.rawValue && !$0.skipped }
        var lines: [RepLine] = []
        for (i, r) in work.enumerated() {
            guard let target = r.targetPaceSPerKm, target > 0,
                  let achieved = r.achievedPaceSPerKm,
                  achieved < target * 2.5   // a paused/aborted rep is not a pacing signal
            else { continue }
            let label: String = {
                if let n = r.repIndex, let total = r.repTotal { return "Rep \(n)/\(total)" }
                return work.count == 1 ? "Work" : "Rep \(i + 1)"
            }()
            lines.append(RepLine(id: i, label: label, targetSPerKm: target, achievedSPerKm: achieved))
        }
        guard !lines.isEmpty else { return nil }

        let deltas = lines.map(\.deltaSPerKm)
        let mean = deltas.reduce(0, +) / Double(deltas.count)
        let spread = (deltas.max() ?? 0) - (deltas.min() ?? 0)
        // The prescription's own tolerance band decides "close enough" — the same band that earned
        // the live iridescent glow.
        let tolerances = work.map(\.toleranceSPerKm).filter { $0 > 0 }
        let tol = tolerances.isEmpty ? 12 : tolerances.reduce(0, +) / Double(tolerances.count)

        let verdict: Verdict
        if lines.count >= 3, spread > tol * 2.5 { verdict = .variable }
        else if abs(mean) <= tol { verdict = .onPoint }
        else if mean < 0 { verdict = .ahead }
        else { verdict = .review }

        let (headline, detail) = narrative(verdict, meanDelta: mean, spread: spread, unit: unit)
        return Analysis(verdict: verdict, headline: headline, detail: detail, reps: lines,
                        meanDeltaSPerKm: mean, suggestsEasing: verdict == .review)
    }

    /// The coach's read — templated, self-relative, and no-shame (never "failed", no medical claims).
    private static func narrative(_ verdict: Verdict, meanDelta: Double, spread: Double,
                                  unit: DistanceUnit) -> (String, String) {
        let perUnit = unit.resolved() == .imperial ? Formatters.metersPerMile / 1000 : 1
        let label = unit.resolved() == .imperial ? "mi" : "km"
        let meanText = "\(Int((abs(meanDelta) * perUnit).rounded()))s/\(label)"
        let spreadText = "\(Int((spread * perUnit).rounded()))s/\(label)"
        switch verdict {
        case .onPoint:
            return ("Right on your targets",
                    "You ran the prescription as written — these paces fit you right now, so the plan holds steady.")
        case .ahead:
            return ("Ahead of your targets",
                    "You averaged \(meanText) faster than prescribed. Strong sign — keep easy days easy, and your plan paces will step up as this holds.")
        case .review:
            return ("Targets ran a touch hot",
                    "You averaged \(meanText) slower than prescribed. One session is just one session — but I can ease your future paces so the reps land the way they should.")
        case .variable:
            return ("Uneven reps",
                    "Your reps swung \(spreadText) apart. Even pacing beats fast starts — try running the first rep like you want to run the last.")
        }
    }
}
