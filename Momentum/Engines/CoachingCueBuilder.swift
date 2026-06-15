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
