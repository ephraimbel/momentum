import Foundation

/// Post-session pace review (running-excellence R4) — the coach's read of ONE guided run's recorded
/// reps (`RepResult`), verdict-style: On point / Ahead / Review / Variable. Complements the
/// cross-session `PaceInsights` trend (which reads whole-run averages over weeks); this reviews the
/// reps you just ran and, only for "Review", offers the consent-gated pace easing
/// (`PlanCoaching.easeQualityPaces`). Pure + deterministic — any AI only narrates the same decision.
/// No-shame by design: "Review" reads as "let's make the targets honest", never as failure.
enum SessionPaceReview {

    enum Verdict: String, Sendable {
        case onPoint = "On point"
        case ahead = "Ahead"
        case review = "Review"
        case variable = "Variable"
    }

    struct Analysis: Equatable, Sendable {
        let verdict: Verdict
        let headline: String
        let detail: String
        /// Mean achieved−target across reviewed reps (s/km; negative = faster than prescribed).
        let meanDeltaSPerKm: Double
        let repsReviewed: Int
        /// True when the verdict earns the consent-gated "ease future paces" offer.
        let suggestsEasing: Bool
    }

    /// Review a guided run's recorded reps. Returns nil when there's nothing meaningful to review
    /// (no reps with both a target and a sane achieved pace) — no card, no noise.
    static func analyze(_ reps: [RepResult], unit: DistanceUnit = .auto) -> Analysis? {
        let valid = reps.filter { rep in
            guard let target = rep.targetPaceSPerKm, target > 0 else { return false }
            // A paused/aborted rep (walking-lost-GPS pace) is not a pacing signal; nor is a
            // skipped-instantly sliver of a rep.
            return rep.achievedPaceSPerKm > 0 && rep.achievedPaceSPerKm < target * 2.5
                && rep.distanceM >= 50
        }
        guard !valid.isEmpty else { return nil }

        let deltas = valid.map { $0.achievedPaceSPerKm - ($0.targetPaceSPerKm ?? 0) }
        let mean = deltas.reduce(0, +) / Double(deltas.count)
        let spread = (deltas.max() ?? 0) - (deltas.min() ?? 0)
        // The prescription's own tolerance band decides "close enough" — the same band that earned
        // the live on-pace glow and the per-rep verdict chips.
        let tolerances = valid.map(\.toleranceSPerKm).filter { $0 > 0 }
        let tol = tolerances.isEmpty ? 12 : tolerances.reduce(0, +) / Double(tolerances.count)

        let verdict: Verdict
        if valid.count >= 3, spread > tol * 2.5 { verdict = .variable }
        else if abs(mean) <= tol { verdict = .onPoint }
        else if mean < 0 { verdict = .ahead }
        else { verdict = .review }

        let (headline, detail) = narrative(verdict, meanDelta: mean, spread: spread, unit: unit)
        return Analysis(verdict: verdict, headline: headline, detail: detail,
                        meanDeltaSPerKm: mean, repsReviewed: valid.count,
                        suggestsEasing: verdict == .review)
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
