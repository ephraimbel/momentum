import Foundation

/// Which open planned session a free workout actually fulfills (PRD §9.4). Pure and deliberately
/// strict about magnitude: a 1 km jog must never mark a 15 km long run complete — a false credit
/// silently deletes the athlete's key session from the plan (credited sessions are skipped by
/// missed-session reconciliation, so they never come back).
enum PlanCredit {
    /// One open candidate session's prescription.
    struct Candidate: Sendable {
        let targetDistanceM: Double?
        let targetDurationS: Double?

        init(targetDistanceM: Double? = nil, targetDurationS: Double? = nil) {
            self.targetDistanceM = targetDistanceM
            self.targetDurationS = targetDurationS
        }
    }

    /// Minimum share of the prescription a workout must cover to credit it. Below this the session
    /// stays open (and reconciliation moves it forward) — doing *more* than prescribed always counts.
    static let minFulfillment = 0.7

    /// Index of the candidate this workout best fulfills, or nil when it doesn't plausibly complete
    /// any of them. Targeted sessions win by closest fit (ratio nearest 1, over- and under-shoot
    /// penalized alike); a session with no measurable target is the fallback — any real workout
    /// satisfies it.
    static func bestMatch(distanceM: Double, durationS: Double, candidates: [Candidate]) -> Int? {
        var best: (index: Int, score: Double)?
        var untargeted: Int?
        for (i, c) in candidates.enumerated() {
            if let ratio = fulfillment(of: c, distanceM: distanceM, durationS: durationS) {
                guard ratio >= minFulfillment else { continue }
                let score = abs(log(ratio))
                if best == nil || score < best!.score { best = (i, score) }
            } else if untargeted == nil {
                untargeted = i
            }
        }
        return best?.index ?? untargeted
    }

    /// Share of the prescription covered — distance target preferred, else duration; nil when the
    /// session has no measurable target (e.g. a strength day).
    static func fulfillment(of c: Candidate, distanceM: Double, durationS: Double) -> Double? {
        if let t = c.targetDistanceM, t > 0 { return distanceM / t }
        if let t = c.targetDurationS, t > 0 { return durationS / t }
        return nil
    }
}
