import Foundation

/// Deterministic coaching narrative for the Progress page (PRD §4.7, §8.8). Turns the rules-based
/// `ProgressInsights` into a warm, plain-language read + a concrete plan tweak. No medical claims.
/// (A future AIService call can replace the prose; this is the always-present fallback.)
@MainActor
enum ProgressNarrator {
    static func coach(_ insights: ProgressInsights, streak: Int) -> String {
        guard insights.hasData else {
            return "Log a few sessions and I'll start reading how you're progressing — and tune your plan around it."
        }
        let acwr = String(format: "%.1f", insights.acwr)
        switch insights.recommendation {
        case .start:
            return "Early days, so consistency first. Hit your planned days this week and I'll start reading your trend."
        case .increase:
            return "You've got room to grow. Your training is below your usual load, so let's add about 10% next week.\(streakLine(streak))"
        case .hold:
            return "You're building well. Load is \(trendWord(insights.loadTrendPct)) and well-absorbed, so hold here, then we'll nudge it up.\(streakLine(streak))"
        case .ease:
            return "You're pushing hard. This week is \(acwr)× your normal load, so keep the next couple of sessions easy to absorb the work."
        case .rest:
            return "That's a sharp jump. This week is \(acwr)× your normal load, so take a rest day; that's where the gains land."
        }
    }

    /// A short action label for the recommendation chip.
    static func action(_ r: ProgressInsights.Recommendation) -> String {
        switch r {
        case .start: "Build consistency"
        case .increase: "Add ~10% next week"
        case .hold: "Hold steady"
        case .ease: "Keep it easy"
        case .rest: "Take a rest day"
        }
    }

    private static func trendWord(_ pct: Double) -> String {
        if pct >= 5 { return "up \(Int(pct.rounded()))%" }
        if pct <= -5 { return "down \(Int((-pct).rounded()))%" }
        return "steady"
    }

    private static func streakLine(_ streak: Int) -> String {
        streak >= 3 ? " \(streak)-day streak, keep it rolling." : ""
    }
}
