import Testing
import Foundation
@testable import Momentum

/// The coach's audit, part three (2026-08-30): the routes through onboarding that parts one and
/// two never walked, and the doses themselves.
///
/// Parts one and two judged a plan's SHAPE (distribution, progression, absorption, taper) and its
/// FIT (paces, days, session length) on the mainstream routes — a runner, three to six days, a
/// race in the window. This part walks the rest of the door: the two-day hybrid whose week holds
/// exactly one run, the athlete who chose Cycle or Walk instead of Run, either end of the fitness
/// range (a 12-minute 5K and a 60-minute one), every injury the injuries step offers, the mileage
/// ceiling, the imperial athlete, a race on Saturday and a race next year.
///
/// It also judges what no earlier bar looked at: **the size of the hard dose against the athlete's
/// own mileage**. Daniels budgets quality as a fraction of the week — threshold ≈ 10%, intervals
/// ≈ 8%, never a fixed rep count — because six kilometres of threshold is a session for a
/// 60 km/week runner and a race for a 26 km/week one. A plan that hands both the same workout is
/// a template with a pace column, which is the thing this engine exists not to be.
struct PlanCoachAuditPart3Tests {

    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private let cal = Calendar.current
    private func race(weeksOut: Int) -> Date { cal.date(byAdding: .day, value: (weeksOut - 1) * 7 + 6, to: start)! }

    private struct Finding: CustomStringConvertible {
        let route: String, bar: String, detail: String
        var description: String { "  ✗ [\(bar)] \(route) — \(detail)" }
    }

    private func report(_ findings: [Finding], _ title: String) {
        guard !findings.isEmpty else { print("\n════ \(title): clean ════"); return }
        var byBar: [String: [Finding]] = [:]
        for f in findings { byBar[f.bar, default: []].append(f) }
        var out = "\n════ \(title): \(findings.count) findings across \(byBar.count) bars ════\n"
        for (bar, list) in byBar.sorted(by: { $0.value.count > $1.value.count }) {
            out += "\n\(bar) — \(list.count)\n"
            for f in list.prefix(6) { out += "\(f)\n" }
            if list.count > 6 { out += "  … \(list.count - 6) more\n" }
        }
        print(out)
    }

    /// The catalog the app actually ships — not a fixture. A strength day built from a hand-made
    /// list of six barbell moves proves nothing about the athlete who picked "Bodyweight".
    private var catalog: [ExerciseCatalogItem] {
        ExerciseLibrarySeed.curated
            .sorted { $0.name < $1.name }
            .map { ex in
                ExerciseCatalogItem(name: ex.name,
                                    primaryMuscles: ex.primaryMuscles.compactMap(MuscleGroup.init(rawValue:)),
                                    secondaryMuscles: ex.secondaryMuscles.compactMap(MuscleGroup.init(rawValue:)),
                                    equipment: ex.equipment, category: ex.category,
                                    defaultRestS: ex.defaultRestS, trackingMode: ex.trackingMode)
            }
    }

    private func base(disciplines: [Discipline] = [.running], goal: Goal = .raceDistance,
                      days: Int = 5, raceM: Double? = 21_097, weeksOut: Int? = 16,
                      exp: ExperienceLevel = .some, seedKm: Double? = 40,
                      intensity: PlanIntensity = .balanced) -> PlanInputs {
        var i = PlanInputs(disciplines: disciplines, goal: goal, daysPerWeek: days, equipment: .fullGym,
                           sessionMinutes: 45, raceDate: weeksOut.map(race(weeksOut:)),
                           runningExperience: exp, liftingExperience: .some,
                           raceDistanceM: raceM, intensity: intensity)
        if let seedKm {
            i.currentWeeklyVolumeM = seedKm * 1_000
            i.longestRunM = seedKm * 1_000 * 0.3
        }
        return i
    }

    private func plan(_ i: PlanInputs, calibration: CalibrationSeed = .none) -> GeneratedPlan {
        PlanEngine.generate(profile: i, catalog: catalog, calibration: calibration,
                            startDate: start, calendar: cal)
    }

    // MARK: What kind of hard, and how much of it

    private enum Zone { case threshold, interval, racePace, testEffort }

    /// The zone a hard session's dose is run at, read from the prescription the athlete sees.
    private func zone(_ s: GeneratedSession) -> Zone? {
        guard s.isHardRun, s.runType != .race else { return nil }
        let note = (s.intervals ?? "").lowercased()
        if note.contains("time trial") { return .testEffort }
        if note.contains("race pace") { return .racePace }
        if note.contains("threshold") { return .threshold }
        if StructuredWorkoutBuilder.parseTimeReps(s.intervals) != nil { return .interval }
        if s.runType == .tempo { return .threshold }
        return .interval
    }

    /// Meters actually run AT that zone — the number a coach budgets, not the size of the session
    /// that contains it (a 10 km session built from 5×1km is 5 km of work and 5 km of everything
    /// else).
    private func doseM(_ s: GeneratedSession) -> Double {
        let note = (s.intervals ?? "").lowercased()
        if note.contains("time trial") { return 5_000 }
        if note.hasPrefix("last"), let km = Double(note.dropFirst(5).prefix(while: { $0.isNumber || $0 == "." })) {
            return km * 1_000
        }
        if let d = StructuredWorkoutBuilder.parseIntervals(s.intervals) {
            return Double(d.reps) * d.distanceM
        }
        if let t = StructuredWorkoutBuilder.parseTimeReps(s.intervals) {
            return (Double(t.reps) * t.seconds) / (s.targetPaceSPerKm ?? 300) * 1_000
        }
        // A continuous steady run carries a warm-up/cool-down carve inside the prescription.
        if s.runType == .tempo { return max(0, (s.targetDistanceM ?? 0) - 2_000) }
        return s.targetDistanceM ?? 0
    }

    private func minutes(_ s: GeneratedSession, fallbackPace: Double) -> Double {
        ((s.targetDistanceM ?? 0) / 1_000) * (s.targetPaceSPerKm ?? fallbackPace) / 60
    }

    // MARK: The audit

    private func audit(_ plan: GeneratedPlan, _ i: PlanInputs, _ route: String) -> [Finding] {
        var out: [Finding] = []
        func fail(_ bar: String, _ detail: String) { out.append(Finding(route: route, bar: bar, detail: detail)) }
        let p5k = plan.p5kSPerKm
        let intervalPace = PlanEngine.pace(.intervals, p5k: p5k)
        let podium = i.intensity == .podium

        for w in plan.weeks {
            let runs = w.sessions.filter { $0.discipline == .running }
            let weekM = w.runVolumeM
            // How many days this athlete's week is spread across — the shape every share bar
            // below is read against.
            let runDays = plan.weeks.first { !$0.isDeload && !$0.isTaper }
                .map { $0.sessions.filter { $0.discipline == .running }.count } ?? runs.count
            var weeklyDose = 0.0

            for s in runs {
                guard let z = zone(s) else { continue }
                let dose = doseM(s)
                // Goal-pace running for a half or longer sits AT or below the lactate threshold,
                // so it is aerobic work with a specificity purpose, not a hard day — Daniels
                // budgets M separately from T, I and R for exactly this reason, and part one's
                // audit gives it its own ceiling. Counting it here would condemn the Pfitzinger
                // staple every marathon build is made of. For 5K and 10K, race pace IS
                // threshold-or-faster and it counts.
                let racePaceIsAerobic = (i.raceDistanceM ?? 0) >= 20_000 && z == .racePace
                if !racePaceIsAerobic { weeklyDose += dose }
                let session = s.targetDistanceM ?? 0

                // A. The dose is a fraction of the athlete's week, not a fixed rep count.
                //    Daniels: threshold ≈ 10% of weekly mileage per session, intervals ≈ 8%.
                //
                //    Two calibrations, both the same ones parts one and two arrived at for the
                //    long run. First, the share a coach signs rises as the days fall: with two
                //    sessions a week the quality HAS to concentrate — that is the trade the
                //    athlete made when they chose two days, and Daniels' percentages assume a
                //    five-to-seven-day week. Second, a percentage is the wrong instrument on a
                //    small week: twelve minutes at threshold is twelve minutes at threshold
                //    whether it lands in a 10 km week or a 60 km one, so a modest absolute dose
                //    is never a finding.
                if weekM > 0 {
                    let share = dose / weekM
                    let tShare: Double = runDays >= 4 ? 0.16 : runDays == 3 ? 0.20 : 0.26
                    let iShare: Double = runDays >= 4 ? 0.12 : runDays == 3 ? 0.15 : 0.18
                    switch z {
                    case .threshold where share > tShare && dose > 3_500:
                        fail("threshold dose", "w\(w.index) runs \(Int(dose))m at threshold — \(Int(share * 100))% of a \(Int(weekM / 1000))km week")
                    case .interval where share > iShare && dose > 3_000:
                        fail("interval dose", "w\(w.index) runs \(Int(dose))m at interval pace — \(Int(share * 100))% of a \(Int(weekM / 1000))km week")
                    default: break
                    }
                }
                // B. …and it fits inside the session that carries it. Reps need a warm-up, a
                //    cool-down, and a jog between them; a prescription whose dose is nearly the
                //    whole session is one the athlete cannot actually run as written.
                if session > 0, dose > session * 0.8, z != .testEffort {
                    fail("prescription fit", "w\(w.index) \(s.intervals ?? "steady") is \(Int(dose))m of work inside a \(Int(session))m session")
                }
                // C. Time on feet. Three hours is the ceiling a coach works to (podium 3.5);
                //    a new runner's ceiling is two. A repeat session is timed honestly: its
                //    stored pace is the REP pace, and the rest of the session is jogging.
                let mins = dose > 0 && dose < (s.targetDistanceM ?? 0)
                    ? (dose / 1_000) * (s.targetPaceSPerKm ?? p5k) / 60
                        + (((s.targetDistanceM ?? 0) - dose) / 1_000) * PlanEngine.pace(.easy, p5k: p5k) / 60
                    : minutes(s, fallbackPace: p5k)
                let cap = i.runningExperience == .new ? 120.0 : (podium ? 210 : 185)
                if mins > cap {
                    fail("time on feet", "w\(w.index) \(s.runType.map { "\($0)" } ?? "run") is \(Int(mins)) minutes")
                }
                // D. Protection means removing the stimulus that hurt them. A shin, knee, IT band,
                //    ankle, achilles, foot or calf history is an IMPACT history — and the fastest
                //    running in the plan is the highest-impact thing in it.
                if !i.injuryHistory.isEmpty, let pace = s.targetPaceSPerKm, pace > 0,
                   pace <= intervalPace + 2, s.runType != .race {
                    let areas = Set(i.injuryHistory)
                    if !areas.isDisjoint(with: PlanEngine.impactSensitiveAreas)
                        || !areas.isDisjoint(with: PlanEngine.speedSensitiveAreas) {
                        fail("injury protection", "w\(w.index) prescribes \(s.intervals ?? "a session") at interval pace to \(i.injuryHistory.map(\.rawValue).joined(separator: "+"))")
                    }
                }
            }

            // E. The whole week's hard dose. Two well-sized sessions can still add up to a week
            //    with no easy days left in it.
            let weeklyCap: Double = runDays >= 4 ? 0.25 : runDays == 3 ? 0.30 : 0.36
            if weekM > 0, weeklyDose / weekM > weeklyCap, !w.isTaper {
                fail("weekly dose", "w\(w.index) runs \(Int(weeklyDose / weekM * 100))% of \(Int(weekM / 1000))km at quality pace")
            }

            // F. A week with exactly one run: that run IS the long run, and it is bounded like one.
            //    Nobody's single weekly run is their whole previous week's mileage in one go.
            if runs.count == 1, let only = runs.first, only.runType != .race {
                if only.runType != .long && only.runType != .progression {
                    fail("one-run week", "w\(w.index) single run is typed \(only.runType.map { "\($0)" } ?? "nil"), not a long run")
                }
                if let longest = i.longestRunM, (only.targetDistanceM ?? 0) > longest * 1.6 {
                    fail("one-run week", "w\(w.index) single run is \(Int((only.targetDistanceM ?? 0) / 1000))km against a stated longest of \(Int(longest / 1000))km")
                }
            }
        }
        return out
    }

    // MARK: Routes — the hybrid week that holds one run

    /// Every hybrid athlete who picks two days a week gets exactly one run (the split rounds to
    /// 1/1 at every emphasis). That run is their entire running week, and it has to be a real,
    /// bounded long run rather than the sum of everything they used to do.
    @Test func theTwoDayHybridStillGetsACoachableRun() {
        var findings: [Finding] = []
        for priority in HybridPriority.allCases {
            for days in [2, 3, 4] {
                for seed in [20.0, 40, 70] {
                    var i = base(disciplines: [.running, .strength], goal: .generalFitness,
                                 days: days, raceM: nil, weeksOut: nil, exp: .experienced, seedKm: seed)
                    i.hybridPriority = priority
                    let p = plan(i)
                    findings += audit(p, i, "hybrid \(priority.rawValue) \(days)d \(Int(seed))km")
                }
            }
        }
        report(findings, "HYBRID TWO-DAY WEEK")
        #expect(findings.count == 0, "see the report above")
    }

    // MARK: Routes — the dose against the athlete's own mileage

    /// The same workout is a session for one athlete and a race for another. Walk the whole
    /// mileage range against every day count and check the dose scales with the runner.
    @Test func theHardDoseScalesWithTheAthlete() {
        var findings: [Finding] = []
        for seed in [12.0, 20, 26, 40, 60, 90, 130] {
            for days in [3, 4, 5, 6] {
                for raceM in [5_000.0, 10_000, 21_097, 42_195] {
                    let exp: ExperienceLevel = seed >= 55 ? .experienced : seed >= 20 ? .some : .new
                    let i = base(days: days, raceM: raceM, weeksOut: 18, exp: exp, seedKm: seed)
                    let p = plan(i)
                    findings += audit(p, i, "\(Int(seed))km \(days)d \(Int(raceM / 1000))K")
                }
            }
        }
        report(findings, "DOSE VS MILEAGE")
        #expect(findings.count == 0, "see the report above")
    }

    // MARK: Routes — either end of the fitness range

    /// Onboarding lets an athlete enter a 12-minute 5K or a 60-minute one, and every "by feel"
    /// answer in between. Both ends have to come out with a plan a coach would sign.
    @Test func everyFitnessTheAthleteCanEnterIsCoachable() {
        var findings: [Finding] = []
        var seeds: [(String, CalibrationSeed, ExperienceLevel)] = []
        for feel in PaceFeel.allCases {
            var s = CalibrationSeed(); s.estimatedP5kSPerKm = feel.p5kSPerKm
            seeds.append((feel.rawValue, s, feel.experienceLevel))
        }
        // The bounds of the manual time entry — the elite floor and the slowest a picker allows.
        for bench in RunBenchmark.allCases {
            for (tag, secs) in [("floor", bench.range.lowerBound), ("ceiling", bench.range.upperBound)] {
                var s = CalibrationSeed(); s.recentRun = (bench.meters, secs)
                seeds.append(("\(bench.rawValue)-\(tag)", s, tag == "floor" ? .experienced : .new))
            }
        }
        for (tag, seed, exp) in seeds {
            for raceM in [5_000.0, 21_097, 42_195] {
                let i = base(days: 5, raceM: raceM, weeksOut: 16, exp: exp,
                             seedKm: exp == .new ? 15 : 55)
                let p = plan(i, calibration: seed)
                findings += audit(p, i, "\(tag) \(Int(raceM / 1000))K")
            }
        }
        report(findings, "FITNESS RANGE")
        #expect(findings.count == 0, "see the report above")
    }

    // MARK: Routes — every injury the step offers

    /// The injuries step promises "a safer ramp where you've been hurt". Every area, singly and
    /// in the pairs athletes actually report together.
    @Test func everyInjuryHistoryIsActuallyProtected() {
        var findings: [Finding] = []
        var sets: [[InjuryArea]] = InjuryArea.allCases.map { [$0] }
        sets += [[.knee, .itBand], [.shins, .calf], [.hamstring, .hip], [.achilles, .foot], [.back, .knee]]
        for areas in sets {
            for raceM in [5_000.0, 21_097, 42_195] {
                var i = base(days: 5, raceM: raceM, weeksOut: 16, exp: .experienced, seedKm: 55)
                i.injuryHistory = areas
                let p = plan(i)
                findings += audit(p, i, "\(areas.map(\.rawValue).joined(separator: "+")) \(Int(raceM / 1000))K")
            }
        }
        report(findings, "INJURY PROTECTION")
        #expect(findings.count == 0, "see the report above")
    }

    // MARK: Routes — the runway, end to end

    /// A race can be picked for any future date. Saturday, three weeks out, next year.
    @Test func everyRunwayProducesAPlanThatEndsOnTheLine() {
        var findings: [Finding] = []
        for weeksOut in [1, 2, 3, 4, 6, 9, 20, 40, 60] {
            for raceM in [5_000.0, 21_097, 42_195, 50_000] {
                let i = base(days: 5, raceM: raceM, weeksOut: weeksOut, exp: .some, seedKm: 40)
                let p = plan(i)
                let route = "\(Int(raceM / 1000))K in \(weeksOut)w"
                findings += audit(p, i, route)
                // The race is on the calendar whenever it falls inside the generated block.
                let hasRace = p.weeks.flatMap(\.sessions).contains { $0.runType == .race }
                let inWindow = weeksOut <= p.weeks.count
                if inWindow && !hasRace {
                    findings.append(Finding(route: route, bar: "race day", detail: "no race session in a \(p.weeks.count)-week block"))
                }
                if !inWindow && p.weeks.contains(where: \.isTaper) {
                    findings.append(Finding(route: route, bar: "race day", detail: "taper generated for a race outside the block"))
                }
                // Nothing empty, ever — a block with a week of nothing is a bug the athlete sees.
                for w in p.weeks where w.sessions.isEmpty {
                    findings.append(Finding(route: route, bar: "empty week", detail: "w\(w.index) has no sessions"))
                }
            }
        }
        report(findings, "RUNWAY")
        #expect(findings.count == 0, "see the report above")
    }

    // MARK: Routes — the ceiling, the units, the tiers

    @Test func theAthletesOwnCeilingIsHonoured() {
        var findings: [Finding] = []
        for capKm in [25.0, 40, 60, 80] {
            for tier in PlanIntensity.allCases {
                var i = base(days: tier == .podium ? 6 : 5, raceM: 42_195, weeksOut: 20,
                             exp: .some, seedKm: 30, intensity: tier)
                i.targetWeeklyVolumeM = capKm * 1_000
                i.goalFinishTimeS = 3 * 3_600
                let p = plan(i)
                let route = "cap \(Int(capKm))km \(tier.rawValue)"
                findings += audit(p, i, route)
                let peak = p.weeks.filter { !$0.isTaper }.map(\.runVolumeM).max() ?? 0
                // A stated ceiling is a promise. Rounding is allowed a little room; a third over
                // is not rounding.
                if peak > max(capKm * 1_000, i.currentWeeklyVolumeM ?? 0) * 1.12 {
                    findings.append(Finding(route: route, bar: "mileage ceiling",
                                            detail: "peaks at \(Int(peak / 1000))km against a stated \(Int(capKm))km"))
                }
            }
        }
        report(findings, "MILEAGE CEILING")
        #expect(findings.count == 0, "see the report above")
    }

    @Test func theImperialAthleteGetsTheSamePlan() {
        var findings: [Finding] = []
        for raceM in [5_000.0, 10_000, 21_097, 42_195] {
            for days in [3, 5] {
                var i = base(days: days, raceM: raceM, weeksOut: 16, exp: .some, seedKm: 45)
                i.distanceUnit = .imperial
                let p = plan(i)
                findings += audit(p, i, "imperial \(Int(raceM / 1000))K \(days)d")
            }
        }
        report(findings, "IMPERIAL")
        #expect(findings.count == 0, "see the report above")
    }

    // MARK: Routes — the athlete who did not choose running

    /// Cycle, Walk and Hike are all on the "what do you want to do?" page, and an athlete may pick
    /// one and nothing else. The engine still owes them a plan whose numbers belong to their sport
    /// and whose words do not say "run".
    @Test func theCyclistAndTheWalkerGetTheirOwnPlan() {
        var findings: [Finding] = []
        for discipline in [Discipline.cycling, .walking] {
            for exp in [ExperienceLevel.new, .some, .experienced] {
                for days in [2, 3, 5] {
                    let i = base(disciplines: [discipline], goal: .generalFitness, days: days,
                                 raceM: nil, weeksOut: nil, exp: exp, seedKm: nil)
                    let p = plan(i)
                    let route = "\(discipline.rawValue) \(exp.rawValue) \(days)d"
                    for w in p.weeks {
                        let sessions = w.sessions.filter { $0.discipline == discipline }
                        if sessions.count != days {
                            findings.append(Finding(route: route, bar: "week shape",
                                                    detail: "w\(w.index) has \(sessions.count) sessions for a \(days)-day athlete"))
                        }
                        for s in sessions {
                            let words = (s.rationale ?? "").lowercased()
                            if words.contains("run") || words.contains("jog") {
                                findings.append(Finding(route: route, bar: "wrong sport",
                                                        detail: "w\(w.index): \"\(s.rationale ?? "")\""))
                            }
                            if (s.targetDistanceM ?? 0) <= 0 {
                                findings.append(Finding(route: route, bar: "empty session", detail: "w\(w.index) has no target"))
                            }
                            // Plausibility at that sport's own speed: a ride is not a 25-minute
                            // ride because a run of the same distance would be, and nobody walks
                            // for four hours on a Tuesday.
                            let speedKmh: Double = discipline == .cycling ? 25 : 5
                            let mins = ((s.targetDistanceM ?? 0) / 1_000) / speedKmh * 60
                            if mins > 180 {
                                findings.append(Finding(route: route, bar: "time on feet",
                                                        detail: "w\(w.index) is \(Int(mins)) minutes at \(Int(speedKmh))km/h"))
                            }
                            if mins < 15, !w.isDeload, !w.isTaper {
                                findings.append(Finding(route: route, bar: "token session",
                                                        detail: "w\(w.index) is only \(Int(mins)) minutes at \(Int(speedKmh))km/h"))
                            }
                        }
                    }
                }
            }
        }
        report(findings, "CYCLIST AND WALKER")
        #expect(findings.count == 0, "see the report above")
    }

    // MARK: Routes — the strength side, on the catalog we ship

    /// Every equipment answer, every split, every lift-day count — judged on the real library.
    /// A day with two exercises in it is not a day, and a day that opens on a triceps pushdown is
    /// not a day either.
    @Test func everyStrengthWeekIsAWorkout() {
        var findings: [Finding] = []
        for equipment in Equipment.allCases {
            for split in StrengthSplitStyle.allCases {
                for days in [2, 3, 4, 5, 6] {
                    for goal in [Goal.buildMuscle, .getStronger, .generalFitness] {
                        var i = base(disciplines: [.strength], goal: goal, days: days,
                                     raceM: nil, weeksOut: nil, exp: .some, seedKm: nil)
                        i.equipment = equipment
                        i.strengthSplit = split
                        i.sessionMinutes = 60
                        let p = plan(i)
                        let route = "\(equipment.rawValue) \(split.rawValue) \(days)d \(goal)"
                        for w in p.weeks {
                            let lifts = w.sessions.filter { $0.discipline == .strength }
                            if lifts.count != days {
                                findings.append(Finding(route: route, bar: "week shape",
                                                        detail: "w\(w.index) has \(lifts.count) lift days for \(days)"))
                            }
                            for s in lifts {
                                let names = s.strengthTargets.map(\.exerciseName)
                                if names.count < 3 {
                                    findings.append(Finding(route: route, bar: "thin session",
                                                            detail: "w\(w.index) \(s.strengthLabel ?? "day") has \(names.count) exercises"))
                                }
                                if Set(names).count != names.count {
                                    findings.append(Finding(route: route, bar: "duplicate move",
                                                            detail: "w\(w.index) \(s.strengthLabel ?? "day") repeats an exercise"))
                                }
                                if s.strengthTargets.contains(where: { $0.targetSets < 2 }) {
                                    findings.append(Finding(route: route, bar: "empty prescription",
                                                            detail: "w\(w.index) has an exercise with fewer than 2 sets"))
                                }
                            }
                        }
                    }
                }
            }
        }
        report(findings, "STRENGTH WEEK")
        #expect(findings.count == 0, "see the report above")
    }

    // MARK: The coach's card — printed for review, not asserted

    /// Dumps the week table for the routes this part exists to watch, so a human can read what a
    /// real athlete on each of them would open the app to.
    @Test func printTheNewRoutesCoachCard() {
        var cards: [(String, PlanInputs)] = []
        var hybrid = base(disciplines: [.running, .strength], goal: .generalFitness, days: 2,
                          raceM: nil, weeksOut: nil, exp: .experienced, seedKm: 45)
        hybrid.hybridPriority = .balanced
        cards.append(("Two-day hybrid, 45 km/wk runner", hybrid))
        cards.append(("26 km/wk runner, half in 16 weeks, 4 days", base(days: 4, raceM: 21_097, weeksOut: 16, seedKm: 26)))
        cards.append(("Cyclist, 3 days, some experience",
                      base(disciplines: [.cycling], goal: .generalFitness, days: 3, raceM: nil, weeksOut: nil, seedKm: nil)))
        cards.append(("Walker, 3 days, some experience",
                      base(disciplines: [.walking], goal: .generalFitness, days: 3, raceM: nil, weeksOut: nil, seedKm: nil)))

        for (title, i) in cards {
            let p = plan(i)
            var out = "\n═══ \(title) ═══\n"
            for w in p.weeks.prefix(8) {
                let vol = w.runVolumeM > 0 ? w.runVolumeM
                    : w.sessions.reduce(0.0) { $0 + ($1.targetDistanceM ?? 0) }
                out += String(format: "w%-2d %-9@ %5.1fkm  ", w.index, w.phase.rawValue as NSString, vol / 1000)
                out += w.sessions.map { s in
                    let d = (s.targetDistanceM ?? 0) / 1000
                    let kind = s.discipline == .strength ? (s.strengthLabel ?? "lift")
                        : (s.runType.map { "\($0)" } ?? s.discipline.rawValue)
                    return String(format: "d%d %@ %.1f%@", s.dayOffset, kind, d, s.intervals.map { " (\($0))" } ?? "")
                }.joined(separator: " | ")
                out += "\n"
            }
            print(out)
        }
        #expect(true)
    }

    /// The full coach's card for the athletes this app is actually built for — printed, not
    /// asserted. Bars catch structure; only reading the program catches taste. Run with
    /// `-only-testing:MomentumTests/PlanCoachAuditPart3Tests/printTheProgramsAthletesReceive`
    /// and read the block between the rules.
    @Test func printTheProgramsAthletesReceive() {
        func card(_ title: String, _ i: PlanInputs, _ seed: CalibrationSeed = .none, weeks: Int = 99) {
            let p = plan(i, calibration: seed)
            var out = "\n\n╔═══ \(title) ═══\n"
            out += "║ p5k \(fmt(p.p5kSPerKm))/km"
            if let g = p.goalRacePaceSPerKm { out += "  ·  goal pace \(fmt(g))/km" }
            out += "  ·  \(p.weeks.count) weeks\n"
            for w in p.weeks.prefix(weeks) {
                let vol = w.trainingVolumeM
                out += String(format: "║ w%-2d %-9@ %5.1fkm │ ", w.index, w.phase.rawValue as NSString, vol / 1000)
                out += w.sessions.map { s in
                    if s.discipline == .strength { return "\(s.strengthLabel ?? "lift")(\(s.strengthTargets.count))" }
                    let d = String(format: "%.1f", (s.targetDistanceM ?? 0) / 1000)
                    let kind = s.runType.map { "\($0)" } ?? s.discipline.rawValue
                    let pace = s.targetPaceSPerKm.map { " @\(fmt($0))" } ?? ""
                    return "\(kind) \(d)\(pace)\(s.intervals.map { " [\($0)]" } ?? "")"
                }.joined(separator: " │ ")
                out += "\n"
            }
            print(out)
        }

        card("BEGINNER · get fit · 3 days · no race",
             base(goal: .generalFitness, days: 3, raceM: nil, weeksOut: nil, exp: .new, seedKm: nil),
             CalibrationSeed(estimatedP5kSPerKm: PaceFeel.newRunner.p5kSPerKm))
        var firstFiveK = base(goal: .raceDistance, days: 3, raceM: 5_000, weeksOut: 10, exp: .new, seedKm: nil)
        firstFiveK.intensity = .gentle
        card("BEGINNER · first 5K · 10 weeks · gentle", firstFiveK,
             CalibrationSeed(estimatedP5kSPerKm: PaceFeel.newRunner.p5kSPerKm))
        var sub315 = base(days: 5, raceM: 42_195, weeksOut: 18, exp: .experienced, seedKm: 55)
        sub315.goalFinishTimeS = 3 * 3_600 + 15 * 60
        card("MARATHON 3:15 · 55 km/wk · 18 weeks · 5 days", sub315,
             CalibrationSeed(recentRun: (10_000, 43 * 60)))
        var podium = base(days: 6, raceM: 42_195, weeksOut: 20, exp: .experienced, seedKm: 70, intensity: .podium)
        podium.goalFinishTimeS = 2 * 3_600 + 55 * 60
        card("PODIUM · sub-3 marathon · 70 km/wk · 20 weeks · 6 days", podium,
             CalibrationSeed(recentRun: (21_097, 84 * 60)))
        var masters = base(days: 4, raceM: 10_000, weeksOut: 12, exp: .some, seedKm: 32)
        masters.age = 58
        masters.injuryHistory = [.knee]
        card("MASTERS 58 · knee history · 10K · 12 weeks · 4 days", masters)
        card("ULTRA 50K · 24 weeks · 5 days",
             base(days: 5, raceM: 50_000, weeksOut: 24, exp: .experienced, seedKm: 60))
        card("RACE IN 3 WEEKS · half · 4 days",
             base(days: 4, raceM: 21_097, weeksOut: 3, exp: .some, seedKm: 35))
        var hybrid = base(disciplines: [.running, .strength], goal: .raceDistance, days: 5,
                          raceM: 21_097, weeksOut: 16, exp: .some, seedKm: 35)
        hybrid.hybridPriority = .balanced
        card("HYBRID · balanced · half · 16 weeks · 5 days", hybrid)
        #expect(true)
    }

    private func fmt(_ sPerKm: Double) -> String {
        String(format: "%d:%02d", Int(sPerKm) / 60, Int(sPerKm) % 60)
    }

    // MARK: The race sets a floor on the running

    /// Owner call 2026-08-30 — "running focused always, since we are a running app". A dated race
    /// is a commitment to a running outcome, so a hybrid week gives running the frequency the
    /// distance needs whenever it can hold it. Lifting is not deleted to do it, and all three
    /// emphases still change the week: a choice that does nothing is a bug, not a preference.
    @Test func aRaceFloorsTheRunningDaysForHybridAthletes() {
        // half marathon (needs 4) — days 3…6 × running / balanced / lifting
        let half: [HybridPriority: [(Int, Int)]] = [
            .running:  [(2, 1), (3, 1), (4, 1), (5, 1)],
            .balanced: [(2, 1), (3, 1), (4, 1), (4, 2)],
            .lifting:  [(2, 1), (2, 2), (3, 2), (4, 2)],
        ]
        // 5K (needs 3) — the floor bites lower, so the emphases separate sooner.
        let fiveK: [HybridPriority: [(Int, Int)]] = [
            .running:  [(2, 1), (3, 1), (4, 1), (5, 1)],
            .balanced: [(2, 1), (3, 1), (3, 2), (4, 2)],
            // 5d: the 5K's three-day floor lifts running from two to three; lifting keeps its two.
            .lifting:  [(2, 1), (2, 2), (3, 2), (3, 3)],
        ]
        for (raceM, table) in [(21_097.0, half), (5_000.0, fiveK)] {
            for (priority, rows) in table {
                for (i, want) in rows.enumerated() {
                    let days = i + 3
                    let got = PlanEngine.hybridSplit(days: days, priority: priority,
                                                     goal: .raceDistance, raceDistanceM: raceM)
                    #expect(got.runDays == want.0,
                            "\(Int(raceM / 1000))K \(priority) \(days)d: \(got.runDays) runs, wanted \(want.0)")
                    #expect(got.liftDays == want.1,
                            "\(Int(raceM / 1000))K \(priority) \(days)d: \(got.liftDays) lifts, wanted \(want.1)")
                }
            }
        }
        // Lifting never disappears, and the floor never eats the whole week.
        for days in 2...7 {
            for priority in HybridPriority.allCases {
                for raceM in [5_000.0, 10_000, 21_097, 42_195, 50_000] {
                    let s = PlanEngine.hybridSplit(days: days, priority: priority,
                                                   goal: .raceDistance, raceDistanceM: raceM)
                    #expect(s.liftDays >= 1, "\(priority) \(days)d lost lifting entirely")
                    #expect(s.runDays >= 1, "\(priority) \(days)d lost running entirely")
                    #expect(s.runDays + s.liftDays == days)
                }
            }
        }
        // …and a race can only ever ADD running to a hybrid week, never take it away.
        for days in 2...7 {
            for priority in HybridPriority.allCases {
                let open = PlanEngine.hybridSplit(days: days, priority: priority, goal: .raceDistance)
                let raced = PlanEngine.hybridSplit(days: days, priority: priority,
                                                  goal: .raceDistance, raceDistanceM: 42_195)
                #expect(raced.runDays >= open.runDays, "\(priority) \(days)d lost a run day to the race")
            }
        }
    }

    /// The floor has to reach the PLAN, not just the arithmetic: a five-day balanced hybrid
    /// training for a half opens the app to four runs.
    @Test func theRaceFlooredWeekIsWhatGetsGenerated() {
        var i = base(disciplines: [.running, .strength], goal: .raceDistance, days: 5,
                     raceM: 21_097, weeksOut: 16, exp: .some, seedKm: 35)
        i.hybridPriority = .balanced
        let p = plan(i)
        let w0 = p.weeks[0]
        #expect(w0.sessions.filter { $0.discipline == .running }.count == 4)
        #expect(w0.sessions.filter { $0.discipline == .strength }.count == 1)
        // …and it is a real running week, not four runs sharing one week's worth of one.
        #expect(w0.sessions.contains { $0.runType == .long })
        #expect(w0.sessions.contains { $0.isHardRun })
    }
}
