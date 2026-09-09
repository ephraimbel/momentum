import Testing
import Foundation
import SwiftData
@testable import Momentum

/// The polish pass of 2026-09-07 (second review round): rules that were found missing or wrong
/// and are now pinned. Each test names the glitch it stops.
@MainActor
struct PlanPolishRegressionTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private final class NotificationSpy: NotificationServing {
        func requestAuthorization(completion: ((Bool) -> Void)?) { completion?(true) }
        func schedulePlannedReminders(_ plan: TrainingPlan?) {}
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
        profile.weeklyRunVolumeM = 25_000
        profile.longestRunM = 10_000
        profile.experience = [Discipline.running.rawValue: ExperienceLevel.some.rawValue]
        if race {
            profile.raceDistanceM = RaceDistance.half.meters
            profile.raceDate = day(7 * 12)
        }
        ctx.insert(profile)
        try? ctx.save()
        PlanService.regenerate(for: profile, startDate: day(-3), in: ctx)
        return profile
    }

    /// "This week is heavy" then "I missed some training": the second is declined, never stacked.
    @Test func aSecondLightenThisWeekIsDeclinedNotStacked() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let spy = NotificationSpy()
        let first = PlanAdjustmentService.proposal(.easeThisWeek, title: "Lighten", request: "heavy",
                                                   profile: profile, workouts: [], today: today, in: ctx)
        #expect(first.isAvailable)
        guard case .applied = PlanAdjustmentService.apply(first, profile: profile, workouts: [], notifications: spy,
                                                         today: today, in: ctx) else {
            Issue.record("the first ease must apply"); return
        }
        let plan = try #require(profile.plan)
        #expect(PlanCoaching.weekAlreadyEased(plan, from: today))
        let second = PlanAdjustmentService.proposal(.easeThisWeek, title: "Lighten", request: "missed",
                                                    profile: profile, workouts: [], today: today, in: ctx)
        #expect(!second.isAvailable)
        #expect(second.blocked?.contains("already lighter") == true)
        // The engine agrees with the proposal: a direct apply is declined too.
        guard case .declined(let reason) = CoachActions.apply(.easeThisWeek, profile: profile, workouts: [], today: today, in: ctx) else {
            Issue.record("the second ease must be declined"); return
        }
        #expect(reason.contains("already lighter"))
    }

    /// A pause shifts the training around race day, never past it.
    @Test func aPauseNeverPushesASessionPastRaceDay() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx, race: true)
        let plan = try #require(profile.plan)
        let raceDay = cal.startOfDay(for: try #require(plan.raceDate))
        // Put an open, ordinary session two days before the race, then pause a week.
        // Non-completed also includes missed/skipped sessions, which a pause intentionally
        // leaves untouched. Select the open ordinary session this regression promises to test.
        let session = try #require(plan.sessions.first {
            ($0.status == .planned || $0.status == .moved) && $0.completedWorkout == nil
                && $0.runType != nil && !PlanCoaching.isFixedDate($0) && $0.discipline != .strength
        })
        session.date = cal.date(byAdding: .day, value: -2, to: raceDay)!
        try ctx.save()
        // The proposal says so before the pause is applied (a paused plan cannot be paused again).
        let p = PlanAdjustmentService.proposal(.pausePlan(days: 7), title: "Pause", request: "away",
                                               profile: profile, workouts: [], today: today, in: ctx)
        #expect(p.isAvailable)
        #expect(p.lines.contains { $0.contains("no room to move") })
        PlanCoaching.pause(plan, days: 7, from: today, in: ctx)
        #expect(cal.startOfDay(for: session.date) == cal.date(byAdding: .day, value: -2, to: raceDay)!,
                "a session that would land after the race stays where it is")
        #expect(plan.sessions.filter { $0.runType != .race }.allSatisfy { cal.startOfDay(for: $0.date) <= raceDay })
    }

    /// The throttle counts calendar days, the way the row's "available again from Monday" reads.
    @Test func throttlesCountCalendarDaysNotFullSpans() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let plan = try #require(profile.plan)
        let lateSevenDaysAgo = cal.date(bySettingHour: 23, minute: 0, second: 0, of: day(-7))!
        plan.lastAdaptedAt = lateSevenDaysAgo
        plan.lastPaceEasedAt = lateSevenDaysAgo
        #expect(CoachActions.canAdaptLoad(plan, today: today))
        #expect(PlanCoaching.canEasePaces(plan, today: today))
        plan.lastAdaptedAt = cal.date(bySettingHour: 8, minute: 0, second: 0, of: day(-6))!
        #expect(!CoachActions.canAdaptLoad(plan, today: today))
    }

    /// Undoing a renewal takes the closing block's shelf record with it: a plan is never both
    /// current and previous.
    @Test func undoOfARenewalRemovesTheGhostShelfRecord() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let plan = try #require(profile.plan)
        plan.sessions.first?.status = .completed
        try ctx.save()
        let originalID = plan.id
        let snapshot = try #require(CoachUndo.capture(profile))
        _ = PlanService.renewBlock(for: profile, startDate: today, in: ctx)
        try ctx.save()
        #expect(PlanLifecycleService.shelf(for: profile, in: ctx).contains { $0.sourcePlanID == originalID })
        #expect(CoachUndo.restore(snapshot, profile: profile, in: ctx))
        try ctx.save()
        #expect(profile.plan?.id == originalID)
        #expect(!PlanLifecycleService.shelf(for: profile, in: ctx).contains { $0.sourcePlanID == originalID })
        #expect(try ctx.fetch(FetchDescriptor<TrainingPlan>()).count == 1)
    }

    /// Switching plans retires every older chat undo point: nothing can resurrect the plan that
    /// was just shelved.
    @Test func activatingAPlanRetiresTheChatsUndoPoints() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let message = ChatMessage(role: .coach, text: "Moved it.")
        message.cardState = .applied
        message.undoJSON = try #require(CoachUndo.capture(profile))
        ctx.insert(message)
        try ctx.save()
        var blueprint = PlanBlueprint(profile: profile)
        blueprint.name = "Fresh block"
        blueprint.goal = .generalFitness
        _ = try PlanLifecycleService.activate(blueprint, for: profile, now: today, in: ctx)
        let messages = try ctx.fetch(FetchDescriptor<ChatMessage>())
        #expect(messages.allSatisfy { $0.undoJSON == nil })
    }
}
