import Foundation
import SwiftData

// MARK: - Blueprint ↔ profile

extension PlanBlueprint {
    /// What the athlete's profile says the current plan is (2026-09-07). The profile is the only
    /// place these inputs live for the current plan; a shelved plan carries its own copy.
    init(profile: UserProfile) {
        self.init()
        name = profile.plan?.name ?? ""
        goal = profile.goal
        includesStrength = profile.disciplines.contains(Discipline.strength.rawValue)
        raceDistanceM = profile.raceDistanceM
        raceDate = profile.raceDate
        goalFinishTimeS = profile.goalFinishTimeS
        daysPerWeek = profile.daysPerWeek
        preferredDays = profile.preferredDays
        sessionMinutes = profile.sessionMinutes
        equipment = profile.equipment
        intensity = PlanIntensity(rawValue: profile.planIntensity ?? "") ?? .balanced
        targetWeeklyRunVolumeM = profile.targetWeeklyRunVolumeM
        hybridPriority = profile.hybridPriority.flatMap(HybridPriority.init(rawValue:))
        strengthSplit = StrengthSplitStyle(rawValue: profile.strengthSplit) ?? .coach
        muscleFocus = profile.muscleFocus.compactMap(MuscleGroup.init(rawValue:))
        weeklyRunVolumeM = profile.weeklyRunVolumeM
        longestRunM = profile.longestRunM
        fitnessDeclaredAt = profile.fitnessDeclaredAt
        runningExperience = ExperienceLevel(rawValue: profile.experience[Discipline.running.rawValue] ?? "") ?? .some
        liftingExperience = ExperienceLevel(rawValue: profile.experience[Discipline.strength.rawValue] ?? "") ?? .some
        isSelfCoached = profile.plan?.isSelfCoached ?? false
    }

    /// Write the plan-shaped fields to the profile. Body, injury history and the athlete model are
    /// not the blueprint's to touch. Disciplines the engine treats as cross-training (cycling,
    /// walking) are preserved for `PlanService.stageRebuild` to fold into `crossTraining`.
    func apply(to profile: UserProfile) {
        let extras = profile.disciplines.filter {
            $0 != Discipline.running.rawValue && $0 != Discipline.strength.rawValue
        }
        profile.disciplines = [Discipline.running.rawValue] + (lifts ? [Discipline.strength.rawValue] : []) + extras
        profile.goal = goal
        profile.raceDistanceM = isRace ? raceDistanceM : nil
        profile.raceDate = isRace ? raceDate : nil
        profile.goalFinishTimeS = isRace ? goalFinishTimeS : nil
        profile.daysPerWeek = daysPerWeek
        profile.preferredDays = preferredDays
        profile.sessionMinutes = sessionMinutes
        profile.equipment = equipment
        profile.planIntensity = intensity.rawValue
        profile.targetWeeklyRunVolumeM = targetWeeklyRunVolumeM
        profile.hybridPriority = hybridPriority?.rawValue
        profile.strengthSplit = strengthSplit.rawValue
        profile.muscleFocus = muscleFocus.map(\.rawValue)
        if let fitnessDeclaredAt {
            profile.weeklyRunVolumeM = weeklyRunVolumeM
            profile.longestRunM = longestRunM
            if let context = profile.modelContext {
                PlanFitnessDeclarationRecord.set(fitnessDeclaredAt, for: profile, in: context)
            }
        } else {
            // Old saved blueprints with absent fields preserve their original fallback behavior.
            if let weeklyRunVolumeM { profile.weeklyRunVolumeM = weeklyRunVolumeM }
            if let longestRunM { profile.longestRunM = longestRunM }
        }
        profile.experience[Discipline.running.rawValue] = runningExperience.rawValue
        if lifts { profile.experience[Discipline.strength.rawValue] = liftingExperience.rawValue }
    }
}

// MARK: - The service

/// The only writer of the plan shelf and the only path that makes a shelved plan the current one
/// (docs/PLAN-AND-FUEL-UPGRADE.md §3.2–3.3). Every mutation is one transaction: autosave off,
/// one save, rollback on any throw, so a half-switched plan can never be observed.
@MainActor
enum PlanLifecycleService {
    enum Failure: Error, Equatable {
        case noProfile
        case unreadableBlueprint
        case raceDateInThePast
        case scheduleMustBeInTheFuture
        /// A race plan cannot start after its own race day.
        case startAfterRaceDay
        case notShelved
    }

    struct Activation {
        var plan: TrainingPlan
        /// The plan this one replaced, now on the shelf. nil when there was nothing to retire.
        var retired: PlanShelfRecord?
        /// The day the athlete had scheduled, when the activation came from an upcoming plan.
        var scheduledStart: Date?
        var start: Date
    }

    // MARK: Reads

    static func shelf(for profile: UserProfile, in context: ModelContext) -> [PlanShelfRecord] {
        PlanShelfRecord.fetch(profileID: profile.id, in: context)
    }

    /// The current plan's calendar footprint.
    static func span(of plan: TrainingPlan, calendar: Calendar = .current) -> PlanLifecycle.Span {
        let dates = plan.sessions.map(\.date)
        let start = plan.blockStart ?? dates.min() ?? plan.createdAt
        let end = plan.raceDate ?? dates.max()
        let open = plan.sessions.filter { $0.status == .planned || $0.status == .moved }.map(\.date)
        return PlanLifecycle.Span(start: start, end: end, raceDate: plan.raceDate, openSessionDates: open)
    }

    static func currentSpan(for profile: UserProfile, calendar: Calendar = .current) -> PlanLifecycle.Span? {
        profile.plan.map { span(of: $0, calendar: calendar) }
    }

    /// The honest read for a blueprint, from the blueprint's own numbers. Weeks are counted the
    /// way every other surface counts them (`PlanEngine.weeksToRace`, day-based), and a distance
    /// with no date on it is a rolling plan, not a race with a zero-week runway.
    /// `currentWeeklyM` is the fitness the generator will actually build from (logged runs first);
    /// the preview passes it so the outlook and the plan beside it read the same number.
    static func feasibility(for blueprint: PlanBlueprint, profile: UserProfile, today: Date = Date(),
                            currentWeeklyM: Double? = nil, calendar: Calendar = .current) -> PlanFeasibility {
        let dated = blueprint.isRace && blueprint.raceDate != nil
        let weeks = blueprint.raceDate.map { PlanEngine.weeksToRace(startDate: today, raceDate: $0, calendar: calendar) ?? 0 } ?? 0
        return PlanFeasibility.assess(
            raceDistanceM: dated ? blueprint.raceDistanceM : nil,
            goalFinishTimeS: dated ? blueprint.goalFinishTimeS : nil,
            currentP5kSPerKm: profile.plan?.p5kSPerKm,
            currentWeeklyVolumeM: currentWeeklyM ?? (blueprint.fitnessDeclaredAt != nil
                ? (blueprint.weeklyRunVolumeM ?? 0) : (blueprint.weeklyRunVolumeM ?? profile.weeklyRunVolumeM ?? 0)),
            weeksAvailable: weeks,
            experience: blueprint.runningExperience,
            injuryProne: !profile.injuryHistory.isEmpty,
            daysPerWeek: blueprint.daysPerWeek,
            intensity: blueprint.intensity,
            targetWeeklyVolumeM: blueprint.targetWeeklyRunVolumeM,
            regularRunLimitS: profile.planPreferences?.regularRunLimitS,
            longRunLimitS: profile.planPreferences?.longRunLimitS)
    }

    /// Generate and summarise a blueprint without writing anything. Synchronous engine work; call
    /// it from a background task when a keystroke is behind it.
    static func preview(for blueprint: PlanBlueprint, profile: UserProfile, startDate: Date,
                        today: Date = Date(), in context: ModelContext,
                        calendar: Calendar = .current) -> PlanPreview {
        let staged = PlanService.stagePreview(blueprint: blueprint, for: profile, startDate: startDate,
                                              in: context, calendar: calendar)
        let outlook = feasibility(for: blueprint, profile: profile, today: startDate,
                                  currentWeeklyM: staged.inputs.currentWeeklyVolumeM, calendar: calendar)
        return PlanPreview.build(generated: staged.generated, inputs: staged.inputs, startDate: startDate,
                                 feasibility: outlook, crossTrainingPerWeek: staged.crossTrainingPerWeek,
                                 calendar: calendar)
    }

    // MARK: Drafts

    @discardableResult
    static func saveDraft(_ blueprint: PlanBlueprint, preview: PlanPreview?, for profile: UserProfile,
                          now: Date = Date(), in context: ModelContext) throws -> PlanShelfRecord {
        let clean = blueprint.sanitized()
        let record = PlanShelfRecord(profileID: profile.id, status: .draft, name: clean.displayName,
                                     createdAt: now, blueprintData: try JSONEncoder().encode(clean))
        record.previewData = try preview.map { try JSONEncoder().encode($0) }
        record.scheduledStart = nil
        context.insert(record)
        try PlanMutation.save(context)
        return record
    }

    static func update(_ record: PlanShelfRecord, blueprint: PlanBlueprint, preview: PlanPreview?,
                       now: Date = Date(), in context: ModelContext) throws {
        let clean = blueprint.sanitized()
        record.blueprintData = try JSONEncoder().encode(clean)
        record.previewData = try preview.map { try JSONEncoder().encode($0) }
        record.name = clean.displayName
        record.updatedAt = now
        try PlanMutation.save(context)
    }

    /// Put a draft on the calendar. Overlap with the current plan is the caller's decision to
    /// surface (`PlanLifecycle.overlap`); this refuses a day that is not in the future and a day
    /// after the plan's own race. With a profile, the cached preview is rebuilt for the scheduled
    /// day, so the card's duration and end date describe the plan that will actually start then.
    static func schedule(_ record: PlanShelfRecord, start: Date, for profile: UserProfile? = nil,
                         now: Date = Date(), in context: ModelContext, calendar: Calendar = .current) throws {
        guard !record.isDeleted, record.modelContext === context,
              profile == nil || record.profileID == profile?.id else { throw Failure.notShelved }
        guard let blueprint = record.blueprint else { throw Failure.unreadableBlueprint }
        guard PlanLifecycle.canSchedule(start, today: now, calendar: calendar) else {
            throw Failure.scheduleMustBeInTheFuture
        }
        let day = calendar.startOfDay(for: start)
        if blueprint.isRace, let raceDate = blueprint.raceDate,
           calendar.startOfDay(for: raceDate) < day {
            throw Failure.startAfterRaceDay
        }
        // The cached preview is rebuilt for the scheduled day unless it already is (the builder
        // previews an upcoming plan for its day, so a Save there would run the generator twice).
        if let profile,
           !(record.preview.map { calendar.isDate($0.startDate, inSameDayAs: day) } ?? false) {
            let built = preview(for: blueprint, profile: profile, startDate: day, today: now, in: context, calendar: calendar)
            record.previewData = try JSONEncoder().encode(built)
        }
        record.status = .upcoming
        record.scheduledStart = day
        record.updatedAt = now
        try PlanMutation.save(context)
    }

    static func moveToDrafts(_ record: PlanShelfRecord, now: Date = Date(), in context: ModelContext) throws {
        record.status = .draft
        record.scheduledStart = nil
        record.updatedAt = now
        try PlanMutation.save(context)
    }

    static func delete(_ record: PlanShelfRecord, in context: ModelContext) throws {
        context.delete(record)
        try PlanMutation.save(context)
    }

    /// A previous plan's blueprint, copied into a fresh draft with the dates cleared: the athlete
    /// starts again from what worked, not from a stale race day.
    @discardableResult
    static func startAgain(_ record: PlanShelfRecord, for profile: UserProfile, now: Date = Date(),
                           in context: ModelContext) throws -> PlanShelfRecord {
        guard var blueprint = record.blueprint else { throw Failure.unreadableBlueprint }
        if let raceDate = blueprint.raceDate, raceDate < now {
            blueprint.raceDate = nil
        }
        return try saveDraft(blueprint, preview: nil, for: profile, now: now, in: context)
    }

    // MARK: Activation

    /// Make a blueprint the current plan. The current plan (if it has any sessions) goes to the
    /// shelf first, as completed when its own end has passed, otherwise as incomplete. The plan
    /// starts today (evenings: tomorrow), never backdated. One save; rollback on any throw.
    @discardableResult
    static func activate(_ blueprint: PlanBlueprint, from record: PlanShelfRecord? = nil,
                         for profile: UserProfile, now: Date = Date(), in context: ModelContext,
                         calendar: Calendar = .current) throws -> Activation {
        if let record {
            guard !record.isDeleted, record.modelContext === context, record.profileID == profile.id else {
                throw Failure.notShelved
            }
        }
        let start = PlanLifecycle.activationStart(now: now, calendar: calendar)
        if blueprint.isRace, let raceDate = blueprint.raceDate,
           calendar.startOfDay(for: raceDate) < calendar.startOfDay(for: start) {
            throw Failure.raceDateInThePast
        }
        let previousAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = previousAutosave }
        do {
            var retired: PlanShelfRecord?
            if let current = profile.plan,
               PlanLifecycle.isWorthShelving(sessionStatuses: current.sessions.map(\.status),
                                             blockStart: current.blockStart, now: now, calendar: calendar) {
                retired = retire(current, of: profile, endedAt: now, now: now, in: context, calendar: calendar)
            }
            // Resolve the season while the current plan is still attached (the command reads it),
            // then write the blueprint, rebuild, and let the command settle the season sidecars.
            let configuration = try PlanConfigurationCommand.legacyUICommand(
                id: UUID(), profile: profile, startsNewSeason: true, planName: blueprint.name,
                goal: blueprint.goal,
                raceDate: blueprint.isRace ? blueprint.raceDate : nil,
                raceDistanceM: blueprint.isRace ? blueprint.raceDistanceM : nil,
                goalFinishTimeS: blueprint.isRace ? blueprint.goalFinishTimeS : nil,
                tuneUps: nil, now: now, in: context)
            try configuration.preflightValidation()
            blueprint.apply(to: profile)
            // A fresh plan carries no tune-ups: the old season's B/C races belong to the old season.
            let plan = try PlanService.stageRebuild(for: profile, startDate: start, tuneUps: [], in: context)
            _ = try configuration.apply(in: context, now: now)
            _ = try RunningPlanBackfill.prepareAfterLegacyPlanMutation(in: context)
            let scheduled = record?.scheduledStart
            if let record { context.delete(record) }
            // A chat undo captured against the replaced plan would resurrect it beside its own
            // shelf record; a switch is a new world, so every older undo point retires here.
            CoachUndo.makeSoleUndoPoint(in: context)
            try PlanMutation.save(context)
            return Activation(plan: plan, retired: retired, scheduledStart: scheduled, start: start)
        } catch {
            context.rollback()
            throw error
        }
    }

    /// The daily settle: the earliest upcoming plan whose day has come starts now. Any other plan
    /// that was also due returns to drafts (two plans cannot both start). A record that fails to
    /// activate also returns to drafts, with its blueprint intact, rather than failing on every
    /// launch. Idempotent by construction: the record is deleted in the activation's own save, so a
    /// second sweep, a retry, or another launch finds nothing due.
    @discardableResult
    static func activateDueUpcoming(for profile: UserProfile, today: Date = Date(),
                                    in context: ModelContext, calendar: Calendar = .current) -> Activation? {
        let upcoming = shelf(for: profile, in: context).filter { $0.status == .upcoming && $0.scheduledStart != nil }
        let due = upcoming.compactMap { record in record.scheduledStart.map { (id: record.id, scheduledStart: $0) } }
        guard let winnerID = PlanLifecycle.firstDue(due, today: today, calendar: calendar),
              let winner = upcoming.first(where: { $0.id == winnerID }) else { return nil }
        let others = upcoming.filter { other in
            other.id != winnerID && other.scheduledStart.map {
                PlanLifecycle.isDue(scheduledStart: $0, today: today, calendar: calendar)
            } == true
        }
        guard let blueprint = winner.blueprint else {
            demote(winner, now: today, in: context, save: true)
            return nil
        }
        // The runners-up return to drafts INSIDE the activation's save: a demotion that failed on
        // its own would leave a second due plan to replace the one just started on the next sweep.
        // A rolled-back activation rolls the demotions back with it, which is the right outcome.
        for other in others { demote(other, now: today, in: context, save: false) }
        do {
            return try activate(blueprint, from: winner, for: profile, now: today, in: context, calendar: calendar)
        } catch {
            demote(winner, now: today, in: context, save: true)
            return nil
        }
    }

    /// Back to drafts, said out loud in the inbox: an upcoming plan that could not start (its race
    /// day passed, or a second plan was due the same day) must never vanish silently.
    private static func demote(_ record: PlanShelfRecord, now: Date, in context: ModelContext, save: Bool) {
        record.status = .draft
        record.scheduledStart = nil
        record.updatedAt = now
        AppNotification.post(kind: .coaching, title: "\(record.name) moved back to drafts",
                             body: "It could not start on its scheduled day. Open Your plans to edit it or start it when you are ready.",
                             on: now, in: context, dedupeToken: "plan-demoted-\(record.id.uuidString)", daily: false,
                             route: .plan)
        if save { try? PlanMutation.save(context) }
    }

    // MARK: Retiring

    /// Put the current plan on the shelf as it stands. Insert only; the enclosing transaction owns
    /// the save (`activate`, `PlanService.completeRace`, `PlanService.renewBlock`). The `Workout`
    /// rows are untouched; the plan's final state rides along as a snapshot.
    @discardableResult
    static func retire(_ plan: TrainingPlan, of profile: UserProfile, endedAt: Date, now: Date = Date(),
                       status: PlanShelfStatus? = nil, in context: ModelContext,
                       calendar: Calendar = .current) -> PlanShelfRecord {
        let planSpan = span(of: plan, calendar: calendar)
        let resolved = status ?? PlanLifecycle.retirementStatus(planSpan, at: endedAt, calendar: calendar)
        var blueprint = PlanBlueprint(profile: profile)
        blueprint.name = plan.name
        // The plan's own fields outrank the profile's for the goal line: a race the profile has
        // already moved past is still the race this plan was for.
        blueprint.goal = plan.goal
        blueprint.raceDate = plan.raceDate ?? blueprint.raceDate
        let unit = (DistanceUnit(rawValue: profile.distanceUnit) ?? .auto).resolved()
        let state = CoachUndo.planState(of: plan)
        // A rolling block is one chapter of an open-ended plan: number it, so "Build running
        // fitness · block 3" reads as the third six-week block rather than three identical plans.
        blueprint.isSelfCoached = plan.isSelfCoached
        let base = plan.isSelfCoached ? "Self-coached" : blueprint.displayName
        let title = plan.name.isEmpty
            ? (plan.raceDate == nil ? "\(base) · block \(plan.blockIndex + 1)" : base)
            : plan.name
        let record = PlanShelfRecord(profileID: profile.id, status: resolved, name: title, createdAt: now,
                                     blueprintData: (try? JSONEncoder().encode(blueprint.sanitized())) ?? Data())
        record.startedAt = planSpan.start
        record.endedAt = min(calendar.startOfDay(for: endedAt), planSpan.end.map { calendar.startOfDay(for: $0) } ?? endedAt)
        record.sourcePlanID = plan.id
        record.snapshotData = try? JSONEncoder().encode(state)
        let preview = PlanPreview.build(snapshot: state, blueprint: blueprint, distanceUnit: unit,
                                        anchor: planSpan.start, calendar: calendar)
        record.previewData = try? JSONEncoder().encode(preview)
        context.insert(record)
        return record
    }

    // MARK: Downstream

    /// Everything that mirrors the current plan: reminders, the widget, the wrist, the inbox. The
    /// widget snapshot walks the whole workout history for its stats, so it runs a beat later off
    /// the frame that switched the plan (Today's own throttled pass repeats it anyway).
    static func propagate(_ activation: Activation, profile: UserProfile, workouts: [Workout],
                          notifications: NotificationServing, in context: ModelContext,
                          calendar: Calendar = .current) {
        notifications.schedulePlannedReminders(activation.plan)
        let plan = activation.plan
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            // The profile may be gone half a second later (an account wipe, a torn-down test
            // container): a relationship read on it then traps inside SwiftData.
            guard !profile.isDeleted, profile.modelContext != nil else { return }
            guard !plan.isDeleted, plan.modelContext != nil else { return }
            WidgetBridge.publish(profile: profile, workouts: workouts,
                                 stats: ProfileStats(workouts: workouts, plan: plan, calendar: calendar))
        }
        PhoneWatchSync.shared.scheduleRefresh()
        let name = activation.plan.name.isEmpty ? "Your new plan" : activation.plan.name
        var body = "\(name) starts \(calendar.isDateInToday(activation.start) ? "today" : "tomorrow")."
        if let scheduled = activation.scheduledStart, !calendar.isDate(scheduled, inSameDayAs: activation.start) {
            body += " It was scheduled for \(scheduled.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))."
        }
        if let retired = activation.retired {
            body += " \(retired.name) is in your previous plans."
        }
        AppNotification.post(kind: .coaching, title: "Plan started", body: body, in: context,
                             dedupeToken: "plan-activated-\(activation.plan.id.uuidString)", daily: false,
                             route: .plan)
    }
}
