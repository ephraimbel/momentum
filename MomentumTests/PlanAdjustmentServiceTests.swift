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
        #expect(receipt.headline == "Week eased")
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
}
