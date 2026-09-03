import Foundation
import SwiftData

enum PlanConfigurationCommandError: Error, Equatable {
    case profileNotFound(UUID)
    case duplicateProfile(UUID)
    case seasonOwnedByAnotherProfile(seasonID: UUID, profileID: UUID)
    case duplicateSeason(UUID)
    case duplicateEvent(UUID)
    case eventOwnedByAnotherSeason(eventID: UUID, seasonID: UUID)
    case invalidSeason([RunningSeasonValidationCode])
    case incompatibleGoal(legacy: Goal, outcome: RunningPrimaryOutcome)
    case invalidRaceDistance
    case invalidGoalTime
    case staleRaceFields
    case primaryEventMismatch
    case multiplePrimaryEvents(UUID)
    case ambiguousActiveSeason(UUID)
    case invalidPersistedSeason(UUID)
    case invalidPersistedEvent(UUID)
    // Tune-up races (2026-09-03): a week can bend around one only when there is a week to bend.
    case tuneUpTooSoon(UUID)          // in the past, or inside the next seven days
    case tuneUpAfterGoalRace(UUID)
    case tuneUpTooClose(UUID)         // B within 7 days of the goal race or another B; C within 3
    case tuneUpInvalid(UUID)          // no distance, or a priority that is not B/C
}

/// One tune-up race as the athlete configures it in Plan Settings: B = race it, C = train through.
struct TuneUpEvent: Sendable, Equatable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String = ""
    var date: Date
    var distanceM: Double
    var priority: RunningEventPriority
    var goalTimeS: Double? = nil
}

/// The compatibility write boundary while `UserProfile` goal fields and the running-domain season
/// coexist. A view supplies one buffered value command; this type writes the legacy fields, the live
/// plan header, and the season/event sidecars together. No view should independently update both
/// representations.
///
/// The command does not generate a plan. `PlanStore` reuses its mutation step inside the one-save
/// candidate transaction; the legacy UI path may execute it after `PlanService` has rebuilt the plan.
struct PlanConfigurationCommand: Sendable {
    let id: UUID
    let profileID: UUID
    let season: RunningSeason
    let planName: String
    let legacyGoal: Goal
    let raceDate: Date?
    let raceDistanceM: Double?
    let goalFinishTimeS: Double?
    /// Planned tune-ups the athlete removed: marked withdrawn (never deleted) by `apply`.
    let withdrawnEventIDs: [UUID]
    /// "Now" for the tune-up timing rules — injected so validation is deterministic in tests.
    let referenceDate: Date

    init(id: UUID,
         profileID: UUID,
         season: RunningSeason,
         planName: String,
         legacyGoal: Goal,
         raceDate: Date?,
         raceDistanceM: Double?,
         goalFinishTimeS: Double?,
         withdrawnEventIDs: [UUID] = [],
         referenceDate: Date = Date()) {
        self.id = id
        self.profileID = profileID
        self.season = season
        self.planName = planName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.legacyGoal = legacyGoal
        self.raceDate = raceDate
        self.raceDistanceM = raceDistanceM
        self.goalFinishTimeS = goalFinishTimeS
        self.withdrawnEventIDs = withdrawnEventIDs
        self.referenceDate = referenceDate
    }

    struct Result: Equatable, Sendable {
        let seasonID: UUID
        let activePlanID: UUID?
        let eventIDs: [UUID]
        let didSave: Bool
    }

    /// Builds the one compatibility command used by the legacy create/adjust UI. Adjustments keep
    /// the current season identity; "New plan" starts a new season and lets execution archive the
    /// old one. Completed events survive an adjustment unchanged. `tuneUps` nil leaves the planned
    /// B/C events exactly as they are; a list REPLACES them — anything planned that the list no
    /// longer carries is withdrawn (visibly, never deleted).
    @MainActor
    static func legacyUICommand(id: UUID,
                                profile: UserProfile,
                                startsNewSeason: Bool,
                                planName: String,
                                goal: Goal,
                                raceDate: Date?,
                                raceDistanceM: Double?,
                                goalFinishTimeS: Double?,
                                tuneUps: [TuneUpEvent]? = nil,
                                now: Date = Date(),
                                in context: ModelContext) throws -> PlanConfigurationCommand {
        let allSeasons = try context.fetch(FetchDescriptor<RunningSeasonRecord>())
        let allEvents = try context.fetch(FetchDescriptor<RunningEventRecord>())
        let activePlanID = profile.plan?.id

        let reused: RunningSeasonRecord? = try {
            guard !startsNewSeason else { return nil }
            let exact = allSeasons.filter {
                $0.profileID == profile.id && $0.activePlanID == activePlanID
            }
            if exact.count > 1 {
                throw PlanConfigurationCommandError.ambiguousActiveSeason(profile.id)
            }
            if let exact = exact.first { return exact }
            let active = allSeasons.filter {
                $0.profileID == profile.id
                    && $0.statusRaw == RunningSeasonStatus.active.rawValue
            }
            if active.count > 1 {
                throw PlanConfigurationCommandError.ambiguousActiveSeason(profile.id)
            }
            return active.first
        }()

        let seasonID: UUID
        if let reused {
            guard RunningSeasonStatus(rawValue: reused.statusRaw) != nil,
                  RunningPrimaryOutcome(rawValue: reused.primaryOutcomeRaw) != nil,
                  reused.motivationRaws.allSatisfy({ RunningMotivation(rawValue: $0) != nil }) else {
                throw PlanConfigurationCommandError.invalidPersistedSeason(reused.id)
            }
            seasonID = reused.id
        } else {
            var proposed = id
            while allSeasons.contains(where: { $0.id == proposed }) { proposed = UUID() }
            seasonID = proposed
        }

        var events: [RunningSeasonEvent] = []
        var priorPrimary: RunningSeasonEvent?
        var withdrawn: [UUID] = []
        let desiredTuneUpIDs = tuneUps.map { Set($0.map(\.id)) }
        if reused != nil {
            for record in allEvents where record.seasonID == seasonID {
                guard let event = domainEvent(record) else {
                    throw PlanConfigurationCommandError.invalidPersistedEvent(record.id)
                }
                if event.priority == .a && event.status == .planned {
                    if priorPrimary != nil {
                        throw PlanConfigurationCommandError.multiplePrimaryEvents(seasonID)
                    }
                    priorPrimary = event
                } else if event.priority != .a, event.status == .planned, let desiredTuneUpIDs {
                    // The list is the truth for planned tune-ups: kept ones are re-appended from
                    // the list below, dropped ones are withdrawn.
                    if !desiredTuneUpIDs.contains(event.id) { withdrawn.append(event.id) }
                } else {
                    events.append(event)
                }
            }
        }
        if let tuneUps {
            for tuneUp in tuneUps {
                var eventID = tuneUp.id
                while allEvents.contains(where: { $0.id == eventID && $0.seasonID != seasonID }) {
                    eventID = UUID()
                }
                let prior = allEvents.first { $0.id == tuneUp.id && $0.seasonID == seasonID }.flatMap(domainEvent)
                events.append(RunningSeasonEvent(
                    id: eventID,
                    name: tuneUp.name,
                    date: tuneUp.date,
                    distanceM: tuneUp.distanceM,
                    durationS: tuneUp.goalTimeS,
                    priority: tuneUp.priority == .a ? .b : tuneUp.priority,
                    surface: prior?.surface ?? .road,
                    ascentM: prior?.ascentM,
                    descentM: prior?.descentM,
                    altitude: prior?.altitude ?? .unknown,
                    technicality: prior?.technicality ?? .unknown,
                    climate: prior?.climate ?? .unknown,
                    status: .planned
                ))
            }
        }

        let normalizedDate = goal == .raceDistance ? raceDate : nil
        let normalizedDistance = goal == .raceDistance ? raceDistanceM : nil
        let normalizedTime = goal == .raceDistance ? goalFinishTimeS : nil
        if let normalizedDate {
            var eventID = priorPrimary?.id ?? UUID()
            while allEvents.contains(where: { $0.id == eventID && $0.seasonID != seasonID }) {
                eventID = UUID()
            }
            events.append(RunningSeasonEvent(
                id: eventID,
                name: planName.isEmpty ? (priorPrimary?.name ?? "") : planName,
                date: normalizedDate,
                distanceM: normalizedDistance,
                durationS: normalizedTime,
                priority: .a,
                surface: priorPrimary?.surface ?? .road,
                ascentM: priorPrimary?.ascentM,
                descentM: priorPrimary?.descentM,
                altitude: priorPrimary?.altitude ?? .unknown,
                technicality: priorPrimary?.technicality ?? .unknown,
                climate: priorPrimary?.climate ?? .unknown,
                status: .planned
            ))
        }

        let outcome: RunningPrimaryOutcome = {
            if goal == .raceDistance { return normalizedTime == nil ? .finish : .targetTime }
            let level = ExperienceLevel(
                rawValue: profile.experience[Discipline.running.rawValue] ?? ""
            ) ?? .some
            return level == .new ? .returnToRunning : .buildBase
        }()
        let season = RunningSeason(
            id: seasonID,
            name: planName,
            status: .active,
            primaryOutcome: outcome,
            motivations: motivations(goal: goal, reason: profile.reason),
            events: events
        )
        return PlanConfigurationCommand(
            id: id,
            profileID: profile.id,
            season: season,
            planName: planName,
            legacyGoal: goal,
            raceDate: normalizedDate,
            raceDistanceM: normalizedDistance,
            goalFinishTimeS: normalizedTime,
            withdrawnEventIDs: withdrawn,
            referenceDate: now
        )
    }

    /// Standalone transactional execution. Candidate persistence calls `apply` directly so the
    /// configuration and replacement plan share one save and one rollback boundary.
    @MainActor
    func execute(in context: ModelContext,
                 now: Date = Date(),
                 beforeSave: (() throws -> Void)? = nil) throws -> Result {
        let previousAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = previousAutosave }
        do {
            let mutation = try apply(in: context, now: now)
            guard mutation.didChange else {
                return Result(
                    seasonID: mutation.seasonID,
                    activePlanID: mutation.activePlanID,
                    eventIDs: mutation.eventIDs,
                    didSave: false
                )
            }
            try beforeSave?()
            try context.save()
            return Result(
                seasonID: mutation.seasonID,
                activePlanID: mutation.activePlanID,
                eventIDs: mutation.eventIDs,
                didSave: true
            )
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Pure structural validation, exposed to `PlanStore` so malformed commands fail before the
    /// profile pointer or workout links enter the mutation window.
    func preflightValidation() throws {
        try validate()
    }
}

extension PlanConfigurationCommand {
    struct MutationResult {
        let seasonID: UUID
        let activePlanID: UUID?
        let eventIDs: [UUID]
        let didChange: Bool
    }

    /// Mutates only; the caller owns save/rollback. Internal so `PlanStore` can include the dual
    /// write in its candidate-first transaction without a nested save.
    @MainActor
    func apply(in context: ModelContext, now: Date) throws -> MutationResult {
        try validate()

        // Filtering the small owner table in actor isolation avoids SwiftData's generated
        // ReferenceWritableKeyPath crossing the strict-concurrency boundary.
        let profiles = try context.fetch(FetchDescriptor<UserProfile>())
            .filter { $0.id == profileID }
        guard let profile = profiles.first else {
            throw PlanConfigurationCommandError.profileNotFound(profileID)
        }
        guard profiles.count == 1 else {
            throw PlanConfigurationCommandError.duplicateProfile(profileID)
        }

        let allSeasons = try context.fetch(FetchDescriptor<RunningSeasonRecord>())
        let matchingSeasons = allSeasons.filter { $0.id == season.id }
        guard matchingSeasons.count <= 1 else {
            throw PlanConfigurationCommandError.duplicateSeason(season.id)
        }
        if let existing = matchingSeasons.first, existing.profileID != profileID {
            throw PlanConfigurationCommandError.seasonOwnedByAnotherProfile(
                seasonID: season.id,
                profileID: existing.profileID
            )
        }

        let allEvents = try context.fetch(FetchDescriptor<RunningEventRecord>())
        let eventsByID = Dictionary(grouping: allEvents, by: \RunningEventRecord.id)
        for (eventID, rows) in eventsByID where rows.count > 1 {
            throw PlanConfigurationCommandError.duplicateEvent(eventID)
        }
        for desired in season.events {
            if let existing = eventsByID[desired.id]?.first, existing.seasonID != season.id {
                throw PlanConfigurationCommandError.eventOwnedByAnotherSeason(
                    eventID: desired.id,
                    seasonID: existing.seasonID
                )
            }
        }

        var changed = false
        changed = assign(profile, \UserProfile.goal, legacyGoal) || changed
        changed = assign(profile, \UserProfile.raceDate, raceDate) || changed
        changed = assign(profile, \UserProfile.raceDistanceM, raceDistanceM) || changed
        changed = assign(profile, \UserProfile.goalFinishTimeS, goalFinishTimeS) || changed
        if let plan = profile.plan {
            changed = assign(plan, \TrainingPlan.name, planName) || changed
            changed = assign(plan, \TrainingPlan.goal, legacyGoal) || changed
            changed = assign(plan, \TrainingPlan.raceDate, raceDate) || changed
        }

        // Activating a different season is explicit: retain the old chapter, but do not leave two
        // rows claiming to be the athlete's active season.
        for other in allSeasons where other.profileID == profileID && other.id != season.id
            && other.statusRaw == RunningSeasonStatus.active.rawValue {
            other.statusRaw = RunningSeasonStatus.archived.rawValue
            other.activePlanID = nil
            other.updatedAt = now
            changed = true
        }

        let seasonRecord: RunningSeasonRecord
        if let existing = matchingSeasons.first {
            seasonRecord = existing
            var seasonChanged = false
            seasonChanged = assign(existing, \RunningSeasonRecord.activePlanID, profile.plan?.id) || seasonChanged
            seasonChanged = assign(existing, \RunningSeasonRecord.name, planName) || seasonChanged
            seasonChanged = assign(existing, \RunningSeasonRecord.statusRaw, season.status.rawValue) || seasonChanged
            seasonChanged = assign(
                existing,
                \RunningSeasonRecord.primaryOutcomeRaw,
                season.primaryOutcome.rawValue
            ) || seasonChanged
            seasonChanged = assign(
                existing,
                \RunningSeasonRecord.motivationRaws,
                season.motivations.map(\RunningMotivation.rawValue).sorted()
            ) || seasonChanged
            // Once an athlete explicitly edits this season, deferred legacy maintenance no longer
            // owns its meaning and must not overwrite the command on a later launch.
            seasonChanged = assign(existing, \RunningSeasonRecord.backfillVersion, 0) || seasonChanged
            if seasonChanged {
                existing.updatedAt = now
                changed = true
            }
        } else {
            let created = RunningSeasonRecord(
                id: season.id,
                profileID: profileID,
                activePlanID: profile.plan?.id,
                name: planName,
                createdAt: now,
                updatedAt: now,
                statusRaw: season.status.rawValue,
                primaryOutcomeRaw: season.primaryOutcome.rawValue,
                motivationRaws: season.motivations.map(\RunningMotivation.rawValue).sorted(),
                backfillVersion: 0
            )
            context.insert(created)
            seasonRecord = created
            changed = true
        }

        let desiredIDs = Set(season.events.map(\RunningSeasonEvent.id))
        let desiredPrimaryID = season.primaryEvent?.id
        // Omitted B/C or completed events are history and remain untouched. Only a superseded planned
        // A event loses primary status, and it does so visibly as withdrawn rather than disappearing.
        for existing in allEvents where existing.seasonID == season.id
            && existing.priorityRaw == RunningEventPriority.a.rawValue
            && existing.statusRaw == RunningEventStatus.planned.rawValue
            && (!desiredIDs.contains(existing.id) || existing.id != desiredPrimaryID) {
            existing.statusRaw = RunningEventStatus.withdrawn.rawValue
            changed = true
        }

        for dropped in withdrawnEventIDs {
            guard let existing = eventsByID[dropped]?.first, existing.seasonID == season.id,
                  existing.priorityRaw != RunningEventPriority.a.rawValue,
                  existing.statusRaw == RunningEventStatus.planned.rawValue else { continue }
            existing.statusRaw = RunningEventStatus.withdrawn.rawValue
            changed = true
        }

        var appliedEventIDs: [UUID] = []
        for desired in season.events {
            appliedEventIDs.append(desired.id)
            if let existing = eventsByID[desired.id]?.first {
                changed = apply(desired, to: existing) || changed
            } else {
                context.insert(record(for: desired, seasonID: season.id))
                changed = true
            }
        }

        let plannedPrimaryCount = allEvents.filter {
            $0.seasonID == season.id
                && $0.priorityRaw == RunningEventPriority.a.rawValue
                && $0.statusRaw == RunningEventStatus.planned.rawValue
                && desiredIDs.contains($0.id)
        }.count + season.events.filter {
            eventsByID[$0.id] == nil && $0.priority == .a && $0.status == .planned
        }.count
        if plannedPrimaryCount > 1 {
            throw PlanConfigurationCommandError.multiplePrimaryEvents(seasonRecord.id)
        }

        return MutationResult(
            seasonID: seasonRecord.id,
            activePlanID: profile.plan?.id,
            eventIDs: appliedEventIDs.sorted { $0.uuidString < $1.uuidString },
            didChange: changed
        )
    }
}

private extension PlanConfigurationCommand {
    static func domainEvent(_ record: RunningEventRecord) -> RunningSeasonEvent? {
        guard let priority = RunningEventPriority(rawValue: record.priorityRaw),
              let surface = RunningEventSurface(rawValue: record.surfaceRaw),
              let altitude = RunningEnvironmentBand(rawValue: record.altitudeRaw),
              let technicality = RunningEnvironmentBand(rawValue: record.technicalityRaw),
              let climate = RunningEnvironmentBand(rawValue: record.climateRaw),
              let status = RunningEventStatus(rawValue: record.statusRaw) else { return nil }
        return RunningSeasonEvent(
            id: record.id,
            name: record.name,
            date: record.date,
            distanceM: record.distanceM,
            durationS: record.durationS,
            priority: priority,
            surface: surface,
            ascentM: record.ascentM,
            descentM: record.descentM,
            altitude: altitude,
            technicality: technicality,
            climate: climate,
            status: status
        )
    }

    static func motivations(goal: Goal, reason: String) -> Set<RunningMotivation> {
        var result = Set<RunningMotivation>()
        switch goal {
        case .raceDistance, .endurance, .getStronger: result.insert(.performance)
        case .stayConsistent: result.insert(.consistency)
        case .loseFat, .buildMuscle: result.insert(.bodyComposition)
        case .generalFitness: result.insert(.health)
        }
        switch reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "clear head", "me-time", "stress": result.insert(.stress)
        case "look better", "body composition": result.insert(.bodyComposition)
        case "compete", "performance": result.insert(.performance)
        case "consistency": result.insert(.consistency)
        case "confidence": result.insert(.confidence)
        default: result.insert(.health)
        }
        return result
    }

    func validate() throws {
        let issues = season.validationIssues.map(\RunningSeasonValidationIssue.code)
        if !issues.isEmpty {
            throw PlanConfigurationCommandError.invalidSeason(issues)
        }
        let isRaceOutcome = ![RunningPrimaryOutcome.buildBase, .returnToRunning]
            .contains(season.primaryOutcome)
        if (legacyGoal == .raceDistance) != isRaceOutcome {
            throw PlanConfigurationCommandError.incompatibleGoal(
                legacy: legacyGoal,
                outcome: season.primaryOutcome
            )
        }
        if let raceDistanceM, !raceDistanceM.isFinite || raceDistanceM <= 0 {
            throw PlanConfigurationCommandError.invalidRaceDistance
        }
        if let goalFinishTimeS, !goalFinishTimeS.isFinite || goalFinishTimeS <= 0 {
            throw PlanConfigurationCommandError.invalidGoalTime
        }
        try validateTuneUps()
        guard legacyGoal == .raceDistance else {
            if raceDate != nil || raceDistanceM != nil || goalFinishTimeS != nil {
                throw PlanConfigurationCommandError.staleRaceFields
            }
            if season.primaryEvent != nil {
                throw PlanConfigurationCommandError.primaryEventMismatch
            }
            return
        }

        switch (raceDate, season.primaryEvent) {
        case (nil, nil):
            break // An undated distance/time goal is valid.
        case let (date?, event?):
            guard date == event.date,
                  sameNumber(raceDistanceM, event.distanceM),
                  sameNumber(goalFinishTimeS, event.durationS) else {
                throw PlanConfigurationCommandError.primaryEventMismatch
            }
        default:
            throw PlanConfigurationCommandError.primaryEventMismatch
        }
    }

    /// The tune-up timing rules: at least a week out (a week bends around a race only when there is
    /// a week to bend), before the goal race, and spaced so no two race efforts collide — a B race
    /// keeps seven days from the goal race and from any other B, a C race keeps three from anything.
    func validateTuneUps() throws {
        let calendar = Calendar(identifier: .gregorian)
        let planned = season.events.filter { $0.status == .planned && $0.priority != .a }
        guard !planned.isEmpty else { return }
        let earliest = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: referenceDate)) ?? referenceDate
        let goal = season.primaryEvent
        func days(_ a: Date, _ b: Date) -> Int {
            abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: a), to: calendar.startOfDay(for: b)).day ?? 0)
        }
        for event in planned {
            guard let distance = event.distanceM, distance.isFinite, distance > 0,
                  event.priority == .b || event.priority == .c else {
                throw PlanConfigurationCommandError.tuneUpInvalid(event.id)
            }
            // A tune-up already behind the athlete is history for `settleRaces`, not a rule
            // violation on an unrelated edit.
            if calendar.startOfDay(for: event.date) < calendar.startOfDay(for: referenceDate) { continue }
            if calendar.startOfDay(for: event.date) < earliest {
                throw PlanConfigurationCommandError.tuneUpTooSoon(event.id)
            }
            if let goal, calendar.startOfDay(for: event.date) >= calendar.startOfDay(for: goal.date) {
                throw PlanConfigurationCommandError.tuneUpAfterGoalRace(event.id)
            }
            let minimum = event.priority == .b ? 7 : 3
            if let goal, days(event.date, goal.date) < minimum {
                throw PlanConfigurationCommandError.tuneUpTooClose(event.id)
            }
            for other in planned where other.id != event.id {
                let required = (event.priority == .b && other.priority == .b) ? 7 : 3
                if days(event.date, other.date) < required {
                    throw PlanConfigurationCommandError.tuneUpTooClose(event.id)
                }
            }
        }
    }

    func record(for event: RunningSeasonEvent, seasonID: UUID) -> RunningEventRecord {
        RunningEventRecord(
            id: event.id,
            seasonID: seasonID,
            name: event.name,
            date: event.date,
            distanceM: event.distanceM,
            durationS: event.durationS,
            priorityRaw: event.priority.rawValue,
            surfaceRaw: event.surface.rawValue,
            ascentM: event.ascentM,
            descentM: event.descentM,
            altitudeRaw: event.altitude.rawValue,
            technicalityRaw: event.technicality.rawValue,
            climateRaw: event.climate.rawValue,
            statusRaw: event.status.rawValue
        )
    }

    func apply(_ event: RunningSeasonEvent, to record: RunningEventRecord) -> Bool {
        var changed = false
        changed = assign(record, \RunningEventRecord.seasonID, season.id) || changed
        changed = assign(record, \RunningEventRecord.name, event.name) || changed
        changed = assign(record, \RunningEventRecord.date, event.date) || changed
        changed = assign(record, \RunningEventRecord.distanceM, event.distanceM) || changed
        changed = assign(record, \RunningEventRecord.durationS, event.durationS) || changed
        changed = assign(record, \RunningEventRecord.priorityRaw, event.priority.rawValue) || changed
        changed = assign(record, \RunningEventRecord.surfaceRaw, event.surface.rawValue) || changed
        changed = assign(record, \RunningEventRecord.ascentM, event.ascentM) || changed
        changed = assign(record, \RunningEventRecord.descentM, event.descentM) || changed
        changed = assign(record, \RunningEventRecord.altitudeRaw, event.altitude.rawValue) || changed
        changed = assign(record, \RunningEventRecord.technicalityRaw, event.technicality.rawValue) || changed
        changed = assign(record, \RunningEventRecord.climateRaw, event.climate.rawValue) || changed
        changed = assign(record, \RunningEventRecord.statusRaw, event.status.rawValue) || changed
        return changed
    }

    func assign<Root: AnyObject, Value: Equatable>(
        _ root: Root,
        _ keyPath: ReferenceWritableKeyPath<Root, Value>,
        _ value: Value
    ) -> Bool {
        guard root[keyPath: keyPath] != value else { return false }
        root[keyPath: keyPath] = value
        return true
    }

    func sameNumber(_ lhs: Double?, _ rhs: Double?, tolerance: Double = 0.001) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): lhs.isFinite && rhs.isFinite && abs(lhs - rhs) <= tolerance
        default: false
        }
    }
}
