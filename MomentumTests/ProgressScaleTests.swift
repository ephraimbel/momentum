import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Scale tripwire for the Progress cold-open pipeline (user call 2026-08-06: the page must load
/// fast "regardless" as histories grow). Seeds three years of a heavy user's training IN MEMORY —
/// ~1,500 workouts, GPS scalars populated, strength sessions with sets — and times the same engine
/// walks `refreshAggregates` runs. The budget is deliberately generous (simulator/CI variance);
/// what it catches is a linear pass turning quadratic or a new relationship fault sneaking into a
/// hot loop — those blow through it by an order of magnitude.
struct ProgressScaleTests {

    @MainActor
    private func heavyHistory(_ n: Int) throws -> (ModelContainer, [Workout], UserProfile) {
        let schema = Schema(PersistenceController.models)
        let container = try ModelContainer(for: schema,
                                           configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        let profile = UserProfile()
        ctx.insert(profile)
        let day = 86_400.0
        for i in 0..<n {
            let w = Workout()
            // ~4 sessions/week over ~3 years for n=1500, mixed running + strength.
            w.startedAt = Date(timeIntervalSinceNow: -Double(i) * (day * 0.75))
            if i % 4 == 3 {
                w.type = .strength
                let s = StrengthSession()
                let ex = WorkoutExercise()
                for r in 0..<4 {
                    let set = SetEntry()
                    set.index = r; set.weightKg = 80 + Double(r); set.reps = 5; set.isComplete = true
                    ex.sets.append(set)
                }
                s.exercises.append(ex)
                s.totalSets = 4
                s.totalVolumeKg = ex.sets.reduce(0) { $0 + ($1.weightKg ?? 0) * Double($1.reps ?? 0) }
                w.strength = s
                w.durationS = 2_700
            } else {
                w.type = .run
                let g = GPSDetail()
                g.distanceM = 5_000 + Double(i % 7) * 1_000
                g.elevationGainM = Double(i % 5) * 30
                g.avgPaceSPerKm = 330
                w.gps = g
                w.durationS = g.distanceM / 2.8
                w.perceivedEffort = 4 + i % 4
            }
            ctx.insert(w)
        }
        try ctx.save()
        let workouts = try ctx.fetch(FetchDescriptor<Workout>())
        return (container, workouts, profile)
    }

    @MainActor
    @Test func coldOpenEngineWalksStayFlatAtThreeYearsOfHistory() throws {
        let (container, workouts, profile) = try heavyHistory(1_500)
        _ = container   // keep alive

        // Warm the relationship faults once (first touch realizes gps/strength rows — that cost
        // is paid on any path and isn't what this test polices).
        _ = workouts.reduce(0.0) { $0 + ($1.gps?.distanceM ?? 0) }

        let t0 = CFAbsoluteTimeGetCurrent()
        _ = ProfileStats(workouts: workouts, plan: profile.plan)
        _ = ProgressInsights(workouts: workouts, weeksBack: 26)
        _ = AthleteModelEngine(workouts: workouts, plan: profile.plan).facts
        _ = TrendsEssentials.weekStat(workouts: workouts, weeksAgo: 0)
        _ = TrendsEssentials.weekStat(workouts: workouts, weeksAgo: 1)
        _ = TrendsEssentials.totals(workouts: workouts)
        _ = workouts.contentSignature
        let elapsed = CFAbsoluteTimeGetCurrent() - t0

        // Measured ~tens of ms on a healthy build. The budget is ~10× headroom so simulator
        // noise never flakes it, while an accidental O(n²) (seconds at n=1500) always trips.
        #expect(elapsed < 1.0, "Progress cold-open engine walks took \(Int(elapsed * 1000))ms for \(workouts.count) workouts")
    }

    @MainActor
    @Test func contentSignatureIsCheapEnoughForPerRenderUse() throws {
        let (container, workouts, _) = try heavyHistory(1_500)
        _ = container
        _ = workouts.contentSignature   // warm

        // aggregateKey (and the memo tokens derived from it) hash this per body evaluation —
        // it must stay microseconds-per-workout cheap, scalars only, no relationship faults.
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<10 { _ = workouts.contentSignature }
        let perPass = (CFAbsoluteTimeGetCurrent() - t0) / 10

        #expect(perPass < 0.05, "contentSignature took \(Int(perPass * 1_000_000))µs per pass at \(workouts.count) workouts")
    }
}
