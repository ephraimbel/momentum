import Foundation

/// Pure, deterministic spoken-cue text for the voice coach (PRD §4.10 — Pro). The synthesizer just
/// reads these strings; building the wording here keeps it testable and free of AVFoundation. Cues
/// are short, factual, second-person where natural, and never make medical claims.
enum CoachingCueBuilder {

    /// A completed-unit milestone, e.g. "Mile 3. 8 minutes 45 seconds per mile." The split pace is
    /// omitted when unknown (≤0), giving just "Mile 3."
    static func milestone(unitCount: Int, splitSecPerUnit: Double, unit: DistanceUnit) -> String {
        let name = unitName(unit)
        let header = "\(name.capitalized) \(unitCount)."
        guard splitSecPerUnit > 0 else { return header }
        return "\(header) \(spokenPace(secPerUnit: splitSecPerUnit)) per \(name)."
    }

    static func restComplete() -> String { "Rest complete. Time for your next set." }
    static func paused() -> String { "Paused." }
    static func resumed() -> String { "Resumed." }
    static func goalReached() -> String { "Goal reached. Strong work." }

    // MARK: Structured workout (R1)

    /// Spoken when a guided step begins — e.g. "Rep 3 of 6. 400 meters at your target. Go.",
    /// "Recover. 90 seconds easy.", "Warm up. Ease in.", "Cool down. Nice and easy."
    static func stepStart(_ step: WorkoutStep) -> String {
        switch step.kind {
        case .warmup: return "Warm up. Ease in."
        case .cooldown: return "Cool down. Nice and easy."
        case .recovery:
            if case let .duration(s) = step.target { return "Recover. \(spokenPace(secPerUnit: s)) easy." }
            return "Recover. Easy now."
        case .work:
            if let i = step.repIndex, let n = step.repTotal {
                return "Rep \(i) of \(n). \(spokenTarget(step.target)) at your target. Go."
            }
            return "\(spokenTarget(step.target)) at tempo. Hold your effort."
        }
    }

    /// A gentle pace nudge inside a work step. Never a shame state — just a direction.
    static func paceNudge(_ adherence: StructuredRunTracker.Adherence) -> String {
        switch adherence {
        case .tooFast: "Ease back a touch."
        case .tooSlow: "Pick it up."
        case .onPace, .noTarget: ""
        }
    }

    static func workoutComplete() -> String { "Workout complete. Strong session." }

    /// A step target spoken naturally: "400 meters" / "1 kilometer" / "90 seconds".
    static func spokenTarget(_ target: WorkoutStep.Target) -> String {
        switch target {
        case let .distance(m):
            if m < 1000 { return "\(Int(m.rounded())) meters" }
            let km = m / 1000
            let n = km == km.rounded() ? String(Int(km)) : String(format: "%.1f", km)
            return "\(n) kilometer\(km == 1 ? "" : "s")"
        case let .duration(s):
            return spokenPace(secPerUnit: s)
        }
    }

    /// "mile" (imperial) or "kilometer" (metric); `auto` resolves via locale.
    static func unitName(_ unit: DistanceUnit) -> String {
        unit.resolved() == .imperial ? "mile" : "kilometer"
    }

    /// A seconds-per-unit value spoken naturally: "8 minutes 45 seconds" / "8 minutes" / "45 seconds".
    static func spokenPace(secPerUnit: Double) -> String {
        let total = Int(secPerUnit.rounded())
        let minutes = total / 60, seconds = total % 60
        var parts: [String] = []
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if seconds > 0 { parts.append("\(seconds) second\(seconds == 1 ? "" : "s")") }
        if parts.isEmpty { parts.append("0 seconds") }
        return parts.joined(separator: " ")
    }
}
