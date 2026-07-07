import Testing
import Foundation
import SwiftData
@testable import Momentum

/// End-to-end seam checks for the running stack (R1/R3/R4). These deliberately exercise the *real*
/// integration points — the plan engine's actual output feeding the guided-run builder, and the Pace
/// Insights reading real completed SwiftData sessions — rather than hand-built fixtures, to catch
/// "each piece works but they don't connect" failures.
@MainActor
struct RunningIntegrationTests {

    func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    // MARK: R1 — the plan the engine actually generates must be guidable

    @Test func planEngineIntervalSessionsExpandIntoGuidedWorkouts() throws {
        // A real 5K race plan, exactly as onboarding would build it.
        let race = Calendar.current.date(byAdding: .weekOfYear, value: 8, to: Date())
        let inputs = PlanInputs(disciplines: [.running], goal: .raceDistance, daysPerWeek: 4,
                                equipment: .fullGym, sessionMinutes: 45, raceDate: race,
                                runningExperience: .some, liftingExperience: .some, raceDistanceM: 5000)
        let plan = PlanEngine.generate(profile: inputs, catalog: [], startDate: Date())

        // The engine must schedule interval work for a 5K plan, and it must carry the reps string.
        let gen = try #require(plan.weeks.flatMap(\.sessions).first { $0.runType == .intervals },
                               "PlanEngine scheduled no interval sessions for a 5K race plan")
        let reps = try #require(gen.intervals, "Interval session carried no reps string to guide from")
        #expect(reps.contains("×") || reps.lowercased().contains("x"))

        // Mirror the generated session onto a PlannedSession (as PlanPersistence does) and guide it —
        // this is the exact object WorkoutRunner hands to StructuredWorkoutBuilder.
        let s = PlannedSession()
        s.discipline = .running
        s.runType = gen.runType
        s.targetDistanceM = gen.targetDistanceM
        s.targetPaceSPerKm = gen.targetPaceSPerKm
        s.intervals = gen.intervals
        let guided = try #require(StructuredWorkoutBuilder.build(from: s),
                                  "The engine's real interval session did NOT expand into a guided workout")
        #expect(guided.workStepCount >= 5)                 // 6×400 → 6 reps
        #expect(guided.steps.first?.kind == .warmup)
        #expect(guided.steps.last?.kind == .cooldown)
        // Every work rep inherits the engine's prescribed interval pace (not invented).
        #expect(guided.steps.filter { $0.kind == .work }.allSatisfy { $0.paceSPerKm == gen.targetPaceSPerKm })
    }

    @Test func longAndEasyRunsAreNotOverGuided() throws {
        // A plain easy run must NOT become a structured session (no false warm-up/rep overlay).
        let s = PlannedSession()
        s.discipline = .running; s.runType = .easy; s.targetPaceSPerKm = 380
        #expect(StructuredWorkoutBuilder.build(from: s) == nil)
    }

    // MARK: R4 — Pace Insights must read real completed sessions

    @Test func paceInsightsReadCompletedQualityRunsEndToEnd() throws {
        let container = try makeContainer()   // retain so the context doesn't dangle mid-test
        let ctx = container.mainContext
        let profile = UserProfile()
        let plan = TrainingPlan()
        ctx.insert(profile); ctx.insert(plan)
        profile.plan = plan

        // Two completed tempo sessions, each run ~4% slower than the 300 s/km target (1560 s / 5 km).
        var sessions: [PlannedSession] = []
        for _ in 0..<2 {
            let s = PlannedSession()
            s.discipline = .running; s.runType = .tempo; s.status = .completed; s.targetPaceSPerKm = 300
            let w = Workout(); w.type = .run; w.startedAt = Date(); w.durationS = 1560
            let gps = GPSDetail(); gps.distanceM = 5000; w.gps = gps
            s.completedWorkout = w
            ctx.insert(s); ctx.insert(w); ctx.insert(gps)
            sessions.append(s)
        }
        plan.sessions = sessions
        try ctx.save()

        // The real SwiftData query finds them and computes achieved pace correctly.
        let runs = PaceInsights.recentQualityRuns(plan)
        #expect(runs.count == 2)
        #expect(abs(runs[0].achievedPaceSPerKm - 312) < 1)     // 1560 / 5 km = 312 s/km

        // …and the classifier flags the targets as a touch hot (the signal auto-recalibration omits).
        #expect(PaceInsights.evaluate(runs).verdict == .review)
    }

    @Test func paceInsightsIgnoresEasyRunsAndStrength() throws {
        let container = try makeContainer()   // retain so the context doesn't dangle mid-test
        let ctx = container.mainContext
        let plan = TrainingPlan(); ctx.insert(plan)
        // A completed EASY run (slow by design) must never be read as a quality-pace signal.
        let easy = PlannedSession()
        easy.discipline = .running; easy.runType = .easy; easy.status = .completed; easy.targetPaceSPerKm = 380
        let w = Workout(); w.type = .run; w.startedAt = Date(); w.durationS = 2000
        let gps = GPSDetail(); gps.distanceM = 5000; w.gps = gps
        easy.completedWorkout = w
        ctx.insert(easy); ctx.insert(w); ctx.insert(gps)
        plan.sessions = [easy]
        try ctx.save()
        #expect(PaceInsights.recentQualityRuns(plan).isEmpty)
    }

    // MARK: R4 — the race projection lines up with the plan's own pace model

    @Test func racePredictionIsConsistentWithPlanPaces() {
        // The plan seeds a 25:00-5k athlete at p5k = 300 s/km; the predictor must return exactly that
        // 5k time (1500 s) and a slower-per-km 10k — proving predictor and pace-seeding are inverses.
        #expect(RacePredictor.finishTimeS(raceDistanceM: 5000, p5kSPerKm: 300) == 1500)
        let tenKPace = RacePredictor.projectedPaceSPerKm(raceDistanceM: 10000, p5kSPerKm: 300)!
        #expect(tenKPace > 300)
    }
}
