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
        runningExperience = ExperienceLevel(rawValue: profile.experience[Discipline.running.rawValue] ?? "") ?? .some
        liftingExperience = ExperienceLevel(rawValue: profile.experience[Discipline.strength.rawValue] ?? "") ?? .some
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
        if let weeklyRunVolumeM { profile.weeklyRunVolumeM = weeklyRunVolumeM }
        if let longestRunM { profile.longestRunM = longestRunM }
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

    /// The honest read for a blueprint, from the blueprint's own numbers.
    static func feasibility(for blueprint: PlanBlueprint, profile: UserProfile, today: Date = Date(),
                            calendar: Calendar = .current) -> PlanFeasibility {
        let weeks = blueprint.raceDate.map {
            max(0, calendar.dateComponents([.weekOfYear], from: today, to: $0).weekOfYear ?? 0)
        } ?? 0
        return PlanFeasibility.assess(
            raceDistanceM: blueprint.isRace ? blueprint.raceDistanceM : nil,
            goalFinishTimeS: blueprint.isRace ? blueprint.goalFinishTimeS : nil,
            currentP5kSPerKm: profile.plan?.p5kSPerKm,
            currentWeeklyVolumeM: blueprint.weeklyRunVolumeM ?? profile.weeklyRunVolumeM ?? 0,
            weeksAvailable: weeks,
            experience: blueprint.runningExperience,
            injuryProne: !profile.injuryHistory.isEmpty,
            daysPerWeek: blueprint.daysPerWeek,
            intensity: blueprint.intensity,
            targetWeeklyVolumeM: blueprint.targetWeeklyRunVolumeM)
    }

    /// Generate and summarise a blueprint without writing anything. Synchronous engine work; call
    /// it from a background task when a keystroke is behind it.
    static func preview(for blueprint: PlanBlueprint, profile: UserProfile, startDate: Date,
                        today: Date = Date(), in context: ModelContext,
                        calendar: Calendar = .current) -> PlanPreview {
        let staged = PlanService.stagePreview(blueprint: blueprint, for: profile, startDate: startDate,
                                              in: context, calendar: calendar)
        let outlook = feasibility(for: blueprint, profile: profile, today: today, calendar: calendar)
        return PlanPreview.build(generated: staged.generated, inputs: staged.inputs, startDate: startDate,
                                 feasibility: outlook, calendar: calendar)
    }

    // MARK: Drafts

    @discardableResult
    static func saveDraft(_ blueprint: PlanBlueprint, preview: PlanPreview?, for profile: UserProfile,
                          now: Date = Date(), in context: ModelContext) throws -> PlanShelfRecord {
        let record = PlanShelfRecord(profileID: profile.id, status: .draft, name: blueprint.displayName,
                                     createdAt: now, blueprintData: try JSONEncoder().encode(blueprint))
        record.previewData = try preview.map { try JSONEncoder().encode($0) }
        record.scheduledStart = nil
        context.insert(record)
        try context.save()
        return record
    }

    static func update(_ record: PlanShelfRecord, blueprint: PlanBlueprint, preview: PlanPreview?,
                       now: Date = Date(), in context: ModelContext) throws {
        record.blueprintData = try JSONEncoder().encode(blueprint)
        record.previewData = try preview.map { try JSONEncoder().encode($0) }
        record.name = blueprint.displayName
        record.updatedAt = now
        try context.save()
    }

    /// Put a draft on the calendar. Overlap with the current plan is the caller's decision to
    /// surface (`PlanLifecycle.overlap`); this only refuses a day that is not in the future.
    static func schedule(_ record: PlanShelfRecord, start: Date, now: Date = Date(),
                         in context: ModelContext, calendar: Calendar = .current) throws {
        guard PlanLifecycle.canSchedule(start, today: now, calendar: calendar) else {
            throw Failure.scheduleMustBeInTheFuture
        }
        record.status = .upcoming
        record.scheduledStart = calendar.startOfDay(for: start)
        record.updatedAt = now
        try context.save()
    }

    static func moveToDrafts(_ record: PlanShelfRecord, now: Date = Date(), in context: ModelContext) throws {
        record.status = .draft
        record.scheduledStart = nil
        record.updatedAt = now
        try context.save()
    }

    static func delete(_ record: PlanShelfRecord, in context: ModelContext) throws {
        context.delete(record)
        try context.save()
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
            if let current = profile.plan, !current.sessions.isEmpty {
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
            try context.save()
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
            demote(winner, now: today, in: context)
            return nil
        }
        do {
            let activation = try activate(blueprint, from: winner, for: profile, now: today,
                                          in: context, calendar: calendar)
            for other in others { demote(other, now: today, in: context) }
            return activation
        } catch {
            demote(winner, now: today, in: context)
            return nil
        }
    }

    private static func demote(_ record: PlanShelfRecord, now: Date, in context: ModelContext) {
        record.status = .draft
        record.scheduledStart = nil
        record.updatedAt = now
        try? context.save()
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
        let title = plan.name.isEmpty
            ? (plan.raceDate == nil ? "\(blueprint.displayName) · block \(plan.blockIndex + 1)" : blueprint.displayName)
            : plan.name
        let record = PlanShelfRecord(profileID: profile.id, status: resolved, name: title, createdAt: now,
                                     blueprintData: (try? JSONEncoder().encode(blueprint)) ?? Data())
        record.startedAt = planSpan.start
        record.endedAt = min(calendar.startOfDay(for: endedAt), planSpan.end.map { calendar.startOfDay(for: $0) } ?? endedAt)
        record.sourcePlanID = plan.id
        record.snapshotData = try? JSONEncoder().encode(state)
        let preview = PlanPreview.build(snapshot: state, blueprint: blueprint, distanceUnit: unit, calendar: calendar)
        record.previewData = try? JSONEncoder().encode(preview)
        context.insert(record)
        return record
    }

    // MARK: Downstream

    /// Everything that mirrors the current plan: reminders, the widget, the wrist, the inbox.
    static func propagate(_ activation: Activation, profile: UserProfile, workouts: [Workout],
                          notifications: NotificationServing, in context: ModelContext,
                          calendar: Calendar = .current) {
        notifications.schedulePlannedReminders(activation.plan)
        WidgetBridge.publish(profile: profile, workouts: workouts,
                             stats: ProfileStats(workouts: workouts, plan: activation.plan, calendar: calendar))
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
