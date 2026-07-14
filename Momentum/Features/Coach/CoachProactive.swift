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
        let messages = (try? context.fetch(FetchDescriptor<ChatMessage>())) ?? []
        if seedRaceWeek(profile: profile, messages: messages, today: today,
                        in: context, calendar: calendar) { return }
        if seedPRCelebration(profile: profile, messages: messages, today: today,
                             in: context, calendar: calendar) { return }
        if seedEarnedBump(profile: profile, workouts: workouts, messages: messages,
                          today: today, in: context, calendar: calendar) { return }
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

    // MARK: - The earned load bump (the one direction that always needs a tap)

    /// When completed load says the athlete has earned more, the offer lands in the chat as a real
    /// proposal card — not just a row buried on the Plan page.
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
}
