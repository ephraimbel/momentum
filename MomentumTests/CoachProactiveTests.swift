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
