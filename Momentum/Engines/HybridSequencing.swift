import Foundation

/// Hybrid sequencing — making momentum's cross-discipline coaching *visible* (PRD §9.3). The plan
/// already keeps a hard run off the day after a heavy leg lift; this narrates *why* the week is arranged
/// the way it is — the one thing a running-only coach (Runna) structurally can't do. Pure + testable.
enum HybridSequencing {
    /// A day's session reduced to what cross-discipline sequencing cares about.
    struct Item: Equatable, Sendable {
        let dayIndex: Int          // position within the week (0…6)
        let runType: RunType?      // nil for a lift
        let isHardRun: Bool        // quality or long
        let isLegDay: Bool         // a strength session emphasizing the lower body

        /// Muscle groups that count as "leg day" for recovery sequencing.
        static let legMuscles: Set<String> = ["quads", "hamstrings", "glutes", "calves"]
    }

    /// A one-line read of how the week's runs + lifts fit together. nil unless the week is genuinely
    /// hybrid (a leg day AND a hard/long run) — otherwise there's no cross-discipline story to tell.
    static func weekInsight(_ items: [Item]) -> String? {
        let legDays = items.filter(\.isLegDay).map(\.dayIndex).sorted()
        let hardRuns = items.filter { $0.runType != nil && $0.isHardRun }
        guard !legDays.isEmpty,
              let keyRun = hardRuns.first(where: { $0.runType == .long }) ?? hardRuns.first else { return nil }
        let name = keyRun.runType == .long ? "long run" : "hard run"
        let nearest = legDays.min(by: { abs($0 - keyRun.dayIndex) < abs($1 - keyRun.dayIndex) })!
        let gap = abs(nearest - keyRun.dayIndex)
        if keyRun.dayIndex > nearest {
            if gap == 1 { return "Leg day, then your \(name) the next day — take it by feel; fresh legs matter more than the clock." }
            return "Your \(name) lands \(gap) days after leg day — legs recovered and fresh for the miles."
        } else if keyRun.dayIndex < nearest {
            return "Your \(name) comes before leg day this week — you hit the miles on fresh legs, then lift."
        } else {
            return "Legs and your \(name) share a day — the run leads while you're fresh, lifting after."
        }
    }

    /// Why a hard run sits where it does relative to leg days — attached at generation for the session
    /// detail. nil when the week has no leg day (nothing cross-discipline to explain).
    static func runRationale(dayIndex: Int, runType: RunType, legDays: Set<Int>) -> String? {
        guard !legDays.isEmpty else { return nil }
        let name = runType == .long ? "Long run" : "Hard session"
        if let gapAfter = legDays.filter({ $0 < dayIndex }).map({ dayIndex - $0 }).min() {
            return "\(name) placed \(gapAfter) day\(gapAfter == 1 ? "" : "s") after leg day — fresh legs for the effort."
        }
        return "\(name) scheduled before leg day, so you hit it on fresh legs."
    }
}
