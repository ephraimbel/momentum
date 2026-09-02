import Testing
import Foundation
@testable import Momentum

/// The plan-generation progression governor — a plan cannot exceed its documented internal limit.
struct ACWRGovernorTests {

    @Test func saneRampsPassUntouched() {
        // A balanced 8%/wk build from a 30 km base — comfortably inside the ceiling.
        let weeks = [30_000.0, 32_400, 34_992, 24_000, 37_791]   // incl. a deload
        let f = ACWRGovernor.capFactors(weeklyMeters: weeks, currentWeeklyM: 30_000)
        #expect(f.allSatisfy { $0 > 0.999 })                      // dormant in normal operation
    }

    @Test func spikeAboveTheAthletesCurrentLoadIsCapped() {
        // Reported 10 km/wk but a 30 km first week — 3× their chronic load. Capped to 1.3×.
        let f = ACWRGovernor.capFactors(weeklyMeters: [30_000, 32_000], currentWeeklyM: 10_000)
        #expect(abs(f[0] - (13_000.0 / 30_000)) < 0.001)          // week 1 → 13 km (1.3 × 10)
        // Week 2 builds on the *governed* history, not the original wish.
        #expect(f[1] < 1)
    }

    @Test func unknownHistorySeedsFromWeekOneAndGovernsAcceleration() {
        // No reported volume: week 1 passes by definition; a later 2× jump is caught.
        let f = ACWRGovernor.capFactors(weeklyMeters: [20_000, 21_000, 44_000], currentWeeklyM: 0)
        #expect(f[0] == 1)
        #expect(f[1] > 0.999)
        #expect(f[2] < 0.7)                                       // 44 km vs ~20 km chronic → capped hard
    }

    @Test func deloadRecoveryJumpIsAllowed() {
        // Deload (70%) then back to the build line — periodization, not a spike; must pass.
        let f = ACWRGovernor.capFactors(weeklyMeters: [30_000, 21_000, 32_000], currentWeeklyM: 30_000)
        #expect(f.allSatisfy { $0 > 0.999 })
    }

    @Test func generatedPlanNeverExceedsTheCeiling() {
        // End-to-end through the real engine on the aggressive tier: every week's planned volume stays
        // within 1.3× its trailing 4-week average (seeded from the reported current volume).
        var inputs = PlanInputs(disciplines: [.running], goal: .raceDistance, daysPerWeek: 5,
                                equipment: .bodyweight, sessionMinutes: 60,
                                raceDate: Calendar.current.date(byAdding: .weekOfYear, value: 14, to: Date()),
                                runningExperience: .experienced, liftingExperience: .some)
        inputs.raceDistanceM = RaceDistance.marathon.meters
        inputs.currentWeeklyVolumeM = 20_000
        inputs.intensity = .aggressive
        let plan = PlanEngine.generate(profile: inputs, catalog: [], startDate: Date())

        var history: [Double] = Array(repeating: 20_000, count: 4)
        for week in plan.weeks {
            let chronic = history.suffix(4).reduce(0, +) / 4
            let v = week.runVolumeM
            // ×1.03 absorbs clean-distance snapping (RunRounding), the last generation step — it can
            // round a capped week up by <2%, still inside the documented progression tolerance.
            if chronic > 0 { #expect(v <= chronic * ACWRGovernor.maxRatio * 1.03, "week \(week.index)") }
            history.append(v)
        }
    }
}
