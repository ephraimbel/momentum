import Foundation

enum RunningStimulus: String, Codable, CaseIterable, Sendable {
    case recovery
    case aerobicEndurance
    case longEndurance
    case threshold
    case vo2
    case speedNeuromuscular
    case hillStrength
    case raceSpecific
    case progression
    case strengthSupport
    case competition
    case unstructured
}

enum RunningIntentSessionClass: String, Codable, CaseIterable, Sendable {
    case easy
    case quality
    case long
    case race
    case strength
    case crossTraining
}

enum RunningHardClass: String, Codable, CaseIterable, Sendable {
    case none
    case hardRun
    case hardLowerBodyStrength
}

enum RunningTargetKind: String, Codable, CaseIterable, Hashable, Sendable {
    case distance
    case duration
    case pace
    case effort
    case heartRate
    case intervalStructure
    case completion
    case strengthPrescription
}

struct RunningTargetHierarchy: Codable, Equatable, Sendable {
    let primary: RunningTargetKind
    let fallbacks: [RunningTargetKind]

    init(primary: RunningTargetKind, fallbacks: [RunningTargetKind] = []) {
        self.primary = primary
        var seen: Set<RunningTargetKind> = [primary]
        self.fallbacks = fallbacks.filter { seen.insert($0).inserted }
    }
}

struct RunningWorkDose: Codable, Equatable, Sendable {
    let distanceM: Double?
    let durationS: Double?
    let paceSPerKm: Double?
    /// A structured interval prescription is intentionally absent from the legacy adapter until the
    /// display string is replaced by typed work/recovery steps.
    let intervalPrescription: String?
    let strengthTargets: [RunningStrengthTarget]
}

struct RunningStrengthTarget: Codable, Equatable, Sendable {
    let exerciseName: String
    let targetSets: Int
    let repLow: Int
    let repHigh: Int
    let targetRPE: Double?
    let targetPctRM: Double?
    let progression: String

    init(_ exercise: GeneratedExercise) {
        exerciseName = exercise.exerciseName
        targetSets = exercise.targetSets
        repLow = exercise.repLow
        repHigh = exercise.repHigh
        targetRPE = exercise.targetRPE
        targetPctRM = exercise.targetPctRM
        progression = exercise.progression
    }
}

struct RunningRecoveryDose: Codable, Equatable, Sendable {
    let distanceM: Double?
    let durationS: Double?
    let mode: RunningTargetKind?
}

enum RunningRecoveryCostBand: String, Codable, CaseIterable, Sendable {
    case low
    case moderate
    case high
    case unknown
}

struct RunningProgressionEvidenceRequirement: Codable, Equatable, Sendable {
    let minimumCompletedExposures: Int
    let minimumConfidence: RunningEvidenceConfidence
}

/// The semantic prescription consumed by planning, execution, explanation and—later—the watch. Its
/// stable string ID is deterministic within a request; no random UUID enters semantic output.
struct SessionIntent: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let version: Int
    let weekIndex: Int
    let dayOffset: Int
    let discipline: Discipline
    let legacyRunType: RunType?
    let stimulus: RunningStimulus
    let sessionClass: RunningIntentSessionClass
    let progressionLevel: Int
    let hardClass: RunningHardClass
    let targetHierarchy: RunningTargetHierarchy
    let workDose: RunningWorkDose
    let recoveryDose: RunningRecoveryDose?
    let successRange: RunningValueRange?
    let expectedRecoveryCost: RunningRecoveryCostBand
    let validSubstitutionIDs: [String]
    let minimumEvidenceToProgress: RunningProgressionEvidenceRequirement
    let purpose: String
    let ruleIDs: [RunningRuleID]
    let limitations: Set<RunningEvidenceLimitation>

    /// Policies refine legacy-backed intent semantics without changing the stable identity or raw
    /// dose. Keeping the copy operation here prevents one policy from accidentally omitting a
    /// field when it changes target priority or an exit-evidence requirement.
    func replacing(
        targetHierarchy: RunningTargetHierarchy? = nil,
        minimumEvidenceToProgress: RunningProgressionEvidenceRequirement? = nil,
        purpose: String? = nil,
        additionalRuleIDs: Set<RunningRuleID> = [],
        additionalLimitations: Set<RunningEvidenceLimitation> = []
    ) -> SessionIntent {
        SessionIntent(
            id: id,
            version: version,
            weekIndex: weekIndex,
            dayOffset: dayOffset,
            discipline: discipline,
            legacyRunType: legacyRunType,
            stimulus: stimulus,
            sessionClass: sessionClass,
            progressionLevel: progressionLevel,
            hardClass: hardClass,
            targetHierarchy: targetHierarchy ?? self.targetHierarchy,
            workDose: workDose,
            recoveryDose: recoveryDose,
            successRange: successRange,
            expectedRecoveryCost: expectedRecoveryCost,
            validSubstitutionIDs: validSubstitutionIDs,
            minimumEvidenceToProgress: minimumEvidenceToProgress ?? self.minimumEvidenceToProgress,
            purpose: purpose ?? self.purpose,
            ruleIDs: Set(ruleIDs).union(additionalRuleIDs).sorted { $0.rawValue < $1.rawValue },
            limitations: limitations.union(additionalLimitations)
        )
    }
}
