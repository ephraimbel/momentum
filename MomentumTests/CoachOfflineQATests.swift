import Testing
import Foundation
@testable import Momentum

/// The offline coach's grounded Q&A — schedule, fueling, readiness, feasibility, volume, skip,
/// follow-ups, and the smart fallback. Pure Context fixtures, no store needed.
@MainActor
struct CoachOfflineQATests {

    private let cal = Calendar.current
    private func day(_ offset: Int, hour: Int = 9) -> Date {
        cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date()))!
            .addingTimeInterval(Double(hour) * 3600)
    }
    private func session(_ dayOffset: Int, _ brief: String, durS: Double? = nil) -> CoachResponder.UpcomingSession {
        .init(id: UUID(), date: day(dayOffset), brief: brief, discipline: "running",
              status: "planned", estimatedDurationS: durS)
    }
    private func weekdayName(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide))
    }

    private func makeContext(upcoming: [CoachResponder.UpcomingSession] = [],
                             race: CoachResponder.RaceInfo? = nil,
                             feasibility: PlanFeasibility? = nil,
                             recovery: RecoverySignals = .empty,
                             p5k: Double? = 300,
                             weekM: Double = 0, prevWeekM: Double = 0,
                             lastCard: CoachCardPayload? = nil,
                             athlete: CoachResponder.AthleteSummary? = nil) -> CoachResponder.Context {
        CoachResponder.Context(
            insights: ProgressInsights(workouts: []),
            stats: ProfileStats(workouts: []),
            todaySession: nil,
            goal: .generalFitness,
            disciplines: ["running"],
            distanceUnit: .metric,
            athlete: athlete,
            upcoming: upcoming,
            race: race,
            feasibility: feasibility,
            recovery: recovery,
            p5kSPerKm: p5k,
            weekDistanceM: weekM,
            prevWeekDistanceM: prevWeekM,
            lastCard: lastCard)
    }

    // MARK: Schedule Q&A

    @Test func namingARaceOffersToPointThePlanAtIt() {
        // Naming a catalog race → a changeRace proposal the athlete can apply (rebuilds the season).
        let turn = CoachResponder.respond(to: "set me up for the Chicago Marathon", context: makeContext())
        #expect(turn.card?.kind == .changeRace)
        #expect(turn.card?.raceName?.isEmpty == false)
        #expect(turn.text.contains("Chicago"))

        // Wanting a race but not naming one → steer to plan settings, where "Find your race" lives.
        let browse = CoachResponder.respond(to: "help me find a race to train for", context: makeContext())
        #expect(browse.card?.kind == .nav)
        #expect(browse.card?.nav == CoachDestination.planSettings.rawValue)

        // A passing mention of a city with no race intent must NOT propose a plan change.
        let chatter = CoachResponder.respond(to: "how was my week?", context: makeContext())
        #expect(chatter.card?.kind != .changeRace)
    }

    @Test func tomorrowIsAnsweredFromTheUpcomingList() {
        let ctx = makeContext(upcoming: [session(1, "6 km easy run")])
        let turn = CoachResponder.respond(to: "What's happening tomorrow?", context: ctx)
        #expect(turn.text.contains("Tomorrow"))
        #expect(turn.text.contains("easy run"))
        // A rest day tomorrow says so and points forward.
        let rest = CoachResponder.respond(to: "anything tomorrow?",
                                          context: makeContext(upcoming: [session(3, "16 km long run")]))
        #expect(rest.text.contains("rest day"))
        #expect(rest.text.contains("long run"))
    }

    @Test func longRunAndHardSessionAreFound() {
        let long = session(5, "16 km long run", durS: 6_300)
        let ctx = makeContext(upcoming: [session(2, "intervals 6x400m"), long])
        let answer = CoachResponder.respond(to: "When's my long run?", context: ctx)
        #expect(answer.text.contains(weekdayName(long.date)))
        #expect(answer.text.contains("long run"))

        let hard = CoachResponder.respond(to: "When's my next hard session?", context: ctx)
        #expect(hard.text.contains("intervals"))
    }

    @Test func weekOverviewListsRemainingSessions() {
        // Anchor inside this calendar week only if the days fit; tomorrow always does when the
        // week has a tomorrow — keep it simple and only assert when tomorrow is still this week.
        guard let week = cal.dateInterval(of: .weekOfYear, for: Date()),
              day(1) < week.end else { return }
        let ctx = makeContext(upcoming: [session(1, "6 km easy run")])
        let turn = CoachResponder.respond(to: "What does the rest of the week look like?", context: ctx)
        #expect(turn.text.contains("easy run"))
    }

    @Test func raceDateIsAnswered() {
        let race = CoachResponder.RaceInfo(date: day(56), distanceM: 10_000, goalFinishTimeS: nil, weeksOut: 8)
        let turn = CoachResponder.respond(to: "When is my race?", context: makeContext(race: race))
        #expect(turn.text.contains("8 weeks out"))
        let none = CoachResponder.respond(to: "when's my race?", context: makeContext())
        #expect(none.text.contains("no race"))
    }

    // MARK: Skip

    @Test func skipResolvesOneSessionToACard() throws {
        let s = session(1, "6 km easy run")
        let turn = CoachResponder.respond(to: "I can't make it tomorrow", context: makeContext(upcoming: [s]))
        let card = try #require(turn.card)
        #expect(card.kind == .skipSession)
        #expect(card.sessionId == s.id.uuidString)
        #expect(turn.text.contains("No penalty"))
    }

    @Test func skipAmbiguityAsksWhichOne() {
        let ctx = makeContext(upcoming: [session(1, "6 km easy run"), session(1, "strength A")])
        let turn = CoachResponder.respond(to: "I have to miss tomorrow", context: ctx)
        #expect(turn.card == nil)
        #expect(turn.text.contains("Which one"))
    }

    // MARK: Fueling

    @Test func raceFuelingUsesPredictedDuration() {
        // 25:00 5K fitness → a marathon predicts ~4 h → the 60–90 g/hr band.
        let race = CoachResponder.RaceInfo(date: day(42), distanceM: 42_195, goalFinishTimeS: nil, weeksOut: 6)
        let turn = CoachResponder.respond(to: "What should I eat during my race?",
                                          context: makeContext(race: race))
        #expect(turn.text.contains("60 to 90"))
        #expect(!turn.text.contains("–"))   // en-dash ranges are humanized, never mangled
    }

    @Test func longRunFuelingUsesItsEstimatedDuration() {
        let ctx = makeContext(upcoming: [session(4, "16 km long run", durS: 6_300)])  // 1:45
        let turn = CoachResponder.respond(to: "What should I eat before my long run?", context: ctx)
        #expect(turn.text.contains("30 to 60"))
    }

    // MARK: Readiness

    @Test func readinessClearsTrainingWhenSignalsAreGood() {
        let good = RecoverySignals(hrvMs: 70, hrvBaselineMs: 65, restingHR: 48,
                                   restingHRBaseline: 49, sleepHours: 8)
        let turn = CoachResponder.respond(to: "I'm tired, should I still run today?",
                                          context: makeContext(recovery: good))
        #expect(turn.text.contains("cleared to train"))
        #expect(turn.text.contains("HRV"))
    }

    @Test func readinessEasesWhenTwoSignalsAgree() {
        let rough = RecoverySignals(hrvMs: 50, hrvBaselineMs: 65, restingHR: 48,
                                    restingHRBaseline: 49, sleepHours: 5.5)
        let turn = CoachResponder.respond(to: "Rough night, feeling flat. Train anyway?",
                                          context: makeContext(recovery: rough))
        #expect(turn.text.contains("your body agrees"))
        #expect(turn.text.contains("HRV below your norm"))
    }

    @Test func readinessWithoutAWearableAnswersFromLoadAndInvitesHealth() {
        let turn = CoachResponder.respond(to: "I'm exhausted, should I train?", context: makeContext())
        #expect(turn.text.contains("Apple Health"))
    }

    // MARK: Feasibility on demand

    @Test func onTrackQuestionGetsTheHonestVerdict() {
        let f = PlanFeasibility(verdict: .onTrack, weeksAvailable: 12, weeksNeeded: 8,
                                recommended: .balanced, headline: "Comfortably on track",
                                detail: "12 weeks for an 8-week build leaves honest margin.",
                                options: [], realisticFinishS: 3_000)
        let turn = CoachResponder.respond(to: "Am I on track for my race?",
                                          context: makeContext(feasibility: f))
        #expect(turn.text.contains("on track"))
        #expect(turn.text.contains("50:00"))   // the realistic finish, formatted
    }

    @Test func tooShortIsSaidPlainlyWithOptions() {
        let f = PlanFeasibility(verdict: .tooShort, weeksAvailable: 3, weeksNeeded: 10,
                                recommended: .aggressive, headline: "Not enough runway",
                                detail: "Three weeks can't safely build what this goal needs.",
                                options: ["aim for a realistic time", "pick a later race"],
                                realisticFinishS: nil)
        let turn = CoachResponder.respond(to: "Honestly, can I break 20 minutes?",
                                          context: makeContext(feasibility: f))
        #expect(turn.text.contains("not by race day"))
        #expect(turn.text.contains("later race"))
    }

    // MARK: Volume + pace trend

    @Test func weeklyVolumeComparesAgainstLastWeek() {
        let turn = CoachResponder.respond(to: "How many km have I run this week?",
                                          context: makeContext(weekM: 25_000, prevWeekM: 20_000))
        #expect(turn.text.contains("25 km"))   // distance formatter drops trailing zeros (2026-07-13)
        #expect(turn.text.contains("25% up"))
    }

    @Test func paceTrendIsToldStraight() {
        let fitter = CoachResponder.AthleteSummary(paceTrendPct: -4)
        let turn = CoachResponder.respond(to: "Am I getting faster?",
                                          context: makeContext(athlete: fitter))
        #expect(turn.text.contains("4% quicker"))
    }

    // MARK: Follow-ups + clarifying questions (the conversation keeps its thread)

    @Test func moveFollowUpRetargetsTheSameSession() throws {
        let s = session(2, "6 km easy run")
        var proposed = CoachCardPayload(kind: .moveSession, label: "Move it")
        proposed.sessionId = s.id.uuidString
        let target = day(4)
        let turn = CoachResponder.respond(to: "actually \(weekdayName(target).lowercased()) instead",
                                          context: makeContext(upcoming: [s], lastCard: proposed))
        let card = try #require(turn.card)
        #expect(card.kind == .moveSession)
        #expect(card.sessionId == s.id.uuidString)
        #expect(card.newDateISO != nil)
    }

    @Test func ambiguousMoveAsksInsteadOfChangingTheSubject() {
        // Two sessions share a weekday (7 days apart) — the coach must ask, not guess.
        let ctx = makeContext(upcoming: [session(2, "6 km easy run"), session(9, "intervals 6x400m")])
        let name = weekdayName(day(2)).lowercased()
        let turn = CoachResponder.respond(to: "can you move \(name)'s session?", context: ctx)
        #expect(turn.card == nil)
        #expect(turn.text.contains("Which one"))
    }

    // MARK: Knowledge + fallback

    @Test func knowledgeAnswersReachTheChat() {
        let turn = CoachResponder.respond(to: "What is a tempo run?", context: makeContext())
        #expect(turn.text.contains("comfortably hard"))
        #expect(turn.text.contains("/km"))   // interpolated from ctx.p5kSPerKm
    }

    @Test func fallbackNudgesTowardTheNearestCapability() {
        let turn = CoachResponder.respond(to: "my pace has been bugging me lately", context: makeContext())
        #expect(turn.text.contains("zones"))
    }

    @Test func fallbackVariesInsteadOfRepeating() {
        let a = CoachResponder.respond(to: "zzzz", context: makeContext()).text
        let b = CoachResponder.respond(to: "zzzza", context: makeContext()).text
        #expect(a != b)
    }
}
