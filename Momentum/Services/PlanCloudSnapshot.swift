import Foundation
import SwiftData
import CryptoKit

/// A versioned plan snapshot, not a device/HealthKit backup. Raw GPS samples and media stay on
/// their recording device. Recent Momentum workouts carry the evidence needed for adaptation.
@MainActor
struct PlanCloudSnapshot: Codable {
    var adaptive: AdaptiveState? = nil
    var recoveryFeedback: [RecoveryFeedback]? = nil
    var version = 1
    var profile: Profile
    var coach: CoachUndo.Snapshot
    var preferences: Preferences?
    var shelf: [Shelf]
    var exercises: [CatalogExercise]
    var workouts: [Evidence]
    var seasons: [DataManager.RunningSeasonDTO]
    var events: [DataManager.RunningEventDTO]
    var metadata: [DataManager.PlanMetadataDTO]
    var intents: [DataManager.PlannedSessionIntentDTO]
    var decisions: [DataManager.PlanDecisionDTO]
    var trainingEvidenceFrom: Date? = nil

    struct Profile: Codable {
        var id: UUID
        var displayName: String
        var disciplines: [String]
        var goal: Goal
        var experience: [String: String]
        var daysPerWeek: Int
        var equipment: Equipment
        var sessionMinutes: Int
        var raceDate: Date?
        var raceDistanceM: Double?
        var weeklyRunVolumeM: Double?
        var longestRunM: Double?
        var targetWeeklyRunVolumeM: Double?
        var hybridPriority: String?
        var strengthSplit: String
        var goalFinishTimeS: Double?
        var planIntensity: String?
        var injuryHistory: [String]
        var activeInjuryArea: String?
        var activeInjurySeverity: String?
        var activeInjuryUntil: Date?
        var muscleFocus: [String]
        var preferredDays: [Int]
        var crossTraining: [String]
        var sex: String?
        var heightCm: Double?
        var reason: String
        var weightUnit: String
        var distanceUnit: String
        var maxHR: Int?
        var restingHR: Int?
        var birthYear: Int?
        var bodyMassKg: Double?
        var fuelGoalKind: String?
        var fuelCustomKcal: Int?
        var fuelCustomProteinG: Int?
        var fuelCustomCarbsG: Int?
        var fuelCustomFatG: Int?
        var fuelCustomSodiumMg: Int?
        var createdAt: Date
        var handle: String
        var bio: String
        var city: String
        var locationGranularity: String
        var defaultWorkoutVisibility: String
        var appearOnMap: Bool
        var publicRouteMaps: Bool
        var showExactNumbers: Bool
        var discoverable: Bool
        init(_ value: UserProfile) {
            id = value.id
            displayName = value.displayName
            disciplines = value.disciplines
            goal = value.goal
            experience = value.experience
            daysPerWeek = value.daysPerWeek
            equipment = value.equipment
            sessionMinutes = value.sessionMinutes
            raceDate = value.raceDate
            raceDistanceM = value.raceDistanceM
            weeklyRunVolumeM = value.weeklyRunVolumeM
            longestRunM = value.longestRunM
            targetWeeklyRunVolumeM = value.targetWeeklyRunVolumeM
            hybridPriority = value.hybridPriority
            strengthSplit = value.strengthSplit
            goalFinishTimeS = value.goalFinishTimeS
            planIntensity = value.planIntensity
            injuryHistory = value.injuryHistory
            activeInjuryArea = value.activeInjuryArea
            activeInjurySeverity = value.activeInjurySeverity
            activeInjuryUntil = value.activeInjuryUntil
            muscleFocus = value.muscleFocus
            preferredDays = value.preferredDays
            crossTraining = value.crossTraining
            sex = value.sex
            heightCm = value.heightCm
            reason = value.reason
            weightUnit = value.weightUnit
            distanceUnit = value.distanceUnit
            maxHR = value.maxHR
            restingHR = value.restingHR
            birthYear = value.birthYear
            bodyMassKg = value.bodyMassKg
            fuelGoalKind = value.fuelGoalKind
            fuelCustomKcal = value.fuelCustomKcal
            fuelCustomProteinG = value.fuelCustomProteinG
            fuelCustomCarbsG = value.fuelCustomCarbsG
            fuelCustomFatG = value.fuelCustomFatG
            fuelCustomSodiumMg = value.fuelCustomSodiumMg
            createdAt = value.createdAt
            handle = value.handle
            bio = value.bio
            city = value.city
            locationGranularity = value.locationGranularity
            defaultWorkoutVisibility = value.defaultWorkoutVisibility
            appearOnMap = value.appearOnMap
            publicRouteMaps = value.publicRouteMaps
            showExactNumbers = value.showExactNumbers
            discoverable = value.discoverable
        }
        func apply(to value: UserProfile) {
            value.id = id
            value.displayName = displayName
            value.disciplines = disciplines
            value.goal = goal
            value.experience = experience
            value.daysPerWeek = daysPerWeek
            value.equipment = equipment
            value.sessionMinutes = sessionMinutes
            value.raceDate = raceDate
            value.raceDistanceM = raceDistanceM
            value.weeklyRunVolumeM = weeklyRunVolumeM
            value.longestRunM = longestRunM
            value.targetWeeklyRunVolumeM = targetWeeklyRunVolumeM
            value.hybridPriority = hybridPriority
            value.strengthSplit = strengthSplit
            value.goalFinishTimeS = goalFinishTimeS
            value.planIntensity = planIntensity
            value.injuryHistory = injuryHistory
            value.activeInjuryArea = activeInjuryArea
            value.activeInjurySeverity = activeInjurySeverity
            value.activeInjuryUntil = activeInjuryUntil
            value.muscleFocus = muscleFocus
            value.preferredDays = preferredDays
            value.crossTraining = crossTraining
            value.sex = sex
            value.heightCm = heightCm
            value.reason = reason
            value.weightUnit = weightUnit
            value.distanceUnit = distanceUnit
            value.maxHR = maxHR
            value.restingHR = restingHR
            value.birthYear = birthYear
            value.bodyMassKg = bodyMassKg
            value.fuelGoalKind = fuelGoalKind
            value.fuelCustomKcal = fuelCustomKcal
            value.fuelCustomProteinG = fuelCustomProteinG
            value.fuelCustomCarbsG = fuelCustomCarbsG
            value.fuelCustomFatG = fuelCustomFatG
            value.fuelCustomSodiumMg = fuelCustomSodiumMg
            value.createdAt = createdAt
            value.handle = handle
            value.bio = bio
            value.city = city
            value.locationGranularity = locationGranularity
            value.defaultWorkoutVisibility = defaultWorkoutVisibility
            value.appearOnMap = appearOnMap
            value.publicRouteMaps = publicRouteMaps
            value.showExactNumbers = showExactNumbers
            value.discoverable = discoverable
        }
    }
    struct CatalogExercise: Codable {
        var id: UUID
        var name: String
        var primaryMuscles: [String]
        var secondaryMuscles: [String]
        var equipment: EquipmentType
        var category: ExerciseCategory
        var trackingMode: TrackingMode
        var defaultRestS: Double
        var instructions: String
        var isCustom: Bool
        init(_ value: Exercise) {
            id = value.id
            name = value.name
            primaryMuscles = value.primaryMuscles
            secondaryMuscles = value.secondaryMuscles
            equipment = value.equipment
            category = value.category
            trackingMode = value.trackingMode
            defaultRestS = value.defaultRestS
            instructions = value.instructions
            isCustom = value.isCustom
        }
        func make() -> Exercise {
            let value = Exercise()
            value.id = id
            value.name = name
            value.primaryMuscles = primaryMuscles
            value.secondaryMuscles = secondaryMuscles
            value.equipment = equipment
            value.category = category
            value.trackingMode = trackingMode
            value.defaultRestS = defaultRestS
            value.instructions = instructions
            value.isCustom = isCustom
            return value
        }
    }
    struct SetValue: Codable {
        var index: Int
        var weightKg: Double?
        var reps: Int?
        var durationS: Double?
        var distanceM: Double?
        var rpe: Double?
        var type: SetType
        var isComplete: Bool
        var restS: Double
        var completedAt: Date?
        init(_ value: SetEntry) {
            index = value.index
            weightKg = value.weightKg
            reps = value.reps
            durationS = value.durationS
            distanceM = value.distanceM
            rpe = value.rpe
            type = value.type
            isComplete = value.isComplete
            restS = value.restS
            completedAt = value.completedAt
        }
        func make() -> SetEntry {
            let value = SetEntry()
            value.index = index
            value.weightKg = weightKg
            value.reps = reps
            value.durationS = durationS
            value.distanceM = distanceM
            value.rpe = rpe
            value.type = type
            value.isComplete = isComplete
            value.restS = restS
            value.completedAt = completedAt
            return value
        }
    }
    private func restoreSidecars(in context: ModelContext) throws {
        for old in try context.fetch(FetchDescriptor<RunningSeasonRecord>()) { context.delete(old) }
        for value in seasons {
            context.insert(RunningSeasonRecord(id: value.id, profileID: value.profileID, activePlanID: value.activePlanID, name: value.name, createdAt: value.createdAt, updatedAt: value.updatedAt, statusRaw: value.statusRaw, primaryOutcomeRaw: value.primaryOutcomeRaw, motivationRaws: value.motivationRaws, version: value.version, backfillVersion: value.backfillVersion))
        }
        for old in try context.fetch(FetchDescriptor<RunningEventRecord>()) { context.delete(old) }
        for value in events {
            context.insert(RunningEventRecord(id: value.id, seasonID: value.seasonID, name: value.name, date: value.date, distanceM: value.distanceM, durationS: value.durationS, priorityRaw: value.priorityRaw, surfaceRaw: value.surfaceRaw, ascentM: value.ascentM, descentM: value.descentM, altitudeRaw: value.altitudeRaw, technicalityRaw: value.technicalityRaw, climateRaw: value.climateRaw, statusRaw: value.statusRaw, version: value.version))
        }
        for old in try context.fetch(FetchDescriptor<PlanMetadataRecord>()) { context.delete(old) }
        for value in metadata {
            context.insert(PlanMetadataRecord(planID: value.planID, seasonID: value.seasonID, requestID: value.requestID, plannerVersion: value.plannerVersion, rulesetID: value.rulesetID, policyIDRaw: value.policyIDRaw, semanticDigest: value.semanticDigest, createdAt: value.createdAt, version: value.version, isLegacyBackfill: value.isLegacyBackfill))
        }
        for old in try context.fetch(FetchDescriptor<PlannedSessionIntentRecord>()) { context.delete(old) }
        for value in intents {
            context.insert(PlannedSessionIntentRecord(id: value.id, plannedSessionID: value.plannedSessionID, planID: value.planID, seasonID: value.seasonID, intentVersion: value.intentVersion, weekIndex: value.weekIndex, dayOffset: value.dayOffset, stimulusRaw: value.stimulusRaw, sessionClassRaw: value.sessionClassRaw, progressionLevel: value.progressionLevel, hardClassRaw: value.hardClassRaw, primaryTargetRaw: value.primaryTargetRaw, fallbackTargetRaws: value.fallbackTargetRaws, workDistanceM: value.workDistanceM, workDurationS: value.workDurationS, workPaceSPerKm: value.workPaceSPerKm, intervalPrescription: value.intervalPrescription, strengthTargetsJSON: value.strengthTargetsJSON, recoveryDistanceM: value.recoveryDistanceM, recoveryDurationS: value.recoveryDurationS, recoveryModeRaw: value.recoveryModeRaw, successLower: value.successLower, successUpper: value.successUpper, recoveryCostRaw: value.recoveryCostRaw, validSubstitutionIDs: value.validSubstitutionIDs, minimumCompletedExposures: value.minimumCompletedExposures, minimumConfidenceRaw: value.minimumConfidenceRaw, purpose: value.purpose, ruleIDRaws: value.ruleIDRaws, limitationRaws: value.limitationRaws, createdAt: value.createdAt))
        }
        for old in try context.fetch(FetchDescriptor<PlanDecisionRecord>()) { context.delete(old) }
        for value in decisions {
            context.insert(PlanDecisionRecord(id: value.id, requestID: value.requestID, profileID: value.profileID, planID: value.planID, seasonID: value.seasonID, decidedAt: value.decidedAt, triggerRaw: value.triggerRaw, statusRaw: value.statusRaw, plannerVersion: value.plannerVersion, rulesetID: value.rulesetID, policyIDRaw: value.policyIDRaw, oldPlanDigest: value.oldPlanDigest, newPlanDigest: value.newPlanDigest, diffJSON: value.diffJSON, appliedRuleIDRaws: value.appliedRuleIDRaws, hardConstraintRaws: value.hardConstraintRaws, relaxedPreferenceRaws: value.relaxedPreferenceRaws, evidenceConfidenceRaws: value.evidenceConfidenceRaws, limitationRaws: value.limitationRaws, headline: value.headline, detail: value.detail, athleteResponseRaw: value.athleteResponseRaw, normalizedInputVersion: value.normalizedInputVersion, normalizedInputJSON: value.normalizedInputJSON, version: value.version))
        }
    }
    struct Preferences: Codable {
        var regularRunLimitS: Double?
        var longRunLimitS: Double?
        var benchmarkDistanceM: Double?
        var benchmarkTimeS: Double?
        var benchmarkPerformedAt: Date?
        var benchmarkRecordedAt: Date?
        init(_ value: PlanPreferencesRecord) {
            regularRunLimitS = value.regularRunLimitS; longRunLimitS = value.longRunLimitS
            benchmarkDistanceM = value.benchmarkDistanceM; benchmarkTimeS = value.benchmarkTimeS
            benchmarkPerformedAt = value.benchmarkPerformedAt; benchmarkRecordedAt = value.benchmarkRecordedAt
        }
        func apply(profileID: UUID, in context: ModelContext) {
            let value = PlanPreferencesRecord.upsert(profileID: profileID, in: context)
            value.regularRunLimitS = regularRunLimitS; value.longRunLimitS = longRunLimitS
            value.benchmarkDistanceM = benchmarkDistanceM; value.benchmarkTimeS = benchmarkTimeS
            value.benchmarkPerformedAt = benchmarkPerformedAt; value.benchmarkRecordedAt = benchmarkRecordedAt
        }
    }
    struct Shelf: Codable {
        var id: UUID
        var status: PlanShelfStatus
        var name: String
        var createdAt: Date
        var updatedAt: Date
        var scheduledStart: Date?
        var startedAt: Date?
        var endedAt: Date?
        var blueprintData: Data
        var previewData: Data?
        var snapshotData: Data?
        var sourcePlanID: UUID?
        var version: Int
        init(_ value: PlanShelfRecord) {
            id = value.id; status = value.status; name = value.name
            createdAt = value.createdAt; updatedAt = value.updatedAt; scheduledStart = value.scheduledStart
            startedAt = value.startedAt; endedAt = value.endedAt
            blueprintData = value.blueprintData; previewData = value.previewData; snapshotData = value.snapshotData
            sourcePlanID = value.sourcePlanID; version = value.version
        }
        func make(profileID: UUID) -> PlanShelfRecord {
            let value = PlanShelfRecord(id: id, profileID: profileID, status: status, name: name,
                                        createdAt: createdAt, blueprintData: blueprintData)
            value.updatedAt = updatedAt; value.scheduledStart = scheduledStart
            value.startedAt = startedAt; value.endedAt = endedAt; value.previewData = previewData
            value.snapshotData = snapshotData; value.sourcePlanID = sourcePlanID; value.version = version
            return value
        }
    }
    struct Lift: Codable {
        var order: Int
        var supersetGroup: Int?
        var note: String
        var exerciseID: UUID?
        var sets: [SetValue]
        init(_ value: WorkoutExercise) {
            order = value.order; supersetGroup = value.supersetGroup; note = value.note
            exerciseID = value.exercise?.id
            sets = value.sets.sorted { $0.index < $1.index }.map(SetValue.init)
        }
    }
    struct Evidence: Codable {
        var id: UUID
        var type: WorkoutType
        var startedAt: Date
        var durationS: Double
        var elapsedS: Double
        var calories: Double?
        var perceivedEffort: Int?
        var planFitRaw: String?
        var title: String
        var note: String
        var privacy: WorkoutPrivacy
        var distanceM: Double?
        var pace: Double?
        var speed: Double?
        var ascent: Double?
        var avgHR: Int?
        var avgCadence: Int?
        var structuredRepsData: Data?
        var volumeKg: Double?
        var totalSets: Int?
        var lifts: [Lift]
        init(_ value: Workout) {
            id = value.id; type = value.type; startedAt = value.startedAt
            durationS = value.durationS; elapsedS = value.elapsedS; calories = value.calories
            perceivedEffort = value.perceivedEffort; planFitRaw = value.planFitRaw
            title = value.title; note = value.note; privacy = value.privacy
            distanceM = value.gps?.distanceM; pace = value.gps?.avgPaceSPerKm
            speed = value.gps?.avgSpeedMS; ascent = value.gps?.elevationGainM
            avgHR = value.gps?.avgHR; avgCadence = value.gps?.avgCadence
            structuredRepsData = value.gps?.structuredRepsData
            volumeKg = value.strength?.totalVolumeKg; totalSets = value.strength?.totalSets
            lifts = (value.strength?.exercises ?? []).sorted { $0.order < $1.order }.map(Lift.init)
        }
        func make(exercises: [UUID: Exercise]) throws -> Workout {
            let value = Workout()
            value.id = id; value.type = type; value.startedAt = startedAt
            value.durationS = durationS; value.elapsedS = elapsedS; value.calories = calories
            value.perceivedEffort = perceivedEffort; value.planFitRaw = planFitRaw
            value.title = title; value.note = note; value.privacy = privacy
            if let distanceM {
                let gps = GPSDetail(); gps.distanceM = distanceM
                gps.avgPaceSPerKm = pace ?? 0; gps.avgSpeedMS = speed ?? 0
                gps.elevationGainM = ascent ?? 0; gps.avgHR = avgHR; gps.avgCadence = avgCadence
                gps.structuredRepsData = structuredRepsData; value.gps = gps
            }
            if volumeKg != nil || !lifts.isEmpty {
                let strength = StrengthSession()
                strength.totalVolumeKg = volumeKg ?? 0; strength.totalSets = totalSets ?? 0
                for lift in lifts {
                    if let id = lift.exerciseID, exercises[id] == nil { throw Failure.invalidSnapshot }
                    let exercise = WorkoutExercise()
                    exercise.order = lift.order; exercise.supersetGroup = lift.supersetGroup
                    exercise.note = lift.note; exercise.exercise = lift.exerciseID.flatMap { exercises[$0] }
                    exercise.sets = lift.sets.map { $0.make() }
                    strength.exercises.append(exercise)
                }
                value.strength = strength
            }
            return value
        }
    }

    enum Failure: Error { case unsupportedVersion, invalidSnapshot, tooLarge, activeWorkout, restoreFailed }
    static let maximumBytes = 8 * 1_024 * 1_024
    static func encoder() -> JSONEncoder {
        let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]
        return value
    }
    func encoded() throws -> Data {
        let data = try Self.encoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
        return data
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Choosing a plan does not discard training completed on the other device. Preserve the
    /// selected copy's edits to existing workout summaries and import previously unseen evidence.
    func mergingTrainingEvidence(from other: Self) throws -> Self {
        var merged = self
        let workoutIDs = Set(workouts.map(\.id))
        merged.workouts += other.workouts.filter { !workoutIDs.contains($0.id) }
        merged.workouts.sort { $0.id.uuidString < $1.id.uuidString }
        var feedback = Dictionary((recoveryFeedback ?? []).map { ($0.id, $0) },
                                  uniquingKeysWith: { a, b in a.submittedAt >= b.submittedAt ? a : b })
        for incoming in other.recoveryFeedback ?? [] {
            if feedback[incoming.id].map({ $0.submittedAt < incoming.submittedAt }) ?? true {
                feedback[incoming.id] = incoming
            }
        }
        if !feedback.isEmpty {
            merged.recoveryFeedback = feedback.values.sorted { $0.id.uuidString < $1.id.uuidString }
        }
        // Selecting the prescription from another device must not discard its symptom hold.
        if other.adaptive?.requiresRecoveryCheckin == true {
            merged.adaptive?.requiresRecoveryCheckin = true
        }
        let exerciseIDs = Set(exercises.map(\.id))
        merged.exercises += other.exercises.filter { !exerciseIDs.contains($0.id) }
        merged.exercises.sort { $0.id.uuidString < $1.id.uuidString }
        Self.preserveCompletedSessions(in: &merged.coach.plan, from: other.coach.plan)
        try merged.validate()
        _ = try merged.encoded()
        return merged
    }

    private static func preserveCompletedSessions(in selected: inout CoachUndo.Snapshot.PlanState?,
                                                  from other: CoachUndo.Snapshot.PlanState?) {
        guard var plan = selected, let other else { return }
        let completed = other.sessions.filter {
            $0.completedWorkoutID != nil && $0.completedWorkoutID != ActiveWorkoutMarker.pendingID
        }
        let byID = Dictionary(completed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in plan.sessions.indices where plan.sessions[index].completedWorkoutID == nil {
            if var evidence = byID[plan.sessions[index].id] {
                // Keep the prescription and date that belonged to the actual completed outing.
                evidence.status = SessionStatus.completed.rawValue
                plan.sessions[index] = evidence
            }
        }
        if plan.id == other.id {
            let selectedIDs = Set(plan.sessions.map(\.id))
            plan.sessions += completed.filter { !selectedIDs.contains($0.id) }.map {
                var session = $0; session.status = SessionStatus.completed.rawValue; return session
            }
        }
        plan.sessions.sort { $0.id.uuidString < $1.id.uuidString }
        selected = plan
    }
    static func capture(_ profile: UserProfile, in context: ModelContext, now: Date = Date()) throws -> Self {
        guard let text = CoachUndo.capture(profile) else { throw Failure.invalidSnapshot }
        var coach = try JSONDecoder().decode(CoachUndo.Snapshot.self, from: Data(text.utf8))
        coach.plan?.sessions.sort { $0.id.uuidString < $1.id.uuidString }
        for index in coach.plan?.sessions.indices ?? 0..<0 {
            coach.plan?.sessions[index].strength.sort { $0.order < $1.order }
        }
        let savedPlans = PlanShelfRecord.fetch(profileID: profile.id, in: context)
        let savedStates = try savedPlans.compactMap { record -> CoachUndo.Snapshot.PlanState? in
            guard let data = record.snapshotData else { return nil }
            return try JSONDecoder().decode(CoachUndo.Snapshot.PlanState.self, from: data)
        }
        let savedCompletions = savedStates.flatMap { $0.sessions.compactMap(\.completedWorkoutID) }
        let linked = Set((coach.plan?.sessions.compactMap(\.completedWorkoutID) ?? []) + savedCompletions)
        let cutoff = now.addingTimeInterval(-90 * 86_400)
        let evidence = try context.fetch(FetchDescriptor<Workout>()).filter {
            $0.id != ActiveWorkoutMarker.pendingID && ($0.startedAt >= cutoff || linked.contains($0.id))
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let workoutValues = evidence.map(Evidence.init)
        let evidenceIDs = Set(workoutValues.map(\.id))
        // Carry every referenced identity plus custom exercises, not the entire bundled catalog
        // on every save. MOMENTUM-IOS-K hung encoding unused catalog entries on the main thread.
        let planStates = savedStates + [coach.plan].compactMap { $0 }
        let exerciseIDs = Set(planStates.flatMap { $0.sessions.flatMap { $0.strength.compactMap(\.exerciseID) } }
            + workoutValues.flatMap { $0.lifts.compactMap(\.exerciseID) })
        var value = Self(profile: Profile(profile), coach: coach, preferences: profile.planPreferences.map(Preferences.init),
            shelf: savedPlans.sorted { $0.id.uuidString < $1.id.uuidString }.map(Shelf.init),
            exercises: try context.fetch(FetchDescriptor<Exercise>())
                .filter { $0.isCustom || exerciseIDs.contains($0.id) }
                .sorted { $0.id.uuidString < $1.id.uuidString }.map(CatalogExercise.init),
            workouts: workoutValues,
            seasons: try context.fetch(FetchDescriptor<RunningSeasonRecord>()).filter { $0.profileID == profile.id }
                .sorted { $0.id.uuidString < $1.id.uuidString }.map(DataManager.RunningSeasonDTO.init),
            events: try context.fetch(FetchDescriptor<RunningEventRecord>()).sorted { $0.id.uuidString < $1.id.uuidString }.map(DataManager.RunningEventDTO.init),
            metadata: try context.fetch(FetchDescriptor<PlanMetadataRecord>()).sorted { $0.id.uuidString < $1.id.uuidString }.map(DataManager.PlanMetadataDTO.init),
            intents: try context.fetch(FetchDescriptor<PlannedSessionIntentRecord>()).sorted { $0.id < $1.id }.map(DataManager.PlannedSessionIntentDTO.init),
            decisions: try context.fetch(FetchDescriptor<PlanDecisionRecord>()).filter { $0.profileID == profile.id }
                .sorted { $0.id.uuidString < $1.id.uuidString }.map(DataManager.PlanDecisionDTO.init))
        value.trainingEvidenceFrom = profile.continuity?.trainingEvidenceFrom
        value.adaptive = profile.plan?.adaptiveState.map(AdaptiveState.init)
        if context.container.schema.entities.contains(where: { $0.name == "WorkoutFeedbackRecord" }) {
            value.recoveryFeedback = try context.fetch(FetchDescriptor<WorkoutFeedbackRecord>())
                .filter { evidenceIDs.contains($0.id) }
                .sorted { $0.id.uuidString < $1.id.uuidString }.map(RecoveryFeedback.init)
        }
        try value.validate()
        return value
    }

    func validate() throws {
        guard version == 1 else { throw Failure.unsupportedVersion }
        if let adaptive {
            guard adaptive.planID == coach.plan?.id, adaptive.reviewsData.count < 1_000_000,
                  (adaptive.baselineData?.count ?? 0) < 100_000,
                  (1...7).contains(adaptive.firstWeekday), (1...7).contains(adaptive.minimumDays),
                  TimeZone(identifier: adaptive.timeZoneID) != nil else { throw Failure.invalidSnapshot }
            _ = try JSONDecoder().decode([AdaptivePlanRecord.Review].self, from: adaptive.reviewsData)
        }
        if let recoveryFeedback {
            guard recoveryFeedback.count <= 10_000,
                  Set(recoveryFeedback.map(\.id)).count == recoveryFeedback.count,
                  recoveryFeedback.allSatisfy({ ($0.recovery.map { (1...3).contains($0) } ?? true)
                    && ($0.plannedDistanceM.map { $0.isFinite && $0 >= 0 } ?? true)
                    && ($0.plannedDurationS.map { $0.isFinite && $0 > 0 } ?? true)
                    && ($0.plannedPaceSPerKm.map { $0.isFinite && $0 > 0 } ?? true) }) else { throw Failure.invalidSnapshot }
        }
        func finite(_ values: [Double?]) -> Bool { values.allSatisfy { $0.map { $0.isFinite && $0 >= 0 } ?? true } }
        func dates(_ values: [Date?]) -> Bool { values.allSatisfy { $0?.timeIntervalSinceReferenceDate.isFinite ?? true } }
        guard (1...7).contains(profile.daysPerWeek), (1...360).contains(profile.sessionMinutes),
              profile.preferredDays.allSatisfy({ (1...7).contains($0) }),
              finite([profile.weeklyRunVolumeM, profile.longestRunM, profile.targetWeeklyRunVolumeM,
                      profile.raceDistanceM, profile.goalFinishTimeS, preferences?.regularRunLimitS,
                      preferences?.longRunLimitS, preferences?.benchmarkDistanceM, preferences?.benchmarkTimeS]),
              workouts.count <= 4_000, shelf.count <= 200, intents.count <= 10_000,
              Set(workouts.map(\.id)).count == workouts.count,
              Set(exercises.map(\.id)).count == exercises.count,
              Set(shelf.map(\.id)).count == shelf.count,
              Set(seasons.map(\.id)).count == seasons.count,
              Set(events.map(\.id)).count == events.count,
              Set(metadata.map(\.planID)).count == metadata.count,
              Set(intents.map(\.id)).count == intents.count,
              Set(decisions.map(\.id)).count == decisions.count,
              coach.goal == profile.goal.rawValue, coach.daysPerWeek == profile.daysPerWeek,
              coach.sessionMinutes == profile.sessionMinutes, coach.equipment == profile.equipment.rawValue,
              dates([profile.createdAt, profile.raceDate, trainingEvidenceFrom,
                     preferences?.benchmarkPerformedAt, preferences?.benchmarkRecordedAt]),
              seasons.allSatisfy({ $0.profileID == profile.id }),
              decisions.allSatisfy({ $0.profileID == profile.id }) else { throw Failure.invalidSnapshot }
        if let data = coach.illnessData {
            let state = try JSONDecoder().decode(IllnessResponse.State.self, from: data)
            guard coach.illnessCaptured == true,
                  dates([state.startedAt, state.checkedAt, state.firstOutingEndedAt, state.returnStartedAt]),
                  dates(state.completedOutings.values.map(Optional.some)),
                  (Array(state.originals.values) + Array(state.applied.values)).allSatisfy({
                      finite([$0.distance, $0.duration, $0.pace]) && ($0.runType.flatMap(RunType.init(rawValue:)) != nil || $0.runType == nil)
                  }) else { throw Failure.invalidSnapshot }
        }
        guard dates([coach.fitnessDeclaredAt]), finite([coach.longestRunM]) else { throw Failure.invalidSnapshot }
        let exercisesByID = Set(exercises.map(\.id))
        let workoutsByID = Set(workouts.map(\.id))
        if let plan = coach.plan {
            guard plan.id != nil, plan.sessions.count <= 3_000, plan.p5kSPerKm.isFinite,
                  plan.p5kSPerKm > 0, Set(plan.sessions.map(\.id)).count == plan.sessions.count,
                  Goal(rawValue: plan.goal) != nil,
                  finite([plan.goalRacePaceSPerKm, plan.pendingP5kSPerKm, plan.athleteState?.thresholdSPerKm,
                          plan.athleteState?.riegelExponent]),
                  dates([plan.createdAt, plan.raceDate, plan.pausedUntil, plan.lastAdaptedAt, plan.blockStart]) else { throw Failure.invalidSnapshot }
            for session in plan.sessions {
                guard Discipline(rawValue: session.discipline) != nil,
                      SessionStatus(rawValue: session.status) != nil,
                      session.runType == nil || session.runType.flatMap(RunType.init(rawValue:)) != nil,
                      session.completedWorkoutID.map(workoutsByID.contains) ?? true,
                      dates([session.date]),
                      finite([session.targetDistanceM, session.targetDurationS, session.targetPaceSPerKm]),
                      session.strength.allSatisfy({
                          ($0.exerciseID.map(exercisesByID.contains) ?? false)
                              && $0.targetSets >= 0 && $0.targetRepLow >= 0 && $0.targetRepHigh >= $0.targetRepLow
                              && finite([$0.targetRPE, $0.targetPctRM])
                      }) else { throw Failure.invalidSnapshot }
            }
        }
        for exercise in exercises {
            guard finite([exercise.defaultRestS]) else { throw Failure.invalidSnapshot }
        }
        for workout in workouts {
            guard finite([workout.durationS, workout.elapsedS, workout.distanceM, workout.pace,
                          workout.speed, workout.ascent, workout.volumeKg, workout.calories]),
                  workout.startedAt.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalidSnapshot }
            for lift in workout.lifts {
                guard lift.exerciseID.map(exercisesByID.contains) ?? true else { throw Failure.invalidSnapshot }
                for set in lift.sets {
                    guard finite([set.weightKg, set.durationS, set.distanceM, set.rpe, set.restS]),
                          set.reps.map({ $0 >= 0 }) ?? true, dates([set.completedAt]) else { throw Failure.invalidSnapshot }
                }
            }
        }
        let seasonIDs = Set(seasons.map(\.id))
        for event in events {
            guard seasonIDs.contains(event.seasonID), dates([event.date]),
                  finite([event.distanceM, event.durationS, event.ascentM, event.descentM]) else { throw Failure.invalidSnapshot }
        }
        for item in shelf {
            _ = try JSONDecoder().decode(PlanBlueprint.self, from: item.blueprintData)
            guard dates([item.createdAt, item.updatedAt, item.scheduledStart, item.startedAt, item.endedAt]) else { throw Failure.invalidSnapshot }
            if let data = item.snapshotData { _ = try JSONDecoder().decode(CoachUndo.Snapshot.PlanState.self, from: data) }
        }
    }

    /// The caller owns the outer transaction and the cloud journal update. Never erases a local
    /// workout or raw sample, and never runs during an active recording.
    func restore(in context: ModelContext) throws -> UserProfile {
        try validate()
        guard ActiveWorkoutMarker.pendingID == nil else { throw Failure.activeWorkout }
        let existing = try context.fetch(FetchDescriptor<UserProfile>())
        guard existing.count <= 1 else { throw Failure.invalidSnapshot }
        let athlete = existing.first ?? UserProfile()
        if existing.isEmpty { context.insert(athlete) }
        var restoredCoach = coach
        Self.preserveCompletedSessions(in: &restoredCoach.plan, from: athlete.plan.map(CoachUndo.planState))
        let oldID = athlete.id
        profile.apply(to: athlete)
        if coach.fitnessDeclarationCaptured != true {
            PlanFitnessDeclarationRecord.set(nil, for: athlete, in: context)
        }
        let catalog = try context.fetch(FetchDescriptor<Exercise>())
        var byID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        for item in exercises where byID[item.id] == nil {
            let value = item.make(); context.insert(value); byID[item.id] = value
        }
        let local = try context.fetch(FetchDescriptor<Workout>())
        var localIDs = Set(local.map(\.id))
        for evidence in workouts where !localIDs.contains(evidence.id) {
            let workout = try evidence.make(exercises: byID)
            context.insert(workout); athlete.workouts.append(workout); localIDs.insert(evidence.id)
        }
        if let preferences { preferences.apply(profileID: athlete.id, in: context) }
        else if let old = athlete.planPreferences { context.delete(old) }
        let text = String(decoding: try Self.encoder().encode(restoredCoach), as: UTF8.self)
        guard CoachUndo.restore(text, profile: athlete, in: context, restoreCloudRecovery: true) else { throw Failure.restoreFailed }
        PlanContinuityRecord.upsert(profileID: athlete.id, in: context).trainingEvidenceFrom = trainingEvidenceFrom
        for old in try context.fetch(FetchDescriptor<PlanShelfRecord>()) { context.delete(old) }
        for item in shelf { context.insert(item.make(profileID: athlete.id)) }
        try restoreSidecars(in: context)
        if context.container.schema.entities.contains(where: { $0.name == "AdaptivePlanRecord" }) {
            try adaptive?.restore(profile: athlete, in: context)
            for item in recoveryFeedback ?? [] { item.restore(in: context) }
        }
        // Reconcile sidecars against the enforced prescription, including a conflict that
        // retained stricter local recovery than the chosen cloud plan.
        _ = try RunningPlanBackfill.prepareAfterLegacyPlanMutation(in: context)
        if oldID != athlete.id {
            if let old = PlanContinuityRecord.fetch(profileID: oldID, in: context) { context.delete(old) }
            if let old = PlanPreferencesRecord.fetch(profileID: oldID, in: context) { context.delete(old) }
        }
        return athlete
    }
}
