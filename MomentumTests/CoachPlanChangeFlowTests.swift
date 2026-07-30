import Testing
import Foundation
import SwiftData
@testable import Momentum

/// The offline conversational plan-change flows: every structural change happens in the chat —
/// direct asks become proposal cards, vague asks become slot-picker cards (the coach's question),
/// and everything resolves confidently offline (the AI never runs for a plan change).
@MainActor
struct CoachPlanChangeFlowTests {

    private func makeContext(goal: Goal = .generalFitness,
                             disciplines: [String] = ["running"],
                             settings: CoachResponder.PlanSettings = .init(),
                             race: CoachResponder.RaceInfo? = nil,
                             upcoming: [CoachResponder.UpcomingSession] = []) -> CoachResponder.Context {
        CoachResponder.Context(
            insights: ProgressInsights(workouts: []),
            stats: ProfileStats(workouts: []),
            todaySession: nil,
            goal: goal,
            disciplines: disciplines,
            distanceUnit: .metric,
            upcoming: upcoming,
            race: race,
            settings: settings)
    }

    /// Every plan-change flow must resolve offline — a non-confident turn would escalate to the AI.
    private func confidentTurn(_ message: String,
                               context: CoachResponder.Context) -> CoachResponder.LocalTurn {
        let (turn, confident) = CoachResponder.resolve(to: message, context: context)
        #expect(confident, "'\(message)' escalated to the AI — plan changes must stay offline")
        return turn
    }

    // MARK: The adjust-plan menu (the coach asks what to change)

    @Test func vaguePlanChangeOpensTheMenu() {
        let turn = confidentTurn("I want to adjust my plan", context: makeContext())
        #expect(turn.card?.kind == .adjustPlan)
        // And every message a menu row sends resolves confidently to its flow.
        let ctx = makeContext(disciplines: ["running", "strength"])
        #expect(confidentTurn("Change my training days", context: ctx).card?.kind == .changeDays)
        #expect(confidentTurn("Change my goal", context: ctx).card?.kind == .changeGoal)
        #expect(confidentTurn("Change my race", context: ctx).card?.kind == .changeRace)
        #expect(confidentTurn("Change my session length", context: ctx).card?.kind == .changeSessionLength)
        #expect(confidentTurn("Start a fresh block", context: ctx).card?.kind == .renewBlock)
    }

    // MARK: Goal

    @Test func namedGoalProposesDirectly() {
        let turn = confidentTurn("I want to get stronger", context: makeContext())
        #expect(turn.card?.kind == .changeGoal)
        #expect(turn.card?.goal == Goal.getStronger.rawValue)
        // Endurance phrasing.
        let faster = confidentTurn("switch my focus to getting faster", context: makeContext())
        #expect(faster.card?.goal == Goal.endurance.rawValue)
    }

    @Test func sameGoalDeclinesGently() {
        let turn = confidentTurn("I want to get stronger", context: makeContext(goal: .getStronger))
        #expect(turn.card == nil)
        #expect(turn.text.contains("already"))
    }

    @Test func vagueGoalAsksOnTheCard() {
        let turn = confidentTurn("change my goal", context: makeContext())
        #expect(turn.card?.kind == .changeGoal)
        #expect(turn.card?.goal == nil)   // the card renders the goal picker
    }

    @Test func questionsAboutStrengthAreNotHijacked() {
        // A question, not a request — must not become a goal-change proposal.
        let turn = CoachResponder.respond(to: "will this plan make me stronger?", context: makeContext())
        #expect(turn.card?.kind != .changeGoal)
    }

    // MARK: Race (non-catalog, in-chat)

    @Test func raceDistanceOpensTheDateSlot() {
        let turn = confidentTurn("I want to run a marathon", context: makeContext())
        #expect(turn.card?.kind == .changeRace)
        #expect(turn.card?.raceDistanceM == 42_195)
        #expect(turn.card?.raceDateISO == nil)   // the card renders the date picker
    }

    @Test func relativeDateParsesInline() {
        let turn = confidentTurn("I want to run a half marathon in 12 weeks", context: makeContext())
        #expect(turn.card?.kind == .changeRace)
        #expect(turn.card?.raceDistanceM == 21_097.5)
        #expect(turn.card?.raceDateISO != nil)
    }

    @Test func vagueRaceAsksForDistance() {
        let turn = confidentTurn("change my race", context: makeContext())
        #expect(turn.card?.kind == .changeRace)
        #expect(turn.card?.raceDistanceM == nil)   // the card renders the distance picker first
    }

    @Test func raceQuestionsAreNotHijacked() {
        // Questions about a race must stay questions.
        let prep = CoachResponder.respond(to: "how should I prep for the marathon?", context: makeContext())
        #expect(prep.card?.kind != .changeRace)
        let ready = CoachResponder.respond(to: "am I ready for a half marathon?", context: makeContext())
        #expect(ready.card?.kind != .changeRace)
    }

    // MARK: Session length

    @Test func explicitMinutesProposeDirectly() {
        let turn = confidentTurn("make my sessions 30 minutes", context: makeContext())
        #expect(turn.card?.kind == .changeSessionLength)
        #expect(turn.card?.sessionMinutes == 30)
    }

    @Test func shorterStepsDownFromCurrent() {
        let turn = confidentTurn("my sessions are too long", context: makeContext())   // default 45
        #expect(turn.card?.kind == .changeSessionLength)
        #expect(turn.card?.sessionMinutes == 30)
    }

    @Test func vagueLengthAsksOnTheCard() {
        let turn = confidentTurn("change my session length", context: makeContext())
        #expect(turn.card?.kind == .changeSessionLength)
        #expect(turn.card?.sessionMinutes == nil)   // the card renders the minutes picker
    }

    @Test func pastTenseWorkoutReportIsNotHijacked() {
        let turn = CoachResponder.respond(to: "my last workout was 60 minutes", context: makeContext())
        #expect(turn.card?.kind != .changeSessionLength)
    }

    // MARK: Preferred days

    @Test func namedWeekdaysAnchorTheWeek() {
        let turn = confidentTurn("train on monday, wednesday and friday", context: makeContext())
        #expect(turn.card?.kind == .changeDays)
        #expect(turn.card?.preferredDays == [2, 4, 6])   // Gregorian: Sun = 1
        #expect(turn.card?.daysPerWeek == nil)           // count untouched — schedule, not volume
    }

    @Test func switchingDaysIsNotMisreadAsAMove() {
        // Two weekday names + "switch" used to satisfy the move matcher. The days phrasing wins.
        let upcoming = [CoachResponder.UpcomingSession(
            id: UUID(), date: Date().addingTimeInterval(86_400), brief: "6 km easy run",
            discipline: "running", status: "planned")]
        let turn = confidentTurn("switch my days to tuesday and thursday",
                                 context: makeContext(upcoming: upcoming))
        #expect(turn.card?.kind == .changeDays)
        #expect(turn.card?.preferredDays == [3, 5])
    }

    // MARK: Equipment

    @Test func equipmentChangeProposesDirectly() {
        let ctx = makeContext(disciplines: ["running", "strength"])   // default equipment: full gym
        let turn = confidentTurn("I only have dumbbells now", context: ctx)
        #expect(turn.card?.kind == .changeEquipment)
        #expect(turn.card?.equipment == Equipment.dumbbellsOnly.rawValue)
    }

    @Test func runnersWithoutStrengthDontGetEquipmentCards() {
        let turn = CoachResponder.respond(to: "I only have dumbbells now",
                                          context: makeContext(disciplines: ["running"]))
        #expect(turn.card?.kind != .changeEquipment)
    }

    // MARK: Fresh block / renewal

    @Test func freshBlockProposesRenewal() {
        let rolling = confidentTurn("let's start over with a new plan", context: makeContext())
        #expect(rolling.card?.kind == .renewBlock)
        // With a race set, the same ask rebuilds toward the race — the text says so honestly.
        let race = CoachResponder.RaceInfo(date: Date().addingTimeInterval(60 * 86_400),
                                           distanceM: 42_195, goalFinishTimeS: nil, weeksOut: 8)
        let toward = confidentTurn("start fresh", context: makeContext(race: race))
        #expect(toward.card?.kind == .renewBlock)
        #expect(toward.text.contains("race"))
    }

    // MARK: Bridge — the new kinds

    @Test func bridgeValidatesRenewBlockAndDropsAdjustPlan() {
        let snapshot = CoachIntentBridge.Snapshot(today: Date())
        #expect(CoachIntentBridge.validate(CoachCardPayload(kind: .renewBlock, label: "Next block"),
                                           snapshot: snapshot) == .renewBlock)
        // The menu card never validates to an executable intent — it can't reach the apply path.
        #expect(CoachIntentBridge.validate(CoachCardPayload(kind: .adjustPlan, label: "Menu"),
                                           snapshot: snapshot) == nil)
    }

    // MARK: Apply — renewBlock lands on real stores

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func makeProfile(in ctx: ModelContext, raceDate: Date? = nil) -> UserProfile {
        let profile = UserProfile()
        profile.disciplines = [Discipline.running.rawValue]
        profile.goal = raceDate == nil ? .generalFitness : .raceDistance
        profile.daysPerWeek = 4
        profile.raceDate = raceDate
        if raceDate != nil { profile.raceDistanceM = 42_195 }
        ctx.insert(profile)
        PlanService.rebuild(for: profile, in: ctx)
        return profile
    }

    @Test func renewBlockAdvancesARollingPlan() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)
        #expect(profile.plan?.blockIndex == 0)

        let outcome = CoachActions.apply(.renewBlock, profile: profile, workouts: [], in: ctx)
        guard case .applied(let receipt) = outcome else {
            Issue.record("renewBlock should apply on a rolling plan"); return
        }
        #expect(profile.plan?.blockIndex == 1)
        #expect(receipt.headline.contains("Block 2"))
    }

    @Test func strengthGoalFromChatAddsStrengthWork() throws {
        // A pure runner tells the coach "get stronger" → the rebuild must add strength sessions,
        // not produce a run-only plan pointed at a barbell.
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)   // running only
        let outcome = CoachActions.apply(.changeGoal(.getStronger), profile: profile, workouts: [], in: ctx)
        guard case .applied = outcome else { Issue.record("changeGoal should apply"); return }
        #expect(profile.disciplines.contains(Discipline.strength.rawValue))
        #expect(profile.plan?.sessions.contains { $0.discipline == .strength } == true)
    }

    @Test func renewBlockRebuildsTowardARace() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let race = Calendar.current.date(byAdding: .weekOfYear, value: 10, to: Date())!
        let profile = makeProfile(in: ctx, raceDate: race)

        let outcome = CoachActions.apply(.renewBlock, profile: profile, workouts: [], in: ctx)
        guard case .applied(let receipt) = outcome else {
            Issue.record("renewBlock should apply on a race plan"); return
        }
        #expect(profile.plan?.blockIndex == 0)         // races don't run in blocks
        #expect(profile.raceDate == race)              // still pointed at the race
        #expect(receipt.detail.contains("race"))
    }
}
