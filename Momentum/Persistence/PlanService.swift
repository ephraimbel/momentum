import Foundation
import SwiftData

struct PlanFitnessSnapshot: Equatable, Sendable {
    let weeklyM: Double?
    let longestM: Double?
    let usesLoggedRuns: Bool
}

struct PlanRunEvidence: Sendable {
    let startedAt: Date
    let distanceM: Double
}

enum PlanFitnessEvidence {
    static let historyDays = 56
    static let establishedFallbackWeeklyM = 8_000.0

    private static func usableDistance(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    static func recentWeeklyRunVolumeM(_ runs: [PlanRunEvidence],
                                       endingAt end: Date,
                                       weeks: Int,
                                       calendar: Calendar) -> Double? {
        guard weeks > 0,
              let since = calendar.date(byAdding: .day, value: -7 * weeks, to: end) else { return nil }
        var buckets = [Double](repeating: 0, count: weeks)
        for run in runs where run.startedAt >= since && run.startedAt <= end
            && run.distanceM.isFinite && run.distanceM > 0 {
            let daysBack = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: run.startedAt),
                to: calendar.startOfDay(for: end)
            ).day ?? 0
            let index = min(weeks - 1, max(0, daysBack / 7))
            buckets[index] += run.distanceM
        }
        let active = buckets.filter { $0 > 0 }
        guard active.count >= 2 else { return nil }
        let kept = weeks > 2 ? Array(buckets.sorted().dropFirst()) : buckets
        guard !kept.isEmpty else { return nil }
        return kept.reduce(0, +) / Double(kept.count)
    }

    /// Onboarding declarations are useful while they are fresh. After eight weeks, recent Momentum
    /// runs replace them instead of being maxed against a months-old peak forever. Sparse history
    /// deliberately returns a conservative starting week; downstream progression can build from
    /// evidence, while an inactive returning athlete cannot accidentally restart at 70 km/week.
    static func snapshot(runs: [PlanRunEvidence],
                         declaredWeeklyM: Double?,
                         declaredLongestM: Double?,
                         profileCreatedAt: Date,
                         endingAt end: Date,
                         calendar: Calendar) -> PlanFitnessSnapshot {
        let cutoff = calendar.date(byAdding: .day, value: -historyDays, to: end) ?? .distantPast
        let recent = runs.filter {
            $0.startedAt >= cutoff && $0.startedAt <= end
                && $0.distanceM.isFinite && $0.distanceM > 0
        }
        let declaredWeeklyM = usableDistance(declaredWeeklyM)
        let declaredLongestM = usableDistance(declaredLongestM)
        let observedWeekly = recentWeeklyRunVolumeM(
            recent,
            endingAt: end,
            weeks: 4,
            calendar: calendar
        )
        let observedLongest = recent.map(\.distanceM).max()
        let declarationsAreFresh = profileCreatedAt >= cutoff

        let weekly: Double?
        if let observedWeekly {
            weekly = observedWeekly
        } else if declarationsAreFresh {
            weekly = declaredWeeklyM
        } else {
            let sparseAverage = recent.reduce(0) { $0 + $1.distanceM } / 4
            let conservativeFallback = min(
                declaredWeeklyM ?? establishedFallbackWeeklyM,
                establishedFallbackWeeklyM
            )
            weekly = max(sparseAverage, conservativeFallback)
        }

        let longest: Double?
        if declarationsAreFresh {
            switch (observedLongest, declaredLongestM) {
            case let (observed?, declared?): longest = max(observed, declared)
            case let (observed?, nil): longest = observed
            case let (nil, declared): longest = declared
            }
        } else {
            longest = observedLongest
        }
        return PlanFitnessSnapshot(
            weeklyM: weekly,
            longestM: longest,
            usesLoggedRuns: observedWeekly != nil
        )
    }
}

/// Reads only the bounded evidence window on SwiftData's serial model executor. The Plan Settings
/// sheet awaits this value without faulting an athlete's entire workout history on the main actor.
@ModelActor
actor PlanFitnessWorker {
    func snapshot(declaredWeeklyM: Double?,
                  declaredLongestM: Double?,
                  profileCreatedAt: Date,
                  endingAt end: Date = Date(),
                  calendar: Calendar = .current) throws -> PlanFitnessSnapshot {
        let runs = try PlanService.runEvidence(endingAt: end, in: modelContext, calendar: calendar)
        return PlanFitnessEvidence.snapshot(
            runs: runs,
            declaredWeeklyM: declaredWeeklyM,
            declaredLongestM: declaredLongestM,
            profileCreatedAt: profileCreatedAt,
            endingAt: end,
            calendar: calendar
        )
    }
}

/// Bridges the pure `PlanEngine` to SwiftData: builds the catalog snapshot, runs generation, and
/// persists the result into `TrainingPlan`/`PlannedSession`/`PlannedExercise` (PRD §9, §8.7).
@MainActor
enum PlanService {

    enum ReplacementError: Error, Equatable {
        case ambiguousMetadata(UUID)
        case ambiguousSeason(UUID)
        case ambiguousIntent(UUID)
    }

    struct Hooks {
        var beforeSave: (() throws -> Void)?
        @MainActor static let none = Hooks()
    }

    /// Regenerate and persist the plan for a profile, replacing any existing one atomically.
    @discardableResult
    static func regenerate(for profile: UserProfile,
                           calibration: CalibrationSeed = .none,
                           startDate: Date = Date(),
                           blockIndex: Int = 0,
                           recoveryWeeks: Int = 0,
                           in context: ModelContext,
                           hooks: Hooks = .none) -> TrainingPlan? {
        transactReplacement(for: profile, in: context, hooks: hooks) {
            try stageRegenerate(
                for: profile,
                calibration: calibration,
                startDate: startDate,
                blockIndex: blockIndex,
                recoveryWeeks: recoveryWeeks,
                in: context
            )
        }
    }

    /// Mutation-only generation used by larger transactions such as Plan Settings. The caller must
    /// disable autosave, reconcile compatibility sidecars, and perform the sole final save.
    static func stageRegenerate(for profile: UserProfile,
                                calibration: CalibrationSeed = .none,
                                startDate: Date = Date(),
                                blockIndex: Int = 0,
                                recoveryWeeks: Int = 0,
                                tuneUps: [PlanRaceEvent]? = nil,
                                in context: ModelContext) throws -> TrainingPlan {
        let catalogItems = catalog(in: context)
        var inputs = planInputs(from: profile, startDate: startDate)
        // A rebuild is a new coaching decision, so it starts from what the athlete is doing now —
        // not the volume they typed during onboarding. `observedFitness` reads Momentum-logged runs
        // only (Health remains signals-only), then falls back conservatively when history is thin.
        let current = observedFitness(for: profile, on: startDate, in: context)
        inputs.currentWeeklyVolumeM = current.weeklyM
        inputs.longestRunM = current.longestM
        inputs.postRaceRecoveryWeeks = recoveryWeeks
        inputs.tuneUpRaces = tuneUps ?? tuneUpRaces(for: profile, in: context)
        // The athlete state (2026-09-03): threshold, personal fatigue curve and durability read
        // off the same eight weeks of Momentum-logged runs. Fills only what the caller's seed left
        // empty — an entered benchmark always outranks an estimate.
        let state = athleteState(for: profile, calibration: calibration, on: startDate, in: context)
        let seeded = AthleteStateEngine.seed(calibration, with: state)
        let generated = PlanEngine.generate(profile: inputs, catalog: catalogItems,
                                            calibration: seeded, startDate: startDate)
        let replacedPlanID = profile.plan?.id
        let plan = try stagePersist(
            generated,
            for: profile,
            startDate: startDate,
            blockIndex: blockIndex,
            in: context
        )
        stampAthleteState(state, generated: generated, on: plan, replacing: replacedPlanID,
                          at: startDate, in: context)
        return plan
    }

    /// Derive the athlete state from the evidence window — pure once the rows are read.
    static func athleteState(for profile: UserProfile, calibration: CalibrationSeed = .none,
                             on date: Date = Date(), in context: ModelContext,
                             calendar: Calendar = .current) -> RunningAthleteState {
        let rows = (try? runEvidenceRows(endingAt: date, in: context, calendar: calendar)) ?? []
        var stateProfile = AthleteStateProfile(maxHR: profile.maxHR, restingHR: profile.restingHR)
        if let run = calibration.recentRun {
            stateProfile.benchmarks.append(.init(distanceM: run.distanceM, timeS: run.timeS))
        }
        return AthleteStateEngine.derive(runs: rows, profile: stateProfile, asOf: date, calendar: calendar)
    }

    /// The compact snapshot the plan carries (`PlanAthleteStateRecord`): the reads the plan was
    /// built with, and where the threshold came from and how sure the read is. Insert only — the
    /// enclosing transaction owns the save. The replaced plan's record goes with the plan.
    static func stampAthleteState(_ state: RunningAthleteState, generated: GeneratedPlan,
                                  on plan: TrainingPlan, replacing replacedPlanID: UUID?,
                                  at date: Date, in context: ModelContext) {
        if let replacedPlanID, replacedPlanID != plan.id {
            PlanAthleteStateRecord.remove(planID: replacedPlanID, in: context)
        }
        let record = PlanAthleteStateRecord.upsert(planID: plan.id, in: context)
        record.computedAt = date
        record.thresholdSPerKm = generated.thresholdSPerKm
        record.riegelExponent = generated.riegelExponent
        record.durabilitySignal = generated.durability?.rawValue
        if let t = state.thresholdProxy, generated.thresholdSPerKm != nil {
            record.thresholdMethod = t.value.method.rawValue
            record.thresholdConfidence = t.confidence.rawValue
            record.thresholdObservedAt = t.observedAt
        } else if generated.thresholdSPerKm != nil {
            // An entered threshold (no derived read behind it) is the athlete's own word.
            record.thresholdMethod = RunningThresholdMethod.athleteEntry.rawValue
            record.thresholdConfidence = RunningEvidenceConfidence.moderate.rawValue
            record.thresholdObservedAt = date
        } else {
            record.thresholdMethod = nil
            record.thresholdConfidence = nil
            record.thresholdObservedAt = nil
        }
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
    }

    /// Rebuild the whole plan from `profile` — the one path used by both onboarding and the
    /// "edit plan settings" sheet. Shares the day budget between structured work and tracked add-ons
    /// (total distinct days ≤ daysPerWeek), preserves the calibrated 5k pace unless a fresh calibration
    /// is supplied, and re-adds the athlete's cross-training. Starts the plan from `startDate`.
    @discardableResult
    static func rebuild(for profile: UserProfile, calibration: CalibrationSeed? = nil,
                        startDate: Date = Date(), blockIndex: Int = 0, recoveryWeeks: Int = 0,
                        in context: ModelContext, hooks: Hooks = .none) -> TrainingPlan? {
        transactReplacement(for: profile, in: context, hooks: hooks) {
            try stageRebuild(
                for: profile,
                calibration: calibration,
                startDate: startDate,
                blockIndex: blockIndex,
                recoveryWeeks: recoveryWeeks,
                in: context
            )
        }
    }

    /// Mutation-only rebuild. This is deliberately throwing so a containing user action can roll
    /// back profile edits, plan replacement, and sidecars as one unit.
    static func stageRebuild(for profile: UserProfile, calibration: CalibrationSeed? = nil,
                             startDate: Date = Date(), blockIndex: Int = 0, recoveryWeeks: Int = 0,
                             tuneUps: [PlanRaceEvent]? = nil,
                             in context: ModelContext) throws -> TrainingPlan {
        // Every coached plan in Momentum is a RUNNING plan. Strength is programmed in support;
        // cycling/walking remain useful cross-training the athlete can track, but cannot silently
        // replace the running foundation because the selected outcome is not a race. Keeping the
        // invariant here protects onboarding, Plan Settings, Coach actions, and legacy profiles.
        let savedDisciplines = profile.disciplines.compactMap(Discipline.init(rawValue:))
        let supportingCardio = savedDisciplines.filter { $0 != .running && $0 != .strength }
        if !supportingCardio.isEmpty {
            var extras = Set(profile.crossTraining)
            supportingCardio.forEach { extras.insert(WorkoutType.forDiscipline($0).rawValue) }
            profile.crossTraining = extras.sorted()
        }
        profile.disciplines = [Discipline.running.rawValue]
        if savedDisciplines.contains(.strength) {
            profile.disciplines.append(Discipline.strength.rawValue)
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
        defer { profile.daysPerWeek = userDays }
        let plan = try stageRegenerate(
            for: profile,
            calibration: seed,
            startDate: startDate,
            blockIndex: blockIndex,
            recoveryWeeks: recoveryWeeks,
            tuneUps: tuneUps,
            in: context
        )
        profile.daysPerWeek = userDays   // restore before cross-training applies the full day budget
        if !extras.isEmpty {
            addCrossTraining(extras, to: plan, startDate: startDate, in: context, totalDaysPerWeek: userDays)
        }
        return plan
    }

    // MARK: The season's other races (2026-09-03)

    /// The athlete's active season record: the one pointing at the current plan, else the one
    /// marked active. Nil for a profile the backfill has not reached yet.
    static func activeSeason(for profile: UserProfile, in context: ModelContext) -> RunningSeasonRecord? {
        let seasons = ((try? context.fetch(FetchDescriptor<RunningSeasonRecord>())) ?? [])
            .filter { $0.profileID == profile.id }
        if let planID = profile.plan?.id, let exact = seasons.first(where: { $0.activePlanID == planID }) {
            return exact
        }
        return seasons.first { $0.statusRaw == RunningSeasonStatus.active.rawValue }
    }

    /// The season's planned tune-ups (B/C), soonest first — what the engine bends weeks around.
    static func tuneUpRaces(for profile: UserProfile, in context: ModelContext) -> [PlanRaceEvent] {
        guard let season = activeSeason(for: profile, in: context) else { return [] }
        let seasonID = season.id
        let events = (try? context.fetch(FetchDescriptor<RunningEventRecord>(
            predicate: #Predicate { $0.seasonID == seasonID }))) ?? []
        return events.compactMap { record -> PlanRaceEvent? in
            guard record.statusRaw == RunningEventStatus.planned.rawValue,
                  let priority = RunningEventPriority(rawValue: record.priorityRaw), priority != .a,
                  let distance = record.distanceM, distance > 0 else { return nil }
            return PlanRaceEvent(id: record.id, date: record.date, distanceM: distance,
                                 priority: priority, goalTimeS: record.durationS)
        }
        .sorted { $0.date < $1.date }
    }

    /// The day-after pass for every race on the season: tune-ups settle first (they never rebuild),
    /// then the goal race (which does). One call from Today, idempotent on both.
    @discardableResult
    static func settleRaces(for profile: UserProfile, today: Date = Date(),
                            in context: ModelContext, calendar: Calendar = .current) -> String? {
        var headline: String?
        for event in tuneUpRaces(for: profile, in: context) {
            if let line = completeTuneUp(event, for: profile, today: today, in: context, calendar: calendar) {
                headline = line
            }
        }
        return completeRace(for: profile, today: today, in: context, calendar: calendar) ?? headline
    }

    /// A tune-up the day after it was run: the event is marked completed, and a logged result
    /// sharpens the paces the way any race does. No rebuild and no goal change — the week already
    /// bent around it, and the block still points at the goal race.
    @discardableResult
    static func completeTuneUp(_ event: PlanRaceEvent, for profile: UserProfile, today: Date = Date(),
                               in context: ModelContext, calendar: Calendar = .current) -> String? {
        guard let dayAfter = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: event.date)),
              calendar.startOfDay(for: today) >= calendar.startOfDay(for: dayAfter) else { return nil }
        let eventID = event.id
        guard let record = (try? context.fetch(FetchDescriptor<RunningEventRecord>(
            predicate: #Predicate { $0.id == eventID })))?.first,
              record.statusRaw == RunningEventStatus.planned.rawValue else { return nil }
        record.statusRaw = RunningEventStatus.completed.rawValue
        let plan = profile.plan
        let raceSession = plan?.sessions.first {
            $0.runType == .race && calendar.isDate($0.date, inSameDayAs: event.date)
        }
        var detail = "Your tune-up is behind you. The block still points at the goal race; the next few days stay easy."
        if let workout = raceSession?.completedWorkout, let plan {
            let sharpened = PlanCoaching.recalibratePaces(from: workout, plan: plan, today: today,
                                                          in: context, calendar: calendar)
            let threshold = PlanCoaching.recalibrateThreshold(from: workout, plan: plan, today: today,
                                                              in: context, calendar: calendar)
            if sharpened != nil || threshold != nil {
                detail = "A race is the truest fitness test there is, so your paces sharpened from it. The block still points at the goal race."
            }
        }
        let headline = "Tune-up done"
        CoachingEvent.record(kind: .recover, headline: headline, detail: detail,
                             on: today, in: context, calendar: calendar)
        try? context.save()
        return headline
    }

    /// After the goal race, the next planned race on the season (A or B, soonest first) becomes
    /// the goal: the profile's race fields move to it and its record is promoted. Nil when the
    /// season holds nothing further, in which case the block rolls undated as it always did.
    private static func promoteNextRace(for profile: UserProfile, after raceDate: Date,
                                        in context: ModelContext, calendar: Calendar) -> RunningEventRecord? {
        guard let season = activeSeason(for: profile, in: context) else { return nil }
        let seasonID = season.id
        let events = (try? context.fetch(FetchDescriptor<RunningEventRecord>(
            predicate: #Predicate { $0.seasonID == seasonID }))) ?? []
        // The race just run is history now.
        for finished in events where finished.priorityRaw == RunningEventPriority.a.rawValue
            && finished.statusRaw == RunningEventStatus.planned.rawValue
            && calendar.startOfDay(for: finished.date) <= calendar.startOfDay(for: raceDate) {
            finished.statusRaw = RunningEventStatus.completed.rawValue
        }
        let next = events.filter {
            $0.statusRaw == RunningEventStatus.planned.rawValue
                && ($0.priorityRaw == RunningEventPriority.a.rawValue || $0.priorityRaw == RunningEventPriority.b.rawValue)
                && calendar.startOfDay(for: $0.date) > calendar.startOfDay(for: raceDate)
                && ($0.distanceM ?? 0) > 0
        }
        .sorted { $0.date < $1.date }
        guard let promoted = next.first else { return nil }
        promoted.priorityRaw = RunningEventPriority.a.rawValue
        // The season is the athlete's again, not the backfill's, from here on.
        season.backfillVersion = 0
        season.updatedAt = Date()
        profile.raceDate = promoted.date
        profile.raceDistanceM = promoted.distanceM
        profile.goalFinishTimeS = promoted.durationS
        return promoted
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

        // 2 + 3) Roll into the next block, recovery lead-in first. If the season holds another
        // race (2026-09-03, owner call), it becomes the goal and the block builds toward it after
        // the recovery; otherwise the finished goal clears and the block rolls undated.
        let recovery = raced ? PlanEngine.postRaceRecoveryWeeks(forRaceM: raceM ?? 5_000) : 0
        let promoted = promoteNextRace(for: profile, after: raceDate, in: context, calendar: calendar)
        if promoted == nil {
            profile.raceDate = nil
            profile.raceDistanceM = nil
            profile.goalFinishTimeS = nil
        }
        guard let replacement = rebuild(
            for: profile,
            calibration: CalibrationSeed(estimatedP5kSPerKm: seedP5k),
            startDate: today,
            blockIndex: plan.blockIndex + 1,
            recoveryWeeks: recovery,
            in: context
        ) else { return nil }
        // The season was named for the race that's now behind them; a promoted race brings its own.
        replacement.name = promoted?.name ?? ""

        let headline: String
        let detail: String
        if let promoted, let distance = promoted.distanceM {
            let label = RaceDistance.nearest(toMeters: distance).label
            let when = promoted.date.formatted(.dateTime.month(.abbreviated).day())
            headline = raced ? "Race done. Recovery first, then your \(label)" : "On to your \(label)"
            detail = raced
                ? "You did the thing. The next \(recovery) week\(recovery == 1 ? "" : "s") stay deliberately easy so the fitness locks in. Then the block builds toward your \(label) on \(when)."
                : "Your plan now builds toward your \(label) on \(when)."
        } else {
            headline = raced ? "Race done — recovery block first" : "Race week's behind you"
            detail = raced
                ? "You did the thing. The next \(recovery) week\(recovery == 1 ? "" : "s") stay deliberately easy — the fitness you built gets locked in by the recovery, not the next hard run. Then we roll."
                : "Your plan rolled into a fresh block. Whenever the next start line calls, set it and the season builds toward it."
        }
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
        return rebuild(
            for: profile,
            calibration: seed,
            startDate: startDate,
            blockIndex: nextIndex,
            in: context
        )
    }

    /// The athlete's real running volume per week over the trailing `weeks`, in meters — the average
    /// of logged run/trail-run distance. `nil` when there's not enough logged to be meaningful (no
    /// GPS distance at all), so callers can fall back to the declared figure rather than trust a zero.
    static func recentWeeklyRunVolumeM(endingAt end: Date = Date(), weeks: Int = 4,
                                       in context: ModelContext, calendar: Calendar = .current) -> Double? {
        let runs = (try? runEvidence(endingAt: end, in: context, calendar: calendar)) ?? []
        return PlanFitnessEvidence.recentWeeklyRunVolumeM(
            runs,
            endingAt: end,
            weeks: weeks,
            calendar: calendar
        )
    }

    /// Where the athlete is **right now** — the figures a coach would ask for before writing or
    /// reshaping a block, read from what was actually logged rather than what was typed at signup.
    ///
    /// `UserProfile.weeklyRunVolumeM` / `longestRunM` are written once during onboarding and never
    /// again, so every rebuild (a settings change, a coach intent, an injury report) restarted the
    /// volume ramp from a number that could be months old: a marathoner peaking at 70 km/wk who
    /// typed 40 at signup was rebuilt back down to 40. The declared figure remains a conservative
    /// guardrail, never the automatic answer.
    ///
    /// Onboarding declarations remain valid during the first eight weeks. After that evidence window,
    /// recent logged running replaces them; sparse or absent evidence gets a conservative returning
    /// baseline instead of resurrecting a months-old peak.
    static func observedFitness(for profile: UserProfile, on date: Date = Date(),
                                in context: ModelContext,
                                calendar: Calendar = .current) -> (weeklyM: Double?, longestM: Double?) {
        let runs = (try? runEvidence(endingAt: date, in: context, calendar: calendar)) ?? []
        let snapshot = PlanFitnessEvidence.snapshot(
            runs: runs,
            declaredWeeklyM: profile.weeklyRunVolumeM,
            declaredLongestM: profile.longestRunM,
            profileCreatedAt: profile.createdAt,
            endingAt: date,
            calendar: calendar
        )
        return (snapshot.weeklyM, snapshot.longestM)
    }

    /// One time-bounded query shared by main-actor generation and `PlanFitnessWorker`. A hard limit
    /// protects corrupted stores while remaining far above any plausible 56-day workout count.
    nonisolated static func runEvidence(endingAt end: Date,
                                        in context: ModelContext,
                                        calendar: Calendar) throws -> [PlanRunEvidence] {
        guard let cutoff = calendar.date(
            byAdding: .day,
            value: -PlanFitnessEvidence.historyDays,
            to: end
        ) else { return [] }
        var descriptor = FetchDescriptor<Workout>(
            predicate: #Predicate { workout in
                workout.startedAt >= cutoff && workout.startedAt <= end
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1_000
        return try context.fetch(descriptor).compactMap { workout in
            guard workout.type.discipline == .running,
                  let distanceM = workout.gps?.distanceM,
                  distanceM.isFinite,
                  distanceM > 0 else { return nil }
            return PlanRunEvidence(startedAt: workout.startedAt, distanceM: distanceM)
        }
    }

    /// The same window, flattened for `AthleteStateEngine`: distance, time, heart rate, splits,
    /// effort and what the run was logged against. Momentum-logged runs only, never Health.
    nonisolated static func runEvidenceRows(endingAt end: Date,
                                            in context: ModelContext,
                                            calendar: Calendar) throws -> [RunEvidenceRow] {
        guard let cutoff = calendar.date(
            byAdding: .day,
            value: -AthleteStateEngine.windowDays,
            to: end
        ) else { return [] }
        var descriptor = FetchDescriptor<Workout>(
            predicate: #Predicate { workout in
                workout.startedAt >= cutoff && workout.startedAt <= end
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1_000
        return try context.fetch(descriptor).compactMap { workout in
            guard workout.type.discipline == .running,
                  let gps = workout.gps,
                  gps.distanceM.isFinite, gps.distanceM > 0,
                  workout.durationS > 0 else { return nil }
            let planned = workout.plannedSession
            let splits = gps.splits.sorted { $0.index < $1.index }.map {
                RunEvidenceRow.SplitRow(distanceM: $0.distanceM, durationS: $0.durationS, avgHR: $0.avgHR)
            }
            return RunEvidenceRow(
                startedAt: workout.startedAt,
                distanceM: gps.distanceM,
                durationS: workout.durationS,
                avgHR: gps.avgHR,
                splits: splits,
                rpe: workout.perceivedEffort,
                plannedRunType: planned?.runType,
                plannedDistanceM: planned?.targetDistanceM,
                planFit: workout.planFit,
                isRace: planned?.runType == .race
            )
        }
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
        // No explicit day choice → let the Athlete Model's slip evidence steer the auto-spread
        // away from the weekdays this athlete demonstrably can't make (avoidWeekdays returns
        // 0-based weekday indices; +1 back to 1…7 before the same offset mapping).
        let avoidOffsets: [Int] = p.preferredDays.isEmpty
            ? AthleteModelEngine.avoidWeekdays(
                missed: p.athlete?.missedWeekdayHistogram ?? [],
                completed: p.athlete?.weekdayHistogram ?? [])
                .map { (((($0 + 1) - anchorWeekday) % 7) + 7) % 7 }
            : []
        return PlanInputs(
            disciplines: disciplines.isEmpty ? [.running] : disciplines,
            goal: p.goal, daysPerWeek: p.daysPerWeek, equipment: p.equipment,
            sessionMinutes: p.sessionMinutes, raceDate: p.raceDate,
            runningExperience: level(Discipline.running.rawValue),
            liftingExperience: level(Discipline.strength.rawValue),
            raceDistanceM: p.raceDistanceM,
            currentWeeklyVolumeM: p.weeklyRunVolumeM, longestRunM: p.longestRunM,
            goalFinishTimeS: p.goalFinishTimeS, targetWeeklyVolumeM: p.targetWeeklyRunVolumeM,
            hybridPriority: p.hybridPriority.flatMap(HybridPriority.init(rawValue:)),
            strengthSplit: StrengthSplitStyle(rawValue: p.strengthSplit) ?? .coach,
            muscleFocus: p.muscleFocus.compactMap(MuscleGroup.init(rawValue:)),
            preferredDayOffsets: offsets,
            avoidDayOffsets: avoidOffsets,
            intensity: PlanIntensity(rawValue: p.planIntensity ?? "") ?? .balanced,
            injuryHistory: p.injuryHistory.compactMap(InjuryArea.init(rawValue:)),
            age: p.birthYear.map { max(0, calendar.component(.year, from: startDate) - $0) },
            distanceUnit: (DistanceUnit(rawValue: p.distanceUnit) ?? .auto).resolved())
    }

    static func stagePersist(_ plan: GeneratedPlan, for profile: UserProfile,
                             startDate: Date, blockIndex: Int = 0, in context: ModelContext,
                             calendar: Calendar = .current) throws -> TrainingPlan {
        // Replace any existing plan — but the athlete's name for it survives the rebuild.
        let existing = profile.plan
        let carriedName = existing?.name ?? ""
        // Finished work survives too: completed sessions from the CURRENT calendar week detach from
        // the old plan before its cascade delete and re-attach to the new block — rebuilding on a
        // Thursday must not turn Monday's finished run into a "Rest day". A completed RACE carries
        // however far back it sits: it's the event the whole block was built for, and `completeRace`
        // rebuilds the day AFTER race day — so a Saturday race read on Monday is already "last week"
        // and would otherwise be erased from the board at the emotional peak of the season.
        // Carried history can therefore predate the block, which is why `blockStart` (not the earliest
        // session) anchors phase indexing and "Week N of M". The workouts themselves are never touched.
        var carriedDone: [PlannedSession] = []
        if let existing {
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
            }
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
        trainingPlan.goalRacePaceSPerKm = plan.goalRacePaceSPerKm
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
                ps.strengthLabel = gen.strengthLabel   // "Push"/"Upper"/… — names the day on every surface
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
        // Clone carried rows instead of detaching and pre-saving them. SwiftData's cascade tracks the
        // old plan's last-saved relationship snapshot; cloning lets the old graph be deleted inside
        // the same transaction without risking the completed workout link.
        let carriedClones = carriedDone.map(cloneCompletedSession)
        trainingPlan.sessions = sessions + carriedClones.map(\.session)
        context.insert(trainingPlan)
        profile.plan = trainingPlan // direct old -> new; the UI never observes a nil plan
        for carried in carriedClones {
            if let workout = carried.workout {
                carried.session.completedWorkout = workout
                workout.plannedSession = carried.session
            }
        }
        if let existing {
            try relinkReplacementSidecars(
                from: existing,
                to: trainingPlan,
                carriedSessionIDs: Set(carriedDone.map(\.id)),
                in: context
            )
            context.delete(existing)
        }
        return trainingPlan
    }

    private struct CarriedSessionClone {
        let session: PlannedSession
        let workout: Workout?
    }

    private static func cloneCompletedSession(_ source: PlannedSession) -> CarriedSessionClone {
        let clone = PlannedSession()
        clone.id = source.id
        clone.date = source.date
        clone.discipline = source.discipline
        clone.sportType = source.sportType
        clone.runType = source.runType
        clone.targetDistanceM = source.targetDistanceM
        clone.targetDurationS = source.targetDurationS
        clone.targetPaceSPerKm = source.targetPaceSPerKm
        clone.intervals = source.intervals
        clone.status = source.status
        clone.rationale = source.rationale
        clone.strengthLabel = source.strengthLabel
        clone.strengthTargets = source.strengthTargets.map { sourceTarget in
            let target = PlannedExercise()
            target.order = sourceTarget.order
            target.exercise = sourceTarget.exercise
            target.targetSets = sourceTarget.targetSets
            target.targetRepLow = sourceTarget.targetRepLow
            target.targetRepHigh = sourceTarget.targetRepHigh
            target.targetRPE = sourceTarget.targetRPE
            target.targetPctRM = sourceTarget.targetPctRM
            target.progression = sourceTarget.progression
            return target
        }
        return CarriedSessionClone(session: clone, workout: source.completedWorkout)
    }

    /// Moves the exact season ownership and carryover intents before legacy reconciliation runs.
    /// Domain-owned seasons (`backfillVersion == 0`) are intentionally included: renewal is a plan
    /// replacement inside the same season, not permission to create a duplicate legacy season.
    private static func relinkReplacementSidecars(from oldPlan: TrainingPlan,
                                                  to newPlan: TrainingPlan,
                                                  carriedSessionIDs: Set<UUID>,
                                                  in context: ModelContext) throws {
        let metadataMatches = try context.fetch(FetchDescriptor<PlanMetadataRecord>()).filter {
            $0.id == oldPlan.id || $0.planID == oldPlan.id
        }
        guard metadataMatches.count <= 1 else {
            throw ReplacementError.ambiguousMetadata(oldPlan.id)
        }
        let oldMetadata = metadataMatches.first

        let allSeasons = try context.fetch(FetchDescriptor<RunningSeasonRecord>())
        let linkedSeasonIDs = Set(
            allSeasons.filter { $0.activePlanID == oldPlan.id }.map(\.id)
                + (oldMetadata.map { [$0.seasonID] } ?? [])
        )
        guard linkedSeasonIDs.count <= 1 else {
            throw ReplacementError.ambiguousSeason(oldPlan.id)
        }
        let season = linkedSeasonIDs.first.flatMap { id in
            allSeasons.first { $0.id == id }
        }
        if let season {
            season.activePlanID = newPlan.id
            season.updatedAt = Date()
        }

        let oldIntents = try context.fetch(FetchDescriptor<PlannedSessionIntentRecord>()).filter {
            $0.planID == oldPlan.id
        }
        let grouped = Dictionary(grouping: oldIntents, by: \.plannedSessionID)
        if let duplicate = grouped.first(where: { $0.value.count > 1 }) {
            throw ReplacementError.ambiguousIntent(duplicate.key)
        }
        for intent in oldIntents {
            if carriedSessionIDs.contains(intent.plannedSessionID) {
                intent.planID = newPlan.id
                if let season { intent.seasonID = season.id }
            } else {
                context.delete(intent)
            }
        }
        if let oldMetadata { context.delete(oldMetadata) }
    }

    private static func transactReplacement(for profile: UserProfile,
                                            in context: ModelContext,
                                            hooks: Hooks,
                                            mutation: () throws -> TrainingPlan) -> TrainingPlan? {
        let previousAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = previousAutosave }
        do {
            let replacement = try mutation()
            _ = try RunningPlanBackfill.prepareAfterLegacyPlanMutation(in: context)
            try hooks.beforeSave?()
            try context.save()
            return replacement
        } catch {
            context.rollback()
            return nil
        }
    }
}
