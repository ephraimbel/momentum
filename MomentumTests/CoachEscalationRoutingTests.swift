import Testing
import Foundation
@testable import Momentum

/// The offline-first routing gate (`CoachResponder.resolve`) that keeps the Claude API cheap: the
/// deterministic coach answers everything it confidently can (cards + grounded answers) for FREE,
/// and only questions it genuinely can't answer report `confident: false` so the app escalates them
/// to the AI. These tests pin BOTH sides of that line — the everyday questions must never escalate
/// (that's the cost win), and the out-of-scope ones must (that's the capability win).
@MainActor
struct CoachEscalationRoutingTests {

    private let cal = Calendar.current
    private func day(_ offset: Int) -> Date {
        cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date()))!.addingTimeInterval(9 * 3600)
    }
    private func session(_ dayOffset: Int, _ brief: String, durS: Double? = nil) -> CoachResponder.UpcomingSession {
        .init(id: UUID(), date: day(dayOffset), brief: brief, discipline: "running",
              status: "planned", estimatedDurationS: durS)
    }

    private func makeContext(upcoming: [CoachResponder.UpcomingSession] = [],
                             race: CoachResponder.RaceInfo? = nil,
                             feasibility: PlanFeasibility? = nil) -> CoachResponder.Context {
        CoachResponder.Context(
            insights: ProgressInsights(workouts: []),
            stats: ProfileStats(workouts: []),
            todaySession: nil,
            goal: .generalFitness,
            disciplines: ["running"],
            distanceUnit: .metric,
            athlete: nil,
            upcoming: upcoming,
            race: race,
            feasibility: feasibility,
            recovery: .empty,
            p5kSPerKm: 300,
            weekDistanceM: 0,
            prevWeekDistanceM: 0,
            lastCard: nil)
    }

    // MARK: Confident — answered offline, must NOT spend the AI

    @Test func groundedTrainingQuestionsStayOffline() {
        let ctx = makeContext(upcoming: [session(2, "16 km long run", durS: 5400)])
        // Each of these has a real grounded answer or a safe card intent → confident, no escalation.
        for q in ["how am I doing?",
                  "what should I eat before my long run",
                  "when's my long run?",
                  "am I overtraining?",
                  "what's my streak?",
                  "why is my plan built this way?",
                  "remember that I prefer trail routes"] {
            let r = CoachResponder.resolve(to: q, context: ctx)
            #expect(r.confident, "‘\(q)’ should be answered offline, not escalated")
            #expect(!r.turn.text.isEmpty)
        }
    }

    @Test func cardIntentsAreConfident() {
        let ctx = makeContext(upcoming: [session(3, "16 km long run")])
        // Plan-change intents resolve to a typed card locally — deterministic, and free.
        #expect(CoachResponder.resolve(to: "ease this week, it's too much", context: ctx).turn.card?.kind == .easeWeek)
        #expect(CoachResponder.resolve(to: "ease this week, it's too much", context: ctx).confident)
        #expect(CoachResponder.resolve(to: "switch me to 5 days a week", context: ctx).confident)
    }

    @Test func naturalEasePhrasingProposesEaseWeekNotSchedule() {
        let ctx = makeContext(upcoming: [session(1, "6 mi easy"), session(3, "13 mi long run")])
        // "ease it off" and friends are clear ease requests — they must propose easeWeek, not fall
        // through to the "this week" SCHEDULE branch (the bug: "this week is too much, ease it off"
        // was answering with the week's session list instead of offering to trim it).
        for q in ["this week is way too much, can we ease it off",
                  "can we back it off this week",
                  "everything feels overwhelming, ease off please"] {
            let r = CoachResponder.resolve(to: q, context: ctx)
            #expect(r.turn.card?.kind == .easeWeek, "‘\(q)’ should propose easeWeek, got \(String(describing: r.turn.card?.kind))")
            #expect(r.confident)
        }
    }

    @Test func namedCatalogRaceIsAnsweredOffline() {
        // A real race from our catalog resolves locally (date + a point-your-plan card) — the AI is
        // NOT needed to look up a race we already know deterministically. This is the cheap path.
        let r = CoachResponder.resolve(to: "set me up for the Chicago Marathon", context: makeContext())
        #expect(r.confident)
        #expect(r.turn.card?.kind == .changeRace)
    }

    // MARK: Not confident — genuinely out of scope, MUST escalate to the AI

    @Test func outOfScopeQuestionsEscalate() {
        let ctx = makeContext(upcoming: [session(2, "16 km long run")])
        // Genuine gaps: a race NOT in our catalog (real research), a gear question our library doesn't
        // cover, and a niche prevention question — none has a deterministic answer, so all escalate.
        for q in ["can you help me train for the Comrades Marathon",
                  "what should I look for in a running watch",
                  "how do I prevent blisters on long runs"] {
            let r = CoachResponder.resolve(to: q, context: ctx)
            #expect(!r.confident, "‘\(q)’ should escalate to the AI, not be answered offline")
            // Even so, the fallback text is always populated so the chat never blocks if the AI is down.
            #expect(!r.turn.text.isEmpty)
        }
    }

    @Test func escalationFallbackStillCarriesSafeText() {
        // When we DO escalate, resolve still returns a usable local line (tier-3 safety net) so a
        // down/unconfigured backend degrades to a grounded capability sentence, never an empty bubble.
        let r = CoachResponder.resolve(to: "what should I look for in a running watch", context: makeContext())
        #expect(!r.confident)
        #expect(r.turn.text.count > 20)
        #expect(r.turn.card == nil)
    }
}
