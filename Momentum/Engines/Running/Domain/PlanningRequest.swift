import Foundation

enum RunningCalendarError: Error, Equatable, Sendable {
    case invalidTimeZone(String)
    case invalidIdentifier(String)
    case invalidFirstWeekday(Int)
    case invalidMinimumDays(Int)
}

/// Codable calendar identity used for deterministic local-day math and replay.
struct RunningCalendarConfiguration: Codable, Equatable, Sendable {
    let identifier: String
    let localeIdentifier: String?
    let timeZoneIdentifier: String
    let firstWeekday: Int
    let minimumDaysInFirstWeek: Int

    init(_ calendar: Calendar) {
        identifier = String(describing: calendar.identifier)
        localeIdentifier = calendar.locale?.identifier
        timeZoneIdentifier = calendar.timeZone.identifier
        firstWeekday = calendar.firstWeekday
        minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek
    }

    func value() throws -> Calendar {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw RunningCalendarError.invalidTimeZone(timeZoneIdentifier)
        }
        guard (1...7).contains(firstWeekday) else {
            throw RunningCalendarError.invalidFirstWeekday(firstWeekday)
        }
        guard (1...7).contains(minimumDaysInFirstWeek) else {
            throw RunningCalendarError.invalidMinimumDays(minimumDaysInFirstWeek)
        }
        var calendar = Calendar(identifier: try Self.decode(identifier))
        calendar.locale = localeIdentifier.map(Locale.init(identifier:))
        calendar.timeZone = timeZone
        calendar.firstWeekday = firstWeekday
        calendar.minimumDaysInFirstWeek = minimumDaysInFirstWeek
        return calendar
    }

    private static func decode(_ value: String) throws -> Calendar.Identifier {
        switch value {
        case "gregorian": .gregorian
        case "buddhist": .buddhist
        case "chinese": .chinese
        case "coptic": .coptic
        case "ethiopic": .ethiopicAmeteMihret
        case "ethioaa": .ethiopicAmeteAlem
        case "hebrew": .hebrew
        case "iso8601": .iso8601
        case "indian": .indian
        case "islamic": .islamic
        case "islamic-civil": .islamicCivil
        case "japanese": .japanese
        case "persian": .persian
        case "roc": .republicOfChina
        case "islamic-tbla": .islamicTabular
        case "islamic-umalqura": .islamicUmmAlQura
        default: throw RunningCalendarError.invalidIdentifier(value)
        }
    }
}

enum RunningPlanningAuthority: String, Codable, CaseIterable, Sendable {
    /// A new or replacement coached plan explicitly requested by the athlete.
    case athleteRequestedCoaching
    /// A coach-initiated rebuild/adaptation. Must stand down for self-coached plans.
    case automaticCoach
    /// Read-only evaluation. Must never authorize persistence.
    case shadowOnly
}

enum RunningPlanningTrigger: String, Codable, CaseIterable, Sendable {
    case initialPlan
    case athleteAdjustment
    case newGoal
    case blockRenewal
    case postRaceRecovery
    case automaticAdaptation
    case shadowEvaluation
}

struct RunningGoalContract: Codable, Equatable, Sendable {
    let outcome: RunningPrimaryOutcome
    let targetDistanceM: Double?
    let targetDurationS: Double?

    init(outcome: RunningPrimaryOutcome,
         targetDistanceM: Double? = nil,
         targetDurationS: Double? = nil) {
        self.outcome = outcome
        self.targetDistanceM = targetDistanceM
        self.targetDurationS = targetDurationS
    }
}

enum RunningFixedDateKind: String, Codable, CaseIterable, Sendable {
    case unavailable
    case fixedRun
    case fixedStrength
    case travel
    case event
}

struct RunningFixedDate: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let date: Date
    let kind: RunningFixedDateKind
}

struct RunningAthleteOverrides: Codable, Equatable, Sendable {
    let intensity: PlanIntensity
    let targetWeeklyDistanceM: Double?
    let hybridPriority: HybridPriority?
    let strengthSplit: StrengthSplitStyle
    let muscleFocus: Set<MuscleGroup>

    init(intensity: PlanIntensity = .balanced,
         targetWeeklyDistanceM: Double? = nil,
         hybridPriority: HybridPriority? = nil,
         strengthSplit: StrengthSplitStyle = .coach,
         muscleFocus: Set<MuscleGroup> = []) {
        self.intensity = intensity
        self.targetWeeklyDistanceM = targetWeeklyDistanceM
        self.hybridPriority = hybridPriority
        self.strengthSplit = strengthSplit
        self.muscleFocus = muscleFocus
    }
}

struct RunningAvailability: Codable, Equatable, Sendable {
    let trainingDaysPerWeek: Int
    /// Foundation weekday values, 1...7. Empty means no explicit weekday preference.
    let preferredWeekdays: Set<Int>
    /// Offset from the planning anchor, 0...6. This preserves the legacy scheduler contract while
    /// the ordered Release-1 scheduler is still shadow-only.
    let preferredDayOffsets: Set<Int>
    let fixedDates: [RunningFixedDate]
    let sessionTimeCeilingS: Double?
    let equipment: Equipment
    let overrides: RunningAthleteOverrides

    init(trainingDaysPerWeek: Int,
         preferredWeekdays: Set<Int> = [],
         preferredDayOffsets: Set<Int> = [],
         fixedDates: [RunningFixedDate] = [],
         sessionTimeCeilingS: Double? = nil,
         equipment: Equipment,
         overrides: RunningAthleteOverrides = RunningAthleteOverrides()) {
        self.trainingDaysPerWeek = trainingDaysPerWeek
        self.preferredWeekdays = preferredWeekdays
        self.preferredDayOffsets = preferredDayOffsets
        self.fixedDates = fixedDates.sorted {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
        }
        self.sessionTimeCeilingS = sessionTimeCeilingS
        self.equipment = equipment
        self.overrides = overrides
    }
}

enum RunningRestrictionKind: String, Codable, CaseIterable, Sendable {
    case noRunning
    case easyOnly
    case noSpeed
    case noHills
    case noDownhill
    case noLowerBodyStrength
    case distanceCap
    case durationCap
}

enum RunningRestrictionSource: String, Codable, CaseIterable, Sendable {
    case athlete
    case clinician
    case injuryResponse
    case acuteIllnessGate
    case operational
}

struct ActiveRunningRestriction: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let kind: RunningRestrictionKind
    let source: RunningRestrictionSource
    let startsAt: Date
    let endsAt: Date?
    /// SI amount for the two cap restrictions; nil for categorical restrictions.
    let maximum: Double?
}

struct ExistingRunningSessionSnapshot: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let date: Date
    let status: SessionStatus
    let discipline: Discipline
    let sportType: String?
    let runType: RunType?
    let targetDistanceM: Double?
    let targetDurationS: Double?
    let targetPaceSPerKm: Double?
    let intervals: String?
    let strengthLabel: String?
    let strengthTargets: [StrengthTarget]
    let completedWorkoutID: UUID?

    struct StrengthTarget: Codable, Equatable, Sendable {
        let order: Int
        let exerciseName: String
        let targetSets: Int
        let targetRepLow: Int
        let targetRepHigh: Int
        let targetRPE: Double?
        let targetPctRM: Double?
        let progression: String
    }

    init(id: UUID,
         date: Date,
         status: SessionStatus,
         discipline: Discipline,
         sportType: String? = nil,
         runType: RunType?,
         targetDistanceM: Double? = nil,
         targetDurationS: Double? = nil,
         targetPaceSPerKm: Double? = nil,
         intervals: String? = nil,
         strengthLabel: String? = nil,
         strengthTargets: [StrengthTarget] = [],
         completedWorkoutID: UUID? = nil) {
        self.id = id
        self.date = date
        self.status = status
        self.discipline = discipline
        self.sportType = sportType
        self.runType = runType
        self.targetDistanceM = targetDistanceM
        self.targetDurationS = targetDurationS
        self.targetPaceSPerKm = targetPaceSPerKm
        self.intervals = intervals
        self.strengthLabel = strengthLabel
        self.strengthTargets = strengthTargets.sorted {
            $0.order == $1.order ? $0.exerciseName < $1.exerciseName : $0.order < $1.order
        }
        self.completedWorkoutID = completedWorkoutID
    }
}

struct ExistingRunningPlanSnapshot: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let isSelfCoached: Bool
    let semanticPlan: PlanSemanticSnapshot?
    let sessions: [ExistingRunningSessionSnapshot]

    init(id: UUID,
         name: String,
         isSelfCoached: Bool,
         semanticPlan: PlanSemanticSnapshot? = nil,
         sessions: [ExistingRunningSessionSnapshot] = []) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isSelfCoached = isSelfCoached
        self.semanticPlan = semanticPlan
        self.sessions = sessions.sorted {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
        }
    }
}

/// Temporary Stage-B bridge. It lets the adapter reproduce the shipping generator without making
/// the new domain pretend that legacy aggregates are richer evidence than they are.
struct LegacyRoadPlanningBridge: Sendable {
    let inputs: PlanInputs
    let calibration: CalibrationSeed
}

/// One immutable input to every pure policy. Store reads and Health access happen before this value
/// exists; policies cannot reach back into either system.
struct PlanningRequest: Sendable, Identifiable {
    static let currentPlannerVersion = "running-domain-v1"
    static let legacyRulesetID = "legacy-road-rules-v1"

    let id: UUID
    let plannerVersion: String
    let rulesetID: String
    let generatedAt: Date
    let startDate: Date
    let calendar: RunningCalendarConfiguration
    let displayUnit: DistanceUnit
    let trigger: RunningPlanningTrigger
    let authority: RunningPlanningAuthority
    let goal: RunningGoalContract
    let season: RunningSeason
    let availability: RunningAvailability
    let athleteState: RunningAthleteState
    let existingPlan: ExistingRunningPlanSnapshot?
    let activeRestrictions: [ActiveRunningRestriction]
    let legacyBridge: LegacyRoadPlanningBridge?

    init(id: UUID,
         plannerVersion: String = PlanningRequest.currentPlannerVersion,
         rulesetID: String,
         generatedAt: Date,
         startDate: Date,
         calendar: RunningCalendarConfiguration,
         displayUnit: DistanceUnit,
         trigger: RunningPlanningTrigger,
         authority: RunningPlanningAuthority,
         goal: RunningGoalContract,
         season: RunningSeason,
         availability: RunningAvailability,
         athleteState: RunningAthleteState,
         existingPlan: ExistingRunningPlanSnapshot? = nil,
         activeRestrictions: [ActiveRunningRestriction] = [],
         legacyBridge: LegacyRoadPlanningBridge? = nil) {
        self.id = id
        self.plannerVersion = plannerVersion
        self.rulesetID = rulesetID
        self.generatedAt = generatedAt
        self.startDate = startDate
        self.calendar = calendar
        self.displayUnit = displayUnit
        self.trigger = trigger
        self.authority = authority
        self.goal = goal
        self.season = season
        self.availability = availability
        self.athleteState = athleteState
        self.existingPlan = existingPlan
        self.activeRestrictions = activeRestrictions.sorted {
            $0.startsAt == $1.startsAt ? $0.id.uuidString < $1.id.uuidString : $0.startsAt < $1.startsAt
        }
        self.legacyBridge = legacyBridge
    }
}

extension PlanningRequest {
    /// Test/shadow construction for the shipping generator. This does not manufacture athlete-state
    /// confidence; legacy fields stay isolated in `legacyBridge` and the state remains explicit.
    static func legacy(id: UUID,
                       inputs: PlanInputs,
                       calibration: CalibrationSeed = .none,
                       name: String,
                       generatedAt: Date,
                       startDate: Date,
                       calendar: Calendar,
                       trigger: RunningPlanningTrigger = .shadowEvaluation,
                       authority: RunningPlanningAuthority = .shadowOnly,
                       existingPlan: ExistingRunningPlanSnapshot? = nil,
                       athleteState: RunningAthleteState = .unknown) -> PlanningRequest {
        let outcome: RunningPrimaryOutcome = {
            if inputs.goal == .raceDistance {
                return inputs.goalFinishTimeS == nil ? .finish : .targetTime
            }
            return inputs.runningExperience == .new ? .returnToRunning : .buildBase
        }()
        let event: RunningSeasonEvent? = {
            guard let date = inputs.raceDate else { return nil }
            return RunningSeasonEvent(
                id: id,
                name: name,
                date: date,
                distanceM: inputs.raceDistanceM,
                durationS: inputs.goalFinishTimeS,
                priority: .a
            )
        }()
        let season = RunningSeason(
            id: id,
            name: name,
            status: .active,
            primaryOutcome: outcome,
            motivations: [],
            events: event.map { [$0] } ?? []
        )
        return PlanningRequest(
            id: id,
            rulesetID: Self.legacyRulesetID,
            generatedAt: generatedAt,
            startDate: startDate,
            calendar: RunningCalendarConfiguration(calendar),
            displayUnit: inputs.distanceUnit,
            trigger: trigger,
            authority: authority,
            goal: RunningGoalContract(
                outcome: outcome,
                targetDistanceM: inputs.raceDistanceM,
                targetDurationS: inputs.goalFinishTimeS
            ),
            season: season,
            availability: RunningAvailability(
                trainingDaysPerWeek: inputs.daysPerWeek,
                preferredDayOffsets: Set(inputs.preferredDayOffsets),
                sessionTimeCeilingS: Double(inputs.sessionMinutes) * 60,
                equipment: inputs.equipment,
                overrides: RunningAthleteOverrides(
                    intensity: inputs.intensity,
                    targetWeeklyDistanceM: inputs.targetWeeklyVolumeM,
                    hybridPriority: inputs.hybridPriority,
                    strengthSplit: inputs.strengthSplit,
                    muscleFocus: Set(inputs.muscleFocus)
                )
            ),
            athleteState: athleteState,
            existingPlan: existingPlan,
            activeRestrictions: [],
            legacyBridge: LegacyRoadPlanningBridge(inputs: inputs, calibration: calibration)
        )
    }
}
