import CryptoKit
import Foundation
import SwiftData

enum PlanStoreError: Error, Equatable {
    case profileNotFound(UUID)
    case duplicateProfile(UUID)
    case shadowRequestCannotCommit
    case requestMismatch(String)
    case invalidCandidate(String)
    case staleCurrentPlan(expected: UUID?, actual: UUID?)
    case staleCurrentPlanSnapshot
    case selfCoachedPlanProtected(UUID)
    case unsupportedCrossTraining
    case invalidCalendar
    case carryoverMismatch(expected: [UUID], actual: [UUID])
    case duplicateSessionID(UUID)
    case brokenWorkoutLink(UUID)
    case intentMismatch(String)
    case duplicateExerciseName(String)
    case missingExercise(String)
    case identifierCollision(entity: String, id: String)
    case ambiguousMetadata(UUID)
    case ambiguousIntent(UUID)
    case ambiguousDecision(UUID)
    case corruptCommittedRequest(UUID)
    case invalidSessionDate(String)
}

/// Candidate-first persistence boundary. Generation and validation happen before this type receives
/// a value. The commit itself is synchronous on the supplied context: it never suspends while the
/// graph is being changed, points the profile directly from old plan to new, and saves exactly once.
/// Any thrown error rolls the context back and leaves the previously saved plan live.
@MainActor
enum PlanStore {
    struct Commit: Sendable {
        let profileID: UUID
        let request: PlanningRequest
        let candidate: LegacyRoadPlanCandidate
        let configuration: PlanConfigurationCommand
        let blockIndex: Int

        init(profileID: UUID,
             request: PlanningRequest,
             candidate: LegacyRoadPlanCandidate,
             configuration: PlanConfigurationCommand,
             blockIndex: Int = 0) {
            self.profileID = profileID
            self.request = request
            self.candidate = candidate
            self.configuration = configuration
            self.blockIndex = blockIndex
        }
    }

    struct Receipt: Equatable, Sendable {
        let requestID: UUID
        let profileID: UUID
        let seasonID: UUID
        let planID: UUID
        /// False means this exact request was already durably committed.
        let didCommit: Bool
    }

    /// Test-only observation/failure seams. Production uses `.none`. The after-swap hook proves the
    /// profile never renders through `nil`; the before-save hook proves every mutation rolls back.
    struct Hooks {
        var afterProfileSwap: ((UserProfile, TrainingPlan?, TrainingPlan) throws -> Void)?
        var beforeSave: (() throws -> Void)?

        @MainActor static let none = Hooks()
    }

    @discardableResult
    static func commit(_ input: Commit,
                       in context: ModelContext,
                       now: Date = Date(),
                       registry: RunningRuleRegistry = .legacyRoadV1,
                       hooks: Hooks = .none) throws -> Receipt {
        let previousAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = previousAutosave }

        do {
            if let receipt = try priorReceipt(for: input, in: context) {
                return receipt
            }

            let calendar: Calendar
            do {
                calendar = try input.request.calendar.value()
            } catch {
                throw PlanStoreError.invalidCalendar
            }
            let profile = try fetchProfile(input.profileID, in: context)
            try validate(input, profile: profile, registry: registry, calendar: calendar)

            let currentPlan = profile.plan
            let currentID = currentPlan?.id
            guard input.request.existingPlan?.id == currentID else {
                throw PlanStoreError.staleCurrentPlan(
                    expected: input.request.existingPlan?.id,
                    actual: currentID
                )
            }
            if let currentPlan {
                try validateCurrentSnapshot(
                    input.request.existingPlan,
                    against: currentPlan,
                    calendar: calendar
                )
                if currentPlan.isSelfCoached,
                   input.request.authority != .athleteRequestedCoaching {
                    throw PlanStoreError.selfCoachedPlanProtected(currentPlan.id)
                }
            }
            guard profile.crossTraining.isEmpty else {
                // The Stage-B value adapter does not yet include PlanService's separately-appended
                // cross-training rows. Fail closed rather than silently deleting them.
                throw PlanStoreError.unsupportedCrossTraining
            }

            let actualCarry = try carryoverIDs(
                currentPlan,
                startDate: input.request.startDate,
                calendar: calendar
            )
            let expectedCarry = input.candidate.carriedCompletedSessionIDs
            guard actualCarry == expectedCarry else {
                throw PlanStoreError.carryoverMismatch(expected: expectedCarry, actual: actualCarry)
            }

            let planID = stableUUID(namespace: input.request.id, label: "committed-plan")
            let decisionID = stableUUID(namespace: input.request.id, label: "decision")
            let allPlans = try context.fetch(FetchDescriptor<TrainingPlan>())
            if allPlans.contains(where: { $0.id == planID }) {
                throw PlanStoreError.identifierCollision(entity: "TrainingPlan", id: planID.uuidString)
            }
            let allSessions = try context.fetch(FetchDescriptor<PlannedSession>())
            try requireUniqueSessionIDs(allSessions)
            let allMetadata = try context.fetch(FetchDescriptor<PlanMetadataRecord>())
            if allMetadata.contains(where: { $0.id == planID || $0.planID == planID }) {
                throw PlanStoreError.identifierCollision(entity: "PlanMetadataRecord", id: planID.uuidString)
            }
            let allIntents = try context.fetch(FetchDescriptor<PlannedSessionIntentRecord>())
            let allDecisions = try context.fetch(FetchDescriptor<PlanDecisionRecord>())
            if allDecisions.contains(where: { $0.id == decisionID }) {
                throw PlanStoreError.identifierCollision(entity: "PlanDecisionRecord", id: decisionID.uuidString)
            }

            let oldMetadata: PlanMetadataRecord? = try {
                guard let currentID else { return nil }
                let matches = allMetadata.filter { $0.planID == currentID || $0.id == currentID }
                guard matches.count <= 1 else { throw PlanStoreError.ambiguousMetadata(currentID) }
                return matches.first
            }()

            let exerciseIndex = try exercisesByName(in: context)
            let generatedPairs = try pairGeneratedSessionsAndIntents(input.candidate)
            let prepared = try makePlan(
                id: planID,
                input: input,
                pairs: generatedPairs,
                exercisesByName: exerciseIndex,
                existingSessionIDs: Set(allSessions.map(\PlannedSession.id)),
                now: now,
                calendar: calendar
            )

            let carriedSources = try carriedSessions(
                ids: expectedCarry,
                from: currentPlan
            )
            let carriedClones = carriedSources.map(cloneCompletedSession)
            prepared.plan.sessions += carriedClones.map(\CarriedClone.clone)

            let candidateIntentIDs = Set(prepared.intentRecords.map(\PlannedSessionIntentRecord.id))
            if let collision = allIntents.first(where: { candidateIntentIDs.contains($0.id) }) {
                throw PlanStoreError.identifierCollision(
                    entity: "PlannedSessionIntentRecord",
                    id: collision.id
                )
            }

            var carriedIntentBySessionID: [UUID: PlannedSessionIntentRecord] = [:]
            for source in carriedSources {
                let matches = allIntents.filter { $0.plannedSessionID == source.id }
                guard matches.count <= 1 else { throw PlanStoreError.ambiguousIntent(source.id) }
                if let existing = matches.first {
                    carriedIntentBySessionID[source.id] = existing
                }
            }

            // All throwable encodes happen before the live graph changes.
            let encoder = sortedEncoder()
            let diffJSON = try encoder.encode(input.candidate.differenceFromExisting)
            let normalizedInputJSON = try encoder.encode(NormalizedCommitInput(input.request))
            let metadata = PlanMetadataRecord(
                planID: planID,
                seasonID: input.candidate.seasonID,
                requestID: input.request.id,
                plannerVersion: input.candidate.plannerVersion,
                rulesetID: input.candidate.rulesetID,
                policyIDRaw: input.candidate.selectedPolicyID.rawValue,
                semanticDigest: input.candidate.semanticDigest.description,
                createdAt: now,
                isLegacyBackfill: false
            )
            let trace = input.candidate.trace
            let decision = PlanDecisionRecord(
                id: decisionID,
                requestID: input.request.id,
                profileID: input.profileID,
                planID: planID,
                seasonID: input.candidate.seasonID,
                decidedAt: now,
                triggerRaw: input.request.trigger.rawValue,
                statusRaw: RunningDecisionStatus.committed.rawValue,
                plannerVersion: input.candidate.plannerVersion,
                rulesetID: input.candidate.rulesetID,
                policyIDRaw: input.candidate.selectedPolicyID.rawValue,
                oldPlanDigest: input.candidate.differenceFromExisting?.oldDigest.description
                    ?? oldMetadata?.semanticDigest,
                newPlanDigest: input.candidate.semanticDigest.description,
                diffJSON: diffJSON,
                appliedRuleIDRaws: trace.appliedRuleIDs.map(\RunningRuleID.rawValue),
                hardConstraintRaws: trace.hardConstraints.map(\RunningHardConstraint.rawValue),
                relaxedPreferenceRaws: trace.relaxedPreferences.map(\RunningRelaxedPreference.rawValue),
                evidenceConfidenceRaws: Array(Set(trace.evidence.map(\RunningEvidenceSummary.confidence.rawValue))).sorted(),
                limitationRaws: trace.evidenceLimitations.map(\RunningEvidenceLimitation.rawValue),
                headline: trace.headline,
                detail: trace.detail,
                normalizedInputJSON: normalizedInputJSON
            )

            // MARK: one no-suspension mutation window

            context.insert(prepared.plan)
            profile.plan = prepared.plan // direct old → new; never through nil
            for carried in carriedClones {
                if let workout = carried.workout {
                    carried.clone.completedWorkout = workout
                    workout.plannedSession = carried.clone
                }
            }
            try hooks.afterProfileSwap?(profile, currentPlan, prepared.plan)

            let configurationResult = try input.configuration.apply(in: context, now: now)
            guard configurationResult.seasonID == input.candidate.seasonID,
                  configurationResult.activePlanID == planID else {
                throw PlanStoreError.requestMismatch("Configuration did not activate the candidate season and plan.")
            }

            for record in prepared.intentRecords { context.insert(record) }
            for source in carriedSources {
                if let existing = carriedIntentBySessionID[source.id] {
                    existing.planID = planID
                    existing.seasonID = input.candidate.seasonID
                } else if let currentPlan {
                    let fallback = try RunningPlanBackfill.compatibilityIntentRecord(
                        for: source,
                        sourcePlan: currentPlan,
                        targetPlanID: planID,
                        seasonID: input.candidate.seasonID,
                        anchor: currentPlan.blockStart ?? currentPlan.createdAt,
                        profile: profile,
                        calendar: calendar,
                        createdAt: now
                    )
                    if candidateIntentIDs.contains(fallback.id)
                        || allIntents.contains(where: { $0.id == fallback.id }) {
                        throw PlanStoreError.identifierCollision(
                            entity: "PlannedSessionIntentRecord",
                            id: fallback.id
                        )
                    }
                    context.insert(fallback)
                }
            }

            if let currentPlan {
                let carriedSet = Set(expectedCarry)
                for record in allIntents where record.planID == currentPlan.id
                    && !carriedSet.contains(record.plannedSessionID) {
                    context.delete(record)
                }
                if let oldMetadata { context.delete(oldMetadata) }
                context.delete(currentPlan)
            }
            context.insert(metadata)
            context.insert(decision)

            try hooks.beforeSave?()
            try context.save() // the sole save in the candidate path

            return Receipt(
                requestID: input.request.id,
                profileID: input.profileID,
                seasonID: input.candidate.seasonID,
                planID: planID,
                didCommit: true
            )
        } catch {
            context.rollback()
            throw error
        }
    }
}

// MARK: - Validation and preparation

@MainActor
private extension PlanStore {
    struct PreparedPlan {
        let plan: TrainingPlan
        let intentRecords: [PlannedSessionIntentRecord]
    }

    struct GeneratedPair {
        let week: GeneratedWeek
        let session: GeneratedSession
        let intent: SessionIntent
    }

    struct CarriedClone {
        let clone: PlannedSession
        let workout: Workout?
    }

    struct NormalizedCommitInput: Codable {
        let version: Int
        let trigger: String
        let authority: String
        let outcome: String
        let hasPrimaryEvent: Bool
        let primaryEventSurface: String?
        let trainingDaysPerWeek: Int
        let includesStrength: Bool
        let restrictionKinds: [String]
        let evidence: [Evidence]

        struct Evidence: Codable {
            let dimension: String
            let source: String
            let confidence: String
            let limitations: [String]
        }

        init(_ request: PlanningRequest) {
            version = 1
            trigger = request.trigger.rawValue
            authority = request.authority.rawValue
            outcome = request.goal.outcome.rawValue
            hasPrimaryEvent = request.season.primaryEvent != nil
            primaryEventSurface = request.season.primaryEvent?.surface.rawValue
            trainingDaysPerWeek = request.availability.trainingDaysPerWeek
            includesStrength = request.legacyBridge?.inputs.disciplines.contains(.strength) == true
            restrictionKinds = request.activeRestrictions.map(\ActiveRunningRestriction.kind.rawValue).sorted()
            evidence = request.athleteState.evidenceSummaries.map {
                Evidence(
                    dimension: $0.dimension,
                    source: $0.source.rawValue,
                    confidence: $0.confidence.rawValue,
                    limitations: $0.limitations.map(\RunningEvidenceLimitation.rawValue).sorted()
                )
            }
        }
    }

    static func priorReceipt(for input: Commit,
                             in context: ModelContext) throws -> Receipt? {
        let rows = try context.fetch(FetchDescriptor<PlanDecisionRecord>())
            .filter { $0.requestID == input.request.id }
        guard rows.count <= 1 else { throw PlanStoreError.ambiguousDecision(input.request.id) }
        guard let row = rows.first else { return nil }
        guard row.profileID == input.profileID,
              row.seasonID == input.candidate.seasonID,
              row.statusRaw == RunningDecisionStatus.committed.rawValue,
              row.plannerVersion == input.candidate.plannerVersion,
              row.rulesetID == input.candidate.rulesetID,
              row.newPlanDigest == input.candidate.semanticDigest.description,
              let planID = row.planID else {
            throw PlanStoreError.corruptCommittedRequest(input.request.id)
        }
        return Receipt(
            requestID: input.request.id,
            profileID: row.profileID,
            seasonID: row.seasonID,
            planID: planID,
            didCommit: false
        )
    }

    static func fetchProfile(_ id: UUID, in context: ModelContext) throws -> UserProfile {
        let profiles = try context.fetch(FetchDescriptor<UserProfile>())
            .filter { $0.id == id }
        guard let profile = profiles.first else { throw PlanStoreError.profileNotFound(id) }
        guard profiles.count == 1 else { throw PlanStoreError.duplicateProfile(id) }
        return profile
    }

    static func validate(_ input: Commit,
                         profile: UserProfile,
                         registry: RunningRuleRegistry,
                         calendar: Calendar) throws {
        let request = input.request
        let candidate = input.candidate
        try input.configuration.preflightValidation()
        guard request.authority != .shadowOnly else {
            throw PlanStoreError.shadowRequestCannotCommit
        }
        guard input.profileID == input.configuration.profileID,
              input.configuration.id == request.id,
              input.configuration.season == request.season,
              input.configuration.planName == candidate.planName,
              candidate.requestID == request.id,
              candidate.seasonID == request.season.id,
              candidate.plannerVersion == request.plannerVersion,
              candidate.rulesetID == request.rulesetID,
              candidate.trace.requestID == request.id,
              candidate.trace.status == .candidate,
              candidate.trace.policyID == candidate.selectedPolicyID else {
            throw PlanStoreError.requestMismatch("Candidate, request, and configuration identities differ.")
        }
        guard registry.rulesetID == candidate.rulesetID,
              registry.validationIssues.isEmpty,
              candidate.trace.unknownRuleIDs(in: registry).isEmpty,
              candidate.sessionIntents.flatMap(\SessionIntent.ruleIDs).allSatisfy({ registry[$0] != nil }) else {
            throw PlanStoreError.invalidCandidate("The compiled ruleset does not cover the candidate trace.")
        }
        guard candidate.validation.isValid,
              candidate.trace.validationCodes.isEmpty,
              candidate.trace.hardConstraints.contains(.validatedBeforeCommit) else {
            throw PlanStoreError.invalidCandidate("Final invariant validation did not pass.")
        }
        let recomputed = try candidate.plan.semanticDigest()
        guard recomputed == candidate.semanticDigest,
              candidate.plan.semanticSnapshot() == candidate.semanticSnapshot else {
            throw PlanStoreError.invalidCandidate("Semantic digest changed after validation.")
        }
        guard let bridge = request.legacyBridge,
              bridge.inputs.goal == input.configuration.legacyGoal,
              sameNumber(request.goal.targetDistanceM, input.configuration.raceDistanceM),
              sameNumber(request.goal.targetDurationS, input.configuration.goalFinishTimeS) else {
            throw PlanStoreError.requestMismatch("Legacy and running-domain goal values differ.")
        }
        // The bridge is the exact input value the deterministic engine evaluated. Reconstruct it
        // from the live profile and fail the draft closed if *any* generation input has moved — not
        // just the three availability fields. This protects discipline, experience, volume,
        // injury, intensity, preferred-day, strength, age, and unit edits made while generation was
        // in flight. Recovery weeks are trigger state rather than a persisted profile field, so the
        // request remains authoritative for that one value.
        var liveInputs = PlanService.planInputs(
            from: profile,
            startDate: request.startDate,
            calendar: calendar
        )
        liveInputs.postRaceRecoveryWeeks = bridge.inputs.postRaceRecoveryWeeks
        guard liveInputs == bridge.inputs else {
            throw PlanStoreError.requestMismatch("Profile planning inputs changed after candidate generation.")
        }
    }

    static func validateCurrentSnapshot(_ expected: ExistingRunningPlanSnapshot?,
                                        against current: TrainingPlan,
                                        calendar: Calendar) throws {
        guard let expected,
              expected.id == current.id,
              expected.name == current.name.trimmingCharacters(in: .whitespacesAndNewlines),
              expected.isSelfCoached == current.isSelfCoached else {
            throw PlanStoreError.staleCurrentPlanSnapshot
        }
        if let expectedSemantic = expected.semanticPlan,
           RunningPlanBackfill.persistedSemanticSnapshot(for: current, calendar: calendar)
            != expectedSemantic {
            throw PlanStoreError.staleCurrentPlanSnapshot
        }
        var actualSessions = current.sessions.map(sessionSnapshot)
        actualSessions.sort {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
        }
        guard actualSessions == expected.sessions else {
            throw PlanStoreError.staleCurrentPlanSnapshot
        }
    }

    static func carryoverIDs(_ plan: TrainingPlan?,
                             startDate: Date,
                             calendar: Calendar) throws -> [UUID] {
        guard let plan else { return [] }
        let snapshot = ExistingRunningPlanSnapshot(
            id: plan.id,
            name: plan.name,
            isSelfCoached: plan.isSelfCoached,
            sessions: plan.sessions.map {
                sessionSnapshot($0)
            }
        )
        return LegacyRoadPolicyAdapter.completedCarryoverIDs(
            from: snapshot,
            startDate: startDate,
            calendar: calendar
        )
    }

    static func requireUniqueSessionIDs(_ sessions: [PlannedSession]) throws {
        var seen = Set<UUID>()
        for session in sessions where !seen.insert(session.id).inserted {
            throw PlanStoreError.duplicateSessionID(session.id)
        }
    }

    static func sessionSnapshot(_ session: PlannedSession) -> ExistingRunningSessionSnapshot {
        ExistingRunningSessionSnapshot(
            id: session.id,
            date: session.date,
            status: session.status,
            discipline: session.discipline,
            sportType: session.sportType,
            runType: session.runType,
            targetDistanceM: session.targetDistanceM,
            targetDurationS: session.targetDurationS,
            targetPaceSPerKm: session.targetPaceSPerKm,
            intervals: session.intervals,
            strengthLabel: session.strengthLabel,
            strengthTargets: session.strengthTargets.map {
                ExistingRunningSessionSnapshot.StrengthTarget(
                    order: $0.order,
                    exerciseName: $0.exercise?.name ?? "",
                    targetSets: $0.targetSets,
                    targetRepLow: $0.targetRepLow,
                    targetRepHigh: $0.targetRepHigh,
                    targetRPE: $0.targetRPE,
                    targetPctRM: $0.targetPctRM,
                    progression: $0.progression
                )
            },
            completedWorkoutID: session.completedWorkout?.id
        )
    }

    static func exercisesByName(in context: ModelContext) throws -> [String: Exercise] {
        var result: [String: Exercise] = [:]
        for exercise in try context.fetch(FetchDescriptor<Exercise>()) {
            if result.updateValue(exercise, forKey: exercise.name) != nil {
                throw PlanStoreError.duplicateExerciseName(exercise.name)
            }
        }
        return result
    }

    static func pairGeneratedSessionsAndIntents(_ candidate: LegacyRoadPlanCandidate) throws
        -> [GeneratedPair] {
        let generated = candidate.plan.weeks.flatMap { week in
            week.sessions.map { (week, $0) }
        }
        guard generated.count == candidate.sessionIntents.count else {
            throw PlanStoreError.intentMismatch("Generated session and intent counts differ.")
        }
        return try zip(generated, candidate.sessionIntents).map { pair, intent in
            let (week, session) = pair
            guard intent.weekIndex == week.index,
                  intent.dayOffset == session.dayOffset,
                  intent.discipline == session.discipline,
                  intent.legacyRunType == session.runType,
                  intent.workDose.distanceM == session.targetDistanceM,
                  intent.workDose.durationS == session.targetDurationS,
                  intent.workDose.paceSPerKm == session.targetPaceSPerKm,
                  intent.workDose.intervalPrescription == session.intervals,
                  intent.workDose.strengthTargets == session.strengthTargets.map(RunningStrengthTarget.init) else {
                throw PlanStoreError.intentMismatch("Intent \(intent.id) does not describe its generated session.")
            }
            return GeneratedPair(week: week, session: session, intent: intent)
        }
    }

    static func makePlan(id: UUID,
                         input: Commit,
                         pairs: [GeneratedPair],
                         exercisesByName: [String: Exercise],
                         existingSessionIDs: Set<UUID>,
                         now: Date,
                         calendar: Calendar) throws -> PreparedPlan {
        guard let bridge = input.request.legacyBridge else {
            throw PlanStoreError.requestMismatch("Legacy candidate has no bridge inputs.")
        }
        let plan = TrainingPlan()
        plan.id = id
        plan.name = input.candidate.planName
        plan.goal = input.configuration.legacyGoal
        plan.disciplines = bridge.inputs.disciplines.map(\Discipline.rawValue)
        plan.raceDate = input.configuration.raceDate
        plan.p5kSPerKm = input.candidate.plan.p5kSPerKm
        plan.goalRacePaceSPerKm = input.candidate.plan.goalRacePaceSPerKm
        plan.createdAt = now
        plan.blockIndex = input.blockIndex
        plan.blockStart = calendar.startOfDay(for: input.request.startDate)
        plan.weekPhases = input.candidate.plan.weeks.map(\GeneratedWeek.phase.rawValue)
        plan.isSelfCoached = false

        var sessions: [PlannedSession] = []
        var records: [PlannedSessionIntentRecord] = []
        var newSessionIDs = Set<UUID>()
        let anchor = calendar.startOfDay(for: input.request.startDate)
        let encoder = sortedEncoder()

        for pair in pairs {
            let sessionID = stableUUID(namespace: input.request.id, label: "session:\(pair.intent.id)")
            if existingSessionIDs.contains(sessionID) || !newSessionIDs.insert(sessionID).inserted {
                throw PlanStoreError.identifierCollision(entity: "PlannedSession", id: sessionID.uuidString)
            }
            guard let date = calendar.date(
                byAdding: .day,
                value: pair.week.index * 7 + pair.session.dayOffset,
                to: anchor
            ) else {
                throw PlanStoreError.invalidSessionDate(pair.intent.id)
            }
            let persisted = PlannedSession()
            persisted.id = sessionID
            persisted.date = date
            persisted.discipline = pair.session.discipline
            persisted.runType = pair.session.runType
            persisted.targetDistanceM = pair.session.targetDistanceM
            persisted.targetDurationS = pair.session.targetDurationS
            persisted.targetPaceSPerKm = pair.session.targetPaceSPerKm
            persisted.intervals = pair.session.intervals
            persisted.rationale = pair.session.rationale
            persisted.strengthLabel = pair.session.strengthLabel
            persisted.status = .planned
            persisted.strengthTargets = try pair.session.strengthTargets.enumerated().map { index, generated in
                guard let exercise = exercisesByName[generated.exerciseName] else {
                    throw PlanStoreError.missingExercise(generated.exerciseName)
                }
                let target = PlannedExercise()
                target.order = index
                target.exercise = exercise
                target.targetSets = generated.targetSets
                target.targetRepLow = generated.repLow
                target.targetRepHigh = generated.repHigh
                target.targetRPE = generated.targetRPE
                target.targetPctRM = generated.targetPctRM
                target.progression = generated.progression
                return target
            }
            sessions.append(persisted)
            records.append(try intentRecord(
                pair.intent,
                sessionID: sessionID,
                planID: id,
                seasonID: input.candidate.seasonID,
                createdAt: now,
                encoder: encoder
            ))
        }
        plan.sessions = sessions
        return PreparedPlan(plan: plan, intentRecords: records)
    }

    static func intentRecord(_ intent: SessionIntent,
                             sessionID: UUID,
                             planID: UUID,
                             seasonID: UUID,
                             createdAt: Date,
                             encoder: JSONEncoder) throws -> PlannedSessionIntentRecord {
        PlannedSessionIntentRecord(
            id: intent.id,
            plannedSessionID: sessionID,
            planID: planID,
            seasonID: seasonID,
            intentVersion: intent.version,
            weekIndex: intent.weekIndex,
            dayOffset: intent.dayOffset,
            stimulusRaw: intent.stimulus.rawValue,
            sessionClassRaw: intent.sessionClass.rawValue,
            progressionLevel: intent.progressionLevel,
            hardClassRaw: intent.hardClass.rawValue,
            primaryTargetRaw: intent.targetHierarchy.primary.rawValue,
            fallbackTargetRaws: intent.targetHierarchy.fallbacks.map(\RunningTargetKind.rawValue),
            workDistanceM: intent.workDose.distanceM,
            workDurationS: intent.workDose.durationS,
            workPaceSPerKm: intent.workDose.paceSPerKm,
            intervalPrescription: intent.workDose.intervalPrescription,
            strengthTargetsJSON: try encoder.encode(intent.workDose.strengthTargets),
            recoveryDistanceM: intent.recoveryDose?.distanceM,
            recoveryDurationS: intent.recoveryDose?.durationS,
            recoveryModeRaw: intent.recoveryDose?.mode?.rawValue,
            successLower: intent.successRange?.lower,
            successUpper: intent.successRange?.upper,
            recoveryCostRaw: intent.expectedRecoveryCost.rawValue,
            validSubstitutionIDs: intent.validSubstitutionIDs,
            minimumCompletedExposures: intent.minimumEvidenceToProgress.minimumCompletedExposures,
            minimumConfidenceRaw: intent.minimumEvidenceToProgress.minimumConfidence.rawValue,
            purpose: intent.purpose,
            ruleIDRaws: intent.ruleIDs.map(\RunningRuleID.rawValue),
            limitationRaws: intent.limitations.map(\RunningEvidenceLimitation.rawValue),
            createdAt: createdAt
        )
    }

    static func carriedSessions(ids: [UUID], from plan: TrainingPlan?) throws -> [PlannedSession] {
        guard !ids.isEmpty else { return [] }
        guard let plan else {
            throw PlanStoreError.carryoverMismatch(expected: ids, actual: [])
        }
        let byID = Dictionary(grouping: plan.sessions, by: \PlannedSession.id)
        return try ids.map { id in
            guard let matches = byID[id], matches.count == 1, let session = matches.first,
                  session.status == .completed else {
                throw PlanStoreError.carryoverMismatch(expected: ids, actual: [])
            }
            if let workout = session.completedWorkout,
               let linked = workout.plannedSession,
               linked.id != session.id {
                throw PlanStoreError.brokenWorkoutLink(workout.id)
            }
            return session
        }
    }

    static func cloneCompletedSession(_ source: PlannedSession) -> CarriedClone {
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
        clone.strengthTargets = source.strengthTargets.map { old in
            let copied = PlannedExercise()
            copied.order = old.order
            copied.exercise = old.exercise
            copied.targetSets = old.targetSets
            copied.targetRepLow = old.targetRepLow
            copied.targetRepHigh = old.targetRepHigh
            copied.targetRPE = old.targetRPE
            copied.targetPctRM = old.targetPctRM
            copied.progression = old.progression
            return copied
        }
        return CarriedClone(clone: clone, workout: source.completedWorkout)
    }

    static func sortedEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    static func stableUUID(namespace: UUID, label: String) -> UUID {
        var namespace = namespace.uuid
        let namespaceData = withUnsafeBytes(of: &namespace) { Data($0) }
        let digest = SHA256.hash(data: namespaceData + Data(label.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func sameNumber(_ lhs: Double?, _ rhs: Double?, tolerance: Double = 0.001) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): lhs.isFinite && rhs.isFinite && abs(lhs - rhs) <= tolerance
        default: false
        }
    }
}
