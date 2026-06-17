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

    @Test func shortRaceUsesIntervalsLongRaceUsesTempo() {
        func qualityTypes(_ raceM: Double) -> Set<RunType> {
            var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 4)
            inp.raceDistanceM = raceM
            let plan = PlanEngine.generate(profile: inp, catalog: catalog,
                                           startDate: Date(timeIntervalSinceReferenceDate: 0))
            return Set(plan.weeks[0].sessions.compactMap(\.runType))
        }
        #expect(qualityTypes(5_000).contains(.intervals))
        #expect(qualityTypes(42_195).contains(.tempo))
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
}
