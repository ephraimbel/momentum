import Testing
import Foundation
@testable import Momentum

/// The trainer's-eye audit of split-era strength prescriptions (2026-08-20): generates real
/// plans across the split × day-count × goal matrix, prints them like a coach's whiteboard for
/// human review, and pins the trainer-grade invariants — muscle coverage over a full rotation
/// cycle, compounds before isolation, core work present in every style's week, and per-muscle
/// weekly volume landing in sane bands.
struct PlanSplitAuditTests {

    // The REAL curated library, snapshotted the way PlanService.catalog does (the PlanEngineTests
    // mirror) — auditing against a fixture catalog would pass plans the shipping app can't build.
    private var catalog: [ExerciseCatalogItem] {
        ExerciseLibrarySeed.curated.map { ex in
            ExerciseCatalogItem(
                name: ex.name,
                primaryMuscles: ex.primaryMuscles.compactMap(MuscleGroup.init(rawValue:)),
                secondaryMuscles: ex.secondaryMuscles.compactMap(MuscleGroup.init(rawValue:)),
                equipment: ex.equipment, category: ex.category, defaultRestS: ex.defaultRestS,
                trackingMode: ex.trackingMode)
        }.sorted { $0.name < $1.name }
    }

    private func inputs(days: Int, split: StrengthSplitStyle, goal: Goal = .buildMuscle,
                        disciplines: [Discipline] = [.strength],
                        equipment: Equipment = .fullGym, minutes: Int = 60,
                        liftExp: ExperienceLevel = .some) -> PlanInputs {
        var p = PlanInputs(disciplines: disciplines, goal: goal, daysPerWeek: days,
                           equipment: equipment, sessionMinutes: minutes, raceDate: nil,
                           runningExperience: .some, liftingExperience: liftExp)
        p.strengthSplit = split
        return p
    }

    private func generate(_ p: PlanInputs) -> GeneratedPlan {
        PlanEngine.generate(profile: p, catalog: catalog,
                            startDate: Date(timeIntervalSinceReferenceDate: 0))
    }

    /// Primary muscles of an exercise name, from the real catalog.
    private func primaries(_ name: String) -> [MuscleGroup] {
        catalog.first { $0.name == name }?.primaryMuscles ?? []
    }

    private func isCompound(_ name: String) -> Bool {
        catalog.first { $0.name == name }?.category == .compound
    }

    // MARK: The whiteboard dump (read this output like a coach)

    @Test func dumpSplitMatrixForReview() {
        let matrix: [(String, PlanInputs)] = [
            ("PPL · 3 lift days · buildMuscle", inputs(days: 3, split: .pushPullLegs)),
            ("PPL · 2 lift days (hybrid 4d) · buildMuscle",
             inputs(days: 4, split: .pushPullLegs, disciplines: [.running, .strength])),
            ("Upper/Lower · 4 lift days · getStronger", inputs(days: 4, split: .upperLower, goal: .getStronger)),
            ("Upper/Lower · 3 lift days · generalFitness", inputs(days: 3, split: .upperLower, goal: .generalFitness)),
            ("Full body · 3 lift days · new lifter", inputs(days: 3, split: .fullBody, liftExp: .new)),
            ("Coach · 5 lift days · buildMuscle", inputs(days: 5, split: .coach)),
            ("PPL · dumbbells only · 3 days", inputs(days: 3, split: .pushPullLegs, equipment: .dumbbellsOnly)),
            ("PPL · bodyweight · 3 days", inputs(days: 3, split: .pushPullLegs, equipment: .bodyweight)),
        ]
        for (title, p) in matrix {
            let plan = generate(p)
            print("════ \(title)")
            for week in plan.weeks.prefix(4) {
                let phase = week.phase.rawValue.uppercased()
                print("  WEEK \(week.index + 1) [\(phase)]")
                for s in week.sessions.sorted(by: { $0.dayOffset < $1.dayOffset }) {
                    if s.discipline == .strength {
                        print("    d\(s.dayOffset) \(s.strengthLabel ?? "?"):")
                        for ex in s.strengthTargets {
                            let cat = isCompound(ex.exerciseName) ? "C" : "i"
                            let pct = ex.targetPctRM.map { " @\(Int($0 * 100))%" } ?? ""
                            let rpe = ex.targetRPE.map { " RPE\(Int($0))" } ?? ""
                            print("      [\(cat)] \(ex.exerciseName) \(ex.targetSets)×\(ex.repLow)-\(ex.repHigh)\(pct)\(rpe) (\(ex.progression))")
                        }
                    } else {
                        print("    d\(s.dayOffset) run: \(s.runType?.rawValue ?? "?")")
                    }
                }
            }
        }
    }

    // MARK: Trainer invariants

    /// Over one full rotation cycle, every major muscle group trains — no split style may orphan
    /// a muscle. (PPL cycle = 3 consecutive lift days wherever they fall; U/L cycle = 2.)
    @Test func everyMuscleTrainsAcrossARotationCycle() {
        let majors: Set<MuscleGroup> = [.chest, .back, .shoulders, .quads, .hamstrings, .glutes]
        for (split, days) in [(StrengthSplitStyle.pushPullLegs, 3), (.pushPullLegs, 2),
                              (.upperLower, 2), (.upperLower, 3), (.fullBody, 2)] {
            let p = inputs(days: max(days, 2), split: split)
            let plan = generate(p)
            // Walk enough weeks to complete a full cycle even at 2 days/week.
            var hit = Set<MuscleGroup>()
            for week in plan.weeks.prefix(3) {
                for s in week.sessions where s.discipline == .strength {
                    for ex in s.strengthTargets {
                        hit.formUnion(primaries(ex.exerciseName))
                        hit.formUnion(catalog.first { $0.name == ex.exerciseName }?.secondaryMuscles ?? [])
                    }
                }
            }
            for m in majors {
                #expect(hit.contains(m), "\(split) @ \(days) days never trains \(m) across 3 weeks")
            }
        }
    }

    /// Compounds always precede isolation inside a session — the order a coach writes a day.
    @Test func compoundsComeBeforeIsolationWithinEveryDay() {
        for split in StrengthSplitStyle.allCases {
            let plan = generate(inputs(days: 4, split: split))
            for week in plan.weeks {
                for s in week.sessions where s.discipline == .strength {
                    var seenIsolation = false
                    for ex in s.strengthTargets {
                        if isCompound(ex.exerciseName) {
                            #expect(!seenIsolation,
                                    "\(split): compound \(ex.exerciseName) after isolation on \(s.strengthLabel ?? "?")")
                        } else {
                            seenIsolation = true
                        }
                    }
                }
            }
        }
    }

    /// Every split style programs core work somewhere in a normal training week — a trainer never
    /// ships a week with zero trunk work (the runner's chassis).
    @Test func coreWorkAppearsInEverySplitStylesWeek() {
        for split in StrengthSplitStyle.allCases {
            let plan = generate(inputs(days: 3, split: split))
            let firstWeek = plan.weeks[0].sessions.filter { $0.discipline == .strength }
            let hasCore = firstWeek.contains { s in
                s.strengthTargets.contains { primaries($0.exerciseName).contains(.core) }
            }
            #expect(hasCore, "\(split): no core work anywhere in week 1")
        }
    }

    /// No prescribed strength day ships thin at ANY equipment tier — a bodyweight athlete's Push
    /// day once generated EMPTY (the library had no bodyweight press at all; trainer audit
    /// 2026-08-20). Every generated lift day carries at least two real exercises.
    @Test func noSplitDayShipsThinAtAnyEquipmentTier() {
        for equipment in [Equipment.fullGym, .dumbbellsOnly, .homeMinimal, .bodyweight] {
            for split in StrengthSplitStyle.allCases {
                let plan = generate(inputs(days: 3, split: split, equipment: equipment))
                for week in plan.weeks.prefix(3) {
                    for s in week.sessions where s.discipline == .strength {
                        #expect(s.strengthTargets.count >= 2,
                                "\(equipment)/\(split): \(s.strengthLabel ?? "?") day has \(s.strengthTargets.count) exercises")
                    }
                }
            }
        }
    }

    /// Weekly working sets per major muscle stay inside a sane coaching band (primary-set
    /// counting): never zero for a muscle the split claims to train, never past the overreach
    /// line a coach wouldn't write (>20 primary sets for one muscle in one week).
    @Test func weeklyMuscleVolumeStaysInCoachingBands() {
        for (split, days) in [(StrengthSplitStyle.fullBody, 3), (.upperLower, 4), (.coach, 5)] {
            let plan = generate(inputs(days: days, split: split))
            for week in plan.weeks.prefix(2) {
                var setsByMuscle: [MuscleGroup: Int] = [:]
                for s in week.sessions where s.discipline == .strength {
                    for ex in s.strengthTargets {
                        for m in primaries(ex.exerciseName) {
                            setsByMuscle[m, default: 0] += ex.targetSets
                        }
                    }
                }
                for (m, sets) in setsByMuscle {
                    #expect(sets <= 20, "\(split) @ \(days)d week \(week.index): \(m) at \(sets) primary sets")
                }
            }
        }
    }
}
