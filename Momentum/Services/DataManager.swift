import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Export + delete the user's data (PRD §13.3 — privacy: own your data, leave anytime). Local-first:
/// no account or network. Deletion is App-Store-required for any app that stores personal data.
@MainActor
enum DataManager {

    // MARK: - Export

    struct Snapshot: Codable {
        var app = "momentum"
        var schemaVersion = 2
        var exportedAt: Date
        var profile: ProfileDTO?
        var workouts: [WorkoutDTO]
        var runningSeasons: [RunningSeasonDTO]
        var runningEvents: [RunningEventDTO]
        var planMetadata: [PlanMetadataDTO]
        var plannedSessionIntents: [PlannedSessionIntentDTO]
        var planDecisions: [PlanDecisionDTO]
    }

    struct ProfileDTO: Codable {
        let displayName: String
        let disciplines: [String]
        let goal: String
        let daysPerWeek: Int
        let weightUnit: String
        let distanceUnit: String
    }

    struct WorkoutDTO: Codable {
        let type: String
        let startedAt: Date
        let durationS: Double
        let perceivedEffort: Int?
        let title: String
        let note: String
        let distanceM: Double?
        let avgPaceSPerKm: Double?
        let elevationGainM: Double?
        let totalVolumeKg: Double?
        let totalSets: Int?
    }

    struct RunningSeasonDTO: Codable {
        let id: UUID
        let profileID: UUID
        let activePlanID: UUID?
        let name: String
        let createdAt: Date
        let updatedAt: Date
        let statusRaw: String
        let primaryOutcomeRaw: String
        let motivationRaws: [String]
        let version: Int
        let backfillVersion: Int

        init(_ value: RunningSeasonRecord) {
            id = value.id
            profileID = value.profileID
            activePlanID = value.activePlanID
            name = value.name
            createdAt = value.createdAt
            updatedAt = value.updatedAt
            statusRaw = value.statusRaw
            primaryOutcomeRaw = value.primaryOutcomeRaw
            motivationRaws = value.motivationRaws
            version = value.version
            backfillVersion = value.backfillVersion
        }
    }

    struct RunningEventDTO: Codable {
        let id: UUID
        let seasonID: UUID
        let name: String
        let date: Date
        let distanceM: Double?
        let durationS: Double?
        let priorityRaw: String
        let surfaceRaw: String
        let ascentM: Double?
        let descentM: Double?
        let altitudeRaw: String
        let technicalityRaw: String
        let climateRaw: String
        let statusRaw: String
        let version: Int

        init(_ value: RunningEventRecord) {
            id = value.id
            seasonID = value.seasonID
            name = value.name
            date = value.date
            distanceM = value.distanceM
            durationS = value.durationS
            priorityRaw = value.priorityRaw
            surfaceRaw = value.surfaceRaw
            ascentM = value.ascentM
            descentM = value.descentM
            altitudeRaw = value.altitudeRaw
            technicalityRaw = value.technicalityRaw
            climateRaw = value.climateRaw
            statusRaw = value.statusRaw
            version = value.version
        }
    }

    struct PlanMetadataDTO: Codable {
        let id: UUID
        let planID: UUID
        let seasonID: UUID
        let requestID: UUID?
        let plannerVersion: String
        let rulesetID: String
        let policyIDRaw: String?
        let semanticDigest: String
        let createdAt: Date
        let version: Int
        let isLegacyBackfill: Bool

        init(_ value: PlanMetadataRecord) {
            id = value.id
            planID = value.planID
            seasonID = value.seasonID
            requestID = value.requestID
            plannerVersion = value.plannerVersion
            rulesetID = value.rulesetID
            policyIDRaw = value.policyIDRaw
            semanticDigest = value.semanticDigest
            createdAt = value.createdAt
            version = value.version
            isLegacyBackfill = value.isLegacyBackfill
        }
    }

    struct PlannedSessionIntentDTO: Codable {
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
        let createdAt: Date

        init(_ value: PlannedSessionIntentRecord) {
            id = value.id
            plannedSessionID = value.plannedSessionID
            planID = value.planID
            seasonID = value.seasonID
            intentVersion = value.intentVersion
            weekIndex = value.weekIndex
            dayOffset = value.dayOffset
            stimulusRaw = value.stimulusRaw
            sessionClassRaw = value.sessionClassRaw
            progressionLevel = value.progressionLevel
            hardClassRaw = value.hardClassRaw
            primaryTargetRaw = value.primaryTargetRaw
            fallbackTargetRaws = value.fallbackTargetRaws
            workDistanceM = value.workDistanceM
            workDurationS = value.workDurationS
            workPaceSPerKm = value.workPaceSPerKm
            intervalPrescription = value.intervalPrescription
            strengthTargetsJSON = value.strengthTargetsJSON
            recoveryDistanceM = value.recoveryDistanceM
            recoveryDurationS = value.recoveryDurationS
            recoveryModeRaw = value.recoveryModeRaw
            successLower = value.successLower
            successUpper = value.successUpper
            recoveryCostRaw = value.recoveryCostRaw
            validSubstitutionIDs = value.validSubstitutionIDs
            minimumCompletedExposures = value.minimumCompletedExposures
            minimumConfidenceRaw = value.minimumConfidenceRaw
            purpose = value.purpose
            ruleIDRaws = value.ruleIDRaws
            limitationRaws = value.limitationRaws
            createdAt = value.createdAt
        }
    }

    struct PlanDecisionDTO: Codable {
        let id: UUID
        let requestID: UUID
        let profileID: UUID
        let planID: UUID?
        let seasonID: UUID
        let decidedAt: Date
        let triggerRaw: String
        let statusRaw: String
        let plannerVersion: String
        let rulesetID: String
        let policyIDRaw: String?
        let oldPlanDigest: String?
        let newPlanDigest: String?
        let diffJSON: Data
        let appliedRuleIDRaws: [String]
        let hardConstraintRaws: [String]
        let relaxedPreferenceRaws: [String]
        let evidenceConfidenceRaws: [String]
        let limitationRaws: [String]
        let headline: String
        let detail: String
        let athleteResponseRaw: String
        let normalizedInputVersion: Int
        let normalizedInputJSON: Data
        let version: Int

        init(_ value: PlanDecisionRecord) {
            id = value.id
            requestID = value.requestID
            profileID = value.profileID
            planID = value.planID
            seasonID = value.seasonID
            decidedAt = value.decidedAt
            triggerRaw = value.triggerRaw
            statusRaw = value.statusRaw
            plannerVersion = value.plannerVersion
            rulesetID = value.rulesetID
            policyIDRaw = value.policyIDRaw
            oldPlanDigest = value.oldPlanDigest
            newPlanDigest = value.newPlanDigest
            diffJSON = value.diffJSON
            appliedRuleIDRaws = value.appliedRuleIDRaws
            hardConstraintRaws = value.hardConstraintRaws
            relaxedPreferenceRaws = value.relaxedPreferenceRaws
            evidenceConfidenceRaws = value.evidenceConfidenceRaws
            limitationRaws = value.limitationRaws
            headline = value.headline
            detail = value.detail
            athleteResponseRaw = value.athleteResponseRaw
            normalizedInputVersion = value.normalizedInputVersion
            normalizedInputJSON = value.normalizedInputJSON
            version = value.version
        }
    }

    /// Background variant for the Settings row: the fetch faults every workout's gps/strength
    /// detail rows and the encode pretty-prints the lot — a perceptible hitch on the main thread
    /// at real history sizes. Runs on a fresh background context; the caller shows a busy row.
    static func exportJSON(container: ModelContainer, now: Date = Date()) async -> Data {
        await Task.detached(priority: .userInitiated) {
            exportJSON(in: ModelContext(container), now: now)
        }.value
    }

    /// A pretty, ISO-8601 JSON snapshot of the athlete's profile, workouts, and complete local
    /// running-planner audit trail. The latter intentionally contains only normalized aggregates—
    /// never raw Health samples, GPS points, exact locations, or unrestricted medical notes.
    nonisolated static func exportJSON(in context: ModelContext, now: Date = Date()) -> Data {
        let profile = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first
        let workouts = (try? context.fetch(
            FetchDescriptor<Workout>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))) ?? []
        let seasons = ((try? context.fetch(FetchDescriptor<RunningSeasonRecord>())) ?? [])
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let events = ((try? context.fetch(FetchDescriptor<RunningEventRecord>())) ?? [])
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let metadata = ((try? context.fetch(FetchDescriptor<PlanMetadataRecord>())) ?? [])
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let intents = ((try? context.fetch(FetchDescriptor<PlannedSessionIntentRecord>())) ?? [])
            .sorted { $0.id < $1.id }
        let decisions = ((try? context.fetch(FetchDescriptor<PlanDecisionRecord>())) ?? [])
            .sorted { $0.id.uuidString < $1.id.uuidString }

        let snapshot = Snapshot(
            exportedAt: now,
            profile: profile.map { p in
                ProfileDTO(displayName: p.displayName, disciplines: p.disciplines, goal: "\(p.goal)",
                           daysPerWeek: p.daysPerWeek, weightUnit: p.weightUnit, distanceUnit: p.distanceUnit)
            },
            workouts: workouts.map { w in
                WorkoutDTO(type: w.type.rawValue, startedAt: w.startedAt, durationS: w.durationS,
                           perceivedEffort: w.perceivedEffort, title: w.title, note: w.note,
                           distanceM: w.gps?.distanceM, avgPaceSPerKm: w.gps?.avgPaceSPerKm,
                           elevationGainM: w.gps?.elevationGainM,
                           totalVolumeKg: w.strength?.totalVolumeKg, totalSets: w.strength?.totalSets)
            },
            runningSeasons: seasons.map(RunningSeasonDTO.init),
            runningEvents: events.map(RunningEventDTO.init),
            planMetadata: metadata.map(PlanMetadataDTO.init),
            plannedSessionIntents: intents.map(PlannedSessionIntentDTO.init),
            planDecisions: decisions.map(PlanDecisionDTO.init)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(snapshot)) ?? Data()
    }

    // MARK: - Delete

    /// Wipe every piece of personal data (PRD §13.3). The bundled exercise catalog (reference data,
    /// not the user's) is preserved. After this `UserProfile` is gone, so the app returns to onboarding.
    ///
    /// Uses per-object deletes (not the bulk `delete(model:)`, which can crash on models with cascade
    /// relationships): deleting each top-level object cascades its children; standalone types are
    /// wiped directly. `Exercise` (the catalog) is intentionally left intact.
    static func deleteAllUserData(in context: ModelContext) {
        // The onboarding resume draft survives outside SwiftData — leaving it meant the wipe's
        // return to onboarding resumed a FINISHED draft onto the post-plan beats with no way to
        // build a profile (the infinite account-beat loop, audit 2026-08-11).
        OnboardingDraftStore.clear()
        func wipe<T: PersistentModel>(_ type: T.Type) {
            for item in (try? context.fetch(FetchDescriptor<T>())) ?? [] { context.delete(item) }
        }
        wipe(UserProfile.self)     // cascades workouts (→ gps/strength), plan, prs, athlete
        wipe(Workout.self)         // any free workouts not under a profile (cascades gps/strength)
        wipe(TrainingPlan.self)
        wipe(PersonalRecord.self)
        wipe(EarnedAward.self)
        wipe(AthleteModel.self)    // cascades its MemoryNote + FitnessSnapshot children
        wipe(ChatMessage.self)
        wipe(PlannedSessionIntentRecord.self)
        wipe(PlanMetadataRecord.self)
        wipe(RunningEventRecord.self)
        wipe(RunningSeasonRecord.self)
        wipe(PlanDecisionRecord.self)
        // Standalone records (no parent relationship to cascade through) — must be wiped explicitly
        // or a reset leaves stale coaching history, inbox notifications, and check-ins behind.
        wipe(CoachingEvent.self)
        wipe(AppNotification.self)
        wipe(DailyCheckin.self)
        wipe(Meal.self)               // food log — standalone since the Fuel tab landed
        wipe(WaterEntry.self)
        ActiveWorkoutMarker.clear()   // drop any in-flight recovery marker
        HealthService.resetDedupe()   // else a post-wipe import silently skips everything
        WidgetBridge.clear()          // the Home Screen widget must not keep the deleted streak
        ReadinessTodayCache.clear()   // nor the strip open on the deleted athlete's score
        // A set-aside store is still this athlete's training history, sitting outside SwiftData
        // where none of the wipes above can see it. Leaving it would make "delete" a lie and would
        // let Settings offer the previous owner's runs to whoever signs in next.
        PersistenceController.purgeQuarantine()
        try? context.save()
    }

    /// Interactive variant for the Settings "Delete all data" row. The synchronous wipe above ran
    /// hundreds of thousands of cascade row deletes (every GPS fix, every HR sample) on the main
    /// context — real histories hard-froze the UI for seconds, and a force-quit mid-hang skipped
    /// the single trailing save so the "deleted" data silently survived. This one runs on a
    /// background context in chunks with a save per chunk (an interrupted wipe stays consistent
    /// and finishes by simply running again), heaviest children first and `UserProfile` LAST —
    /// its disappearance is what flips RootView back to onboarding, so the UI only transitions
    /// when everything else is already gone.
    static func deleteAllUserData(container: ModelContainer) async {
        // Same reason as the synchronous overload: a leftover resume draft re-raises the tail of
        // a finished onboarding once the profile is gone.
        OnboardingDraftStore.clear()
        await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            func wipe<T: PersistentModel>(_ type: T.Type, chunk: Int = 32) {
                while true {
                    var fd = FetchDescriptor<T>()
                    fd.fetchLimit = chunk
                    let batch = (try? context.fetch(fd)) ?? []
                    if batch.isEmpty { break }
                    for item in batch { context.delete(item) }
                    try? context.save()
                }
            }
            wipe(Workout.self, chunk: 8)   // cascades gps samples + strength sets — the heavy rows
            wipe(TrainingPlan.self)
            wipe(PersonalRecord.self)
            wipe(EarnedAward.self)
            wipe(AthleteModel.self)
            wipe(ChatMessage.self)
            wipe(PlannedSessionIntentRecord.self)
            wipe(PlanMetadataRecord.self)
            wipe(RunningEventRecord.self)
            wipe(RunningSeasonRecord.self)
            wipe(PlanDecisionRecord.self)
            wipe(CoachingEvent.self)
            wipe(AppNotification.self)
            wipe(DailyCheckin.self)
            wipe(Meal.self)
            wipe(WaterEntry.self)
            wipe(UserProfile.self)
        }.value
        ActiveWorkoutMarker.clear()   // drop any in-flight recovery marker
        HealthService.resetDedupe()   // else a post-wipe import silently skips everything
        WidgetBridge.clear()          // the Home Screen widget must not keep the deleted streak
        ReadinessTodayCache.clear()   // nor the strip open on the deleted athlete's score
        PersistenceController.purgeQuarantine()   // see the sync variant — "delete" must mean it
    }
}

/// A JSON file for `.fileExporter` (Save to Files / share).
struct JSONExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
