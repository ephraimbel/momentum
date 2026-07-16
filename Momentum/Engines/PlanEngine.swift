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

    /// Training paces from Daniels/VDOT zones (see `DanielsPaces`): recovery/long/easy sit in the E
    /// band (60/64/66% VO₂max), tempo at threshold (~one-hour-race intensity), intervals at vVO₂max.
    /// Curvilinear — the easy gap widens for slower runners instead of a flat "+80 s/km for everyone".
    static func pace(_ type: RunType, p5k: Double) -> Double {
        DanielsPaces.trainingPace(type, p5kSPerKm: p5k)
    }

    /// The pace a *persisted* session should target on (re)derivation — honors the rep intent encoded
    /// in its `intervals` note, so recalibration keeps "@ 5K" reps at race pace, "@ threshold" cruise
    /// reps at T, and "@ race pace" blocks at the goal distance's predicted pace, instead of stamping
    /// every interval session with vVO₂max pace.
    static func sessionPace(_ type: RunType, p5k: Double, intervals: String?,
                            raceDistanceM: Double? = nil) -> Double {
        // Race day targets the GOAL distance's predicted pace — a marathon race session must never
        // re-derive to 5K pace on recalibration (pace(.race) is the 5K scalar, right only for a 5K).
        if type == .race {
            return DanielsPaces.racePaceSPerKm(distanceM: raceDistanceM ?? 5_000, p5kSPerKm: p5k)
        }
        if type == .intervals, let note = intervals?.lowercased() {
            // Threshold first — a rep distance like "1.5km" also contains "5k", so the anchored
            // "@ 5k" check must not win on threshold cruise reps.
            if note.contains("threshold") { return pace(.tempo, p5k: p5k) }
            if note.contains("race pace") {
                return DanielsPaces.racePaceSPerKm(distanceM: raceDistanceM ?? 5_000, p5kSPerKm: p5k)
            }
            if note.contains("@ 5k") { return pace(.race, p5k: p5k) }
        }
        return pace(type, p5k: p5k)
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
            // The athlete's stated hybrid emphasis wins; otherwise infer from the goal.
            let liftFraction: Double
            if let priority = profile.hybridPriority {
                liftFraction = priority.liftFraction
            } else {
                liftFraction = (profile.goal == .buildMuscle || profile.goal == .getStronger) ? 0.6 : 0.4
            }
            liftDays = max(1, Int((Double(days) * liftFraction).rounded()))
            liftDays = min(liftDays, days - 1)
            runDays = days - liftDays
        } else if hasLift {
            liftDays = days
        } else if hasCardio {
            runDays = days
        }

        // Macrocycle (PRD §9.1: base → build → peak → taper).
        let totalWeeks = weeksToGenerate(startDate: startDate, raceDate: profile.raceDate, calendar: calendar)
        // A race past the block's horizon means this block is pure foundation — the race-specific
        // peak/taper arrive when the plan regenerates closer in.
        let raceInWindow = (weeksToRace(startDate: startDate, raceDate: profile.raceDate,
                                        calendar: calendar) ?? .max) <= totalWeeks
        let meso = mesocycle(totalWeeks: totalWeeks, raceDistanceM: profile.raceDistanceM,
                             hasRace: profile.raceDate != nil, raceInsideWindow: raceInWindow)
        let taperMults = taperMultipliers(weeks: meso.taperWeeks)

        var weeks: [GeneratedWeek] = []
        var buildIndex = 0
        var lastBuildMult = 1.0
        // The chosen intensity sets how fast volume ramps and how often we cut back. Aggressive ramps
        // harder and stacks a little more before easing; gentle ramps softly and rests more often.
        // Injury history delivers the onboarding promise ("a safer ramp where you've been hurt"):
        // the ramp and deload cadence are capped at balanced, so an aggressive pick can't stack
        // volume onto a body that's been hurt before. Gentle stays gentle.
        let injuryAreas = Set(profile.injuryHistory)
        let ramp = injuryAreas.isEmpty
            ? profile.intensity.weeklyRamp
            : min(profile.intensity.weeklyRamp, PlanIntensity.balanced.weeklyRamp)
        var buildWeeks = injuryAreas.isEmpty
            ? profile.intensity.buildWeeksPerDownWeek
            : min(profile.intensity.buildWeeksPerDownWeek, PlanIntensity.balanced.buildWeeksPerDownWeek)
        // Masters recovery (50+): keep the intensity, add recovery frequency — the evidence for older
        // athletes favors more frequent absorption weeks over softer work. Deload every 3rd week.
        if (profile.age ?? 0) >= 50 { buildWeeks = min(buildWeeks, 2) }
        let downEvery = buildWeeks + 1   // deload on the Nth week

        // Build ceiling: volume grows toward the race distance's readiness peak and then HOLDS —
        // a year-long marathon plan reaches marathon volume; a no-race block never exceeds double
        // its start. Clamped so a very low starting base can't be asked to quadruple in one plan.
        let startWeeklyM = profile.currentWeeklyVolumeM ?? {
            switch profile.runningExperience { case .new: 14_000; case .some: 26_000; case .experienced: 42_000 }
        }()
        let multCeiling: Double = {
            guard hasCardio, let raceM = profile.raceDistanceM, startWeeklyM > 0 else { return 2.0 }
            let peakTarget = PlanFeasibility.peakWeeklyVolumeM(distanceM: raceM,
                                                               experience: profile.runningExperience)
            return min(3.5, max(1.0, peakTarget / startWeeklyM))
        }()
        // Post-race recovery lead-in (the reverse taper): the block's first weeks are all-easy at a
        // fraction of normal volume, then training resumes from baseline. Never consumes the whole
        // block, and shifts the deload cadence so a natural down-week doesn't land right after it.
        let leadIn = max(0, min(profile.postRaceRecoveryWeeks, totalWeeks - 1))
        let leadInMults = recoveryMultipliers(weeks: leadIn)
        for w in 0..<totalWeeks {
            let isTaper = meso.taperWeeks > 0 && w >= totalWeeks - meso.taperWeeks
            let isPeak = !isTaper && meso.peakWeeks > 0 && w >= totalWeeks - meso.taperWeeks - meso.peakWeeks
            let isLeadIn = w < leadIn && !isTaper && !isPeak
            let isDeload = !isTaper && !isPeak
                && (isLeadIn || (w >= leadIn && (w - leadIn) % downEvery == downEvery - 1))
            let phase: PlanPhase = isTaper ? .taper
                : isPeak ? .peak
                : isDeload ? .recovery
                : (w < meso.baseWeeks + leadIn ? .base : .build)
            let volumeMult: Double
            if isTaper {
                // Bosquet 2007: exponential volume cut relative to the PEAK week (race week ~45–55%
                // of peak), never relative to week one — a long plan's taper isn't a crash diet.
                let into = w - (totalWeeks - meso.taperWeeks)
                volumeMult = lastBuildMult * taperMults[min(into, taperMults.count - 1)]
            } else if isPeak {
                volumeMult = lastBuildMult          // hold the biggest load — no further ramp
            } else if isLeadIn {
                volumeMult = leadInMults[min(w, leadInMults.count - 1)]
            } else if isDeload {
                volumeMult = lastBuildMult * 0.7
            } else {
                // Grow toward the ceiling, then hold: long runways plateau at the race-appropriate
                // peak instead of compounding geometrically for months. (The ACWR governor guards
                // the week-over-week rate; this guards the destination.)
                volumeMult = min(pow(ramp, Double(buildIndex)), multCeiling)
                lastBuildMult = volumeMult
                buildIndex += 1
            }

            let runs = hasCardio
                ? cardioSessions(discipline: cardio!, runDays: runDays, level: profile.runningExperience,
                                 goal: profile.goal, p5k: p5k, volumeMult: volumeMult, isDeload: isDeload,
                                 raceDistanceM: profile.raceDistanceM, weekIndex: w,
                                 currentWeeklyVolumeM: profile.currentWeeklyVolumeM, longestRunM: profile.longestRunM,
                                 injuryAreas: injuryAreas, phase: phase)
                : []
            let lifts = hasLift
                ? strengthSessions(liftDays: liftDays, goal: profile.goal, level: profile.liftingExperience,
                                   equipment: profile.equipment, sessionMinutes: profile.sessionMinutes,
                                   catalog: catalog, isDeload: isDeload || isTaper, muscleFocus: Set(profile.muscleFocus))
                : []
            let scheduled = schedule(runs: runs, lifts: lifts, preferredDayOffsets: profile.preferredDayOffsets)
            weeks.append(GeneratedWeek(index: w, isDeload: isDeload, isTaper: isTaper, phase: phase, sessions: scheduled))
        }

        // Safety governor (ENDURANCE-FOCUS §6.2): no generated week may exceed 1.3× its trailing
        // 4-week average running volume. Dormant on sane ramps; catches the dangerous edges.
        let factors = ACWRGovernor.capFactors(weeklyMeters: weeks.map(\.runVolumeM),
                                              currentWeeklyM: profile.currentWeeklyVolumeM ?? 0)
        for (w, factor) in factors.enumerated() where factor < 0.999 {
            for s in weeks[w].sessions.indices where weeks[w].sessions[s].discipline == .running {
                if let d = weeks[w].sessions[s].targetDistanceM {
                    weeks[w].sessions[s].targetDistanceM = (d * factor).rounded()
                }
                if let dur = weeks[w].sessions[s].targetDurationS {
                    weeks[w].sessions[s].targetDurationS = (dur * factor).rounded()
                }
            }
        }

        // Race day itself — the season's crown, placed on the exact race date with the goal distance
        // at this athlete's predicted race pace. The whole macrocycle points at this day; without it
        // the plan tapers into… a filler run. Added AFTER the ACWR governor (you don't run 80% of a
        // marathon) and BEFORE RunRounding (whose `isRace` branch snaps it to the exact distance).
        if raceInWindow, cardio == .running, let raceDate = profile.raceDate,
           let raceM = profile.raceDistanceM, raceM > 0 {
            let dayCount = calendar.dateComponents([.day], from: calendar.startOfDay(for: startDate),
                                                   to: calendar.startOfDay(for: raceDate)).day ?? -1
            let raceWeek = dayCount / 7
            if dayCount >= 0, raceWeek < weeks.count {
                let off = dayCount % 7
                // Race day owns the rest of its week: nothing on the day itself, and nothing after —
                // post-race days are recovery, not training. The day before drops any lift (nobody
                // squats the eve of their goal race) and a run there becomes a classic shakeout
                // (short + easy, with a few strides unless a speed-sensitive injury history rules
                // maximal turnover out).
                weeks[raceWeek].sessions.removeAll {
                    $0.dayOffset >= off || ($0.dayOffset == off - 1 && $0.discipline == .strength)
                }
                let shakeoutStrides = injuryAreas.isDisjoint(with: Self.speedSensitiveAreas)
                for i in weeks[raceWeek].sessions.indices
                    where weeks[raceWeek].sessions[i].dayOffset == off - 1
                          && weeks[raceWeek].sessions[i].discipline == .running {
                    weeks[raceWeek].sessions[i].runType = shakeoutStrides ? .strides : .easy
                    weeks[raceWeek].sessions[i].isHardRun = false
                    weeks[raceWeek].sessions[i].intervals = shakeoutStrides ? "4×20sec strides" : nil
                    weeks[raceWeek].sessions[i].targetDistanceM =
                        min(weeks[raceWeek].sessions[i].targetDistanceM ?? 3_000, 3_000)
                    weeks[raceWeek].sessions[i].targetPaceSPerKm = pace(.easy, p5k: p5k)
                    weeks[raceWeek].sessions[i].rationale = "Shakeout — loose legs for tomorrow. Nothing to gain here, plenty to lose."
                }
                var race = GeneratedSession(dayOffset: off, discipline: .running)
                race.runType = .race
                race.targetDistanceM = raceM
                race.targetPaceSPerKm = DanielsPaces.racePaceSPerKm(distanceM: raceM, p5kSPerKm: p5k)
                race.isHardRun = true
                race.rationale = "Race day — everything pointed here. Trust the taper and run your plan."
                weeks[raceWeek].sessions.append(race)
                weeks[raceWeek].sessions.sort { $0.dayOffset < $1.dayOffset }
            }
        }

        // Clean prescriptions (RunRounding): snap every running target to the round value a coach
        // would write in the athlete's unit — the LAST step, so it's what's stored and shown. The
        // race session snaps to the exact race distance. Perturbs weekly volume by <2% (well inside
        // the ACWR guardrail's range), so the safety ramp holds.
        for w in weeks.indices {
            for s in weeks[w].sessions.indices where weeks[w].sessions[s].discipline == .running {
                guard let d = weeks[w].sessions[s].targetDistanceM, d > 0 else { continue }
                let isRace = weeks[w].sessions[s].runType == .race
                weeks[w].sessions[s].targetDistanceM =
                    RunRounding.snap(meters: d, unit: profile.distanceUnit, isRace: isRace)
            }
        }

        return GeneratedPlan(p5kSPerKm: p5k, weeks: weeks)
    }

    /// Weeks between now and the race, inclusive of race week (nil without a race date).
    static func weeksToRace(startDate: Date, raceDate: Date?, calendar: Calendar) -> Int? {
        guard let race = raceDate else { return nil }
        return max(0, calendar.dateComponents([.weekOfYear], from: startDate, to: race).weekOfYear ?? 0) + 1
    }

    /// Any timeframe generates a real plan: a race next week gets a 1-week race-week block, and a
    /// marathon next YEAR gets the whole season — up to 52 weeks of base → build → peak → taper
    /// landing exactly on race week. Beyond a year, the block is pure foundation and the horizon
    /// rolls forward on regeneration — never a taper stranded before race day.
    static func weeksToGenerate(startDate: Date, raceDate: Date?, calendar: Calendar) -> Int {
        guard let toRace = weeksToRace(startDate: startDate, raceDate: raceDate, calendar: calendar) else {
            return openBlockWeeks
        }
        return max(1, min(52, toRace))
    }

    /// An open-ended plan (no race date) generates one full mesocycle at a time — a rolling BLOCK the
    /// athlete renews when it wraps (`PlanService.renewBlock`), so the plan never dead-ends and never
    /// bloats into an unearned year-long prescription for someone who just wants to get fitter. Six
    /// weeks is a real training block — base + build with an absorbed deload — long enough to show
    /// progress and short enough to reassess honestly ("we'll see where you're at").
    static let openBlockWeeks = 6

    /// Mesocycle boundaries (base → build → peak → taper). Taper length follows the science by race
    /// distance — 5K/10K ≈ 1 week, half ≈ 2, marathon+ ≈ 3 (Bosquet 2007 meta: cut volume 41–60%,
    /// KEEP intensity and frequency) — capped at a quarter of the plan so a short runway still gets
    /// build weeks. Peak = 1–2 race-specific weeks holding the biggest volume before the taper, when
    /// the plan is long enough to afford them. Base ≈ the first quarter. No race → one settling week,
    /// then a rolling build.
    static func mesocycle(totalWeeks: Int, raceDistanceM: Double?, hasRace: Bool,
                          raceInsideWindow: Bool = true)
        -> (baseWeeks: Int, peakWeeks: Int, taperWeeks: Int) {
        guard hasRace else { return (1, 0, 0) }
        // Race beyond this block's horizon → pure foundation (base + build, deloads as earned) —
        // never a phantom taper stranded weeks before race day.
        guard raceInsideWindow else {
            return (max(1, Int((0.25 * Double(totalWeeks)).rounded())), 0, 0)
        }
        let byDistance: Int
        switch raceDistanceM {
        case .some(let d) where d < 13_000: byDistance = 1
        case .some(let d) where d < 25_000: byDistance = 2
        case .some(let d) where d < 45_000: byDistance = 3
        case .some: byDistance = 4                    // ultra — the deepest hole needs the longest climb out
        case .none: byDistance = min(3, Int((0.15 * Double(totalWeeks)).rounded(.up)))
        }
        // Ultra-short runway (≤3 weeks): there's no building left to do — the honest block is a
        // freshness taper that gets the athlete to the line ready to run the day well.
        if totalWeeks <= 3 { return (0, 0, min(byDistance, totalWeeks)) }
        let taper = min(byDistance, max(1, totalWeeks / 4))
        let peak = totalWeeks - taper >= 8 ? 2 : (totalWeeks - taper >= 5 ? 1 : 0)
        let base = max(1, min(Int((0.25 * Double(totalWeeks)).rounded()), totalWeeks - taper - peak - 1))
        return (base, peak, taper)
    }

    /// Taper-week volume as a fraction of the PEAK week, per week into the taper (Bosquet 2007:
    /// progressive exponential-style reduction; race week lands at ~45–55% of peak volume).
    static func taperMultipliers(weeks: Int) -> [Double] {
        switch weeks {
        case ..<2: return [0.55]
        case 2: return [0.65, 0.5]
        case 3: return [0.7, 0.55, 0.45]
        default: return [0.75, 0.65, 0.55, 0.45]      // ultra — a gentler, longer glide to the start
        }
    }

    /// Post-race recovery lead-in length by the distance just raced — the reverse taper. The weeks
    /// after a goal race are the highest re-injury window in running: the block that follows starts
    /// with this many all-easy weeks before normal training resumes (5K/10K ≈ 1, half ≈ 1,
    /// marathon ≈ 2, ultra ≈ 3 — matching the "recover as long as the taper" convention).
    static func postRaceRecoveryWeeks(forRaceM race: Double) -> Int {
        switch race {
        case ..<25_000: return 1
        case ..<45_000: return 2
        default: return 3
        }
    }

    /// Recovery lead-in volume as a fraction of the athlete's normal week, per week into the
    /// lead-in — a reverse taper climbing back to baseline (never a jump straight to full load).
    static func recoveryMultipliers(weeks: Int) -> [Double] {
        switch weeks {
        case ..<2: return [0.55]
        case 2: return [0.45, 0.7]
        default: return [0.4, 0.6, 0.8]
        }
    }

    // MARK: Cardio sessions

    static func cardioSessions(discipline: Discipline, runDays: Int, level: ExperienceLevel,
                               goal: Goal, p5k: Double, volumeMult: Double, isDeload: Bool,
                               raceDistanceM: Double? = nil, weekIndex: Int = 0,
                               currentWeeklyVolumeM: Double? = nil, longestRunM: Double? = nil,
                               injuryAreas: Set<InjuryArea> = [], phase: PlanPhase = .build) -> [GeneratedSession] {
        guard runDays > 0 else { return [] }
        var (easyBase, longBase, qualityBase): (Double, Double, Double)
        // Seed the starting week from the athlete's actual current load when they gave it — so the plan
        // meets them where they are instead of an experience-tier average (fixes "too aggressive" plans).
        if let weekly = currentWeeklyVolumeM, weekly > 0 {
            let hasLong = runDays >= 2, hasQuality = runDays >= 3
            longBase = min(max(longestRunM ?? weekly * 0.35, weekly * 0.22), weekly * 0.45)
            qualityBase = weekly * 0.18
            let easyDays = max(1, runDays - (hasLong ? 1 : 0) - (hasQuality ? 1 : 0))
            let used = (hasLong ? longBase : 0) + (hasQuality ? qualityBase : 0)
            easyBase = max(weekly * 0.12, (weekly - used) / Double(easyDays))
        } else {
            switch level {
            case .new: (easyBase, longBase, qualityBase) = (3000, 5000, 3000)
            case .some: (easyBase, longBase, qualityBase) = (6000, 10000, 5000)
            case .experienced: (easyBase, longBase, qualityBase) = (9000, 16000, 8000)
            }
        }
        let isRunning = discipline == .running

        // Race-specific shaping: the long run progresses toward a race-appropriate peak and is clamped
        // there so a 5K plan doesn't drift into marathon volume (and a marathon's long run actually
        // gets long). Short races sharpen with intervals; long races build threshold with tempo.
        let longCap = raceDistanceM.map { longRunPeak(forRaceM: $0) }
        if let cap = longCap {
            // Seeded athletes start from their own longest run (never forced up to half-peak); everyone
            // else uses the race-appropriate default. Both cap at the race peak.
            longBase = currentWeeklyVolumeM != nil ? min(longBase, cap) : min(max(longBase, cap * 0.5), cap)
        }
        let useIntervals: Bool = {
            if let r = raceDistanceM { return r <= 12_000 }     // 5K/10K → speed; half/marathon → tempo
            return goal == .raceDistance || goal == .endurance
        }()

        var out: [GeneratedSession] = []
        // `paceOverride` lets VO₂ / threshold interval sessions carry a rep pace other than 5k pace.
        func makeRun(_ type: RunType, _ base: Double, hard: Bool, intervals: String? = nil,
                     cap: Double? = nil, paceOverride: Double? = nil, note: String? = nil) -> GeneratedSession {
            var s = GeneratedSession(dayOffset: -1, discipline: discipline)
            var dist = (base * volumeMult).rounded()
            if let cap { dist = min(dist, cap.rounded()) }
            s.targetDistanceM = dist
            if isRunning {
                s.runType = type
                s.targetPaceSPerKm = paceOverride ?? pace(type, p5k: p5k)
                s.intervals = intervals
                s.isHardRun = hard
                s.rationale = note
            }
            return s
        }

        // Long run — the rotation for non-beginners outside deload/taper weeks:
        //  • every 3rd week a progression run (finish faster than you started),
        //  • for half/marathon+ plans in build/peak, every 3rd week a **race-pace finish** — the
        //    signature marathon workout (Canova/Daniels: the last kilometres at goal pace on tired
        //    legs are the race rehearsal nothing else provides). The block grows with the calendar.
        //  • otherwise plain and easy. Taper long runs always stay plain — freshness, not stimulus.
        if runDays >= 2 {
            let rotate = level != .new && !isDeload && phase != .taper
            let longRace = (raceDistanceM ?? 0) >= 20_000
            if rotate, longRace, weekIndex % 3 == 1, phase == .build || phase == .peak, isRunning {
                var s = makeRun(.long, longBase, hard: true, cap: longCap)
                let dist = s.targetDistanceM ?? 0
                // Grow 3 km → cap (marathon 8 km, half 5 km), never more than 40% of the run.
                let finishKm = min(Double(3 + weekIndex / 3),
                                   (raceDistanceM ?? 0) >= 40_000 ? 8 : 5,
                                   (dist / 1000) * 0.4).rounded(.down)
                if finishKm >= 2 {
                    s.intervals = "Last \(Int(finishKm))km @ race pace"
                    s.rationale = "Long run with a race-pace finish — racing on tired legs is the skill."
                } else {
                    s.isHardRun = false   // too short for a real block → plain long run
                }
                out.append(s)
            } else {
                let longType: RunType = (rotate && weekIndex % 3 == 2) ? .progression : .long
                out.append(makeRun(longType, longBase, hard: false, cap: longCap))
            }
        }
        // The week's main quality session. Deload weeks skip it entirely; taper weeks KEEP it —
        // taper science cuts volume, never intensity (the menu shrinks to a short race-pace touch).
        if runDays >= 3 && !isDeload && goal != .stayConsistent && isRunning {
            // The athlete's weekly volume this week — scales the threshold dose (Daniels: T volume
            // per session tops out near ~10% of weekly mileage, so cruise reps grow with the athlete).
            let tierWeekly: Double = switch level { case .new: 14_000; case .some: 26_000; case .experienced: 42_000 }
            let weeklyM = (currentWeeklyVolumeM ?? tierWeekly) * volumeMult
            let q = qualityWorkout(weekIndex: weekIndex, raceDistanceM: raceDistanceM, level: level, p5k: p5k,
                                   injuryAreas: injuryAreas, phase: phase, weeklyVolumeM: weeklyM)
            out.append(makeRun(q.type, qualityBase, hard: true, intervals: q.intervals,
                               paceOverride: q.paceOverride, note: q.note))
        }
        // Fill easy; for non-beginners, one easy run becomes a strides day (cheap neuromuscular speed).
        // Deload weeks keep exactly this one touch of turnover — volume drops ~30% and quality is
        // skipped, but a few relaxed strides stop the legs going flat (a deload absorbs, not stales).
        // Maximal-speed strides are the classic re-injury mechanism for hamstring/hip histories, so
        // those athletes keep the day easy instead.
        var stridesAdded = false
        let avoidStrides = !injuryAreas.isDisjoint(with: Self.speedSensitiveAreas)
        while out.count < runDays {
            if isRunning, level != .new, !stridesAdded, !avoidStrides,
               (runDays >= 4 || (isDeload && runDays >= 3)) {
                stridesAdded = true
                out.append(makeRun(.strides, easyBase, hard: false, intervals: "6×20sec strides"))
            } else {
                let intervals = (isRunning && level == .new) ? "Run/walk 1:1" : nil
                out.append(makeRun(.easy, easyBase, hard: false, intervals: intervals))
            }
        }
        return out
    }

    /// Body areas that high-impact hill repeats load hardest (ENDURANCE-FOCUS §8.2) — with a history
    /// here, quality stays flat and controlled.
    static let impactSensitiveAreas: Set<InjuryArea> = [.shins, .ankle, .achilles, .foot, .calf, .knee, .itBand]
    /// Areas whose classic re-injury mechanism is maximal-speed running — no sprint-fast reps/strides.
    static let speedSensitiveAreas: Set<InjuryArea> = [.hamstring, .hip]

    /// The week's main quality workout — phase-aware and progressive, not a flat rotation:
    ///  • **base** is pyramidal (Seiler/Lydiard): tempo, hills-for-strength, fartlek — no VO₂ or
    ///    race-pace sharpening while the foundation is being laid.
    ///  • **build** rotates the race-specific menu, and rep counts GROW with the week index
    ///    (progressive overload of the stimulus, audit fix #3 — not "6×400 @ 5K" forever).
    ///  • **peak** goes race-specific at full flight: race-pace reps + VO₂ for short races,
    ///    threshold cruise + goal-race-pace blocks for long ones.
    ///  • **taper** keeps intensity while volume falls (Bosquet): one short race-pace touch a week.
    /// `paceOverride` carries a rep pace other than the type's default zone: "@ 5K" reps at race
    /// pace, threshold cruise at T, "@ race pace" at the goal distance's predicted pace.
    ///
    /// Injury history reshapes every phase's menu (ENDURANCE-FOCUS §8.2): lower-leg/knee histories
    /// swap high-impact hill reps out; hamstring/hip histories swap sprint-fast reps and strides for
    /// threshold cruise work. The swap is explained on the session (`note`) — never silent.
    static func qualityWorkout(weekIndex: Int, raceDistanceM: Double?, level: ExperienceLevel,
                               p5k: Double, injuryAreas: Set<InjuryArea> = [], phase: PlanPhase = .build,
                               weeklyVolumeM: Double? = nil)
        -> (type: RunType, intervals: String?, paceOverride: Double?, note: String?) {
        let fiveK = pace(.race, p5k: p5k), threshold = pace(.tempo, p5k: p5k)
        let goalRace = DanielsPaces.racePaceSPerKm(distanceM: raceDistanceM ?? 5_000, p5kSPerKm: p5k)
        let avoidImpact = !injuryAreas.isDisjoint(with: impactSensitiveAreas)
        let avoidSpeed = !injuryAreas.isDisjoint(with: speedSensitiveAreas)
        let impactNote = "Kept quality flat and controlled — building carefully around your injury history."
        let speedNote = "Cruise reps instead of fast ones — protecting where you've been hurt before."

        // Progressive overload within the block: rep counts climb with the calendar, capped at a
        // sane ceiling. Interval strings drive the guided-run builder, so growth flows through.
        let r400 = min(10, 6 + weekIndex / 3)
        let rVO2 = min(6, 4 + weekIndex / 3)
        let rHill = min(12, 8 + weekIndex / 3)
        // Threshold dose scales with the ATHLETE, not just the calendar (Daniels: T volume per
        // session tops out near ~10% of weekly mileage). A 40 km/wk runner cruises 4–5×1km; a
        // 120 km/wk runner has earned 10–12. The calendar still gates the ramp inside the ceiling.
        let tCeil = weeklyVolumeM.map { max(4, min(12, Int(($0 * 0.10) / 1000))) } ?? 7
        let rKm = min(tCeil, 4 + weekIndex / 4)
        let shortRace = (raceDistanceM ?? 5_000) <= 12_000

        var menu: [(RunType, String?, Double?, String?)]
        if level == .new {
            // Beginners keep the same gentle menu in every phase — consistency beats periodization
            // until the habit and the tissues are established.
            menu = [(.fartlek, "6×(1min hard / 2min easy)", nil, nil),
                    avoidSpeed ? (.tempo, nil, nil, speedNote)
                               : (.strides, "6×20sec strides", nil, nil),
                    (.tempo, nil, nil, nil)]
        } else {
            switch phase {
            case .base:
                menu = [(.tempo, nil, nil, nil),
                        avoidImpact ? (.fartlek, "6×(2min hard / 90sec float)", nil, impactNote)
                                    : (.hills, "\(rHill)×45sec hills", nil, nil),
                        (.fartlek, "8×(1min hard / 1min float)", nil, nil)]
            case .peak:
                menu = shortRace
                    ? [avoidSpeed ? (.intervals, "\(rKm)×1km @ threshold", threshold, speedNote)
                                  : (.intervals, "\(r400)×400m @ 5K", fiveK, nil),
                       (.intervals, "\(rVO2)×3min @ VO2", nil, nil)]
                    : [(.intervals, "\(rKm)×1km @ threshold", threshold, nil),
                       (.intervals, "3×2km @ race pace", goalRace, nil)]
            case .taper:
                menu = shortRace
                    ? [avoidSpeed ? (.intervals, "3×1km @ threshold", threshold, speedNote)
                                  : (.intervals, "4×400m @ 5K", fiveK, nil)]
                    : [(.intervals, "3×1km @ race pace", goalRace, nil)]
            default:   // .build (recovery weeks never request quality)
                if shortRace {
                    menu = [avoidSpeed ? (.intervals, "\(rKm)×1km @ threshold", threshold, speedNote)
                                       : (.intervals, "\(r400)×400m @ 5K", fiveK, nil),
                            (.intervals, "\(rVO2)×3min @ VO2", nil, nil),
                            avoidImpact ? (.tempo, nil, nil, impactNote)
                                        : (.hills, "\(rHill)×45sec hills", nil, nil),
                            (.fartlek, "8×(1min hard / 1min float)", nil, nil)]
                } else {
                    menu = [(.intervals, "\(rKm)×1km @ threshold", threshold, nil),
                            (.tempo, nil, nil, nil),
                            (.fartlek, "6×(2min hard / 90sec float)", nil, nil),
                            (.intervals, "\(min(tCeil, 5 + weekIndex / 4))×1km @ threshold", threshold, nil)]
                }
            }
        }
        let pick = menu[((weekIndex % menu.count) + menu.count) % menu.count]
        return (pick.0, pick.1, pick.2, pick.3)
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
                let day = safe.removeFirst()
                runs[i].dayOffset = day
                // In a hybrid week, explain the cross-discipline placement (fresh legs) — our edge.
                // An injury-history note set at generation is more specific: it wins.
                if runs[i].rationale == nil, let rt = runs[i].runType {
                    runs[i].rationale = HybridSequencing.runRationale(dayIndex: day, runType: rt, legDays: lowerDays)
                }
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
        case .progression: return "Progression — start easy, finish strong; teaches pace control on tired legs."
        case .tempo: return "Tempo — controlled discomfort lifts your threshold."
        case .intervals: return "Intervals — sharpen speed and running economy."
        case .fartlek: return "Fartlek — playful surges that build speed without the track."
        case .hills: return "Hill reps — strength and power, easy on the joints."
        case .strides: return "Strides — short, fast, relaxed; wakes up your legs."
        case .race: return "Race day — everything pointed here."
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
    /// Current running load (meters) captured at onboarding — seeds starting volume when present.
    var currentWeeklyVolumeM: Double? = nil
    var longestRunM: Double? = nil
    /// Hybrid emphasis — biases the run/lift day split. nil → inferred from the goal.
    var hybridPriority: HybridPriority? = nil
    /// Muscles to emphasize — adds a working set to matching strength exercises.
    var muscleFocus: [MuscleGroup] = []
    /// Preferred in-week day offsets (0…6 from the plan's start day). Empty → even auto-spread.
    var preferredDayOffsets: [Int] = []
    /// How hard to push — sets the weekly volume ramp + down-week cadence. Defaults to balanced.
    var intensity: PlanIntensity = .balanced
    /// Past injury areas from onboarding — caps the ramp at balanced and steers quality selection
    /// away from each area's aggravating stimulus (the "safer ramp where you've been hurt" promise).
    var injuryHistory: [InjuryArea] = []
    /// Age in years (from onboarding's birth year) — 50+ gets masters recovery: deload every 3rd
    /// week instead of the intensity default. Intensity itself is never reduced by age.
    var age: Int? = nil
    /// Post-race recovery lead-in (weeks): the block opens with this many all-easy reverse-taper
    /// weeks before normal training resumes. Set by `PlanService.completeRace` on the block that
    /// follows a finished goal race; 0 everywhere else.
    var postRaceRecoveryWeeks: Int = 0
    /// The athlete's display unit — prescriptions snap to clean values in it (`RunRounding`), so a
    /// coach's "run 4 miles / a 5K" reads clean instead of "3.73 mi". Storage stays SI.
    var distanceUnit: DistanceUnit = .metric
}
