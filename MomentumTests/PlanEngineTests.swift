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

    @Test func paceZonesFollowDaniels() {
        // A 25:00 5K runner (p5k 300 → VDOT ≈ 38.3). Golden values from the Daniels–Gilbert curves.
        #expect(abs(PlanEngine.pace(.easy, p5k: 300) - 397) <= 1)        // E band (66% VO₂max)
        #expect(abs(PlanEngine.pace(.long, p5k: 300) - 407) <= 1)        // E band, easier end (64%)
        #expect(abs(PlanEngine.pace(.recovery, p5k: 300) - 428) <= 1)    // E band floor (60%)
        #expect(abs(PlanEngine.pace(.tempo, p5k: 300) - 314) <= 1)       // T ≈ one-hour-race intensity
        #expect(abs(PlanEngine.pace(.intervals, p5k: 300) - 285) <= 1)   // I = vVO₂max, faster than 5K pace
        #expect(PlanEngine.pace(.race, p5k: 300) == 300)                 // 5K race pace is the anchor
        // Zone order is invariant at any fitness level: recovery > long > easy > tempo > intervals,
        // with 5K race pace between tempo and intervals (5K ≈ 95% VO₂max sits above T, below I).
        for p5k in [200.0, 240, 300, 360, 420, 500] {
            #expect(PlanEngine.pace(.recovery, p5k: p5k) > PlanEngine.pace(.long, p5k: p5k))
            #expect(PlanEngine.pace(.long, p5k: p5k) > PlanEngine.pace(.easy, p5k: p5k))
            #expect(PlanEngine.pace(.easy, p5k: p5k) > PlanEngine.pace(.tempo, p5k: p5k))
            #expect(PlanEngine.pace(.tempo, p5k: p5k) > p5k)
            #expect(p5k > PlanEngine.pace(.intervals, p5k: p5k))
        }
        // Curvilinear personalization: the easy-pace gap widens for slower runners (the old flat
        // "+80 s/km for everyone" is exactly what this replaces).
        #expect(PlanEngine.pace(.easy, p5k: 420) - 420 > PlanEngine.pace(.easy, p5k: 240) - 240)
    }

    @Test func sessionPaceHonorsRepIntent() {
        // Re-derivation (recalibration) must keep "@ 5K" reps at race pace and threshold cruise reps
        // at T — only true VO₂ reps get the base interval zone.
        #expect(PlanEngine.sessionPace(.intervals, p5k: 300, intervals: "6×400m @ 5K") == 300)
        #expect(PlanEngine.sessionPace(.intervals, p5k: 300, intervals: "4×1km @ threshold")
                == PlanEngine.pace(.tempo, p5k: 300))
        #expect(PlanEngine.sessionPace(.intervals, p5k: 300, intervals: "5×3min @ VO2")
                == PlanEngine.pace(.intervals, p5k: 300))
        #expect(PlanEngine.sessionPace(.easy, p5k: 300, intervals: nil)
                == PlanEngine.pace(.easy, p5k: 300))
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
        // Build-phase quality differs by race: short races include race-pace reps; long races build
        // threshold and never touch raw 5K speed. (Default experience → P5k = 300 s/km.)
        func buildPaces(_ raceM: Double) -> [Double] {
            var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 4)
            inp.raceDistanceM = raceM
            inp.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 9,
                                                 to: Date(timeIntervalSinceReferenceDate: 0))
            let plan = PlanEngine.generate(profile: inp, catalog: catalog,
                                           startDate: Date(timeIntervalSinceReferenceDate: 0))
            return plan.weeks.filter { $0.phase == .build }
                .flatMap(\.sessions).filter(\.isHardRun).compactMap(\.targetPaceSPerKm)
        }
        #expect(buildPaces(5_000).contains(300))                                  // race-pace reps appear
        let marathon = buildPaces(42_195)
        #expect(!marathon.isEmpty)
        #expect(!marathon.contains(300))                                          // never raw 5K speed
        #expect(marathon.contains(PlanEngine.pace(.tempo, p5k: 300)))             // threshold emphasis
    }

    // MARK: Periodization (base → build → peak → taper)

    @Test func taperLengthMatchesRaceDistance() {
        #expect(PlanEngine.mesocycle(totalWeeks: 12, raceDistanceM: 5_000, hasRace: true).taperWeeks == 1)
        #expect(PlanEngine.mesocycle(totalWeeks: 12, raceDistanceM: 21_097, hasRace: true).taperWeeks == 2)
        #expect(PlanEngine.mesocycle(totalWeeks: 16, raceDistanceM: 42_195, hasRace: true).taperWeeks == 3)
        #expect(PlanEngine.mesocycle(totalWeeks: 16, raceDistanceM: 50_000, hasRace: true).taperWeeks == 4)
        // A short runway caps the taper so build weeks survive; no race → no taper at all.
        #expect(PlanEngine.mesocycle(totalWeeks: 4, raceDistanceM: 42_195, hasRace: true).taperWeeks == 1)
        #expect(PlanEngine.mesocycle(totalWeeks: 4, raceDistanceM: nil, hasRace: false).taperWeeks == 0)
    }

    @Test func ultraPlansGenerateEndToEnd() {
        // "From your first 5K to your first ultra" — a 50K plan periodizes with a 4-week taper,
        // threshold-emphasis quality, and the long run capped at 32 km.
        var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 4)
        inp.raceDistanceM = 50_000
        inp.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 15,
                                             to: Date(timeIntervalSinceReferenceDate: 0))
        let plan = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        #expect(plan.weeks.suffix(4).allSatisfy { $0.isTaper })
        let longs = plan.weeks.flatMap(\.sessions).filter { $0.runType == .long || $0.runType == .progression }
        #expect((longs.compactMap(\.targetDistanceM).max() ?? 0) <= 32_000 + 1)
        // No raw 5K-speed reps anywhere in an ultra build.
        #expect(!plan.weeks.flatMap(\.sessions).contains { $0.intervals?.contains("@ 5K") == true })
    }

    @Test func planPhasesRunBaseBuildPeakTaper() {
        var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 4)
        inp.raceDistanceM = 42_195
        inp.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 15,
                                             to: Date(timeIntervalSinceReferenceDate: 0))
        let plan = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        let phases = plan.weeks.map(\.phase)
        #expect(phases.first == .base)
        #expect(phases.contains(.build) && phases.contains(.peak) && phases.contains(.recovery))
        #expect(phases.suffix(3).allSatisfy { $0 == .taper })
        // Peak holds the biggest volume — no further ramp, no dip.
        let peakVol = plan.weeks.first { $0.phase == .peak }?.runVolumeM ?? 0
        let maxBuildVol = plan.weeks.filter { $0.phase == .build || $0.phase == .base }.map(\.runVolumeM).max() ?? 0
        #expect(abs(peakVol - maxBuildVol) < 1)
    }

    @Test func taperKeepsIntensityWhileVolumeFalls() {
        // Bosquet 2007: cut volume 41–60%, KEEP intensity. Every taper week still carries one short
        // race-pace touch, and taper volume lands at ~45–70% of the peak week.
        var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 4)
        inp.raceDistanceM = 42_195
        inp.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 15,
                                             to: Date(timeIntervalSinceReferenceDate: 0))
        let plan = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        let peakVol = plan.weeks.first { $0.phase == .peak }?.runVolumeM ?? 0
        let goalPace = DanielsPaces.racePaceSPerKm(distanceM: 42_195, p5kSPerKm: 300)
        for week in plan.weeks where week.isTaper {
            let hard = week.sessions.filter(\.isHardRun)
            #expect(hard.count == 1, "taper week \(week.index) lost its quality touch")
            #expect(hard.first?.intervals?.contains("race pace") == true)
            #expect(hard.first?.targetPaceSPerKm == goalPace)
            #expect(week.runVolumeM < peakVol * 0.75 && week.runVolumeM > peakVol * 0.35)
            // Taper long runs are plain and easy — no progression finish.
            #expect(!week.sessions.contains { $0.runType == .progression })
        }
    }

    @Test func basePhaseIsPyramidal() {
        // No VO₂ or race-pace sharpening while the foundation is laid — tempo/hills/fartlek only.
        var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 4)
        inp.raceDistanceM = 5_000
        inp.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 15,
                                             to: Date(timeIntervalSinceReferenceDate: 0))
        let plan = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        let baseHard = plan.weeks.filter { $0.phase == .base }.flatMap(\.sessions).filter(\.isHardRun)
        #expect(!baseHard.isEmpty)
        #expect(baseHard.allSatisfy { [.tempo, .hills, .fartlek].contains($0.runType) })
    }

    @Test func qualityRepsProgressAcrossTheBlock() {
        // Progressive overload, not rotation: the same menu slot prescribes more reps later in the
        // block (weeks 0 and 8 both land on the 400s entry of the 4-item build menu).
        let early = PlanEngine.qualityWorkout(weekIndex: 0, raceDistanceM: 5_000, level: .some, p5k: 300)
        let late = PlanEngine.qualityWorkout(weekIndex: 8, raceDistanceM: 5_000, level: .some, p5k: 300)
        let earlyReps = StructuredWorkoutBuilder.parseIntervals(early.intervals)?.reps ?? 0
        let lateReps = StructuredWorkoutBuilder.parseIntervals(late.intervals)?.reps ?? 0
        #expect(earlyReps == 6 && lateReps == 8)
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
        // "@ 5K" reps override to race pace (the base intervals zone is vVO₂max, faster than 5K).
        #expect(w0.paceOverride == 300)
        // The VO₂ week uses the base interval zone — no override needed.
        #expect(w1.paceOverride == nil)
        #expect(PlanEngine.pace(.intervals, p5k: 300) < 300)
        // A half-marathon plan emphasizes threshold (Daniels T), not raw speed.
        let half = PlanEngine.qualityWorkout(weekIndex: 0, raceDistanceM: 21_097, level: .some, p5k: 300)
        #expect(half.paceOverride == PlanEngine.pace(.tempo, p5k: 300))
    }

    // MARK: Injury history (the "safer ramp where you've been hurt" promise)

    @Test func injuryHistoryCapsAggressiveRamp() {
        // An aggressive pick with an injury history ramps no faster than balanced (1.08/wk) and
        // deloads on the balanced cadence (every 4th week, not aggressive's 5th).
        var inp = inputs(disciplines: [.running], goal: .endurance, days: 4)
        inp.intensity = .aggressive
        inp.injuryHistory = [.shins]
        let race = Calendar.current.date(byAdding: .weekOfYear, value: 9, to: Date(timeIntervalSinceReferenceDate: 0))
        inp.raceDate = race
        let plan = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        var lastBuild: Double?
        for week in plan.weeks where !week.isDeload && !week.isTaper {
            if let prev = lastBuild { #expect(week.runVolumeM <= prev * 1.08 + 1) }
            lastBuild = week.runVolumeM
        }
        #expect(plan.weeks[3].isDeload)   // balanced cadence: deload on week 4
        // No injury history → aggressive keeps its own ramp (regression guard).
        var clean = inp; clean.injuryHistory = []
        let cleanPlan = PlanEngine.generate(profile: clean, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        #expect(!cleanPlan.weeks[3].isDeload)   // aggressive deloads every 5th, not 4th
    }

    @Test func lowerLegInjuryAvoidsHillReps() {
        // A shin history swaps high-impact hill reps for tempo — and says so on the session.
        func runTypes(_ areas: [InjuryArea]) -> (types: Set<RunType>, notes: [String]) {
            var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 4)
            inp.raceDistanceM = 5_000
            inp.injuryHistory = areas
            inp.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 9,
                                                 to: Date(timeIntervalSinceReferenceDate: 0))
            let plan = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
            let sessions = plan.weeks.flatMap(\.sessions)
            return (Set(sessions.compactMap(\.runType)), sessions.compactMap(\.rationale))
        }
        let hurt = runTypes([.shins])
        #expect(!hurt.types.contains(.hills))
        #expect(hurt.notes.contains { $0.lowercased().contains("injury history") })
        let clean = runTypes([])
        #expect(clean.types.contains(.hills))   // regression: hills stay without a history
    }

    @Test func hamstringInjuryAvoidsMaxSpeedWork() {
        // A hamstring history drops sprint-fast 400s and strides; threshold cruise reps take over.
        var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 4)
        inp.raceDistanceM = 5_000
        inp.injuryHistory = [.hamstring]
        inp.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 9,
                                             to: Date(timeIntervalSinceReferenceDate: 0))
        let plan = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        let sessions = plan.weeks.flatMap(\.sessions)
        #expect(!sessions.contains { $0.intervals?.contains("@ 5K") == true })
        #expect(!sessions.contains { $0.runType == .strides })
        #expect(sessions.contains { $0.intervals?.contains("threshold") == true })
        // The swapped-in cruise reps carry the threshold pace, not race pace.
        let cruise = sessions.first { $0.intervals?.contains("threshold") == true && $0.rationale != nil }
        #expect(cruise?.targetPaceSPerKm == PlanEngine.pace(.tempo, p5k: 300))
    }

    // MARK: Masters recovery (50+)

    @Test func mastersDeloadEveryThirdWeek() {
        // A 55-year-old keeps every intensity but absorbs more often: deload week 3, not week 4.
        var inp = inputs(disciplines: [.running], goal: .endurance, days: 4)
        inp.age = 55
        let masters = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        #expect(masters.weeks[2].isDeload)
        // A 30-year-old on the same settings deloads on the balanced cadence (week 4).
        inp.age = 30
        let young = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        #expect(!young.weeks[2].isDeload && young.weeks[3].isDeload)
        // Unknown age → unchanged (never assume masters).
        inp.age = nil
        let unknown = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        #expect(!unknown.weeks[2].isDeload && unknown.weeks[3].isDeload)
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
