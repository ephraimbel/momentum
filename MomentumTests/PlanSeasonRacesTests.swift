import Testing
import Foundation
import SwiftData
@testable import Momentum

/// The season's other races, end to end (2026-09-03): tune-ups reach the persisted plan through
/// Plan Settings' command, the command's timing rules hold, a completed tune-up settles without a
/// rebuild, and after the goal race the next planned race is promoted.
@MainActor
struct PlanSeasonRacesTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private let cal = Calendar.current

    /// A marathon plan with a goal race `weeksOut` ahead, generated from `now`, with its season
    /// sidecars in place (the same launch pass production runs).
    private func marathoner(in container: ModelContainer, now: Date, weeksOut: Int = 16) throws -> UserProfile {
        let ctx = container.mainContext
        let profile = UserProfile()
        profile.distanceUnit = "metric"
        profile.disciplines = ["running"]
        profile.goal = .raceDistance
        profile.daysPerWeek = 5
        profile.preferredDays = [3, 4, 5, 7, 1]
        profile.experience = ["running": ExperienceLevel.experienced.rawValue]
        profile.weeklyRunVolumeM = 48_000
        profile.longestRunM = 18_000
        profile.raceDate = cal.date(byAdding: .weekOfYear, value: weeksOut, to: cal.startOfDay(for: now))
        profile.raceDistanceM = 42_195
        ctx.insert(profile)
        PlanService.regenerate(for: profile, startDate: now, in: ctx)
        _ = try RunningPlanBackfill.repair(in: container, now: now, calendar: cal)
        return profile
    }

    private func day(_ n: Int, from now: Date) -> Date { cal.date(byAdding: .day, value: n, to: cal.startOfDay(for: now))! }

    private func tuneUps(for profile: UserProfile, in ctx: ModelContext) -> [PlanRaceEvent] {
        PlanService.tuneUpRaces(for: profile, in: ctx)
    }

    /// Plan Settings' Save, in miniature: rebuild with the buffered list, then the command.
    private func save(tuneUps list: [TuneUpEvent], for profile: UserProfile, now: Date, in ctx: ModelContext) throws {
        let command = try PlanConfigurationCommand.legacyUICommand(
            id: UUID(), profile: profile, startsNewSeason: false,
            planName: profile.plan?.name ?? "", goal: profile.goal,
            raceDate: profile.raceDate, raceDistanceM: profile.raceDistanceM,
            goalFinishTimeS: profile.goalFinishTimeS, tuneUps: list, now: now, in: ctx)
        try command.preflightValidation()
        let events = list.map { PlanRaceEvent(id: $0.id, date: $0.date, distanceM: $0.distanceM, priority: $0.priority, goalTimeS: $0.goalTimeS) }
        _ = try PlanService.stageRebuild(for: profile, startDate: now, tuneUps: events, in: ctx)
        _ = try command.apply(in: ctx, now: now)
        _ = try RunningPlanBackfill.prepareAfterLegacyPlanMutation(in: ctx)
        try ctx.save()
    }

    // MARK: Configuration

    @Test func addingATuneUpPersistsItAndBendsThePersistedPlan() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let now = try #require(DateComponents(calendar: cal, year: 2026, month: 9, day: 7).date)   // a Monday
        let profile = try marathoner(in: container, now: now)
        #expect(tuneUps(for: profile, in: ctx).isEmpty)

        let tenK = TuneUpEvent(name: "Harbor 10K", date: day(7 * 8 + 6, from: now), distanceM: 10_000, priority: .b)
        try save(tuneUps: [tenK], for: profile, now: now, in: ctx)

        let stored = tuneUps(for: profile, in: ctx)
        #expect(stored.count == 1)
        #expect(stored.first?.priority == .b)
        #expect(stored.first?.distanceM == 10_000)
        // The rebuilt plan carries the race on its day, marked as a tune-up.
        let plan = try #require(profile.plan)
        let race = try #require(plan.sessions.first { $0.runType == .race && cal.isDate($0.date, inSameDayAs: tenK.date) })
        #expect(race.intervals == "Tune-up · Race it")
        #expect(race.targetDistanceM == 10_000)
        // The goal race is still there and still the block's last session.
        #expect(plan.sessions.contains { $0.runType == .race && $0.targetDistanceM == 42_195 })
        // A rebuild WITHOUT a list keeps reading it from the season.
        _ = try PlanService.stageRebuild(for: profile, startDate: day(1, from: now), in: ctx)
        try ctx.save()
        #expect(profile.plan?.sessions.contains { $0.intervals == "Tune-up · Race it" } == true)
    }

    @Test func removingATuneUpWithdrawsItRatherThanDeletingIt() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let now = try #require(DateComponents(calendar: cal, year: 2026, month: 9, day: 7).date)
        let profile = try marathoner(in: container, now: now)
        let tenK = TuneUpEvent(name: "Harbor 10K", date: day(7 * 8 + 6, from: now), distanceM: 10_000, priority: .b)
        let fiveK = TuneUpEvent(name: "", date: day(7 * 5 + 3, from: now), distanceM: 5_000, priority: .c)
        try save(tuneUps: [tenK, fiveK], for: profile, now: now, in: ctx)
        #expect(tuneUps(for: profile, in: ctx).count == 2)

        try save(tuneUps: [fiveK], for: profile, now: now, in: ctx)
        #expect(tuneUps(for: profile, in: ctx).map(\.id) == [fiveK.id])
        let tenKID = tenK.id
        let record = try #require(try ctx.fetch(FetchDescriptor<RunningEventRecord>(predicate: #Predicate { $0.id == tenKID })).first)
        #expect(record.statusRaw == RunningEventStatus.withdrawn.rawValue)
        #expect(profile.plan?.sessions.contains { $0.runType == .race && $0.targetDistanceM == 10_000 } == false)
    }

    @Test func theTimingRulesHold() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let now = try #require(DateComponents(calendar: cal, year: 2026, month: 9, day: 7).date)
        let profile = try marathoner(in: container, now: now)
        func attempt(_ list: [TuneUpEvent]) -> PlanConfigurationCommandError? {
            do {
                let command = try PlanConfigurationCommand.legacyUICommand(
                    id: UUID(), profile: profile, startsNewSeason: false, planName: "", goal: profile.goal,
                    raceDate: profile.raceDate, raceDistanceM: profile.raceDistanceM,
                    goalFinishTimeS: profile.goalFinishTimeS, tuneUps: list, now: now, in: ctx)
                try command.preflightValidation()
                return nil
            } catch let error as PlanConfigurationCommandError {
                return error
            } catch { return nil }
        }
        let goal = try #require(profile.raceDate)
        // Inside the next week.
        if case .tuneUpTooSoon? = attempt([TuneUpEvent(date: day(3, from: now), distanceM: 5_000, priority: .c)]) {} else {
            Issue.record("a tune-up three days out should be too soon")
        }
        // After the goal race.
        if case .tuneUpAfterGoalRace? = attempt([TuneUpEvent(date: cal.date(byAdding: .day, value: 2, to: goal)!, distanceM: 5_000, priority: .c)]) {} else {
            Issue.record("a tune-up after the goal race should be rejected")
        }
        // A B race four days before the goal.
        if case .tuneUpTooClose? = attempt([TuneUpEvent(date: cal.date(byAdding: .day, value: -4, to: goal)!, distanceM: 10_000, priority: .b)]) {} else {
            Issue.record("a raced tune-up four days before the goal should be too close")
        }
        // Two B races five days apart.
        if case .tuneUpTooClose? = attempt([
            TuneUpEvent(date: day(7 * 6, from: now), distanceM: 10_000, priority: .b),
            TuneUpEvent(date: day(7 * 6 + 5, from: now), distanceM: 10_000, priority: .b),
        ]) {} else { Issue.record("two raced tune-ups five days apart should be too close") }
        // A C race three days from a B is fine; a week out is fine; nine days before the goal is fine.
        #expect(attempt([
            TuneUpEvent(date: day(7 * 6, from: now), distanceM: 10_000, priority: .b),
            TuneUpEvent(date: day(7 * 6 + 3, from: now), distanceM: 5_000, priority: .c),
            TuneUpEvent(date: cal.date(byAdding: .day, value: -9, to: goal)!, distanceM: 10_000, priority: .b),
        ]) == nil)
        #expect(attempt([TuneUpEvent(date: day(7, from: now), distanceM: 5_000, priority: .c)]) == nil)
    }

    // MARK: Settling

    @Test func aCompletedTuneUpSettlesWithoutRebuildingOrMovingTheGoal() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let now = try #require(DateComponents(calendar: cal, year: 2026, month: 9, day: 7).date)
        let profile = try marathoner(in: container, now: now)
        let raceDay = day(7 * 6 + 6, from: now)
        let tenK = TuneUpEvent(name: "Harbor 10K", date: raceDay, distanceM: 10_000, priority: .b)
        try save(tuneUps: [tenK], for: profile, now: now, in: ctx)
        let plan = try #require(profile.plan)
        let planID = plan.id
        let goalDate = profile.raceDate

        // The athlete ran it: 10K in 42:00, a strong result against a 330 s/km assumed 5K.
        let session = try #require(plan.sessions.first { $0.runType == .race && cal.isDate($0.date, inSameDayAs: raceDay) })
        let workout = Workout()
        workout.type = .run
        workout.startedAt = raceDay
        workout.durationS = 42 * 60
        let gps = GPSDetail(); gps.distanceM = 10_000
        workout.gps = gps
        ctx.insert(workout)
        PlanCoaching.markComplete(session, with: workout, in: ctx)

        // Race evening: nothing settles yet.
        #expect(PlanService.settleRaces(for: profile, today: raceDay, in: ctx) == nil)
        // The day after: the event completes, the paces sharpen, nothing is rebuilt.
        let headline = PlanService.settleRaces(for: profile, today: day(7 * 6 + 7, from: now), in: ctx)
        #expect(headline == "Tune-up done")
        #expect(profile.plan?.id == planID)
        #expect(profile.raceDate == goalDate)
        #expect(profile.raceDistanceM == 42_195)
        #expect(tuneUps(for: profile, in: ctx).isEmpty)
        let tenKID = tenK.id
        let record = try #require(try ctx.fetch(FetchDescriptor<RunningEventRecord>(predicate: #Predicate { $0.id == tenKID })).first)
        #expect(record.statusRaw == RunningEventStatus.completed.rawValue)
        #expect((profile.plan?.p5kSPerKm ?? 0) < 330)
        // Idempotent.
        #expect(PlanService.settleRaces(for: profile, today: day(7 * 6 + 8, from: now), in: ctx) == nil)
    }

    @Test func afterTheGoalRaceTheNextPlannedRaceIsPromoted() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let now = try #require(DateComponents(calendar: cal, year: 2026, month: 9, day: 7).date)
        let profile = try marathoner(in: container, now: now, weeksOut: 12)
        let goal = try #require(profile.raceDate)
        // A half marathon six weeks after the marathon, planned as a B on the same season.
        let later = cal.date(byAdding: .weekOfYear, value: 6, to: goal)!
        guard let season = PlanService.activeSeason(for: profile, in: ctx) else {
            Issue.record("the backfill should have written a season"); return
        }
        let half = RunningEventRecord(
            id: UUID(), seasonID: season.id, name: "Autumn Half", date: later, distanceM: 21_097, durationS: nil,
            priorityRaw: RunningEventPriority.b.rawValue, surfaceRaw: RunningEventSurface.road.rawValue,
            ascentM: nil, descentM: nil,
            altitudeRaw: RunningEnvironmentBand.unknown.rawValue, technicalityRaw: RunningEnvironmentBand.unknown.rawValue,
            climateRaw: RunningEnvironmentBand.unknown.rawValue, statusRaw: RunningEventStatus.planned.rawValue)
        ctx.insert(half)
        try ctx.save()

        // The marathon happens.
        let plan = try #require(profile.plan)
        let raceSession = try #require(plan.sessions.first { $0.runType == .race && $0.targetDistanceM == 42_195 })
        let workout = Workout()
        workout.type = .run
        workout.startedAt = goal
        workout.durationS = 3 * 3600 + 30 * 60
        let gps = GPSDetail(); gps.distanceM = 42_195
        workout.gps = gps
        ctx.insert(workout)
        PlanCoaching.markComplete(raceSession, with: workout, in: ctx)

        let headline = PlanService.settleRaces(for: profile, today: cal.date(byAdding: .day, value: 1, to: goal)!, in: ctx)
        #expect(headline?.contains("Half marathon") == true)
        // The half is the goal now, on the profile and on the season.
        #expect(profile.raceDate.map { cal.isDate($0, inSameDayAs: later) } == true)
        #expect(profile.raceDistanceM == 21_097)
        #expect(half.priorityRaw == RunningEventPriority.a.rawValue)
        #expect(profile.plan?.name == "Autumn Half")
        #expect(profile.plan?.id != plan.id)
        // The block opens with the marathon's recovery lead-in and ends on the half.
        let next = try #require(profile.plan)
        #expect(next.weekPhases.first == PlanPhase.recovery.rawValue)
        #expect(next.sessions.contains { $0.runType == .race && abs(($0.targetDistanceM ?? 0) - 21_097) < 1 })
        #expect(next.raceDate.map { cal.isDate($0, inSameDayAs: later) } == true)
    }

    @Test func withNothingElseOnTheSeasonTheGoalClearsAsBefore() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let now = try #require(DateComponents(calendar: cal, year: 2026, month: 9, day: 7).date)
        let profile = try marathoner(in: container, now: now, weeksOut: 12)
        let goal = try #require(profile.raceDate)
        let headline = PlanService.settleRaces(for: profile, today: cal.date(byAdding: .day, value: 1, to: goal)!, in: ctx)
        #expect(headline == "Race week's behind you")
        #expect(profile.raceDate == nil)
        #expect(profile.raceDistanceM == nil)
    }
}
