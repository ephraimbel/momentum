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
        // The athlete trained on the current plan, so it is worth a Previous entry when replaced.
        profile.plan?.sessions.first?.status = .completed

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
        profile.plan?.sessions.first?.status = .completed   // trained on, so it is shelved when replaced

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

    // MARK: - Regressions (second pass)

    /// A throw AFTER the current plan was put on the shelf (the season command's validation runs
    /// once `retire` has inserted its record) must roll the shelf insert back with everything
    /// else: the athlete never sees a "previous plan" for a switch that did not happen.
    @Test func aFailureAfterTheShelfInsertRollsTheShelfBackToo() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let current = try #require(profile.plan)
        let currentID = current.id
        let sessionIDs = Set(current.sessions.map(\.id))
        // One completed session makes the current plan worth shelving, so `retire` runs first.
        let done = try #require(current.sessions.filter { $0.discipline == .running }.min { $0.date < $1.date })
        done.status = .completed
        try ctx.save()

        var broken = blueprint10K(profile)
        broken.goalFinishTimeS = 0   // clears the race-day pre-check, fails the command's validation
        let record = try PlanLifecycleService.saveDraft(broken, preview: nil, for: profile, now: today, in: ctx)
        #expect(try ctx.fetch(FetchDescriptor<PlanShelfRecord>()).count == 1)

        #expect(throws: (any Error).self) {
            try PlanLifecycleService.activate(broken, from: record, for: profile, now: today, in: ctx)
        }
        #expect(profile.plan?.id == currentID)
        #expect(Set(profile.plan?.sessions.map(\.id) ?? []) == sessionIDs)
        #expect(done.status == .completed)
        #expect(profile.goal == .generalFitness)
        #expect(profile.raceDistanceM == nil)
        #expect(try ctx.fetch(FetchDescriptor<TrainingPlan>()).count == 1)
        // The shelf holds the draft and nothing else: the retirement insert was rolled back.
        let shelf = try ctx.fetch(FetchDescriptor<PlanShelfRecord>())
        #expect(shelf.count == 1)
        #expect(shelf.first?.id == record.id)
        #expect(record.status == .draft)
        #expect(PlanLifecycleService.shelf(for: profile, in: ctx).allSatisfy { $0.status == .draft })
    }

    @Test func anEveningActivationStartsTomorrowNeverToday() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let evening = try #require(cal.date(bySettingHour: 21, minute: 0, second: 0, of: today))
        let tomorrow = cal.startOfDay(for: day(1))
        #expect(cal.isDate(PlanLifecycle.activationStart(now: evening), inSameDayAs: day(1)))

        let record = try PlanLifecycleService.saveDraft(blueprint10K(profile), preview: nil, for: profile, now: evening, in: ctx)
        let activation = try PlanLifecycleService.activate(try #require(record.blueprint), from: record,
                                                            for: profile, now: evening, in: ctx)
        #expect(cal.isDate(activation.start, inSameDayAs: day(1)))
        #expect(activation.plan.blockStart == tomorrow)
        let first = try #require(activation.plan.sessions.map(\.date).min())
        #expect(first >= tomorrow)
        #expect(!activation.plan.sessions.contains { cal.isDate($0.date, inSameDayAs: today) })
        #expect(activation.plan.sessions.allSatisfy { $0.date >= tomorrow })
        // Replaced within the day it was built, with nothing done: not history.
        #expect(activation.retired == nil)
        #expect(PlanLifecycleService.shelf(for: profile, in: ctx).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<TrainingPlan>()).count == 1)
    }

    /// The card and the plan can never disagree: the preview is read off the same generator
    /// output the activation persists, built from the blueprint's own fitness numbers.
    @Test func thePreviewIsThePlanTheActivationPersists() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        var b = blueprint10K(profile)
        b.weeklyRunVolumeM = 40_000    // the blueprint's own fitness, not the profile's 25 km
        b.longestRunM = 15_000
        let preview = PlanLifecycleService.preview(for: b, profile: profile, startDate: today, in: ctx)
        let record = try PlanLifecycleService.saveDraft(b, preview: preview, for: profile, now: today, in: ctx)
        let activation = try PlanLifecycleService.activate(b, from: record, for: profile, now: today, in: ctx)
        let plan = activation.plan
        let blockStart = try #require(plan.blockStart)
        #expect(profile.weeklyRunVolumeM == 40_000)

        func isRun(_ s: PlannedSession) -> Bool { s.discipline != .strength && s.runType != .race }
        var volumes: [Int: Double] = [:]
        var runs: [Int: Int] = [:]
        for s in plan.sessions where isRun(s) {
            let days = cal.dateComponents([.day], from: blockStart, to: cal.startOfDay(for: s.date)).day ?? 0
            volumes[days / 7, default: 0] += s.targetDistanceM ?? 0
            runs[days / 7, default: 0] += 1
        }
        #expect(preview.weeks == plan.weekPhases.count)
        #expect(preview.phases.reduce(0) { $0 + $1.weeks } == plan.weekPhases.count)
        #expect(preview.plannedSessions == plan.sessions.count)
        #expect(preview.peakWeekM > 0)
        #expect(abs(preview.peakWeekM - (volumes.values.max() ?? 0)) < 1)
        #expect(abs(preview.firstWeekM - (volumes[0] ?? 0)) < 1)
        let longest = plan.sessions.filter(isRun).compactMap(\.targetDistanceM).max() ?? 0
        #expect(preview.longestRunM == longest)
        #expect(preview.runsPerWeek >= 3)
        #expect(Set(runs.values).contains(preview.runsPerWeek))
    }

    /// A distance with no date on it is a rolling plan, not a race with a zero-week runway.
    @Test func anUndatedDistanceGoalPreviewsAsARollingPlanNotAZeroWeekRace() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        var b = PlanBlueprint(profile: profile)
        b.goal = .raceDistance
        b.raceDistanceM = RaceDistance.tenK.meters
        b.raceDate = nil
        b.daysPerWeek = 4
        #expect(b.isRace)
        #expect(b.raceDistance == .tenK)

        let outlook = PlanLifecycleService.feasibility(for: b, profile: profile, today: today)
        #expect(outlook.verdict == .noRace)
        #expect(outlook.weeksAvailable == 0)
        #expect(!outlook.headline.contains("0 week"))
        #expect(!outlook.detail.contains("0 week"))

        let preview = PlanLifecycleService.preview(for: b, profile: profile, startDate: today, in: ctx)
        #expect(preview.weeks == PlanEngine.openBlockWeeks)
        #expect(preview.outlook?.verdict == PlanFeasibility.Verdict.noRace.rawValue)
        #expect(preview.outlook?.isTooShort == false)
        #expect(preview.outlook?.detail.contains("0 week") == false)
        #expect(cal.dateComponents([.day], from: preview.startDate, to: preview.endDate).day
                == PlanEngine.openBlockWeeks * 7 - 1)
        #expect(preview.peakWeekM > 0)
        #expect(!preview.typicalWeek.isEmpty)
        let record = try PlanLifecycleService.saveDraft(b, preview: preview, for: profile, now: today, in: ctx)
        #expect(record.name == RaceDistance.tenK.label)
        #expect(record.blueprint?.raceDate == nil)
        #expect(record.preview?.weeks == PlanEngine.openBlockWeeks)
    }

    @Test func schedulingRebuildsTheCachedPreviewForTheScheduledDay() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let b = blueprint10K(profile)
        let raceDay = try #require(b.raceDate)
        let before = PlanLifecycleService.preview(for: b, profile: profile, startDate: today, in: ctx)
        #expect(before.startDate == cal.startOfDay(for: today))
        let record = try PlanLifecycleService.saveDraft(b, preview: before, for: profile, now: today, in: ctx)
        #expect(record.preview?.startDate == before.startDate)

        let start = day(7)
        try PlanLifecycleService.schedule(record, start: start, for: profile, now: today, in: ctx)
        let rebuilt = try #require(record.preview)
        #expect(record.status == .upcoming)
        #expect(rebuilt.startDate == cal.startOfDay(for: start))
        #expect(rebuilt.startDate != before.startDate)
        #expect(rebuilt.weeks == PlanEngine.weeksToGenerate(startDate: start, raceDate: raceDay, calendar: cal))
        #expect(rebuilt.weeks == before.weeks - 1)   // a week later to the same race day
        #expect(rebuilt.endDate == cal.startOfDay(for: raceDay))
        #expect(rebuilt.endDate >= rebuilt.startDate)
    }

    /// Finished work carried across a rebuild can sit before the block; the look-back preview
    /// counts weeks from the block's own day zero, never from that history or the retire day.
    @Test func aRetiredPlansPreviewIsAnchoredOnTheBlockStart() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let plan = try #require(profile.plan)
        let blockStart = try #require(plan.blockStart)
        #expect(blockStart == cal.startOfDay(for: today))
        let earlier = PlannedSession()
        earlier.date = day(-10)
        earlier.discipline = .running
        earlier.runType = .easy
        earlier.targetDistanceM = 5_000
        earlier.status = .completed
        ctx.insert(earlier)
        plan.sessions.append(earlier)
        try ctx.save()

        let state = CoachUndo.planState(of: plan)
        let blueprint = PlanBlueprint(profile: profile)
        let anchored = PlanPreview.build(snapshot: state, blueprint: blueprint, distanceUnit: .metric, anchor: blockStart)
        let unanchored = PlanPreview.build(snapshot: state, blueprint: blueprint, distanceUnit: .metric)
        #expect(anchored.startDate == blockStart)
        #expect(anchored.weeks == PlanEngine.openBlockWeeks)
        #expect(anchored.completedSessions == 1)
        #expect(unanchored.startDate == cal.startOfDay(for: day(-10)))
        #expect(unanchored.weeks > PlanEngine.openBlockWeeks)

        // The service retires through the same anchor.
        let retireDay = day(20)
        let record = PlanLifecycleService.retire(plan, of: profile, endedAt: retireDay, now: retireDay, in: ctx)
        try ctx.save()
        let preview = try #require(record.preview)
        #expect(preview.startDate == blockStart)
        #expect(record.startedAt == blockStart)
        #expect(preview.startDate != cal.startOfDay(for: retireDay))
        #expect(preview.startDate != cal.startOfDay(for: day(-10)))
        #expect(record.endedAt == cal.startOfDay(for: retireDay))
        #expect(preview.completedSessions == 1)
        #expect(preview.weeks == PlanEngine.openBlockWeeks)
    }

    @Test func schedulingAfterTheRaceDayIsRefused() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let b = blueprint10K(profile)
        let raceDay = try #require(b.raceDate)
        let record = try PlanLifecycleService.saveDraft(b, preview: nil, for: profile, now: today, in: ctx)
        let afterRace = try #require(cal.date(byAdding: .day, value: 1, to: raceDay))
        #expect(throws: PlanLifecycleService.Failure.startAfterRaceDay) {
            try PlanLifecycleService.schedule(record, start: afterRace, now: today, in: ctx)
        }
        #expect(record.status == .draft)
        #expect(record.scheduledStart == nil)
        // Any day before the race is still a day the plan can start on.
        let beforeRace = try #require(cal.date(byAdding: .day, value: -1, to: raceDay))
        try PlanLifecycleService.schedule(record, start: beforeRace, now: today, in: ctx)
        #expect(record.status == .upcoming)
        #expect(record.scheduledStart == cal.startOfDay(for: beforeRace))
    }

    /// The day-after settle runs on every launch; the second pass finds the race already behind
    /// them and shelves nothing twice.
    @Test func completingTheSameRaceTwiceShelvesItOnce() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx, race: true)
        let plan = try #require(profile.plan)
        plan.name = "City Half"
        try ctx.save()
        let raceDay = try #require(profile.raceDate)
        let after = try #require(cal.date(byAdding: .day, value: 2, to: raceDay))
        let later = try #require(cal.date(byAdding: .day, value: 1, to: after))

        #expect(PlanService.completeRace(for: profile, today: after, in: ctx) != nil)
        #expect(profile.raceDate == nil)
        #expect(profile.plan?.raceDate == nil)
        #expect(profile.plan?.blockIndex == 1)
        let firstPass = PlanLifecycleService.shelf(for: profile, in: ctx)
        #expect(firstPass.count == 1)
        #expect(firstPass.first?.status == .completed)
        #expect(firstPass.first?.name == "City Half")

        #expect(PlanService.completeRace(for: profile, today: after, in: ctx) == nil)
        #expect(PlanService.completeRace(for: profile, today: later, in: ctx) == nil)
        let secondPass = PlanLifecycleService.shelf(for: profile, in: ctx)
        #expect(secondPass.count == 1)
        #expect(secondPass.first?.id == firstPass.first?.id)
        #expect(secondPass.filter { $0.status == .completed }.count == 1)
        #expect(profile.plan?.blockIndex == 1)
        #expect(try ctx.fetch(FetchDescriptor<TrainingPlan>()).count == 1)
    }

    /// Stored JSON outlives the code that wrote it: keys added later decode to their defaults.
    @Test func storedBlueprintsAndPreviewsDecodeWithoutNewerKeys() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        var b = blueprint10K(profile)
        b.raceDate = nil                 // keeps the fixture free of Date round-trips
        b.weeklyRunVolumeM = 40_000
        b.isSelfCoached = true
        let encoded = try JSONEncoder().encode(b)
        let json = try JSONSerialization.jsonObject(with: encoded)
        var object = try #require(json as? [String: Any])
        #expect(object["weeklyRunVolumeM"] != nil)
        #expect(object["isSelfCoached"] != nil)
        object.removeValue(forKey: "weeklyRunVolumeM")
        object.removeValue(forKey: "isSelfCoached")
        object.removeValue(forKey: "strengthSplit")
        object.removeValue(forKey: "muscleFocus")
        let trimmed = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(PlanBlueprint.self, from: trimmed)
        var expected = b
        expected.weeklyRunVolumeM = nil
        expected.isSelfCoached = false
        expected.strengthSplit = .coach
        expected.muscleFocus = []
        #expect(decoded == expected)
        #expect(decoded.raceDistanceM == RaceDistance.tenK.meters)
        // An empty object is a blueprint too: every key has a default.
        let bare = try JSONDecoder().decode(PlanBlueprint.self, from: Data("{}".utf8))
        #expect(bare == PlanBlueprint())

        let preview = PlanLifecycleService.preview(for: blueprint10K(profile), profile: profile, startDate: today, in: ctx)
        let previewEncoded = try JSONEncoder().encode(preview)
        let previewJSON = try JSONSerialization.jsonObject(with: previewEncoded)
        var previewObject = try #require(previewJSON as? [String: Any])
        #expect(previewObject["crossTrainingPerWeek"] != nil)
        previewObject.removeValue(forKey: "crossTrainingPerWeek")
        let previewTrimmed = try JSONSerialization.data(withJSONObject: previewObject)
        let old = try JSONDecoder().decode(PlanPreview.self, from: previewTrimmed)
        #expect(old.crossTrainingPerWeek == 0)
        #expect(old.weeks == preview.weeks)
        #expect(old.runsPerWeek == preview.runsPerWeek)
        #expect(old.plannedSessions == preview.plannedSessions)
        #expect(abs(old.peakWeekM - preview.peakWeekM) < 1)
        #expect(old.outlook?.verdict == preview.outlook?.verdict)
        let minimal = try JSONDecoder().decode(PlanPreview.self, from: Data(#"{"weeks":4}"#.utf8))
        #expect(minimal.weeks == 4)
        #expect(minimal.crossTrainingPerWeek == 0)
        #expect(minimal.typicalWeek.isEmpty)
    }

    /// The runner-up's demotion rides inside the activation's save: a fresh context reads it back.
    @Test func theDemotionOfTheOtherDuePlanIsPersistedWithTheActivation() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let profileID = profile.id
        let first = try PlanLifecycleService.saveDraft(blueprint10K(profile), preview: nil, for: profile, now: day(-9), in: ctx)
        try PlanLifecycleService.schedule(first, start: day(-2), now: day(-9), in: ctx)
        var other = blueprint10K(profile); other.name = "Half instead"; other.raceDistanceM = RaceDistance.half.meters
        other.raceDate = day(7 * 14)
        let second = try PlanLifecycleService.saveDraft(other, preview: nil, for: profile, now: day(-9), in: ctx)
        try PlanLifecycleService.schedule(second, start: day(-1), now: day(-9), in: ctx)
        let firstID = first.id, secondID = second.id

        let activation = try #require(PlanLifecycleService.activateDueUpcoming(for: profile, today: today, in: ctx))
        #expect(activation.plan.name == "Faster 10K")
        #expect(second.status == .draft)
        #expect(second.scheduledStart == nil)

        // What the store holds, read through a context that saw none of the in-memory objects.
        let fresh = ModelContext(c)
        let shelf = PlanShelfRecord.fetch(profileID: profileID, in: fresh)
        let demoted = try #require(shelf.first { $0.id == secondID })
        #expect(demoted.status == .draft)
        #expect(demoted.scheduledStart == nil)
        #expect(demoted.name == "Half instead")
        #expect(!shelf.contains { $0.id == firstID })
        #expect(!shelf.contains { $0.status == .upcoming })
        let plans = try fresh.fetch(FetchDescriptor<TrainingPlan>())
        #expect(plans.count == 1)
        #expect(plans.first?.name == "Faster 10K")
        let profiles = try fresh.fetch(FetchDescriptor<UserProfile>())
        #expect(profiles.count == 1)
        #expect(profiles.first?.plan?.name == "Faster 10K")
        #expect(PlanLifecycleService.activateDueUpcoming(for: profile, today: today, in: ctx) == nil)
    }

    /// Today's settle order the morning after a race: races settle first (the finished season
    /// goes to the shelf as completed), then the plan scheduled for that day takes over.
    @Test func theDayAfterTheRaceTheUpcomingPlanTakesOverAndTheRaceIsShelvedCompleted() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx, race: true)
        let racePlan = try #require(profile.plan)
        let racePlanID = racePlan.id
        racePlan.name = "City Half"
        try ctx.save()
        let raceDay = try #require(profile.raceDate)
        let dayAfter = try #require(cal.date(byAdding: .day, value: 1, to: raceDay))

        // Scheduled weeks ago to start the day after the race.
        var next = blueprint10K(profile)
        next.raceDate = cal.date(byAdding: .day, value: 70, to: dayAfter)
        let record = try PlanLifecycleService.saveDraft(next, preview: nil, for: profile, now: day(60), in: ctx)
        try PlanLifecycleService.schedule(record, start: dayAfter, now: day(60), in: ctx)

        #expect(PlanService.settleRaces(for: profile, today: dayAfter, in: ctx) != nil)
        #expect(profile.raceDate == nil)
        let activation = try #require(PlanLifecycleService.activateDueUpcoming(for: profile, today: dayAfter, in: ctx))
        #expect(cal.isDate(activation.start, inSameDayAs: dayAfter))
        #expect(activation.plan.name == "Faster 10K")
        #expect(profile.plan?.id == activation.plan.id)
        #expect(profile.raceDistanceM == RaceDistance.tenK.meters)
        #expect(activation.retired == nil)   // the block built moments earlier is not history

        let shelf = PlanLifecycleService.shelf(for: profile, in: ctx)
        #expect(shelf.count == 1)
        let done = try #require(shelf.first)
        #expect(done.status == .completed)
        #expect(done.name == "City Half")
        #expect(done.sourcePlanID == racePlanID)
        #expect(done.endedAt.map { cal.isDate($0, inSameDayAs: raceDay) } == true)
        #expect(try ctx.fetch(FetchDescriptor<TrainingPlan>()).count == 1)
    }

    @Test func retiringASelfCoachedPlanNamesTheRecordSelfCoached() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let plan = try #require(profile.plan)
        plan.isSelfCoached = true
        plan.name = ""
        try ctx.save()
        let record = PlanLifecycleService.retire(plan, of: profile, endedAt: day(10), now: day(10), in: ctx)
        try ctx.save()
        #expect(record.name.contains("Self-coached"))
        #expect(record.name.contains("block 1"))
        #expect(record.blueprint?.isSelfCoached == true)
        #expect(record.sourcePlanID == plan.id)
        #expect(record.status == .incomplete)
        #expect(PlanLifecycleService.shelf(for: profile, in: ctx).first?.name.contains("Self-coached") == true)
    }

    /// The same title when the self-coached plan is replaced through the activation path.
    @Test func activatingOverASelfCoachedPlanShelvesItUnderItsOwnName() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let plan = try #require(profile.plan)
        plan.isSelfCoached = true
        plan.name = ""
        let done = try #require(plan.sessions.filter { $0.discipline == .running }.min { $0.date < $1.date })
        done.status = .completed   // worth shelving
        try ctx.save()
        let record = try PlanLifecycleService.saveDraft(blueprint10K(profile), preview: nil, for: profile, now: today, in: ctx)
        let activation = try PlanLifecycleService.activate(try #require(record.blueprint), from: record,
                                                            for: profile, now: today, in: ctx)
        let retired = try #require(activation.retired)
        #expect(retired.name.contains("Self-coached"))
        #expect(retired.blueprint?.isSelfCoached == true)
        #expect(activation.plan.isSelfCoached == false)
        #expect(activation.plan.name == "Faster 10K")
        #expect(try ctx.fetch(FetchDescriptor<TrainingPlan>()).count == 1)
    }
    @Test func anUnreadableDraftCannotBeScheduled() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let record = PlanShelfRecord(profileID: profile.id, status: .draft, name: "Broken",
            createdAt: today, blueprintData: Data("broken".utf8))
        ctx.insert(record); try ctx.save()
        #expect(throws: PlanLifecycleService.Failure.unreadableBlueprint) {
            try PlanLifecycleService.schedule(record, start: day(1), now: today, in: ctx)
        }
        #expect(record.status == .draft)
        #expect(record.scheduledStart == nil)
    }

    @Test func anotherAthletesDraftCannotBeActivatedOrScheduled() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeProfile(in: ctx)
        let other = UserProfile(); ctx.insert(other)
        let blueprint = PlanBlueprint(profile: profile)
        let record = try PlanLifecycleService.saveDraft(blueprint, preview: nil, for: profile, in: ctx)
        #expect(throws: PlanLifecycleService.Failure.notShelved) {
            try PlanLifecycleService.activate(blueprint, from: record, for: other, now: today, in: ctx)
        }
        #expect(throws: PlanLifecycleService.Failure.notShelved) {
            try PlanLifecycleService.schedule(record, start: day(1), for: other, now: today, in: ctx)
        }
        #expect(record.status == .draft)
        #expect(other.plan == nil)
    }

}


extension PlanLifecycleTests {
    /// Six distinct ability/current-load profiles × four road distances × two availability budgets.
    /// These exercise the actual preview and persisted activation, not a hand-built schedule.
    @Test(arguments: Array(0..<48))
    func runnerCohortPreviewActivationMatrix(_ scenario: Int) throws {
        let cohorts: [(ExperienceLevel, Double, Double, Double, Int)] = [
            (.new, 0, 0, 480, 3), (.some, 0, 0, 360, 3),
            (.some, 20_000, 8_000, 330, 4), (.experienced, 40_000, 16_000, 270, 5),
            (.experienced, 65_000, 24_000, 235, 6), (.experienced, 90_000, 30_000, 210, 6)]
        let cohort = cohorts[scenario / 8], distance = [5_000.0, 10_000, 21_097.5, 42_195][(scenario / 2) % 4]
        let limited = scenario % 2 == 1
        let c = try makeContainer(), ctx = c.mainContext, p = UserProfile(), current = TrainingPlan()
        p.createdAt = day(-180); p.disciplines = [Discipline.running.rawValue]
        p.weeklyRunVolumeM = 70_000; p.longestRunM = 30_000
        current.p5kSPerKm = cohort.3; ctx.insert(p); ctx.insert(current); p.plan = current
        var b = PlanBlueprint(profile: p)
        b.goal = .raceDistance; b.raceDistanceM = distance; b.raceDate = day(distance > 40_000 ? 140 : 112)
        b.weeklyRunVolumeM = cohort.1; b.longestRunM = cohort.2; b.runningExperience = cohort.0
        b.daysPerWeek = cohort.4; b.fitnessDeclaredAt = today.addingTimeInterval(-60)
        if limited {
            b.targetWeeklyRunVolumeM = max(10_000, cohort.1 * 0.8)
            let prefs = PlanPreferencesRecord.upsert(profileID: p.id, in: ctx)
            prefs.regularRunLimitS = 30 * 60; prefs.longRunLimitS = 60 * 60
        }
        try ctx.save()
        let staged = PlanService.stagePreview(blueprint: b, for: p, startDate: today, in: ctx)
        #expect(staged.inputs.currentWeeklyVolumeM == cohort.1)
        #expect(staged.inputs.longestRunM == cohort.2)
        let validation = LegacyPlanInvariantValidator.validate(staged.generated, inputs: staged.inputs,
            calibration: CalibrationSeed(estimatedP5kSPerKm: cohort.3), startDate: today)
        #expect(validation.isValid, "scenario \(scenario): \(validation.hardViolations.map(\.code))")
        let preview = PlanLifecycleService.preview(for: b, profile: p, startDate: today, today: today, in: ctx)
        let activated = try PlanLifecycleService.activate(b, for: p, now: today, in: ctx).plan
        let rows = activated.sessions.filter { $0.discipline == .running && $0.runType != .race }
        let blockStart = try #require(activated.blockStart)
        let volumes = Dictionary(grouping: rows) {
            (cal.dateComponents([.day], from: blockStart, to: $0.date).day ?? 0) / 7
        }.mapValues { $0.reduce(0.0) { $0 + ($1.targetDistanceM ?? 0) } }
        #expect(abs(preview.firstWeekM - (volumes[0] ?? 0)) < 1)
        #expect(abs(preview.peakWeekM - (volumes.values.max() ?? 0)) < 1)
        #expect(preview.longestRunM == rows.compactMap(\.targetDistanceM).max())
        #expect(activated.sessions.filter { $0.runType == .race }.count == 1)
        #expect(activated.sessions.first { $0.runType == .race }?.targetDistanceM == distance)
        #expect(activated.weekPhases.last == PlanPhase.taper.rawValue)
        if let ceiling = b.targetWeeklyRunVolumeM { #expect(preview.peakWeekM <= ceiling + 1) }
        if limited {
            for run in rows {
                let seconds = FuelingGuide.estimatedDurationS(distanceM: run.targetDistanceM,
                    paceSPerKm: run.targetPaceSPerKm, durationS: run.targetDurationS) ?? 0
                #expect(seconds <= (run.runType == .long ? 3_600 : 1_800) + 1)
            }
        }
        let after = PlanService.observedFitness(for: p, on: today, in: ctx)
        #expect(after.weeklyM == cohort.1 && after.longestM == cohort.2)
    }

    @Test func freshFitnessAnswersClearOldMileageAndSurviveUndoAndCloudRestore() throws {
        let c = try makeContainer(), ctx = c.mainContext, p = makeProfile(in: ctx)
        p.createdAt = day(-180)
        _ = logRun(25_000, at: day(-5), for: p, in: ctx)
        var b = PlanBlueprint(profile: p)
        b.weeklyRunVolumeM = 0; b.longestRunM = 0; b.fitnessDeclaredAt = today.addingTimeInterval(-60)
        try PlanMutation.perform(in: ctx) { b.apply(to: p) }
        let zero = PlanService.observedFitness(for: p, on: today, in: ctx)
        #expect(zero.weeklyM == 0 && zero.longestM == 0)
        let saved = try #require(CoachUndo.capture(p))
        var unknown = b; unknown.weeklyRunVolumeM = nil; unknown.longestRunM = nil
        unknown.fitnessDeclaredAt = today
        try PlanMutation.perform(in: ctx) { unknown.apply(to: p) }
        let unclear = PlanService.observedFitness(for: p, on: today, in: ctx)
        #expect(unclear.weeklyM == nil && unclear.longestM == nil)
        #expect(CoachUndo.restore(saved, profile: p, in: ctx))
        #expect(p.weeklyRunVolumeM == 0 && p.longestRunM == 0 && p.fitnessDeclaredAt == b.fitnessDeclaredAt)
        let snapshot = try PlanCloudSnapshot.capture(p, in: ctx)
        let destination = try makeContainer()
        let restored = try PlanMutation.perform(in: destination.mainContext) { try snapshot.restore(in: destination.mainContext) }
        #expect(restored.fitnessDeclaredAt == b.fitnessDeclaredAt)
        let restoredFitness = PlanService.observedFitness(for: restored, on: today, in: destination.mainContext)
        #expect(restoredFitness.weeklyM == 0 && restoredFitness.longestM == 0)
    }

    @Test func recoveryEvidenceIsIdenticalInWorkerPreviewAndRebuild() async throws {
        let c = try makeContainer(), ctx = c.mainContext, p = makeProfile(in: ctx)
        p.createdAt = day(-180)
        _ = logRun(30_000, at: day(-5), for: p, in: ctx)
        let marker = PlanContinuityRecord.upsert(profileID: p.id, in: ctx)
        marker.trainingEvidenceFrom = day(-2)
        _ = logRun(2_000, at: day(-1), for: p, in: ctx)
        var b = PlanBlueprint(profile: p)
        b.weeklyRunVolumeM = 80_000; b.longestRunM = 30_000; b.fitnessDeclaredAt = today
        try PlanMutation.perform(in: ctx) { b.apply(to: p) }
        let worker = PlanFitnessWorker(modelContainer: c)
        let read = try await worker.snapshot(declaredWeeklyM: p.weeklyRunVolumeM, declaredLongestM: p.longestRunM,
            profileCreatedAt: p.createdAt, trainingEvidenceFrom: marker.trainingEvidenceFrom,
            declaredAt: p.fitnessDeclaredAt, endingAt: today)
        let staged = PlanService.stagePreview(blueprint: b, for: p, startDate: today, in: ctx)
        let actual = PlanService.observedFitness(for: p, on: today, in: ctx)
        #expect(read.weeklyM == 500 && read.longestM == 2_000 && read.usesLoggedRuns)
        #expect(staged.inputs.currentWeeklyVolumeM == read.weeklyM && staged.inputs.longestRunM == read.longestM)
        #expect(actual.weeklyM == read.weeklyM && actual.longestM == read.longestM)
    }

    @Test func scheduledPreviewCountsOnlyTrainingAfterItsStart() throws {
        let c = try makeContainer(), ctx = c.mainContext, p = makeProfile(in: ctx)
        let b = blueprint10K(p), start = day(49)
        let preview = PlanLifecycleService.preview(for: b, profile: p, startDate: start, today: today, in: ctx)
        let fitness = PlanService.stagePreview(blueprint: b, for: p, startDate: start, in: ctx).inputs.currentWeeklyVolumeM
        let expected = PlanLifecycleService.feasibility(for: b, profile: p, today: start, currentWeeklyM: fitness)
        #expect(preview.outlook?.verdict == expected.verdict.rawValue)
        #expect(preview.outlook?.realisticFinishS == expected.realisticFinishS)
    }

    @Test func v8StoreUpgradesAndKeepsFreshDeclarationsOnReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("upgrade.store"), id = UUID()
        do {
            let schema = Schema(versionedSchema: SchemaV8.self)
            let c = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let p = UserProfile(); p.id = id; p.weeklyRunVolumeM = 0
            c.mainContext.insert(p); try c.mainContext.save()
        }
        do {
            let schema = Schema(versionedSchema: SchemaV9.self)
            let c = try ModelContainer(for: schema, migrationPlan: MomentumMigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema, url: url)])
            let p = try #require(try c.mainContext.fetch(FetchDescriptor<UserProfile>()).first)
            #expect(p.id == id && p.weeklyRunVolumeM == 0)
            PlanFitnessDeclarationRecord.set(today, for: p, in: c.mainContext); try c.mainContext.save()
        }
        let schema = Schema(versionedSchema: SchemaV9.self)
        let c = try ModelContainer(for: schema, migrationPlan: MomentumMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: url)])
        let p = try #require(try c.mainContext.fetch(FetchDescriptor<UserProfile>()).first)
        #expect(p.fitnessDeclaredAt == today)
    }
}


extension PlanLifecycleTests {
    @Test func currentVolumeChangesTheStartingDoseAndZeroNeverUsesExperiencedDefaults() throws {
        let c = try makeContainer(), ctx = c.mainContext, p = makeProfile(in: ctx)
        p.createdAt = day(-180)
        var b = blueprint10K(p)
        b.runningExperience = .experienced; b.daysPerWeek = 5
        b.fitnessDeclaredAt = today.addingTimeInterval(-60)
        b.weeklyRunVolumeM = 20_000; b.longestRunM = 8_000
        let regular = PlanService.stagePreview(blueprint: b, for: p, startDate: today, in: ctx).generated
        b.weeklyRunVolumeM = 65_000; b.longestRunM = 24_000
        let highVolume = PlanService.stagePreview(blueprint: b, for: p, startDate: today, in: ctx).generated
        #expect(highVolume.weeks[0].runVolumeM > regular.weeks[0].runVolumeM)
        b.weeklyRunVolumeM = 0; b.longestRunM = 0
        let returning = PlanService.stagePreview(blueprint: b, for: p, startDate: today, in: ctx).generated
        #expect(returning.weeks[0].runVolumeM < regular.weeks[0].runVolumeM)
        #expect(returning.weeks[0].sessions.filter { $0.discipline == .running }.allSatisfy { !$0.isHardRun })
        #expect(returning.weeks[0].sessions.contains { ($0.intervals ?? "").contains("Run/walk") })
        #expect(returning.p5kSPerKm == regular.p5kSPerKm, "Experience and mileage are not a new measured race result.")
    }

    @Test func freshDeclarationsExpireAndDeletionRemovesTheirProvenance() async throws {
        let c = try makeContainer(), ctx = c.mainContext, p = makeProfile(in: ctx)
        p.createdAt = day(-180); p.weeklyRunVolumeM = 65_000; p.longestRunM = 25_000
        PlanFitnessDeclarationRecord.set(today, for: p, in: ctx); try ctx.save()
        #expect(PlanService.observedFitness(for: p, on: today, in: ctx).weeklyM == 65_000)
        #expect(PlanService.observedFitness(for: p, on: day(60), in: ctx).weeklyM == 8_000)
        try await DataManager.deleteAllUserData(container: c)
        #expect(try ctx.fetchCount(FetchDescriptor<PlanFitnessDeclarationRecord>()) == 0)
    }
}
