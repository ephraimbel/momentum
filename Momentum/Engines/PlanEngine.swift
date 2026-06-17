import Foundation

/// Deterministic plan generation (PRD §9). Structure, paces, loads, volume, and recovery spacing
/// are all rules-based and testable here; the LLM only narrates rationale later. Not medical advice.
enum PlanEngine {

    // MARK: Running paces (§9.1)

    /// Riegel: T₂ = T₁·(D₂/D₁)^1.06 → 5k pace in seconds per km.
    static func riegelP5k(distanceM: Double, timeS: Double) -> Double {
        guard distanceM > 0, timeS > 0 else { return levelP5k(.some) }
        let t5k = timeS * pow(5000 / distanceM, 1.06)
        return t5k / 5.0
    }

    static func levelP5k(_ level: ExperienceLevel) -> Double {
        switch level { case .new: 360; case .some: 330; case .experienced: 300 }
    }

    /// Training paces as offsets from P5k (s/km): recovery +110, easy +80, long +90, tempo +20,
    /// intervals/race +0.
    static func pace(_ type: RunType, p5k: Double) -> Double {
        let offset: Double
        switch type {
        case .recovery: offset = 110
        case .easy, .freeRun: offset = 80
        case .long: offset = 90
        case .tempo: offset = 20
        case .intervals, .race: offset = 0
        }
        return p5k + offset
    }

    // MARK: Top-level generation

    static func generate(profile: PlanInputs,
                         catalog: [ExerciseCatalogItem],
                         calibration: CalibrationSeed = .none,
                         startDate: Date,
                         calendar: Calendar = .current) -> GeneratedPlan {
        let disciplines = Set(profile.disciplines)
        let hasLift = disciplines.contains(.strength)
        let cardio: Discipline? = disciplines.contains(.running) ? .running
            : disciplines.contains(.walking) ? .walking
            : disciplines.contains(.cycling) ? .cycling : nil
        let hasCardio = cardio != nil

        // Most precise first: a real recent effort (Riegel) → a self-reported "by feel" estimate →
        // the experience-level default.
        let p5k = calibration.recentRun.map { riegelP5k(distanceM: $0.distanceM, timeS: $0.timeS) }
            ?? calibration.estimatedP5kSPerKm
            ?? levelP5k(profile.runningExperience)

        // Day allocation across disciplines.
        let days = max(1, min(7, profile.daysPerWeek))
        var liftDays = 0, runDays = 0
        if hasLift && hasCardio {
            let strengthLeaning = profile.goal == .buildMuscle || profile.goal == .getStronger
            liftDays = max(1, strengthLeaning ? Int((Double(days) * 0.6).rounded()) : Int(Double(days) * 0.4))
            liftDays = min(liftDays, days - 1)
            runDays = days - liftDays
        } else if hasLift {
            liftDays = days
        } else if hasCardio {
            runDays = days
        }

        // Macrocycle.
        let totalWeeks = weeksToGenerate(startDate: startDate, raceDate: profile.raceDate, calendar: calendar)
        let taperWeeks = profile.raceDate != nil ? min(3, Int((0.15 * Double(totalWeeks)).rounded(.up))) : 0

        var weeks: [GeneratedWeek] = []
        var buildIndex = 0
        var lastBuildMult = 1.0
        for w in 0..<totalWeeks {
            let isTaper = taperWeeks > 0 && w >= totalWeeks - taperWeeks
            let isDeload = !isTaper && (w % 4 == 3)
            let volumeMult: Double
            if isTaper {
                let into = w - (totalWeeks - taperWeeks)
                volumeMult = [0.6, 0.45, 0.35][min(into, 2)]
            } else if isDeload {
                volumeMult = lastBuildMult * 0.7
            } else {
                volumeMult = pow(1.08, Double(buildIndex))
                lastBuildMult = volumeMult
                buildIndex += 1
            }

            let runs = hasCardio
                ? cardioSessions(discipline: cardio!, runDays: runDays, level: profile.runningExperience,
                                 goal: profile.goal, p5k: p5k, volumeMult: volumeMult, isDeload: isDeload || isTaper,
                                 raceDistanceM: profile.raceDistanceM)
                : []
            let lifts = hasLift
                ? strengthSessions(liftDays: liftDays, goal: profile.goal, level: profile.liftingExperience,
                                   equipment: profile.equipment, sessionMinutes: profile.sessionMinutes,
                                   catalog: catalog, isDeload: isDeload, muscleFocus: Set(profile.muscleFocus))
                : []
            let scheduled = schedule(runs: runs, lifts: lifts, preferredDayOffsets: profile.preferredDayOffsets)
            weeks.append(GeneratedWeek(index: w, isDeload: isDeload, isTaper: isTaper, sessions: scheduled))
        }

        return GeneratedPlan(p5kSPerKm: p5k, weeks: weeks)
    }

    static func weeksToGenerate(startDate: Date, raceDate: Date?, calendar: Calendar) -> Int {
        guard let race = raceDate else { return 4 }
        let comps = calendar.dateComponents([.weekOfYear], from: startDate, to: race)
        return max(4, min(16, (comps.weekOfYear ?? 4) + 1))
    }

    // MARK: Cardio sessions

    static func cardioSessions(discipline: Discipline, runDays: Int, level: ExperienceLevel,
                               goal: Goal, p5k: Double, volumeMult: Double, isDeload: Bool,
                               raceDistanceM: Double? = nil) -> [GeneratedSession] {
        guard runDays > 0 else { return [] }
        var (easyBase, longBase, qualityBase): (Double, Double, Double)
        switch level {
        case .new: (easyBase, longBase, qualityBase) = (3000, 5000, 3000)
        case .some: (easyBase, longBase, qualityBase) = (6000, 10000, 5000)
        case .experienced: (easyBase, longBase, qualityBase) = (9000, 16000, 8000)
        }
        let isRunning = discipline == .running

        // Race-specific shaping: the long run progresses toward a race-appropriate peak and is clamped
        // there so a 5K plan doesn't drift into marathon volume (and a marathon's long run actually
        // gets long). Short races sharpen with intervals; long races build threshold with tempo.
        let longCap = raceDistanceM.map { longRunPeak(forRaceM: $0) }
        if let cap = longCap {
            longBase = min(max(longBase, cap * 0.5), cap)   // start ~half-peak, grow toward the cap
        }
        let useIntervals: Bool = {
            if let r = raceDistanceM { return r <= 12_000 }     // 5K/10K → speed; half/marathon → tempo
            return goal == .raceDistance || goal == .endurance
        }()

        var out: [GeneratedSession] = []
        func makeRun(_ type: RunType, _ base: Double, hard: Bool, intervals: String? = nil, cap: Double? = nil) -> GeneratedSession {
            var s = GeneratedSession(dayOffset: -1, discipline: discipline)
            var dist = (base * volumeMult).rounded()
            if let cap { dist = min(dist, cap.rounded()) }
            s.targetDistanceM = dist
            if isRunning {
                s.runType = type
                s.targetPaceSPerKm = pace(type, p5k: p5k)
                s.intervals = intervals
                s.isHardRun = hard
            }
            return s
        }

        if runDays >= 2 { out.append(makeRun(.long, longBase, hard: false, cap: longCap)) }
        if runDays >= 3 && !isDeload && goal != .stayConsistent && isRunning {
            if useIntervals {
                let reps = (raceDistanceM ?? 5_000) <= 6_000 ? "6×400m @ 5K pace" : "5×800m @ 5K pace"
                out.append(makeRun(.intervals, qualityBase, hard: true, intervals: reps))
            } else {
                out.append(makeRun(.tempo, qualityBase, hard: true))
            }
        }
        while out.count < runDays {
            let intervals = (isRunning && level == .new) ? "Run/walk 1:1" : nil
            out.append(makeRun(.easy, easyBase, hard: false, intervals: intervals))
        }
        return out
    }

    /// The peak weekly long-run distance a race builds toward (meters). Short races multiply up; long
    /// races run a fraction of race distance (you never run a full marathon in training).
    static func longRunPeak(forRaceM race: Double) -> Double {
        switch race {
        case ..<6_000:    return race * 1.8          // 5K → ~9K long
        case ..<13_000:   return race * 1.5          // 10K → ~15K long
        case ..<25_000:   return min(20_000, race * 0.9)   // half → ~19K
        default:          return min(32_000, race * 0.76)  // marathon → ~32K
        }
    }

    // MARK: Strength sessions (§9.2)

    static func strengthSessions(liftDays: Int, goal: Goal, level: ExperienceLevel, equipment: Equipment,
                                 sessionMinutes: Int, catalog: [ExerciseCatalogItem], isDeload: Bool,
                                 muscleFocus: Set<MuscleGroup> = []) -> [GeneratedSession] {
        guard liftDays > 0 else { return [] }
        let labels = splitLabels(liftDays: liftDays)
        let allowed = allowedEquipment(equipment)
        let exerciseCount = max(3, min(6, sessionMinutes / 10))

        return labels.map { label in
            var s = GeneratedSession(dayOffset: -1, discipline: .strength)
            s.strengthLabel = label
            s.isHardLowerLift = ["Lower", "Legs", "Full Body"].contains(label)
            var used = Set<String>()
            var targets: [GeneratedExercise] = []
            // Emphasized muscles in this day's slots come first so focus work survives the count cap.
            let slots = muscleSlots(for: label).sorted { a, b in
                muscleFocus.contains(a.muscle) && !muscleFocus.contains(b.muscle)
            }
            for slot in slots.prefix(exerciseCount) {
                guard let pick = selectExercise(muscle: slot.muscle, preferCompound: slot.compound,
                                                allowed: allowed, catalog: catalog, used: used) else { continue }
                used.insert(pick.name)
                var ge = scheme(for: pick, goal: goal, level: level, isDeload: isDeload)
                // Earned extra volume on the muscles the athlete chose to grow.
                if muscleFocus.contains(slot.muscle), !isDeload { ge.targetSets = min(6, ge.targetSets + 1) }
                targets.append(ge)
            }
            s.strengthTargets = targets
            return s
        }
    }

    static func splitLabels(liftDays: Int) -> [String] {
        switch liftDays {
        case 1, 2, 3: return Array(repeating: "Full Body", count: liftDays)
        case 4: return ["Upper", "Lower", "Upper", "Lower"]
        case 5: return ["Push", "Pull", "Legs", "Upper", "Lower"]
        default: return ["Push", "Pull", "Legs", "Push", "Pull", "Legs"]
        }
    }

    private static func muscleSlots(for label: String) -> [(muscle: MuscleGroup, compound: Bool)] {
        switch label {
        case "Full Body": return [(.quads, true), (.chest, true), (.back, true), (.shoulders, true), (.hamstrings, true), (.core, false)]
        case "Upper": return [(.chest, true), (.back, true), (.shoulders, true), (.triceps, false), (.biceps, false)]
        case "Lower": return [(.quads, true), (.hamstrings, true), (.glutes, true), (.calves, false), (.core, false)]
        case "Push": return [(.chest, true), (.shoulders, true), (.triceps, false), (.chest, false)]
        case "Pull": return [(.back, true), (.back, false), (.biceps, false), (.forearms, false)]
        case "Legs": return [(.quads, true), (.hamstrings, true), (.glutes, true), (.calves, false)]
        default: return [(.fullBody, true)]
        }
    }

    private static func allowedEquipment(_ e: Equipment) -> Set<EquipmentType> {
        switch e {
        case .fullGym: Set(EquipmentType.allCases)
        case .dumbbellsOnly: [.dumbbell, .bodyweight]
        case .homeMinimal: [.dumbbell, .bodyweight, .band, .kettlebell]
        case .bodyweight: [.bodyweight]
        }
    }

    private static func selectExercise(muscle: MuscleGroup, preferCompound: Bool, allowed: Set<EquipmentType>,
                                       catalog: [ExerciseCatalogItem], used: Set<String>) -> ExerciseCatalogItem? {
        let candidates = catalog.filter {
            allowed.contains($0.equipment) && !used.contains($0.name) && $0.primaryMuscles.contains(muscle)
        }
        let preferred = candidates.filter { $0.category == (preferCompound ? .compound : .isolation) }
        return (preferCompound ? (preferred.first ?? candidates.first) : (preferred.first ?? candidates.first))
    }

    private static func scheme(for ex: ExerciseCatalogItem, goal: Goal, level: ExperienceLevel, isDeload: Bool) -> GeneratedExercise {
        var sets: Int, low: Int, high: Int, prog: String, pct: Double?, rpe: Double?
        switch (goal, level) {
        case (_, .new):
            (sets, low, high, prog, pct, rpe) = (3, 8, 12, "linear", nil, nil)
        case (.getStronger, _):
            (sets, low, high, prog, pct, rpe) = (4, 4, 6, "percent", ex.category == .compound ? 0.82 : nil, 8)
        case (.buildMuscle, _):
            (sets, low, high, prog, pct, rpe) = (4, 8, 12, "double", nil, 8)
        default:
            (sets, low, high, prog, pct, rpe) = (3, 10, 15, "double", nil, nil)
        }
        if isDeload { sets = max(2, sets - 1) }
        return GeneratedExercise(exerciseName: ex.name, targetSets: sets, repLow: low, repHigh: high,
                                 targetRPE: rpe, targetPctRM: pct, progression: prog)
    }

    // MARK: Hybrid recovery scheduling (§9.3)

    /// Assigns day offsets so a **hard run never lands the day after a heavy lower-body lift**.
    /// Lifts are spread first; hard runs take the remaining non-adjacent days, downgrading to easy
    /// only if forced. Also tags rationale.
    static func schedule(runs: [GeneratedSession], lifts: [GeneratedSession],
                         preferredDayOffsets: [Int] = []) -> [GeneratedSession] {
        var lifts = lifts, runs = runs
        let total = lifts.count + runs.count
        guard total > 0 else { return [] }

        // Use the athlete's preferred days as the candidate pool when they gave enough of them;
        // otherwise fall back to an even spread across the whole week.
        let cleanedPref = Array(Set(preferredDayOffsets.filter { (0..<7).contains($0) })).sorted()
        let pool = cleanedPref.count >= total ? cleanedPref : Array(0..<7)

        let liftDayList = pickSpread(from: pool, count: lifts.count)
        for i in lifts.indices { lifts[i].dayOffset = liftDayList[i] }
        let lowerDays = Set(zip(lifts.indices, liftDayList).filter { lifts[$0.0].isHardLowerLift }.map { $0.1 })
        let usedByLifts = Set(liftDayList)
        let forbidden = Set(lowerDays.map { $0 + 1 })

        // Prefer remaining pool days for runs; fall back to other week days only if the pool runs out.
        let available = pool.filter { !usedByLifts.contains($0) }
            + (0..<7).filter { !pool.contains($0) && !usedByLifts.contains($0) }
        var safe = available.filter { !forbidden.contains($0) }
        var unsafe = available.filter { forbidden.contains($0) }

        // Hard runs first onto safe days; downgrade if none left.
        for i in runs.indices where runs[i].isHardRun {
            if !safe.isEmpty {
                runs[i].dayOffset = safe.removeFirst()
            } else {
                runs[i].isHardRun = false
                runs[i].runType = .easy
                runs[i].intervals = nil
                runs[i].rationale = "Kept easy to protect recovery around your lifting."
                if !unsafe.isEmpty { runs[i].dayOffset = unsafe.removeFirst() }
                else if !safe.isEmpty { runs[i].dayOffset = safe.removeFirst() }
            }
        }
        // Easy runs take whatever remains.
        var remaining = (safe + unsafe).sorted()
        for i in runs.indices where !runs[i].isHardRun && runs[i].dayOffset < 0 {
            runs[i].dayOffset = remaining.isEmpty ? (available.last ?? 6) : remaining.removeFirst()
        }

        var all = (lifts + runs).sorted { $0.dayOffset < $1.dayOffset }
        for i in all.indices where all[i].rationale == nil {
            all[i].rationale = rationale(for: all[i])
        }
        return all
    }

    /// Evenly spread `count` distinct day offsets across a 7-day week.
    static func spread(_ count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var days: [Int] = []
        for i in 0..<count {
            var d = Int((Double(i) + 0.5) * 7.0 / Double(count))
            while days.contains(d) { d = (d + 1) % 7 }
            days.append(d)
        }
        return days.sorted()
    }

    /// Evenly pick `count` distinct days from a candidate `pool` (the athlete's preferred days). If the
    /// pool is smaller than needed, it's used in full and backfilled from the rest of the week.
    static func pickSpread(from pool: [Int], count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let sorted = pool.sorted()
        guard !sorted.isEmpty else { return spread(count) }
        if count >= sorted.count {
            var out = sorted
            var extras = (0..<7).filter { !sorted.contains($0) }
            while out.count < count, !extras.isEmpty { out.append(extras.removeFirst()) }
            return out.sorted()
        }
        var seen = Set<Int>(), result: [Int] = []
        for i in 0..<count {
            let idx = min(sorted.count - 1, Int((Double(i) + 0.5) * Double(sorted.count) / Double(count)))
            if seen.insert(sorted[idx]).inserted { result.append(sorted[idx]) }
        }
        // Backfill any collisions so we always return `count` distinct days.
        var k = 0
        while result.count < count, k < sorted.count {
            if seen.insert(sorted[k]).inserted { result.append(sorted[k]) }
            k += 1
        }
        return result.sorted()
    }

    private static func rationale(for s: GeneratedSession) -> String {
        if s.discipline == .strength { return "\(s.strengthLabel ?? "Strength") day." }
        switch s.runType {
        case .long: return "Long run — build your aerobic base."
        case .tempo: return "Tempo — controlled discomfort lifts your threshold."
        case .intervals: return "Intervals — sharpen speed."
        default: return "Easy run — most of your week should feel like this."
        }
    }

    /// Validates the squat→hard-run recovery invariant (used by tests).
    static func scheduleSatisfiesRecovery(_ sessions: [GeneratedSession]) -> Bool {
        let lowerDays = Set(sessions.filter { $0.isHardLowerLift }.map { $0.dayOffset })
        return !sessions.contains { $0.isHardRun && lowerDays.contains($0.dayOffset - 1) }
    }
}

/// The inputs `PlanEngine` reads — a value mirror of `UserProfile` so generation stays pure.
struct PlanInputs: Sendable {
    var disciplines: [Discipline]
    var goal: Goal
    var daysPerWeek: Int
    var equipment: Equipment
    var sessionMinutes: Int
    var raceDate: Date?
    var runningExperience: ExperienceLevel
    var liftingExperience: ExperienceLevel
    /// Target race distance (meters) — shapes the long run + quality work. nil → general fitness.
    var raceDistanceM: Double? = nil
    /// Muscles to emphasize — adds a working set to matching strength exercises.
    var muscleFocus: [MuscleGroup] = []
    /// Preferred in-week day offsets (0…6 from the plan's start day). Empty → even auto-spread.
    var preferredDayOffsets: [Int] = []
}
