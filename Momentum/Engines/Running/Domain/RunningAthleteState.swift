import Foundation

/// A typed range prevents callers from losing which side is lower and keeps unknown distinct from
/// an invented midpoint.
struct RunningValueRange: Codable, Equatable, Hashable, Sendable {
    let lower: Double
    let upper: Double

    init(lower: Double, upper: Double) {
        self.lower = lower
        self.upper = upper
    }

    var isValid: Bool {
        lower.isFinite && upper.isFinite && lower <= upper
    }
}

struct RunningWeeklyDistribution: Codable, Equatable, Sendable {
    /// Oldest to newest; each value is SI meters and represents one complete calendar/training week.
    let distanceM: [Double]
    /// Oldest to newest; SI seconds for the same weeks when known.
    let durationS: [Double]
}

struct RunningContinuity: Codable, Equatable, Sendable {
    let activeWeeks: Int
    let observedWeeks: Int
    let currentConsecutiveWeeks: Int
}

struct RunningPerformancePoint: Codable, Equatable, Sendable {
    let distanceM: Double
    let durationS: Double
    let paceSPerKm: Double
}

struct RunningPerformanceCurve: Codable, Equatable, Sendable {
    let points: [RunningPerformancePoint]
    /// Durations actually represented by the evidence. Extrapolations outside this range must carry
    /// `.outsideObservedDuration`.
    let observedDurationBoundsS: RunningValueRange
}

enum RunningThresholdMethod: String, Codable, CaseIterable, Sendable {
    case fieldTest
    case raceResult
    case workoutEstimate
    case athleteEntry
}

struct RunningThresholdProxy: Codable, Equatable, Sendable {
    let paceSPerKm: Double?
    let heartRateBPM: Double?
    let method: RunningThresholdMethod
}

enum RunningTrendDirection: String, Codable, CaseIterable, Sendable {
    case improving
    case stable
    case declining
    case indeterminate
}

struct RunningEasyEffortTrend: Codable, Equatable, Sendable {
    let direction: RunningTrendDirection
    let paceSPerKm: RunningValueRange?
    let heartRateBPM: RunningValueRange?
    let perceivedEffort: RunningValueRange?
    let comparableSessionCount: Int
}

struct RunningDurability: Codable, Equatable, Sendable {
    /// Longest observed continuous easy/long duration.
    let observedDurationS: Double
    /// Fraction of comparable long sessions completed within their intended effort/dose, 0...1.
    let completionFraction: Double?
    let lateSessionResponse: RunningTrendDirection
}

enum RunningSessionClass: String, Codable, CaseIterable, Hashable, Sendable {
    case easy
    case quality
    case long
    case downhill
    case lowerBodyStrength
}

enum RunningToleranceBand: String, Codable, CaseIterable, Sendable {
    case unknown
    case limited
    case developing
    case established
}

struct RunningToleranceObservation: Codable, Equatable, Sendable {
    let band: RunningToleranceBand
    let completedExposureCount: Int
    let typicalRecoveryS: RunningValueRange?
}

struct RunningRecoveryInterval: Codable, Equatable, Sendable {
    let afterEasyS: RunningValueRange?
    let afterQualityS: RunningValueRange?
    let afterLongS: RunningValueRange?
    let afterLowerStrengthS: RunningValueRange?
}

enum RunningAdherencePattern: String, Codable, CaseIterable, Sendable {
    case unknown
    case consistent
    case variable
    case weekdayConstrained
    case weekendConstrained
}

struct RunningScheduleAdherence: Codable, Equatable, Sendable {
    let pattern: RunningAdherencePattern
    /// Calendar weekdays use Foundation's 1...7 convention; empty means no supported inference.
    let commonlyCompletedWeekdays: Set<Int>
    let commonlyMissedWeekdays: Set<Int>
    let completionFraction: Double?
}

enum RunningResponseFlag: String, Codable, CaseIterable, Hashable, Sendable {
    case sessionFeltHarderThanPlanned
    case repeatedIncompleteQuality
    case repeatedIncompleteLongRun
    case improvingAtComparableEffort
    case worseningAtComparableEffort
    case activeSymptomsReported
    case acuteIllnessConcern
}

struct RunningEnvironmentEvidence: Codable, Equatable, Sendable {
    let dominantSurface: RunningEventSurface
    let altitude: RunningEnvironmentBand
    let climate: RunningEnvironmentBand
    let elevationChangeMPerKm: RunningValueRange?
}

/// Only state that currently changes, or is explicitly reserved to change, a road-core decision.
/// There is intentionally no universal readiness score, injury probability, economy score, or
/// inferred menstrual phase.
struct RunningAthleteState: Codable, Equatable, Sendable {
    let currentFrequency: RunningEvidence<Int>?
    let weeklyDistribution: RunningEvidence<RunningWeeklyDistribution>?
    let continuity: RunningEvidence<RunningContinuity>?
    let longestRecentRunM: RunningEvidence<Double>?
    let performanceCurve: RunningEvidence<RunningPerformanceCurve>?
    let thresholdProxy: RunningEvidence<RunningThresholdProxy>?
    let easyEffortTrend: RunningEvidence<RunningEasyEffortTrend>?
    let durability: RunningEvidence<RunningDurability>?
    let toleranceBySessionClass: [RunningSessionClass: RunningEvidence<RunningToleranceObservation>]
    let typicalRecoveryInterval: RunningEvidence<RunningRecoveryInterval>?
    let scheduleAdherence: RunningEvidence<RunningScheduleAdherence>?
    let recentResponseFlags: RunningEvidence<Set<RunningResponseFlag>>?
    let environment: RunningEvidence<RunningEnvironmentEvidence>?

    init(currentFrequency: RunningEvidence<Int>? = nil,
         weeklyDistribution: RunningEvidence<RunningWeeklyDistribution>? = nil,
         continuity: RunningEvidence<RunningContinuity>? = nil,
         longestRecentRunM: RunningEvidence<Double>? = nil,
         performanceCurve: RunningEvidence<RunningPerformanceCurve>? = nil,
         thresholdProxy: RunningEvidence<RunningThresholdProxy>? = nil,
         easyEffortTrend: RunningEvidence<RunningEasyEffortTrend>? = nil,
         durability: RunningEvidence<RunningDurability>? = nil,
         toleranceBySessionClass: [RunningSessionClass: RunningEvidence<RunningToleranceObservation>] = [:],
         typicalRecoveryInterval: RunningEvidence<RunningRecoveryInterval>? = nil,
         scheduleAdherence: RunningEvidence<RunningScheduleAdherence>? = nil,
         recentResponseFlags: RunningEvidence<Set<RunningResponseFlag>>? = nil,
         environment: RunningEvidence<RunningEnvironmentEvidence>? = nil) {
        self.currentFrequency = currentFrequency
        self.weeklyDistribution = weeklyDistribution
        self.continuity = continuity
        self.longestRecentRunM = longestRecentRunM
        self.performanceCurve = performanceCurve
        self.thresholdProxy = thresholdProxy
        self.easyEffortTrend = easyEffortTrend
        self.durability = durability
        self.toleranceBySessionClass = toleranceBySessionClass
        self.typicalRecoveryInterval = typicalRecoveryInterval
        self.scheduleAdherence = scheduleAdherence
        self.recentResponseFlags = recentResponseFlags
        self.environment = environment
    }

    static let unknown = RunningAthleteState()

    /// Every evidence envelope, in a stable order, for validation and decision-trace summaries.
    var evidenceSummaries: [RunningEvidenceSummary] {
        var result: [RunningEvidenceSummary] = []
        func append<Value>(_ key: String, _ evidence: RunningEvidence<Value>?) {
            guard let evidence else { return }
            result.append(RunningEvidenceSummary(
                dimension: key,
                source: evidence.source,
                observedAt: evidence.observedAt,
                sampleCount: evidence.sampleCount,
                confidence: evidence.confidence,
                limitations: evidence.limitations
            ))
        }
        append("currentFrequency", currentFrequency)
        append("weeklyDistribution", weeklyDistribution)
        append("continuity", continuity)
        append("longestRecentRunM", longestRecentRunM)
        append("performanceCurve", performanceCurve)
        append("thresholdProxy", thresholdProxy)
        append("easyEffortTrend", easyEffortTrend)
        append("durability", durability)
        for key in RunningSessionClass.allCases {
            append("tolerance.\(key.rawValue)", toleranceBySessionClass[key])
        }
        append("typicalRecoveryInterval", typicalRecoveryInterval)
        append("scheduleAdherence", scheduleAdherence)
        append("recentResponseFlags", recentResponseFlags)
        append("environment", environment)
        return result
    }
}

struct RunningEvidenceSummary: Codable, Equatable, Sendable {
    let dimension: String
    let source: RunningEvidenceSource
    let observedAt: Date
    let sampleCount: Int
    let confidence: RunningEvidenceConfidence
    let limitations: Set<RunningEvidenceLimitation>
}
