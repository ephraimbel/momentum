import Testing
import Foundation
import SwiftData
@testable import Momentum

/// The delight-wave info cards (race predictor, today briefing, zones) and the new proactive
/// moments (race week, PR celebration) — every number from the athlete's own data.
@MainActor
struct CoachInfoCardsTests {

    func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private let cal = Calendar.current
    private var today: Date { cal.startOfDay(for: Date()) }
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

    private func makeProfile(in ctx: ModelContext, p5k: Double = 300) -> UserProfile {
        let profile = UserProfile()
        let plan = TrainingPlan()
        plan.p5kSPerKm = p5k
        ctx.insert(profile)
        ctx.insert(plan)
        profile.plan = plan
        try? ctx.save()
        return profile
    }

    // MARK: Race predictor

    @Test func predictorDerivesEquivalentTimesFromCalibratedFitness() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx, p5k: 300)   // a 25:00 5K runner

        let sections = CoachRacePredictor.sections(profile: profile)
        // Every race + the ultra honesty line + the how-to-read line.
        #expect(sections.count == RaceDistance.allCases.count + 2)
        let fiveK = sections.first { $0.title == "5K" }
        #expect(fiveK?.detail.contains("25:00") == true)             // race pace at 5K ≈ p5k itself
        let marathon = sections.first { $0.title == "Marathon" }
        #expect(marathon != nil)
        // The 50K number never stands alone — the endurance-tax caveat rides with it.
        #expect(sections.contains { $0.title == "About the ultra number" })

        // No calibrated fitness → no invented numbers.
        let empty = UserProfile()
        ctx.insert(empty)
        #expect(CoachRacePredictor.sections(profile: empty).isEmpty)
    }

    /// The coach quotes the SAME predictions Progress shows — one model, one truth. This card once
    /// ran its own Daniels-curve derivation and double-taxed the long day: the coach's 50K came
    /// out ~13 min slower than the identical athlete's Progress card (owner caught it 2026-07-30).
    @Test func predictorCardMatchesRacePredictorOnEveryDistance() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx, p5k: 372)   // ~a 4:2x-marathon athlete — the reported case

        let sections = CoachRacePredictor.sections(profile: profile)
        for race in RaceDistance.allCases {
            let expected = try #require(RacePredictor.finishTimeS(raceDistanceM: race.meters,
                                                                  p5kSPerKm: 372))
            let row = try #require(sections.first { $0.title == race.label })
            #expect(row.detail.contains(PlanFeasibility.hms(expected)),
                    "\(race.label) row (\(row.detail)) disagrees with RacePredictor (\(PlanFeasibility.hms(expected)))")
        }
    }

    // MARK: Today briefing

    @Test func briefingDescribesTheSessionAndItsStructure() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)
        profile.maxHR = 190

        let session = PlannedSession()
        session.date = today
        session.discipline = .running
        session.runType = .intervals
        session.status = .planned
        session.targetDistanceM = 5_000
        session.targetPaceSPerKm = 280
        session.intervals = "6x400m @ I"
        ctx.insert(session)
        profile.plan?.sessions.append(session)
        try? ctx.save()

        let sections = CoachTodayBriefing.sections(profile: profile, today: today)
        let all = sections.map { "\($0.title): \($0.detail)" }.joined(separator: " | ")
        #expect(all.contains("The session"))
        #expect(all.contains("How it runs"))     // structured steps summarized
        #expect(all.contains("6×"))              // the rep group survived the summary
        #expect(all.contains("Effort"))          // HR target present with maxHR set
    }

    @Test func briefingOnARestDayPointsAtWhatsNext() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)
        let next = PlannedSession()
        next.date = day(2)
        next.discipline = .running
        next.runType = .easy
        next.status = .planned
        next.targetDistanceM = 8_000
        ctx.insert(next)
        profile.plan?.sessions.append(next)
        try? ctx.save()

        let sections = CoachTodayBriefing.sections(profile: profile, today: today)
        #expect(sections.first?.title == "Rest day")
        #expect(sections.contains { $0.title == "Up next" })
    }

    // MARK: Zones

    @Test func zonesComeFromMaxHRAndPacesFromFitness() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)
        profile.maxHR = 190
        profile.restingHR = 50
        try? ctx.save()

        let sections = CoachZones.sections(profile: profile)
        #expect(sections.count == 6)                                   // five zones + training paces
        #expect(sections.first?.title.hasPrefix("Z1") == true)
        #expect(sections.last?.title == "Training paces")
        #expect(sections.last?.detail.contains("Easy") == true)

        // No max HR → the honest ask, plus paces still derived from fitness.
        profile.maxHR = nil
        let without = CoachZones.sections(profile: profile)
        #expect(without.first?.detail.contains("max heart rate") == true)
        #expect(without.contains { $0.title == "Training paces" })
    }

    // MARK: Proactive — the post-onboarding introduction

    @Test func planIntroSeedsExactlyOnce() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        #expect(CoachProactive.seedPlanIntro(in: ctx))
        var intros = (try? ctx.fetch(FetchDescriptor<ChatMessage>()))?.filter { $0.card?.kind == .explainPlan } ?? []
        #expect(intros.count == 1)
        #expect(CoachProactive.seedPlanIntro(in: ctx) == false)   // once ever, whatever its state
        intros = (try? ctx.fetch(FetchDescriptor<ChatMessage>()))?.filter { $0.card?.kind == .explainPlan } ?? []
        #expect(intros.count == 1)
    }

    // MARK: Proactive — race week and PR celebration

    @Test func raceWeekSeedsThePlanCardOncePerDay() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)
        profile.raceDate = day(2)                       // inside the 0...3 briefing window
        profile.raceDistanceM = 10_000
        try? ctx.save()

        CoachProactive.sweep(profile: profile, workouts: [], today: today, in: ctx)
        var seeds = (try? ctx.fetch(FetchDescriptor<ChatMessage>()))?.filter { $0.card?.kind == .racePlan } ?? []
        #expect(seeds.count == 1)

        CoachProactive.sweep(profile: profile, workouts: [], today: today, in: ctx)
        seeds = (try? ctx.fetch(FetchDescriptor<ChatMessage>()))?.filter { $0.card?.kind == .racePlan } ?? []
        #expect(seeds.count == 1)                       // same day → no repeat
    }

    @Test func prCelebrationSeedsOnceOnTheDay() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)
        let pr = PersonalRecord()
        pr.type = .fastest5k
        pr.value = 1_450
        pr.achievedAt = today
        ctx.insert(pr)
        profile.prs.append(pr)
        try? ctx.save()

        CoachProactive.sweep(profile: profile, workouts: [], today: today, in: ctx)
        let celebrations = (try? ctx.fetch(FetchDescriptor<ChatMessage>()))?
            .filter { $0.role == .coach && $0.text.contains("personal record") } ?? []
        #expect(celebrations.count == 1)

        CoachProactive.sweep(profile: profile, workouts: [], today: today, in: ctx)
        let after = (try? ctx.fetch(FetchDescriptor<ChatMessage>()))?
            .filter { $0.role == .coach && $0.text.contains("personal record") } ?? []
        #expect(after.count == 1)                       // one win, one cheer
    }
}
