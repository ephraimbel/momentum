import Foundation

/// Where a plan-critical observation came from. Health remains a signal source only: it can
/// describe recovery context, but it can never prove that training happened.
enum RunningEvidenceSource: String, Codable, CaseIterable, Hashable, Sendable {
    case momentumWorkout
    case athleteEntry
    case fieldTest
    case raceResult
    case healthSignal
    case derived

    var canRepresentCompletedTrainingExposure: Bool {
        self != .healthSignal
    }
}

/// Deliberately categorical. A made-up percentage would imply precision the underlying evidence
/// does not have.
enum RunningEvidenceConfidence: String, Codable, CaseIterable, Comparable, Hashable, Sendable {
    case unknown
    case low
    case moderate
    case high

    private var rank: Int {
        switch self {
        case .unknown: 0
        case .low: 1
        case .moderate: 2
        case .high: 3
        }
    }

    static func < (lhs: RunningEvidenceConfidence, rhs: RunningEvidenceConfidence) -> Bool {
        lhs.rank < rhs.rank
    }
}

enum RunningEvidenceLimitation: String, Codable, CaseIterable, Hashable, Sendable {
    case stale
    case smallSample
    case selfReported
    case poorGPS
    case missingRPE
    case missingEnvironment
    case nonComparableConditions
    case partialSession
    case outsideObservedDuration
    case healthSignalCannotCountAsTraining
    case legacyAggregate
    case unstructuredLegacyInterval
    case noProgressionGate
}

enum RunningEvidenceValidationIssue: String, Codable, Equatable, Sendable {
    case nonPositiveSampleCount
    case observationPrecedesWindow
    case highConfidenceHasKnownLimitations
}

/// Immutable evidence envelope used by the pure running domain. It stores only the aggregate a rule
/// consumes, never raw Health samples, GPS points, routes, or unrestricted notes.
struct RunningEvidence<Value: Sendable>: Sendable {
    let value: Value
    let source: RunningEvidenceSource
    let observedAt: Date
    let window: DateInterval?
    let sampleCount: Int
    let confidence: RunningEvidenceConfidence
    let limitations: Set<RunningEvidenceLimitation>

    init(value: Value,
         source: RunningEvidenceSource,
         observedAt: Date,
         window: DateInterval? = nil,
         sampleCount: Int,
         confidence: RunningEvidenceConfidence,
         limitations: Set<RunningEvidenceLimitation> = []) {
        self.value = value
        self.source = source
        self.observedAt = observedAt
        self.window = window
        self.sampleCount = sampleCount
        self.confidence = confidence
        self.limitations = limitations
    }

    /// Validation reports bad evidence instead of silently clamping it into something credible.
    var validationIssues: [RunningEvidenceValidationIssue] {
        var issues: [RunningEvidenceValidationIssue] = []
        if sampleCount <= 0 { issues.append(.nonPositiveSampleCount) }
        if let window, observedAt < window.start {
            issues.append(.observationPrecedesWindow)
        }
        if confidence == .high, !limitations.isEmpty {
            issues.append(.highConfidenceHasKnownLimitations)
        }
        return issues
    }

    func addingLimitations(_ additional: Set<RunningEvidenceLimitation>,
                           confidence loweredConfidence: RunningEvidenceConfidence? = nil)
        -> RunningEvidence<Value> {
        RunningEvidence(
            value: value,
            source: source,
            observedAt: observedAt,
            window: window,
            sampleCount: sampleCount,
            confidence: min(confidence, loweredConfidence ?? confidence),
            limitations: limitations.union(additional)
        )
    }
}

extension RunningEvidence: Equatable where Value: Equatable {}
extension RunningEvidence: Hashable where Value: Hashable {}
extension RunningEvidence: Codable where Value: Codable {}

