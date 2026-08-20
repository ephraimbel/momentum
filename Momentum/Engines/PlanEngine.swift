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
        // Quality density follows the same injury cap as the ramp: a body that's been hurt before
        // never gets the second weekly quality session, whatever the intensity dial says.
        let qualityBias = injuryAreas.isEmpty
            ? profile.intensity.qualityBias
            : min(profile.intensity.qualityBias, PlanIntensity.balanced.qualityBias)

        // Podium activation: the top tier's structural upgrades (higher volume ceiling, longer
        // long-run cap, the two-hard-days week as standard, rest-day shakeouts) switch on only
        // when the week can hold them (5+ run days) and the body has no injury history — the same
        // protective cap as the ramp. Podium on a 3-day week or a hurt body trains like Aggressive.
        let podiumActive = profile.intensity == .podium && runDays >= 5 && injuryAreas.isEmpty

        // The tune-up time trial (2026-07-24, pro-practice pass): every real build for a long race
        // carries a checkpoint race effort — coaches use it to test fitness and set honest paces.
        // Ours does the same job mechanically: a hard 5K TT is planned quality, so its result feeds
        // the recalibration loop (bank → confirm) with REAL evidence instead of waiting for one to
        // happen by accident. Placed once, on the first build week (end of base = exactly when a
        // coach tests), for in-window races of 10K+ with an 8+ week runway.
        let wantsTimeTrial = cardio == .running && raceInWindow && totalWeeks >= 8
            && (profile.raceDistanceM ?? 0) >= 10_000 && runDays >= 3
        var timeTrialPlaced = false

        // Build ceiling: volume grows toward the race distance's readiness peak and then HOLDS —
        // a year-long marathon plan reaches marathon volume; a no-race block never exceeds double
        // its start. Clamped so a very low starting base can't be asked to quadruple in one plan.
        // Podium raises the readiness peak ~20% — front-of-race preparation runs real volume.
        let startWeeklyM = profile.currentWeeklyVolumeM ?? {
            switch profile.runningExperience { case .new: 14_000; case .some: 26_000; case .experienced: 42_000 }
        }()
        let multCeiling: Double = {
            guard hasCardio, let raceM = profile.raceDistanceM, startWeeklyM > 0 else { return 2.0 }
            let peakTarget = PlanFeasibility.peakWeeklyVolumeM(distanceM: raceM,
                                                               experience: profile.runningExperience)
                * (podiumActive ? 1.2 : 1.0)
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
            var longWaveMult = 1.0
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
                // Once the plateau is reached, the LONG RUN oscillates instead of repeating the
                // same distance for months (real programs wave: 16-18-20-14…). The deload cadence
                // still provides the big dips; this is the week-to-week texture between them.
                if volumeMult >= multCeiling - 0.0001 {
                    longWaveMult = Self.longRunWave[buildIndex % Self.longRunWave.count]
                }
                lastBuildMult = volumeMult
                buildIndex += 1
            }

            let isTimeTrialWeek = wantsTimeTrial && !timeTrialPlaced && phase == .build && !isDeload
            if isTimeTrialWeek { timeTrialPlaced = true }
            let runs = hasCardio
                ? cardioSessions(discipline: cardio!, runDays: runDays, level: profile.runningExperience,
                                 goal: profile.goal, p5k: p5k, volumeMult: volumeMult, isDeload: isDeload,
                                 raceDistanceM: profile.raceDistanceM, weekIndex: w,
                                 currentWeeklyVolumeM: profile.currentWeeklyVolumeM, longestRunM: profile.longestRunM,
                                 injuryAreas: injuryAreas, phase: phase,
                                 qualityBias: qualityBias, longWaveMult: longWaveMult,
                                 podium: podiumActive, timeTrial: isTimeTrialWeek)
                : []
            let lifts = hasLift
                ? strengthSessions(liftDays: liftDays, goal: profile.goal, level: profile.liftingExperience,
                                   equipment: profile.equipment, sessionMinutes: profile.sessionMinutes,
                                   catalog: catalog, isDeload: isDeload || isTaper, muscleFocus: Set(profile.muscleFocus),
                                   split: profile.strengthSplit, weekIndex: w)
                : []
            var scheduled = schedule(runs: runs, lifts: lifts,
                                     preferredDayOffsets: profile.preferredDayOffsets,
                                     avoidDayOffsets: profile.avoidDayOffsets)
            // Podium's rest-day shakeout: on training weeks (never deload/taper/lead-in), one of
            // the remaining rest days — the day after the long run when it's free — carries an
            // OPTIONAL 3 km jog. "Rest days will just be a slow mile or two" is the tier's promise;
            // the rationale keeps it honest: skipping it still counts as rest.
            if podiumActive, hasCardio, !isDeload, !isTaper, !isLeadIn, runDays <= 6 {
                let used = Set(scheduled.map(\.dayOffset))
                let afterLong = scheduled.first(where: { $0.runType == .long }).map(\.dayOffset).map { $0 + 1 }
                let day = (afterLong.flatMap { $0 <= 6 && !used.contains($0) ? $0 : nil })
                    ?? (0...6).first { !used.contains($0) }
                if let day {
                    var jog = GeneratedSession(dayOffset: day, discipline: cardio!)
                    jog.runType = .recovery
                    jog.targetDistanceM = 3_000
                    jog.targetPaceSPerKm = pace(.recovery, p5k: p5k)
                    jog.rationale = "Optional shakeout — twenty easy minutes keeps the legs turning between hard days. Flat today? Skipping it counts as rest too."
                    scheduled.append(jog)
                    scheduled.sort { $0.dayOffset < $1.dayOffset }
                }
            }
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

        // Clean prescriptions (RunRounding): snap every running target — distance AND pace — to the
        // round value a coach would write in the athlete's unit, as the LAST step, so it's what's
        // stored and shown. The race session snaps to the exact race distance; easy-family paces
        // snap to :15 and quality/race paces to :05 (8:30/mi, never 8:24/mi). Perturbs weekly
        // volume by <2% and paces by ≤7.5 s/unit (inside SessionPaceReview's tolerance band), so
        // both the ACWR ramp and the pace-review verdicts hold.
        for w in weeks.indices {
            for s in weeks[w].sessions.indices where weeks[w].sessions[s].discipline == .running {
                let runType = weeks[w].sessions[s].runType
                if let d = weeks[w].sessions[s].targetDistanceM, d > 0 {
                    // A time trial IS its distance — "5K time trial", never "3 mi time trial".
                    let canonical = runType == .race
                        || weeks[w].sessions[s].intervals?.contains("Time trial") == true
                    weeks[w].sessions[s].targetDistanceM =
                        RunRounding.snap(meters: d, unit: profile.distanceUnit, isRace: canonical)
                }
                if let p = weeks[w].sessions[s].targetPaceSPerKm, p > 0, let runType {
                    weeks[w].sessions[s].targetPaceSPerKm =
                        RunRounding.snapPace(sPerKm: p, unit: profile.distanceUnit, type: runType)
                }
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
                               injuryAreas: Set<InjuryArea> = [], phase: PlanPhase = .build,
                               qualityBias: Double = 1.0, longWaveMult: Double = 1.0,
                               podium: Bool = false, timeTrial: Bool = false) -> [GeneratedSession] {
        guard runDays > 0 else { return [] }
        var (easyBase, longBase, qualityBase): (Double, Double, Double)
        // Seed the starting week from the athlete's actual current load when they gave it — so the plan
        // meets them where they are instead of an experience-tier average (fixes "too aggressive" plans).
        if let weekly = currentWeeklyVolumeM, weekly > 0 {
            let hasLong = runDays >= 2, hasQuality = runDays >= 3
            // Long-run share of the week: ≤30-ish% once there are enough days to spread volume across
            // (the microcycle guideline); 3-day runners legitimately concentrate more in the long run.
            let shareCap = runDays >= 4 ? 0.32 : 0.45
            longBase = min(max(longestRunM ?? weekly * 0.35, weekly * 0.22), weekly * shareCap)
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
        // gets long). The companion rule — short races sharpen with intervals, long races build
        // threshold with tempo — is applied inside `qualityWorkout` (see its race band), which is
        // where the session menu is actually chosen.
        let raceCap = raceDistanceM.map { longRunPeak(forRaceM: $0, podium: podium) }
        if let cap = raceCap {
            // Seeded athletes start from their own longest run (never forced up to half-peak); everyone
            // else uses the race-appropriate default. Both cap at the race peak.
            longBase = currentWeeklyVolumeM != nil ? min(longBase, cap) : min(max(longBase, cap * 0.5), cap)
        }
        // Time-on-feet cap: no long run beyond ~3 h at this athlete's long-run pace (Daniels caps by
        // DURATION, not distance — a 32 km prescription is a 4-hour injury factory for a slower
        // runner, and the aerobic stimulus tops out long before the tissue damage does).
        let durationCapM = ((podium ? 12_600.0 : 10_800.0) / pace(.long, p5k: p5k)) * 1000   // podium: 3.5 h
        longBase = min(longBase, durationCapM)
        let longCap: Double? = min(raceCap ?? .infinity, durationCapM)
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
            // `longWaveMult` oscillates the plateau (1.0 / 0.88 / 0.95) so months of identical
            // 32 km Sundays become a real wave; the caps still bound every variant.
            let wavedLong = longBase * longWaveMult
            // `!timeTrial`: the checkpoint week keeps its long run EASY — the test needs fresh
            // legs to mean anything, so the TT is that week's only hard running.
            if rotate, longRace, weekIndex % 3 == 1, phase == .build || phase == .peak, isRunning, !timeTrial {
                var s = makeRun(.long, wavedLong, hard: true, cap: longCap)
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
                out.append(makeRun(longType, wavedLong, hard: false, cap: longCap))
            }
        }
        // The athlete's weekly volume this week — scales the threshold dose (Daniels: T volume per
        // session tops out near ~10% of weekly mileage) and gates the second quality slot.
        let tierWeekly: Double = switch level { case .new: 14_000; case .some: 26_000; case .experienced: 42_000 }
        let weeklyM = (currentWeeklyVolumeM ?? tierWeekly) * volumeMult
        // The week's main quality session. Deload weeks skip it entirely; taper weeks KEEP it —
        // taper science cuts volume, never intensity (the menu shrinks to a short race-pace touch).
        var primaryQuality: (type: RunType, intervals: String?, paceOverride: Double?, note: String?)?
        if runDays >= 3 && !isDeload && goal != .stayConsistent && isRunning {
            if timeTrial {
                // The checkpoint race effort — replaces this week's quality menu. A .tempo carrier
                // (planned quality, so a hard result banks recalibration evidence) at 5K race pace.
                let tt = (type: RunType.tempo, intervals: Optional("Time trial — 5K at race effort"),
                          paceOverride: Optional(pace(.race, p5k: p5k)),
                          note: Optional("A checkpoint, not a race: run it honest. Your training paces recalibrate from the result."))
                primaryQuality = tt
                var session = makeRun(tt.type, 5_000, hard: true, intervals: tt.intervals,
                                      paceOverride: tt.paceOverride, note: tt.note)
                // A test is its exact distance — never scaled by the week's multiplier (the final
                // snap also keeps it canonical, so the governor can't be silently undone there).
                session.targetDistanceM = 5_000
                out.append(session)
                // The fixed 5K can outweigh the quality it replaced — shave the surplus off the
                // easy days so the week's TOTAL stays on the governed ramp.
                let fillerDays = Double(max(1, runDays - (runDays >= 2 ? 1 : 0) - 1))
                let surplus = 5_000 - qualityBase * volumeMult
                if surplus > 0 {
                    easyBase = max(2_000, easyBase - (surplus / fillerDays) / volumeMult)
                }
            } else {
                let q = qualityWorkout(weekIndex: weekIndex, raceDistanceM: raceDistanceM, level: level, p5k: p5k,
                                       injuryAreas: injuryAreas, phase: phase, weeklyVolumeM: weeklyM,
                                       qualityDistanceM: qualityBase * volumeMult)
                primaryQuality = q
                out.append(makeRun(q.type, qualityBase, hard: true, intervals: q.intervals,
                                   paceOverride: q.paceOverride, note: q.note))
            }
        }
        // The SECOND weekly quality session — the dial `PlanIntensity.qualityBias` was built for.
        // Two hard sessions is the Pfitzinger/Hansons norm for committed athletes; one-forever was
        // the biggest gap between our plans and a real program. Earned, never default: aggressive
        // or experienced athletes at real volume (≥45 km/wk), on ≥5 run days, in build/peak only
        // (base stays pyramidal, taper stays fresh), never with an injury history (the same
        // protective cap as the ramp), and never on a deload. The stimulus COMPLEMENTS the primary
        // (`secondQualityWorkout`) — threshold beside a speed day, VO₂ beside a threshold day.
        var secondQualityAdded = false
        // A race-pace-finish long run IS this week's second hard stimulus — Pfitzinger pairs the
        // LT day with the RP-long in one week, and nobody stacks a third quality session on top.
        // Without this gate, the rotation weeks (weekIndex%3==1 in a half/marathon build) carried
        // RP-long + primary + second quality: three hard days on a five-day week, which is the
        // grey-zone overload every coach's first red pen finds.
        let longIsHard = out.contains { ($0.runType == .long || $0.runType == .progression) && $0.isHardRun }
        let wantsSecond = !timeTrial && !longIsHard
            && (qualityBias > 1.0 || level == .experienced) && weeklyM >= (podium ? 40_000 : 45_000)
        if isRunning, runDays >= 5, !isDeload, goal != .stayConsistent, injuryAreas.isEmpty,
           level != .new, wantsSecond, phase == .build || phase == .peak, out.count < runDays,
           let primary = primaryQuality {
            let q2 = secondQualityWorkout(weekIndex: weekIndex, p5k: p5k,
                                          weeklyVolumeM: weeklyM, primary: primary)
            secondQualityAdded = true
            out.append(makeRun(q2.type, qualityBase * 0.85, hard: true, intervals: q2.intervals,
                               paceOverride: q2.paceOverride, note: q2.note))
        }
        // Fill the remaining days with real TEXTURE, not identical easy runs (a week that reads
        // "5.5 / 5.5 / 5.5" was the tell of a template):
        //  • one strides day (cheap neuromuscular speed) — skipped when a second quality session
        //    already covers turnover, and on hamstring/hip histories (max-speed re-injury risk);
        //    deload weeks keep exactly this one touch so the legs don't go flat.
        //  • one MEDIUM-LONG run (the Pfitzinger staple — the quiet aerobic middle gear), and one
        //    true RECOVERY jog, on ≥5-day weeks. Sized 1.4× / 0.6× the easy base, so together they
        //    equal two easy days — texture is volume-neutral.
        var stridesAdded = false
        var mediumLongAdded = false, recoveryAdded = false
        let avoidStrides = !injuryAreas.isDisjoint(with: Self.speedSensitiveAreas)
        let texture = isRunning && level != .new && !isDeload && phase != .taper && runDays >= 5
        while out.count < runDays {
            if isRunning, level != .new, !stridesAdded, !avoidStrides, !secondQualityAdded,
               (runDays >= 4 || (isDeload && runDays >= 3)) {
                stridesAdded = true
                out.append(makeRun(.strides, easyBase, hard: false, intervals: "6×20sec strides"))
            } else if texture, !mediumLongAdded {
                mediumLongAdded = true
                var s = makeRun(.easy, easyBase * 1.4, hard: false,
                                cap: min(longBase * volumeMult * 0.85, longCap ?? .infinity))
                s.rationale = "Medium-long run — the quiet aerobic engine-builder between the hard days."
                out.append(s)
            } else if texture, !recoveryAdded {
                recoveryAdded = true
                var s = makeRun(.recovery, easyBase * 0.6, hard: false)
                s.rationale = "Recovery jog — slower on purpose; this is where the hard work absorbs."
                out.append(s)
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
                               weeklyVolumeM: Double? = nil, qualityDistanceM: Double? = nil)
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
        // Hills need a hill — not every athlete has one, so the plan never REQUIRES terrain
        // (2026-07-24). The power stimulus is a flat hard-surge fartlek by default; a hill
        // is a welcome option, not a prerequisite. Dedicated hill sessions live in the
        // workout library for athletes who have one and want it.
        let powerNote = "Short, hard efforts for power — flat ground is perfect; take them uphill if you've got a hill."
        // Threshold dose scales with the ATHLETE, not just the calendar (Daniels: T volume per
        // session tops out near ~10% of weekly mileage). A 40 km/wk runner cruises 4–5×1km; a
        // 120 km/wk runner has earned 10–12. The calendar still gates the ramp inside the ceiling.
        let tCeil = weeklyVolumeM.map { max(4, min(12, Int(($0 * 0.10) / 1000))) } ?? 7
        let rKm = min(tCeil, 4 + weekIndex / 4)
        // Race bands: a 10K is NOT a long 5K — it's threshold-centric with VO₂ touches (Daniels),
        // where 5K training leans on speed and half/marathon+ on threshold + race-pace volume.
        // The old ≤12 km "short" boundary trained 10K runners on 400s at 5K pace all build.
        let raceM = raceDistanceM ?? 5_000
        let shortRace = raceM <= 8_000
        let midRace = raceM > 8_000 && raceM <= 15_000

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
                                    : (.fartlek, "\(rHill)×(45sec hard / 90sec float)", nil, powerNote),
                        (.fartlek, "8×(1min hard / 1min float)", nil, nil)]
            case .peak:
                menu = shortRace
                    ? [avoidSpeed ? (.intervals, "\(rKm)×1km @ threshold", threshold, speedNote)
                                  : (.intervals, "\(r400)×400m @ 5K", fiveK, nil),
                       (.intervals, "\(rVO2)×3min @ VO2", nil, nil)]
                    : midRace
                    ? [(.intervals, "\(rKm)×1km @ threshold", threshold, nil),
                       (.intervals, "3×1km @ race pace", goalRace, nil)]
                    : [(.intervals, "\(rKm)×1km @ threshold", threshold, nil),
                       (.intervals, "3×2km @ race pace", goalRace, nil)]
            case .taper:
                menu = shortRace
                    ? [avoidSpeed ? (.intervals, "3×1km @ threshold", threshold, speedNote)
                                  : (.intervals, "4×400m @ 5K", fiveK, nil)]
                    // The mid-band taper touch is at RACE pace — the old short-race menu sent 10K
                    // runners into race week practicing a pace faster than they'll run.
                    : [(.intervals, "3×1km @ race pace", goalRace, nil)]
            default:   // .build (recovery weeks never request quality)
                if shortRace {
                    menu = [avoidSpeed ? (.intervals, "\(rKm)×1km @ threshold", threshold, speedNote)
                                       : (.intervals, "\(r400)×400m @ 5K", fiveK, nil),
                            (.intervals, "\(rVO2)×3min @ VO2", nil, nil),
                            avoidImpact ? (.tempo, nil, nil, impactNote)
                                        : (.fartlek, "\(rHill)×(45sec hard / 90sec float)", nil, powerNote),
                            (.fartlek, "8×(1min hard / 1min float)", nil, nil)]
                } else if midRace {
                    menu = [(.intervals, "\(rKm)×1km @ threshold", threshold, nil),
                            (.intervals, "\(rVO2)×3min @ VO2", nil, nil),
                            (.tempo, nil, nil, nil),
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
        // Continuous tempo caps at ~25 min at threshold (Daniels; Pfitzinger tops out similarly) —
        // a bigger allocation becomes cruise intervals, the same T dose in absorbable pieces. At
        // 80 km/wk the old allocation prescribed 40+ continuous minutes at T, which nobody runs.
        if pick.0 == .tempo, let qDist = qualityDistanceM {
            let tempoCapM = (1_500.0 / threshold) * 1000 + 2_000   // 25 min at T + wu/cd carve
            if qDist > tempoCapM {
                return (.intervals, "\(rKm)×1km @ threshold", threshold, pick.3)
            }
        }
        return (pick.0, pick.1, pick.2, pick.3)
    }

    /// The plateau wave for the long run (applied once weekly volume holds at its ceiling): full,
    /// step-back, near-full — so a months-long plateau reads 32-28-30-32 instead of 32 forever.
    /// Deload weeks still provide the big dips; this is the texture between them.
    static let longRunWave: [Double] = [1.0, 0.88, 0.95]

    /// The week's SECOND quality session — always the COMPLEMENT of the primary (the Pfitzinger
    /// LT+VO₂ pairing): a threshold-flavored primary earns a VO₂ touch; anything else (speed reps,
    /// hills, fartlek, race-pace blocks) earns threshold cruise work. Two stimuli classes means the
    /// two hard days can never collapse into the same workout. Injury histories never reach here
    /// (the second slot is gated off entirely for them).
    static func secondQualityWorkout(weekIndex: Int, p5k: Double, weeklyVolumeM: Double?,
                                     primary: (type: RunType, intervals: String?, paceOverride: Double?, note: String?))
        -> (type: RunType, intervals: String?, paceOverride: Double?, note: String?) {
        let threshold = pace(.tempo, p5k: p5k)
        let tCeil = weeklyVolumeM.map { max(4, min(12, Int(($0 * 0.10) / 1000))) } ?? 7
        let rKm = min(tCeil, 4 + weekIndex / 4)
        let rVO2 = min(5, 3 + weekIndex / 4)
        let primaryIsThreshold = (primary.intervals?.lowercased().contains("threshold") ?? false)
            || primary.type == .tempo
        return primaryIsThreshold
            ? (.intervals, "\(rVO2)×3min @ VO2", nil,
               "Second quality day — a VO₂ touch beside the threshold work. Your volume has earned both.")
            : (.intervals, "\(rKm)×1km @ threshold", threshold,
               "Second quality day — threshold work beside the harder reps. Your volume has earned both.")
    }

    /// The peak weekly long-run distance a race builds toward (meters). Short races multiply up; long
    /// races run a fraction of race distance (you never run a full marathon in training).
    static func longRunPeak(forRaceM race: Double, podium: Bool = false) -> Double {
        switch race {
        case ..<6_000:    return race * 1.8          // 5K → ~9K long
        case ..<13_000:   return race * 1.5          // 10K → ~15K long
        case ..<25_000:   return min(podium ? 22_000 : 20_000, race * (podium ? 0.95 : 0.9))
        default:          return min(podium ? 35_000 : 32_000, race * (podium ? 0.85 : 0.76))
        }
    }

    // MARK: Strength sessions (§9.2)

    static func strengthSessions(liftDays: Int, goal: Goal, level: ExperienceLevel, equipment: Equipment,
                                 sessionMinutes: Int, catalog: [ExerciseCatalogItem], isDeload: Bool,
                                 muscleFocus: Set<MuscleGroup> = [],
                                 split: StrengthSplitStyle = .coach, weekIndex: Int = 0) -> [GeneratedSession] {
        guard liftDays > 0 else { return [] }
        let labels = splitLabels(liftDays: liftDays, split: split, weekIndex: weekIndex)
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

    /// The week's strength-day labels. `.coach` keeps the original day-count table, bit-identical
    /// for every plan built before splits were choosable. Explicit styles override it at any day
    /// count — and ROTATE across weeks (`weekIndex`), so 2 push-pull-legs days a week still cycle
    /// through legs (P,Pu → L,P → Pu,L…) instead of never reaching them. Fewer than 2 lift days →
    /// full body regardless: a split needs at least two days to be a split.
    static func splitLabels(liftDays: Int, split: StrengthSplitStyle = .coach,
                            weekIndex: Int = 0) -> [String] {
        guard liftDays > 0 else { return [] }
        switch split {
        case .coach:
            switch liftDays {
            case 1, 2, 3: return Array(repeating: "Full Body", count: liftDays)
            case 4: return ["Upper", "Lower", "Upper", "Lower"]
            case 5: return ["Push", "Pull", "Legs", "Upper", "Lower"]
            default: return ["Push", "Pull", "Legs", "Push", "Pull", "Legs"]
            }
        case .fullBody:
            return Array(repeating: "Full Body", count: liftDays)
        case .upperLower:
            guard liftDays >= 2 else { return ["Full Body"] }
            return rotatingLabels(["Upper", "Lower"], count: liftDays, weekIndex: weekIndex)
        case .pushPullLegs:
            guard liftDays >= 2 else { return ["Full Body"] }
            return rotatingLabels(["Push", "Pull", "Legs"], count: liftDays, weekIndex: weekIndex)
        }
    }

    /// `count` labels drawn from `cycle`, continuing across weeks — deterministic (a pure function
    /// of the week index, per the deterministic-engine rule), never restarting mid-cycle.
    private static func rotatingLabels(_ cycle: [String], count: Int, weekIndex: Int) -> [String] {
        let start = (weekIndex * count) % cycle.count
        return (0..<count).map { cycle[(start + $0) % cycle.count] }
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

    /// Picks an exercise for a muscle slot — **rep-countable only**.
    ///
    /// Timed holds and loaded carries are excluded outright, not merely deprioritized. The whole
    /// app logs sets as reps × weight, so an auto-prescribed plank or farmer's carry has no
    /// honest way to be written down: prescribing it in reps is nonsense ("3 × 10–15" of a
    /// plank), and prescribing it in seconds would demand a per-set timer the logger doesn't
    /// have. Excluding them removes the dilemma instead of picking a side of it — every
    /// prescription the plan produces is now something the athlete can actually record.
    ///
    /// These exercises stay in the LIBRARY and remain fully loggable by hand; they are simply
    /// never auto-prescribed (the same arrangement hills have). A slot whose only candidates are
    /// timed is skipped by the caller, which is strictly better than prescribing something
    /// unloggable.
    private static func selectExercise(muscle: MuscleGroup, preferCompound: Bool, allowed: Set<EquipmentType>,
                                       catalog: [ExerciseCatalogItem], used: Set<String>) -> ExerciseCatalogItem? {
        let candidates = catalog.filter {
            allowed.contains($0.equipment) && !used.contains($0.name)
                && $0.primaryMuscles.contains(muscle)
                && ($0.trackingMode == .weightReps || $0.trackingMode == .repsOnly)
        }
        let preferred = candidates.filter { $0.category == (preferCompound ? .compound : .isolation) }
        return preferred.first ?? candidates.first
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
                         preferredDayOffsets: [Int] = [],
                         avoidDayOffsets: [Int] = []) -> [GeneratedSession] {
        var lifts = lifts, runs = runs
        let total = lifts.count + runs.count
        guard total > 0 else { return [] }

        // Use the athlete's preferred days as the candidate pool when they gave enough of them;
        // otherwise the auto-spread schedules around any LEARNED avoid-days (the Athlete Model's
        // slip evidence) — falling back to the whole week when avoiding would leave too few days.
        // An explicit preference always beats the inference (avoid-days are ignored beside it).
        let cleanedPref = Array(Set(preferredDayOffsets.filter { (0..<7).contains($0) })).sorted()
        let pool: [Int]
        if cleanedPref.count >= total {
            pool = cleanedPref
        } else {
            let avoid = Set(avoidDayOffsets)
            let open = (0..<7).filter { !avoid.contains($0) }
            pool = open.count >= total ? open : Array(0..<7)
        }

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

        // The LONG RUN anchors the week, placed first — the way a coach builds a microcycle (fix
        // the long day, then space the quality around it). It takes the LATEST available day, which
        // on calendar-anchored weeks is the weekend slot long runs actually live in. A hard long
        // (race-pace finish) honors the day-after-a-lower-lift rule like any hard run; a plain one
        // may sit anywhere. Without this anchor, the long run took "whatever day was left", which
        // put 25 km between two quality days with zero recovery on either side.
        var hardDays: [Int] = []
        var longDay: Int?
        if let li = runs.firstIndex(where: { $0.runType == .long || $0.runType == .progression }) {
            let candidates = runs[li].isHardRun && !safe.isEmpty ? safe
                : (safe + unsafe).isEmpty ? [] : (safe + unsafe)
            if let day = candidates.max() {
                runs[li].dayOffset = day
                longDay = day
                if runs[li].isHardRun { hardDays.append(day) }
                safe.removeAll { $0 == day }
                unsafe.removeAll { $0 == day }
            }
        }

        // Hard runs next onto safe days; downgrade if none left. With two quality days in a week
        // (the second-quality slot), back-to-back hard days are the classic overuse pattern — so
        // each hard run prefers a day NOT adjacent to an already-placed one, AND not adjacent to
        // the long run (quality on dead legs the day after a long run is the other classic). A
        // soft preference: when the pool leaves no such day, the run still schedules rather than
        // vanish.
        for i in runs.indices where runs[i].isHardRun && runs[i].dayOffset < 0 {
            if !safe.isEmpty {
                let spaced = Set(hardDays + (longDay.map { [$0] } ?? []))
                let idx = safe.firstIndex { d in !spaced.contains { abs($0 - d) == 1 } }
                    ?? safe.firstIndex { d in !hardDays.contains { abs($0 - d) == 1 } }
                    ?? 0
                let day = safe.remove(at: idx)
                hardDays.append(day)
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
    /// How strength days compose — the athlete's split choice. `.coach` = the day-count default.
    var strengthSplit: StrengthSplitStyle = .coach
    /// Muscles to emphasize — adds a working set to matching strength exercises.
    var muscleFocus: [MuscleGroup] = []
    /// Preferred in-week day offsets (0…6 from the plan's start day). Empty → even auto-spread.
    var preferredDayOffsets: [Int] = []
    /// Day offsets the Athlete Model has learned this athlete can't make (derived from slips —
    /// `AthleteModelEngine.avoidWeekdays`). Consulted ONLY when `preferredDayOffsets` is empty:
    /// an explicit choice always beats an inference. The auto-spread schedules around these.
    var avoidDayOffsets: [Int] = []
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
