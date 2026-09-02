import Foundation

/// Wire-level target vocabulary shared by the iPhone and Watch targets. It intentionally does not
/// depend on the planner module so an older watch can decode a compact prescription independently.
enum ExecutionTargetKind: String, Codable, CaseIterable, Hashable, Sendable {
    case distance
    case duration
    case pace
    case effort
    case heartRate
    case intervalStructure
    case completion
    case strengthPrescription
}

struct ExecutionTargetHierarchy: Codable, Equatable, Sendable {
    let primary: ExecutionTargetKind
    let fallbacks: [ExecutionTargetKind]

    init(primary: ExecutionTargetKind, fallbacks: [ExecutionTargetKind] = []) {
        self.primary = primary
        var seen: Set<ExecutionTargetKind> = [primary]
        self.fallbacks = fallbacks.filter { seen.insert($0).inserted }
    }
}

struct ExecutionValueRange: Codable, Equatable, Sendable {
    let lower: Double
    let upper: Double

    var isValid: Bool { lower.isFinite && upper.isFinite && lower <= upper }
}

/// The fields every currently shipped surface already understands. They travel inside the new
/// payload and remain duplicated as top-level WatchConnectivity keys during version transition.
struct LegacyExecutionFields: Codable, Equatable, Sendable {
    let discipline: Discipline
    let runType: RunType?
    let targetDistanceM: Double?
    let targetDurationS: Double?
    let targetPaceSPerKm: Double?
    let intervalPrescription: String?
}

struct ExecutionTargetContract: Codable, Equatable, Sendable {
    let hierarchy: ExecutionTargetHierarchy
    let distanceM: Double?
    let durationS: Double?
    let paceSPerKm: Double?
    let effortCue: String?
    let intervalPrescription: String?
    let recoveryDistanceM: Double?
    let recoveryDurationS: Double?
    let recoveryMode: ExecutionTargetKind?
    let successRange: ExecutionValueRange?
}

/// One execution contract for Today, detail, live capture, Watch, and review. Version 1 preserves
/// the complete legacy prescription so unsupported clients can always execute a safe run.
struct ExecutionPrescription: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let planID: String
    let sessionID: String
    let intentID: String?
    let intentVersion: Int?
    let target: ExecutionTargetContract
    let legacy: LegacyExecutionFields
    let structuredWorkout: StructuredWorkout?
    let purpose: String

    var validationIssues: [ExecutionPrescriptionValidationIssue] {
        var issues: [ExecutionPrescriptionValidationIssue] = []
        if schemaVersion != Self.currentSchemaVersion { issues.append(.unsupportedSchemaVersion) }
        if planID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.missingStableIdentifier)
        }
        if intentID != nil, intentVersion.map({ $0 <= 0 }) != false {
            issues.append(.invalidIntentVersion)
        }
        let numeric = [
            target.distanceM, target.durationS, target.paceSPerKm,
            target.recoveryDistanceM, target.recoveryDurationS,
            legacy.targetDistanceM, legacy.targetDurationS, legacy.targetPaceSPerKm,
        ].compactMap { $0 }
        if numeric.contains(where: { !$0.isFinite || $0 <= 0 }) { issues.append(.invalidSIValue) }
        if target.successRange.map({ !$0.isValid }) == true { issues.append(.invalidSuccessRange) }
        if target.hierarchy.primary == .distance && target.distanceM == nil
            || target.hierarchy.primary == .duration && target.durationS == nil
            || target.hierarchy.primary == .pace && target.paceSPerKm == nil
            || target.hierarchy.primary == .intervalStructure
                && target.intervalPrescription?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            issues.append(.missingPrimaryTarget)
        }
        if let structuredWorkout, structuredWorkout.steps.contains(where: { step in
            let targetIsValid: Bool = switch step.target {
            case let .distance(value), let .duration(value): value.isFinite && value > 0
            }
            return !targetIsValid || step.paceSPerKm.map { !$0.isFinite || $0 <= 0 } == true
        }) {
            issues.append(.invalidStructuredStep)
        }
        return Array(Set(issues)).sorted { $0.rawValue < $1.rawValue }
    }
}

enum ExecutionPrescriptionValidationIssue: String, Codable, CaseIterable, Hashable, Sendable {
    case unsupportedSchemaVersion
    case missingStableIdentifier
    case invalidIntentVersion
    case invalidSIValue
    case invalidSuccessRange
    case missingPrimaryTarget
    case invalidStructuredStep
}

enum ExecutionPrescriptionSource: String, Codable, CaseIterable, Sendable {
    case versioned
    case legacyMissingPayload
    case legacyMalformedPayload
    case legacyUnsupportedVersion
    case legacyInvalidPayload
}

struct ResolvedExecutionPrescription: Equatable, Sendable {
    let source: ExecutionPrescriptionSource
    let prescription: ExecutionPrescription?
    let legacy: LegacyExecutionFields

    var target: ExecutionTargetContract? { prescription?.target }
    var structuredWorkout: StructuredWorkout? { prescription?.structuredWorkout }
    var purpose: String? { prescription?.purpose }
}

/// Version skew is a normal state, not an error. Unknown/malformed/invalid payloads return the
/// caller-supplied legacy fields without throwing, crashing, or blocking the workout.
enum ExecutionPrescriptionResolver {
    private struct Envelope: Decodable { let schemaVersion: Int }

    static func resolve(_ data: Data?,
                        legacyFallback: LegacyExecutionFields,
                        decoder: JSONDecoder = JSONDecoder()) -> ResolvedExecutionPrescription {
        guard let data else {
            return ResolvedExecutionPrescription(
                source: .legacyMissingPayload,
                prescription: nil,
                legacy: legacyFallback
            )
        }
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
            return ResolvedExecutionPrescription(
                source: .legacyMalformedPayload,
                prescription: nil,
                legacy: legacyFallback
            )
        }
        guard envelope.schemaVersion == ExecutionPrescription.currentSchemaVersion else {
            return ResolvedExecutionPrescription(
                source: .legacyUnsupportedVersion,
                prescription: nil,
                legacy: legacyFallback
            )
        }
        guard let prescription = try? decoder.decode(ExecutionPrescription.self, from: data) else {
            return ResolvedExecutionPrescription(
                source: .legacyMalformedPayload,
                prescription: nil,
                legacy: legacyFallback
            )
        }
        guard prescription.validationIssues.isEmpty else {
            return ResolvedExecutionPrescription(
                source: .legacyInvalidPayload,
                prescription: nil,
                legacy: legacyFallback
            )
        }
        return ResolvedExecutionPrescription(
            source: .versioned,
            prescription: prescription,
            legacy: prescription.legacy
        )
    }
}
