import Foundation
import SwiftData

enum RunningPlanBackfillError: Error, Equatable {
    case duplicateIdentifier(entity: String, id: UUID)
    case planOwnedByMultipleProfiles(planID: UUID)
    case sessionOwnedByMultiplePlans(sessionID: UUID)
    case ambiguousActiveSeason(profileID: UUID, planID: UUID)
    case ambiguousMetadata(planID: UUID)
    case ambiguousPrimaryEvent(seasonID: UUID)
}

/// Stage-D compatibility adapter for plans that predate the running-domain sidecars.
///
/// The pass owns a fresh, no-autosave context and saves exactly once. It never regenerates or edits
/// a `TrainingPlan`, never changes a `PlannedSession`, and never creates a decision record: opening an
/// old plan is not a new coaching decision. Backfill-owned records are identifiable by
/// `backfillVersion`; domain-authored seasons and retained decision history are left alone.
enum RunningPlanBackfill {
    static let currentVersion = 1

    struct Report: Equatable, Sendable {
        var createdSeasons = 0
        var updatedSeasons = 0
        var createdEvents = 0
        var updatedEvents = 0
        var createdMetadata = 0
        var updatedMetadata = 0
        var createdIntents = 0
        var updatedIntents = 0
        var removedOrphans = 0
        var didSave = false
    }

    /// `beforeSave` is an internal failure-injection seam. Production callers leave it nil; tests use
    /// it to prove rollback without needing to corrupt a real SQLite store.
    @MainActor
    static func repair(in container: ModelContainer,
                       now: Date = Date(),
                       calendar: Calendar = .current,
                       beforeSave: (() throws -> Void)? = nil) throws -> Report {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            return try repair(
                in: context,
                now: now,
                calendar: calendar,
                shouldSave: true,
                beforeSave: beforeSave
            )
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Immediate compatibility repair for the still-live legacy create/adjust path. That path may
    /// save a replacement `TrainingPlan` before its sidecars exist; finish the operation in the same
    /// user action instead of waiting for the next launch's deferred maintenance pass.
    @MainActor
    static func repairAfterLegacyPlanMutation(in context: ModelContext,
                                              now: Date = Date(),
                                              calendar: Calendar = .current) throws -> Report {
        let previousAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = previousAutosave }
        do {
            return try repair(
                in: context,
                now: now,
                calendar: calendar,
                shouldSave: true,
                beforeSave: nil
            )
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Mutates compatibility sidecars without saving. Replacement flows call this only after they
    /// have disabled autosave, then include these changes in the same final save as the new plan.
    /// The caller owns rollback; keeping that ownership outside this helper is what makes a plan,
    /// its season pointer, metadata, and intents one transaction instead of a chain of best-effort
    /// writes.
    @MainActor
    static func prepareAfterLegacyPlanMutation(in context: ModelContext,
                                               now: Date = Date(),
                                               calendar: Calendar = .current) throws -> Report {
        try repair(
            in: context,
            now: now,
            calendar: calendar,
            shouldSave: false,
            beforeSave: nil
        )
    }

    fileprivate static func repair(in context: ModelContext,
                                   now: Date,
                                   calendar: Calendar,
                                   shouldSave: Bool,
                                   beforeSave: (() throws -> Void)?) throws -> Report {
        let profiles = try context.fetch(FetchDescriptor<UserProfile>())
        let plans = try context.fetch(FetchDescriptor<TrainingPlan>())
        let sessions = try context.fetch(FetchDescriptor<PlannedSession>())
        var seasons = try context.fetch(FetchDescriptor<RunningSeasonRecord>())
        var events = try context.fetch(FetchDescriptor<RunningEventRecord>())
        var metadata = try context.fetch(FetchDescriptor<PlanMetadataRecord>())
        var intents = try context.fetch(FetchDescriptor<PlannedSessionIntentRecord>())

        try requireUnique(profiles.map(\UserProfile.id), entity: "UserProfile")
        try requireUnique(plans.map(\TrainingPlan.id), entity: "TrainingPlan")
        try requireUnique(sessions.map(\PlannedSession.id), entity: "PlannedSession")

        let profileIDs = Set(profiles.map(\UserProfile.id))
        var profileIDByCurrentPlanID: [UUID: UUID] = [:]
        for profile in profiles {
            guard let plan = profile.plan else { continue }
            if let owner = profileIDByCurrentPlanID[plan.id], owner != profile.id {
                throw RunningPlanBackfillError.planOwnedByMultipleProfiles(planID: plan.id)
            }
            profileIDByCurrentPlanID[plan.id] = profile.id
        }

        var planIDBySessionID: [UUID: UUID] = [:]
        for plan in plans {
            var seenInPlan = Set<UUID>()
            for session in plan.sessions {
                guard seenInPlan.insert(session.id).inserted else {
                    throw RunningPlanBackfillError.sessionOwnedByMultiplePlans(sessionID: session.id)
                }
                if let owner = planIDBySessionID[session.id], owner != plan.id {
                    throw RunningPlanBackfillError.sessionOwnedByMultiplePlans(sessionID: session.id)
                }
                planIDBySessionID[session.id] = plan.id
            }
        }

        var report = Report()
        var changed = false

        // A season with no athlete cannot be recovered by a scalar-ID adapter. Delete its dependent
        // sidecars in the final sweep, but retain PlanDecisionRecord rows until explicit data deletion.
        let invalidSeasonIDs = Set(seasons.lazy.filter { !profileIDs.contains($0.profileID) }.map(\RunningSeasonRecord.id))
        for season in seasons where invalidSeasonIDs.contains(season.id) {
            context.delete(season)
            report.removedOrphans += 1
            changed = true
        }
        seasons.removeAll { invalidSeasonIDs.contains($0.id) }

        for profile in profiles.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard let plan = profile.plan else { continue }

            let validMetadata = metadata.filter { record in
                guard record.id == plan.id, record.planID == plan.id,
                      let season = seasons.first(where: { $0.id == record.seasonID }) else { return false }
                return season.profileID == profile.id
            }
            guard validMetadata.count <= 1 else {
                throw RunningPlanBackfillError.ambiguousMetadata(planID: plan.id)
            }
            let existingMetadata = validMetadata.first

            let activeMatches = seasons.filter {
                $0.profileID == profile.id && $0.activePlanID == plan.id
            }
            guard activeMatches.count <= 1 else {
                throw RunningPlanBackfillError.ambiguousActiveSeason(
                    profileID: profile.id,
                    planID: plan.id
                )
            }

            let season: RunningSeasonRecord
            var seasonWasCreated = false
            if let existingMetadata,
               let linked = seasons.first(where: { $0.id == existingMetadata.seasonID }) {
                season = linked
            } else if let active = activeMatches.first {
                season = active
            } else {
                let priorBackfills = seasons.filter {
                    $0.profileID == profile.id && $0.backfillVersion > 0
                }
                guard priorBackfills.count <= 1 else {
                    throw RunningPlanBackfillError.ambiguousActiveSeason(
                        profileID: profile.id,
                        planID: plan.id
                    )
                }
                if let prior = priorBackfills.first {
                    season = prior
                } else {
                    let newSeason = RunningSeasonRecord(
                        id: unusedSeasonID(preferred: profile.id, seasons: seasons),
                        profileID: profile.id,
                        activePlanID: plan.id,
                        name: plan.name,
                        createdAt: plan.createdAt,
                        updatedAt: plan.createdAt,
                        statusRaw: RunningSeasonStatus.active.rawValue,
                        primaryOutcomeRaw: primaryOutcome(for: profile).rawValue,
                        motivationRaws: motivations(for: profile).map(\RunningMotivation.rawValue),
                        backfillVersion: currentVersion
                    )
                    context.insert(newSeason)
                    seasons.append(newSeason)
                    report.createdSeasons += 1
                    changed = true
                    seasonWasCreated = true
                    season = newSeason
                }
            }

            let legacyOwned = existingMetadata?.isLegacyBackfill ?? true
            if legacyOwned && season.backfillVersion > 0 {
                var seasonChanged = false
                seasonChanged = assign(season, \.activePlanID, plan.id) || seasonChanged
                seasonChanged = assign(season, \.statusRaw, RunningSeasonStatus.active.rawValue) || seasonChanged
                seasonChanged = assign(season, \.primaryOutcomeRaw, primaryOutcome(for: profile).rawValue) || seasonChanged
                seasonChanged = assign(
                    season,
                    \.motivationRaws,
                    motivations(for: profile).map(\RunningMotivation.rawValue)
                ) || seasonChanged
                seasonChanged = assign(season, \.backfillVersion, currentVersion) || seasonChanged

                // An empty legacy plan name is ambiguous (old unnamed plan vs. post-race reset). Never
                // erase a stable season name during maintenance; explicit edits use the command path.
                let legacyName = plan.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !legacyName.isEmpty || season.name.isEmpty {
                    seasonChanged = assign(season, \.name, legacyName) || seasonChanged
                }
                if seasonChanged {
                    _ = assign(season, \.updatedAt, now)
                    if !seasonWasCreated { report.updatedSeasons += 1 }
                    changed = true
                }
            }

            if legacyOwned && season.backfillVersion > 0,
               let raceDate = profile.raceDate ?? plan.raceDate {
                let primaryEvents = events.filter {
                    $0.seasonID == season.id
                        && $0.priorityRaw == RunningEventPriority.a.rawValue
                        && $0.statusRaw == RunningEventStatus.planned.rawValue
                }
                guard primaryEvents.count <= 1 else {
                    throw RunningPlanBackfillError.ambiguousPrimaryEvent(seasonID: season.id)
                }
                let event: RunningEventRecord
                var eventWasCreated = false
                if let existing = primaryEvents.first {
                    event = existing
                } else {
                    let newEvent = RunningEventRecord(
                        id: unusedEventID(preferred: season.id, events: events),
                        seasonID: season.id,
                        name: season.name,
                        date: raceDate,
                        distanceM: positiveFinite(profile.raceDistanceM),
                        durationS: positiveFinite(profile.goalFinishTimeS),
                        priorityRaw: RunningEventPriority.a.rawValue,
                        surfaceRaw: RunningEventSurface.road.rawValue
                    )
                    context.insert(newEvent)
                    events.append(newEvent)
                    report.createdEvents += 1
                    changed = true
                    eventWasCreated = true
                    event = newEvent
                }

                var eventChanged = false
                let eventName = plan.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !eventName.isEmpty || event.name.isEmpty {
                    eventChanged = assign(event, \.name, eventName) || eventChanged
                }
                eventChanged = assign(event, \.date, raceDate) || eventChanged
                eventChanged = assign(event, \.distanceM, positiveFinite(profile.raceDistanceM)) || eventChanged
                eventChanged = assign(event, \.durationS, positiveFinite(profile.goalFinishTimeS)) || eventChanged
                eventChanged = assign(event, \.priorityRaw, RunningEventPriority.a.rawValue) || eventChanged
                eventChanged = assign(event, \.surfaceRaw, RunningEventSurface.road.rawValue) || eventChanged
                eventChanged = assign(event, \.statusRaw, RunningEventStatus.planned.rawValue) || eventChanged
                if eventChanged {
                    if !eventWasCreated { report.updatedEvents += 1 }
                    changed = true
                }
            }

            let digest = try persistedSemanticDigest(for: plan, calendar: calendar)
            let planMetadata: PlanMetadataRecord
            if let existingMetadata {
                planMetadata = existingMetadata
                if existingMetadata.isLegacyBackfill {
                    var metadataChanged = false
                    metadataChanged = assign(planMetadata, \.seasonID, season.id) || metadataChanged
                    metadataChanged = assign(planMetadata, \.plannerVersion, LegacyPlanReplay.currentPlannerVersion) || metadataChanged
                    metadataChanged = assign(planMetadata, \.rulesetID, PlanningRequest.legacyRulesetID) || metadataChanged
                    metadataChanged = assign(
                        planMetadata,
                        \.policyIDRaw,
                        plan.isSelfCoached ? nil : RunningPolicyID.legacyRoadV1.rawValue
                    ) || metadataChanged
                    metadataChanged = assign(planMetadata, \.semanticDigest, digest) || metadataChanged
                    if metadataChanged {
                        report.updatedMetadata += 1
                        changed = true
                    }
                }
            } else {
                let newMetadata = PlanMetadataRecord(
                    planID: plan.id,
                    seasonID: season.id,
                    requestID: nil,
                    plannerVersion: LegacyPlanReplay.currentPlannerVersion,
                    rulesetID: PlanningRequest.legacyRulesetID,
                    policyIDRaw: plan.isSelfCoached ? nil : RunningPolicyID.legacyRoadV1.rawValue,
                    semanticDigest: digest,
                    createdAt: plan.createdAt,
                    isLegacyBackfill: true
                )
                context.insert(newMetadata)
                metadata.append(newMetadata)
                report.createdMetadata += 1
                changed = true
                planMetadata = newMetadata
            }

            guard planMetadata.isLegacyBackfill else { continue }
            let anchor = planAnchor(plan, calendar: calendar)
            for session in plan.sessions.sorted(by: sessionOrder) {
                let projection = try intentProjection(
                    session,
                    plan: plan,
                    seasonID: season.id,
                    anchor: anchor,
                    profile: profile,
                    calendar: calendar
                )
                let matches = intents.filter { $0.plannedSessionID == session.id }
                guard matches.count <= 1 else {
                    throw RunningPlanBackfillError.duplicateIdentifier(
                        entity: "PlannedSessionIntentRecord.plannedSessionID",
                        id: session.id
                    )
                }
                if let record = matches.first {
                    if apply(projection, to: record) {
                        report.updatedIntents += 1
                        changed = true
                    }
                } else {
                    let record = projection.record(createdAt: plan.createdAt)
                    context.insert(record)
                    intents.append(record)
                    report.createdIntents += 1
                    changed = true
                }
            }
        }

        // Remove dangling scalar references after current legacy plans have had a chance to adopt a
        // carried completed session's existing intent. Decision rows are deliberately absent here.
        let livingSeasonByID = Dictionary(
            seasons.filter { profileIDs.contains($0.profileID) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let currentPlanIDs = Set(profileIDByCurrentPlanID.keys)
        let currentMetadataByPlanID = Dictionary(
            metadata.filter { record in
                currentPlanIDs.contains(record.planID)
                    && record.id == record.planID
                    && livingSeasonByID[record.seasonID] != nil
            }.map { ($0.planID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for event in events where livingSeasonByID[event.seasonID] == nil {
            context.delete(event)
            report.removedOrphans += 1
            changed = true
        }
        for record in metadata {
            guard let ownerID = profileIDByCurrentPlanID[record.planID],
                  record.id == record.planID,
                  let season = livingSeasonByID[record.seasonID],
                  season.profileID == ownerID else {
                context.delete(record)
                report.removedOrphans += 1
                changed = true
                continue
            }
        }
        for record in intents {
            guard let planID = planIDBySessionID[record.plannedSessionID],
                  currentPlanIDs.contains(planID),
                  record.planID == planID,
                  let ownerID = profileIDByCurrentPlanID[planID],
                  let season = livingSeasonByID[record.seasonID],
                  season.profileID == ownerID,
                  currentMetadataByPlanID[planID]?.seasonID == record.seasonID else {
                context.delete(record)
                report.removedOrphans += 1
                changed = true
                continue
            }
        }

        // Clear only dangling active-plan pointers. Seasons and their events intentionally outlive a
        // replaceable plan, including the post-race recovery chapter.
        for season in seasons where profileIDs.contains(season.profileID) {
            guard let activePlanID = season.activePlanID,
                  profileIDByCurrentPlanID[activePlanID] != season.profileID else { continue }
            _ = assign(season, \.activePlanID, nil)
            _ = assign(season, \.updatedAt, now)
            if season.backfillVersion > 0 { report.updatedSeasons += 1 }
            changed = true
        }

        guard changed, shouldSave else { return report }
        try beforeSave?()
        try context.save()
        report.didSave = true
        return report
    }

    /// Candidate replacement preserves completed sessions even when a legacy plan has not yet had
    /// its deferred compatibility pass. Reuse the exact backfill projection so the carried session
    /// receives the same stable intent ID and meaning it would have received at launch.
    static func compatibilityIntentRecord(for session: PlannedSession,
                                          sourcePlan: TrainingPlan,
                                          targetPlanID: UUID,
                                          seasonID: UUID,
                                          anchor: Date,
                                          profile: UserProfile,
                                          calendar: Calendar,
                                          createdAt: Date) throws -> PlannedSessionIntentRecord {
        let projection = try intentProjection(
            session,
            plan: sourcePlan,
            seasonID: seasonID,
            anchor: anchor,
            profile: profile,
            calendar: calendar
        )
        let record = projection.record(createdAt: createdAt)
        record.planID = targetPlanID
        return record
    }
}

/// Runs the compatibility pass on SwiftData's dedicated serial model executor. A large legacy store
/// must never make the app miss its first frame (or the test host miss its bootstrap deadline).
@ModelActor
actor RunningPlanBackfillWorker {
    func repair(now: Date = Date(), calendar: Calendar = .current) throws -> RunningPlanBackfill.Report {
        try RunningPlanBackfill.repair(
            in: modelContext,
            now: now,
            calendar: calendar,
            shouldSave: true,
            beforeSave: nil
        )
    }
}

// MARK: - Stable legacy projections

extension RunningPlanBackfill {
    /// Stable value projection shared with the atomic plan store. The implementation remains
    /// file-private so only this narrow replay surface crosses the backfill boundary.
    static func persistedSemanticSnapshot(for plan: TrainingPlan,
                                           calendar: Calendar) -> PlanSemanticSnapshot {
        makePersistedSemanticSnapshot(for: plan, calendar: calendar)
    }

    struct IntentProjection {
        let id: String
        let plannedSessionID: UUID
        let planID: UUID
        let seasonID: UUID
        let intentVersion: Int
        let weekIndex: Int
        let dayOffset: Int
        let stimulusRaw: String
        let sessionClassRaw: String
        let progressionLevel: Int
        let hardClassRaw: String
        let primaryTargetRaw: String
        let fallbackTargetRaws: [String]
        let workDistanceM: Double?
        let workDurationS: Double?
        let workPaceSPerKm: Double?
        let intervalPrescription: String?
        let strengthTargetsJSON: Data
        let recoveryDistanceM: Double?
        let recoveryDurationS: Double?
        let recoveryModeRaw: String?
        let successLower: Double?
        let successUpper: Double?
        let recoveryCostRaw: String
        let validSubstitutionIDs: [String]
        let minimumCompletedExposures: Int
        let minimumConfidenceRaw: String
        let purpose: String
        let ruleIDRaws: [String]
        let limitationRaws: [String]

        func record(createdAt: Date) -> PlannedSessionIntentRecord {
            PlannedSessionIntentRecord(
                id: id,
                plannedSessionID: plannedSessionID,
                planID: planID,
                seasonID: seasonID,
                intentVersion: intentVersion,
                weekIndex: weekIndex,
                dayOffset: dayOffset,
                stimulusRaw: stimulusRaw,
                sessionClassRaw: sessionClassRaw,
                progressionLevel: progressionLevel,
                hardClassRaw: hardClassRaw,
                primaryTargetRaw: primaryTargetRaw,
                fallbackTargetRaws: fallbackTargetRaws,
                workDistanceM: workDistanceM,
                workDurationS: workDurationS,
                workPaceSPerKm: workPaceSPerKm,
                intervalPrescription: intervalPrescription,
                strengthTargetsJSON: strengthTargetsJSON,
                recoveryDistanceM: recoveryDistanceM,
                recoveryDurationS: recoveryDurationS,
                recoveryModeRaw: recoveryModeRaw,
                successLower: successLower,
                successUpper: successUpper,
                recoveryCostRaw: recoveryCostRaw,
                validSubstitutionIDs: validSubstitutionIDs,
                minimumCompletedExposures: minimumCompletedExposures,
                minimumConfidenceRaw: minimumConfidenceRaw,
                purpose: purpose,
                ruleIDRaws: ruleIDRaws,
                limitationRaws: limitationRaws,
                createdAt: createdAt
            )
        }
    }

    static func intentProjection(_ session: PlannedSession,
                                 plan: TrainingPlan,
                                 seasonID: UUID,
                                 anchor: Date,
                                 profile: UserProfile,
                                 calendar: Calendar) throws -> IntentProjection {
        let offset = calendar.dateComponents(
            [.day],
            from: anchor,
            to: calendar.startOfDay(for: session.date)
        ).day ?? 0
        let weekIndex = floorDiv(offset, by: 7)
        let dayOffset = positiveModulo(offset, 7)
        let sessionClass = sessionClass(session)
        let hardLower = isHardLowerStrength(session)
        let hardRun = session.runType?.isQuality == true
        let targetHierarchy = targetHierarchy(session)
        var rules: Set<RunningRuleID>
        var limitations: Set<RunningEvidenceLimitation> = [.legacyAggregate]
        if plan.isSelfCoached {
            rules = [.selfCoachedBoundary]
        } else if session.discipline == .strength {
            rules = [.calendarScheduling, .strengthSupport]
        } else {
            rules = [.calendarScheduling, .displayRounding, .paceCalibration]
            if session.runType == .long || session.runType == .progression { rules.insert(.longRunDose) }
            if hardRun { rules.formUnion([.qualityDose, .intensityDistribution]) }
            if session.runType == .race { rules.insert(.raceTerminal) }
        }
        if session.intervals != nil { limitations.insert(.unstructuredLegacyInterval) }
        if ExperienceLevel(rawValue: profile.experience[Discipline.running.rawValue] ?? "") == .new {
            rules.insert(.returnProgression)
            limitations.insert(.noProgressionGate)
        }

        let generatedExercises = session.strengthTargets.sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return (lhs.exercise?.name ?? "") < (rhs.exercise?.name ?? "")
        }.map {
            GeneratedExercise(
                exerciseName: $0.exercise?.name ?? "",
                targetSets: $0.targetSets,
                repLow: $0.targetRepLow,
                repHigh: $0.targetRepHigh,
                targetRPE: $0.targetRPE,
                targetPctRM: $0.targetPctRM,
                progression: $0.progression
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let strengthJSON = try encoder.encode(generatedExercises.map(RunningStrengthTarget.init))

        return IntentProjection(
            id: "legacy-backfill-v1:\(session.id.uuidString.lowercased())",
            plannedSessionID: session.id,
            planID: plan.id,
            seasonID: seasonID,
            intentVersion: 1,
            weekIndex: weekIndex,
            dayOffset: dayOffset,
            stimulusRaw: stimulus(session).rawValue,
            sessionClassRaw: sessionClass.rawValue,
            progressionLevel: max(0, weekIndex),
            hardClassRaw: hardLower ? RunningHardClass.hardLowerBodyStrength.rawValue
                : hardRun ? RunningHardClass.hardRun.rawValue : RunningHardClass.none.rawValue,
            primaryTargetRaw: targetHierarchy.primary.rawValue,
            fallbackTargetRaws: targetHierarchy.fallbacks.map(\RunningTargetKind.rawValue),
            workDistanceM: session.targetDistanceM,
            workDurationS: session.targetDurationS,
            workPaceSPerKm: session.targetPaceSPerKm,
            intervalPrescription: normalized(session.intervals),
            strengthTargetsJSON: strengthJSON,
            recoveryDistanceM: nil,
            recoveryDurationS: nil,
            recoveryModeRaw: nil,
            successLower: nil,
            successUpper: nil,
            recoveryCostRaw: hardLower || hardRun ? RunningRecoveryCostBand.high.rawValue
                : sessionClass == .long ? RunningRecoveryCostBand.moderate.rawValue
                : RunningRecoveryCostBand.low.rawValue,
            validSubstitutionIDs: [],
            minimumCompletedExposures: 0,
            minimumConfidenceRaw: RunningEvidenceConfidence.unknown.rawValue,
            purpose: purpose(session, selfCoached: plan.isSelfCoached),
            ruleIDRaws: rules.map(\RunningRuleID.rawValue).sorted(),
            limitationRaws: limitations.map(\RunningEvidenceLimitation.rawValue).sorted()
        )
    }

    static func apply(_ value: IntentProjection, to record: PlannedSessionIntentRecord) -> Bool {
        var changed = false
        changed = assign(record, \.planID, value.planID) || changed
        changed = assign(record, \.seasonID, value.seasonID) || changed
        changed = assign(record, \.intentVersion, value.intentVersion) || changed
        changed = assign(record, \.weekIndex, value.weekIndex) || changed
        changed = assign(record, \.dayOffset, value.dayOffset) || changed
        changed = assign(record, \.stimulusRaw, value.stimulusRaw) || changed
        changed = assign(record, \.sessionClassRaw, value.sessionClassRaw) || changed
        changed = assign(record, \.progressionLevel, value.progressionLevel) || changed
        changed = assign(record, \.hardClassRaw, value.hardClassRaw) || changed
        changed = assign(record, \.primaryTargetRaw, value.primaryTargetRaw) || changed
        changed = assign(record, \.fallbackTargetRaws, value.fallbackTargetRaws) || changed
        changed = assign(record, \.workDistanceM, value.workDistanceM) || changed
        changed = assign(record, \.workDurationS, value.workDurationS) || changed
        changed = assign(record, \.workPaceSPerKm, value.workPaceSPerKm) || changed
        changed = assign(record, \.intervalPrescription, value.intervalPrescription) || changed
        changed = assign(record, \.strengthTargetsJSON, value.strengthTargetsJSON) || changed
        changed = assign(record, \.recoveryDistanceM, value.recoveryDistanceM) || changed
        changed = assign(record, \.recoveryDurationS, value.recoveryDurationS) || changed
        changed = assign(record, \.recoveryModeRaw, value.recoveryModeRaw) || changed
        changed = assign(record, \.successLower, value.successLower) || changed
        changed = assign(record, \.successUpper, value.successUpper) || changed
        changed = assign(record, \.recoveryCostRaw, value.recoveryCostRaw) || changed
        changed = assign(record, \.validSubstitutionIDs, value.validSubstitutionIDs) || changed
        changed = assign(record, \.minimumCompletedExposures, value.minimumCompletedExposures) || changed
        changed = assign(record, \.minimumConfidenceRaw, value.minimumConfidenceRaw) || changed
        changed = assign(record, \.purpose, value.purpose) || changed
        changed = assign(record, \.ruleIDRaws, value.ruleIDRaws) || changed
        changed = assign(record, \.limitationRaws, value.limitationRaws) || changed
        return changed
    }
}

// MARK: - Legacy meaning and digest

private extension RunningPlanBackfill {
    static func primaryOutcome(for profile: UserProfile) -> RunningPrimaryOutcome {
        if profile.goal == .raceDistance {
            return positiveFinite(profile.goalFinishTimeS) == nil ? .finish : .targetTime
        }
        let experience = ExperienceLevel(
            rawValue: profile.experience[Discipline.running.rawValue] ?? ""
        ) ?? .some
        return experience == .new ? .returnToRunning : .buildBase
    }

    static func motivations(for profile: UserProfile) -> [RunningMotivation] {
        var result = Set<RunningMotivation>()
        switch profile.goal {
        case .raceDistance, .endurance, .getStronger:
            result.insert(.performance)
        case .stayConsistent:
            result.insert(.consistency)
        case .loseFat, .buildMuscle:
            result.insert(.bodyComposition)
        case .generalFitness:
            result.insert(.health)
        }
        switch profile.reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "clear head", "me-time", "stress": result.insert(.stress)
        case "look better", "body composition": result.insert(.bodyComposition)
        case "compete", "performance": result.insert(.performance)
        case "consistency": result.insert(.consistency)
        case "confidence": result.insert(.confidence)
        default: result.insert(.health)
        }
        return result.sorted { $0.rawValue < $1.rawValue }
    }

    static func makePersistedSemanticSnapshot(for plan: TrainingPlan,
                                              calendar: Calendar) -> PlanSemanticSnapshot {
        let anchor = planAnchor(plan, calendar: calendar)
        var grouped: [Int: [PlannedSession]] = [:]
        for session in plan.sessions {
            let days = calendar.dateComponents(
                [.day],
                from: anchor,
                to: calendar.startOfDay(for: session.date)
            ).day ?? 0
            grouped[floorDiv(days, by: 7), default: []].append(session)
        }
        var weekIndexes = Set(grouped.keys)
        weekIndexes.formUnion(plan.weekPhases.indices)
        let weeks = weekIndexes.sorted().map { index -> GeneratedWeek in
            let phase = plan.weekPhases.indices.contains(index)
                ? (PlanPhase(rawValue: plan.weekPhases[index]) ?? .build)
                : .build
            let generatedSessions = (grouped[index] ?? []).sorted(by: sessionOrder).map { session in
                let days = calendar.dateComponents(
                    [.day],
                    from: anchor,
                    to: calendar.startOfDay(for: session.date)
                ).day ?? 0
                return GeneratedSession(
                    dayOffset: positiveModulo(days, 7),
                    discipline: session.discipline,
                    runType: session.runType,
                    targetDistanceM: session.targetDistanceM,
                    targetDurationS: session.targetDurationS,
                    targetPaceSPerKm: session.targetPaceSPerKm,
                    intervals: normalized(session.intervals),
                    strengthLabel: normalized(session.strengthLabel),
                    strengthTargets: session.strengthTargets.sorted {
                        if $0.order != $1.order { return $0.order < $1.order }
                        return ($0.exercise?.name ?? "") < ($1.exercise?.name ?? "")
                    }.map {
                        GeneratedExercise(
                            exerciseName: $0.exercise?.name ?? "",
                            targetSets: $0.targetSets,
                            repLow: $0.targetRepLow,
                            repHigh: $0.targetRepHigh,
                            targetRPE: $0.targetRPE,
                            targetPctRM: $0.targetPctRM,
                            progression: $0.progression
                        )
                    },
                    rationale: nil,
                    isHardLowerLift: isHardLowerStrength(session),
                    isHardRun: session.runType?.isQuality == true
                )
            }
            return GeneratedWeek(
                index: index,
                isDeload: phase == .recovery,
                isTaper: phase == .taper,
                phase: phase,
                sessions: generatedSessions
            )
        }
        return GeneratedPlan(
            p5kSPerKm: plan.p5kSPerKm,
            goalRacePaceSPerKm: plan.goalRacePaceSPerKm,
            weeks: weeks
        ).semanticSnapshot()
    }

    static func persistedSemanticDigest(for plan: TrainingPlan, calendar: Calendar) throws -> String {
        try persistedSemanticSnapshot(for: plan, calendar: calendar).digest().description
    }

    static func stimulus(_ session: PlannedSession) -> RunningStimulus {
        if session.discipline == .strength { return .strengthSupport }
        guard session.discipline == .running else { return .aerobicEndurance }
        switch session.runType {
        case .easy, .freeRun, nil: return .aerobicEndurance
        case .long: return .longEndurance
        case .recovery: return .recovery
        case .tempo: return .threshold
        case .intervals:
            let text = session.intervals?.lowercased() ?? ""
            if text.contains("threshold") { return .threshold }
            if text.contains("race pace") { return .raceSpecific }
            return .vo2
        case .race: return .competition
        case .fartlek, .strides: return .speedNeuromuscular
        case .hills: return .hillStrength
        case .progression: return .progression
        }
    }

    static func sessionClass(_ session: PlannedSession) -> RunningIntentSessionClass {
        if session.discipline == .strength { return .strength }
        if session.discipline != .running { return .crossTraining }
        if session.runType == .race { return .race }
        if session.runType == .long || session.runType == .progression { return .long }
        if session.runType?.isQuality == true { return .quality }
        return .easy
    }

    static func targetHierarchy(_ session: PlannedSession) -> RunningTargetHierarchy {
        if session.discipline == .strength {
            return RunningTargetHierarchy(primary: .strengthPrescription)
        }
        if session.intervals != nil {
            return RunningTargetHierarchy(primary: .intervalStructure, fallbacks: [.effort])
        }
        if session.targetDistanceM != nil {
            var fallbacks: [RunningTargetKind] = []
            if session.targetDurationS != nil { fallbacks.append(.duration) }
            if session.targetPaceSPerKm != nil { fallbacks.append(.pace) }
            fallbacks.append(.effort)
            return RunningTargetHierarchy(primary: .distance, fallbacks: fallbacks)
        }
        if session.targetDurationS != nil {
            return RunningTargetHierarchy(primary: .duration, fallbacks: [.effort])
        }
        return RunningTargetHierarchy(primary: .completion, fallbacks: [.effort])
    }

    static func purpose(_ session: PlannedSession, selfCoached: Bool) -> String {
        if selfCoached { return "Athlete-authored session; Momentum will not rewrite its targets." }
        if session.discipline == .strength {
            return "Support running with a recovery-spaced strength dose."
        }
        if session.discipline != .running {
            return "Keep supporting movement inside the runner's chosen week."
        }
        return switch session.runType {
        case .long: "Extend aerobic endurance without turning the session into a race."
        case .progression: "Practice finishing with controlled pace after accumulated easy running."
        case .tempo: "Accumulate controlled threshold-oriented work."
        case .intervals: "Accumulate a bounded faster-running dose with recovery between efforts."
        case .fartlek: "Introduce flexible faster running inside an otherwise controlled session."
        case .hills: "Build running-specific force on an appropriate incline."
        case .strides: "Practice short relaxed speed with low total dose."
        case .recovery: "Maintain gentle movement while protecting recovery."
        case .race: "Execute the named primary event."
        case .easy, .freeRun, nil: "Build repeatable aerobic volume at an easy effort."
        }
    }

    static func isHardLowerStrength(_ session: PlannedSession) -> Bool {
        guard session.discipline == .strength else { return false }
        if ["Lower", "Legs", "Full Body"].contains(session.strengthLabel ?? "") { return true }
        let lower: Set<String> = [
            MuscleGroup.quads.rawValue,
            MuscleGroup.hamstrings.rawValue,
            MuscleGroup.glutes.rawValue,
            MuscleGroup.calves.rawValue,
        ]
        return session.strengthTargets.contains { target in
            !lower.isDisjoint(with: Set(target.exercise?.primaryMuscles ?? []))
        }
    }
}

// MARK: - Small deterministic helpers

private extension RunningPlanBackfill {
    static func requireUnique(_ ids: [UUID], entity: String) throws {
        var seen = Set<UUID>()
        for id in ids where !seen.insert(id).inserted {
            throw RunningPlanBackfillError.duplicateIdentifier(entity: entity, id: id)
        }
    }

    static func unusedSeasonID(preferred: UUID,
                               seasons: [RunningSeasonRecord]) -> UUID {
        let ids = Set(seasons.map(\RunningSeasonRecord.id))
        return ids.contains(preferred) ? UUID() : preferred
    }

    static func unusedEventID(preferred: UUID,
                              events: [RunningEventRecord]) -> UUID {
        let ids = Set(events.map(\RunningEventRecord.id))
        return ids.contains(preferred) ? UUID() : preferred
    }

    static func planAnchor(_ plan: TrainingPlan, calendar: Calendar) -> Date {
        if let blockStart = plan.blockStart { return calendar.startOfDay(for: blockStart) }
        if let first = plan.sessions.map(\PlannedSession.date).min(),
           let week = calendar.dateInterval(of: .weekOfYear, for: first) {
            return week.start
        }
        return calendar.startOfDay(for: plan.createdAt)
    }

    static func floorDiv(_ value: Int, by divisor: Int) -> Int {
        precondition(divisor > 0)
        return value >= 0 ? value / divisor : -((-value + divisor - 1) / divisor)
    }

    static func positiveModulo(_ value: Int, _ divisor: Int) -> Int {
        ((value % divisor) + divisor) % divisor
    }

    static func positiveFinite(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return result.isEmpty ? nil : result
    }

    static func sessionOrder(_ lhs: PlannedSession, _ rhs: PlannedSession) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    @discardableResult
    static func assign<Root: AnyObject, Value: Equatable>(
        _ root: Root,
        _ keyPath: ReferenceWritableKeyPath<Root, Value>,
        _ value: Value
    ) -> Bool {
        guard root[keyPath: keyPath] != value else { return false }
        root[keyPath: keyPath] = value
        return true
    }
}
