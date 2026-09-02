import Foundation

enum RunningSeasonStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case active
    case complete
    case archived
}

enum RunningPrimaryOutcome: String, Codable, CaseIterable, Sendable {
    case finish
    case finishStrong
    case targetTime
    case placement
    case qualify
    case buildBase
    case returnToRunning

    var requiresPrimaryEvent: Bool {
        switch self {
        // A finish/time goal may be intentionally undated while the athlete chooses a race. A
        // placement or qualification target, by contrast, has no meaning without a named event.
        case .placement, .qualify: true
        case .finish, .finishStrong, .targetTime, .buildBase, .returnToRunning: false
        }
    }
}

enum RunningMotivation: String, Codable, CaseIterable, Hashable, Sendable {
    case health
    case consistency
    case confidence
    case stress
    case bodyComposition
    case performance
}

enum RunningEventPriority: String, Codable, CaseIterable, Comparable, Sendable {
    case a
    case b
    case c

    private var rank: Int {
        switch self { case .a: 0; case .b: 1; case .c: 2 }
    }

    static func < (lhs: RunningEventPriority, rhs: RunningEventPriority) -> Bool {
        lhs.rank < rhs.rank
    }
}

enum RunningEventSurface: String, Codable, CaseIterable, Sendable {
    case road
    case track
    case treadmill
    case trail
    case mixed
    case unknown
}

enum RunningEventStatus: String, Codable, CaseIterable, Sendable {
    case planned
    case completed
    case withdrawn
    case cancelled
}

enum RunningEnvironmentBand: String, Codable, CaseIterable, Sendable {
    case low
    case moderate
    case high
    case unknown
}

struct RunningSeasonEvent: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let date: Date
    /// SI distance. nil is valid for a time-based event.
    let distanceM: Double?
    /// SI duration for a time-based event or explicit target-time outcome.
    let durationS: Double?
    let priority: RunningEventPriority
    let surface: RunningEventSurface
    let ascentM: Double?
    let descentM: Double?
    let altitude: RunningEnvironmentBand
    let technicality: RunningEnvironmentBand
    let climate: RunningEnvironmentBand
    let status: RunningEventStatus

    init(id: UUID,
         name: String,
         date: Date,
         distanceM: Double?,
         durationS: Double? = nil,
         priority: RunningEventPriority,
         surface: RunningEventSurface = .road,
         ascentM: Double? = nil,
         descentM: Double? = nil,
         altitude: RunningEnvironmentBand = .unknown,
         technicality: RunningEnvironmentBand = .unknown,
         climate: RunningEnvironmentBand = .unknown,
         status: RunningEventStatus = .planned) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.date = date
        self.distanceM = distanceM
        self.durationS = durationS
        self.priority = priority
        self.surface = surface
        self.ascentM = ascentM
        self.descentM = descentM
        self.altitude = altitude
        self.technicality = technicality
        self.climate = climate
        self.status = status
    }
}

enum RunningSeasonValidationCode: String, Codable, CaseIterable, Sendable {
    case duplicateEventID
    case multiplePrimaryEvents
    case missingPrimaryEvent
    case invalidEventDistance
    case invalidEventDuration
    case invalidEventElevation
}

struct RunningSeasonValidationIssue: Codable, Equatable, Sendable {
    let code: RunningSeasonValidationCode
    let eventID: UUID?
}

/// A season outlives a replaceable plan. Its name is the athlete's stable plan name; macrocycle
/// labels never silently rename it.
struct RunningSeason: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let status: RunningSeasonStatus
    let primaryOutcome: RunningPrimaryOutcome
    let motivations: Set<RunningMotivation>
    let events: [RunningSeasonEvent]

    init(id: UUID,
         name: String,
         status: RunningSeasonStatus,
         primaryOutcome: RunningPrimaryOutcome,
         motivations: Set<RunningMotivation> = [],
         events: [RunningSeasonEvent] = []) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.status = status
        self.primaryOutcome = primaryOutcome
        self.motivations = motivations
        self.events = events.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    var primaryEvent: RunningSeasonEvent? {
        events.first { $0.priority == .a && $0.status == .planned }
    }

    var validationIssues: [RunningSeasonValidationIssue] {
        var issues: [RunningSeasonValidationIssue] = []
        var seen = Set<UUID>()
        for event in events {
            if !seen.insert(event.id).inserted {
                issues.append(.init(code: .duplicateEventID, eventID: event.id))
            }
            if let value = event.distanceM, !value.isFinite || value <= 0 {
                issues.append(.init(code: .invalidEventDistance, eventID: event.id))
            }
            if let value = event.durationS, !value.isFinite || value <= 0 {
                issues.append(.init(code: .invalidEventDuration, eventID: event.id))
            }
            if [event.ascentM, event.descentM].compactMap({ $0 }).contains(where: { !$0.isFinite || $0 < 0 }) {
                issues.append(.init(code: .invalidEventElevation, eventID: event.id))
            }
        }
        let primaryCount = events.filter { $0.priority == .a && $0.status == .planned }.count
        if primaryCount > 1 {
            issues.append(.init(code: .multiplePrimaryEvents, eventID: nil))
        }
        if primaryOutcome.requiresPrimaryEvent, primaryCount == 0 {
            issues.append(.init(code: .missingPrimaryEvent, eventID: nil))
        }
        return issues
    }
}
