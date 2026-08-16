import Testing
import Foundation
import SwiftData
@testable import Momentum

/// The proactive coach: seeds at most one thought per sweep, never nags (unanswered proposals and
/// this week's recap block re-seeding), and the Monday recap anchors to the week that just closed.
/// Plus the SSE parser that carries streamed replies.
@MainActor
struct CoachProactiveTests {

    func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private let cal = Calendar.current
    private var today: Date { cal.startOfDay(for: Date()) }
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

    private func makeProfile(in ctx: ModelContext, futureSessions: Int = 2) -> UserProfile {
        let profile = UserProfile()
        let plan = TrainingPlan()
        ctx.insert(profile)
        ctx.insert(plan)
        var sessions: [PlannedSession] = []
        for i in 1...futureSessions {
            let s = PlannedSession()
            s.date = day(i * 2)
            s.discipline = .running
            s.runType = .easy
            s.status = .planned
            s.targetDistanceM = 6_000
            ctx.insert(s)
            sessions.append(s)
        }
        plan.sessions = sessions
        profile.plan = plan
        try? ctx.save()
        return profile
    }

    /// Steady completed load that reads as under-loaded → the ACWR rec is .increase.
    private func earnedLoad(in ctx: ModelContext) -> [Workout] {
        var out: [Workout] = []
        // Chronic base: 4 weeks of solid running; acute week light → ACWR < 0.8 → .increase.
        for weeksAgo in 1...4 {
            for d in 0..<3 {
                let w = Workout()
                w.type = .run
                w.startedAt = day(-(weeksAgo * 7) - d)
                w.durationS = 3_000
                let g = GPSDetail(); g.distanceM = 9_000
                w.gps = g
                ctx.insert(w)
                out.append(w)
            }
        }
        try? ctx.save()
        return out
    }

    @Test func seedsEarnedBumpOnceAndNeverNags() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)
        let workouts = earnedLoad(in: ctx)
        // The fixture must actually earn an increase or every assertion below is vacuous.
        guard ProgressInsights(workouts: workouts, now: today).recommendation == .increase else {
            Issue.record("fixture did not earn an increase — rec is \(ProgressInsights(workouts: workouts, now: today).recommendation)")
            return
        }

        CoachProactive.sweep(profile: profile, workouts: workouts, today: today, in: ctx)
        var seeded = (try? ctx.fetch(FetchDescriptor<ChatMessage>()))?.filter { $0.card?.kind == .bumpLoad } ?? []
        #expect(seeded.count == 1)
        #expect(seeded.first?.role == .coach)
        #expect(seeded.first?.cardState == .proposed)

        // Second sweep the same day: the unanswered proposal blocks a repeat.
        CoachProactive.sweep(profile: profile, workouts: workouts, today: today, in: ctx)
        seeded = (try? ctx.fetch(FetchDescriptor<ChatMessage>()))?.filter { $0.card?.kind == .bumpLoad } ?? []
        #expect(seeded.count == 1)

        // Declined → still no re-seed inside the same week.
        seeded.first?.cardState = .declined
        try? ctx.save()
        CoachProactive.sweep(profile: profile, workouts: workouts, today: today, in: ctx)
        seeded = (try? ctx.fetch(FetchDescriptor<ChatMessage>()))?.filter { $0.card?.kind == .bumpLoad } ?? []
        #expect(seeded.count == 1)
    }

    // MARK: Plan truth (the Athlete Model talks back to the plan's shape)

    private func athleteModel(for profile: UserProfile, in ctx: ModelContext) -> AthleteModel {
        let m = AthleteModel()
        ctx.insert(m)
        profile.athlete = m
        return m
    }

    @Test func lowAdherenceProposesOneFewerDay() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)
        profile.daysPerWeek = 5
        let m = athleteModel(for: profile, in: ctx)
        m.planAdherence28d = 0.4

        #expect(CoachProactive.seedPlanTruth(profile: profile, messages: [], today: today,
                                             in: ctx, calendar: cal))
        let msgs = (try? ctx.fetch(FetchDescriptor<ChatMessage>())) ?? []
        #expect(msgs.count == 1)
        #expect(msgs.first?.card?.kind == .changeDays)
        #expect(msgs.first?.card?.daysPerWeek == 4)      // one fewer, never a cliff
    }

    @Test func divergentSessionLengthProposesRightSizing() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)
        profile.sessionMinutes = 60
        profile.daysPerWeek = 3                          // adherence branch stays out of the way
        let m = athleteModel(for: profile, in: ctx)
        m.planAdherence28d = 0.9
        m.preferredSessionMinutes = 40                   // ≥25% under the plan's assumption
        m.trainingHourHistogram[18] = 10                 // ≥8 sessions of evidence

        #expect(CoachProactive.seedPlanTruth(profile: profile, messages: [], today: today,
                                             in: ctx, calendar: cal))
        let msgs = (try? ctx.fetch(FetchDescriptor<ChatMessage>())) ?? []
        #expect(msgs.first?.card?.kind == .changeSessionLength)
        #expect(msgs.first?.card?.sessionMinutes == 40)
    }

    @Test func planTruthNeverNagsAndNeedsEvidence() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)
        profile.daysPerWeek = 5
        let m = athleteModel(for: profile, in: ctx)

        // No evidence at all → quiet.
        #expect(!CoachProactive.seedPlanTruth(profile: profile, messages: [], today: today,
                                              in: ctx, calendar: cal))
        m.planAdherence28d = 0.4
        #expect(CoachProactive.seedPlanTruth(profile: profile, messages: [], today: today,
                                             in: ctx, calendar: cal))
        // The unanswered proposal (and the 28-day window) blocks a repeat.
        let msgs = (try? ctx.fetch(FetchDescriptor<ChatMessage>())) ?? []
        #expect(!CoachProactive.seedPlanTruth(profile: profile, messages: msgs, today: today,
                                              in: ctx, calendar: cal))
        #expect(msgs.count == 1)
    }

    @Test func seedsMondayRecapAfterARealWeek() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)
        // Anchor "today" to a week start so the sweep runs inside the recap window.
        let weekStart = cal.dateInterval(of: .weekOfYear, for: today)!.start

        // Last week was real: 3 workouts.
        for d in 1...3 {
            let w = Workout(); w.type = .run
            w.startedAt = cal.date(byAdding: .day, value: -d, to: weekStart)!
            w.durationS = 2_400
            ctx.insert(w)
        }
        try? ctx.save()
        let workouts = (try? ctx.fetch(FetchDescriptor<Workout>())) ?? []

        CoachProactive.sweep(profile: profile, workouts: workouts, today: weekStart, in: ctx)
        let recaps = (try? ctx.fetch(FetchDescriptor<ChatMessage>()))?.filter { $0.card?.kind == .weekRecap } ?? []
        #expect(recaps.count == 1)

        // Same week, next day: already spoken — no second recap.
        CoachProactive.sweep(profile: profile, workouts: workouts,
                             today: cal.date(byAdding: .day, value: 1, to: weekStart)!, in: ctx)
        let after = (try? ctx.fetch(FetchDescriptor<ChatMessage>()))?.filter { $0.card?.kind == .weekRecap } ?? []
        #expect(after.count == 1)
    }

    @Test func emptyLastWeekEarnsNoRecap() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)
        let weekStart = cal.dateInterval(of: .weekOfYear, for: today)!.start

        CoachProactive.sweep(profile: profile, workouts: [], today: weekStart, in: ctx)
        let recaps = (try? ctx.fetch(FetchDescriptor<ChatMessage>()))?.filter { $0.card?.kind == .weekRecap } ?? []
        #expect(recaps.isEmpty)
    }

    @Test func mondayRecapAnchorsToTheClosedWeek() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = UserProfile()
        ctx.insert(profile)
        let plan = TrainingPlan()
        ctx.insert(plan)
        profile.plan = plan
        let weekStart = cal.dateInterval(of: .weekOfYear, for: today)!.start

        // All the running happened LAST week; this week is untouched.
        let w = Workout(); w.type = .run
        w.startedAt = cal.date(byAdding: .day, value: -2, to: weekStart)!
        w.durationS = 3_000
        let g = GPSDetail(); g.distanceM = 12_000
        w.gps = g
        ctx.insert(w)
        try? ctx.save()

        let sections = CoachWeekRecap.sections(profile: profile, workouts: [w], events: [], today: weekStart)
        let volume = sections.first { $0.title == "Volume" }
        #expect(volume != nil, "a Monday ask should review the closed week, not the empty new one")
        #expect(volume?.detail.contains("7.46 mi") == true || volume?.detail.contains("12") == true)
    }

    // MARK: Week-level protective seeds (Recovery Hub §11.1.1 / §11.1.4)

    /// The last day of the current plan week — the recheck's natural firing day.
    private var weekLastDay: Date {
        cal.date(byAdding: .day, value: 6, to: cal.dateInterval(of: .weekOfYear, for: today)!.start)!
    }

    /// Four identical completed weeks → `ProgressInsights.chronic` (ACWR's weekly denominator)
    /// is a known 420: one 60-minute run per week at the default run RPE 7 (4 × 420 ÷ 4 weeks).
    private func steadyChronic(anchor: Date, in ctx: ModelContext) -> [Workout] {
        var out: [Workout] = []
        for weeksAgo in 1...4 {
            let w = Workout()
            w.type = .run
            w.startedAt = cal.date(byAdding: .day, value: -7 * weeksAgo, to: anchor)!
            w.durationS = 3_600
            ctx.insert(w)
            out.append(w)
        }
        try? ctx.save()
        return out
    }

    /// A plan whose coming week holds one duration-only run — `PlannedLoad` reads it at the
    /// default run RPE 7, so `durationS` controls the planned-vs-chronic ratio exactly.
    private func planWithRun(durationS: Double, on date: Date, in ctx: ModelContext) -> TrainingPlan {
        let plan = TrainingPlan()
        ctx.insert(plan)
        let s = PlannedSession()
        s.date = date
        s.discipline = .running
        s.runType = nil
        s.status = .planned
        s.targetDurationS = durationS
        ctx.insert(s)
        plan.sessions = [s]
        try? ctx.save()
        return plan
    }

    private func easeProposals(in ctx: ModelContext) -> [ChatMessage] {
        ((try? ctx.fetch(FetchDescriptor<ChatMessage>())) ?? []).filter { $0.card?.kind == .easeWeek }
    }

    @Test func overreachingSeedsOnceAndDedupes() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx, futureSessions: 4)   // sessions out to day(8)

        #expect(CoachProactive.seedOverreachingEase(state: .overreaching, plan: profile.plan,
                                                    today: today, in: ctx, calendar: cal))
        var eases = easeProposals(in: ctx)
        #expect(eases.count == 1)
        #expect(eases.first?.role == .coach)
        #expect(eases.first?.cardState == .proposed)   // consent-gated: proposed, never applied

        // Same day again: the unanswered proposal blocks a repeat.
        #expect(!CoachProactive.seedOverreachingEase(state: .overreaching, plan: profile.plan,
                                                     today: today, in: ctx, calendar: cal))
        // Declined → still once per trailing week.
        eases.first?.cardState = .declined
        try? ctx.save()
        #expect(!CoachProactive.seedOverreachingEase(state: .overreaching, plan: profile.plan,
                                                     today: day(2), in: ctx, calendar: cal))
        #expect(easeProposals(in: ctx).count == 1)
        // Seeds never touch the plan — lastAdaptedAt stays unarmed until the athlete taps Apply.
        #expect(profile.plan?.lastAdaptedAt == nil)

        // A full week later the window has passed — still overreaching earns a fresh ask.
        #expect(CoachProactive.seedOverreachingEase(state: .overreaching, plan: profile.plan,
                                                    today: day(7), in: ctx, calendar: cal))
        eases = easeProposals(in: ctx)
        #expect(eases.count == 2)
    }

    @Test func overreachingRequiresTheStateAndRespectsTheAdaptationGate() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)

        // Only the overreaching state seeds — every other week pattern stays quiet.
        for state in [StrainRecoveryBalance.State.building, .balanced, .detraining, .insufficient] {
            #expect(!CoachProactive.seedOverreachingEase(state: state, plan: profile.plan,
                                                         today: today, in: ctx, calendar: cal))
        }
        #expect(easeProposals(in: ctx).isEmpty)

        // Adapted 2 days ago (an autoAdapt ease, say) → never stack a proposal on it.
        profile.plan?.lastAdaptedAt = day(-2)
        try? ctx.save()
        #expect(!CoachProactive.seedOverreachingEase(state: .overreaching, plan: profile.plan,
                                                     today: today, in: ctx, calendar: cal))
        // The gate is the ≤1-change/week throttle, not a permanent mute.
        profile.plan?.lastAdaptedAt = day(-8)
        try? ctx.save()
        #expect(CoachProactive.seedOverreachingEase(state: .overreaching, plan: profile.plan,
                                                    today: today, in: ctx, calendar: cal))
    }

    @Test func plannedLoadRecheckUnderTheBarStaysQuiet() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let anchor = weekLastDay
        let workouts = steadyChronic(anchor: anchor, in: ctx)
        // The fixture must produce the chronic the ratios below assume, or the test is vacuous.
        #expect(ProgressInsights(workouts: workouts, now: anchor, calendar: cal).chronic == 420.0)

        // Next week planned at 1.2× chronic (72 min × RPE 7 = 504) — inside the safe band.
        let plan = planWithRun(durationS: 4_320, on: cal.date(byAdding: .day, value: 1, to: anchor)!, in: ctx)
        #expect(PlannedLoad.estimate(plan.sessions[0]) == 504.0)
        #expect(!CoachProactive.seedPlannedLoadRecheck(plan: plan, workouts: workouts,
                                                       today: anchor, in: ctx, calendar: cal))
        #expect(easeProposals(in: ctx).isEmpty)
    }

    @Test func plannedLoadRecheckSeedsPastTheBarAndNeverNagsAcrossTheBoundary() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let anchor = weekLastDay
        let workouts = steadyChronic(anchor: anchor, in: ctx)

        // Next week planned at 1.4× chronic (84 min × RPE 7 = 588) → one trim proposal.
        let plan = planWithRun(durationS: 5_040, on: cal.date(byAdding: .day, value: 1, to: anchor)!, in: ctx)
        #expect(PlannedLoad.estimate(plan.sessions[0]) == 588.0)
        #expect(CoachProactive.seedPlannedLoadRecheck(plan: plan, workouts: workouts,
                                                      today: anchor, in: ctx, calendar: cal))
        let eases = easeProposals(in: ctx)
        #expect(eases.count == 1)
        #expect(eases.first?.cardState == .proposed)
        #expect(eases.first?.text.contains("1.4") == true)

        // Declined on the week's last day → the first morning of the new week (the window's other
        // half) must NOT re-ask, even though the calendar week rolled over.
        eases.first?.cardState = .declined
        try? ctx.save()
        #expect(!CoachProactive.seedPlannedLoadRecheck(plan: plan, workouts: workouts,
                                                       today: cal.date(byAdding: .day, value: 1, to: anchor)!,
                                                       in: ctx, calendar: cal))
        #expect(easeProposals(in: ctx).count == 1)
    }

    @Test func plannedLoadRecheckFiresOnlyAtTheWeekBoundary() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let weekStart = cal.dateInterval(of: .weekOfYear, for: today)!.start
        let workouts = steadyChronic(anchor: weekStart, in: ctx)
        let plan = planWithRun(durationS: 5_040, on: cal.date(byAdding: .day, value: 3, to: weekStart)!, in: ctx)

        // Midweek: no recheck, however heavy the week ahead reads.
        #expect(!CoachProactive.seedPlannedLoadRecheck(plan: plan, workouts: workouts,
                                                       today: cal.date(byAdding: .day, value: 3, to: weekStart)!,
                                                       in: ctx, calendar: cal))
        #expect(easeProposals(in: ctx).isEmpty)

        // The first morning of the week looks at the week just beginning — and says so.
        #expect(CoachProactive.seedPlannedLoadRecheck(plan: plan, workouts: workouts,
                                                      today: weekStart, in: ctx, calendar: cal))
        let eases = easeProposals(in: ctx)
        #expect(eases.count == 1)
        #expect(eases.first?.text.contains("This week") == true)
    }

    @Test func plannedLoadRecheckRespectsTheAdaptationGate() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let anchor = weekLastDay
        let workouts = steadyChronic(anchor: anchor, in: ctx)
        let plan = planWithRun(durationS: 5_040, on: cal.date(byAdding: .day, value: 1, to: anchor)!, in: ctx)

        // Adapted 2 days before the boundary → the recheck never stacks on it.
        plan.lastAdaptedAt = cal.date(byAdding: .day, value: -2, to: anchor)
        try? ctx.save()
        #expect(!CoachProactive.seedPlannedLoadRecheck(plan: plan, workouts: workouts,
                                                       today: anchor, in: ctx, calendar: cal))
        #expect(easeProposals(in: ctx).isEmpty)

        // A stale adaptation (8 days back) no longer gates.
        plan.lastAdaptedAt = cal.date(byAdding: .day, value: -8, to: anchor)
        try? ctx.save()
        #expect(CoachProactive.seedPlannedLoadRecheck(plan: plan, workouts: workouts,
                                                      today: anchor, in: ctx, calendar: cal))
        #expect(easeProposals(in: ctx).count == 1)
    }

    // MARK: SSE parser (the streamed reply's transport)

    @Test func sseParserDispatchesEventDataPairs() {
        var parser = CoachChatService.SSEParser()
        #expect(parser.consume(line: "event: delta") == nil)
        let delta = parser.consume(line: #"data: {"text":"Hello"}"#)
        #expect(delta == CoachChatService.SSEEvent(name: "delta", data: #"{"text":"Hello"}"#))

        // The event name persists across data lines until the next event line.
        let second = parser.consume(line: #"data: {"text":" athlete"}"#)
        #expect(second?.name == "delta")

        #expect(parser.consume(line: "event: card") == nil)
        let card = parser.consume(line: #"data: {"kind":"easeWeek","label":"Ease this week"}"#)
        #expect(card?.name == "card")
        // Unknown/comment lines are ignored.
        #expect(parser.consume(line: ": keep-alive") == nil)
        #expect(parser.consume(line: "") == nil)
    }
}
