import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Planned-session load estimation (Health hub §11.1.1) — the Foster twin of `TrainingLoad.session`.
@MainActor
struct PlannedLoadTests {

    /// Build an in-memory container (retained by the caller so it doesn't dealloc mid-test).
    func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    @Test func durationBasedSessionUsesPrescribedMinutes() {
        // 40-minute tempo: expected RPE 7 → 40 × 7 = 280.
        let load = PlannedLoad.estimate(.init(runType: .tempo, targetDurationS: 2400))
        #expect(load == 280)
        // Duration wins over distance × pace when both are prescribed.
        let both = PlannedLoad.estimate(.init(runType: .easy, targetDistanceM: 10_000,
                                              targetDurationS: 1800, targetPaceSPerKm: 400))
        #expect(both == 30 * 4)
    }

    @Test func paceTimesDistanceDerivesMinutes() {
        // 8 km easy at 6:00/km → 48 min at RPE 4 = 192.
        let load = PlannedLoad.estimate(.init(runType: .easy, targetDistanceM: 8_000, targetPaceSPerKm: 360))
        #expect(load == 192)
    }

    @Test func distanceOnlyFallbackMirrorsTrainingLoad() {
        // No duration, no pace → km × 6, the exact fallback in TrainingLoad.session.
        let load = PlannedLoad.estimate(.init(runType: .long, targetDistanceM: 10_000))
        #expect(load == 60)
    }

    @Test func strengthApproximatesThreeMinutesPerSetAtRPE6() {
        // 12 working sets ≈ 36 minutes at RPE 6 = 216.
        #expect(PlannedLoad.estimate(.init(strengthSets: 12)) == 216)
    }

    @Test func nothingPrescribedEstimatesZero() {
        #expect(PlannedLoad.estimate(PlannedLoad.Input()) == 0)   // explicit — bare .init() is ambiguous with the PlannedSession overload
        // Degenerate prescriptions (zero/negative) never produce a phantom load.
        #expect(PlannedLoad.estimate(.init(runType: .easy, targetDistanceM: 0, targetDurationS: 0)) == 0)
    }

    @Test func handCheckedEndToEnd() throws {
        // Interval session as PlanEngine writes it: 5 km at 4:40/km (280 s/km), expected RPE 8.
        // Minutes = 5 × 280 / 60 = 23.3̅ → load = 186.6̅.
        let container = try makeContainer()
        let s = PlannedSession()
        s.discipline = .running
        s.runType = .intervals
        s.targetDistanceM = 5_000
        s.targetPaceSPerKm = 280
        container.mainContext.insert(s)
        #expect(abs(PlannedLoad.estimate(s) - 560.0 / 3) < 0.001)
    }

    @Test func mapsStrengthTargetsAndDisciplineDefaults() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        // Strength session: 4 + 3 sets → 7 × 3 min × RPE 6 = 126.
        let strength = PlannedSession()
        strength.discipline = .strength
        let a = PlannedExercise(); a.targetSets = 4
        let b = PlannedExercise(); b.targetSets = 3
        ctx.insert(strength); ctx.insert(a); ctx.insert(b)
        strength.strengthTargets = [a, b]
        #expect(PlannedLoad.estimate(strength) == 126)
        // No runType → discipline default intensity (walking = 4): 60 min walk = 240.
        let walk = PlannedSession()
        walk.discipline = .walking
        walk.targetDurationS = 3600
        ctx.insert(walk)
        #expect(PlannedLoad.estimate(walk) == 240)
    }
}
