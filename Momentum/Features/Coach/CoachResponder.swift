import Foundation

/// Deterministic coach replies grounded in the athlete's real data (PRD §4.7/§9 — rules compute, AI
/// narrates). This is the always-available fallback that runs with no backend, and the safety net
/// when the `coach-chat` Edge Function is slow or down. No medical claims; no-shame tone.
@MainActor
enum CoachResponder {
    struct Context {
        let insights: ProgressInsights
        let stats: ProfileStats
        let todaySession: PlannedSession?
        let goal: Goal
        let disciplines: [String]
        let distanceUnit: DistanceUnit
    }

    static let suggestions = ["How am I doing?", "What should I do today?", "Am I overtraining?", "How's my streak?"]

    static func reply(to message: String, context ctx: Context) -> String {
        let q = message.lowercased()
        let i = ctx.insights
        let s = ctx.stats

        func has(_ words: [String]) -> Bool { words.contains { q.contains($0) } }

        // Today / what to do
        if has(["today", "what should i", "what do i do", "workout now", "should i train", "next session"]) {
            if let session = ctx.todaySession {
                let brief = PlanCoaching.brief(for: session, distanceUnit: ctx.distanceUnit)
                let why = session.rationale.map { " \($0)" } ?? ""
                return "Today's plan is \(brief).\(why) Tap Today's Plan when you're ready — I'll walk you in."
            }
            switch i.recommendation {
            case .rest, .ease:
                return "Nothing's scheduled, and your load is on the higher side — I'd keep it easy today. A short recovery walk or a rest day will pay off."
            default:
                let pick = ctx.disciplines.contains("strength") && !ctx.disciplines.contains("running") ? "a strength session" : "an easy run"
                return "Nothing's on the calendar today. If you're feeling good, \(pick) would fit your goal nicely — start one from the map."
            }
        }

        // Overtraining / recovery
        if has(["overtrain", "overdoing", "too much", "rest", "recover", "tired", "sore", "burn"]) {
            if i.recommendation == .rest {
                return "Yes — ease off. Your acute:chronic load is \(acwrText(i)), above the 0.8–1.3 sweet spot. Take a rest or recovery day and we'll rebuild from there. Rest is where the gains land."
            }
            if i.recommendation == .ease {
                return "You're pushing a bit — load balance \(acwrText(i)). Not alarming, but I'd pull the next session back ~15% so you absorb the work."
            }
            return "You're not overdoing it — load balance \(acwrText(i)), \(i.acwr >= 0.8 ? "right in" : "a touch below") the 0.8–1.3 sweet spot. Listen to your body, but the numbers say you've got room."
        }

        // Push harder / increase
        if has(["more", "harder", "increase", "push", "add", "ramp", "build"]) {
            switch i.recommendation {
            case .increase, .hold, .start:
                return "You've got room — I'd add about 10% next week rather than all at once. Open Progress and tap the coach chip and I'll bump your plan."
            case .ease, .rest:
                return "I'd hold off on more right now — your load's already high (\(acwrText(i))). Let's absorb this block first, then ramp."
            }
        }

        // Streak
        if has(["streak", "consistent", "consistency", "days in a row"]) {
            let d = s.currentStreak
            if d <= 0 { return "No active streak yet — knock out any session today and you're rolling. Rest days count, and one slipped day is always forgiven." }
            return "\(d) day\(d == 1 ? "" : "s") and counting. Rest days count and a single slipped day is forgiven, so just keep moving — you won't lose it easily."
        }

        // PRs / records
        if has(["pr", "record", "strongest", "best lift", "1rm", "e1rm", "max"]) {
            if let pr = s.strengthPRs.first {
                return "Your standout is \(pr.name) at an estimated \(Formatters.weight(kg: pr.e1RMKg, unit: .default())) one-rep max. Keep the working sets honest and that'll climb."
            }
            return "No strength PRs on the board yet — log a few lifting sessions and I'll start tracking your estimated maxes."
        }

        // How am I doing / progress / trending
        if has(["how am i", "progress", "trend", "doing", "improv", "getting better", "fitness"]) {
            return ProgressNarrator.coach(i, streak: s.currentStreak)
        }

        // Greeting
        if has(["hi", "hey", "hello", "yo", "sup"]) && q.count < 12 {
            return "Hey — I'm your coach. I can talk through how you're trending, what to do today, recovery, or your records. What's on your mind?"
        }

        // Fallback — grounded, points somewhere useful
        let lead = i.hasData
            ? "Right now you're \(i.status.rawValue.lowercased()) (load balance \(acwrText(i)))."
            : "We're just getting started — log a few sessions and I'll have a lot more to say."
        return "\(lead) I can help with how you're trending, what to do today, recovery, or your records — just ask."
    }

    private static func acwrText(_ i: ProgressInsights) -> String {
        i.acwr > 0 ? String(format: "%.2f", i.acwr) : "still building"
    }
}
