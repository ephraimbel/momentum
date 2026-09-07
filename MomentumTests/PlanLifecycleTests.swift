import Testing
import Foundation
import SwiftData
@testable import Momentum

/// The plan shelf (2026-09-07, docs/PLAN-AND-FUEL-UPGRADE.md §3): one current plan, drafts that
/// never start on their own, upcoming plans that start on their day exactly once, previous plans
/// that keep their story, and workouts that are never touched by any of it.
@MainActor
struct PlanLifecycleTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private let cal = Calendar.current
    private var today: Date { cal.date(bySettingHour: 10, minute: 0, second: 0, of: cal.startOfDay(for: Date()))! }
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

    /// A runner with a generated open-ended plan (the real engine, so sessions and phases exist).
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
        PlanService.regenerate(for: profile, startDate: today, in: ctx)
        return profile
    }

    private func blueprint10K(_ profile: UserProfile) -> PlanBlueprint {
        var b = PlanBlueprint(profile: profile)
        b.name = "Faster 10K"
        b.goal = .raceDistance
        b.raceDistanceM = RaceDistance.tenK.meters
        b.raceDate = day(7 * 10)
        b.goalFinishTimeS = 50 * 60
        b.daysPerWeek = 4
        return b
    }

    private func logRun(_ meters: Double, at date: Date, for profile: UserProfile, in ctx: ModelContext) -> Workout {
        let w = Workout()
        w.type = .run
        w.startedAt = date
        w.durationS = meters / 1000 * 330
        let gps = GPSDetail()
        gps.distanceM = meters
        w.gps = gps
        ctx.insert(gps)
        ctx.insert(w)
        profile.workouts.append(w)
        return w
    }

    // MARK: - Pure rules

    @Test func overlapIsNilWhenTheCurrentPlanIsAlreadyOver() {
        let span = PlanLifecycle.Span(start: day(-40), end: day(-1), raceDate: day(-1), openSessionDates: [])
        #expect(PlanLifecycle.overlap(current: span, proposedStart: today) == nil)
        #expect(PlanLifecycle.overlap(current: nil, proposedStart: today) == nil)
    }

    @Test func overlapCountsTheWeeksAndSessionsCutAndOffersTheDayAfter() throws {
        let span = PlanLifecycle.Span(start: day(-14), end: day(20), raceDate: day(20),
                                      openSessionDates: [day(-1), day(2), day(9), day(20)])
        let overlap = try #require(PlanLifecycle.overlap(current: span, proposedStart: day(1)))
        #expect(overlap.weeksCut == 3)          // 20 days → 3 weeks, rounded up
        #expect(overlap.sessionsCut == 3)       // yesterday's session is not cut
        #expect(overlap.cutsGoalRace)
        #expect(cal.isDate(overlap.nextFreeStart, inSameDayAs: day(21)))
    }

    @Test func retirementIsCompletedOnlyWhenThePlanEndedBeforeTheDate() {
        let over = PlanLifecycle.Span(start: day(-40), end: day(-1), raceDate: nil, openSessionDates: [])
        let open = PlanLifecycle.Span(start: day(-10), end: day(10), raceDate: nil, openSessionDates: [day(3)])
        #expect(PlanLifecycle.retirementStatus(over, at: today) == .completed)
        #expect(PlanLifecycle.retirementStatus(open, at: today) == .incomplete)
        #expect(PlanLifecycle.retirementStatus(nil, at: today) == .completed)
    }

    @Test func dueIsDayGranularAndTheEarliestDueWins() {
        #expect(PlanLifecycle.isDue(scheduledStart: day(0), today: today))
        #expect(PlanLifecycle.isDue(scheduledStart: day(-3), today: today))
        #expect(!PlanLifecycle.isDue(scheduledStart: day(1), today: today))
        let a = UUID(), b = UUID(), c = UUID()
        let winner = PlanLifecycle.firstDue([(a, day(-1)), (b, day(-4)), (c, day(2))], today: today)
        #expect(winner == b)
        #expect(PlanLifecycle.firstDue([(c, day(2))], today: today) == nil)
    }

    @Test func schedulingRequiresAFutureDay() {
        #expect(!PlanLifecycle.canSchedule(today, today: today))
        #expect(PlanLifecycle.canSchedule(day(1), today: today))
    }

    @Test func progressReadsTheWeekFromTheStart() {
        let p = PlanLifecycle.progress(start: day(-15), weeks: 6,
                                       sessionStatuses: [.completed, .completed, .planned, .missed], today: today)
        #expect(p.weekNumber == 3)
        #expect(p.weeks == 6)
        #expect(p.sessionsDone == 2)
        #expect(p.sessionsPlanned == 4)
    }

    @Test func blueprintRoundTripsThroughTheProfile() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        var b = blueprint10K(profile)
        b.preferredDays = [2, 4, 6, 1]
        b.intensity = .aggressive
        b.includesStrength = true
        b.apply(to: profile)
        let read = PlanBlueprint(profile: profile)
        #expect(read.goal == .raceDistance)
        #expect(read.raceDistanceM == RaceDistance.tenK.meters)
        #expect(read.goalFinishTimeS == 3000.0)
        #expect(read.preferredDays == [2, 4, 6, 1])
        #expect(read.intensity == .aggressive)
        #expect(read.includesStrength)
        #expect(profile.disciplines == [Discipline.running.rawValue, Discipline.strength.rawValue])
        let data = try JSONEncoder().encode(b)
        #expect(try JSONDecoder().decode(PlanBlueprint.self, from: data) == b)
    }

    // MARK: - Draft isolation

    @Test func previewingAndSavingADraftDoesNotTouchTheCurrentPlanOrProfile() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let currentID = try #require(profile.plan?.id)
        let sessionIDs = Set(profile.plan?.sessions.map(\.id) ?? [])
        let goalBefore = profile.goal
        let daysBefore = profile.daysPerWeek

        let b = blueprint10K(profile)
        let preview = PlanLifecycleService.preview(for: b, profile: profile, startDate: today, in: ctx)
        let expectedWeeks = PlanEngine.weeksToGenerate(startDate: today, raceDate: b.raceDate, calendar: cal)
        #expect(preview.weeks == expectedWeeks)
        #expect(preview.runsPerWeek >= 3)
        #expect(preview.peakWeekM > 0)
        #expect(preview.longestRunM > 0)
        #expect(preview.outlook != nil)
        #expect(!preview.typicalWeek.isEmpty)

        let record = try PlanLifecycleService.saveDraft(b, preview: preview, for: profile, now: today, in: ctx)
        #expect(record.status == .draft)
        #expect(record.preview?.weeks == expectedWeeks)
        #expect(profile.plan?.id == currentID)
        #expect(Set(profile.plan?.sessions.map(\.id) ?? []) == sessionIDs)
        #expect(profile.goal == goalBefore)
        #expect(profile.daysPerWeek == daysBefore)
        #expect(profile.raceDistanceM == nil)
        #expect(try ctx.fetch(FetchDescriptor<TrainingPlan>()).count == 1)
    }

    @Test func aDraftNeverStartsWhenItsDayPasses() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let currentID = try #require(profile.plan?.id)
        let record = try PlanLifecycleService.saveDraft(blueprint10K(profile), preview: nil, for: profile, now: day(-10), in: ctx)
        record.scheduledStart = day(-3)   // a pencilled-in day on a DRAFT is informational
        try ctx.save()
        #expect(PlanLifecycleService.activateDueUpcoming(for: profile, today: today, in: ctx) == nil)
        #expect(profile.plan?.id == currentID)
        #expect(record.status == .draft)
    }

    // MARK: - Activation and conflicts

    @Test func activatingADraftRetiresTheCurrentPlanAsIncompleteAndKeepsEveryWorkout() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let oldPlan = try #require(profile.plan)
        let oldID = oldPlan.id
        // A run credited to the old plan, two weeks back: it must survive untouched.
        let past = day(-14)
        let run = logRun(8_000, at: past, for: profile, in: ctx)
        let credited = try #require(oldPlan.sessions.filter { $0.discipline == .running }.min { $0.date < $1.date })
        credited.status = .completed
        credited.completedWorkout = run
        run.plannedSession = credited
        try ctx.save()
        let workoutCount = try ctx.fetch(FetchDescriptor<Workout>()).count

        let record = try PlanLifecycleService.saveDraft(blueprint10K(profile), preview: nil, for: profile, now: today, in: ctx)
        let activation = try PlanLifecycleService.activate(try #require(record.blueprint), from: record,
                                                            for: profile, now: today, in: ctx)
        #expect(activation.plan.id != oldID)
        #expect(profile.plan?.id == activation.plan.id)
        #expect(profile.goal == .raceDistance)
        #expect(profile.raceDistanceM == RaceDistance.tenK.meters)
        #expect(activation.plan.name == "Faster 10K")
        #expect(cal.isDate(activation.start, inSameDayAs: today))
        // Exactly one TrainingPlan row remains; the record is gone; the old plan is on the shelf.
        #expect(try ctx.fetch(FetchDescriptor<TrainingPlan>()).count == 1)
        let shelf = PlanLifecycleService.shelf(for: profile, in: ctx)
        #expect(shelf.count == 1)
        let retired = try #require(activation.retired)
        #expect(retired.status == .incomplete)
        #expect(retired.sourcePlanID == oldID)
        #expect(retired.snapshot?.sessions.isEmpty == false)
        #expect(retired.snapshot?.sessions.contains { $0.completedWorkoutID == run.id } == true)
        // Workouts: same count, same run, history rewritten nowhere.
        let workouts = try ctx.fetch(FetchDescriptor<Workout>())
        #expect(workouts.count == workoutCount)
        #expect(workouts.contains { $0.id == run.id && $0.gps?.distanceM == 8_000 })
        #expect(run.startedAt == past)
    }

    @Test func activationFailureRollsBackEverything() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let currentID = try #require(profile.plan?.id)
        var stale = blueprint10K(profile)
        stale.raceDate = day(-2)   // a race already run cannot be trained for
        let record = try PlanLifecycleService.saveDraft(stale, preview: nil, for: profile, now: today, in: ctx)
        #expect(throws: PlanLifecycleService.Failure.raceDateInThePast) {
            try PlanLifecycleService.activate(stale, from: record, for: profile, now: today, in: ctx)
        }
        #expect(profile.plan?.id == currentID)
        #expect(profile.goal == .generalFitness)
        #expect(PlanLifecycleService.shelf(for: profile, in: ctx).count == 1)
        #expect(record.status == .draft)
    }

    @Test func schedulingRefusesTodayAndAcceptsTomorrow() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let record = try PlanLifecycleService.saveDraft(blueprint10K(profile), preview: nil, for: profile, now: today, in: ctx)
        #expect(throws: PlanLifecycleService.Failure.scheduleMustBeInTheFuture) {
            try PlanLifecycleService.schedule(record, start: today, now: today, in: ctx)
        }
        try PlanLifecycleService.schedule(record, start: day(1), now: today, in: ctx)
        #expect(record.status == .upcoming)
        #expect(record.scheduledStart.map { cal.isDate($0, inSameDayAs: day(1)) } == true)
        try PlanLifecycleService.moveToDrafts(record, now: today, in: ctx)
        #expect(record.status == .draft)
        #expect(record.scheduledStart == nil)
    }

    @Test func theCurrentPlanReportsAnOverlapForAScheduleInsideIt() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx, race: true)
        let span = try #require(PlanLifecycleService.currentSpan(for: profile))
        let overlap = try #require(PlanLifecycle.overlap(current: span, proposedStart: day(14)))
        #expect(overlap.cutsGoalRace)
        #expect(overlap.sessionsCut > 0)
        #expect(overlap.nextFreeStart > span.end!)
        // After the race there is nothing to cut.
        #expect(PlanLifecycle.overlap(current: span, proposedStart: day(7 * 12 + 1)) == nil)
    }

    // MARK: - Upcoming transitions

    @Test func anUpcomingPlanStartsOnItsDayExactlyOnce() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let oldID = try #require(profile.plan?.id)
        let record = try PlanLifecycleService.saveDraft(blueprint10K(profile), preview: nil, for: profile, now: day(-8), in: ctx)
        try PlanLifecycleService.schedule(record, start: day(-2), now: day(-8), in: ctx)

        // Not due yet the day before it was scheduled.
        #expect(PlanLifecycleService.activateDueUpcoming(for: profile, today: day(-3), in: ctx) == nil)
        #expect(profile.plan?.id == oldID)

        // Due: it starts TODAY (not backdated), the old plan goes to the shelf, the record is gone.
        let activation = try #require(PlanLifecycleService.activateDueUpcoming(for: profile, today: today, in: ctx))
        #expect(cal.isDate(activation.start, inSameDayAs: today))
        #expect(activation.scheduledStart.map { cal.isDate($0, inSameDayAs: day(-2)) } == true)
        #expect(profile.plan?.id == activation.plan.id)
        #expect(activation.plan.sessions.allSatisfy { $0.status == .completed || $0.date >= cal.startOfDay(for: today) })
        let shelf = PlanLifecycleService.shelf(for: profile, in: ctx)
        #expect(shelf.count == 1)
        #expect(shelf.first?.status == .incomplete)

        // A second sweep, a retry, another launch: nothing to do, nothing changes.
        let afterID = profile.plan?.id
        #expect(PlanLifecycleService.activateDueUpcoming(for: profile, today: today, in: ctx) == nil)
        #expect(PlanLifecycleService.activateDueUpcoming(for: profile, today: day(1), in: ctx) == nil)
        #expect(profile.plan?.id == afterID)
        #expect(try ctx.fetch(FetchDescriptor<TrainingPlan>()).count == 1)
        #expect(PlanLifecycleService.shelf(for: profile, in: ctx).count == 1)
    }

    @Test func twoDuePlansStartTheEarliestAndReturnTheOtherToDrafts() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let first = try PlanLifecycleService.saveDraft(blueprint10K(profile), preview: nil, for: profile, now: day(-9), in: ctx)
        try PlanLifecycleService.schedule(first, start: day(-4), now: day(-9), in: ctx)
        var other = blueprint10K(profile); other.name = "Half instead"; other.raceDistanceM = RaceDistance.half.meters
        other.raceDate = day(7 * 14)
        let second = try PlanLifecycleService.saveDraft(other, preview: nil, for: profile, now: day(-9), in: ctx)
        try PlanLifecycleService.schedule(second, start: day(-1), now: day(-9), in: ctx)

        let activation = try #require(PlanLifecycleService.activateDueUpcoming(for: profile, today: today, in: ctx))
        #expect(activation.plan.name == "Faster 10K")
        let shelf = PlanLifecycleService.shelf(for: profile, in: ctx)
        #expect(shelf.contains { $0.id == second.id && $0.status == .draft && $0.scheduledStart == nil })
        #expect(shelf.contains { $0.status == .incomplete })
        #expect(shelf.count == 2)
    }

    @Test func anUpcomingPlanWhoseRaceHasPassedReturnsToDraftsInsteadOfFailingEveryLaunch() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let currentID = try #require(profile.plan?.id)
        var stale = blueprint10K(profile); stale.raceDate = day(-1)
        let record = try PlanLifecycleService.saveDraft(stale, preview: nil, for: profile, now: day(-30), in: ctx)
        try PlanLifecycleService.schedule(record, start: day(-20), now: day(-30), in: ctx)
        #expect(PlanLifecycleService.activateDueUpcoming(for: profile, today: today, in: ctx) == nil)
        #expect(record.status == .draft)
        #expect(profile.plan?.id == currentID)
        #expect(PlanLifecycleService.activateDueUpcoming(for: profile, today: day(1), in: ctx) == nil)
    }

    // MARK: - Previous plans

    @Test func aFinishedRaceShelvesTheSeasonAsCompleted() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx, race: true)
        let plan = try #require(profile.plan)
        plan.name = "City Half"
        // Move the calendar past the race: retire through the same path Today's settle uses.
        let raceDay = try #require(profile.raceDate)
        let after = cal.date(byAdding: .day, value: 2, to: raceDay)!
        _ = PlanService.completeRace(for: profile, today: after, in: ctx)
        let shelf = PlanLifecycleService.shelf(for: profile, in: ctx)
        let done = try #require(shelf.first)
        #expect(done.status == .completed)
        #expect(done.name == "City Half")
        #expect(done.blueprint?.raceDistanceM == RaceDistance.half.meters)
        #expect(done.preview?.plannedSessions ?? 0 > 0)
        #expect(done.endedAt.map { cal.isDate($0, inSameDayAs: raceDay) } == true)
        #expect(try ctx.fetch(FetchDescriptor<TrainingPlan>()).count == 1)
    }

    @Test func renewingABlockShelvesTheClosingBlock() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let plan = try #require(profile.plan)
        let oldID = plan.id
        _ = PlanService.renewBlock(for: profile, startDate: day(42), in: ctx)
        let shelf = PlanLifecycleService.shelf(for: profile, in: ctx)
        #expect(shelf.count == 1)
        #expect(shelf.first?.status == .completed)
        #expect(shelf.first?.sourcePlanID == oldID)
        #expect(shelf.first?.name.contains("block 1") == true)
    }

    @Test func startAgainCopiesABlueprintIntoAFreshDraftWithoutAStaleRaceDay() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        var old = blueprint10K(profile); old.raceDate = day(-30)
        let previous = PlanShelfRecord(profileID: profile.id, status: .completed, name: "Old 10K",
                                       createdAt: day(-100), blueprintData: try JSONEncoder().encode(old))
        ctx.insert(previous); try ctx.save()
        let draft = try PlanLifecycleService.startAgain(previous, for: profile, now: today, in: ctx)
        #expect(draft.status == .draft)
        #expect(draft.blueprint?.raceDate == nil)
        #expect(draft.blueprint?.raceDistanceM == RaceDistance.tenK.meters)
        #expect(PlanLifecycleService.shelf(for: profile, in: ctx).count == 2)
    }

    @Test func previewFromASnapshotCountsWhatWasDone() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let plan = try #require(profile.plan)
        let runs = plan.sessions.filter { $0.discipline == .running }.sorted { $0.date < $1.date }
        runs.prefix(3).forEach { $0.status = .completed }
        let preview = PlanPreview.build(snapshot: CoachUndo.planState(of: plan),
                                        blueprint: PlanBlueprint(profile: profile), distanceUnit: .metric)
        #expect(preview.completedSessions == 3)
        #expect(preview.plannedSessions == plan.sessions.count)
        #expect(preview.weeks == PlanEngine.openBlockWeeks)
        #expect(preview.phases.reduce(0) { $0 + $1.weeks } == plan.weekPhases.count)
    }
}
