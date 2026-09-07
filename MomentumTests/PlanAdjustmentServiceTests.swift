import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Manage plan's action layer (2026-09-07): one engine behind every adjustment, a proposal that
/// names what it touches, throttles explained before the tap, a stale proposal recomputed rather
/// than applied, and an undo that puts the plan back.
@MainActor
struct PlanAdjustmentServiceTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private final class NotificationSpy: NotificationServing {
        var scheduled = 0
        func requestAuthorization(completion: ((Bool) -> Void)?) { completion?(true) }
        func schedulePlannedReminders(_ plan: TrainingPlan?) { scheduled += 1 }
        func scheduleWeeklyCheckIn() {}
        func scheduleStreakNudge(streak: Int, isPlannedDayToday: Bool, hasWorkedOutToday: Bool) {}
    }

    private let cal = Calendar.current
    private var today: Date { cal.date(bySettingHour: 10, minute: 0, second: 0, of: cal.startOfDay(for: Date()))! }
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

    private func makeProfile(in ctx: ModelContext, race: Bool = false) -> UserProfile {
        let profile = UserProfile()
        profile.disciplines = [Discipline.running.rawValue]
        profile.goal = race ? .raceDistance : .generalFitness
        profile.daysPerWeek = 4
        profile.weeklyRunVolumeM = 30_000
        profile.longestRunM = 12_000
        profile.experience = [Discipline.running.rawValue: ExperienceLevel.some.rawValue]
        if race { profile.raceDistanceM = RaceDistance.half.meters; profile.raceDate = day(7 * 12) }
        ctx.insert(profile)
        try? ctx.save()
        PlanService.regenerate(for: profile, startDate: day(-3), in: ctx)
        return profile
    }

    @Test func aProposalNamesWhatItTouchesAndHowTheWeekMoves() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let p = PlanAdjustmentService.proposal(.changeDays(daysPerWeek: 5, preferredDays: nil), title: "Days",
                                               request: "5 days", profile: profile, workouts: [], today: today, in: ctx)
        #expect(p.isAvailable)
        let affected = try #require(p.affected)
        #expect(affected.sessions > 0)
        #expect(affected.from >= cal.startOfDay(for: today))
        #expect(p.lines.contains { $0.hasPrefix("Training days: 4 → 5") })
        #expect(p.lines.contains { $0.hasPrefix("Runs a week:") })
        #expect(!p.explanation.isEmpty)
        #expect(p.signature == PlanAdjustmentService.signature(of: profile.plan))
    }

    @Test func theThrottleIsExplainedBeforeTheTapAndEnforcedOnApply() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let plan = try #require(profile.plan)
        plan.lastAdaptedAt = day(-2)
        try ctx.save()
        let p = PlanAdjustmentService.proposal(.easeWeek, title: "Ease", request: "lighter", profile: profile,
                                               workouts: [], today: today, in: ctx)
        #expect(!p.isAvailable)
        #expect(p.blocked?.contains("One structural change a week") == true)
        let spy = NotificationSpy()
        switch PlanAdjustmentService.apply(p, profile: profile, workouts: [], notifications: spy, today: today, in: ctx) {
        case .declined(let reason): #expect(reason.contains("One structural change a week"))
        default: Issue.record("a throttled ease must be declined")
        }
        #expect(spy.scheduled == 0)
    }

    @Test func aStaleProposalIsRecomputedNotApplied() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let p = PlanAdjustmentService.proposal(.easeWeek, title: "Ease", request: "lighter", profile: profile,
                                               workouts: [], today: today, in: ctx)
        // The plan changes underneath: a session moves a day.
        let plan = try #require(profile.plan)
        let open = try #require(plan.sessions.filter { $0.status == .planned && $0.date > today }.first)
        open.date = cal.date(byAdding: .day, value: 1, to: open.date)!
        try ctx.save()
        let before = plan.sessions.map(\.targetDistanceM)
        let spy = NotificationSpy()
        switch PlanAdjustmentService.apply(p, profile: profile, workouts: [], notifications: spy, today: today, in: ctx) {
        case .stale(let fresh):
            #expect(fresh.signature != p.signature)
            #expect(fresh.intent == p.intent)
        default: Issue.record("a proposal against a changed plan must be recomputed")
        }
        #expect(plan.sessions.map(\.targetDistanceM) == before)
        #expect(plan.lastAdaptedAt == nil)
        #expect(spy.scheduled == 0)
    }

    @Test func applyThenUndoPutsThePlanBackIncludingTheWeeklyBudget() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let plan = try #require(profile.plan)
        let distancesBefore = plan.sessions.sorted { $0.date < $1.date }.map { $0.targetDistanceM ?? 0 }
        let p = PlanAdjustmentService.proposal(.easeWeek, title: "Ease", request: "lighter", profile: profile,
                                               workouts: [], today: today, in: ctx)
        #expect(p.isAvailable)
        let spy = NotificationSpy()
        guard case .applied(let receipt, let undo) = PlanAdjustmentService.apply(
            p, profile: profile, workouts: [], notifications: spy, today: today, in: ctx) else {
            Issue.record("ease must apply on a fresh plan"); return
        }
        #expect(receipt.headline == "Rest of the plan eased")
        #expect(spy.scheduled == 1)
        #expect(profile.plan?.lastAdaptedAt != nil)
        let eased = try #require(profile.plan).sessions.sorted { $0.date < $1.date }.map { $0.targetDistanceM ?? 0 }
        #expect(eased != distancesBefore)
        // A second ease is now throttled.
        let again = PlanAdjustmentService.proposal(.easeWeek, title: "Ease", request: "lighter", profile: profile,
                                                   workouts: [], today: today, in: ctx)
        #expect(!again.isAvailable)

        #expect(PlanAdjustmentService.undo(try #require(undo), profile: profile, workouts: [], notifications: spy, in: ctx))
        let restored = try #require(profile.plan).sessions.sorted { $0.date < $1.date }.map { $0.targetDistanceM ?? 0 }
        #expect(restored == distancesBefore)
        #expect(profile.plan?.lastAdaptedAt == nil)
        #expect(spy.scheduled == 2)
    }

    @Test func aRaceOutlookChangeIsNamedWhenTheVerdictMoves() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx, race: true)
        // Moving the race to two weeks out for a half at 30 km/week moves the verdict.
        let soon = day(14)
        let p = PlanAdjustmentService.proposal(.changeRace(distanceM: RaceDistance.half.meters, date: soon, goalFinishTimeS: nil),
                                               title: "Race", request: "sooner", profile: profile, workouts: [],
                                               today: today, in: ctx)
        #expect(p.outlookChange?.hasPrefix("Outlook:") == true)
    }

    @Test func aSelfCoachedPlanStillAllowsScheduleEditsButNotReshaping() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let plan = try #require(profile.plan)
        plan.isSelfCoached = true
        try ctx.save()
        let ease = PlanAdjustmentService.proposal(.easeWeek, title: "Ease", request: "lighter", profile: profile,
                                                  workouts: [], today: today, in: ctx)
        #expect(!ease.isAvailable)
        let session = try #require(plan.sessions.first { $0.status == .planned && $0.date > today })
        let move = PlanAdjustmentService.proposal(.moveSession(id: session.id, to: day(5)), title: "Move",
                                                  request: "move", profile: profile, workouts: [], today: today, in: ctx)
        #expect(move.isAvailable)
        #expect(move.affected?.sessions == 1)
    }

    @Test func pauseShowsWhereTheFirstSessionsLand() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let p = PlanAdjustmentService.proposal(.pausePlan(days: 3), title: "Pause", request: "3 days",
                                               profile: profile, workouts: [], today: today, in: ctx)
        #expect(p.isAvailable)
        #expect(p.lines.contains { $0.contains("→") })
        #expect(p.affected?.sessions ?? 0 > 0)
    }

    // MARK: - Regression pass (2026-09-07)
    // The seven-day ease, race day under a pause, an expired pause, undo identity, the sole undo
    // point, the latches across a rebuild, a move onto an occupied day, a proposal gone stale.

    /// A session's adjustable shape, for before/after comparisons across a whole plan.
    private struct Shape: Equatable {
        let date: Date
        let runType: RunType?
        let distanceM: Double?
        let rationale: String?
    }

    private func shape(_ s: PlannedSession) -> Shape {
        Shape(date: s.date, runType: s.runType, distanceM: s.targetDistanceM, rationale: s.rationale)
    }

    private func shapes(_ sessions: [PlannedSession]) -> [UUID: Shape] {
        Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, shape($0)) })
    }

    /// Open sessions the way the engines select them: planned or moved, nothing credited, today or
    /// later, soonest first.
    private func openSessions(of plan: TrainingPlan) -> [PlannedSession] {
        let start = cal.startOfDay(for: today)
        return plan.sessions
            .filter { ($0.status == .planned || $0.status == .moved) && $0.completedWorkout == nil
                      && cal.startOfDay(for: $0.date) >= start }
            .sorted { $0.date < $1.date }
    }

    /// The seven-day ease's horizon: the start of the day a week from today.
    private var weekHorizon: Date { cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: today))! }

    @Test func easeThisWeekTouchesOnlyTheNextSevenDaysAndNeverAProtectedOrFixedDateSession() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let plan = try #require(profile.plan)
        let inWindow = openSessions(of: plan).filter { $0.date < weekHorizon }
        try #require(inWindow.count >= 3)
        // Inside the window: one session the injury loop already converted, one race day (the
        // engine's own tune-up shape), and the ordinary sessions the ease is for.
        let protected = inWindow[0]
        protected.rationale = InjuryResponse.marker + " knee. Easy only."
        let race = inWindow[1]
        race.runType = .race
        race.intervals = "Tune-up · Race it"
        try ctx.save()
        let ordinary = Array(inWindow.dropFirst(2))
        let ordinaryBefore = shapes(ordinary)
        let protectedBefore = shape(protected)
        let raceBefore = shape(race)
        let farStart = cal.startOfDay(for: day(10))
        let farBefore = shapes(plan.sessions.filter { $0.date >= farStart })
        try #require(!farBefore.isEmpty)
        let unit = PlanCoaching.displayUnit(in: ctx)

        let p = PlanAdjustmentService.proposal(.easeThisWeek, title: "Lighten this week", request: "swamped",
                                               profile: profile, workouts: [], today: today, in: ctx)
        #expect(p.isAvailable)
        #expect(p.affected?.sessions == ordinary.count)
        let spy = NotificationSpy()
        guard case .applied(let receipt, _) = PlanAdjustmentService.apply(
            p, profile: profile, workouts: [], notifications: spy, today: today, in: ctx) else {
            Issue.record("the seven-day ease must apply on a fresh plan"); return
        }
        #expect(receipt.headline == "This week eased")
        #expect(plan.lastAdaptedAt == today)
        #expect(spy.scheduled == 1)

        for s in ordinary {
            let before = try #require(ordinaryBefore[s.id])
            #expect(s.rationale == "Eased for a busy week. Showing up small still counts.")
            #expect(s.date == before.date)
            if let d = before.distanceM {
                #expect(s.targetDistanceM == RunRounding.snap(meters: d * 0.85, unit: unit))
            }
            if let rt = before.runType, rt.isQuality {
                #expect(s.runType == .easy)
                #expect(s.intervals == nil)
            } else {
                #expect(s.runType == before.runType)   // the long run keeps its place
            }
        }
        #expect(shape(protected) == protectedBefore)
        #expect(shape(race) == raceBefore)
        #expect(race.intervals == "Tune-up · Race it")
        for s in plan.sessions where s.date >= farStart {
            #expect(shape(s) == farBefore[s.id])
        }
    }

    @Test func easeThisWeekIsDeclinedOnASelfCoachedPlan() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let plan = try #require(profile.plan)
        plan.isSelfCoached = true
        try ctx.save()
        let before = shapes(plan.sessions)
        switch CoachActions.apply(.easeThisWeek, profile: profile, workouts: [], today: today, in: ctx) {
        case .declined(let reason): #expect(reason.contains("coaching this plan yourself"))
        default: Issue.record("a self-coached plan is never reshaped")
        }
        #expect(shapes(plan.sessions) == before)
        #expect(plan.lastAdaptedAt == nil)
    }

    @Test func aPauseShiftsTheTrainingAroundRaceDayAndATuneUp() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let plan = try #require(profile.plan)
        let open = openSessions(of: plan)
        try #require(open.count >= 3)
        // Race day sits inside the pause window; a tune-up the athlete trains through keeps its
        // date on the intervals prefix alone.
        let race = open[0]
        race.runType = .race
        race.intervals = "Tune-up · Race it"
        let tuneUp = open[1]
        tuneUp.intervals = "Tune-up · Train through"
        try ctx.save()
        let days = 7
        let until = cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: today))!
        try #require(race.date < until)
        #expect(PlanCoaching.isFixedDate(race))
        #expect(PlanCoaching.isFixedDate(tuneUp))
        let raceDay = race.date, tuneUpDay = tuneUp.date
        let ordinary = open.dropFirst(2).map { ($0.id, $0.date) }
        #expect(PlanAdjustmentService.affected(.pausePlan(days: days), plan: plan, today: today)?.sessions == ordinary.count)

        #expect(PlanCoaching.pause(plan, days: days, from: today, in: ctx) == ordinary.count)
        #expect(plan.pausedUntil == until)
        #expect(race.date == raceDay)
        #expect(tuneUp.date == tuneUpDay)
        for (id, was) in ordinary {
            let s = try #require(plan.sessions.first { $0.id == id })
            #expect(s.date == cal.date(byAdding: .day, value: days, to: was))
        }
        // Resuming the same day pulls the training back and still leaves the start lines alone.
        #expect(PlanCoaching.resume(plan, from: today, in: ctx) == ordinary.count)
        #expect(plan.pausedUntil == nil)
        #expect(race.date == raceDay)
        #expect(tuneUp.date == tuneUpDay)
        for (id, was) in ordinary {
            #expect(plan.sessions.first { $0.id == id }?.date == was)
        }
    }

    @Test func anExpiredPauseIsPausableAgain() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let plan = try #require(profile.plan)
        plan.pausedUntil = day(-2)
        try ctx.save()
        #expect(PlanAdjustmentService.blocked(.pausePlan(days: 3), profile: profile, workouts: [], today: today) == nil)
        #expect(PlanAdjustmentService.blocked(.resumePlan, profile: profile, workouts: [], today: today) == "The plan is not paused.")
        let p = PlanAdjustmentService.proposal(.pausePlan(days: 3), title: "Pause", request: "3 days",
                                               profile: profile, workouts: [], today: today, in: ctx)
        #expect(p.isAvailable)
        let spy = NotificationSpy()
        guard case .applied(let receipt, _) = PlanAdjustmentService.apply(
            p, profile: profile, workouts: [], notifications: spy, today: today, in: ctx) else {
            Issue.record("a pause that ended days ago must not block a new one"); return
        }
        #expect(receipt.headline == "Plan paused")
        let until = try #require(plan.pausedUntil)
        #expect(until == cal.date(byAdding: .day, value: 3, to: cal.startOfDay(for: today)))
        #expect(until > today)
        #expect(spy.scheduled == 1)
        // Now the window is live, and the gate says so before the tap.
        let live = PlanAdjustmentService.blocked(.pausePlan(days: 3), profile: profile, workouts: [], today: today)
        #expect(live?.contains("already paused") == true)
        #expect(PlanAdjustmentService.blocked(.resumePlan, profile: profile, workouts: [], today: today) == nil)
    }

    @Test func reconcileMissedClearsAnExpiredPauseAndStandsDownForALiveOne() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let plan = try #require(profile.plan)
        // One session that slipped: it sits yesterday, still open.
        let slipped = try #require(openSessions(of: plan).last)
        slipped.date = cal.startOfDay(for: day(-1))
        try ctx.save()
        let past = plan.sessions.filter { $0.date < cal.startOfDay(for: today) }
        try #require(!past.isEmpty)
        // A live window: nothing rolls forward and the stamp stays.
        plan.pausedUntil = day(2)
        try ctx.save()
        PlanCoaching.reconcileMissed(plan, today: today, in: ctx)
        #expect(plan.pausedUntil == day(2))
        #expect(past.allSatisfy { $0.status == .planned })
        // An expired window clears itself, and the past-due sessions roll forward as usual.
        plan.pausedUntil = day(-1)
        try ctx.save()
        PlanCoaching.reconcileMissed(plan, today: today, in: ctx)
        #expect(plan.pausedUntil == nil)
        #expect(past.allSatisfy { $0.status == .moved })
    }

    @Test func undoRestoresThePlanUnderTheSameIdentityWithItsAthleteState() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let plan = try #require(profile.plan)
        let planID = plan.id
        let record = try #require(PlanAthleteStateRecord.fetch(planID: planID, in: ctx))
        record.thresholdSPerKm = 275
        record.riegelExponent = 1.08
        try ctx.save()
        let computedAt = record.computedAt

        let p = PlanAdjustmentService.proposal(.changeDays(daysPerWeek: 5, preferredDays: nil), title: "Days",
                                               request: "5 days", profile: profile, workouts: [], today: today, in: ctx)
        #expect(p.isAvailable)
        let spy = NotificationSpy()
        guard case .applied(_, let undo) = PlanAdjustmentService.apply(
            p, profile: profile, workouts: [], notifications: spy, today: today, in: ctx) else {
            Issue.record("a day change must apply on a fresh plan"); return
        }
        // The rebuild minted a new plan and dropped the old plan's record with it.
        let rebuiltID = try #require(profile.plan?.id)
        #expect(rebuiltID != planID)
        #expect(profile.daysPerWeek == 5)
        #expect(PlanAthleteStateRecord.fetch(planID: planID, in: ctx) == nil)

        #expect(PlanAdjustmentService.undo(try #require(undo), profile: profile, workouts: [], notifications: spy, in: ctx))
        let restored = try #require(profile.plan)
        #expect(restored.id == planID)
        #expect(restored.isSelfCoached == false)
        #expect(profile.daysPerWeek == 4)
        // A fresh context sees the record back under the original id, with the reads it was built with.
        let fresh = ModelContext(c)
        let again = try #require(PlanAthleteStateRecord.fetch(planID: planID, in: fresh))
        #expect(again.thresholdSPerKm == 275)
        #expect(again.riegelExponent == 1.08)
        #expect(abs(again.computedAt.timeIntervalSince(computedAt)) < 1)
    }

    @Test func undoKeepsASelfCoachedPlanSelfCoached() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let plan = try #require(profile.plan)
        plan.isSelfCoached = true
        try ctx.save()
        let planID = plan.id
        let session = try #require(openSessions(of: plan).first)
        let sessionID = session.id
        let from = session.date
        let target = cal.date(byAdding: .day, value: 30, to: cal.startOfDay(for: today))!
        let p = PlanAdjustmentService.proposal(.moveSession(id: sessionID, to: target), title: "Move", request: "move",
                                               profile: profile, workouts: [], today: today, in: ctx)
        #expect(p.isAvailable)
        let spy = NotificationSpy()
        guard case .applied(let receipt, let undo) = PlanAdjustmentService.apply(
            p, profile: profile, workouts: [], notifications: spy, today: today, in: ctx) else {
            Issue.record("a move must apply on a self-coached plan"); return
        }
        #expect(receipt.headline == "Session moved")
        #expect(profile.plan?.sessions.first { $0.id == sessionID }?.date == target)

        #expect(PlanAdjustmentService.undo(try #require(undo), profile: profile, workouts: [], notifications: spy, in: ctx))
        let restored = try #require(profile.plan)
        #expect(restored.id == planID)
        #expect(restored.isSelfCoached)
        #expect(restored.sessions.first { $0.id == sessionID }?.date == from)
        #expect(PlanAthleteStateRecord.fetch(planID: planID, in: ModelContext(c)) != nil)
    }

    @Test func aManageApplyRetiresTheChatsUndoPointAndBecomesTheOnlyOne() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let plan = try #require(profile.plan)
        // The chat applied a move and kept its undo point on the receipt, the way
        // CoachChatViewModel does: capture, apply, retire older points, stamp the card.
        let moved = try #require(openSessions(of: plan).first)
        let movedID = moved.id
        let originalDay = moved.date
        let chatTarget = cal.date(byAdding: .day, value: 40, to: cal.startOfDay(for: today))!
        let chatSnapshot = try #require(CoachUndo.capture(profile))
        guard case .applied = CoachActions.apply(.moveSession(id: movedID, to: chatTarget), profile: profile,
                                                 workouts: [], today: today, in: ctx) else {
            Issue.record("the chat's move must apply"); return
        }
        let card = ChatMessage(role: .coach, text: "Moved it.", createdAt: today,
                               card: CoachCardPayload(kind: .moveSession, label: "Move"))
        card.cardState = .applied
        ctx.insert(card)
        CoachUndo.makeSoleUndoPoint(in: ctx)
        card.undoJSON = chatSnapshot
        try ctx.save()
        let chatPoints = try ctx.fetch(FetchDescriptor<ChatMessage>()).filter { $0.undoJSON != nil }
        #expect(chatPoints.count == 1)

        // Manage plan applies a different change on top.
        let distancesBefore = plan.sessions.sorted { $0.date < $1.date }.map { $0.targetDistanceM ?? 0 }
        let p = PlanAdjustmentService.proposal(.easeThisWeek, title: "Lighten this week", request: "swamped",
                                               profile: profile, workouts: [], today: today, in: ctx)
        #expect(p.isAvailable)
        let spy = NotificationSpy()
        guard case .applied(_, let manageUndo) = PlanAdjustmentService.apply(
            p, profile: profile, workouts: [], notifications: spy, today: today, in: ctx) else {
            Issue.record("the ease must apply on a fresh plan"); return
        }
        // The chat's point is gone: the one undo point in the app is the Manage receipt's.
        let messages = try ctx.fetch(FetchDescriptor<ChatMessage>())
        #expect(messages.allSatisfy { $0.undoJSON == nil })
        #expect(card.undoJSON == nil)
        let json = try #require(manageUndo)
        #expect(json != chatSnapshot)

        #expect(PlanAdjustmentService.undo(json, profile: profile, workouts: [], notifications: spy, in: ctx))
        let restored = try #require(profile.plan)
        // Back to the plan the chat left: the move stands, the ease is gone.
        let movedAfter = try #require(restored.sessions.first { $0.id == movedID })
        #expect(movedAfter.date == chatTarget)
        #expect(movedAfter.date != originalDay)
        #expect(restored.sessions.sorted { $0.date < $1.date }.map { $0.targetDistanceM ?? 0 } == distancesBefore)
        #expect(restored.lastAdaptedAt == nil)
    }

    @Test func theWeeklyThrottleAndAnOpenPauseSurviveARebuild() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let plan = try #require(profile.plan)
        let planID = plan.id
        plan.lastAdaptedAt = today
        plan.lastPaceEasedAt = day(-1)
        plan.pausedUntil = day(3)
        try ctx.save()

        let rebuilt = try #require(PlanService.rebuild(for: profile, startDate: today, in: ctx))
        #expect(rebuilt.id != planID)
        #expect(profile.plan?.id == rebuilt.id)
        #expect(rebuilt.lastAdaptedAt == today)
        #expect(rebuilt.lastPaceEasedAt == day(-1))
        #expect(rebuilt.pausedUntil == day(3))
        // The throttle still holds on the rebuilt plan, and says so before the tap.
        #expect(!CoachActions.canAdaptLoad(rebuilt, today: today))
        let ease = PlanAdjustmentService.proposal(.easeWeek, title: "Ease", request: "lighter", profile: profile,
                                                  workouts: [], today: today, in: ctx)
        #expect(ease.blocked?.contains("One structural change a week") == true)

        // An expired pause is the one latch a rebuild lets go of.
        rebuilt.pausedUntil = day(-1)
        try ctx.save()
        let again = try #require(PlanService.rebuild(for: profile, startDate: today, in: ctx))
        #expect(again.id != rebuilt.id)
        #expect(again.lastAdaptedAt == today)
        #expect(again.lastPaceEasedAt == day(-1))
        #expect(again.pausedUntil == nil)
    }

    @Test func aMoveOntoAnOccupiedDaySaysSoInTheProposal() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let plan = try #require(profile.plan)
        let open = openSessions(of: plan)
        try #require(open.count >= 2)
        let moving = open[0], sitting = open[1]
        try #require(!cal.isDate(moving.date, inSameDayAs: sitting.date))

        let p = PlanAdjustmentService.proposal(.moveSession(id: moving.id, to: sitting.date), title: "Move",
                                               request: "move", profile: profile, workouts: [], today: today, in: ctx)
        #expect(p.isAvailable)
        #expect(p.affected?.sessions == 1)
        let collision = try #require(p.lines.first { $0.contains("already holds") })
        #expect(collision.contains("both would sit on that day"))
        #expect(collision.contains(sitting.date.formatted(.dateTime.weekday(.wide))))

        // Onto a free day there is no such line.
        let free = try #require((1...14).map { day($0) }.first { d in
            !plan.sessions.contains { cal.isDate($0.date, inSameDayAs: d) }
        })
        let clean = PlanAdjustmentService.proposal(.moveSession(id: moving.id, to: free), title: "Move",
                                                   request: "move", profile: profile, workouts: [], today: today, in: ctx)
        #expect(clean.isAvailable)
        #expect(!clean.lines.contains { $0.contains("already holds") })
    }

    @Test func aProposalComputedBeforeASessionWasCompletedIsRecomputedAgainstTheFreshPlan() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let plan = try #require(profile.plan)
        let p = PlanAdjustmentService.proposal(.easeThisWeek, title: "Lighten this week", request: "swamped",
                                               profile: profile, workouts: [], today: today, in: ctx)
        #expect(p.isAvailable)
        let staleAffected = try #require(p.affected)
        // The athlete checks off the next session before tapping.
        let done = try #require(openSessions(of: plan).first { $0.date < weekHorizon })
        PlanCoaching.setCompletion(done, done: true, in: ctx)
        let before = shapes(plan.sessions)
        let spy = NotificationSpy()
        guard case .stale(let fresh) = PlanAdjustmentService.apply(
            p, profile: profile, workouts: [], notifications: spy, today: today, in: ctx) else {
            Issue.record("a proposal against a plan with a newly completed session must be recomputed"); return
        }
        // Nothing was applied, and the fresh proposal reads the plan as it is now.
        #expect(shapes(plan.sessions) == before)
        #expect(plan.lastAdaptedAt == nil)
        #expect(spy.scheduled == 0)
        #expect(fresh.intent == .easeThisWeek)
        #expect(fresh.signature != p.signature)
        #expect(fresh.signature == PlanAdjustmentService.signature(of: profile.plan))
        #expect(fresh.affected?.sessions == staleAffected.sessions - 1)

        // The fresh one applies, and leaves the completed session alone.
        guard case .applied(let receipt, _) = PlanAdjustmentService.apply(
            fresh, profile: profile, workouts: [], notifications: spy, today: today, in: ctx) else {
            Issue.record("the recomputed proposal must apply"); return
        }
        #expect(receipt.headline == "This week eased")
        #expect(done.status == .completed)
        #expect(done.targetDistanceM == before[done.id]?.distanceM)
        #expect(spy.scheduled == 1)
    }
}
