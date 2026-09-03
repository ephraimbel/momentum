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
    static func pace(_ type: RunType, p5k: Double, threshold: Double? = nil) -> Double {
        DanielsPaces.trainingPace(type, p5kSPerKm: p5k, thresholdSPerKm: threshold)
    }

    /// The pace a *persisted* session should target on (re)derivation — honors the rep intent encoded
    /// in its `intervals` note, so recalibration keeps "@ 5K" reps at race pace, "@ threshold" cruise
    /// reps at T, and "@ race pace" blocks at the goal distance's predicted pace, instead of stamping
    /// every interval session with vVO₂max pace.
    static func sessionPace(_ type: RunType, p5k: Double, intervals: String?,
                            raceDistanceM: Double? = nil, goalRacePaceSPerKm: Double? = nil,
                            thresholdSPerKm: Double? = nil,
                            riegelExponent: Double = DanielsPaces.populationRiegelExponent) -> Double {
        // Race day targets the GOAL pace when the athlete set one (2026-08-28: a goal is a decision,
        // not a fitness read, so recalibration never overwrites it), else the predicted pace — a
        // marathon race session must never re-derive to 5K pace (pace(.race) is the 5K scalar).
        if type == .race {
            return goalRacePaceSPerKm ?? DanielsPaces.racePaceSPerKm(distanceM: raceDistanceM ?? 5_000, p5kSPerKm: p5k,
                                                                     riegelExponent: riegelExponent)
        }
        if type == .intervals, let note = intervals?.lowercased() {
            // Threshold first — a rep distance like "1.5km" also contains "5k", so the anchored
            // "@ 5k" check must not win on threshold cruise reps.
            if note.contains("threshold") { return pace(.tempo, p5k: p5k, threshold: thresholdSPerKm) }
            if note.contains("race pace") {
                return goalRacePaceSPerKm ?? DanielsPaces.racePaceSPerKm(distanceM: raceDistanceM ?? 5_000, p5kSPerKm: p5k,
                                                                         riegelExponent: riegelExponent)
            }
            if note.contains("@ 5k") { return pace(.race, p5k: p5k) }
        }
        return pace(type, p5k: p5k, threshold: thresholdSPerKm)
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
        // The athlete state (2026-09-03): observed threshold anchors the steady family, the
        // personal fatigue exponent shapes every race prediction, durability shapes long-run
        // growth. All optional — without evidence this is exactly the one-number engine.
        let threshold = calibration.thresholdSPerKm
        let exponent = calibration.riegelExponent ?? DanielsPaces.populationRiegelExponent
        let durability = calibration.durability

        // Day allocation across disciplines.
        let days = max(1, min(7, profile.daysPerWeek))
        var liftDays = 0, runDays = 0
        if hasLift && hasCardio {
            let split = hybridSplit(days: days, priority: profile.hybridPriority, goal: profile.goal,
                                    raceDistanceM: profile.raceDate != nil ? profile.raceDistanceM : nil)
            runDays = split.runDays
            liftDays = split.liftDays
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
        /// Consecutive loading weeks since the last eased one — drives the cutback cadence.
        var loadingRun = 0
        // The chosen intensity sets how fast volume ramps and how often we cut back. Aggressive ramps
        // harder and stacks a little more before easing; gentle ramps softly and rests more often.
        // A reported prior injury is a conservative planning modifier, not a prediction: cap the
        // ramp and deload cadence at balanced so an aggressive choice cannot erase recovery margin.
        // Gentle stays gentle; current symptoms still belong in the gated injury flow.
        let injuryAreas = Set(profile.injuryHistory)
        var ramp = injuryAreas.isEmpty
            ? profile.intensity.weeklyRamp
            : min(profile.intensity.weeklyRamp, PlanIntensity.balanced.weeklyRamp)
        var buildWeeks = injuryAreas.isEmpty
            ? profile.intensity.buildWeeksPerDownWeek
            : min(profile.intensity.buildWeeksPerDownWeek, PlanIntensity.balanced.buildWeeksPerDownWeek)
        // Masters recovery (50+): keep the intensity, add recovery frequency — the evidence for older
        // athletes favors more frequent absorption weeks over softer work. Deload every 3rd week.
        if (profile.age ?? 0) >= 50 { buildWeeks = min(buildWeeks, 2) }
        let downEvery = buildWeeks + 1   // deload on the Nth week
        // Quality density follows the same history modifier: a reported prior injury suppresses the
        // second weekly quality session. This is a bounded product policy, not a medical clearance.
        let qualityBias = injuryAreas.isEmpty
            ? profile.intensity.qualityBias
            : min(profile.intensity.qualityBias, PlanIntensity.balanced.qualityBias)

        // Podium activation: the top tier's structural upgrades (higher volume ceiling, longer
        // long-run cap, the two-hard-days week as standard, rest-day shakeouts) switch on only
        // when the week can hold them (5+ run days) and no prior injury was reported — the same
        // conservative modifier as the ramp. Otherwise Podium uses the Aggressive structure.
        let podiumActive = profile.intensity == .podium && runDays >= 5 && injuryAreas.isEmpty

        // The tune-up time trial (2026-07-24, pro-practice pass): every real build for a long race
        // carries a checkpoint race effort — coaches use it to test fitness and set honest paces.
        // Ours does the same job mechanically: a hard 5K TT is planned quality, so its result feeds
        // the recalibration loop (bank → confirm) with REAL evidence instead of waiting for one to
        // happen by accident. Placed once, on the first build week (end of base = exactly when a
        // coach tests), for in-window races of 10K+ with an 8+ week runway.
        // …but only for an athlete a test is honest for. A 5 km time trial is a fixed 5 km at race
        // effort: for a new runner on 14 km a week that is a third of their week spent racing, as
        // their FIRST build session (2026-08-29 coach audit). Nobody tests a beginner — they test
        // an athlete with a base to measure.
        let weeklyForTest = profile.currentWeeklyVolumeM
            ?? (profile.runningExperience == .new ? 14_000 : profile.runningExperience == .some ? 26_000 : 42_000)
        let wantsTimeTrial = cardio == .running && raceInWindow && totalWeeks >= 8
            && (profile.raceDistanceM ?? 0) >= 10_000 && runDays >= 3
            && profile.runningExperience != .new && weeklyForTest >= 30_000
        var timeTrialPlaced = false

        // Build ceiling: volume grows toward the GOAL's peak and then HOLDS — a year-long marathon
        // plan reaches marathon volume; a no-race block never exceeds double its start. Clamped so
        // a very low starting base can't be asked to quadruple in one plan. The peak is the
        // goal-driven read (`PlanFeasibility.peakWeeklyVolumeM(…intensity:goalFinishTimeS:…)`,
        // 2026-08-28): the tier moves the destination, a goal time sets a floor, and the athlete's
        // own ceiling caps it. Injury history holds the tier at Balanced, same as the ramp.
        // Per discipline, like `cardioSessions`' own default: this number is what `weekVolumeM`
        // carries into session sizing, so reading a cyclist's week as a runner's 26 km pinned
        // every ride at the stated-session-length cap and stopped the easy rides growing.
        let startWeeklyM = profile.currentWeeklyVolumeM
            ?? defaultWeeklyVolumeM(discipline: cardio ?? .running, level: profile.runningExperience)
        let peakTier: PlanIntensity = (injuryAreas.isEmpty || profile.intensity == .gentle) ? profile.intensity : .balanced
        let multCeiling: Double = {
            guard hasCardio, startWeeklyM > 0 else { return 2.0 }
            guard let raceM = profile.raceDistanceM else {
                // No race: double the start at most, under the athlete's own ceiling if they set one.
                let cap = profile.targetWeeklyVolumeM.map { max(1.0, $0 / startWeeklyM) } ?? 2.0
                return min(2.0, cap)
            }
            let peakTarget = PlanFeasibility.peakWeeklyVolumeM(distanceM: raceM, experience: profile.runningExperience,
                                                               intensity: peakTier, goalFinishTimeS: profile.goalFinishTimeS,
                                                               currentWeeklyM: startWeeklyM,
                                                               targetWeeklyM: profile.targetWeeklyVolumeM)
            return min(3.5, max(1.0, peakTarget / startWeeklyM))
        }()
        // Post-race recovery lead-in (the reverse taper): the block's first weeks are all-easy at a
        // fraction of normal volume, then training resumes from baseline. Never consumes the whole
        // block, and shifts the deload cadence so a natural down-week doesn't land right after it.
        let leadIn = max(0, min(profile.postRaceRecoveryWeeks, totalWeeks - 1))
        let leadInMults = recoveryMultipliers(weeks: leadIn)
        // Goal-pace specificity (2026-08-28, owner call: train the athlete to the TIME, not just
        // the distance). Every "@ race pace" session used to sit at the pace current fitness
        // predicts, so a 3:30 goal with 4:00 legs trained at 4:00 to the taper. Now:
        //  • the plan's race pace is the GOAL pace, honesty-capped by the improvement model
        //    (`PlanFeasibility.achievableImprovement`) so no session demands a jump physiology
        //    can't deliver in this many weeks;
        //  • it is approached week by week from today's predicted pace, arriving at goal pace by
        //    the start of the race-specific mesocycle (the last 6/6/8/10 weeks before the taper
        //    for 5K/10K/half/marathon — Pfitzinger's "race-specific" block, Daniels' phase IV);
        //  • inside that block the goal-pace DOSE grows every week (`qualityWorkout`) and the
        //    marathon/half long runs finish at goal pace on alternating weekends.
        let predictedRacePace = profile.raceDistanceM.flatMap {
            DanielsPaces.racePaceSPerKm(distanceM: $0, p5kSPerKm: p5k, riegelExponent: exponent)
        }
        let goalRacePace: Double? = {
            guard let raceM = profile.raceDistanceM, let goalS = profile.goalFinishTimeS, goalS > 0,
                  let predicted = predictedRacePace else { return nil }
            let asked = goalS / (raceM / 1000)
            let achievable = PlanFeasibility.achievableImprovement(experience: profile.runningExperience,
                                                                   weeks: totalWeeks, intensity: profile.intensity)
            return max(asked, predicted * (1 - achievable))
        }()
        let specificWeeks: Int = switch profile.raceDistanceM ?? 0 {
        case ..<8_000: 6; case ..<15_000: 6; case ..<25_000: 8; default: 10
        }
        let specificStart = max(meso.baseWeeks + leadIn, totalWeeks - meso.taperWeeks - specificWeeks)
        func racePace(week w: Int) -> Double? {
            guard let predicted = predictedRacePace else { return nil }
            guard let goal = goalRacePace else { return predicted }
            if goal >= predicted { return goal }          // fitter than the goal: train the goal, not faster
            let frac = min(1.0, Double(w + 1) / Double(max(1, specificStart)))
            return predicted + (goal - predicted) * frac
        }
        // Runway-fitted ramp (2026-08-28, owner call): the race has a date and the goal is the
        // goal, so a short runway changes the RAMP, not the destination. If the tier's weekly
        // ramp can't reach the peak inside the build weeks available, steepen it to the rate
        // that does, up to a 15%/week operational ceiling. The workload governor below still holds
        // every week to 1.3× its trailing average; neither value is presented as an injury or safety
        // threshold. A reported injury keeps the Balanced cap so the goal cannot force a faster ramp.
        if raceInWindow, multCeiling > 1.0 {
            let buildSlots = totalWeeks - meso.taperWeeks - meso.peakWeeks - leadIn
            let buildable = max(1, buildSlots - buildSlots / downEvery)
            let needed = log(multCeiling) / log(ramp)
            if needed > Double(buildable) {
                let fitted = pow(multCeiling, 1.0 / Double(buildable))
                let ceiling = injuryAreas.isEmpty ? 1.15 : PlanIntensity.balanced.weeklyRamp
                ramp = min(ceiling, max(ramp, fitted))
            }
        }
        for w in 0..<totalWeeks {
            let isTaper = meso.taperWeeks > 0 && w >= totalWeeks - meso.taperWeeks
            let isPeak = !isTaper && meso.peakWeeks > 0 && w >= totalWeeks - meso.taperWeeks - meso.peakWeeks
            let isLeadIn = w < leadIn && !isTaper && !isPeak
            // Absorption is where fitness is made, so the cutback cadence counts EVERY loading
            // week — peak weeks included (2026-08-29 coach audit: a build phase running into a
            // two-week peak stacked six straight loading weeks before the taper, and a "take your
            // time" athlete met five). A peak week that lands on the cadence becomes the cutback;
            // Pfitzinger's peak blocks do exactly this.
            // …but never on the LAST loading week: the taper descends from the week before it, so
            // a cutback there would have the athlete ease off and then climb back up into the
            // taper. The taper is that week's absorption.
            let lastLoadingWeek = totalWeeks - meso.taperWeeks - 1
            // A peak block of one week is the point of the whole macrocycle — it never becomes the
            // cutback, or the plan has no peak at all. With two or more peak weeks the cadence may
            // claim the first; the last always peaks.
            let peakIsSacred = isPeak && (meso.peakWeeks <= 1 || w == totalWeeks - meso.taperWeeks - 1)
            let isDeload = !isTaper && !peakIsSacred
                && (isLeadIn || (w >= leadIn && loadingRun >= buildWeeks && w < lastLoadingWeek))
            let phase: PlanPhase = isTaper ? .taper
                : isDeload ? .recovery
                : isPeak ? .peak
                : (w < meso.baseWeeks + leadIn ? .base : .build)
            let volumeMult: Double
            var longWaveMult = 1.0
            if isTaper {
                // Bosquet 2007: exponential volume cut relative to the PEAK week (race week ~45–55%
                // of peak), never relative to week one — a long plan's taper isn't a crash diet.
                let into = w - (totalWeeks - meso.taperWeeks)
                volumeMult = lastBuildMult * taperMults[min(into, taperMults.count - 1)]
            } else if isLeadIn {
                volumeMult = leadInMults[min(w, leadInMults.count - 1)]
            } else if isDeload {
                volumeMult = lastBuildMult * 0.7
            } else if isPeak {
                volumeMult = lastBuildMult          // hold the biggest load — no further ramp
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

            loadingRun = isDeload || isTaper ? 0 : loadingRun + 1
            let isTimeTrialWeek = wantsTimeTrial && !timeTrialPlaced && phase == .build && !isDeload
            if isTimeTrialWeek { timeTrialPlaced = true }
            let runs = hasCardio
                ? cardioSessions(discipline: cardio!, runDays: runDays, level: profile.runningExperience,
                                 goal: profile.goal, p5k: p5k, volumeMult: volumeMult, isDeload: isDeload,
                                 raceDistanceM: profile.raceDistanceM, weekIndex: w,
                                 currentWeeklyVolumeM: profile.currentWeeklyVolumeM, longestRunM: profile.longestRunM,
                                 injuryAreas: injuryAreas, phase: phase,
                                 qualityBias: qualityBias, longWaveMult: longWaveMult,
                                 podium: podiumActive, weekVolumeM: startWeeklyM * volumeMult, timeTrial: isTimeTrialWeek,
                                 racePace: racePace(week: w),
                                 specificIndex: (raceInWindow && w >= specificStart) ? w - specificStart : -1,
                                 sessionMinutes: profile.sessionMinutes,
                                 thresholdSPerKm: threshold, riegelExponent: exponent, durability: durability)
                : []
            let lifts = hasLift
                ? strengthSessions(liftDays: liftDays, goal: profile.goal, level: profile.liftingExperience,
                                   equipment: profile.equipment, sessionMinutes: profile.sessionMinutes,
                                   catalog: catalog, isDeload: isDeload || isTaper, muscleFocus: Set(profile.muscleFocus),
                                   split: profile.strengthSplit, weekIndex: w, phase: phase)
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
                    jog.targetPaceSPerKm = pace(.recovery, p5k: p5k, threshold: threshold)
                    jog.rationale = "Optional shakeout — twenty easy minutes keeps the legs turning between hard days. Flat today? Skipping it counts as rest too."
                    scheduled.append(jog)
                    scheduled.sort { $0.dayOffset < $1.dayOffset }
                }
            }
            weeks.append(GeneratedWeek(index: w, isDeload: isDeload, isTaper: isTaper, phase: phase, sessions: scheduled))
        }

        // A cutback goes DOWN — a first pass BEFORE the governor so the governor smooths the real
        // shape (2026-08-29 coach audit). A cutback is computed from the build multiplier while the
        // week before it may sit pinned at a long-run cap, so a "recovery" week could otherwise land
        // larger than the week it was meant to absorb. Only ever reduces.
        var lastLoadingVolumePre: Double?
        for w in weeks.indices {
            let eased = weeks[w].isDeload || weeks[w].isTaper
            guard !weeks[w].sessions.contains(where: { $0.runType == .race }) else { continue }
            guard eased else {
                if weeks[w].trainingVolumeM > 0 { lastLoadingVolumePre = weeks[w].trainingVolumeM }
                continue
            }
            guard let ceiling = lastLoadingVolumePre, ceiling > 0,
                  weeks[w].trainingVolumeM > ceiling * 0.90 else { continue }
            let raceMeters = weeks[w].sessions.filter { $0.runType == .race }
                .reduce(0.0) { $0 + ($1.targetDistanceM ?? 0) }
            let trainable = weeks[w].trainingVolumeM - raceMeters
            let target = max(0, ceiling * 0.90 - raceMeters)
            guard trainable > 0, target < trainable else { continue }
            let factor = max(0.4, target / trainable)   // a cutback trims, never blanks
            for i in weeks[w].sessions.indices
            where weeks[w].sessions[i].discipline != .strength && weeks[w].sessions[i].runType != .race {
                if let d = weeks[w].sessions[i].targetDistanceM {
                    weeks[w].sessions[i].targetDistanceM = (d * factor).rounded()
                }
                if let dur = weeks[w].sessions[i].targetDurationS {
                    weeks[w].sessions[i].targetDurationS = (dur * factor).rounded()
                }
            }
        }

        // Progression governor (ENDURANCE-FOCUS §6.2): no generated week may exceed 1.3× its trailing
        // 4-week average running volume. Dormant on ordinary ramps; catches abrupt engine output. An
        // athlete who never stated a volume is anchored on the plan's own opening week — passing 0
        // made the first ratio degenerate and read the opening week as a spike (2026-08-29).
        let factors = ACWRGovernor.capFactors(weeklyMeters: weeks.map(\.trainingVolumeM),
                                              currentWeeklyM: profile.currentWeeklyVolumeM ?? 0)
        for (w, factor) in factors.enumerated() where factor < 0.999 {
            for s in weeks[w].sessions.indices where weeks[w].sessions[s].discipline != .strength {
                if let d = weeks[w].sessions[s].targetDistanceM {
                    weeks[w].sessions[s].targetDistanceM = (d * factor).rounded()
                }
                if let dur = weeks[w].sessions[s].targetDurationS {
                    weeks[w].sessions[s].targetDurationS = (dur * factor).rounded()
                }
            }
        }

        // A down week goes DOWN — enforced after the governor, on the volumes the athlete
        // actually sees. Multipliers alone could not guarantee it (2026-08-29 coach audit): a
        // cutback is computed from the build multiplier while the week before it may have been
        // trimmed by the governor or pinned at a long-run cap, so a "recovery" week could land
        // larger than the week it was meant to absorb. Enforced HERE rather than before the
        // governor because an artificial dip lowers the trailing average and makes the next week
        // read as a spike. Only ever reduces. (2026-08-29 coach audit). Multipliers alone
        // could not guarantee it: a cutback is computed from the build multiplier while the week
        // before it may have been trimmed by the ACWR governor or pinned at a long-run cap, so a
        // "recovery" week could land larger than the week it was meant to absorb. The rule is
        // simple enough to state and now simple enough to trust: an eased week is at most 95% of
        // the last loading week.
        var lastLoadingVolumeFinal: Double?
        for w in weeks.indices {
            let eased = weeks[w].isDeload || weeks[w].isTaper
            guard !weeks[w].sessions.contains(where: { $0.runType == .race }) else { continue }
            guard eased else {
                if weeks[w].trainingVolumeM > 0 { lastLoadingVolumeFinal = weeks[w].trainingVolumeM }
                continue
            }
            guard let ceiling = lastLoadingVolumeFinal, ceiling > 0,
                  weeks[w].trainingVolumeM > ceiling * 0.95 else { continue }
            // Never scale the race itself — you do not run 85% of your marathon.
            let raceMeters = weeks[w].sessions.filter { $0.runType == .race }
                .reduce(0.0) { $0 + ($1.targetDistanceM ?? 0) }
            let trainable = weeks[w].trainingVolumeM - raceMeters
            let target = max(0, ceiling * 0.95 - raceMeters)
            guard trainable > 0, target < trainable else { continue }
            let factor = max(0.4, target / trainable)   // a cutback trims, never blanks
            for i in weeks[w].sessions.indices
            where weeks[w].sessions[i].discipline != .strength && weeks[w].sessions[i].runType != .race {
                if let d = weeks[w].sessions[i].targetDistanceM {
                    weeks[w].sessions[i].targetDistanceM = (d * factor).rounded()
                }
                if let dur = weeks[w].sessions[i].targetDurationS {
                    weeks[w].sessions[i].targetDurationS = (dur * factor).rounded()
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
                // (short and easy — a plan never prescribes strides; 2026-08-28).
                weeks[raceWeek].sessions.removeAll {
                    $0.dayOffset >= off || ($0.dayOffset == off - 1 && $0.discipline == .strength)
                }
                for i in weeks[raceWeek].sessions.indices
                    where weeks[raceWeek].sessions[i].dayOffset == off - 1
                          && weeks[raceWeek].sessions[i].discipline == .running {
                    weeks[raceWeek].sessions[i].runType = .easy
                    weeks[raceWeek].sessions[i].isHardRun = false
                    weeks[raceWeek].sessions[i].intervals = nil
                    weeks[raceWeek].sessions[i].targetDistanceM =
                        min(weeks[raceWeek].sessions[i].targetDistanceM ?? 3_000, 3_000)
                    weeks[raceWeek].sessions[i].targetPaceSPerKm = pace(.easy, p5k: p5k, threshold: threshold)
                    weeks[raceWeek].sessions[i].rationale = "Shakeout — loose legs for tomorrow. Nothing to gain here, plenty to lose."
                }
                var race = GeneratedSession(dayOffset: off, discipline: .running)
                race.runType = .race
                race.targetDistanceM = raceM
                race.targetPaceSPerKm = goalRacePace ?? DanielsPaces.racePaceSPerKm(distanceM: raceM, p5kSPerKm: p5k,
                                                                                    riegelExponent: exponent)
                race.isHardRun = true
                race.rationale = "Race day — everything pointed here. Trust the taper and run your plan."
                weeks[raceWeek].sessions.append(race)
                weeks[raceWeek].sessions.sort { $0.dayOffset < $1.dayOffset }
            }
        }

        // The athlete's own ceiling, enforced on the week they actually receive (2026-08-30).
        // `PlanFeasibility.peakWeeklyVolumeM` caps the RAMP at "Build up to", but the sessions are
        // then sized and rounded independently — a workout priced from its own dose, a long run
        // pinned at its cap, a shakeout added — and those had the peak drifting past a stated cap
        // by ~15%. A cap the athlete typed is a promise; this keeps it. Never below what they
        // already run, and never scales the race itself.
        if let ceiling = profile.targetWeeklyVolumeM, ceiling > 0 {
            let cap = max(ceiling, profile.currentWeeklyVolumeM ?? 0) * 1.02
            for w in weeks.indices where weeks[w].trainingVolumeM > cap {
                let factor = cap / weeks[w].trainingVolumeM
                for i in weeks[w].sessions.indices
                where weeks[w].sessions[i].discipline != .strength && weeks[w].sessions[i].runType != .race {
                    if let d = weeks[w].sessions[i].targetDistanceM {
                        weeks[w].sessions[i].targetDistanceM = (d * factor).rounded()
                    }
                }
            }
        }

        // Clean prescriptions (RunRounding): snap every running target — distance AND pace — to the
        // round value a coach would write in the athlete's unit. The race session snaps to the exact
        // race distance; easy-family paces snap to :15 and quality/race paces to :05 (8:30/mi,
        // never 8:24/mi). The reduction-only load/down-week reconciliation below may leave a
        // non-race distance just under this grid rather than round it back up through a hard cap.
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

        // Re-run the governor after the ordering pass moved volumes and clean-distance rounding
        // snapped them. On a beginner's small sessions a snap is a large relative change, and the
        // plan the athlete gets is the rounded one, so that is the shape the 1.3x cap has to hold.
        let finalFactors = ACWRGovernor.capFactors(weeklyMeters: weeks.map(\.trainingVolumeM),
                                                   currentWeeklyM: profile.currentWeeklyVolumeM ?? 0)
        for (w, factor) in finalFactors.enumerated() where factor < 0.999 {
            guard !weeks[w].sessions.contains(where: { $0.runType == .race }) else { continue }
            for i in weeks[w].sessions.indices where weeks[w].sessions[i].discipline != .strength {
                if let d = weeks[w].sessions[i].targetDistanceM {
                    weeks[w].sessions[i].targetDistanceM = (d * factor).rounded()
                }
                if let dur = weeks[w].sessions[i].targetDurationS {
                    weeks[w].sessions[i].targetDurationS = (dur * factor).rounded()
                }
            }
        }

        // Reconcile the other reduction-only invariant after that final cap: a labeled deload or
        // taper must still be lower than the most recent loading week. The governor can reduce that
        // earlier loading week after the first down-week pass; unit snapping can also round a small
        // down week back to the same displayed dose. Scaling the eased week here cannot introduce a
        // load spike, add intensity, or alter the schedule. Keep the five-percent margin in raw SI
        // values rather than snapping upward through either constraint.
        var lastLoadingVolumeAfterCaps: Double?
        for w in weeks.indices {
            let eased = weeks[w].isDeload || weeks[w].isTaper
            guard !weeks[w].sessions.contains(where: { $0.runType == .race }) else { continue }
            guard eased else {
                if weeks[w].trainingVolumeM > 0 {
                    lastLoadingVolumeAfterCaps = weeks[w].trainingVolumeM
                }
                continue
            }
            guard let ceiling = lastLoadingVolumeAfterCaps, ceiling > 0,
                  weeks[w].trainingVolumeM >= ceiling else { continue }
            let current = weeks[w].trainingVolumeM
            guard current > 0 else { continue }
            let factor = ceiling * 0.95 / current
            for i in weeks[w].sessions.indices
            where weeks[w].sessions[i].discipline != .strength && weeks[w].sessions[i].runType != .race {
                if let distance = weeks[w].sessions[i].targetDistanceM {
                    weeks[w].sessions[i].targetDistanceM = (distance * factor).rounded()
                }
                if let duration = weeks[w].sessions[i].targetDurationS {
                    weeks[w].sessions[i].targetDurationS = (duration * factor).rounded()
                }
            }
        }


        var generated = GeneratedPlan(p5kSPerKm: p5k, weeks: weeks)
        generated.thresholdSPerKm = threshold
        generated.riegelExponent = calibration.riegelExponent
        generated.durability = durability
        generated.goalRacePaceSPerKm = goalRacePace
        return generated
    }

    /// How a hybrid athlete's week divides between running and lifting.
    ///
    /// Extracted so the ENGINE and the onboarding copy read one definition (2026-08-30): the days
    /// step's honesty note compared the athlete's total days against the race's effective floor,
    /// which told a five-day hybrid their half-marathon build was well staffed when only three of
    /// those days would be runs.
    ///
    /// Run days are derived FIRST so a rounding tie goes to running, not to the gym. `.rounded()`
    /// is half-away-from-zero, so computing lift days first silently handed every .5 to lifting:
    /// "Balanced" came out 1 run / 2 lift on a three-day week, which is not balanced, and at three
    /// and five days it was bit-identical to the strength-heavy choice — one of the three choices
    /// did nothing. Running is the headline of this app; the tie belongs to it.
    static func hybridSplit(days: Int, priority: HybridPriority?, goal: Goal,
                            raceDistanceM: Double? = nil) -> (runDays: Int, liftDays: Int) {
        let days = max(1, min(7, days))
        // The athlete's stated emphasis wins; otherwise infer from the goal. With no stated
        // emphasis a strength goal gets as close to 50/50 as the week allows, but the odd day stays
        // with running. Everything else remains more clearly running-led. A goal changes why the
        // strength is there; it never turns Momentum into a lift-dominant programme.
        let liftFraction = priority?.liftFraction
            ?? ((goal == .buildMuscle || goal == .getStronger) ? 0.50 : 0.30)
        var runDays = max(1, Int((Double(days) * (1 - liftFraction)).rounded()))
        runDays = min(runDays, max(1, days - 1))
        // **The race sets a floor on the running** (owner call 2026-08-30: "we want to make it
        // running focused always since we are a running app"). A dated race is a commitment to a
        // running outcome, and `PlanFeasibility.minimumEffectiveDays` is the frequency below which
        // a build maintains fitness rather than preparing for the distance — so when the week can
        // hold those days, running gets them. Before this a Balanced hybrid who gave us five days
        // for a half marathon received three runs, one under the floor, while the flow told them
        // five days was enough.
        //
        // Lifting is not deleted to do it: it keeps a day always, and two on a four-plus-day week
        // when the athlete asks for more strength support. Small odd schedules can quantize two
        // adjacent preferences to the same split; the runner-first tie is the honest tradeoff.
        if let raceM = raceDistanceM, raceM > 0 {
            let liftFloor = (priority == .lifting && days >= 4) ? 2 : 1
            let need = PlanFeasibility.minimumEffectiveDays(forDistanceM: raceM)
            runDays = max(runDays, min(days - liftFloor, need))
            runDays = max(1, min(runDays, max(1, days - 1)))
        }
        return (runDays, days - runDays)
    }

    /// Weeks between now and the race, inclusive of race week (nil without a race date).
    static func weeksToRace(startDate: Date, raceDate: Date?, calendar: Calendar) -> Int? {
        guard let race = raceDate else { return nil }
        // Counted in DAYS from midnight to midnight, not in `.weekOfYear` between two timestamps
        // (2026-08-29): a race exactly sixteen weeks out generated a sixteen-week plan whose last
        // week was week index 15, while race day lands in week 16 — so the plan had NO RACE DAY on
        // it. `.weekOfYear` floors, and an afternoon start against a morning race date floored it
        // again, which is the commonest case of all: a date picked off a race calendar.
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: startDate),
                                           to: calendar.startOfDay(for: race)).day ?? 0
        return max(1, days / 7 + 1)
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
                               podium: Bool = false, weekVolumeM: Double? = nil,
                               timeTrial: Bool = false, racePace: Double? = nil,
                               specificIndex: Int = -1, sessionMinutes: Int = 0,
                               thresholdSPerKm: Double? = nil,
                               riegelExponent: Double = DanielsPaces.populationRiegelExponent,
                               durability: DurabilitySignal? = nil) -> [GeneratedSession] {
        guard runDays > 0 else { return [] }
        let threshold = thresholdSPerKm
        let isRunning = discipline == .running
        var (easyBase, longBase, qualityBase): (Double, Double, Double)
        /// Days left for plain easy running once the long run and the hard day have their slots.
        var easyDayCount = 0
        // Seed the starting week from the athlete's actual current load when they gave it — so the plan
        // meets them where they are instead of an experience-tier average (fixes "too aggressive" plans).
        // ONE week shape for every athlete (2026-08-29 coach audit). The unseeded branch used to
        // carry fixed bases, which at two or three days a week produced a long run worth 70% of
        // the week and a "quality" session worth 27% of a beginner's mileage. Everyone is now
        // shaped from a weekly total by the same shares — a seeded athlete's real one, an
        // unseeded athlete's experience-tier default. The default is per DISCIPLINE (2026-08-30):
        // an athlete who chose Cycle instead of Run was handed a runner's mileage — 26 km spread
        // over three rides is three twenty-five-minute rides, which is not a cycling week.
        let weekly = (currentWeeklyVolumeM ?? 0) > 0 ? currentWeeklyVolumeM!
            : defaultWeeklyVolumeM(discipline: discipline, level: level)
        // Can this week carry a session that counts? Three days always can; below that it takes
        // real mileage — except in the closing weeks, where even a base-building athlete gets one
        // short race-pace rehearsal so the pace is not novel on the start line.
        let weekCanCarryQuality = runDays >= 3 || phase == .taper || phase == .peak
            || (currentWeeklyVolumeM ?? (level == .new ? 14_000 : level == .some ? 26_000 : 42_000)) >= 18_000
        do {
            // Shares of the week, by how many days the athlete runs. Written as a table because
            // the constraints are only satisfiable at some values and a formula hid that: at three
            // days you cannot have a long run under 40% AND an easy day shorter than it — the
            // three parts have to sum to the week. So the fewer the days, the bigger the long run
            // and the bigger the one session that counts. A two-day week is a long run and a
            // steady run; there is no third slot to get faster in.
            //
            // ONE day is a real answer too (2026-08-30 coach audit). Every hybrid athlete who
            // picks two days a week lands here — the run/lift split rounds to 1/1 at every
            // emphasis — as does any runner whose swim or yoga days eat the budget
            // (`PlanService.rebuild`'s `structuredDays`). That week used to have no long run at
            // all, which meant the fallthrough handed the athlete's ENTIRE stated weekly volume
            // to a single session typed "easy": a 45 km/week runner opened the app to a 45 km
            // easy run, and it grew to 61 km by week six. One run a week is a long run, sized
            // like one and capped like one.
            let hasLong = runDays >= 1
            let hasQuality = isRunning && runDays >= 2 && weekCanCarryQuality
            easyDayCount = max(0, runDays - (hasLong ? 1 : 0) - (hasQuality ? 1 : 0))
            let longShare0: Double, qualityShare: Double
            switch runDays {
            case ...0:  longShare0 = 0;    qualityShare = 0
            case 1:     longShare0 = 0.55; qualityShare = 0
            case 2:     longShare0 = 0.52; qualityShare = 0.48
            case 3:     longShare0 = 0.40; qualityShare = 0.27
            case 4:     longShare0 = 0.33; qualityShare = 0.21
            default:    longShare0 = 0.30; qualityShare = 0.18
            }
            // The athlete's own longest run is honoured where it fits inside the share.
            // Durability moves the long run's SHARE of the week by three points either way: a
            // strong athlete's week leans a little further into the long day, a fragile one's
            // spreads it. The caps below are untouched — this shapes growth, never the ceiling.
            let longShare = longShare0 + (durability == .strong ? 0.03 : durability == .fragile ? -0.03 : 0)
            longBase = hasLong ? min(max(longestRunM ?? weekly * longShare, weekly * 0.22), weekly * longShare) : 0
            qualityBase = hasQuality ? weekly * qualityShare : 0
            easyBase = easyDayCount > 0
                ? max(weekly * 0.10, (weekly - longBase - qualityBase) / Double(easyDayCount))
                : qualityBase
            // The long run is the longest run of the week — a midweek easy run that outruns the
            // athlete's Sunday reads as a mistake because it is one. What the clamp takes off the
            // easy days goes to the LONG run, up to its own share of the week (2026-08-30): with
            // nowhere to put it, a three-day athlete whose longest run sat at 30% of their week
            // quietly received 84% of the volume they had just stated.
            if hasLong, easyDayCount > 0, easyBase > longBase * 0.9 {
                longBase = min(weekly * longShare,
                               longBase + (easyBase - longBase * 0.9) * Double(easyDayCount))
                easyBase = min(max(weekly * 0.10, (weekly - longBase - qualityBase) / Double(easyDayCount)),
                               longBase * 0.9)
            }
        }

        // Race-specific shaping: the long run progresses toward a race-appropriate peak and is clamped
        // there so a 5K plan doesn't drift into marathon volume (and a marathon's long run actually
        // gets long). The companion rule — short races sharpen with intervals, long races build
        // threshold with tempo — is applied inside `qualityWorkout` (see its race band), which is
        // where the session menu is actually chosen.
        // A strong athlete's peak sits 5 % higher, still under the hard 32/35 km ceiling below.
        let raceCap = raceDistanceM.map {
            let peak = longRunPeak(forRaceM: $0, podium: podium, weekVolumeM: weekVolumeM)
            return durability == .strong ? min(podium ? 35_000 : 32_000, peak * 1.05) : peak
        }
        if let cap = raceCap {
            // Seeded athletes start from their own longest run (never forced up to half-peak); everyone
            // else uses the race-appropriate default. Both cap at the race peak.
            longBase = min(longBase, cap)
        }
        // Time-on-feet cap: no long session beyond ~3 h at this athlete's own long pace (Daniels
        // caps by DURATION, not distance — a 32 km prescription is a 4-hour injury factory for a
        // slower runner, and the aerobic stimulus tops out long before the tissue damage does).
        // The clock is the same for every sport; only the speed that fills it changes, so a ride
        // is measured at riding speed and a walk at walking speed rather than at a runner's pace.
        let cruisePace = isRunning ? pace(.long, p5k: p5k, threshold: threshold) : Self.cruisePaceSPerKm(discipline)
        var durationCapM = ((podium ? 12_600.0 : 10_800.0) / cruisePace) * 1000   // podium: 3.5 h
        // A walk is prescribed against a shorter clock: three hours on foot at walking speed is a
        // hike someone plans a weekend around, not a Tuesday session.
        if discipline == .walking { durationCapM = min(durationCapM, (7_200.0 / cruisePace) * 1000) }
        // …and one session a WEEK is capped tighter still. An athlete who runs once is not
        // carrying the load that earns a three-hour effort, whatever their old weekly total said.
        if runDays == 1 { durationCapM = min(durationCapM, (7_200.0 / cruisePace) * 1000) }
        longBase = min(longBase, durationCapM)
        // …and the easy days stay under the long day even when a cap has just shortened it. The
        // shares were struck before the race and time-on-feet ceilings applied, so without this a
        // clamped long session could be overtaken by the ordinary ones beside it.
        if easyDayCount > 0, longBase > 0 { easyBase = min(easyBase, longBase * 0.9) }
        // A cutback week's long run comes down too — otherwise a long run sitting on its race or
        // time-on-feet ceiling ignores the deload multiplier entirely and the "recovery" week
        // never actually recovers.
        let longCap: Double? = min(raceCap ?? .infinity, durationCapM) * (isDeload ? 0.75 : 1.0)
        var out: [GeneratedSession] = []
        // `paceOverride` lets VO₂ / threshold interval sessions carry a rep pace other than 5k pace.
        func makeRun(_ type: RunType, _ base: Double, hard: Bool, intervals: String? = nil,
                     cap: Double? = nil, paceOverride: Double? = nil, note: String? = nil) -> GeneratedSession {
            var s = GeneratedSession(dayOffset: -1, discipline: discipline)
            var dist = (base * volumeMult).rounded()
            if let cap { dist = min(dist, cap.rounded()) }
            // Three hours is the ceiling for ANY session, not just the long one (2026-08-30). It
            // was enforced on the long run alone, so on a two-day week the other session — which
            // is nearly as big by construction — could sail past it: an experienced cyclist's
            // Tuesday reached 80 km, twelve minutes longer than the three-hour ride the same plan
            // refused to prescribe on the weekend.
            if type != .race { dist = min(dist, durationCapM.rounded()) }
            // The athlete's stated session length is a real constraint — a plan that does not fit
            // the hour they have is a plan they abandon. The long run is exempt, deliberately.
            // A ride and a walk are held to the same clock at their own speed (2026-08-30).
            if sessionMinutes > 0, type != .long, type != .progression, type != .race {
                let sessionPace = isRunning ? (paceOverride ?? pace(type, p5k: p5k, threshold: threshold)) : cruisePace
                if sessionPace > 0 {
                    // Half again over what they said, never more. A hard cap AT the stated time
                    // would quietly delete the weekly mileage they also stated — when the two
                    // conflict the mileage is the commitment they actually measured — but a
                    // 30-minute athlete must never open the app to an 84-minute Tuesday.
                    let statedCapM = (Double(sessionMinutes) * 60 / sessionPace) * 1000 * 1.45
                    // …unless their own mileage implies longer sessions anyway. A 60-mile-a-week
                    // athlete runs 90-minute easy days whatever box they ticked; the cap exists to
                    // stop a DISPROPORTIONATE session, not to overrule the volume they measured.
                    // 1.35 covers the medium-long run (1.4x the easy base, ~1.2x the average
                    // session) without licensing a session half again longer than the athlete's
                    // own typical run.
                    // Anchored on the week being BUILT, not the week they walked in with: sessions
                    // grow as the mileage grows, and pinning the cap to the starting average
                    // throttled a sub-3 marathon build to 55 mpw when the goal needs 60+.
                    let weekNow = (weekVolumeM ?? weekly) > 0 ? (weekVolumeM ?? weekly) : weekly
                    let impliedCapM = runDays > 0 ? (weekNow / Double(runDays)) * 1.35 : 0
                    let timeCapM = max(statedCapM, impliedCapM)
                    dist = min(dist, timeCapM.rounded())
                }
            }
            s.targetDistanceM = dist
            if isRunning {
                s.runType = type
                s.targetPaceSPerKm = paceOverride ?? pace(type, p5k: p5k, threshold: threshold)
                s.intervals = intervals
                s.isHardRun = hard
                s.rationale = note
            } else {
                // A ride is not a run and must never be described as one. `runType` stays nil (the
                // surfaces read the discipline for a ride's title), so this is the session's only
                // chance to say what it is — before `schedule`'s fallback fills in a runner's
                // sentence (2026-08-30: every cycling and walking session in the app read "Easy
                // run — most of your week should feel like this").
                s.rationale = note ?? cardioRationale(type, discipline)
            }
            return s
        }

        /// Move the gap between a hard session's ALLOCATED share of the week and its real size
        /// onto the easy days, so changing the SHAPE of the hard day never changes the SIZE of
        /// the week: a base block's capped steady run and a build block's repeats both leave the
        /// week on the same ramp. Positive = the session came out smaller than its share.
        /// A week with no easy days to spread across (two runs, one of them the long run) simply
        /// comes out at what two days can hold, which is the honest answer: the athlete's old
        /// weekly volume was spread over more days than they have now chosen.
        func spendSurplus(_ surplus: Double) {
            let easyDays = runDays - 2          // long + this hard day are already accounted for
            guard easyDays > 0, abs(surplus) > 1 else { return }
            easyBase = max(2_000, easyBase + (surplus / Double(easyDays)) / max(volumeMult, 0.01))
        }

        // Long run — the rotation for non-beginners outside deload/taper weeks:
        //  • every 3rd week a progression run (finish faster than you started),
        //  • for half/marathon+ plans in build/peak, every 3rd week a **race-pace finish** — the
        //    signature marathon workout (Canova/Daniels: the last kilometres at goal pace on tired
        //    legs are the race rehearsal nothing else provides). The block grows with the calendar.
        //  • otherwise plain and easy. Taper long runs always stay plain — freshness, not stimulus.
        //
        // A one-day week gets exactly this session and nothing else: when the week holds a single
        // run it IS the long run (2026-08-30 audit), never an "easy run" carrying the whole week.
        if runDays >= 1 {
            let rotate = runDays >= 2 && level != .new && !isDeload && phase != .taper
            let longRace = (raceDistanceM ?? 0) >= 20_000
            // `longWaveMult` oscillates the plateau (1.0 / 0.88 / 0.95) so months of identical
            // 32 km Sundays become a real wave; the caps still bound every variant.
            var wavedLong = longBase * longWaveMult
            // A fragile athlete's long run grows at HALF the week's ramp on two of every three
            // build weeks — the same destination, reached on more Sundays. What the long run does
            // not take, the easy days already hold (`easyBase` was struck from the full share).
            // `makeRun` multiplies by `volumeMult`; dividing the growth out here halves it.
            if durability == .fragile, phase == .build, weekIndex % 3 != 0, volumeMult > 1 {
                wavedLong *= (1 + (volumeMult - 1) * 0.5) / volumeMult
            }
            // `!timeTrial`: the checkpoint week keeps its long run EASY — the test needs fresh
            // legs to mean anything, so the TT is that week's only hard running.
            // Race-specific weeks alternate goal-pace long runs with plain ones (Pfitzinger); the
            // general build keeps its every-third-week rehearsal.
            let raceFinishWeek = specificIndex >= 0 ? specificIndex % 2 == 1 : weekIndex % 3 == 1
            if rotate, longRace, raceFinishWeek, phase == .build || phase == .peak, isRunning, !timeTrial {
                var s = makeRun(.long, wavedLong, hard: true, cap: longCap)
                let dist = s.targetDistanceM ?? 0
                // Grow 3 km → cap (marathon 8 km, half 5 km), never more than 40% of the run. In the
                // specific block the finish climbs further (marathon 6→16 km, half 4→8 km: the
                // Pfitzinger/Hansons marathon-pace long runs), same 40% guard.
                let isMarathon = (raceDistanceM ?? 0) >= 40_000
                let specificFinish: Double? = specificIndex >= 0 ? {
                    let ladder: [Double] = isMarathon ? [6, 8, 10, 12, 14, 16] : [4, 5, 6, 8]
                    return ladder[min(specificIndex / 2, ladder.count - 1)]
                }() : nil
                let finishKm = min(specificFinish ?? Double(3 + weekIndex / 3),
                                   specificFinish != nil ? (isMarathon ? 16 : 8) : (isMarathon ? 8 : 5),
                                   (dist / 1000) * 0.4).rounded(.down)
                if finishKm >= 2 {
                    s.intervals = "Last \(Int(finishKm))km @ race pace"
                    s.rationale = "Long run with a race-pace finish — racing on tired legs is the skill."
                } else {
                    s.isHardRun = false   // too short for a real block → plain long run
                }
                out.append(s)
            } else {
                // `!timeTrial` for the same reason the race-pace finish is suppressed: a
                // progression run finishes fast, and the checkpoint week's whole point is that the
                // 5K is the only hard running in it (2026-08-30 — the guard was on one branch only).
                let longType: RunType = (rotate && !timeTrial && weekIndex % 3 == 2) ? .progression : .long
                var s = makeRun(longType, wavedLong, hard: false, cap: longCap)
                // The one-run week says out loud what it is. A single weekly run holds the
                // endurance the athlete has; it does not build much, and pretending otherwise is
                // the dishonesty this coach exists to refuse.
                if isRunning, level == .new, s.intervals == nil { s.intervals = "Run/walk 1:1" }
                if runDays == 1, isRunning {
                    s.rationale = "Your run this week — keep it easy and unhurried. One run a week holds your endurance; when you can add a second day, that is where it starts to grow again."
                }
                out.append(s)
            }
        }
        // Does this week's long run already finish at goal pace? Pfitzinger alternates the
        // marathon-pace long run with the lactate-threshold session precisely so both never land
        // in one week; without this the specific block stacked goal-pace repeats ON TOP of a
        // goal-pace long finish and ran 30% of the week at race pace (2026-08-29 coach audit).
        let longCarriesRacePace = out.contains { ($0.intervals ?? "").lowercased().contains("race pace") }
        // The athlete's weekly volume this week — scales the threshold dose (Daniels: T volume per
        // session tops out near ~10% of weekly mileage) and gates the second quality slot.
        let tierWeekly: Double = switch level { case .new: 14_000; case .some: 26_000; case .experienced: 42_000 }
        // The week this plan DELIVERS, not the week the athlete walked in with (2026-08-30). At
        // low day counts the two diverge sharply — a 40 km/week runner who can train twice gets
        // roughly 30 — and budgeting the hard dose against the larger number handed that athlete
        // five kilometres of threshold inside a nineteen-kilometre week.
        let plannedWeekM = max(1_000, longBase + qualityBase + Double(easyDayCount) * easyBase) * volumeMult
        let weeklyM = min((currentWeeklyVolumeM ?? tierWeekly) * volumeMult, plannedWeekM)
        // The week's main quality session. Deload weeks skip it entirely; taper weeks KEEP it —
        // taper science cuts volume, never intensity (the menu shrinks to a short race-pace touch).
        var primaryQuality: (type: RunType, intervals: String?, paceOverride: Double?, note: String?)?
        if runDays >= 2 && weekCanCarryQuality && !isDeload && goal != .stayConsistent && isRunning {
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
                spendSurplus(qualityBase * volumeMult - 5_000)
            } else {
                let q = qualityWorkout(weekIndex: weekIndex, raceDistanceM: raceDistanceM, level: level, p5k: p5k,
                                       injuryAreas: injuryAreas, phase: phase, weeklyVolumeM: weeklyM,
                                       qualityDistanceM: qualityBase * volumeMult,
                                       racePace: racePace,
                                       specificIndex: longCarriesRacePace ? -1 : specificIndex,
                                       thresholdSPerKm: threshold, riegelExponent: riegelExponent)
                primaryQuality = q
                // A repeat session is as long as the WORKOUT is, not as long as the week's
                // quality allocation happens to be (2026-08-30 coach audit). Sizing it from the
                // share produced two opposite absurdities: a two-run week at 70 km handed the
                // athlete "6×1km @ threshold" as a 43 km session at threshold pace, and a lean
                // week handed them "6×1km" inside a 6.5 km session with no room for a warm-up.
                // `repeatSessionM` prices the reps, the jog between them, and the warm-up and
                // cool-down that bracket them — the surplus (or shortfall) moves to the easy
                // days, so the week's TOTAL still sits on the governed ramp.
                // A new runner's hard session is capped tighter — their prescription runs at one
                // pace for its whole length, so the number IS the dose (`beginnerQualityCapM`).
                // Only where the week has an easy day to absorb what the cap takes off, though:
                // on a two-run week the hard day is also the week's other RUN, and shrinking it
                // to a twenty-minute dose leaves a long run and a token beside it.
                let qCap: Double? = q.type == .tempo
                    ? (level == .new && easyDayCount > 0
                        ? beginnerQualityCapM(p5k: p5k, racePaceSPerKm: q.paceOverride, raceDistanceM: raceDistanceM,
                                              thresholdSPerKm: threshold)
                        : tempoCapM(p5k: p5k, weeklyM: weeklyM, weekIndex: weekIndex, thresholdSPerKm: threshold))
                    : nil
                // A repeat session carries its reps INSIDE a real run (Pfitzinger's medium-long
                // with a threshold block): it is never shorter than the workout needs — reps,
                // the jog between them, a warm-up and a cool-down — and never longer than a long
                // session. Between those it takes its share of the week, so the easy volume the
                // share was paying for is not thrown away.
                let allocated = qualityBase * volumeMult
                let sized = repeatSessionM(intervals: q.intervals,
                                           repPaceSPerKm: q.paceOverride ?? pace(q.type, p5k: p5k, threshold: threshold),
                                           p5k: p5k, thresholdSPerKm: threshold)
                let target = min(max(sized ?? allocated, allocated), durationCapM)
                let session = makeRun(q.type, target / max(volumeMult, 0.01),
                                      hard: true, intervals: q.intervals,
                                      cap: qCap, paceOverride: q.paceOverride, note: q.note)
                spendSurplus(allocated.rounded() - (session.targetDistanceM ?? 0))
                out.append(session)
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
                                          weeklyVolumeM: weeklyM, primary: primary,
                                          thresholdSPerKm: threshold)
            secondQualityAdded = true
            // Priced from its own dose, exactly like the primary — the second hard day is a
            // workout, not a second slice of the week's quality budget.
            let allocated2 = qualityBase * 0.85 * volumeMult
            let sized2 = repeatSessionM(intervals: q2.intervals,
                                        repPaceSPerKm: q2.paceOverride ?? pace(q2.type, p5k: p5k, threshold: threshold),
                                        p5k: p5k, thresholdSPerKm: threshold)
            let second = makeRun(q2.type, min(max(sized2 ?? allocated2, allocated2), durationCapM) / max(volumeMult, 0.01),
                                 hard: true, intervals: q2.intervals,
                                 paceOverride: q2.paceOverride, note: q2.note)
            // One fewer easy day than `spendSurplus` assumes (it prices the long + one hard day),
            // so the shift is spread by hand over what is genuinely left.
            let easyLeft = runDays - 3
            if easyLeft > 0 {
                let surplus = allocated2.rounded() - (second.targetDistanceM ?? 0)
                easyBase = max(2_000, easyBase + (surplus / Double(easyLeft)) / max(volumeMult, 0.01))
            }
            out.append(second)
        }
        // Fill the remaining days with real TEXTURE, not identical easy runs (a week that reads
        // "5.5 / 5.5 / 5.5" was the tell of a template):
        //  • one MEDIUM-LONG run (the Pfitzinger staple — the quiet aerobic middle gear), and one
        //    true RECOVERY jog, on ≥5-day weeks. Sized 1.4× / 0.6× the easy base, so together they
        //    equal two easy days — texture is volume-neutral.
        var mediumLongAdded = false, recoveryAdded = false
        let texture = isRunning && level != .new && !isDeload && phase != .taper && runDays >= 5
        while out.count < runDays {
            if texture, !mediumLongAdded {
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
        // Long-run share, checked against the week actually built (2026-08-28): the week-based
        // cap above is an estimate from the tier/seed volume; once the sessions exist, the long
        // run may not exceed ~28% of the real week unless the race alone asks for more (3-day
        // weeks legitimately concentrate more in the long run — `longRunPeak`'s race term).
        if let raceM = raceDistanceM,
           let i = out.firstIndex(where: { $0.runType == .long || $0.runType == .progression }),
           let long = out[i].targetDistanceM {
            let others = out.enumerated().filter { $0.offset != i }.reduce(0.0) { $0 + ($1.element.targetDistanceM ?? 0) }
            let shareCap = max(longRunPeak(forRaceM: raceM, podium: podium), (0.28 / 0.72) * others)
            if long > shareCap { out[i].targetDistanceM = shareCap.rounded() }
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
                               weeklyVolumeM: Double? = nil, qualityDistanceM: Double? = nil,
                               racePace: Double? = nil, specificIndex: Int = -1,
                               thresholdSPerKm: Double? = nil,
                               riegelExponent: Double = DanielsPaces.populationRiegelExponent)
        -> (type: RunType, intervals: String?, paceOverride: Double?, note: String?) {
        let threshold = pace(.tempo, p5k: p5k, threshold: thresholdSPerKm)
        let goalRace = racePace ?? DanielsPaces.racePaceSPerKm(distanceM: raceDistanceM ?? 5_000, p5kSPerKm: p5k,
                                                               riegelExponent: riegelExponent)
        let avoidImpact = !injuryAreas.isDisjoint(with: impactSensitiveAreas)
        let avoidSpeed = !injuryAreas.isDisjoint(with: speedSensitiveAreas)
        let impactNote = "A steady run instead of repeats today — building carefully around your injury history."
        let speedNote = "Comfortably hard repeats instead of fast ones — protecting where you've been hurt before."

        // Progressive overload within the block: rep counts climb with the calendar, capped at a
        // sane ceiling. Interval strings drive the guided-run builder, so growth flows through.
        // Threshold dose scales with the ATHLETE, not just the calendar (Daniels: T volume per
        // session tops out near ~10% of weekly mileage). A 40 km/wk runner cruises 4×1km; a
        // 120 km/wk runner has earned 10–12. The calendar still gates the ramp inside the ceiling.
        //
        // The floor is THREE, not six (2026-08-30 coach audit). A floor of six handed a 26 km/wk
        // runner six kilometres of threshold — 23% of their week in one session, more than twice
        // Daniels' budget — because a fixed floor is a fixed workout wearing a percentage. The
        // progression it was there to protect survives without it: the ceiling itself climbs as
        // the plan's mileage climbs, so the session grows when the athlete does, which is the
        // order a coach grows things in.
        let tCeil = weeklyVolumeM.map { max(3, min(12, Int((($0 * 0.10) / 1000).rounded()))) } ?? 5
        let rKm = min(tCeil, 3 + weekIndex / 3)
        // Race bands: a 10K is NOT a long 5K — it's threshold-centric with VO₂ touches (Daniels),
        // where 5K training leans on speed and half/marathon+ on threshold + race-pace volume.
        // The old ≤12 km "short" boundary trained 10K runners on 400s at 5K pace all build.
        let raceM = raceDistanceM ?? 5_000
        let shortRace = raceM <= 8_000
        let midRace = raceM > 8_000 && raceM <= 15_000

        // THE PLAN'S VOCABULARY (owner call 2026-08-28). A plan is a simple thing to follow:
        // easy runs, a long run, a steady run, and — once the athlete has the base for it —
        // repeats. No fartleks, no hill reps, no strides, no track jargon; those live in the
        // WORKOUT LIBRARY for athletes who go looking for them. Every prescription here is a
        // round number with a pace beside it, and the words say what it should feel like.
        //
        // Two kinds of hard, both plain:
        //  • STEADY — one continuous stretch at "comfortably hard" (threshold). The single best
        //    session for a runner who wants to get faster without a track (Daniels' T pace).
        //  • REPEATS — clean, round reps with an easy jog between (time reps early, distance
        //    reps once there's volume to carry them).
        var menu: [(RunType, String?, Double?, String?)]
        // Repeat doses grow with the block: 3 → 8 reps of 3 minutes — and, like the threshold
        // dose above, they are bounded by the athlete's own mileage. Three minutes at interval
        // pace is the hardest running the plan contains; Daniels budgets it at ~8% of the week,
        // and eight of them is an elite's session, not a 26 km/week runner's (2026-08-30 audit,
        // which found the same eight reps handed to a 26 km and a 130 km athlete).
        let repM = 180 / max(1, pace(.intervals, p5k: p5k)) * 1000
        let iCeil = weeklyVolumeM.map { max(3, min(8, Int(($0 * 0.08) / repM))) } ?? 5
        let timeReps = min(iCeil, 4 + weekIndex / 3)
        let steadyNote = "Steady run — comfortably hard, the pace you could hold for about an hour. This is what lifts your everyday pace."
        let repeatNote = "Repeats — a little faster than steady, with an easy jog between. Short doses of quick running teach your legs to hold pace."
        let goalNote = "Repeats at your goal race pace, with an easy jog between. Practice the pace and it stops feeling fast."
        if level == .new {
            // Beginners get ONE kind of hard: a steady run, every time. Consistency first;
            // repeats arrive when the base is there. But they still meet race pace before race
            // day — in the closing weeks the steady run simply runs AT it, so the pace they have
            // to hold is not novel on the start line (2026-08-29 coach audit: a beginner's plan
            // reached the start line having never run the pace).
            menu = (phase == .taper || phase == .peak) && racePace != nil
                ? [(.tempo, nil, goalRace,
                    "Steady run at your race pace. Short, and the point is the pace — run it now and it will feel familiar on the day.")]
                : [(.tempo, nil, nil, steadyNote)]
        } else {
            switch phase {
            case .base:
                // Base is aerobic: steady runs only, growing in length. Nothing fast while the
                // foundation is laid (Lydiard/Seiler) — and nothing complicated to follow.
                menu = [(.tempo, nil, nil, steadyNote)]
            case .peak:
                menu = [(.intervals, "\(rKm)×1km @ threshold", threshold, repeatNote),
                        (.tempo, nil, nil, steadyNote)]
            case .taper:
                // Race week and the weeks before it: ONE short touch of race pace, every time.
                // Taper science cuts volume, never intensity — and never rotates into something new.
                menu = [(.intervals, shortRace ? "4×400m @ race pace" : "3×1km @ race pace", goalRace, goalNote)]
            default:   // .build (recovery weeks never request quality)
                // Build alternates the two plain hard days. Short races lean on quicker repeats,
                // longer races on comfortably-hard kilometre repeats — the same session grammar
                // either way, only the dose and the pace change.
                // Protection takes out the session that hurt them, and the fastest running in a
                // plan is also the highest-impact thing in it (2026-08-30 coach audit: the swap
                // was inverted — a shin, knee or achilles history lost the comfortably-hard
                // repeats and KEPT the three-minute reps at interval pace, which is the wrong one
                // of the two by a distance). Both families now replace the fast day; what they
                // replace it with differs. A hamstring or hip history gets the same session run
                // slower (threshold repeats), because its mechanism is maximal-speed running. An
                // impact history gets a continuous steady run — no repeated hard footstrikes at
                // all — because peak impact force scales with pace.
                let quick: (RunType, String?, Double?, String?) = avoidSpeed
                    ? (.intervals, "\(rKm)×1km @ threshold", threshold, speedNote)
                    : avoidImpact
                    ? (.tempo, nil, nil, impactNote)
                    : (.intervals, "\(timeReps)×3min", nil, repeatNote)
                let cruise: (RunType, String?, Double?, String?) =
                    (.intervals, "\(rKm)×1km @ threshold", threshold, repeatNote)
                menu = shortRace
                    ? [(.tempo, nil, nil, steadyNote), quick, (.tempo, nil, nil, steadyNote), cruise]
                    : [(.tempo, nil, nil, steadyNote), cruise, (.tempo, nil, nil, steadyNote), quick]
            }
        }
        // The race-specific block (2026-08-28): goal-pace work in the primary slot, its dose
        // growing week by week — reps at goal pace for 5K/10K (Daniels), goal-pace cruise blocks
        // for the half and marathon (Pfitzinger/Hansons). Every third week the primary slot goes
        // back to threshold so the T stimulus never lapses; the second quality day, when the
        // week has one, complements whatever sits here. Capped by the week's volume so a 45 km
        // week is never handed 16 km at marathon pace.
        if specificIndex >= 0, level != .new, phase == .build || phase == .peak,
           !(shortRace && avoidSpeed), specificIndex % 3 != 2 {
            // Every ladder opens on a rung a modest week can actually carry (2026-08-30). The
            // walk-down below can only step DOWN from where it starts, so a first rung of
            // 2×4 km meant a 30 km/week marathoner opened their race-specific block with eight
            // kilometres at goal pace whatever their mileage said — the cap had nothing left to
            // bite on. Starting small also reads as a coach writes it: the dose grows.
            let ladder: [String] = shortRace
                ? ["5×400m", "8×400m", "5×800m", "6×800m", "4×1km", "5×1km", "3×1km"]
                : midRace
                ? ["4×1km", "5×1km", "6×1km", "3×2km", "4×2km", "2×3km", "3×2km"]
                : raceM < 25_000
                ? ["2×2km", "2×3km", "2×4km", "3×3km", "2×5km", "3×4km", "2×6km", "2×5km", "3×3km"]
                : ["2×2km", "2×3km", "2×4km", "2×5km", "3×4km", "2×6km", "3×5km", "2×8km", "3×5km", "2×6km", "2×5km"]
            let share = shortRace ? 0.08 : midRace ? 0.10 : raceM < 25_000 ? 0.13 : 0.16
            // The floor is the SMALLEST rung on the ladder (2026-08-30): a 4 km floor sat above
            // the first two rungs of the short-race ladder, so the athlete's own mileage could
            // never bind on the sessions where it matters most — 5 km of 5K-pace repeats is a
            // race for a 26 km/week runner, not a workout.
            let capM = max(3_200, (weeklyVolumeM ?? 40_000) * share)
            var i = min(specificIndex, ladder.count - 1)
            while i > 0, goalPaceDoseM(ladder[i]) > capM { i -= 1 }
            return (.intervals, "\(ladder[i]) @ race pace", goalRace,
                    "Goal-pace work. Each specific week carries a little more of the race's own pace, so race day feels rehearsed.")
        }
        let pick = menu[((weekIndex % menu.count) + menu.count) % menu.count]
        // Continuous tempo caps at ~25 min at threshold (Daniels; Pfitzinger tops out similarly) —
        // a bigger allocation becomes cruise intervals, the same T dose in absorbable pieces. At
        // 80 km/wk the old allocation prescribed 40+ continuous minutes at T, which nobody runs.
        // …except for beginners (whose whole session is "run 20 minutes comfortably hard") and
        // except in BASE, where the steady run stays one continuous piece and is simply capped at
        // the same 25 minutes (`tempoCapM`) — a base week should read as plainly as it trains.
        if pick.0 == .tempo, level != .new, phase != .base, let qDist = qualityDistanceM {
            if qDist > tempoCapM(p5k: p5k, weeklyM: weeklyVolumeM, weekIndex: weekIndex, thresholdSPerKm: thresholdSPerKm) {
                return (.intervals, "\(rKm)×1km @ threshold", threshold, pick.3)
            }
        }
        return (pick.0, pick.1, pick.2, pick.3)
    }

    /// The longest CONTINUOUS steady run we prescribe: ~25 minutes at threshold plus a warm-up
    /// and cool-down carve (Daniels caps continuous T there; Pfitzinger tops out similarly).
    /// Beyond it the same dose is better taken as repeats — or, in base, simply capped.
    static func tempoCapM(p5k: Double, weeklyM: Double? = nil, weekIndex: Int = 0,
                          thresholdSPerKm: Double? = nil) -> Double {
        let carve = 2_000.0                                   // warm-up + cool-down inside the session
        // …and it GROWS into that ceiling: 18 minutes at threshold in week one, 25 by week six
        // (2026-08-30). Pinned at the ceiling from the first week, a base block read 7.5 km of
        // threshold every Tuesday for five weeks — the volume around it progressed and the
        // session the athlete feels never did.
        let seconds = min(1_500.0, 1_080.0 + Double(max(0, weekIndex)) * 84)
        let byTime = (seconds / pace(.tempo, p5k: p5k, threshold: thresholdSPerKm)) * 1000 + carve
        // …and by the WEEK (2026-08-29 coach audit). Daniels caps threshold volume near 10% of
        // weekly mileage. Time alone let a two-day beginner's steady run carry 38% of their week
        // at quality pace — the session was a sane length, the week was not. 12% leaves room for
        // clean-distance rounding without letting one session become the training week.
        guard let weeklyM, weeklyM > 0 else { return byTime }
        return min(byTime, weeklyM * 0.12 + carve)
    }

    /// The longest hard session a NEW runner is given. Their prescription runs at ONE pace for
    /// its whole length — there is no warm-up carve hidden inside it — so the number IS the dose:
    /// about twenty minutes at threshold, or a shorter rehearsal when the pace is race pace.
    /// Never more than 40% of the race itself: a beginner's peak week used to carry a 4 km run at
    /// 5K race pace, which is a time trial with a friendly name (2026-08-30 coach audit).
    static func beginnerQualityCapM(p5k: Double, racePaceSPerKm: Double?, raceDistanceM: Double?,
                                    thresholdSPerKm: Double? = nil) -> Double {
        if let rp = racePaceSPerKm, rp > 0 {
            return max(1_500, min((900.0 / rp) * 1000, (raceDistanceM ?? 5_000) * 0.4))
        }
        return max(1_500, (1_200.0 / pace(.tempo, p5k: p5k, threshold: thresholdSPerKm)) * 1000)
    }

    /// Total meters in a "N×Dkm" / "N×Dm" dose string (0 if unparseable).
    static func goalPaceDoseM(_ dose: String) -> Double {
        guard let p = StructuredWorkoutBuilder.parseIntervals(dose) else { return 0 }
        return Double(p.reps) * p.distanceM
    }

    /// How far a repeat session actually covers: the reps, the jog between them, and the warm-up
    /// and cool-down that bracket them. nil when the prescription is not a repeat session.
    ///
    /// Before this (2026-08-30) a repeat session was sized from the week's quality ALLOCATION,
    /// which is a budget, not a workout. Two opposite absurdities came out of that: a two-run
    /// week at 70 km/week prescribed "6×1km @ threshold" as a 43 km session carrying threshold
    /// pace, and a lean week prescribed "6×1km" inside a 6.5 km session with no room to warm up.
    /// The session is the workout; the leftover budget belongs to the easy days.
    static func repeatSessionM(intervals: String?, repPaceSPerKm: Double, p5k: Double,
                               thresholdSPerKm: Double? = nil) -> Double? {
        guard let intervals, !intervals.lowercased().contains("time trial"),
              repPaceSPerKm > 0 else { return nil }
        let repDistanceM: Double
        let dose: Double
        if let d = StructuredWorkoutBuilder.parseIntervals(intervals) {
            repDistanceM = d.distanceM
            dose = Double(d.reps) * d.distanceM
        } else if let t = StructuredWorkoutBuilder.parseTimeReps(intervals) {
            repDistanceM = t.seconds / repPaceSPerKm * 1000
            dose = Double(t.reps) * repDistanceM
        } else {
            return nil
        }
        guard dose > 0 else { return nil }
        let easy = pace(.easy, p5k: p5k, threshold: thresholdSPerKm)
        let threshold = pace(.tempo, p5k: p5k, threshold: thresholdSPerKm)
        // How much jogging the reps need between them, as a fraction of the time spent running
        // them. Faster than threshold and the recovery is nearly one-for-one; comfortably-hard
        // cruise reps take a short float; the long goal-pace blocks of a marathon build barely
        // break at all.
        let jogFraction: Double = repPaceSPerKm < threshold * 0.97 ? 0.9
            : repDistanceM >= 2_000 ? 0.15 : 0.25
        let jogM = (dose / 1000 * repPaceSPerKm) * jogFraction / max(1, easy) * 1000
        return dose + jogM + 2_500      // ~15 min of warm-up and cool-down at easy pace
    }

    /// The weekly volume a plan starts from when the athlete never stated one — per DISCIPLINE,
    /// because the same number means different things on foot and on a bike. A runner's tiers are
    /// 14 / 26 / 42 km; a cyclist covers roughly three times the ground in the same hour, and a
    /// walker rather more than half of it (2026-08-30: a cyclist was handed a runner's mileage,
    /// which made three rides of twenty-five minutes read as a cycling week).
    static func defaultWeeklyVolumeM(discipline: Discipline, level: ExperienceLevel) -> Double {
        let runningKm: Double = switch level { case .new: 14; case .some: 26; case .experienced: 42 }
        let factor: Double = switch discipline {
        case .cycling: 3.0
        case .walking: 0.55
        case .running, .strength: 1.0
        }
        return runningKm * factor * 1_000
    }

    /// Typical steady moving pace (s/km) for a non-running cardio discipline — 25 km/h on a bike,
    /// 5 km/h on foot. Used for the time-on-feet and stated-session-length caps, which are about
    /// the CLOCK: three hours is three hours whichever sport fills it.
    static func cruisePaceSPerKm(_ discipline: Discipline) -> Double {
        switch discipline {
        case .cycling: 3_600 / 25
        case .walking: 3_600 / 5
        case .running, .strength: 3_600 / 10
        }
    }

    /// What a non-running cardio session says for itself. `runType` stays nil on a ride or a walk
    /// (the surfaces title those from the discipline), so without this the scheduler's fallback
    /// described every one of them as "Easy run — most of your week should feel like this".
    static func cardioRationale(_ type: RunType, _ discipline: Discipline) -> String {
        let long = type == .long || type == .progression
        switch discipline {
        case .cycling:
            return long
                ? "Your long ride — steady and conversational the whole way. This is the one that builds the engine."
                : "Easy ride — comfortable enough to talk through. Most of your week should feel like this."
        case .walking:
            return long
                ? "Your long walk — unhurried, and further than the others. Time on your feet is the point."
                : "Easy walk — a steady pace you could hold all day."
        case .running, .strength:
            return long ? "Long — steady and unhurried." : "Easy — most of your week should feel like this."
        }
    }

    /// The plateau wave for the long run (applied once weekly volume holds at its ceiling): full,
    /// step-back, near-full — so a months-long plateau reads 32-28-30-32 instead of 32 forever.
    /// Deload weeks still provide the big dips; this is the texture between them.
    static let longRunWave: [Double] = [1.0, 0.88, 0.95]

    /// The week's SECOND hard day — always the COMPLEMENT of the first, in the plan's plain
    /// vocabulary (2026-08-28): a steady-flavored first day earns repeats, repeats earn a steady
    /// run. Two different stimuli means the two hard days can never collapse into one workout.
    /// Injury histories never reach here (the second slot is gated off entirely for them).
    static func secondQualityWorkout(weekIndex: Int, p5k: Double, weeklyVolumeM: Double?,
                                     primary: (type: RunType, intervals: String?, paceOverride: Double?, note: String?),
                                     thresholdSPerKm: Double? = nil)
        -> (type: RunType, intervals: String?, paceOverride: Double?, note: String?) {
        let threshold = pace(.tempo, p5k: p5k, threshold: thresholdSPerKm)
        // Both doses are the athlete's own, on the same budgets the primary slot works to
        // (Daniels: T ≈ 10% of the week, I ≈ 8%). The second hard day is only ever reached at
        // 40 km+ a week, but "only reached at real volume" is not the same as "sized for it".
        let tCeil = weeklyVolumeM.map { max(3, min(12, Int((($0 * 0.10) / 1000).rounded()))) } ?? 5
        let rKm = min(tCeil, 3 + weekIndex / 3)
        let repM = 180 / max(1, pace(.intervals, p5k: p5k)) * 1000
        let iCeil = weeklyVolumeM.map { max(3, min(6, Int(($0 * 0.08) / repM))) } ?? 4
        let reps = min(iCeil, 4 + weekIndex / 4)
        let primaryIsSteady = (primary.intervals?.lowercased().contains("threshold") ?? false)
            || primary.type == .tempo
        return primaryIsSteady
            ? (.intervals, "\(reps)×3min", nil,
               "Your second hard day — short repeats beside the steady work. Your mileage has earned both.")
            : (.intervals, "\(rKm)×1km @ threshold", threshold,
               "Your second hard day — comfortably hard repeats beside the faster ones. Your mileage has earned both.")
    }

    /// The peak weekly long-run distance a race builds toward (meters). Short races multiply up; long
    /// races run a fraction of race distance (you never run a full marathon in training). The long
    /// run also keeps pace with the WEEK (2026-08-28): at real volume it's ~28% of the week it sits
    /// in, so a 50 mpw 5K racer runs a 12-mile long run, not the 5-miler the race alone would ask.
    /// `weekVolumeM` is THIS week's running volume (not the plan's ceiling — a short runway that
    /// never reaches the ceiling must not carry ceiling-sized long runs).
    static func longRunPeak(forRaceM race: Double, podium: Bool = false, weekVolumeM: Double? = nil) -> Double {
        let byRace: Double = switch race {
        case ..<6_000:    race * 1.8          // 5K → ~9K long
        case ..<13_000:   race * 1.5          // 10K → ~15K long
        case ..<25_000:   min(podium ? 22_000 : 20_000, race * (podium ? 0.95 : 0.9))
        default:          min(podium ? 35_000 : 32_000, race * (podium ? 0.85 : 0.76))
        }
        let byWeek = (weekVolumeM ?? 0) * 0.28
        return min(podium ? 35_000 : 32_000, max(byRace, byWeek))
    }

    // MARK: Strength sessions (§9.2)

    static func strengthSessions(liftDays: Int, goal: Goal, level: ExperienceLevel, equipment: Equipment,
                                 sessionMinutes: Int, catalog: [ExerciseCatalogItem], isDeload: Bool,
                                 muscleFocus: Set<MuscleGroup> = [],
                                 split: StrengthSplitStyle = .coach, weekIndex: Int = 0,
                                 phase: PlanPhase = .build) -> [GeneratedSession] {
        guard liftDays > 0 else { return [] }
        let labels = splitLabels(liftDays: liftDays, split: split, weekIndex: weekIndex)
        let allowed = allowedEquipment(equipment)
        let exerciseCount = max(3, min(6, sessionMinutes / 10))

        return labels.map { label in
            var s = GeneratedSession(dayOffset: -1, discipline: .strength)
            s.strengthLabel = label
            s.isHardLowerLift = ["Lower", "Legs", "Full Body"].contains(label)
            var used = Set<String>()
            var compounds: [GeneratedExercise] = []
            var isolations: [GeneratedExercise] = []
            // Emphasized muscles in this day's slots come first so focus work survives the count
            // cap. A STABLE partition, not `sorted` — with no focus the old all-false comparator
            // let the sort shuffle the designed slot order, which is how a compound could land
            // after an isolation move (trainer audit, 2026-08-20).
            let raw = muscleSlots(for: label)
            let slots = muscleFocus.isEmpty ? raw
                : raw.filter { muscleFocus.contains($0.muscle) } + raw.filter { !muscleFocus.contains($0.muscle) }
            for slot in slots.prefix(exerciseCount) {
                guard let pick = selectExercise(muscle: slot.muscle, preferCompound: slot.compound,
                                                allowed: allowed, catalog: catalog, used: used) else { continue }
                used.insert(pick.name)
                var ge = scheme(for: pick, goal: goal, level: level, isDeload: isDeload)
                // Base weeks accumulate: one set fewer than the build prescription, so the block
                // ramps 3→4 sets into the build phase the way a coach periodizes it — instead of
                // week 1 opening at the block's full volume (trainer audit, 2026-08-20).
                if phase == .base, !isDeload { ge.targetSets = max(2, ge.targetSets - 1) }
                // Earned extra volume on the muscles the athlete chose to grow.
                if muscleFocus.contains(slot.muscle), !isDeload { ge.targetSets = min(6, ge.targetSets + 1) }
                // The day reads heavy-first: every compound before any isolation, each in slot
                // order — the isolation-slot FALLBACK can legitimately pick a compound (no chest
                // isolation ships, so Push's 4th slot becomes Incline Press), and it belongs up
                // with the other presses, not after the pushdowns.
                if pick.category == .compound { compounds.append(ge) } else { isolations.append(ge) }
            }
            s.strengthTargets = compounds + isolations
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
        // Pull's 4th slot is core, not forearms (trainer audit 2026-08-20): grip comes free with
        // every row and pulldown, while a PPL week previously shipped ZERO trunk work — the one
        // thing a runner's strength block exists to build. Wrist curls stay library-only.
        case "Pull": return [(.back, true), (.back, false), (.biceps, false), (.core, false)]
        // Legs closes with core for the same reason — every split style now trains the trunk
        // somewhere each rotation, and any 2-day PPL week includes Pull or Legs (or both).
        case "Legs": return [(.quads, true), (.hamstrings, true), (.glutes, true), (.calves, false), (.core, false)]
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
        let avoidSet = Set(avoidDayOffsets)
        let spare = (0..<7).filter { !pool.contains($0) && !usedByLifts.contains($0) }
        var available = pool.filter { !usedByLifts.contains($0) }
        // Only widen past the athlete's own days when their days cannot hold the runs, and even
        // then take the days they did NOT ask to avoid first.
        if available.count < runs.count {
            available += spare.filter { !avoidSet.contains($0) }
            if available.count < runs.count { available += spare.filter { avoidSet.contains($0) } }
        }
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
            let welcome = candidates.filter { !avoidSet.contains($0) }
            if let day = (welcome.isEmpty ? candidates : welcome).max() {
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
                // The session's own plain description comes first (every hard day carries one as
                // of 2026-08-28), then the placement sentence: what it is, then why it's today.
                if let rt = runs[i].runType,
                   let seq = HybridSequencing.runRationale(dayIndex: day, runType: rt, legDays: lowerDays) {
                    runs[i].rationale = runs[i].rationale.map { "\($0) \(seq)" } ?? seq
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
        // A ride or a walk never borrows a runner's sentence — `runType` is nil on those, and the
        // `default` below used to describe every one of them as an easy run (2026-08-30).
        guard s.discipline == .running else {
            return cardioRationale(s.runType ?? .easy, s.discipline)
        }
        switch s.runType {
        case .long: return "Long run — steady and unhurried. This is the run that builds your endurance."
        case .progression: return "Start easy and finish a little quicker. Teaches you to hold pace when your legs are tired."
        case .tempo: return "Steady run — comfortably hard, the pace you could hold for about an hour."
        case .intervals: return "Repeats with an easy jog between. Short doses of quicker running."
        case .fartlek: return "Easy run with a few quicker stretches whenever you feel like it."
        case .hills: return "Hill repeats — strength and power, easy on the joints."
        case .strides: return "A few short, relaxed pick-ups to wake your legs up."
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
struct PlanInputs: Equatable, Sendable {
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
    /// Target race finish time (s) — sets a floor under the plan's peak volume (a goal is a load,
    /// not a wish: `PlanFeasibility.goalRequiredWeeklyM`). nil → the tier's peak alone.
    var goalFinishTimeS: Double? = nil
    /// The most the athlete is willing to run per week (meters) — caps the peak. nil → the coach
    /// builds to what the goal needs.
    var targetWeeklyVolumeM: Double? = nil
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
    /// Past injury areas from onboarding — a conservative history modifier that caps the ramp at
    /// balanced and steers quality selection away from previously aggravating stimulus. It does not
    /// diagnose current capacity or guarantee that a session will be symptom-free.
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
