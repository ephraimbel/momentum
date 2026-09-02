import Foundation
import SwiftData

/// The coach that was already thinking about you. Runs inside Today's daily coaching pass and seeds
/// at most ONE new thought into the chat thread per sweep, badged on the Today coach button and
/// mirrored to the bell inbox. Strictly deduped — a proposal the athlete hasn't answered is never
/// repeated, and each kind fires at most once per its natural cadence. Deterministic triggers only;
/// consent rules are unchanged (a seeded proposal is still propose → preview → Apply).
@MainActor
enum CoachProactive {

    /// One pass. Called from Today's bootstrap (same cadence as the other coaching passes).
    /// Priority order: race week (time-critical) → PR celebration (emotional, day-of) →
    /// earned bump → Monday recap. One seed per sweep — the coach starts one conversation, not four.
    static func sweep(profile: UserProfile?, workouts: [Workout], today: Date = Date(),
                      in context: ModelContext, calendar: Calendar = .current) {
        guard let profile else { return }
        #if DEBUG
        // `--coach-card` seeds ONE specific proposal so the card + Apply flow can be verified.
        // A proactive card inserted afterwards becomes the newest message, the thread scrolls to
        // it, and the seeded proposal is left unrendered off-screen — so the card the launch arg
        // exists to show is invisible to a UI test. `CoachDemo.seedProposalIfNeeded` already
        // clears thread state that would "block or bury the verification card", but it runs
        // BEFORE this sweep and so cannot see what this adds.
        //
        // This was date-dependent and therefore invisible most of the week: the weekly recap only
        // fires in the first two days of a week (`daysIn < 2`), so the suite passed on Thursday
        // 2026-08-27 and failed on Sunday 2026-08-30 with no code change in between.
        if ProcessInfo.processInfo.arguments.contains("--coach-card") { return }
        #endif
        let messages = (try? context.fetch(FetchDescriptor<ChatMessage>())) ?? []
        if seedRaceWeek(profile: profile, messages: messages, today: today,
                        in: context, calendar: calendar) { return }
        if seedPRCelebration(profile: profile, messages: messages, today: today,
                             in: context, calendar: calendar) { return }
        if seedEarnedBump(profile: profile, workouts: workouts, messages: messages,
                          today: today, in: context, calendar: calendar) { return }
        if seedPlanTruth(profile: profile, messages: messages, today: today,
                         in: context, calendar: calendar) { return }
        seedWeekRecap(profile: profile, workouts: workouts, messages: messages,
                      today: today, in: context, calendar: calendar)
    }

    // MARK: - The first hello (once, the moment onboarding builds a plan)

    /// Seed the coach's introduction right after onboarding: the personalized plan explainer,
    /// offered at the moment of peak curiosity. Silent — the unseen dot on Today's coach button
    /// does the inviting; nothing pops over the reveal. Once ever (an explainPlan card in the
    /// thread, in any state, means the introduction already happened).
    @discardableResult
    static func seedPlanIntro(in context: ModelContext) -> Bool {
        let messages = (try? context.fetch(FetchDescriptor<ChatMessage>())) ?? []
        guard !messages.contains(where: { $0.card?.kind == .explainPlan }) else { return false }
        let card = CoachCardPayload(kind: .explainPlan, label: "Your plan, explained")
        context.insert(ChatMessage(role: .coach,
            text: "Your plan is ready, and I built it around you: your fitness, your schedule, your goal. Want the tour of why each week looks the way it does?",
            card: card))
        try? context.save()
        return true
    }

    // MARK: - Race week (final 3 days — the plan card lands in the chat, not just the bell)

    @discardableResult
    private static func seedRaceWeek(profile: UserProfile, messages: [ChatMessage], today: Date,
                                     in context: ModelContext, calendar: Calendar) -> Bool {
        guard let raceDate = profile.raceDate,
              let distanceM = profile.raceDistanceM, distanceM > 0,
              let p5k = profile.plan?.p5kSPerKm, p5k > 0,
              let daysOut = calendar.dateComponents([.day], from: calendar.startOfDay(for: today),
                                                    to: calendar.startOfDay(for: raceDate)).day,
              let briefing = RaceBriefing.build(distanceM: distanceM, p5kSPerKm: p5k, daysOut: daysOut)
        else { return false }
        // Once per day through race week — each day's briefing is different.
        guard !messages.contains(where: {
            $0.card?.kind == .racePlan && calendar.isDate($0.createdAt, inSameDayAs: today)
        }) else { return false }

        let card = CoachCardPayload(kind: .racePlan, label: "Your race plan")
        context.insert(ChatMessage(role: .coach,
            text: CoachResponder.deDash("\(briefing.title). \(briefing.body)"),
            card: card))
        try? context.save()
        AppNotification.post(kind: .coaching, title: briefing.title,
                             body: "Your race plan is waiting in the coach chat.",
                             on: today, in: context, dedupeToken: "coach-proactive-race-\(daysOut)", daily: false)
        return true
    }

    // MARK: - PR celebration (the coach says it first)

    @discardableResult
    private static func seedPRCelebration(profile: UserProfile, messages: [ChatMessage], today: Date,
                                          in context: ModelContext, calendar: Calendar) -> Bool {
        let todaysPRs = profile.prs.filter { calendar.isDate($0.achievedAt, inSameDayAs: today) }
        guard !todaysPRs.isEmpty else { return false }
        // One celebration per day, however many records fell.
        guard !messages.contains(where: {
            $0.card?.nav == CoachDestination.viewProgress.rawValue
            && calendar.isDate($0.createdAt, inSameDayAs: today)
        }) else { return false }

        let count = todaysPRs.count
        var card = CoachCardPayload(kind: .nav, label: "See your records")
        card.nav = CoachDestination.viewProgress.rawValue
        context.insert(ChatMessage(role: .coach,
            text: count == 1
                ? "That was a personal record. Not luck, not a fluke, just the training landing exactly where we aimed it. Take the win."
                : "\(count) personal records in one day. The block is working and today proved it. Take the win.",
            card: card))
        try? context.save()
        AppNotification.post(kind: .achievement, title: count == 1 ? "Personal record" : "\(count) personal records",
                             body: "Your coach has thoughts. All of them are proud.",
                             on: today, in: context, dedupeToken: "coach-proactive-pr")
        return true
    }

    // MARK: - The reviewed load bump (the one direction that always needs a tap)

    /// When completed load is lighter than the recent pattern, a conditional review lands in chat as
    /// a real proposal card. The ratio never claims the athlete has "earned" or is cleared for more.
    @discardableResult
    private static func seedEarnedBump(profile: UserProfile, workouts: [Workout],
                                       messages: [ChatMessage], today: Date,
                                       in context: ModelContext, calendar: Calendar) -> Bool {
        guard let proposal = PlanCoaching.proposeAdjustment(profile.plan, workouts: workouts,
                                                            today: today, calendar: calendar) else { return false }
        // Never nag: skip while an unanswered bump sits in the thread, or one was seeded this week.
        let existing = messages.filter { $0.card?.kind == .bumpLoad }
        guard !existing.contains(where: { $0.cardState == .proposed }),
              !existing.contains(where: { calendar.isDate($0.createdAt, equalTo: today, toGranularity: .weekOfYear) })
        else { return false }

        let card = CoachCardPayload(kind: .bumpLoad, label: "Raise ~10%")
        context.insert(ChatMessage(role: .coach,
            text: CoachResponder.deDash("\(proposal.headline). \(proposal.detail)"),
            card: card))
        try? context.save()
        AppNotification.post(kind: .coaching, title: proposal.headline,
                             body: "Your coach has a proposal waiting. It's your call.",
                             on: today, in: context, dedupeToken: "coach-proactive-bump")
        return true
    }

    // MARK: - Plan truth (enterprise pass 2026-08-15 — the Athlete Model talks back to the plan)

    /// When the Athlete Model's evidence says the plan's SHAPE doesn't fit the athlete's real life,
    /// the coach says so — once, gently, with a real Apply-able proposal card (the same
    /// propose → preview → Apply grammar as every other change; nothing auto-applies).
    /// Two truths, strongest first:
    ///  • adherence: landing under 60% of planned sessions over 28 days on a ≥4-day week is a fit
    ///    problem, not a willpower problem — propose one fewer day (`.changeDays`);
    ///  • session length: completed sessions habitually diverging ≥25% from the plan's assumed
    ///    minutes (≥8 sessions of evidence) — propose right-sizing (`.changeSessionLength`).
    /// Deduped to one plan-truth conversation per 28 days — reshaping is a considered ask.
    @discardableResult
    static func seedPlanTruth(profile: UserProfile, messages: [ChatMessage], today: Date,
                              in context: ModelContext, calendar: Calendar) -> Bool {
        guard let plan = profile.plan, !plan.isSelfCoached,
              let athlete = profile.athlete else { return false }
        let truthKinds: Set<CoachCardPayload.Kind> = [.changeDays, .changeSessionLength]
        let existing = messages.filter { ($0.card?.kind).map(truthKinds.contains) ?? false }
        guard !existing.contains(where: { $0.cardState == .proposed }),
              !existing.contains(where: {
                  (calendar.dateComponents([.day], from: calendar.startOfDay(for: $0.createdAt),
                                           to: calendar.startOfDay(for: today)).day ?? .max) < 28
              })
        else { return false }

        let sessions = athlete.trainingHourHistogram.reduce(0, +)
        if athlete.planAdherence28d > 0, athlete.planAdherence28d < 0.6, profile.daysPerWeek >= 4 {
            let fewer = profile.daysPerWeek - 1
            let pct = Int((athlete.planAdherence28d * 100).rounded())
            var card = CoachCardPayload(kind: .changeDays, label: "Drop to \(fewer) days")
            card.daysPerWeek = fewer
            context.insert(ChatMessage(role: .coach,
                text: CoachResponder.deDash("You've landed about \(pct)% of your planned sessions this month. That's a fit problem, not a willpower problem: a \(fewer)-day week you hit beats a \(profile.daysPerWeek)-day week you don't. Want me to reshape it?"),
                createdAt: today, card: card))
        } else if sessions >= 8, athlete.preferredSessionMinutes > 0, profile.sessionMinutes > 0,
                  abs(athlete.preferredSessionMinutes - Double(profile.sessionMinutes))
                      / Double(profile.sessionMinutes) >= 0.25 {
            let actual = min(120, max(20, Int(athlete.preferredSessionMinutes)))
            var card = CoachCardPayload(kind: .changeSessionLength, label: "Right-size to \(actual) min")
            card.sessionMinutes = actual
            context.insert(ChatMessage(role: .coach,
                text: CoachResponder.deDash("Your sessions actually run about \(actual) minutes; the plan assumes \(profile.sessionMinutes). Want me to build around your real \(actual)?"),
                createdAt: today, card: card))
        } else {
            return false
        }
        try? context.save()
        AppNotification.post(kind: .coaching, title: "Your plan could fit you better",
                             body: "Your coach noticed a pattern. The reshape is your call.",
                             on: today, in: context, dedupeToken: "coach-proactive-plan-truth")
        return true
    }

    // MARK: - The Monday recap

    /// First days of a fresh week, with a real week behind you → the review is waiting in the chat.
    @discardableResult
    private static func seedWeekRecap(profile: UserProfile, workouts: [Workout],
                                      messages: [ChatMessage], today: Date,
                                      in context: ModelContext, calendar: Calendar) -> Bool {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: today),
              let daysIn = calendar.dateComponents([.day], from: week.start, to: today).day,
              daysIn < 2 else { return false }
        // The closed week must have been a real one (≥2 workouts) to earn a review.
        guard let lastWeek = calendar.dateInterval(of: .weekOfYear, for: week.start.addingTimeInterval(-1)),
              workouts.filter({ $0.startedAt >= lastWeek.start && $0.startedAt < lastWeek.end }).count >= 2
        else { return false }
        // Once per week, ever — an existing recap card inside this week means we already spoke.
        guard !messages.contains(where: {
            $0.card?.kind == .weekRecap
            && calendar.isDate($0.createdAt, equalTo: today, toGranularity: .weekOfYear)
        }) else { return false }

        let card = CoachCardPayload(kind: .weekRecap, label: "Your week")
        context.insert(ChatMessage(role: .coach,
            text: "Your week's in the books. Here's how it actually went, and what's ahead.",
            card: card))
        try? context.save()
        AppNotification.post(kind: .coaching, title: "Your week, reviewed",
                             body: "The recap is waiting in your coach chat.",
                             on: today, in: context, dedupeToken: "coach-proactive-recap")
        return true
    }

    // MARK: - Week-level protective proposals (Recovery Hub §11.1.1 / §11.1.4)
    //
    // INTEGRATION: not yet wired — the orchestrator adds one line each to Today's daily coaching
    // pass (alongside `sweep`, which keeps its own one-seed-per-sweep priority chain):
    //     CoachProactive.seedOverreachingEase(state: balance.state, plan: profile.plan, in: context)
    //     CoachProactive.seedPlannedLoadRecheck(plan: profile.plan, workouts: workouts, in: context)
    // Both are SEEDS ONLY: consent-gated `.easeWeek` proposal cards (propose → preview → Apply via
    // `CoachActions`, which re-runs the `lastAdaptedAt` throttle at tap time) — they never touch
    // the plan themselves. They share one `.easeWeek` dedupe, so at most one week-level ease
    // proposal exists per trailing 7 days; call order decides priority (overreaching first — the
    // body's signal outranks the calendar's).

    /// §11.1.4 — a week of poor recovery at *normal* load (`StrainRecoveryBalance.state ==
    /// .overreaching`) trips no existing trigger: the only week-level guard is completed-load ACWR,
    /// which normal load never moves. Seed ONE consent-gated ease proposal so the signature chart
    /// informs a real decision. Never auto-applies; never stacks on an adaptation
    /// (`plan.lastAdaptedAt` < 7 days blocks, mirroring `PlanCoaching.autoAdapt`'s gate).
    @discardableResult
    static func seedOverreachingEase(state: StrainRecoveryBalance.State, plan: TrainingPlan?,
                                     today: Date = Date(), in context: ModelContext,
                                     calendar: Calendar = .current) -> Bool {
        guard state == .overreaching, let plan else { return false }
        if let last = plan.lastAdaptedAt,
           (calendar.dateComponents([.day], from: last, to: today).day ?? .max) < 7 { return false }
        // Something upcoming must exist to ease, or Apply could only decline.
        let todayStart = calendar.startOfDay(for: today)
        guard plan.sessions.contains(where: {
            $0.status == .planned && $0.completedWorkout == nil
            && calendar.startOfDay(for: $0.date) >= todayStart
        }) else { return false }
        let messages = (try? context.fetch(FetchDescriptor<ChatMessage>())) ?? []
        guard !easeProposalSeededRecently(messages, today: today, calendar: calendar) else { return false }

        let card = CoachCardPayload(kind: .easeWeek, label: "Ease this week")
        context.insert(ChatMessage(role: .coach,
            text: CoachResponder.deDash("A week of low recovery against a normal load. Worth easing before it costs you."),
            createdAt: today, card: card))
        try? context.save()
        AppNotification.post(kind: .coaching, title: "Worth easing this week",
                             body: "Your coach has a proposal waiting. It's your call.",
                             on: today, in: context, dedupeToken: "coach-proactive-overreach")
        return true
    }

    /// §11.1.1 — the pre-week planned-vs-actual ACWR recheck. `ACWRGovernor` runs only at
    /// generation against *planned* history, so after misses/pauses the coming week can quietly
    /// exceed 1.3× the athlete's actual chronic. On a plan week's closing day (or the first
    /// morning of the next), sum the coming week's `PlannedLoad` estimates against
    /// `ProgressInsights.chronic` — chronic is already the weekly currency (the 28-day load ÷
    /// weeks of history, ACWR's denominator), so the planned week compares to it directly —
    /// and above 1.3 seed ONE consent-gated trim proposal. Seeds only; never auto-applies.
    @discardableResult
    static func seedPlannedLoadRecheck(plan: TrainingPlan?, workouts: [Workout],
                                       today: Date = Date(), in context: ModelContext,
                                       calendar: Calendar = .current) -> Bool {
        guard let plan else { return false }
        if let last = plan.lastAdaptedAt,
           (calendar.dateComponents([.day], from: last, to: today).day ?? .max) < 7 { return false }

        // The two-day recheck window: a week's last day looks at next week; the first morning of
        // a fresh week looks at the week just beginning (still almost entirely ahead of you).
        let todayStart = calendar.startOfDay(for: today)
        guard let week = calendar.dateInterval(of: .weekOfYear, for: todayStart),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart) else { return false }
        let comingWeek: DateInterval
        if todayStart == week.start {
            comingWeek = week
        } else if tomorrow >= week.end {
            guard let next = calendar.dateInterval(of: .weekOfYear, for: week.end) else { return false }
            comingWeek = next
        } else {
            return false
        }

        // The coming week's prescription, spoken in the completed-load currency (`PlannedLoad`
        // is the planned twin of `TrainingLoad.session`, same Foster minutes × RPE).
        let planned = plan.sessions
            .filter { $0.completedWorkout == nil && $0.status != .completed
                      && $0.date >= comingWeek.start && $0.date < comingWeek.end }
            .reduce(0) { $0 + PlannedLoad.estimate($1) }
        guard planned > 0 else { return false }

        // chronic < 1 means no real history (`ProgressInsights` reads .starting) — a ratio
        // against nothing is noise, never a proposal.
        let chronic = ProgressInsights(workouts: workouts, now: today, calendar: calendar).chronic
        guard chronic >= 1 else { return false }
        let ratio = planned / chronic
        guard ratio > 1.3 else { return false }

        let messages = (try? context.fetch(FetchDescriptor<ChatMessage>())) ?? []
        guard !easeProposalSeededRecently(messages, today: today, calendar: calendar) else { return false }

        let weekWord = todayStart == comingWeek.start ? "This week" : "Next week"
        let card = CoachCardPayload(kind: .easeWeek, label: "Trim ~15%")
        context.insert(ChatMessage(role: .coach,
            text: CoachResponder.deDash("\(weekWord) is planned at ~\(String(format: "%.1f", ratio))× what you've actually been doing . Want me to trim it to fit?"),
            createdAt: today, card: card))
        try? context.save()
        AppNotification.post(kind: .coaching, title: "\(weekWord) is planned heavy",
                             body: "Your coach has a proposal waiting. It's your call.",
                             on: today, in: context, dedupeToken: "coach-proactive-load-recheck")
        return true
    }

    /// Shared never-nag guard for the week-level `.easeWeek` seeds: an unanswered ease proposal,
    /// or ANY ease proposal inside the trailing 7 days, blocks a new one. A sliding window rather
    /// than `seedEarnedBump`'s calendar-week check, because the recheck fires exactly on the
    /// week boundary — a calendar-week dedupe would re-nag the morning after a decline.
    private static func easeProposalSeededRecently(_ messages: [ChatMessage], today: Date,
                                                   calendar: Calendar) -> Bool {
        messages.contains { m in
            guard m.card?.kind == .easeWeek else { return false }
            if m.cardState == .proposed { return true }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: m.createdAt),
                                               to: calendar.startOfDay(for: today)).day ?? .max
            return days < 7
        }
    }
}
