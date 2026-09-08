import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Wall-clock cost of the engine work behind the new plan and fuel flows (2026-09-07). The
/// numbers print so a run tells the story; the ceilings are loose (a debug build on a busy
/// machine) and exist to catch an order-of-magnitude regression, never to flake.
@MainActor
struct NewFlowsBenchmarkTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private let cal = Calendar.current
    private var today: Date { cal.date(bySettingHour: 10, minute: 0, second: 0, of: cal.startOfDay(for: Date()))! }
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

    /// A marathoner with strength on: the heaviest plan the builder previews.
    private func makeMarathoner(in ctx: ModelContext) -> UserProfile {
        let profile = UserProfile()
        profile.disciplines = [Discipline.running.rawValue, Discipline.strength.rawValue]
        profile.goal = .raceDistance
        profile.daysPerWeek = 6
        profile.weeklyRunVolumeM = 60_000
        profile.longestRunM = 25_000
        profile.experience = [Discipline.running.rawValue: ExperienceLevel.experienced.rawValue,
                              Discipline.strength.rawValue: ExperienceLevel.some.rawValue]
        profile.raceDistanceM = RaceDistance.marathon.meters
        profile.raceDate = day(7 * 18)
        ctx.insert(profile)
        try? ctx.save()
        PlanService.regenerate(for: profile, startDate: day(-3), in: ctx)
        return profile
    }

    private func timed(_ label: String, _ block: () throws -> Void) rethrows -> Double {
        let t0 = Date()
        try block()
        let ms = Date().timeIntervalSince(t0) * 1000
        print("⏱ \(label): \(String(format: "%.1f", ms)) ms")
        return ms
    }

    @Test func builderPreviewOfAnEighteenWeekMarathonPlan() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeMarathoner(in: ctx)
        var b = PlanBlueprint(profile: profile)
        b.name = "Berlin"
        _ = PlanLifecycleService.preview(for: b, profile: profile, startDate: today, in: ctx)   // warm
        let ms = timed("builder preview (18-week marathon, strength on)") {
            _ = PlanLifecycleService.preview(for: b, profile: profile, startDate: today, in: ctx)
        }
        #expect(ms < 400)
    }

    @Test func manageProposalThatRebuildsThePlan() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeMarathoner(in: ctx)
        let ms = timed("Manage proposal: change days (rebuild preview)") {
            _ = PlanAdjustmentService.proposal(.changeDays(daysPerWeek: 5, preferredDays: nil), title: "Days", request: "5 days",
                                               profile: profile, workouts: [], today: today, in: ctx)
        }
        #expect(ms < 400)
        let light = timed("Manage proposal: lighten this week") {
            _ = PlanAdjustmentService.proposal(.easeThisWeek, title: "Lighten", request: "heavy",
                                               profile: profile, workouts: [], today: today, in: ctx)
        }
        #expect(light < 100)
        let sig = timed("plan signature (x20)") {
            for _ in 0..<20 { _ = PlanAdjustmentService.signature(of: profile.plan) }
        }
        #expect(sig < 200)
    }

    @Test func shelfReadAndActivation() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeMarathoner(in: ctx)
        profile.plan?.sessions.first?.status = .completed
        try ctx.save()
        var b = PlanBlueprint(profile: profile)
        b.name = "Autumn 10K"; b.raceDistanceM = RaceDistance.tenK.meters; b.raceDate = day(7 * 10)
        let preview = PlanLifecycleService.preview(for: b, profile: profile, startDate: today, in: ctx)
        let record = try PlanLifecycleService.saveDraft(b, preview: preview, for: profile, in: ctx)
        let shelf = timed("shelf read + spans") {
            _ = PlanLifecycleService.shelf(for: profile, in: ctx)
            _ = PlanLifecycleService.currentSpan(for: profile)
        }
        #expect(shelf < 50)
        let activation = try timed("activate (retire + rebuild + save)") {
            _ = try PlanLifecycleService.activate(b, from: record, for: profile, now: today, in: ctx)
        }
        #expect(activation < 800)
    }

    @Test func fuelReadoutOverABusyJournal() throws {
        let c = try makeContainer(); let ctx = c.mainContext
        let profile = makeMarathoner(in: ctx)
        // 500 meals over 90 days, 6 today, most with numbers (the usuals population).
        for i in 0..<500 {
            let m = Meal()
            m.text = "meal \(i % 40)"
            m.eatenAt = cal.date(byAdding: .hour, value: -(i * 4), to: Date())!
            m.kcal = 400; m.carbsG = 50; m.proteinG = 20; m.fatG = 10
            m.source = i % 7 == 0 ? "manual" : "ai"
            ctx.insert(m)
        }
        try ctx.save()
        let meals = try ctx.fetch(FetchDescriptor<Meal>(sortBy: [SortDescriptor(\Meal.eatenAt, order: .reverse)]))
        let readout = timed("FuelReadoutBuilder.readout (today's slice of 500)") {
            _ = FuelReadoutBuilder.readout(meals: Array(meals.prefix(20)), plan: profile.plan, workouts: [], profile: profile, water: [], now: Date())
        }
        #expect(readout < 100)
        let usuals = timed("FuelLocalResolver.candidates (500 meals)") {
            _ = FuelLocalResolver.candidates(in: ctx)
        }
        #expect(usuals < 150)
        let titles = timed("journalTitle decode x500") {
            for m in meals { _ = m.journalTitle }
        }
        #expect(titles < 300)
    }
}
