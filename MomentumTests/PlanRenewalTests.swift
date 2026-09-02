import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Rolling-block renewal (`PlanService.renewBlock`): the "we'll see where you're at" checkpoint for
/// open-ended plans. Each renewal reassesses the athlete's ACTUAL recent running, regenerates one
/// fresh block from today, and advances the block counter. Dated-race plans never renew — they
/// periodize continuously to race day.
@MainActor
struct PlanRenewalTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private let cal = Calendar.current
    private var today: Date { cal.startOfDay(for: Date()) }
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

    /// A running profile with an existing open-ended plan (no race date).
    private func makeRollingProfile(in ctx: ModelContext) -> UserProfile {
        let profile = UserProfile()
        profile.disciplines = [Discipline.running.rawValue]
        profile.goal = .generalFitness
        profile.daysPerWeek = 4
        profile.weeklyRunVolumeM = 20_000
        let plan = TrainingPlan()
        plan.raceDate = nil
        plan.p5kSPerKm = 330
        ctx.insert(profile)
        ctx.insert(plan)
        // A lone past session so the plan is non-empty (renewal replaces it wholesale anyway).
        let s = PlannedSession()
        s.date = day(-2); s.discipline = .running; s.runType = .easy; s.status = .planned
        s.targetDistanceM = 6_000
        ctx.insert(s)
        plan.sessions = [s]
        profile.plan = plan
        try? ctx.save()
        return profile
    }

    private func logRun(_ meters: Double, at date: Date, in ctx: ModelContext) {
        let w = Workout()
        w.type = .run
        w.startedAt = date
        let gps = GPSDetail()
        gps.distanceM = meters
        w.gps = gps
        ctx.insert(gps)
        ctx.insert(w)
    }

    @Test func renewAdvancesTheBlockAndBuildsFromToday() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeRollingProfile(in: ctx)
        #expect(profile.plan?.blockIndex == 0)

        let renewed = PlanService.renewBlock(for: profile, startDate: today, in: ctx)
        #expect(renewed != nil)
        #expect(profile.plan?.blockIndex == 1)
        // A fresh full block, generated from today (no session earlier than today survives).
        #expect(profile.plan?.sessions.isEmpty == false)
        let earliest = profile.plan?.sessions.map(\.date).min()
        #expect(earliest != nil && earliest! >= today)
    }

    @Test func renewReassessesRecentRunningVolume() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeRollingProfile(in: ctx)
        // Four weeks of real running at ~40 km/week (10 km twice a week).
        for w in 0..<4 {
            logRun(10_000, at: day(-7 * w - 1), in: ctx)
            logRun(10_000, at: day(-7 * w - 3), in: ctx)
        }
        try? ctx.save()

        PlanService.renewBlock(for: profile, startDate: today, in: ctx)
        // 8 runs × 10 km ÷ 4 weeks = 20 km/week achieved → seeds the next block honestly.
        #expect(profile.weeklyRunVolumeM == 20_000)
    }

    @Test func recentVolumeIsNilWithoutLoggedDistance() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        _ = makeRollingProfile(in: ctx)
        #expect(PlanService.recentWeeklyRunVolumeM(endingAt: today, in: ctx) == nil)
    }

    @Test func rebuildingStartsFromCurrentLoggedFitnessNotTheOnboardingNumber() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeRollingProfile(in: ctx)
        profile.weeklyRunVolumeM = 8_000                 // stale signup answer
        profile.longestRunM = 4_000
        // Four settled weeks at 20 km/week. These are Momentum rows; Health never creates them.
        for week in 0..<4 {
            logRun(10_000, at: day(-7 * week - 1), in: ctx)
            logRun(10_000, at: day(-7 * week - 3), in: ctx)
        }
        try ctx.save()

        PlanService.rebuild(for: profile, startDate: today, in: ctx)

        let plan = try #require(profile.plan)
        let weekEnd = try #require(cal.date(byAdding: .day, value: 7, to: today))
        let firstWeekM = plan.sessions
            .filter { $0.discipline == .running && $0.date >= today && $0.date < weekEnd }
            .compactMap(\.targetDistanceM).reduce(0, +)
        #expect(firstWeekM > 15_000,
                "rebuild should start near the logged 20 km week, not the stale 8 km onboarding answer")
        #expect(profile.weeklyRunVolumeM == 8_000,
                "observed fitness is evidence for this build, not a rewrite of the athlete's saved answer")
    }

    @Test func establishedAthleteDoesNotRestartFromMonthsOldOnboardingPeak() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeRollingProfile(in: ctx)
        profile.createdAt = day(-180)
        profile.weeklyRunVolumeM = 70_000
        profile.longestRunM = 32_000
        try ctx.save()

        let current = PlanService.observedFitness(for: profile, on: today, in: ctx, calendar: cal)
        #expect(current.weeklyM == 8_000)
        #expect(current.longestM == nil)
    }

    @Test func establishedAthleteUsesRecentLongestRatherThanHistoricalDeclaredMaximum() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeRollingProfile(in: ctx)
        profile.createdAt = day(-180)
        profile.weeklyRunVolumeM = 70_000
        profile.longestRunM = 32_000
        logRun(10_000, at: day(-2), in: ctx)
        // This large run is outside the bounded evidence window and must not be faulted into the
        // current fitness decision.
        logRun(50_000, at: day(-100), in: ctx)
        try ctx.save()

        let current = PlanService.observedFitness(for: profile, on: today, in: ctx, calendar: cal)
        #expect(current.weeklyM == 8_000)
        #expect(current.longestM == 10_000)
    }

    @Test func invalidLegacyFitnessValuesCannotPoisonARebuild() {
        let snapshot = PlanFitnessEvidence.snapshot(
            runs: [
                PlanRunEvidence(startedAt: day(-2), distanceM: .infinity),
                PlanRunEvidence(startedAt: day(-3), distanceM: .nan)
            ],
            declaredWeeklyM: .infinity,
            declaredLongestM: -.infinity,
            profileCreatedAt: day(-180),
            endingAt: today,
            calendar: cal
        )

        #expect(snapshot.weeklyM == 8_000)
        #expect(snapshot.longestM == nil)
        #expect(snapshot.usesLoggedRuns == false)
    }

    @Test func everyRebuiltGoalRemainsARunningPlan() throws {
        for goal in Goal.allCases {
            let container = try makeContainer()
            let ctx = container.mainContext
            let profile = UserProfile()
            profile.goal = goal
            profile.disciplines = [Discipline.strength.rawValue]
            profile.daysPerWeek = 5
            ctx.insert(profile)

            PlanService.rebuild(for: profile, startDate: today, in: ctx)

            let sessions = try #require(profile.plan).sessions
            #expect(profile.disciplines.first == Discipline.running.rawValue,
                    "\(goal) did not retain running as the plan foundation")
            #expect(sessions.contains { $0.discipline == .running },
                    "\(goal) generated a coached plan without a run")
            #expect(sessions.contains { $0.discipline == .strength },
                    "\(goal) dropped selected supporting strength")
        }
    }

    @Test func legacyCardioBecomesTrackedCrossTrainingAroundTheRuns() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = UserProfile()
        profile.goal = .stayConsistent
        profile.disciplines = [Discipline.cycling.rawValue]
        profile.daysPerWeek = 4
        ctx.insert(profile)

        PlanService.rebuild(for: profile, startDate: today, in: ctx)

        #expect(profile.disciplines == [Discipline.running.rawValue])
        #expect(profile.crossTraining.contains(WorkoutType.ride.rawValue))
        let sessions = try #require(profile.plan).sessions
        #expect(sessions.contains { $0.discipline == .running })
        #expect(sessions.contains { $0.workoutType == .ride })
    }

    @Test func datedRacePlanNeverRenews() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeRollingProfile(in: ctx)
        profile.raceDate = cal.date(byAdding: .weekOfYear, value: 10, to: today)
        profile.plan?.raceDate = profile.raceDate
        let before = profile.plan?.blockIndex

        let renewed = PlanService.renewBlock(for: profile, startDate: today, in: ctx)
        #expect(renewed == nil)
        #expect(profile.plan?.blockIndex == before)   // untouched — races run to the line, not in blocks
    }
}
