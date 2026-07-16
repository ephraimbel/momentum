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
