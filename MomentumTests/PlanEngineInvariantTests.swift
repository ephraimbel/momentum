import Testing
import Foundation
@testable import Momentum

/// Property-based sweep over the whole plan-generation input space. Where the fixture tests pin
/// specific behaviors, these assert the invariants that must hold for EVERY plan the engine can
/// produce — any goal, any experience, any day count, any race distance, any runway from race week
/// to 30 weeks out, any injury history, any intensity. If a combination violates safety or honesty,
/// this suite names it.
struct PlanEngineInvariantTests {

    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private let cal = Calendar.current

    private func race(weeksOut: Int) -> Date { cal.date(byAdding: .weekOfYear, value: weeksOut, to: start)! }

    private func catalogFixture() -> [ExerciseCatalogItem] {
        func item(_ n: String, _ m: MuscleGroup, _ cat: ExerciseCategory) -> ExerciseCatalogItem {
            ExerciseCatalogItem(name: n, primaryMuscles: [m], secondaryMuscles: [],
                                equipment: .barbell, category: cat, defaultRestS: 120)
        }
        return [item("Squat", .quads, .compound), item("Bench", .chest, .compound),
                item("Row", .back, .compound), item("OHP", .shoulders, .compound),
                item("RDL", .hamstrings, .compound), item("Curl", .biceps, .isolation),
                item("Plank", .core, .isolation), item("Calf Raise", .calves, .isolation)]
    }

    /// Every hard safety/honesty invariant, checked against one generated plan.
    private func assertInvariants(_ plan: GeneratedPlan, inputs: PlanInputs, label: String) {
        #expect(!plan.weeks.isEmpty, "\(label): empty plan")
        #expect(plan.weeks.count <= 52, "\(label): horizon exceeded")

        let hasRunning = inputs.disciplines.contains(.running)
        let raceWeeks = PlanEngine.weeksToRace(startDate: start, raceDate: inputs.raceDate, calendar: cal)
        let raceInWindow = (raceWeeks ?? .max) <= plan.weeks.count
        // Mirrors the engine's activation rule: Podium's structural upgrades (incl. the rest-day
        // shakeout) apply only on a 5+ run-day week with no injury history.
        let podiumActive = inputs.intensity == .podium && !inputs.disciplines.contains(.strength)
            && inputs.daysPerWeek >= 5 && inputs.injuryHistory.isEmpty

        // Honesty of the macro shape.
        if let rw = raceWeeks {
            #expect(plan.weeks.count == min(52, max(1, rw)), "\(label): plan length ≠ runway")
            if raceInWindow {
                #expect(plan.weeks.last?.isTaper == true, "\(label): no taper before the race")
                // Short runways never pretend there's a base/peak to build — only sharpening and taper.
                if rw <= 3 {
                    #expect(plan.weeks.allSatisfy { $0.isTaper || $0.phase == .build },
                            "\(label): short runway grew a base/peak phase")
                }
            } else {
                #expect(!plan.weeks.contains { $0.isTaper || $0.phase == .peak },
                        "\(label): phantom taper/peak with race beyond window")
            }
        }

        // The progression invariant: the finished plan stays a near-fixed-point of its own legacy-
        // named recent-to-usual load governor
        // governor. Clean-distance snapping (RunRounding) is the very last step and perturbs weekly
        // volume by <2%, so re-running the governor may want a hair off a capped week — but never a
        // meaningful cut. Assert no week exceeds the 1.3× cap by more than one rounding increment's
        // worth (factor ≥ 0.95 ⇒ ≤ ~1.37× recent norm, inside the rounding tolerance).
        if hasRunning {
            let factors = ACWRGovernor.capFactors(weeklyMeters: plan.weeks.map(\.runVolumeM),
                                                  currentWeeklyM: inputs.currentWeeklyVolumeM ?? 0)
            #expect(factors.allSatisfy { $0 >= 0.95 }, "\(label): a week ramps dangerously past 1.3× chronic")
        }

        var lastBuildVol: Double?
        for week in plan.weeks {
            // Scheduling invariants — every week, every combination.
            let days = week.sessions.map(\.dayOffset)
            #expect(days.allSatisfy { (0...6).contains($0) }, "\(label) w\(week.index): day offset out of week")
            #expect(Set(days).count == days.count, "\(label) w\(week.index): two sessions share a day")
            // Race week is the one legitimate exception to the exact day-count: race day clears
            // itself and everything after it, then adds the race — so the week holds the race plus
            // whatever training survived before it. Every other week fills the athlete's day budget.
            if let raceIdx = week.sessions.firstIndex(where: { $0.runType == .race }) {
                #expect(week.sessions.count <= min(7, inputs.daysPerWeek) + 1,
                        "\(label) w\(week.index): race week overfilled")
                let raceDay = week.sessions[raceIdx].dayOffset
                #expect(!week.sessions.contains { $0.runType != .race && $0.dayOffset >= raceDay },
                        "\(label) w\(week.index): training scheduled on/after race day")
            } else {
                // Podium training weeks carry one extra OPTIONAL shakeout on a rest day (never on
                // deload/taper/lead-in weeks) — the one sanctioned exception to the exact day budget.
                let shakeout = podiumActive && !week.isDeload && !week.isTaper
                    && week.phase != .recovery && inputs.daysPerWeek <= 6 ? 1 : 0
                #expect(week.sessions.count == min(7, inputs.daysPerWeek) + shakeout,
                        "\(label) w\(week.index): wrong session count")
            }
            #expect(PlanEngine.scheduleSatisfiesRecovery(week.sessions),
                    "\(label) w\(week.index): hard run the day after a heavy lower lift")

            // Down weeks (deload/taper) always dip below the last build week — a "recovery" week
            // that grows is a lie. (Week-over-week progression is the fixed-point check above.)
            if week.isDeload || week.isTaper {
                if let prev = lastBuildVol, hasRunning, prev > 0 {
                    #expect(week.runVolumeM < prev, "\(label) w\(week.index): down week didn't dip")
                }
            } else if hasRunning {
                lastBuildVol = week.runVolumeM
            }

            for s in week.sessions where s.discipline == .running {
                // Pace sanity on every prescribed session.
                if let p = s.targetPaceSPerKm {
                    #expect(p.isFinite && p >= 120 && p <= 1200, "\(label) w\(week.index): insane pace \(p)")
                }
                // Long runs never exceed the race-appropriate cap — allow one whole unit of slack,
                // since clean-distance snapping can round a capped long run up to the next round
                // km/mi (e.g. an 18.99 km half-cap reads as a clean "19 km"). Coaching-irrelevant.
                if let raceM = inputs.raceDistanceM, s.runType == .long || s.runType == .progression {
                    let peakWeek = plan.weeks.map(\.runVolumeM).max()
                    #expect((s.targetDistanceM ?? 0) <= PlanEngine.longRunPeak(forRaceM: raceM, podium: podiumActive, weekVolumeM: peakWeek) + 1_000,
                            "\(label) w\(week.index): long run above cap")
                }
                // The auto-plan never requires terrain — hills are library-only (2026-07-24), so no
                // generated session, for any athlete, prescribes them.
                #expect(s.runType != .hills, "\(label) w\(week.index): auto-plan required a hill")
                if !Set(inputs.injuryHistory).isDisjoint(with: PlanEngine.speedSensitiveAreas) {
                    #expect(s.runType != .strides, "\(label) w\(week.index): strides despite speed-sensitive history")
                    #expect(s.intervals?.contains("@ 5K") != true, "\(label) w\(week.index): sprint reps despite history")
                }
                // Clean prescriptions: every stored pace is already snapped in the athlete's unit
                // (re-snapping must be a no-op) — no 8:24/mi ever reaches a plan.
                if s.discipline == .running, let p = s.targetPaceSPerKm, let rt = s.runType {
                    #expect(abs(RunRounding.snapPace(sPerKm: p, unit: inputs.distanceUnit, type: rt) - p) < 0.001,
                            "\(label) w\(week.index): unsnapped pace \(p) on \(rt)")
                }
            }
            // Deload weeks never carry a quality running session.
            if week.isDeload {
                #expect(!week.sessions.contains { $0.isHardRun }, "\(label) w\(week.index): quality on a deload")
            }
        }

        // Volume ceiling: with a seeded start, the plan grows toward the race-appropriate peak (or
        // 2× for no-race blocks) and never past it — and never more than 3.5× the start regardless.
        if hasRunning, let seeded = inputs.currentWeeklyVolumeM, seeded > 0 {
            let maxVol = plan.weeks.map(\.runVolumeM).max() ?? 0
            // Podium adds a ~3 km optional shakeout per training week (stacked on the capped
            // volume, plus clean-distance rounding drift across a 6-session week) — deliberate
            // and bounded, so the tolerance names it. The ceiling is the goal-driven peak
            // (2026-08-28): tier-scaled, goal-time floored, capped by the athlete's own ceiling;
            // injury history holds the tier at Balanced exactly as the engine does.
            let shakeoutAllowance = podiumActive ? 4_500.0 : 0
            let peakTier: PlanIntensity = (inputs.injuryHistory.isEmpty || inputs.intensity == .gentle) ? inputs.intensity : .balanced
            let ceiling = inputs.raceDistanceM.map {
                max(seeded, PlanFeasibility.peakWeeklyVolumeM(distanceM: $0, experience: inputs.runningExperience,
                                                              intensity: peakTier, goalFinishTimeS: inputs.goalFinishTimeS,
                                                              currentWeeklyM: seeded, targetWeeklyM: inputs.targetWeeklyVolumeM))
            } ?? seeded * 2.0
            // ×1.03: clean-distance snapping rounds a few sessions up to the next whole mile/km.
            #expect(maxVol <= ceiling * 1.03 + shakeoutAllowance + 10, "\(label): volume ceiling breached (\(maxVol) vs \(ceiling))")
            #expect(maxVol <= seeded * 3.5 + shakeoutAllowance + 10, "\(label): asked to more than 3.5× the starting load")
        }
    }

    @Test func everyRunwayEveryLevelEveryDistanceHoldsInvariants() {
        let catalog = catalogFixture()
        // 50K appears at three runways — crash build, the honest 16-week floor's neighborhood,
        // and a long patient block — since the catalog now offers real 50K ultras (2026-07-30).
        let races: [(Double?, Int?)] = [(nil, nil), (5_000, 2), (5_000, 10), (10_000, 8), (21_097, 12),
                                        (42_195, 2), (42_195, 16), (50_000, 8), (50_000, 20), (50_000, 32),
                                        (42_195, 30), (42_195, 52), (42_195, 60)]
        for (raceM, weeksOut) in races {
            for exp in [ExperienceLevel.new, .some, .experienced] {
                for days in [2, 3, 4, 5, 6] {
                    var inp = PlanInputs(disciplines: [.running], goal: raceM != nil ? .raceDistance : .endurance,
                                         daysPerWeek: days, equipment: .fullGym, sessionMinutes: 45,
                                         raceDate: weeksOut.map(race(weeksOut:)),
                                         runningExperience: exp, liftingExperience: .some)
                    inp.raceDistanceM = raceM
                    let plan = PlanEngine.generate(profile: inp, catalog: catalog, startDate: start)
                    assertInvariants(plan, inputs: inp,
                                     label: "race \(raceM.map { Int($0) } ?? 0)@\(weeksOut ?? 0)wk \(exp) \(days)d")
                }
            }
        }
    }

    @Test func intensityInjuryAgeAndSeedingHoldInvariants() {
        let catalog = catalogFixture()
        for intensity in PlanIntensity.allCases {
            for injuries in [[], [InjuryArea.shins], [.hamstring], [.knee, .hamstring]] {
                for age in [nil, 34, 57] as [Int?] {
                    for seeded in [nil, 30_000.0] as [Double?] {
                      for days in [4, 6] {   // 4 exercises Podium's graceful degradation; 6 its full form
                        var inp = PlanInputs(disciplines: [.running], goal: .raceDistance,
                                             daysPerWeek: days, equipment: .fullGym, sessionMinutes: 45,
                                             raceDate: race(weeksOut: 12),
                                             runningExperience: .some, liftingExperience: .some)
                        inp.raceDistanceM = 10_000
                        inp.intensity = intensity
                        inp.injuryHistory = injuries
                        inp.age = age
                        inp.currentWeeklyVolumeM = seeded
                        inp.longestRunM = seeded.map { $0 / 3 }
                        let plan = PlanEngine.generate(profile: inp, catalog: catalog, startDate: start)
                        assertInvariants(plan, inputs: inp,
                                         label: "\(intensity) inj\(injuries.count) age\(age ?? 0) seed\(Int(seeded ?? 0)) \(days)d")
                      }
                    }
                }
            }
        }
    }

    @Test func hybridPlansHoldInvariantsAcrossGoals() {
        let catalog = catalogFixture()
        for goal in [Goal.raceDistance, .endurance, .buildMuscle, .getStronger, .generalFitness, .stayConsistent] {
            for days in [3, 4, 5, 6] {
                var inp = PlanInputs(disciplines: [.running, .strength], goal: goal,
                                     daysPerWeek: days, equipment: .fullGym, sessionMinutes: 60,
                                     raceDate: goal == .raceDistance ? race(weeksOut: 10) : nil,
                                     runningExperience: .some, liftingExperience: .some)
                if goal == .raceDistance { inp.raceDistanceM = 21_097 }
                let plan = PlanEngine.generate(profile: inp, catalog: catalog, startDate: start)
                assertInvariants(plan, inputs: inp, label: "hybrid \(goal) \(days)d")
                // Hybrid weeks actually contain both disciplines when days allow it.
                if days >= 3 {
                    let w0 = plan.weeks[0].sessions
                    #expect(w0.contains { $0.discipline == .running } && w0.contains { $0.discipline == .strength },
                            "hybrid \(goal) \(days)d: a discipline vanished")
                }
            }
        }
    }

    @Test func generationIsDeterministic() {
        // Identical inputs → byte-identical plans. Adaptation, sync, and honest explanations all
        // depend on this — no hidden randomness or date leakage.
        var inp = PlanInputs(disciplines: [.running, .strength], goal: .raceDistance,
                             daysPerWeek: 5, equipment: .fullGym, sessionMinutes: 60,
                             raceDate: race(weeksOut: 14), runningExperience: .experienced,
                             liftingExperience: .some)
        inp.raceDistanceM = 42_195
        inp.injuryHistory = [.shins]
        inp.currentWeeklyVolumeM = 40_000
        inp.longestRunM = 14_000
        let a = PlanEngine.generate(profile: inp, catalog: catalogFixture(), startDate: start)
        let b = PlanEngine.generate(profile: inp, catalog: catalogFixture(), startDate: start)
        #expect(a == b)
    }
}
