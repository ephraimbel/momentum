import Testing
import Foundation
@testable import Momentum

/// Verifies the deterministic plan invariants from PRD §13.11.
struct PlanEngineTests {

    func item(_ name: String, _ primary: [MuscleGroup], _ secondary: [MuscleGroup],
              _ eq: EquipmentType, _ cat: ExerciseCategory) -> ExerciseCatalogItem {
        ExerciseCatalogItem(name: name, primaryMuscles: primary, secondaryMuscles: secondary,
                            equipment: eq, category: cat, defaultRestS: 120)
    }

    var catalog: [ExerciseCatalogItem] {
        [item("Barbell Back Squat", [.quads], [.glutes, .hamstrings], .barbell, .compound),
         item("Barbell Bench Press", [.chest], [.triceps, .shoulders], .barbell, .compound),
         item("Barbell Row", [.back], [.biceps], .barbell, .compound),
         item("Overhead Press", [.shoulders], [.triceps], .barbell, .compound),
         item("Romanian Deadlift", [.hamstrings], [.glutes], .barbell, .compound),
         item("Hip Thrust", [.glutes], [], .barbell, .compound),
         item("Dumbbell Curl", [.biceps], [], .dumbbell, .isolation),
         item("Triceps Pushdown", [.triceps], [], .cable, .isolation),
         item("Lateral Raise", [.shoulders], [], .dumbbell, .isolation),
         item("Leg Curl", [.hamstrings], [], .machine, .isolation),
         item("Calf Raise", [.calves], [], .machine, .isolation),
         item("Plank", [.core], [], .bodyweight, .isolation)]
    }

    func inputs(disciplines: [Discipline], goal: Goal, days: Int,
                runExp: ExperienceLevel = .experienced, liftExp: ExperienceLevel = .some) -> PlanInputs {
        PlanInputs(disciplines: disciplines, goal: goal, daysPerWeek: days, equipment: .fullGym,
                   sessionMinutes: 60, raceDate: nil, runningExperience: runExp, liftingExperience: liftExp)
    }

    // MARK: Paces

    @Test func riegelPace() {
        #expect(PlanEngine.riegelP5k(distanceM: 5000, timeS: 1500) == 300)
        #expect(abs(PlanEngine.riegelP5k(distanceM: 10000, timeS: 3000) - 288.3) < 1)
    }

    @Test func paceOffsets() {
        #expect(PlanEngine.pace(.easy, p5k: 300) == 380)
        #expect(PlanEngine.pace(.intervals, p5k: 300) == 300)
        #expect(PlanEngine.pace(.long, p5k: 300) == 390)
    }

    @Test func spreadIsDistinct() {
        for n in 1...7 {
            let days = PlanEngine.spread(n)
            #expect(days.count == n)
            #expect(Set(days).count == n)
            #expect(days == days.sorted())
        }
    }

    // MARK: Running volume (≤10%/week on the build, deload dips)

    @Test func runningVolumeProgressionNeverExceedsTenPercent() {
        let plan = PlanEngine.generate(profile: inputs(disciplines: [.running], goal: .endurance, days: 4),
                                       catalog: catalog, startDate: Date(timeIntervalSinceReferenceDate: 0))
        var lastBuildVolume: Double?
        for week in plan.weeks {
            if week.isDeload || week.isTaper {
                #expect(week.runVolumeM < (lastBuildVolume ?? .infinity))  // a planned dip
            } else {
                if let prev = lastBuildVolume {
                    #expect(week.runVolumeM <= prev * 1.10 + 1)            // ≤10% over prior build
                }
                lastBuildVolume = week.runVolumeM
            }
        }
    }

    @Test func deloadAppearsOnSchedule() {
        let plan = PlanEngine.generate(profile: inputs(disciplines: [.running], goal: .endurance, days: 4),
                                       catalog: catalog, startDate: Date(timeIntervalSinceReferenceDate: 0))
        #expect(plan.weeks.count == 4)
        #expect(plan.weeks[3].isDeload)
    }

    // MARK: Strength splits

    @Test func strengthSplitByDays() {
        let plan = PlanEngine.generate(profile: inputs(disciplines: [.strength], goal: .buildMuscle, days: 4),
                                       catalog: catalog, startDate: Date(timeIntervalSinceReferenceDate: 0))
        let labels = Set(plan.weeks[0].sessions.compactMap(\.strengthLabel))
        #expect(labels == ["Upper", "Lower"])
        // Each strength day has working exercises selected from the catalog.
        #expect(plan.weeks[0].sessions.allSatisfy { !$0.strengthTargets.isEmpty })
    }

    @Test func strengthDeloadReducesSets() {
        let plan = PlanEngine.generate(profile: inputs(disciplines: [.strength], goal: .buildMuscle, days: 3),
                                       catalog: catalog, startDate: Date(timeIntervalSinceReferenceDate: 0))
        let buildSets = plan.weeks[0].sessions.first?.strengthTargets.first?.targetSets ?? 0
        let deloadSets = plan.weeks[3].sessions.first?.strengthTargets.first?.targetSets ?? 0
        #expect(deloadSets < buildSets)
    }

    // MARK: Hybrid recovery — the capability no competitor has

    @Test func hybridNeverPlacesHardRunAfterHeavyLower() {
        // Sweep day counts and goals that produce both hard runs and lower-lift days.
        for days in 3...6 {
            for goal in [Goal.raceDistance, .endurance, .buildMuscle, .generalFitness] {
                let plan = PlanEngine.generate(
                    profile: inputs(disciplines: [.running, .strength], goal: goal, days: days),
                    catalog: catalog, startDate: Date(timeIntervalSinceReferenceDate: 0))
                for week in plan.weeks {
                    #expect(PlanEngine.scheduleSatisfiesRecovery(week.sessions),
                            "violation: days=\(days) goal=\(goal) week=\(week.index)")
                }
            }
        }
    }

    // MARK: Calibration

    @Test func feelEstimateSeedsPace() {
        var seed = CalibrationSeed(); seed.estimatedP5kSPerKm = 360   // "easy jogger"
        let plan = PlanEngine.generate(profile: inputs(disciplines: [.running], goal: .endurance, days: 3),
                                       catalog: catalog, calibration: seed,
                                       startDate: Date(timeIntervalSinceReferenceDate: 0))
        #expect(abs(plan.p5kSPerKm - 360) < 0.5)
    }

    @Test func recentTimeOverridesFeel() {
        var seed = CalibrationSeed(); seed.recentRun = (5000, 1500); seed.estimatedP5kSPerKm = 400
        let plan = PlanEngine.generate(profile: inputs(disciplines: [.running], goal: .endurance, days: 3),
                                       catalog: catalog, calibration: seed,
                                       startDate: Date(timeIntervalSinceReferenceDate: 0))
        #expect(abs(plan.p5kSPerKm - 300) < 1)   // a precise 5K time wins over the by-feel estimate
    }

    // MARK: Race-distance tailoring

    @Test func raceDistanceShapesLongRun() {
        func peakLong(_ raceM: Double) -> Double {
            var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 4)
            inp.raceDistanceM = raceM
            let plan = PlanEngine.generate(profile: inp, catalog: catalog,
                                           startDate: Date(timeIntervalSinceReferenceDate: 0))
            return plan.weeks.flatMap(\.sessions).filter { $0.runType == .long }.map { $0.targetDistanceM ?? 0 }.max() ?? 0
        }
        // A marathon's longest run dwarfs a 5K's — and never exceeds the engine's clamp.
        let fiveK = peakLong(5_000), marathon = peakLong(42_195)
        #expect(marathon > fiveK)
        #expect(marathon <= 32_000 + 1)
        #expect(fiveK <= PlanEngine.longRunPeak(forRaceM: 5_000) + 1)
    }

    @Test func shortRaceUsesSpeedLongRaceUsesThreshold() {
        // Both prescribe reps, but the *pace* differs: short races sharpen at ~5K pace (P5k), long races
        // build threshold (P5k + 20). (Default experience → P5k = 300 s/km.)
        func week0QualityPace(_ raceM: Double) -> Double? {
            var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 4)
            inp.raceDistanceM = raceM
            let plan = PlanEngine.generate(profile: inp, catalog: catalog,
                                           startDate: Date(timeIntervalSinceReferenceDate: 0))
            return plan.weeks[0].sessions.first { $0.discipline == .running && $0.isHardRun }?.targetPaceSPerKm
        }
        #expect(week0QualityPace(5_000) == 300)     // 5K → speed reps at P5k
        #expect(week0QualityPace(42_195) == 320)    // marathon → threshold reps (P5k + 20)
    }

    // MARK: Muscle focus

    @Test func muscleFocusAddsVolumeToChosenMuscles() {
        var inp = inputs(disciplines: [.strength], goal: .buildMuscle, days: 4)
        inp.muscleFocus = [.chest]
        let plan = PlanEngine.generate(profile: inp, catalog: catalog,
                                       startDate: Date(timeIntervalSinceReferenceDate: 0))
        // The chest exercise in an Upper day gets an extra working set vs the base scheme (4 → 5).
        let chestSets = plan.weeks[0].sessions
            .flatMap(\.strengthTargets)
            .filter { $0.exerciseName == "Barbell Bench Press" }
            .map(\.targetSets).max() ?? 0
        #expect(chestSets >= 5)
    }

    // MARK: Preferred days

    @Test func preferredDaysAreHonored() {
        var inp = inputs(disciplines: [.strength], goal: .buildMuscle, days: 3)
        inp.preferredDayOffsets = [1, 3, 5]   // Mon/Wed/Fri-style spacing from the start day
        let plan = PlanEngine.generate(profile: inp, catalog: catalog,
                                       startDate: Date(timeIntervalSinceReferenceDate: 0))
        let offsets = Set(plan.weeks[0].sessions.map(\.dayOffset))
        #expect(offsets.isSubset(of: [1, 3, 5]))
    }

    @Test func unifiedPlanFillsRequestedDays() {
        let plan = PlanEngine.generate(profile: inputs(disciplines: [.running, .strength], goal: .raceDistance, days: 6),
                                       catalog: catalog, startDate: Date(timeIntervalSinceReferenceDate: 0))
        // Non-deload week schedules exactly daysPerWeek sessions on distinct days.
        let week0 = plan.weeks[0]
        #expect(week0.sessions.count == 6)
        #expect(Set(week0.sessions.map(\.dayOffset)).count == 6)
    }

    // MARK: Workout variety

    @Test func qualityWorkoutRotatesAndCarriesRepPace() {
        // Two consecutive weeks produce different quality work — no "6×400 @ 5K" every week.
        let w0 = PlanEngine.qualityWorkout(weekIndex: 0, raceDistanceM: 5000, level: .some, p5k: 300)
        let w1 = PlanEngine.qualityWorkout(weekIndex: 1, raceDistanceM: 5000, level: .some, p5k: 300)
        #expect(w0.type != w1.type || w0.intervals != w1.intervals)
        // The VO₂ week carries a faster-than-5K rep pace (P5k − 6).
        #expect(w1.paceOverride == 294)
        // A half-marathon plan emphasizes threshold (P5k + 20), not raw speed.
        let half = PlanEngine.qualityWorkout(weekIndex: 0, raceDistanceM: 21_097, level: .some, p5k: 300)
        #expect(half.paceOverride == 320)
    }

    @Test func hybridPriorityShiftsRunLiftSplit() {
        func runDays(_ priority: HybridPriority?) -> Int {
            var inp = inputs(disciplines: [.running, .strength], goal: .generalFitness, days: 5)
            inp.hybridPriority = priority
            let plan = PlanEngine.generate(profile: inp, catalog: catalog, startDate: Date(timeIntervalSinceReferenceDate: 0))
            return plan.weeks[0].sessions.filter { $0.discipline == .running }.count
        }
        // Running-priority weights the week toward runs; lifting-priority away from them.
        #expect(runDays(.running) > runDays(.lifting))
        #expect(runDays(.balanced) >= runDays(.lifting))
    }

    @Test func hybridWeekAttachesSequencingRationale() {
        // A running + strength week places a leg day and a hard run — the hard run should carry a
        // cross-discipline "fresh legs" rationale (our differentiator, made visible).
        let plan = PlanEngine.generate(profile: inputs(disciplines: [.running, .strength], goal: .raceDistance, days: 6),
                                       catalog: catalog, startDate: Date(timeIntervalSinceReferenceDate: 0))
        let hardRuns = plan.weeks[0].sessions.filter { $0.discipline == .running && $0.isHardRun }
        #expect(!hardRuns.isEmpty)
        #expect(hardRuns.contains { ($0.rationale?.lowercased().contains("leg")) == true })
    }

    @Test func seedsStartingVolumeFromStatedLoad() {
        // An athlete running 30 km/week with a 10 km long run should start near that — not the
        // experience-tier default (fixes plans that open too aggressively).
        var inp = inputs(disciplines: [.running], goal: .generalFitness, days: 4)
        inp.currentWeeklyVolumeM = 30_000
        inp.longestRunM = 10_000
        let plan = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        let week0 = plan.weeks[0].sessions.filter { $0.discipline == .running }
        let weekly = week0.compactMap(\.targetDistanceM).reduce(0, +)
        #expect(weekly >= 24_000 && weekly <= 36_000)                 // starting week within ~20% of stated
        let longRun = week0.first { $0.runType == .long }?.targetDistanceM ?? 0
        #expect(longRun >= 9_000 && longRun <= 14_000)               // reflects their 10 km, not the 16 km default
    }

    @Test func startingVolumeUnchangedWithoutStatedLoad() {
        // No stated volume → the experience-tier default still governs (regression guard).
        let inp = inputs(disciplines: [.running], goal: .generalFitness, days: 4)   // helper defaults to .experienced
        let plan = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        let longRun = plan.weeks[0].sessions.first { $0.discipline == .running && $0.runType == .long }?.targetDistanceM ?? 0
        #expect(longRun >= 15_000)                                    // experienced default long base ≈ 16 km
    }

    @Test func generatedPlanHasRealVariety() {
        let race = Calendar.current.date(byAdding: .weekOfYear, value: 10, to: Date(timeIntervalSinceReferenceDate: 0))
        let ins = PlanInputs(disciplines: [.running], goal: .raceDistance, daysPerWeek: 4, equipment: .fullGym,
                             sessionMinutes: 45, raceDate: race, runningExperience: .some, liftingExperience: .some,
                             raceDistanceM: 5000)
        let plan = PlanEngine.generate(profile: ins, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        let runTypes = Set(plan.weeks.flatMap { $0.sessions }.compactMap { $0.runType })
        // Across the block we should see several distinct run types (intervals/fartlek/hills/strides/…).
        #expect(runTypes.count >= 4)
    }
}
