import Testing
import Foundation
@testable import Momentum

/// Verifies the deterministic plan invariants from PRD §13.11.
struct PlanEngineTests {

    func item(_ name: String, _ primary: [MuscleGroup], _ secondary: [MuscleGroup],
              _ eq: EquipmentType, _ cat: ExerciseCategory,
              _ tracking: TrackingMode = .weightReps) -> ExerciseCatalogItem {
        ExerciseCatalogItem(name: name, primaryMuscles: primary, secondaryMuscles: secondary,
                            equipment: eq, category: cat, defaultRestS: 120,
                            trackingMode: tracking)
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
         item("Hanging Knee Raise", [.core], [.forearms], .bodyweight, .isolation, .repsOnly),
         item("Lying Leg Raise", [.core], [], .bodyweight, .isolation, .repsOnly),
         item("Plank", [.core], [], .bodyweight, .isolation, .time),
         item("Farmer's Carry", [.forearms, .core], [], .dumbbell, .compound, .distance)]
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
        // No race → one full rolling block (a real mesocycle), not a stub 4-week plan.
        #expect(plan.weeks.count == PlanEngine.openBlockWeeks)
        #expect(plan.weeks[3].isDeload)   // deload still lands on the 4th week of the block
    }

    @Test func openEndedPlanIsAFullBlockNotFourWeeks() {
        // The regression this guards: a no-race athlete ("just get fitter") used to get a static
        // 4-week plan. Now they get one full rolling block that renews.
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let plan = PlanEngine.generate(profile: inputs(disciplines: [.running], goal: .generalFitness, days: 3),
                                       catalog: catalog, startDate: start)
        #expect(plan.weeks.count == 6)
        #expect(PlanEngine.weeksToGenerate(startDate: start, raceDate: nil, calendar: .current) == 6)
    }

    @Test func datedRacePlanStillScalesToTheSeason() {
        // The dated path must keep adapting — a race ~30 weeks out is a full season, not a block.
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let race = Calendar.current.date(byAdding: .weekOfYear, value: 30, to: start)!
        #expect(PlanEngine.weeksToGenerate(startDate: start, raceDate: race, calendar: .current) == 31)
        // A marathon a year+ out is capped at the 52-week horizon and rolls forward on regeneration.
        let farRace = Calendar.current.date(byAdding: .weekOfYear, value: 70, to: start)!
        #expect(PlanEngine.weeksToGenerate(startDate: start, raceDate: farRace, calendar: .current) == 52)
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

    // MARK: Duration prescriptions — you cannot do 10–15 reps of a plank

    /// A timed hold or loaded carry must be prescribed in SECONDS. The engine used to pick
    /// sets/reps purely from goal + experience without ever consulting `trackingMode`, so a
    /// plank came out as "3 × 10–15" — and since Plank is the library's only core-primary
    /// exercise, that reached essentially every Full Body and Lower day.
    /// The plan reaches for a rep-countable core exercise, never the plank — a hold gives the
    /// weekly progression nothing to push on, and "3 × 10–15" of a plank is not a thing.
    @Test func coreWorkIsPrescribedInRepsNotAsAPlank() {
        for goal in [Goal.buildMuscle, .getStronger, .generalFitness, .endurance] {
            for level in [ExperienceLevel.new, .some, .experienced] {
                let plan = PlanEngine.generate(
                    profile: inputs(disciplines: [.strength], goal: goal, days: 4, liftExp: level),
                    catalog: catalog, startDate: Date(timeIntervalSinceReferenceDate: 0))
                let targets = plan.weeks.flatMap(\.sessions).flatMap(\.strengthTargets)
                #expect(!targets.contains { $0.exerciseName == "Plank" },
                        "plank prescribed for goal=\(goal) level=\(level) — a countable core exercise was available")
                let core = targets.filter { $0.exerciseName == "Hanging Knee Raise" || $0.exerciseName == "Lying Leg Raise" }
                #expect(!core.isEmpty, "no core work at all for goal=\(goal) level=\(level)")
                for ex in core {
                    #expect(ex.targetHoldS == nil, "\(ex.exerciseName) got a hold instead of reps")
                    #expect(ex.repHigh >= ex.repLow && ex.repLow >= 1)
                }
            }
        }
    }

    /// The fallback still has to be honest: when only a timed/carry exercise fits a slot, it is
    /// prescribed in SECONDS. Farmer's Carry is the library's only forearms-primary exercise, so
    /// this path is live today — removing the plank alone would not have fixed it.
    @Test func timedExercisesFallBackToHoldsNotReps() {
        for goal in [Goal.buildMuscle, .getStronger, .generalFitness, .endurance] {
            for level in [ExperienceLevel.new, .some, .experienced] {
                let plan = PlanEngine.generate(
                    profile: inputs(disciplines: [.strength], goal: goal, days: 4, liftExp: level),
                    catalog: catalog, startDate: Date(timeIntervalSinceReferenceDate: 0))
                let timed = plan.weeks.flatMap(\.sessions).flatMap(\.strengthTargets)
                    .filter { $0.exerciseName == "Plank" || $0.exerciseName == "Farmer's Carry" }
                for ex in timed {
                    #expect(ex.targetHoldS != nil,
                            "\(ex.exerciseName) has no hold duration (goal=\(goal) level=\(level))")
                    #expect((ex.targetHoldS ?? 0) >= 20, "hold too short to be a real prescription")
                    // One hold is one set — never an invented rep range.
                    #expect(ex.repLow == 1 && ex.repHigh == 1,
                            "\(ex.exerciseName) prescribed \(ex.repLow)–\(ex.repHigh) reps")
                }
            }
        }
    }

    /// Rep-based lifts are untouched by the hold branch.
    @Test func weightRepExercisesKeepTheirRepRanges() {
        let plan = PlanEngine.generate(
            profile: inputs(disciplines: [.strength], goal: .buildMuscle, days: 4),
            catalog: catalog, startDate: Date(timeIntervalSinceReferenceDate: 0))
        let lifts = plan.weeks.flatMap(\.sessions).flatMap(\.strengthTargets)
            .filter { $0.exerciseName != "Plank" && $0.exerciseName != "Farmer's Carry" }
        #expect(!lifts.isEmpty)
        for ex in lifts {
            #expect(ex.targetHoldS == nil, "\(ex.exerciseName) wrongly got a hold duration")
            #expect(ex.repHigh >= ex.repLow && ex.repLow >= 1)
        }
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
            // The tune-up TT legitimately runs at 5K effort — it's a checkpoint, not a training
            // stimulus, so it's excluded from the "never raw 5K speed in a marathon build" pin.
            return plan.weeks.filter { $0.phase == .build }
                .flatMap(\.sessions).filter(\.isHardRun)
                .filter { $0.intervals?.contains("Time trial") != true }
                .compactMap(\.targetPaceSPerKm)
        }
        #expect(buildPaces(5_000).contains(300))                                  // race-pace reps appear
        let marathon = buildPaces(42_195)
        #expect(!marathon.isEmpty)
        #expect(!marathon.contains(300))                                          // never raw 5K speed
        // Threshold emphasis — stored paces carry the clean-pace snap (5s grid for quality).
        #expect(marathon.contains(RunRounding.snapPace(sPerKm: PlanEngine.pace(.tempo, p5k: 300),
                                                       unit: .metric, type: .tempo)))
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

    // MARK: Any timeframe (short runways stay honest; long runways don't strand the taper)

    @Test func twoWeekMarathonIsAnHonestFreshnessBlock() {
        // A marathon in ~2 weeks: no building left to do — the whole block is a taper that holds
        // volume BELOW current load and keeps one race-pace touch a week. Never a ramp, never a
        // plan that extends past race day.
        var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 4)
        inp.raceDistanceM = 42_195
        inp.raceDate = Calendar.current.date(byAdding: .day, value: 10, to: Date(timeIntervalSinceReferenceDate: 0))
        inp.currentWeeklyVolumeM = 30_000
        inp.longestRunM = 10_000
        let plan = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        #expect(plan.weeks.count <= 2)
        #expect(plan.weeks.allSatisfy { $0.isTaper && $0.phase == .taper })
        #expect(plan.weeks.allSatisfy { $0.runVolumeM < 30_000 })          // freshness, not building
        #expect(plan.weeks.allSatisfy { w in w.sessions.contains { $0.intervals?.contains("race pace") == true } })
    }

    @Test func marathonNextYearGetsTheWholeSeason() {
        // A marathon 52 weeks out generates the entire season: base first, months of build with
        // deloads, a peak, and the 3-week taper landing exactly on race week — while volume grows
        // toward the marathon readiness peak (70 km/wk at this level) and then holds.
        var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 4, runExp: .some)
        inp.raceDistanceM = 42_195
        inp.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 51, to: Date(timeIntervalSinceReferenceDate: 0))
        inp.currentWeeklyVolumeM = 30_000
        inp.longestRunM = 12_000
        let plan = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        #expect(plan.weeks.count == 52)
        #expect(plan.weeks.first?.phase == .base)
        #expect(plan.weeks.contains { $0.phase == .peak })
        #expect(plan.weeks.suffix(3).allSatisfy { $0.isTaper })            // taper ends ON race week
        let maxVol = plan.weeks.map(\.runVolumeM).max() ?? 0
        #expect(maxVol > 30_000 * 1.8)                                     // actually grows over a year…
        #expect(maxVol <= 70_000 * 1.04)                                   // …and holds near the marathon peak
    }                                                                       // (×1.04 absorbs clean-distance snapping)

    @Test func raceBeyondHorizonBuildsWithoutPhantomTaper() {
        // A race 60 weeks out: the 52-week block is pure foundation — base + build + deloads,
        // no taper stranded months before race day.
        var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 4)
        inp.raceDistanceM = 42_195
        inp.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 60, to: Date(timeIntervalSinceReferenceDate: 0))
        inp.currentWeeklyVolumeM = 30_000
        inp.longestRunM = 10_000
        let plan = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        #expect(plan.weeks.count == 52)
        #expect(!plan.weeks.contains { $0.isTaper || $0.phase == .taper || $0.phase == .peak })
        #expect(plan.weeks.first?.phase == .base)
        #expect(plan.weeks.contains { $0.phase == .recovery })             // deloads still land
        // Volume grows toward the marathon readiness peak (90 km at this level) and holds there
        // (×1.04 absorbs clean-distance snapping rounding a few sessions up).
        #expect((plan.weeks.map(\.runVolumeM).max() ?? 0)
                <= PlanFeasibility.peakWeeklyVolumeM(distanceM: 42_195, experience: .experienced) * 1.04)
    }

    @Test func raceWeekPlanIsOneWeek() {
        // A race in 3 days still gets a real plan: one race-week block of freshness.
        var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 3)
        inp.raceDistanceM = 5_000
        inp.raceDate = Calendar.current.date(byAdding: .day, value: 3, to: Date(timeIntervalSinceReferenceDate: 0))
        let plan = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        #expect(plan.weeks.count == 1)
        #expect(plan.weeks[0].isTaper)
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
        // race-pace touch, and taper volume lands at ~45–70% of the peak week. The race session
        // itself sits outside these TRAINING-volume invariants (it's the day it all points at, not
        // taper load), so it's filtered out here and pinned by `raceDayLandsOnThePlan` instead.
        var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 4)
        inp.raceDistanceM = 42_195
        inp.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 15,
                                             to: Date(timeIntervalSinceReferenceDate: 0))
        let plan = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        let peakVol = plan.weeks.first { $0.phase == .peak }?.runVolumeM ?? 0
        let goalPace = DanielsPaces.racePaceSPerKm(distanceM: 42_195, p5kSPerKm: 300)
        for week in plan.weeks where week.isTaper {
            let training = week.sessions.filter { $0.runType != .race }
            let hard = training.filter(\.isHardRun)
            let trainingVol = training.compactMap(\.targetDistanceM).reduce(0, +)
            // Race week can lose its quality touch to race-day clearing (nothing on/after the race);
            // every other taper week must keep exactly one.
            if !week.sessions.contains(where: { $0.runType == .race }) {
                #expect(hard.count == 1, "taper week \(week.index) lost its quality touch")
                #expect(hard.first?.intervals?.contains("race pace") == true)
                #expect(hard.first?.targetPaceSPerKm == goalPace)
                #expect(trainingVol < peakVol * 0.75 && trainingVol > peakVol * 0.35)
            }
            // Taper long runs are plain and easy — no progression finish.
            #expect(!training.contains { $0.runType == .progression })
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
        // Threshold cruise reps are pyramidal-compliant (they're the tempo dose in absorbable
        // pieces — the oversized-tempo swap); VO₂/race-pace sharpening stays out of base.
        #expect(baseHard.allSatisfy {
            [.tempo, .hills, .fartlek].contains($0.runType)
                || ($0.runType == .intervals && ($0.intervals?.contains("threshold") ?? false))
        })
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
            // Capped at the balanced 8% ramp (not aggressive's 11%); ×1.02 absorbs clean-distance
            // snapping wobble on the weekly total — still unmistakably the safer cadence.
            if let prev = lastBuild { #expect(week.runVolumeM <= prev * 1.08 * 1.02 + 1) }
            lastBuild = week.runVolumeM
        }
        #expect(plan.weeks[3].isDeload)   // balanced cadence: deload on week 4
        // No injury history → aggressive keeps its own ramp (regression guard).
        var clean = inp; clean.injuryHistory = []
        let cleanPlan = PlanEngine.generate(profile: clean, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        #expect(!cleanPlan.weeks[3].isDeload)   // aggressive deloads every 5th, not 4th
    }

    @Test func autoPlanNeverRequiresTerrain() {
        // Hills need a hill and not every athlete has one — the plan never PRESCRIBES terrain
        // (2026-07-24). Dedicated hill sessions live in the workout library for those who want them.
        // The flat power stimulus is a fartlek, offered with a hill as an option, not a requirement.
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
        // No auto-generated plan — clean OR injured — ever forces a hill.
        #expect(!runTypes([]).types.contains(.hills))
        #expect(!runTypes([.shins]).types.contains(.hills))
        // The flat power fartlek that replaced it says a hill is welcome but optional.
        #expect(runTypes([]).notes.contains { $0.lowercased().contains("hill") && $0.lowercased().contains("flat") })
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
        // The swapped-in cruise reps carry the threshold pace (snapped to the clean 5s grid), not race pace.
        let cruise = sessions.first { $0.intervals?.contains("threshold") == true && $0.rationale != nil }
        #expect(cruise?.targetPaceSPerKm == RunRounding.snapPace(sPerKm: PlanEngine.pace(.tempo, p5k: 300),
                                                                 unit: .metric, type: .intervals))
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

    // MARK: Race day on the plan (the season's crown)

    @Test func raceDayLandsOnThePlan() {
        // A marathon plan carries the race itself: exact date, exact distance, predicted race pace.
        var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 4)
        inp.raceDistanceM = 42_195
        let start = Date(timeIntervalSinceReferenceDate: 0)
        inp.raceDate = Calendar.current.date(byAdding: .day, value: 15 * 7 + 3, to: start)   // mid-week race
        let plan = PlanEngine.generate(profile: inp, catalog: [], startDate: start)

        let races = plan.weeks.flatMap(\.sessions).filter { $0.runType == .race }
        #expect(races.count == 1)
        let race = races[0]
        #expect(race.targetDistanceM == 42_195)                       // RunRounding snaps to the exact distance
        #expect(race.targetPaceSPerKm == DanielsPaces.racePaceSPerKm(distanceM: 42_195, p5kSPerKm: 300))
        // Placed on the exact race date: week 15, day 3.
        let raceWeek = plan.weeks.first { $0.sessions.contains { $0.runType == .race } }
        #expect(raceWeek?.index == 15)
        #expect(race.dayOffset == 3)
        // Nothing scheduled on or after race day; the day before is a shakeout, not a workout.
        let after = raceWeek?.sessions.filter { $0.dayOffset >= race.dayOffset && $0.runType != .race } ?? []
        #expect(after.isEmpty)
        let dayBefore = raceWeek?.sessions.filter { $0.dayOffset == race.dayOffset - 1 } ?? []
        #expect(dayBefore.allSatisfy { $0.runType == .strides && !$0.isHardRun })
    }

    @Test func raceSessionPaceRederivesAtGoalDistance() {
        // Recalibration re-derives every future pace via sessionPace — the race session must come
        // back at the GOAL distance's predicted pace, never the raw 5K scalar.
        let marathonPace = PlanEngine.sessionPace(.race, p5k: 300, intervals: nil, raceDistanceM: 42_195)
        #expect(marathonPace == DanielsPaces.racePaceSPerKm(distanceM: 42_195, p5kSPerKm: 300))
        #expect(marathonPace > 300)   // a marathon is raced slower than a 5K
    }

    // MARK: Race-pace finish long runs (the signature half/marathon workout)

    @Test func marathonBuildLongRunsCarryRacePaceFinish() {
        var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 4)
        inp.raceDistanceM = 42_195
        inp.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 15,
                                             to: Date(timeIntervalSinceReferenceDate: 0))
        let plan = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))

        let finishLongs = plan.weeks.flatMap(\.sessions).filter {
            $0.runType == .long && ($0.intervals?.contains("race pace") ?? false)
        }
        #expect(!finishLongs.isEmpty, "a marathon build must rehearse race pace on tired legs")
        // Only in build/peak — never while the base is laid, never in the taper.
        for week in plan.weeks where week.phase == .base || week.isTaper {
            #expect(!week.sessions.contains { $0.runType == .long && ($0.intervals?.contains("race pace") ?? false) })
        }
        // The block grows with the calendar and never exceeds the marathon cap (8 km).
        let kms = finishLongs.compactMap { s in
            StructuredWorkoutBuilder.parseRaceFinish(s.intervals).map { $0 / 1000 }
        }
        #expect(kms.allSatisfy { $0 >= 2 && $0 <= 8 })
        #expect((kms.last ?? 0) >= (kms.first ?? 0))                  // later blocks are never smaller

        // A 5K plan never gets one — race-pace finishes are a long-race tool.
        var fiveK = inputs(disciplines: [.running], goal: .raceDistance, days: 4)
        fiveK.raceDistanceM = 5_000
        fiveK.raceDate = inp.raceDate
        let shortPlan = PlanEngine.generate(profile: fiveK, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        #expect(!shortPlan.weeks.flatMap(\.sessions).contains {
            $0.runType == .long && ($0.intervals?.contains("race pace") ?? false)
        })
    }

    @Test func raceFinishLongRunGuidesItsFinishBlock() {
        // The builder expands "Last 5km @ race pace" into steady body + race-pace finish steps.
        #expect(StructuredWorkoutBuilder.parseRaceFinish("Last 5km @ race pace") == 5_000)
        #expect(StructuredWorkoutBuilder.parseRaceFinish("6×400m @ 5K") == nil)
        #expect(StructuredWorkoutBuilder.parseRaceFinish(nil) == nil)
        let w = StructuredWorkoutBuilder.raceFinishLong(totalDistanceM: 26_000, finishM: 5_000,
                                                        bodyPace: 400, racePace: 320)
        #expect(w?.steps.count == 2)
        #expect(w?.steps.first?.target.distanceM == 21_000)
        #expect(w?.steps.last?.paceSPerKm == 320)
    }

    // MARK: Deload keeps a touch of turnover

    @Test func deloadWeekKeepsStridesNotQuality() {
        let plan = PlanEngine.generate(profile: inputs(disciplines: [.running], goal: .endurance, days: 4),
                                       catalog: catalog, startDate: Date(timeIntervalSinceReferenceDate: 0))
        let deload = plan.weeks.first { $0.isDeload }
        let sessions = deload?.sessions ?? []
        #expect(!sessions.contains { $0.isHardRun })                  // no quality — the week absorbs
        #expect(sessions.contains { $0.runType == .strides })         // but the legs stay awake
    }

    // MARK: Post-race recovery lead-in (the reverse taper)

    @Test func postRaceRecoveryLeadInShapesTheBlock() {
        // Distance-scaled recovery length.
        #expect(PlanEngine.postRaceRecoveryWeeks(forRaceM: 5_000) == 1)
        #expect(PlanEngine.postRaceRecoveryWeeks(forRaceM: 21_097) == 1)
        #expect(PlanEngine.postRaceRecoveryWeeks(forRaceM: 42_195) == 2)
        #expect(PlanEngine.postRaceRecoveryWeeks(forRaceM: 50_000) == 3)

        // A rolling block opening with a 2-week lead-in: both weeks are recovery (all easy, reduced
        // volume, climbing back toward baseline), then training resumes at normal volume.
        var inp = inputs(disciplines: [.running], goal: .endurance, days: 4)
        inp.postRaceRecoveryWeeks = 2
        let plan = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        #expect(plan.weeks.count == PlanEngine.openBlockWeeks)
        #expect(plan.weeks[0].phase == .recovery && plan.weeks[1].phase == .recovery)
        #expect(!plan.weeks[0].sessions.contains { $0.isHardRun })    // nothing hard while absorbing
        #expect(!plan.weeks[1].sessions.contains { $0.isHardRun })
        #expect(plan.weeks[0].runVolumeM < plan.weeks[1].runVolumeM)  // reverse taper climbs…
        #expect(plan.weeks[1].runVolumeM < plan.weeks[2].runVolumeM)  // …back to normal training
        #expect(plan.weeks[2].sessions.contains { $0.isHardRun })     // quality returns after the lead-in
    }

    // MARK: Threshold dose scales with the athlete

    @Test func thresholdDoseScalesWithWeeklyVolume() {
        // Same calendar week, three different athletes: cruise-rep count tracks weekly mileage
        // (Daniels: T volume per session ≈ ≤10% of weekly volume), inside the 4…12 envelope.
        func reps(_ weeklyM: Double) -> Int {
            let q = PlanEngine.qualityWorkout(weekIndex: 12, raceDistanceM: 42_195, level: .experienced,
                                              p5k: 240, weeklyVolumeM: weeklyM)
            guard let iv = q.intervals, iv.contains("×1km") else { return -1 }
            return Int(iv.prefix { $0.isNumber }) ?? -1
        }
        let modest = reps(40_000), big = reps(90_000), elite = reps(150_000)
        if modest > 0, big > 0 { #expect(modest <= big) }
        if big > 0, elite > 0 { #expect(big <= elite) }
        if elite > 0 { #expect(elite <= 12) }
        if modest > 0 { #expect(modest >= 4) }
        // Callers without a volume estimate keep the legacy ceiling (back-compat).
        let legacy = PlanEngine.qualityWorkout(weekIndex: 12, raceDistanceM: 42_195, level: .experienced, p5k: 240)
        if let iv = legacy.intervals, iv.contains("×1km") {
            #expect((Int(iv.prefix { $0.isNumber }) ?? 0) <= 7)
        }
    }

    // MARK: Quality density (the second weekly quality session — PlanIntensity.qualityBias, wired)

    @Test func aggressiveHighVolumeWeekCarriesTwoQualitySessions() {
        var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 5)
        inp.raceDistanceM = 21_097
        inp.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 12,
                                             to: Date(timeIntervalSinceReferenceDate: 0))
        inp.intensity = .aggressive
        inp.currentWeeklyVolumeM = 50_000
        inp.longestRunM = 16_000
        let plan = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))

        // The time-trial week deliberately carries ONE hard run (the test needs fresh legs) —
        // TimeTrialTests owns that pin; here we assert the ordinary build weeks.
        let buildWeeks = plan.weeks.filter { w in w.phase == .build
            && !w.sessions.contains { $0.intervals?.contains("Time trial") == true } }
        #expect(!buildWeeks.isEmpty)
        for week in buildWeeks {
            let quality = week.sessions.filter { $0.isHardRun && $0.runType != .long }
            #expect(quality.count == 2, "build week \(week.index): expected two quality days, got \(quality.count)")
            // The two stimuli differ, and the days are never back-to-back (running-only week has room).
            if quality.count == 2 {
                #expect(quality[0].intervals != quality[1].intervals)
                #expect(abs(quality[0].dayOffset - quality[1].dayOffset) >= 2,
                        "build week \(week.index): quality days adjacent")
            }
            // The week still fills exactly the athlete's day budget.
            #expect(week.sessions.count == 5)
        }
        // Base stays single-quality (pyramidal), taper stays single (freshness).
        for week in plan.weeks where week.phase == .base || week.isTaper {
            #expect(week.sessions.filter { $0.isHardRun && $0.runType != .long }.count <= 1)
        }
    }

    @Test func balancedModestWeekKeepsOneQuality() {
        // The default athlete is untouched by the second-quality slot: balanced intensity, 4 days.
        var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 4, runExp: .some)
        inp.raceDistanceM = 10_000
        inp.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 10,
                                             to: Date(timeIntervalSinceReferenceDate: 0))
        inp.currentWeeklyVolumeM = 30_000
        let plan = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        for week in plan.weeks {
            #expect(week.sessions.filter { $0.isHardRun && $0.runType != .long }.count <= 1)
        }
    }

    @Test func injuryHistoryBlocksTheSecondQualitySlot() {
        // The same protective cap as the ramp: a body that's been hurt gets one quality day, period.
        var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 5)
        inp.raceDistanceM = 21_097
        inp.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 12,
                                             to: Date(timeIntervalSinceReferenceDate: 0))
        inp.intensity = .aggressive
        inp.currentWeeklyVolumeM = 50_000
        inp.injuryHistory = [.knee]
        let plan = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        for week in plan.weeks {
            #expect(week.sessions.filter { $0.isHardRun && $0.runType != .long }.count <= 1)
        }
    }

    // MARK: Easy-day texture (medium-long + recovery jog, not three identical easies)

    @Test func fiveDayWeekHasMediumLongAndRecoveryTexture() {
        var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 5)
        inp.raceDistanceM = 42_195
        inp.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 14,
                                             to: Date(timeIntervalSinceReferenceDate: 0))
        inp.currentWeeklyVolumeM = 42_000
        inp.longestRunM = 14_000
        let plan = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        // A normal training week (not deload/taper) carries a recovery jog and a medium-long run —
        // the fill days are distinct sizes, not one repeated number.
        let week = plan.weeks.first { !$0.isDeload && !$0.isTaper }!
        #expect(week.sessions.contains { $0.runType == .recovery })
        let mediumLong = week.sessions.first { $0.rationale?.contains("Medium-long") ?? false }
        #expect(mediumLong != nil)
        // The medium-long outsizes the recovery jog and stays under the week's true long run.
        let long = week.sessions.first { $0.runType == .long || $0.runType == .progression }?.targetDistanceM ?? 0
        let rec = week.sessions.first { $0.runType == .recovery }?.targetDistanceM ?? 0
        if let ml = mediumLong?.targetDistanceM {
            #expect(ml > rec)
            #expect(ml < long)
        }
    }

    // MARK: 10K band (threshold-centric, not a long 5K)

    @Test func tenKTrainsThresholdNotRawFiveKSpeed() {
        func buildQuality(_ raceM: Double) -> [GeneratedSession] {
            var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 4)
            inp.raceDistanceM = raceM
            inp.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 10,
                                                 to: Date(timeIntervalSinceReferenceDate: 0))
            let plan = PlanEngine.generate(profile: inp, catalog: [],
                                           startDate: Date(timeIntervalSinceReferenceDate: 0))
            return plan.weeks.filter { $0.phase == .build }.flatMap(\.sessions)
                .filter { $0.isHardRun && $0.runType != .long }
        }
        // 10K build work never prescribes "@ 5K" reps; it cruises at threshold with VO₂ touches.
        let tenK = buildQuality(10_000)
        #expect(!tenK.isEmpty)
        #expect(!tenK.contains { $0.intervals?.contains("@ 5K") ?? false })
        #expect(tenK.contains { $0.intervals?.contains("threshold") ?? false })
        // And its taper touch is at RACE pace, not 5K pace (the old menu sharpened too fast).
        let taper = PlanEngine.qualityWorkout(weekIndex: 9, raceDistanceM: 10_000, level: .some,
                                              p5k: 300, phase: .taper)
        #expect(taper.intervals?.contains("race pace") ?? false)
        // 5K plans keep their speed menu (regression guard on the new band boundary).
        #expect(buildQuality(5_000).contains { $0.intervals?.contains("@ 5K") ?? false })
    }

    // MARK: Long-run caps + plateau wave

    @Test func longRunDurationCappedForSlowerRunners() {
        // A 7:00/km-5K athlete's marathon long run caps near 3 h of running, not at 32 km (4+ h).
        var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 4, runExp: .some)
        inp.raceDistanceM = 42_195
        inp.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 16,
                                             to: Date(timeIntervalSinceReferenceDate: 0))
        let seed = CalibrationSeed(recentRun: nil, estimatedP5kSPerKm: 420)
        let plan = PlanEngine.generate(profile: inp, catalog: [], calibration: seed,
                                       startDate: Date(timeIntervalSinceReferenceDate: 0))
        let capM: Double = (10_800.0 / PlanEngine.pace(.long, p5k: 420)) * 1000
        let allSessions: [GeneratedSession] = plan.weeks.flatMap(\.sessions)
        let longs: [GeneratedSession] = allSessions.filter { $0.runType == .long || $0.runType == .progression }
        let maxLong: Double = longs.compactMap(\.targetDistanceM).max() ?? 0
        #expect(maxLong > 0)
        #expect(maxLong <= capM + 1_000, "long run \(maxLong) exceeds the ~3h cap \(capM)")
    }

    @Test func plateauedLongRunOscillatesInsteadOfRepeating() {
        // Once weekly volume holds at its ceiling, the long run waves (1.0/0.88/0.95) — months of
        // identical Sundays were the tell of a template.
        var inp = inputs(disciplines: [.running], goal: .raceDistance, days: 4)
        inp.raceDistanceM = 42_195
        inp.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 24,
                                             to: Date(timeIntervalSinceReferenceDate: 0))
        inp.currentWeeklyVolumeM = 40_000
        inp.longestRunM = 13_000
        let plan = PlanEngine.generate(profile: inp, catalog: [], startDate: Date(timeIntervalSinceReferenceDate: 0))
        // The last stretch of build weeks sits at the plateau: their long runs must not all match.
        let plateauLongs = plan.weeks.filter { $0.phase == .build }.suffix(6)
            .compactMap { week in
                week.sessions.first { $0.runType == .long || $0.runType == .progression }?.targetDistanceM
            }
        #expect(plateauLongs.count >= 3)
        #expect(Set(plateauLongs).count >= 2, "plateau long runs all identical: \(plateauLongs)")
    }

    // MARK: Tempo overflow → cruise intervals

    @Test func oversizedTempoBecomesCruiseIntervals() {
        // A 90 km/wk athlete's tempo allocation (~16 km) far exceeds ~25 min at T — the prescription
        // becomes cruise intervals (same dose, absorbable pieces). weekIndex 1 lands the long-race
        // build menu's tempo slot.
        let big = PlanEngine.qualityWorkout(weekIndex: 1, raceDistanceM: 42_195, level: .experienced,
                                            p5k: 240, weeklyVolumeM: 90_000, qualityDistanceM: 16_000)
        #expect(big.type == .intervals)
        #expect(big.intervals?.contains("threshold") ?? false)
        // A modest allocation keeps the classic continuous tempo.
        let small = PlanEngine.qualityWorkout(weekIndex: 1, raceDistanceM: 42_195, level: .experienced,
                                              p5k: 240, weeklyVolumeM: 40_000, qualityDistanceM: 5_000)
        #expect(small.type == .tempo)
    }

    // MARK: Cruise recovery is short (Daniels ~60 s), regular intervals keep full recovery

    @Test func cruiseIntervalsTakeShortRecoveries() {
        let session = PlannedSession()
        session.discipline = .running
        session.runType = .intervals
        session.intervals = "6×1km @ threshold"
        session.targetPaceSPerKm = 314
        let cruise = StructuredWorkoutBuilder.build(from: session, p5kSPerKm: 300)
        let cruiseRecovery = cruise?.steps.first { $0.kind == .recovery }
        #expect(cruiseRecovery?.target == .duration(60))

        session.intervals = "6×1km @ 5K"
        session.targetPaceSPerKm = 300
        let speed = StructuredWorkoutBuilder.build(from: session, p5kSPerKm: 300)
        let speedRecovery = speed?.steps.first { $0.kind == .recovery }
        // Full recovery on kilometre reps is a real 3:00 (2026-07-24 rest-ladder fix — 2:00 was
        // quietly collapsing long VO₂ reps into tempo effort).
        #expect(speedRecovery?.target == .duration(180))
    }
}

/// The shipped library, run through the real `PlanService.catalog` mapping — the step the plank
/// fix actually depends on. A unit test against a hand-built fixture would still pass if the
/// service forgot to forward `trackingMode`, which is exactly how the bug reached users.
@MainActor
struct RealLibraryPrescriptionTests {

    /// Mirrors `PlanService.catalog(in:)` over `ExerciseLibrarySeed.curated`, so a regression in
    /// either the seed's tracking modes or the catalog mapping fails here.
    private var catalog: [ExerciseCatalogItem] {
        ExerciseLibrarySeed.curated.map { ex in
            ExerciseCatalogItem(
                name: ex.name,
                primaryMuscles: ex.primaryMuscles.compactMap(MuscleGroup.init(rawValue:)),
                secondaryMuscles: ex.secondaryMuscles.compactMap(MuscleGroup.init(rawValue:)),
                equipment: ex.equipment, category: ex.category, defaultRestS: ex.defaultRestS,
                trackingMode: ex.trackingMode)
        }
    }

    /// End-to-end on the shipped library: core work is countable, and nothing timed is ever
    /// handed a rep range. A fixture-only test would still pass if `PlanService.catalog` forgot
    /// to forward `trackingMode` — which is exactly how this reached users.
    @Test func shippedLibraryPrescribesCountableCoreWork() {
        for goal in [Goal.buildMuscle, .getStronger, .generalFitness] {
            let plan = PlanEngine.generate(
                profile: PlanInputs(disciplines: [.strength], goal: goal, daysPerWeek: 4,
                                    equipment: .fullGym, sessionMinutes: 60, raceDate: nil,
                                    runningExperience: .experienced, liftingExperience: .some),
                catalog: catalog, startDate: Date(timeIntervalSinceReferenceDate: 0))
            let names = plan.weeks.flatMap(\.sessions).flatMap(\.strengthTargets).map(\.exerciseName)
            #expect(!names.contains("Plank"), "shipped library still prescribes a plank for goal=\(goal)")
        }
    }

    @Test func shippedLibraryNeverPrescribesRepsForATimedExercise() {
        let timedNames = Set(ExerciseLibrarySeed.curated
            .filter { $0.trackingMode == .time || $0.trackingMode == .distance }
            .map(\.name))
        #expect(!timedNames.isEmpty, "library has no timed exercises — did the seed change?")

        for goal in [Goal.buildMuscle, .getStronger, .generalFitness, .endurance] {
            let plan = PlanEngine.generate(
                profile: PlanInputs(disciplines: [.strength], goal: goal, daysPerWeek: 4,
                                    equipment: .fullGym, sessionMinutes: 60, raceDate: nil,
                                    runningExperience: .experienced, liftingExperience: .some),
                catalog: catalog, startDate: Date(timeIntervalSinceReferenceDate: 0))
            for ex in plan.weeks.flatMap(\.sessions).flatMap(\.strengthTargets)
            where timedNames.contains(ex.exerciseName) {
                #expect(ex.targetHoldS != nil,
                        "\(ex.exerciseName) prescribed \(ex.repLow)–\(ex.repHigh) reps for goal=\(goal)")
            }
        }
    }

    /// The athlete-facing string — the thing the user actually reported seeing.
    @Test func planFormatsAHoldInSecondsNotReps() {
        let plank = PlannedExercise()
        plank.targetSets = 3; plank.targetRepLow = 1; plank.targetRepHigh = 1; plank.targetHoldS = 45
        #expect(plank.prescriptionText == "3 × 45s")

        let squat = PlannedExercise()
        squat.targetSets = 4; squat.targetRepLow = 8; squat.targetRepHigh = 12
        #expect(squat.prescriptionText == "4 × 8–12")
    }
}
