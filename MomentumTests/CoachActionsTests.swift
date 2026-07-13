import Testing
import Foundation
import SwiftData
@testable import Momentum

/// The coach-chat apply layer: validated intents route to the deterministic engines, the ≤1
/// structural change/week throttle is enforced at tap time, load raises must be earned, and every
/// applied change returns a receipt the coach can narrate.
@MainActor
struct CoachActionsTests {

    func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private let cal = Calendar.current
    private var today: Date { cal.startOfDay(for: Date()) }
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

    /// A running profile with a plan holding future easy runs every 4th day (so some sessions still
    /// sit ahead even when a test advances "today" past the throttle window).
    private func makeProfile(in ctx: ModelContext, futureSessions count: Int = 3) -> UserProfile {
        let profile = UserProfile()
        profile.disciplines = [Discipline.running.rawValue]
        let plan = TrainingPlan()
        ctx.insert(profile)
        ctx.insert(plan)
        var sessions: [PlannedSession] = []
        for i in 1...max(1, count) {
            let s = PlannedSession()
            s.date = day(i * 4)
            s.discipline = .running
            s.runType = .easy
            s.status = .planned
            s.targetDistanceM = 6_000
            s.targetPaceSPerKm = 380
            ctx.insert(s)
            sessions.append(s)
        }
        plan.sessions = sessions
        profile.plan = plan
        try? ctx.save()
        return profile
    }

    // MARK: Throttle

    @Test func easeWeekAppliesOnceThenThrottles() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)

        let first = CoachActions.apply(.easeWeek, profile: profile, workouts: [], today: today, in: ctx)
        guard case .applied(let receipt) = first else { Issue.record("expected applied, got \(first)"); return }
        #expect(!receipt.headline.isEmpty && !receipt.detail.isEmpty)
        #expect(profile.plan?.lastAdaptedAt != nil)

        // Same ask two days later: the one-structural-change-per-week gate declines in words.
        let second = CoachActions.apply(.easeWeek, profile: profile, workouts: [], today: day(2), in: ctx)
        guard case .declined(let reason) = second else { Issue.record("expected declined, got \(second)"); return }
        #expect(reason.contains("One structural change"))

        // Eight days later the window has passed.
        let third = CoachActions.apply(.easeWeek, profile: profile, workouts: [], today: day(8), in: ctx)
        guard case .applied = third else { Issue.record("expected applied after 7 days, got \(third)"); return }
    }

    @Test func bumpLoadMustBeEarned() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)

        // No completed load at all → the ACWR rec is not .increase → declined, plan untouched.
        let outcome = CoachActions.apply(.bumpLoad, profile: profile, workouts: [], today: today, in: ctx)
        guard case .declined = outcome else { Issue.record("expected declined, got \(outcome)"); return }
        #expect(profile.plan?.lastAdaptedAt == nil)
        #expect(profile.plan?.sessions.allSatisfy { $0.targetDistanceM == 6_000 } == true)
    }

    // MARK: Schedule (not throttled — scheduling, not load)

    @Test func moveSessionReschedulesWithoutTouchingThrottle() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)
        let session = profile.plan!.sessions.sorted { $0.date < $1.date }[0]

        let outcome = CoachActions.apply(.moveSession(id: session.id, to: day(5)),
                                         profile: profile, workouts: [], today: today, in: ctx)
        guard case .applied = outcome else { Issue.record("expected applied, got \(outcome)"); return }
        #expect(cal.isDate(session.date, inSameDayAs: day(5)))
        #expect(profile.plan?.lastAdaptedAt == nil)
    }

    @Test func skipSessionDeletesAndStaleIdDeclines() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx, futureSessions: 2)
        let session = profile.plan!.sessions.sorted { $0.date < $1.date }[0]
        let id = session.id

        let outcome = CoachActions.apply(.skipSession(id: id), profile: profile, workouts: [], today: today, in: ctx)
        guard case .applied = outcome else { Issue.record("expected applied, got \(outcome)"); return }
        #expect(profile.plan?.sessions.count == 1)

        // The same card tapped again (stale): honest decline, no crash.
        let again = CoachActions.apply(.skipSession(id: id), profile: profile, workouts: [], today: today, in: ctx)
        guard case .declined = again else { Issue.record("expected declined, got \(again)"); return }
    }

    // MARK: Rebuild-class changes

    @Test func changeDaysWritesProfileAndRebuilds() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)
        profile.weeklyRunVolumeM = 20_000
        try? ctx.save()

        let outcome = CoachActions.apply(.changeDays(daysPerWeek: 5, preferredDays: nil),
                                         profile: profile, workouts: [], today: today, in: ctx)
        guard case .applied = outcome else { Issue.record("expected applied, got \(outcome)"); return }
        #expect(profile.daysPerWeek == 5)
        #expect(profile.plan != nil)
        #expect((profile.plan?.sessions.isEmpty) == false)
    }

    @Test func sameGoalDeclinesWithoutRebuilding() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)
        profile.goal = .endurance
        let planID = profile.plan?.id

        let outcome = CoachActions.apply(.changeGoal(.endurance), profile: profile, workouts: [], today: today, in: ctx)
        guard case .declined = outcome else { Issue.record("expected declined, got \(outcome)"); return }
        #expect(profile.plan?.id == planID)   // untouched — no silent rebuild
    }

    @Test func switchingAStrengthAthleteToARunningGoalAddsRunning() throws {
        // A strength-only athlete asks the coach for a running focus — the rebuild must add running,
        // or the plan would be a "race" with no runs. (changeGoal(.endurance) skips feasibility, so
        // it always applies — the cleanest way to exercise the guard.)
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)
        profile.disciplines = [Discipline.strength.rawValue]   // strength only
        profile.goal = .buildMuscle
        try? ctx.save()

        let outcome = CoachActions.apply(.changeGoal(.endurance), profile: profile, workouts: [], today: today, in: ctx)
        guard case .applied = outcome else { Issue.record("expected applied, got \(outcome)"); return }
        #expect(profile.disciplines.contains(Discipline.running.rawValue))
        let runs = (profile.plan?.sessions ?? []).filter { $0.discipline == .running }
        #expect(!runs.isEmpty, "a running goal must produce running sessions")
    }

    // MARK: Race honesty

    @Test func impossibleRaceDeclinesBeforeAnyMutation() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)
        profile.experience = [Discipline.running.rawValue: ExperienceLevel.new.rawValue]
        profile.weeklyRunVolumeM = 0
        let planID = profile.plan?.id

        // A brand-new runner, marathon in two weeks: tooShort → declined, profile untouched.
        let outcome = CoachActions.apply(.changeRace(distanceM: 42_195, date: day(14), goalFinishTimeS: nil),
                                         profile: profile, workouts: [], today: today, in: ctx)
        guard case .declined = outcome else { Issue.record("expected declined, got \(outcome)"); return }
        #expect(profile.raceDate == nil)
        #expect(profile.raceDistanceM == nil)
        #expect(profile.plan?.id == planID)
    }

    @Test func reachableRaceAppliesAndRetargetsGoal() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)
        profile.experience = [Discipline.running.rawValue: ExperienceLevel.some.rawValue]
        profile.weeklyRunVolumeM = 25_000

        let raceDay = day(16 * 7)
        let outcome = CoachActions.apply(.changeRace(distanceM: 10_000, date: raceDay, goalFinishTimeS: nil),
                                         profile: profile, workouts: [], today: today, in: ctx)
        guard case .applied = outcome else { Issue.record("expected applied, got \(outcome)"); return }
        #expect(profile.raceDistanceM == 10_000)
        #expect(profile.raceDate.map { cal.isDate($0, inSameDayAs: raceDay) } == true)
        #expect(profile.goal == .raceDistance)
        #expect((profile.plan?.sessions.isEmpty) == false)
    }

    // MARK: Pause / resume

    @Test func pauseShiftsSessionsAndResumePullsBack() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx, futureSessions: 3)
        let plan = profile.plan!
        let originalDates = plan.sessions.sorted { $0.date < $1.date }.map(\.date)

        let paused = CoachActions.apply(.pausePlan(days: 7), profile: profile, workouts: [], today: today, in: ctx)
        guard case .applied = paused else { Issue.record("expected applied, got \(paused)"); return }
        #expect(plan.pausedUntil != nil)
        let shifted = plan.sessions.sorted { $0.date < $1.date }.map(\.date)
        for (orig, new) in zip(originalDates, shifted) {
            #expect(cal.dateComponents([.day], from: orig, to: new).day == 7)
        }

        // Paused plans are exempt from missed-session reconciliation.
        let statusBefore = plan.sessions.map(\.status)
        PlanCoaching.reconcileMissed(plan, today: day(2), in: ctx)
        #expect(plan.sessions.map(\.status) == statusBefore)

        // Back after 2 of 7 days: sessions pull back by the unused 5, pause clears.
        let resumed = CoachActions.apply(.resumePlan, profile: profile, workouts: [], today: day(2), in: ctx)
        guard case .applied = resumed else { Issue.record("expected applied, got \(resumed)"); return }
        #expect(plan.pausedUntil == nil)
        let restored = plan.sessions.sorted { $0.date < $1.date }.map(\.date)
        for (orig, new) in zip(originalDates, restored) {
            let delta = cal.dateComponents([.day], from: orig, to: new).day ?? -1
            #expect(delta == 2)   // net shift = days actually paused
            #expect(cal.startOfDay(for: new) >= day(2))
        }

        // Double-pause / double-resume decline honestly.
        let rePause = CoachActions.apply(.resumePlan, profile: profile, workouts: [], today: day(2), in: ctx)
        guard case .declined = rePause else { Issue.record("expected declined, got \(rePause)"); return }
    }

    // MARK: Injury + paces

    @Test func injuryReportChangesWindowAndReturnsReceipt() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx, futureSessions: 4)
        profile.plan!.sessions.forEach { $0.runType = .tempo }

        let outcome = CoachActions.apply(.injuryReport(area: .shins, severity: .twinge),
                                         profile: profile, workouts: [], today: today, in: ctx)
        guard case .applied(let receipt) = outcome else { Issue.record("expected applied, got \(outcome)"); return }
        #expect(!receipt.headline.isEmpty)
        #expect(profile.activeInjuryArea == InjuryArea.shins.rawValue)
    }

    @Test func easePacesDeclinesWithNothingToEase() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx, futureSessions: 1)
        profile.plan!.sessions.forEach { $0.targetPaceSPerKm = nil }   // no paced runs upcoming

        let outcome = CoachActions.apply(.easePaces, profile: profile, workouts: [], today: today, in: ctx)
        guard case .declined = outcome else { Issue.record("expected declined, got \(outcome)"); return }
    }

    // MARK: Preview

    @Test func previewsAreConcreteDiffLines() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)

        let days = CoachActions.preview(.changeDays(daysPerWeek: 5, preferredDays: nil), profile: profile)
        #expect(days.contains { $0.contains("3 → 5") })

        let session = profile.plan!.sessions[0]
        let move = CoachActions.preview(.moveSession(id: session.id, to: day(6)), profile: profile)
        #expect(move.count == 2)
    }
}
