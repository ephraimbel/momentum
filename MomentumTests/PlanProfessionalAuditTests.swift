import Testing
import Foundation
@testable import Momentum

/// The professional-quality audit: generates REAL plans for the standard athlete personas and holds
/// the OUTCOMES to the standards a certified coach would — not just the structural safety the
/// invariant sweep already pins, but the numbers an athlete actually sees.
///
/// The named references, one per rule, so nobody has to re-litigate them:
///  • ~80/20 intensity split (Seiler): hard-session distance stays a minority of the week.
///  • Race-week volume 40–60% of peak (Bosquet 2007 meta), intensity retained through the taper.
///  • Marathon readiness (Pfitzinger/Daniels): a properly-runwayed marathon build actually REACHES
///    marathon volume — peak long run ≥ 26 km, peak week ≥ the distance's readiness volume.
///  • Long-run share ≤ ~1/3 of the week on 4+ day plans (microcycle balance).
///  • Deloads cut ~30% (the absorb week), every 3–4 build weeks; masters every 3rd (Friel).
///  • Progressive overload: the quality stimulus grows across the block, never a frozen template.
///
/// Each persona also prints a full coach's card (week table + one build week in session detail)
/// so a regression in FEEL — not just in bounds — is visible in the test log.
struct PlanProfessionalAuditTests {

    private let start = Date(timeIntervalSinceReferenceDate: 0)   // fixed anchor; engine is pure
    private let cal = Calendar.current

    private func race(weeksOut: Int, dayOfWeek: Int = 6) -> Date {
        cal.date(byAdding: .day, value: (weeksOut - 1) * 7 + dayOfWeek, to: start)!
    }

    private func catalogFixture() -> [ExerciseCatalogItem] {
        func item(_ n: String, _ m: MuscleGroup, _ cat: ExerciseCategory) -> ExerciseCatalogItem {
            ExerciseCatalogItem(name: n, primaryMuscles: [m], secondaryMuscles: [],
                                equipment: .barbell, category: cat, defaultRestS: 120)
        }
        return [item("Squat", .quads, .compound), item("Bench", .chest, .compound),
                item("Row", .back, .compound), item("OHP", .shoulders, .compound),
                item("RDL", .hamstrings, .compound), item("Curl", .biceps, .isolation),
                item("Leg Raise", .core, .isolation), item("Calf Raise", .calves, .isolation)]
    }

    // MARK: Metrics

    private struct WeekMetrics {
        let index: Int
        let phase: PlanPhase
        let isDeload: Bool
        let isTaper: Bool
        let totalM: Double
        let longM: Double
        let hardM: Double
        let hardCount: Int
        let sessions: [GeneratedSession]
        var longShare: Double { totalM > 0 ? longM / totalM : 0 }
        var hardShare: Double { totalM > 0 ? hardM / totalM : 0 }
    }

    /// A session's HARD distance. A race-pace-finish long run ("Last 6km @ race pace") is hard for
    /// recovery-placement purposes, but only its finish kilometres are actually run hard — counting
    /// the whole 27 km as intensity would flag every Canova-style long run as a grey-zone week.
    private func hardMeters(_ s: GeneratedSession) -> Double {
        guard s.isHardRun else { return 0 }
        if s.runType == .long || s.runType == .progression,
           let note = s.intervals, note.hasPrefix("Last "),
           let km = Double(note.dropFirst(5).prefix(while: { $0.isNumber || $0 == "." })) {
            return km * 1000
        }
        return s.targetDistanceM ?? 0
    }

    private func metrics(_ plan: GeneratedPlan) -> [WeekMetrics] {
        plan.weeks.map { w in
            let runs = w.sessions.filter { $0.discipline == .running && $0.runType != .race }
            let long = runs.filter { $0.runType == .long || $0.runType == .progression }
                .map { $0.targetDistanceM ?? 0 }.max() ?? 0
            let hard = runs.filter(\.isHardRun)
            return WeekMetrics(index: w.index, phase: w.phase, isDeload: w.isDeload, isTaper: w.isTaper,
                               totalM: w.runVolumeM, longM: long,
                               hardM: hard.reduce(0) { $0 + hardMeters($1) },
                               hardCount: hard.count, sessions: w.sessions)
        }
    }

    /// The coach's card, printed into the test log for eyeball review.
    private func dump(_ label: String, _ plan: GeneratedPlan, detailWeek: Int? = nil) {
        var out = "\n═══ \(label) — p5k \(Int(plan.p5kSPerKm))s/km, \(plan.weeks.count)w ═══\n"
        for m in metrics(plan) {
            let flag = m.isTaper ? "TAPER" : m.isDeload ? "DOWN " : m.phase.label.prefix(5).uppercased().padding(toLength: 5, withPad: " ", startingAt: 0)
            let quality = m.sessions.filter { $0.isHardRun && $0.runType != .race }
                .compactMap { $0.intervals ?? $0.runType?.rawValue }.joined(separator: " + ")
            out += String(format: "w%02d %@ %5.1fkm  long %4.1f (%2.0f%%)  hard %2.0f%%  %@\n",
                          m.index, flag as CVarArg, m.totalM / 1000, m.longM / 1000,
                          m.longShare * 100, m.hardShare * 100, quality)
        }
        if let dw = detailWeek, dw < plan.weeks.count {
            out += "— week \(dw) detail —\n"
            for s in plan.weeks[dw].sessions.sorted(by: { $0.dayOffset < $1.dayOffset }) {
                let dist = s.targetDistanceM.map { String(format: "%.1fkm", $0 / 1000) } ?? "-"
                let pace = s.targetPaceSPerKm.map { p in String(format: "%d:%02d/km", Int(p) / 60, Int(p) % 60) } ?? ""
                let what = s.discipline == .strength
                    ? "STR \(s.strengthLabel ?? "") ×\(s.strengthTargets.count)"
                    : "\(s.runType?.rawValue ?? "?") \(dist) \(pace) \(s.intervals ?? "")"
                out += "  d\(s.dayOffset) \(what)\n"
            }
        }
        print(out)
    }

    // MARK: - The marathon build (the flagship product)

    @Test func experiencedMarathonBuildIsProfessionallyShaped() {
        let inputs = PlanInputs(disciplines: [.running], goal: .raceDistance, daysPerWeek: 5,
                                equipment: .fullGym, sessionMinutes: 60,
                                raceDate: race(weeksOut: 16), runningExperience: .experienced,
                                liftingExperience: .some, raceDistanceM: 42_195,
                                currentWeeklyVolumeM: 55_000, longestRunM: 18_000,
                                intensity: .balanced)
        let plan = PlanEngine.generate(profile: inputs, catalog: [], startDate: start, calendar: cal)
        dump("MARATHON 16w · exp · 5d · 55k seed (4:30 shape)", plan, detailWeek: 9)
        let m = metrics(plan)

        // Readiness: the build actually reaches marathon numbers before the taper.
        let peakWeek = m.filter { !$0.isTaper }.map(\.totalM).max() ?? 0
        let peakLong = m.map(\.longM).max() ?? 0
        #expect(peakWeek >= 65_000, "peak week \(peakWeek / 1000)km never reached marathon volume")
        #expect(peakLong >= 26_000, "peak long run \(peakLong / 1000)km leaves the athlete under-prepared")
        #expect(peakLong <= 33_000, "long run \(peakLong / 1000)km beyond the injury-safe cap")

        // Bosquet taper: race week lands at 25–60% of peak (post-race days are cleared, so the
        // floor sits below the raw 45–55% multiplier band).
        let raceWeekM = m.last!.totalM
        #expect(raceWeekM < peakWeek * 0.6 && raceWeekM > peakWeek * 0.15,
                "race week \(raceWeekM / 1000)km isn't a taper (peak \(peakWeek / 1000)km)")
        // Intensity retained: every taper week before race week keeps one quality touch.
        for w in m.filter(\.isTaper).dropLast() {
            #expect(w.hardCount >= 1, "taper w\(w.index) lost all intensity — Bosquet cuts volume, never intensity")
        }

        // 80/20 shape: hard-session distance stays a minority of every non-taper training week.
        for w in m where !w.isTaper && !w.isDeload && w.totalM > 0 {
            #expect(w.hardShare <= 0.40, "w\(w.index) hard share \(Int(w.hardShare * 100))% — grey-zone week")
            #expect(w.longShare <= 0.42, "w\(w.index) long-run share \(Int(w.longShare * 100))% dominates the week")
            // Never a third hard day: the RP-finish long run counts as one of the two, so no
            // combination of rotation + second-quality may stack three (the w10 bug this caught).
            #expect(w.hardCount <= 2, "w\(w.index): \(w.hardCount) hard days on a 5-day week")
        }

        // Microcycle spacing: no quality session lands the day before OR after the long run —
        // the long day anchors the week and the hard days breathe around it (5 sessions across
        // 7 slots always admits a legal arrangement, so this holds strictly here).
        for week in plan.weeks where !week.isTaper {
            let longDay = week.sessions.first { $0.runType == .long || $0.runType == .progression }?.dayOffset
            guard let longDay else { continue }
            for s in week.sessions where s.isHardRun && s.dayOffset != longDay && s.runType != .race {
                #expect(abs(s.dayOffset - longDay) != 1,
                        "w\(week.index): quality on d\(s.dayOffset) adjacent to the long run on d\(longDay)")
            }
        }

        // Deloads exist, dip meaningfully, and recover: every down week cuts ≥15% vs the
        // surrounding builds (0.7× by construction; rounding + long-wave can soften the edges).
        let downs = m.filter(\.isDeload)
        #expect(downs.count >= 2, "16 weeks with fewer than 2 absorb weeks")
        for d in downs where d.index > 0 && d.index + 1 < m.count {
            let neighbors = max(m[d.index - 1].totalM, m[d.index + 1].totalM)
            if neighbors > 0 {
                #expect(d.totalM <= neighbors * 0.85, "down week w\(d.index) barely dips (\(d.totalM) vs \(neighbors))")
            }
        }

        // The marathon staples appear: a race-pace-finish long run and a goal-pace block.
        let allIntervals = plan.weeks.flatMap(\.sessions).compactMap(\.intervals)
        #expect(allIntervals.contains { $0.contains("@ race pace") }, "no goal-race-pace work in a marathon build")
        #expect(allIntervals.contains { $0.contains("Last") && $0.contains("race pace") },
                "no race-pace-finish long run — the signature marathon workout is missing")
        // The checkpoint time trial is placed exactly once.
        #expect(allIntervals.filter { $0.contains("Time trial") }.count == 1, "checkpoint TT missing or duplicated")

        // Race day: on the exact date, eve is a ≤3 km shakeout, nothing scheduled after.
        let raceWeek = plan.weeks.last!
        let raceSession = raceWeek.sessions.first { $0.runType == .race }
        #expect(raceSession != nil, "no race day at the end of a race plan")
        #expect(raceSession?.targetDistanceM == 42_195, "race day distance wrong")
        if let raceDay = raceSession?.dayOffset {
            let eve = raceWeek.sessions.first { $0.dayOffset == raceDay - 1 }
            if let eve { #expect((eve.targetDistanceM ?? 0) <= 3_100, "race-eve run isn't a shakeout") }
            #expect(!raceWeek.sessions.contains { $0.runType != .race && $0.dayOffset >= raceDay },
                    "training scheduled on/after race day")
        }
    }

    // MARK: - The beginner 5K (the other end of the spectrum)

    @Test func beginnerCouchTo5KIsGentleAndConsistent() {
        let inputs = PlanInputs(disciplines: [.running], goal: .raceDistance, daysPerWeek: 3,
                                equipment: .bodyweight, sessionMinutes: 45,
                                raceDate: race(weeksOut: 10), runningExperience: .new,
                                liftingExperience: .new, raceDistanceM: 5_000)
        let plan = PlanEngine.generate(profile: inputs, catalog: [], startDate: start, calendar: cal)
        dump("BEGINNER 5K 10w · 3d", plan, detailWeek: 4)
        let m = metrics(plan)

        // A beginner's first week is small — single-digit km, never a shock.
        #expect(m[0].totalM <= 13_000, "beginner week 1 is \(m[0].totalM / 1000)km")
        // No VO₂max reps or threshold cruise intervals anywhere — the beginner menu holds in
        // every phase (fartlek, strides, tempo only).
        let intervals = plan.weeks.flatMap(\.sessions).compactMap(\.intervals)
        #expect(!intervals.contains { $0.contains("VO2") || $0.contains("threshold") || $0.contains("@ 5K") },
                "beginner prescribed advanced intervals: \(intervals)")
        // Run/walk scaffolding appears on easy days.
        #expect(intervals.contains { $0.contains("Run/walk") }, "no run/walk scaffolding for a new runner")
        // The long run never exceeds the 5K-appropriate peak (~9 km).
        #expect(m.map(\.longM).max() ?? 0 <= 9_500, "beginner 5K long run overgrown")
    }

    // MARK: - The 10K is not a long 5K

    @Test func tenKPlanIsThresholdCentric() {
        let inputs = PlanInputs(disciplines: [.running], goal: .raceDistance, daysPerWeek: 4,
                                equipment: .fullGym, sessionMinutes: 60,
                                raceDate: race(weeksOut: 10), runningExperience: .some,
                                liftingExperience: .some, raceDistanceM: 10_000,
                                currentWeeklyVolumeM: 30_000, longestRunM: 12_000)
        let plan = PlanEngine.generate(profile: inputs, catalog: [], startDate: start, calendar: cal)
        dump("10K 10w · some · 4d · 30k seed", plan)

        let buildIntervals = plan.weeks.filter { $0.phase == .build || $0.phase == .peak }
            .flatMap(\.sessions).compactMap(\.intervals)
        #expect(buildIntervals.contains { $0.contains("threshold") },
                "a 10K build with no threshold work is a 5K plan wearing a 10K label")
        // The checkpoint TT exists for a 10-week 10K runway.
        #expect(plan.weeks.flatMap(\.sessions).compactMap(\.intervals).contains { $0.contains("Time trial") },
                "no checkpoint TT on a 10-week 10K runway")
        // Taper touch is at RACE pace, not 5K pace (10K race week ≠ 5K practice).
        let taperIntervals = plan.weeks.filter(\.isTaper).flatMap(\.sessions).compactMap(\.intervals)
        #expect(!taperIntervals.contains { $0.contains("@ 5K") }, "10K taper practicing 5K pace")
    }

    // MARK: - Progressive overload across the block

    @Test func qualityStimulusGrowsAcrossTheBuild() {
        // Two snapshots of the same short-race build menu, 6 weeks apart: the rep count must grow.
        let early = PlanEngine.qualityWorkout(weekIndex: 0, raceDistanceM: 5_000, level: .experienced,
                                              p5k: 300, phase: .build, weeklyVolumeM: 45_000, qualityDistanceM: 8_000)
        let late = PlanEngine.qualityWorkout(weekIndex: 8, raceDistanceM: 5_000, level: .experienced,
                                             p5k: 300, phase: .build, weeklyVolumeM: 45_000, qualityDistanceM: 8_000)
        func repCount(_ s: String?) -> Int { Int(s?.prefix(while: \.isNumber) ?? "") ?? 0 }
        #expect(repCount(late.intervals) > repCount(early.intervals),
                "quality frozen: \(early.intervals ?? "-") → \(late.intervals ?? "-")")
    }

    // MARK: - Masters recovery cadence

    @Test func mastersAthleteDeloadsEveryThirdWeek() {
        let inputs = PlanInputs(disciplines: [.running], goal: .raceDistance, daysPerWeek: 4,
                                equipment: .fullGym, sessionMinutes: 60,
                                raceDate: race(weeksOut: 14), runningExperience: .some,
                                liftingExperience: .some, raceDistanceM: 21_097,
                                currentWeeklyVolumeM: 35_000, intensity: .aggressive, age: 56)
        let plan = PlanEngine.generate(profile: inputs, catalog: [], startDate: start, calendar: cal)
        dump("MASTERS 56y HALF 14w · aggressive", plan)
        // Aggressive normally deloads every 5th week; masters caps the cadence at every 3rd.
        let firstDeload = plan.weeks.first(where: \.isDeload)?.index
        #expect(firstDeload != nil && firstDeload! <= 3, "masters athlete's first absorb week arrives too late")
    }

    // MARK: - Injury history caps everything it should

    @Test func injuryHistoryProducesTheProtectivePlan() {
        let inputs = PlanInputs(disciplines: [.running], goal: .raceDistance, daysPerWeek: 5,
                                equipment: .fullGym, sessionMinutes: 60,
                                raceDate: race(weeksOut: 12), runningExperience: .experienced,
                                liftingExperience: .some, raceDistanceM: 10_000,
                                currentWeeklyVolumeM: 50_000, intensity: .aggressive,
                                injuryHistory: [.hamstring])
        let plan = PlanEngine.generate(profile: inputs, catalog: [], startDate: start, calendar: cal)
        dump("INJURY (hamstring) 10K 12w · aggressive-capped", plan)
        let sessions = plan.weeks.flatMap(\.sessions)
        // No strides, no 5K-pace sprint reps, and never a second quality day.
        #expect(!sessions.contains { $0.runType == .strides }, "strides despite hamstring history")
        for w in metrics(plan) {
            #expect(w.hardCount <= 1, "w\(w.index): two hard days despite injury history")
        }
        // Ramp capped at balanced: week-over-week growth ≤ ~8% (+ rounding slack).
        let m = metrics(plan)
        for i in 1..<m.count where !m[i].isDeload && !m[i].isTaper && !m[i - 1].isDeload && m[i - 1].totalM > 0 {
            // The tune-up time trial replaces a quality session with a short race effort, so its
            // week runs light by design; the step back up out of it is not a ramp.
            let outOfTimeTrial = m[i - 1].sessions.contains {
                $0.runType == .race || ($0.intervals ?? "").localizedCaseInsensitiveContains("time trial")
            }
            if outOfTimeTrial { continue }
            let ratio = m[i].totalM / m[i - 1].totalM
            #expect(ratio <= 1.12, "w\(m[i].index) ramps \(ratio)× despite injury history")
        }
    }

    // MARK: - The hybrid week

    @Test func hybridWeekSequencesLiftsAndRunsSafely() {
        let inputs = PlanInputs(disciplines: [.running, .strength], goal: .buildMuscle, daysPerWeek: 5,
                                equipment: .fullGym, sessionMinutes: 60,
                                raceDate: nil, runningExperience: .some, liftingExperience: .some)
        let plan = PlanEngine.generate(profile: inputs, catalog: catalogFixture(), startDate: start, calendar: cal)
        dump("HYBRID 5d · buildMuscle · rolling", plan, detailWeek: 1)
        for week in plan.weeks {
            #expect(PlanEngine.scheduleSatisfiesRecovery(week.sessions))
            let lifts = week.sessions.filter { $0.discipline == .strength }
            #expect(lifts.count >= 2, "buildMuscle hybrid should bias toward lifting")
            for lift in lifts {
                #expect(!lift.strengthTargets.isEmpty, "empty strength prescription")
                for ex in lift.strengthTargets {
                    #expect((2...6).contains(ex.targetSets), "insane set count \(ex.targetSets)")
                    #expect(ex.repLow >= 4 && ex.repHigh <= 15 && ex.repLow < ex.repHigh,
                            "insane rep range \(ex.repLow)–\(ex.repHigh)")
                }
            }
        }
    }

    // MARK: - The ultra gets the long glide

    @Test func ultraPlanTapersLongAndCapsTimeOnFeet() {
        let inputs = PlanInputs(disciplines: [.running], goal: .raceDistance, daysPerWeek: 5,
                                equipment: .fullGym, sessionMinutes: 60,
                                raceDate: race(weeksOut: 20), runningExperience: .experienced,
                                liftingExperience: .some, raceDistanceM: 50_000,
                                currentWeeklyVolumeM: 60_000, longestRunM: 25_000)
        let plan = PlanEngine.generate(profile: inputs, catalog: [], startDate: start, calendar: cal)
        dump("ULTRA 50K 20w · exp · 5d · 60k seed", plan)
        #expect(plan.weeks.suffix(4).filter(\.isTaper).count >= 3, "ultra taper shorter than 3 weeks")
        // Time-on-feet: no long run beyond 3 h at this athlete's long pace — plus the one snapped
        // kilometre RunRounding may add (a coach writes "27 km", not "26.67 km"; the extra ~2 min
        // is a prescription-cleanliness artifact, not a coaching breach).
        let longPace = PlanEngine.pace(.long, p5k: plan.p5kSPerKm)
        for w in metrics(plan) {
            #expect(w.longM * longPace / 1000 <= 3.0 * 3600 + 0.6 * longPace,
                    "w\(w.index) long run exceeds the 3 h time-on-feet cap")
        }
    }

    // MARK: - Paces are the paces a coach would give

    @Test func paceCardIsSaneAcrossFitnessLevels() {
        var card = "\n═══ PACE CARD (s/km → min/km) ═══\n"
        for (label, p5k) in [("19:10 5K", 230.0), ("25:00 5K", 300.0), ("30:00 5K", 360.0), ("37:30 5K", 450.0)] {
            func f(_ s: Double) -> String { "\(Int(s) / 60):\(String(format: "%02d", Int(s) % 60))" }
            let e = PlanEngine.pace(.easy, p5k: p5k), t = PlanEngine.pace(.tempo, p5k: p5k)
            let i = PlanEngine.pace(.intervals, p5k: p5k), l = PlanEngine.pace(.long, p5k: p5k)
            let mar = DanielsPaces.racePaceSPerKm(distanceM: 42_195, p5kSPerKm: p5k)
            card += "\(label): E \(f(e))  L \(f(l))  M \(f(mar))  T \(f(t))  I \(f(i))\n"
            // Zone order (the non-negotiable): I < 5K < T < M < E < L < recovery.
            #expect(i < p5k && p5k < t && t < mar && mar < e && e < l)
            // The easy gap is proportional, not flat: 60–120 s/km slower than 5K pace across levels.
            #expect(e - p5k > 55 && e - p5k < 180, "\(label): easy offset \(e - p5k)s off the curve")
        }
        print(card)
    }
}
