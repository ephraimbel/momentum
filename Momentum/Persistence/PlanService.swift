import Foundation
import SwiftData

/// Bridges the pure `PlanEngine` to SwiftData: builds the catalog snapshot, runs generation, and
/// persists the result into `TrainingPlan`/`PlannedSession`/`PlannedExercise` (PRD §9, §8.7).
@MainActor
enum PlanService {

    /// Regenerate and persist the plan for a profile, replacing any existing one.
    @discardableResult
    static func regenerate(for profile: UserProfile,
                           calibration: CalibrationSeed = .none,
                           startDate: Date = Date(),
                           blockIndex: Int = 0,
                           recoveryWeeks: Int = 0,
                           in context: ModelContext) -> TrainingPlan {
        let catalogItems = catalog(in: context)
        var inputs = planInputs(from: profile, startDate: startDate)
        inputs.postRaceRecoveryWeeks = recoveryWeeks
        let generated = PlanEngine.generate(profile: inputs, catalog: catalogItems,
                                            calibration: calibration, startDate: startDate)
        return persist(generated, for: profile, startDate: startDate, blockIndex: blockIndex, in: context)
    }

    /// Add tracked cross-training the engine doesn't program (swim/row/yoga…) as one recurring
    /// session per activity per week, on a day the structured plan didn't already use. Capped at
    /// `totalDaysPerWeek` distinct workout days so the athlete's chosen day count is honored — extras
    /// that don't fit are dropped rather than adding days. Each carries its precise `sportType`.
    static func addCrossTraining(_ types: [WorkoutType], to plan: TrainingPlan, startDate: Date = Date(),
                                 in context: ModelContext, totalDaysPerWeek: Int = 7,
                                 calendar: Calendar = .current) {
        guard !types.isEmpty else { return }
        let anchor = calendar.startOfDay(for: startDate)
        func dayIndex(_ d: Date) -> Int {
            calendar.dateComponents([.day], from: anchor, to: calendar.startOfDay(for: d)).day ?? 0
        }
        let weekCount = (plan.sessions.map { dayIndex($0.date) / 7 }.max() ?? 3) + 1

        for w in 0..<weekCount {
            let weekRange = (w * 7)..<((w + 1) * 7)
            var used = Set(plan.sessions.compactMap { s -> Int? in
                let di = dayIndex(s.date); return weekRange.contains(di) ? di % 7 : nil
            })
            for type in types {
                guard used.count < totalDaysPerWeek else { break }   // honor the chosen training-day count
                guard let off = (0..<7).first(where: { !used.contains($0) }) else { break }
                used.insert(off)
                let s = PlannedSession()
                s.date = calendar.date(byAdding: .day, value: w * 7 + off, to: anchor) ?? anchor
                s.sportType = type.rawValue
                s.discipline = type.discipline
                s.targetDurationS = 1800   // a 30-min default the athlete can adjust
                s.status = .planned
                s.rationale = "Cross-training — your call."
                plan.sessions.append(s)
                context.insert(s)
            }
        }
        try? context.save()
    }

    /// Rebuild the whole plan from `profile` — the one path used by both onboarding and the
    /// "edit plan settings" sheet. Shares the day budget between structured work and tracked add-ons
    /// (total distinct days ≤ daysPerWeek), preserves the calibrated 5k pace unless a fresh calibration
    /// is supplied, and re-adds the athlete's cross-training. Starts the plan from `startDate`.
    static func rebuild(for profile: UserProfile, calibration: CalibrationSeed? = nil,
                        startDate: Date = Date(), blockIndex: Int = 0, recoveryWeeks: Int = 0,
                        in context: ModelContext) {
        // A running goal implies you run: if the athlete switched to a race/endurance focus (via the
        // coach or plan settings) without running among their disciplines, add it — otherwise the
        // engine would build a race plan with no runs. Guards every rebuild caller in one place.
        let runningGoal = profile.goal == .raceDistance || profile.goal == .endurance
        if runningGoal, !profile.disciplines.contains(Discipline.running.rawValue) {
            profile.disciplines = [Discipline.running.rawValue] + profile.disciplines
        }
        // Symmetric guard: a strength goal implies you lift — a runner who tells the coach "get
        // stronger" must get strength sessions, not a run-only plan pointed at a barbell.
        let strengthGoal = profile.goal == .getStronger || profile.goal == .buildMuscle
        if strengthGoal, !profile.disciplines.contains(Discipline.strength.rawValue) {
            profile.disciplines += [Discipline.strength.rawValue]
        }
        let extras = profile.crossTraining.compactMap(WorkoutType.init(rawValue:))
        let disciplines = profile.disciplines.compactMap(Discipline.init(rawValue:))
        let userDays = profile.daysPerWeek
        let structuredDays = max(1, min(userDays, max(disciplines.count, userDays - extras.count)))
        // Preserve the existing calibrated pace across a rebuild unless a new calibration is given.
        let seed = calibration ?? (profile.plan.map { CalibrationSeed(estimatedP5kSPerKm: $0.p5kSPerKm) } ?? .none)

        profile.daysPerWeek = structuredDays
        regenerate(for: profile, calibration: seed, startDate: startDate, blockIndex: blockIndex,
                   recoveryWeeks: recoveryWeeks, in: context)
        profile.daysPerWeek = userDays   // restore the athlete's actual choice (plan + display)
        if let plan = profile.plan, !extras.isEmpty {
            addCrossTraining(extras, to: plan, startDate: startDate, in: context, totalDaysPerWeek: userDays)
        }
    }

    /// The post-race continuation (the coaching arc's close): once race day has passed, the season
    /// rolls into what comes next instead of dead-ending —
    ///  1. **The race result recalibrates the athlete.** A finished race is the gold-standard
    ///     fitness measurement: its Riegel-equivalent 5k replaces the plan's assumed pace when it's
    ///     faster (a rough day never slows the targets — no-shame, evidence-only).
    ///  2. **A recovery block opens the next plan.** The weeks after a goal race are running's
    ///     highest re-injury window, so the fresh rolling block leads with a distance-scaled
    ///     reverse taper (5K/half ≈ 1 easy week, marathon 2, ultra 3) before training resumes.
    ///     A race that was never run skips the recovery lead-in — there's nothing to recover from.
    ///  3. **The goal resets.** The dated race clears (its name too); the athlete picks the next
    ///     one whenever they're ready, and the plan keeps rolling block-to-block until then.
    /// Runs the day AFTER the race, not race evening — the finish line belongs to the athlete.
    /// Idempotent: the transition clears `raceDate`, so a second call is a no-op. Returns the
    /// coaching headline when a transition happened.
    @discardableResult
    static func completeRace(for profile: UserProfile, today: Date = Date(),
                             in context: ModelContext, calendar: Calendar = .current) -> String? {
        guard let plan = profile.plan, let raceDate = profile.raceDate ?? plan.raceDate else { return nil }
        guard let dayAfter = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: raceDate)),
              calendar.startOfDay(for: today) >= calendar.startOfDay(for: dayAfter) else { return nil }

        // 1) Recalibrate from the result, when the race was actually run and logged.
        let raceM = profile.raceDistanceM
        let raceWorkout = plan.sessions.first { $0.runType == .race }?.completedWorkout
        var seedP5k = plan.p5kSPerKm
        var raced = false
        if let w = raceWorkout, w.durationS > 60, let raceM, raceM > 0 {
            raced = true
            let equivalent = PlanEngine.riegelP5k(distanceM: raceM, timeS: w.durationS)
            if equivalent < seedP5k, equivalent >= 150 {
                let delta = Int((seedP5k - equivalent).rounded())
                seedP5k = equivalent
                CoachingEvent.record(kind: .recalibrate, headline: "Your race reset your paces",
                                     detail: "That finish line is the truest fitness test there is — your training paces just got about \(max(1, delta)) s/km faster. You ran your way there.",
                                     on: today, in: context, calendar: calendar)
            }
        }

        // 2 + 3) Clear the finished goal and roll into the next block, recovery lead-in first.
        let recovery = raced ? PlanEngine.postRaceRecoveryWeeks(forRaceM: raceM ?? 5_000) : 0
        profile.raceDate = nil
        profile.raceDistanceM = nil
        profile.goalFinishTimeS = nil
        rebuild(for: profile, calibration: CalibrationSeed(estimatedP5kSPerKm: seedP5k),
                startDate: today, blockIndex: plan.blockIndex + 1, recoveryWeeks: recovery, in: context)
        profile.plan?.name = ""   // the season was named for the race that's now behind them

        let headline = raced ? "Race done — recovery block first" : "Race week's behind you"
        let detail = raced
            ? "You did the thing. The next \(recovery) week\(recovery == 1 ? "" : "s") stay deliberately easy — the fitness you built gets locked in by the recovery, not the next hard run. Then we roll."
            : "Your plan rolled into a fresh block. Whenever the next start line calls, set it and the season builds toward it."
        CoachingEvent.record(kind: .recover, headline: headline, detail: detail,
                             on: today, in: context, calendar: calendar)
        try? context.save()
        return headline
    }

    /// Roll an open-ended plan into its next block — the "we'll see where you're at" moment.
    /// Reassesses the athlete's ACTUAL recent running (trailing 4 weeks of logged runs) so the new
    /// block honestly starts where they now are — a strong block steps up, a rough one holds, and the
    /// ACWR governor still caps week-over-week — then regenerates one fresh mesocycle from today and
    /// advances the block counter. No-op for dated-race plans: they periodize continuously to race day
    /// and are never "renewed." Returns the new plan, or nil when there's nothing to renew.
    @discardableResult
    static func renewBlock(for profile: UserProfile, startDate: Date = Date(),
                           in context: ModelContext, calendar: Calendar = .current) -> TrainingPlan? {
        guard let plan = profile.plan, plan.raceDate == nil else { return nil }
        let nextIndex = plan.blockIndex + 1
        // Reassess: what did they actually run over the last 4 weeks? That achieved volume seeds the
        // next block so progression is earned, never assumed. Only overwrite when there's real signal
        // — otherwise keep their declared/prior figure so a quiet month doesn't zero the plan out.
        if let achieved = recentWeeklyRunVolumeM(endingAt: startDate, weeks: 4, in: context, calendar: calendar) {
            profile.weeklyRunVolumeM = achieved
        }
        let seed = CalibrationSeed(estimatedP5kSPerKm: plan.p5kSPerKm)
        rebuild(for: profile, calibration: seed, startDate: startDate, blockIndex: nextIndex, in: context)
        return profile.plan
    }

    /// The athlete's real running volume per week over the trailing `weeks`, in meters — the average
    /// of logged run/trail-run distance. `nil` when there's not enough logged to be meaningful (no
    /// GPS distance at all), so callers can fall back to the declared figure rather than trust a zero.
    static func recentWeeklyRunVolumeM(endingAt end: Date = Date(), weeks: Int = 4,
                                       in context: ModelContext, calendar: Calendar = .current) -> Double? {
        guard let since = calendar.date(byAdding: .day, value: -7 * weeks, to: end) else { return nil }
        let recent = ((try? context.fetch(FetchDescriptor<Workout>())) ?? []).filter {
            $0.type.discipline == .running && $0.startedAt >= since && $0.startedAt <= end
        }
        let total = recent.compactMap { $0.gps?.distanceM }.reduce(0, +)
        guard total > 0 else { return nil }
        return total / Double(weeks)
    }

    /// Snapshot the exercise library for the engine.
    ///
    /// Sorted by name. The fetch is unordered, and `selectExercise` picks the FIRST acceptable
    /// candidate — so with two equally-valid choices for a muscle slot, which one the athlete got
    /// depended on SwiftData's row order. A deterministic plan engine (the whole point of §9) can't
    /// rest on that: the same profile must generate the same plan on every device, every install.
    static func catalog(in context: ModelContext) -> [ExerciseCatalogItem] {
        let all = ((try? context.fetch(FetchDescriptor<Exercise>())) ?? [])
            .sorted { $0.name < $1.name }
        return all.map { ex in
            ExerciseCatalogItem(
                name: ex.name,
                primaryMuscles: ex.primaryMuscles.compactMap(MuscleGroup.init(rawValue:)),
                secondaryMuscles: ex.secondaryMuscles.compactMap(MuscleGroup.init(rawValue:)),
                equipment: ex.equipment, category: ex.category, defaultRestS: ex.defaultRestS,
                trackingMode: ex.trackingMode)
        }
    }

    static func planInputs(from p: UserProfile, startDate: Date = Date(),
                           calendar: Calendar = .current) -> PlanInputs {
        let disciplines = p.disciplines.compactMap(Discipline.init(rawValue:))
        func level(_ key: String) -> ExperienceLevel {
            ExperienceLevel(rawValue: p.experience[key] ?? "") ?? .some
        }
        // Map preferred weekdays (1 = Sun … 7 = Sat) to in-week offsets from the plan's start day.
        let anchorWeekday = calendar.component(.weekday, from: calendar.startOfDay(for: startDate))
        let offsets = p.preferredDays.map { ((($0 - anchorWeekday) % 7) + 7) % 7 }
        return PlanInputs(
            disciplines: disciplines.isEmpty ? [.running] : disciplines,
            goal: p.goal, daysPerWeek: p.daysPerWeek, equipment: p.equipment,
            sessionMinutes: p.sessionMinutes, raceDate: p.raceDate,
            runningExperience: level(Discipline.running.rawValue),
            liftingExperience: level(Discipline.strength.rawValue),
            raceDistanceM: p.raceDistanceM,
            currentWeeklyVolumeM: p.weeklyRunVolumeM, longestRunM: p.longestRunM,
            hybridPriority: p.hybridPriority.flatMap(HybridPriority.init(rawValue:)),
            muscleFocus: p.muscleFocus.compactMap(MuscleGroup.init(rawValue:)),
            preferredDayOffsets: offsets,
            intensity: PlanIntensity(rawValue: p.planIntensity ?? "") ?? .balanced,
            injuryHistory: p.injuryHistory.compactMap(InjuryArea.init(rawValue:)),
            age: p.birthYear.map { max(0, calendar.component(.year, from: startDate) - $0) },
            distanceUnit: (DistanceUnit(rawValue: p.distanceUnit) ?? .auto).resolved())
    }

    static func persist(_ plan: GeneratedPlan, for profile: UserProfile,
                        startDate: Date, blockIndex: Int = 0, in context: ModelContext,
                        calendar: Calendar = .current) -> TrainingPlan {
        // Replace any existing plan — but the athlete's name for it survives the rebuild.
        let carriedName = profile.plan?.name ?? ""
        // Finished work survives too: completed sessions from the CURRENT calendar week detach from
        // the old plan before its cascade delete and re-attach to the new block — rebuilding on a
        // Thursday must not turn Monday's finished run into a "Rest day". A completed RACE carries
        // however far back it sits: it's the event the whole block was built for, and `completeRace`
        // rebuilds the day AFTER race day — so a Saturday race read on Monday is already "last week"
        // and would otherwise be erased from the board at the emotional peak of the season.
        // Carried history can therefore predate the block, which is why `blockStart` (not the earliest
        // session) anchors phase indexing and "Week N of M". The workouts themselves are never touched.
        var carriedDone: [PlannedSession] = []
        if let existing = profile.plan {
            if let weekStart = calendar.dateInterval(of: .weekOfYear, for: startDate)?.start {
                // The race exemption is bounded to the recent past. Unbounded, every rebuild re-carried
                // every race the athlete had ever run, so a multi-season history accumulated on the
                // plan forever — and one old enough could push the block past the Plan strip's
                // 64-week span entirely. Eight weeks covers the post-race rebuild (which runs the day
                // after) with room for an athlete who doesn't open the app for a while.
                let raceFloor = calendar.date(byAdding: .weekOfYear, value: -8, to: startDate) ?? weekStart
                carriedDone = existing.sessions.filter {
                    $0.status == .completed && $0.date <= startDate
                        && ($0.date >= weekStart || ($0.runType == .race && $0.date >= raceFloor))
                }
                let carriedIDs = Set(carriedDone.map(\.id))
                existing.sessions.removeAll { carriedIDs.contains($0.id) }   // detach from the cascade
                // Materialize the detach BEFORE the delete: cascade walks the last-SAVED relationship
                // snapshot, so deleting in the same transaction would still take the carried sessions.
                if !carriedDone.isEmpty { try? context.save() }
            }
            context.delete(existing)
            profile.plan = nil
        }

        let exercisesByName = Dictionary(
            ((try? context.fetch(FetchDescriptor<Exercise>())) ?? []).map { ($0.name, $0) },
            uniquingKeysWith: { a, _ in a })

        let trainingPlan = TrainingPlan()
        trainingPlan.name = carriedName
        trainingPlan.blockIndex = blockIndex
        trainingPlan.goal = profile.goal
        trainingPlan.disciplines = profile.disciplines
        trainingPlan.raceDate = profile.raceDate
        trainingPlan.p5kSPerKm = plan.p5kSPerKm
        // Persist the macrocycle (§6.1) exactly as the generator periodized it — base → build →
        // peak → taper, with deloads as recovery. One source of truth: `GeneratedWeek.phase`.
        trainingPlan.weekPhases = plan.weeks.map(\.phase.rawValue)

        let anchor = calendar.startOfDay(for: startDate)
        trainingPlan.blockStart = anchor   // the block's own day zero — see `TrainingPlan.blockStart`
        var sessions: [PlannedSession] = []
        for week in plan.weeks {
            for gen in week.sessions {
                let ps = PlannedSession()
                ps.date = calendar.date(byAdding: .day, value: week.index * 7 + gen.dayOffset, to: anchor) ?? anchor
                ps.discipline = gen.discipline
                ps.runType = gen.runType
                ps.targetDistanceM = gen.targetDistanceM
                ps.targetDurationS = gen.targetDurationS
                ps.targetPaceSPerKm = gen.targetPaceSPerKm
                ps.intervals = gen.intervals
                ps.rationale = gen.rationale
                ps.strengthTargets = gen.strengthTargets.enumerated().map { idx, ge in
                    let pe = PlannedExercise()
                    pe.order = idx
                    pe.exercise = exercisesByName[ge.exerciseName]
                    pe.targetSets = ge.targetSets
                    pe.targetRepLow = ge.repLow
                    pe.targetRepHigh = ge.repHigh
                    pe.targetRPE = ge.targetRPE
                    pe.targetPctRM = ge.targetPctRM
                    pe.progression = ge.progression
                    return pe
                }
                sessions.append(ps)
            }
        }
        trainingPlan.sessions = sessions + carriedDone   // the new block + this week's finished work
        context.insert(trainingPlan)
        profile.plan = trainingPlan
        try? context.save()
        return trainingPlan
    }
}
