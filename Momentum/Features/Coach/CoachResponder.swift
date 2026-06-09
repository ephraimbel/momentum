import Foundation

/// Deterministic coach replies grounded in the athlete's real data and long-term memory (PRD §4.7/§9
/// — rules compute, AI narrates). This is the always-available fallback that runs with no backend,
/// and the safety net when the `coach-chat` Edge Function is slow or down. No medical claims;
/// no-shame tone; never uses em dashes (they read as generic AI slop).
@MainActor
enum CoachResponder {
    /// A decoupled projection of the Athlete Model, so the responder never depends on its schema.
    struct AthleteSummary {
        var notes: [String] = []                 // active memory, pinned first
        var preferredSessionMinutes: Int = 0
        var topDiscipline: String? = nil          // most-trained discipline (display name)
        var overreachACWR: Double = 0             // learned ratio where this athlete struggles
        var paceTrendPct: Double = 0              // easy-pace change at matched effort; negative = fitter
    }

    struct Context {
        let insights: ProgressInsights
        let stats: ProfileStats
        let todaySession: PlannedSession?
        let goal: Goal
        let disciplines: [String]
        let distanceUnit: DistanceUnit
        var athlete: AthleteSummary? = nil
    }

    static let suggestions = ["How am I doing?", "What should I do today?", "Am I overtraining?", "How's my streak?"]

    static func reply(to message: String, context ctx: Context) -> String {
        deDash(rawReply(to: message, context: ctx))
    }

    private static func rawReply(to message: String, context ctx: Context) -> String {
        let q = message.lowercased()
        let i = ctx.insights
        let s = ctx.stats
        let a = ctx.athlete

        func has(_ words: [String]) -> Bool { words.contains { q.contains($0) } }

        // What do you know about me / memory
        if has(["know about me", "remember", "who am i to you", "my profile", "what do you know"]) {
            let notes = a?.notes ?? []
            if notes.isEmpty {
                return "I'm still learning your patterns. The more you log, the sharper my read on how you train and recover."
            }
            return "Here's what I'm tracking: " + notes.prefix(3).joined(separator: "; ") + "."
        }

        // Today / what to do
        if has(["today", "what should i", "what do i do", "workout now", "should i train", "next session"]) {
            if let session = ctx.todaySession {
                let brief = PlanCoaching.brief(for: session, distanceUnit: ctx.distanceUnit)
                let why = session.rationale.map { " \($0)" } ?? ""
                return "Today's plan is \(brief).\(why) Tap Today's Plan when you're ready and I'll walk you in."
            }
            switch i.recommendation {
            case .rest, .ease:
                return "Nothing's scheduled, and your load is on the higher side. I'd keep it easy today: a short recovery walk or a rest day will pay off."
            default:
                let disc = a?.topDiscipline?.lowercased()
                    ?? (ctx.disciplines.contains("strength") && !ctx.disciplines.contains("running") ? "strength session" : "easy run")
                let mins = (a?.preferredSessionMinutes ?? 0) > 0 ? "\(a!.preferredSessionMinutes)-minute " : ""
                return "Nothing's on the calendar. If you're feeling good, a \(mins)\(disc) fits your goal nicely. Start one from the map."
            }
        }

        // Overtraining / recovery
        if has(["overtrain", "overdoing", "too much", "rest", "recover", "tired", "sore", "burn"]) {
            let thresh = (a?.overreachACWR ?? 0) > 0.8 ? a!.overreachACWR : 1.5
            if i.recommendation == .rest {
                return "Yes, ease off. Your load balance is \(acwrText(i)), past the 0.8 to 1.3 sweet spot, and you tend to struggle above \(String(format: "%.1f", thresh)). Take a rest or recovery day and we'll rebuild. Rest is where the gains land."
            }
            if i.recommendation == .ease {
                return "You're pushing a bit, load balance \(acwrText(i)). Not alarming, but I'd pull the next session back about 15% so you absorb the work."
            }
            return "You're not overdoing it. Load balance \(acwrText(i)), \(i.acwr >= 0.8 ? "right in" : "a touch below") the 0.8 to 1.3 sweet spot. Listen to your body, but the numbers say you've got room."
        }

        // Push harder / increase
        if has(["more", "harder", "increase", "push", "add", "ramp", "build"]) {
            switch i.recommendation {
            case .increase, .hold, .start:
                return "You've got room. I'd add about 10% next week rather than all at once. Open Progress, tap the coach chip, and I'll bump your plan."
            case .ease, .rest:
                return "I'd hold off on more right now, your load's already high at \(acwrText(i)). Let's absorb this block first, then ramp."
            }
        }

        // Streak
        if has(["streak", "consistent", "consistency", "days in a row"]) {
            let d = s.currentStreak
            if d <= 0 { return "No active streak yet. Knock out any session today and you're rolling. Rest days count, and one slipped day is always forgiven." }
            return "\(d) day\(d == 1 ? "" : "s") and counting. Rest days count and a single slipped day is forgiven, so just keep moving. You won't lose it easily."
        }

        // PRs / records
        if has(["pr", "record", "strongest", "best lift", "1rm", "e1rm", "max"]) {
            if let pr = s.strengthPRs.first {
                return "Your standout is \(pr.name) at an estimated \(Formatters.weight(kg: pr.e1RMKg, unit: .default())) one-rep max. Keep the working sets honest and that'll climb."
            }
            return "No strength PRs on the board yet. Log a few lifting sessions and I'll start tracking your estimated maxes."
        }

        // How am I doing / progress / trending
        if has(["how am i", "progress", "trend", "doing", "improv", "getting better", "fitness"]) {
            var line = ProgressNarrator.coach(i, streak: s.currentStreak)
            if let p = a?.paceTrendPct, p <= -2 {
                line += " Your easy pace at the same effort is about \(Int(abs(p)))% quicker than two months ago, so the engine's growing."
            }
            return line
        }

        // Greeting
        if has(["hi", "hey", "hello", "yo", "sup"]) && q.count < 12 {
            return "Hey, I'm your coach. I can talk through how you're trending, what to do today, recovery, or your records. What's on your mind?"
        }

        // Fallback, grounded and pointed somewhere useful
        let lead = i.hasData
            ? "Right now you're \(i.status.rawValue.lowercased()), load balance \(acwrText(i))."
            : "We're just getting started. Log a few sessions and I'll have a lot more to say."
        return "\(lead) I can help with how you're trending, what to do today, recovery, or your records. Just ask."
    }

    private static func acwrText(_ i: ProgressInsights) -> String {
        i.acwr > 0 ? String(format: "%.2f", i.acwr) : "still building"
    }

    /// Belt-and-suspenders: turn any em/en dash (the AI-slop tell) into clean sentence punctuation.
    /// Hyphens in compound words (3-day, well-absorbed) are left alone.
    static func deDash(_ s: String) -> String {
        guard s.contains("—") || s.contains("–") else { return s }
        let pieces = s.replacingOccurrences(of: "–", with: "—")
            .components(separatedBy: "—")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return pieces.enumerated().reduce("") { acc, e in
            let (idx, piece) = e
            let capped = idx == 0 ? piece : piece.prefix(1).uppercased() + piece.dropFirst()
            return idx == 0 ? capped : acc + ". " + capped
        }
    }
}
