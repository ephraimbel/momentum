import Foundation

struct RunningSchedulePreferenceDecision: Codable, Equatable, Sendable {
    let preference: RunningRelaxedPreference
    let isSatisfied: Bool
    let detail: String
}

struct RunningSchedulePlacement: Codable, Equatable, Sendable {
    let intent: SessionIntent
    let originalDayOffset: Int
    let scheduledDayOffset: Int
}

struct RunningScheduledWeek: Codable, Equatable, Sendable {
    let weekIndex: Int
    let placements: [RunningSchedulePlacement]
    let appliedRuleIDs: [RunningRuleID]
    let hardConstraints: Set<RunningHardConstraint>
    let preferenceDecisions: [RunningSchedulePreferenceDecision]
    let relaxedPreferences: Set<RunningRelaxedPreference>
    /// Number of complete, hard-valid schedules compared. This is diagnostic only and does not
    /// enter the plan digest.
    let evaluatedCandidateCount: Int
}

enum RunningSchedulingResult: Equatable, Sendable {
    case scheduled(RunningScheduledWeek)
    case conflict([RunningPlanningConflict])
}

/// Pure, exhaustive seven-day scheduler. Hard constraints remove candidates; remaining candidates
/// are compared lexicographically in the documented preference order. A normal week has at most
/// seven sessions, so exhaustive permutation (7! = 5,040 candidates) is both simpler to audit and
/// safer than a weighted optimizer whose trade-offs could silently change.
struct OrderedRunningScheduler: Sendable {
    func schedule(weekIndex: Int,
                  weekStart: Date,
                  intents: [SessionIntent],
                  request: PlanningRequest) -> RunningSchedulingResult {
        let calendar: Calendar
        do {
            calendar = try request.calendar.value()
        } catch {
            return .conflict([RunningPlanningConflict(
                .invalidCalendar,
                field: "calendar",
                detail: "The scheduler could not reconstruct the injected calendar."
            )])
        }

        let sortedIntents = intents.sorted(by: Self.intentOrder)
        guard Set(sortedIntents.map(\.id)).count == sortedIntents.count,
              sortedIntents.allSatisfy({ $0.weekIndex == weekIndex && (0...6).contains($0.dayOffset) }) else {
            return .conflict([RunningPlanningConflict(
                .validationFailed,
                field: "sessionIntents",
                detail: "Intent IDs must be unique and every intent must identify this week with a valid day offset."
            )])
        }
        guard request.availability.trainingDaysPerWeek >= 1,
              request.availability.trainingDaysPerWeek <= 7 else {
            return .conflict([RunningPlanningConflict(
                .invalidAvailability,
                field: "availability.trainingDaysPerWeek",
                detail: "Training availability must be between one and seven days."
            )])
        }
        guard sortedIntents.count <= request.availability.trainingDaysPerWeek else {
            return .conflict([RunningPlanningConflict(
                .trainingDayBudgetExceeded,
                field: "availability.trainingDaysPerWeek",
                detail: "This week contains \(sortedIntents.count) sessions but the athlete chose \(request.availability.trainingDaysPerWeek) training days.",
                alternatives: ["Add a training day", "Reduce optional weekly dose"]
            )])
        }
        guard !sortedIntents.isEmpty else {
            return .scheduled(RunningScheduledWeek(
                weekIndex: weekIndex,
                placements: [],
                appliedRuleIDs: [.calendarScheduling],
                hardConstraints: [.availabilityBudget, .fixedCalendar],
                preferenceDecisions: Self.emptyPreferenceDecisions,
                relaxedPreferences: [],
                evaluatedCandidateCount: 1
            ))
        }

        let weekDay = calendar.startOfDay(for: weekStart)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekDay) ?? weekDay.addingTimeInterval(7 * 86_400)
        let fixed = request.availability.fixedDates.compactMap { item -> (Int, RunningFixedDateKind)? in
            let date = calendar.startOfDay(for: item.date)
            guard date >= weekDay, date < weekEnd else { return nil }
            let offset = calendar.dateComponents([.day], from: weekDay, to: date).day
            guard let offset, (0...6).contains(offset) else { return nil }
            return (offset, item.kind)
        }
        let groupedFixed = Dictionary(grouping: fixed, by: \.0)
        if let collision = groupedFixed.sorted(by: { $0.key < $1.key }).first(where: { entry in
            let kinds = Set(entry.value.map(\.1))
            return kinds.contains(.unavailable) && kinds.count > 1
                || kinds.contains(.fixedRun) && kinds.contains(.fixedStrength)
                || kinds.contains(.event) && (kinds.contains(.fixedRun) || kinds.contains(.fixedStrength))
        }) {
            return .conflict([RunningPlanningConflict(
                .fixedDateCollision,
                field: "availability.fixedDates",
                detail: "Day offset \(collision.key) contains incompatible fixed commitments."
            )])
        }

        let unavailable = Set(fixed.filter { $0.1 == .unavailable || $0.1 == .travel }.map(\.0))
        let fixedRunDays = Set(fixed.filter { $0.1 == .fixedRun }.map(\.0))
        let fixedStrengthDays = Set(fixed.filter { $0.1 == .fixedStrength }.map(\.0))
        let declaredEventDays = Set(fixed.filter { $0.1 == .event }.map(\.0))
        let primaryEventDay = request.season.primaryEvent.flatMap { event -> Int? in
            let date = calendar.startOfDay(for: event.date)
            guard date >= weekDay, date < weekEnd else { return nil }
            return calendar.dateComponents([.day], from: weekDay, to: date).day
        }
        let eventDays = declaredEventDays.union(primaryEventDay.map { [$0] } ?? [])

        let runningCount = sortedIntents.filter { $0.discipline == .running }.count
        let strengthCount = sortedIntents.filter { $0.discipline == .strength }.count
        if fixedRunDays.count > runningCount || fixedStrengthDays.count > strengthCount
            || eventDays.count > sortedIntents.filter({ $0.sessionClass == .race }).count {
            return .conflict([RunningPlanningConflict(
                .fixedDateCollision,
                field: "availability.fixedDates",
                detail: "The fixed run, strength, or event dates cannot be paired with this week's required intents.",
                alternatives: ["Move a fixed commitment", "Regenerate the week's dose"]
            )])
        }

        let raceOffsets = eventDays.isEmpty
            ? Set(sortedIntents.filter { $0.sessionClass == .race }.map(\.dayOffset))
            : eventDays
        if raceOffsets.count > 1 {
            return .conflict([RunningPlanningConflict(
                .terminalEventConflict,
                field: "season.events",
                detail: "One training week cannot contain multiple terminal race dates."
            )])
        }
        let terminalRaceDay = raceOffsets.first
        if let terminalRaceDay, unavailable.contains(terminalRaceDay) {
            return .conflict([RunningPlanningConflict(
                .fixedDateCollision,
                field: "availability.fixedDates",
                detail: "The primary race is on a day marked unavailable or travel."
            )])
        }

        var best: Assignment?
        var candidateCount = 0
        var assigned: [String: Int] = [:]
        var used = Set<Int>()

        func search(_ index: Int) {
            if index == sortedIntents.count {
                guard Self.satisfiesFixedDays(
                    assigned: assigned,
                    intents: sortedIntents,
                    fixedRunDays: fixedRunDays,
                    fixedStrengthDays: fixedStrengthDays,
                    eventDays: eventDays
                ) else { return }
                candidateCount += 1
                let score = Self.score(
                    assigned: assigned,
                    intents: sortedIntents,
                    weekStart: weekDay,
                    calendar: calendar,
                    request: request
                )
                let candidate = Assignment(days: assigned, score: score)
                if best == nil || candidate.score < best!.score { best = candidate }
                return
            }

            let intent = sortedIntents[index]
            let domain: [Int]
            if intent.sessionClass == .race, let terminalRaceDay {
                domain = [terminalRaceDay]
            } else {
                domain = Array(0...6)
            }
            for day in domain where !used.contains(day) && !unavailable.contains(day) {
                if let terminalRaceDay, intent.sessionClass != .race, day > terminalRaceDay { continue }
                if Self.violatesRestriction(intent: intent, dayOffset: day, weekStart: weekDay,
                                            calendar: calendar, restrictions: request.activeRestrictions) {
                    continue
                }
                if Self.violatesRecovery(intent: intent, dayOffset: day,
                                         assigned: assigned, intents: sortedIntents) {
                    continue
                }
                assigned[intent.id] = day
                used.insert(day)
                search(index + 1)
                used.remove(day)
                assigned[intent.id] = nil
            }
        }
        search(0)

        guard let best else {
            return .conflict([RunningPlanningConflict(
                .noFeasibleSchedule,
                field: "schedule.week[\(weekIndex)]",
                detail: "No seven-day placement satisfies availability, fixed dates, active restrictions, terminal-race ordering, and hard recovery spacing.",
                alternatives: ["Add or move an available day", "Reduce optional weekly dose", "Keep the current plan unchanged"]
            )])
        }

        let preferenceState = Self.preferenceState(
            score: best.score,
            request: request,
            hasAdherenceEvidence: Self.usableAdherence(request) != nil
        )
        var hard: Set<RunningHardConstraint> = [
            .availabilityBudget, .fixedCalendar, .lowerStrengthRecoverySpacing,
        ]
        if terminalRaceDay != nil { hard.insert(.noTrainingAfterTerminalRace) }
        if !request.activeRestrictions.isEmpty { hard.insert(.activeRestriction) }
        var placements: [RunningSchedulePlacement] = []
        placements.reserveCapacity(intents.count)
        for intent in intents {
            let scheduledDay = best.days[intent.id] ?? intent.dayOffset
            placements.append(RunningSchedulePlacement(
                intent: intent,
                originalDayOffset: intent.dayOffset,
                scheduledDayOffset: scheduledDay
            ))
        }
        placements.sort {
            $0.scheduledDayOffset == $1.scheduledDayOffset
                ? $0.intent.id < $1.intent.id
                : $0.scheduledDayOffset < $1.scheduledDayOffset
        }
        return .scheduled(RunningScheduledWeek(
            weekIndex: weekIndex,
            placements: placements,
            appliedRuleIDs: [.calendarScheduling, .hardDaySpacing],
            hardConstraints: hard,
            preferenceDecisions: preferenceState.decisions,
            relaxedPreferences: preferenceState.relaxed,
            evaluatedCandidateCount: candidateCount
        ))
    }
}

private extension OrderedRunningScheduler {
    struct Assignment {
        let days: [String: Int]
        let score: Score
    }

    struct Score: Comparable {
        let explicitDayPenalty: Int
        let adherencePenalty: Int
        let existingMovementPenalty: Int
        let recoverySpacingPenalty: Int
        let durationFitPenalty: Int
        let stableMovementPenalty: Int
        let tieBreakOffsets: [Int]

        static func < (lhs: Score, rhs: Score) -> Bool {
            let left = [lhs.explicitDayPenalty, lhs.adherencePenalty, lhs.existingMovementPenalty,
                        lhs.recoverySpacingPenalty, lhs.durationFitPenalty, lhs.stableMovementPenalty]
            let right = [rhs.explicitDayPenalty, rhs.adherencePenalty, rhs.existingMovementPenalty,
                         rhs.recoverySpacingPenalty, rhs.durationFitPenalty, rhs.stableMovementPenalty]
            for index in left.indices where left[index] != right[index] {
                return left[index] < right[index]
            }
            for index in 0..<min(lhs.tieBreakOffsets.count, rhs.tieBreakOffsets.count)
                where lhs.tieBreakOffsets[index] != rhs.tieBreakOffsets[index] {
                return lhs.tieBreakOffsets[index] < rhs.tieBreakOffsets[index]
            }
            return lhs.tieBreakOffsets.count < rhs.tieBreakOffsets.count
        }
    }

    static let emptyPreferenceDecisions: [RunningSchedulePreferenceDecision] = [
        .init(preference: .preferredWeekday, isSatisfied: true, detail: "No sessions require placement."),
        .init(preference: .learnedAvoidWeekday, isSatisfied: true, detail: "No sessions require placement."),
        .init(preference: .existingPlanPlacement, isSatisfied: true, detail: "No sessions require placement."),
        .init(preference: .evenRecoverySpacing, isSatisfied: true, detail: "No sessions require placement."),
        .init(preference: .sessionTimeCeilingForLongRun, isSatisfied: true, detail: "No sessions require placement."),
    ]

    static func intentOrder(_ lhs: SessionIntent, _ rhs: SessionIntent) -> Bool {
        let left = priority(lhs)
        let right = priority(rhs)
        return left == right ? lhs.id < rhs.id : left < right
    }

    static func priority(_ intent: SessionIntent) -> Int {
        if intent.sessionClass == .race { return 0 }
        if intent.hardClass == .hardRun { return 1 }
        if intent.sessionClass == .long { return 2 }
        if intent.hardClass == .hardLowerBodyStrength { return 3 }
        if intent.discipline == .strength { return 4 }
        return 5
    }

    static func satisfiesFixedDays(assigned: [String: Int],
                                   intents: [SessionIntent],
                                   fixedRunDays: Set<Int>,
                                   fixedStrengthDays: Set<Int>,
                                   eventDays: Set<Int>) -> Bool {
        let byID = Dictionary(uniqueKeysWithValues: intents.map { ($0.id, $0) })
        let runDays = Set(assigned.compactMap { id, day in
            byID[id]?.discipline == .running ? day : nil
        })
        let strengthDays = Set(assigned.compactMap { id, day in
            byID[id]?.discipline == .strength ? day : nil
        })
        let raceDays = Set(assigned.compactMap { id, day in
            byID[id]?.sessionClass == .race ? day : nil
        })
        return fixedRunDays.isSubset(of: runDays)
            && fixedStrengthDays.isSubset(of: strengthDays)
            && eventDays.isSubset(of: raceDays)
    }

    static func violatesRecovery(intent: SessionIntent,
                                 dayOffset: Int,
                                 assigned: [String: Int],
                                 intents: [SessionIntent]) -> Bool {
        for other in intents {
            guard let otherDay = assigned[other.id] else { continue }
            if intent.hardClass == .hardRun,
               other.hardClass == .hardLowerBodyStrength,
               dayOffset == otherDay + 1 {
                return true
            }
            if intent.hardClass == .hardLowerBodyStrength,
               other.hardClass == .hardRun,
               otherDay == dayOffset + 1 {
                return true
            }
        }
        return false
    }

    static func violatesRestriction(intent: SessionIntent,
                                    dayOffset: Int,
                                    weekStart: Date,
                                    calendar: Calendar,
                                    restrictions: [ActiveRunningRestriction]) -> Bool {
        guard !restrictions.isEmpty,
              let date = calendar.date(byAdding: .day, value: dayOffset, to: weekStart) else {
            return false
        }
        let day = calendar.startOfDay(for: date)
        for restriction in restrictions where isActive(restriction, on: day, calendar: calendar) {
            switch restriction.kind {
            case .noRunning where intent.discipline == .running:
                return true
            case .easyOnly where intent.discipline == .running && intent.sessionClass != .easy:
                return true
            case .noSpeed where intent.discipline == .running && intent.hardClass == .hardRun:
                return true
            case .noHills where intent.stimulus == .hillStrength:
                return true
            case .noDownhill where intent.stimulus == .hillStrength:
                // Release 1 has no separate downhill intent. Conservatively keep hill work out.
                return true
            case .noLowerBodyStrength where intent.hardClass == .hardLowerBodyStrength:
                return true
            case .distanceCap:
                if let maximum = restriction.maximum,
                   let distance = intent.workDose.distanceM,
                   distance > maximum { return true }
            case .durationCap:
                if let maximum = restriction.maximum,
                   let duration = estimatedDuration(intent),
                   duration > maximum { return true }
            default:
                break
            }
        }
        return false
    }

    static func isActive(_ restriction: ActiveRunningRestriction,
                         on day: Date,
                         calendar: Calendar) -> Bool {
        let start = calendar.startOfDay(for: restriction.startsAt)
        guard day >= start else { return false }
        guard let end = restriction.endsAt else { return true }
        return day <= calendar.startOfDay(for: end)
    }

    static func score(assigned: [String: Int],
                      intents: [SessionIntent],
                      weekStart: Date,
                      calendar: Calendar,
                      request: PlanningRequest) -> Score {
        let explicitOffsets = preferredOffsets(request: request, weekStart: weekStart, calendar: calendar)
        let explicit = explicitOffsets.isEmpty ? 0 : assigned.values.filter { !explicitOffsets.contains($0) }.count
        let adherence = usableAdherence(request).map { evidence in
            assigned.values.reduce(0) { result, offset in
                guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else {
                    return result
                }
                let weekday = calendar.component(.weekday, from: date)
                var penalty = evidence.value.commonlyMissedWeekdays.contains(weekday) ? 2 : 0
                if !evidence.value.commonlyCompletedWeekdays.isEmpty,
                   !evidence.value.commonlyCompletedWeekdays.contains(weekday) {
                    penalty += 1
                }
                return result + penalty
            }
        } ?? 0
        let stableMovement = intents.reduce(0) { result, intent in
            result + abs((assigned[intent.id] ?? intent.dayOffset) - intent.dayOffset)
        }
        let existingMovement = request.existingPlan == nil ? 0 : stableMovement
        let spacing = recoverySpacingPenalty(assigned: assigned, intents: intents)
        let duration = durationFitPenalty(assigned: assigned, intents: intents,
                                          ceilingS: request.availability.sessionTimeCeilingS)
        let ids = intents.map(\.id).sorted()
        return Score(
            explicitDayPenalty: explicit,
            adherencePenalty: adherence,
            existingMovementPenalty: existingMovement,
            recoverySpacingPenalty: spacing,
            durationFitPenalty: duration,
            stableMovementPenalty: stableMovement,
            tieBreakOffsets: ids.map { assigned[$0] ?? 7 }
        )
    }

    static func preferredOffsets(request: PlanningRequest,
                                 weekStart: Date,
                                 calendar: Calendar) -> Set<Int> {
        var offsets = request.availability.preferredDayOffsets
        if !request.availability.preferredWeekdays.isEmpty {
            for offset in 0...6 {
                guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else { continue }
                if request.availability.preferredWeekdays.contains(calendar.component(.weekday, from: date)) {
                    offsets.insert(offset)
                }
            }
        }
        return offsets
    }

    static func usableAdherence(_ request: PlanningRequest) -> RunningEvidence<RunningScheduleAdherence>? {
        guard let evidence = request.athleteState.scheduleAdherence,
              evidence.source.canRepresentCompletedTrainingExposure,
              evidence.validationIssues.isEmpty,
              evidence.confidence >= .low else { return nil }
        return evidence
    }

    static func recoverySpacingPenalty(assigned: [String: Int], intents: [SessionIntent]) -> Int {
        var penalty = 0
        for leftIndex in intents.indices {
            for rightIndex in intents.indices where rightIndex > leftIndex {
                let left = intents[leftIndex]
                let right = intents[rightIndex]
                guard let leftDay = assigned[left.id], let rightDay = assigned[right.id] else { continue }
                let gap = abs(leftDay - rightDay)
                guard gap == 1 else { continue }
                if left.hardClass == .hardRun && right.hardClass == .hardRun {
                    penalty += 8
                } else if (left.hardClass == .hardRun && right.sessionClass == .long)
                    || (right.hardClass == .hardRun && left.sessionClass == .long) {
                    penalty += 5
                } else if (left.sessionClass == .long && right.hardClass == .hardLowerBodyStrength)
                    || (right.sessionClass == .long && left.hardClass == .hardLowerBodyStrength) {
                    penalty += 3
                }
            }
        }
        return penalty
    }

    static func durationFitPenalty(assigned: [String: Int],
                                   intents: [SessionIntent],
                                   ceilingS: Double?) -> Int {
        guard let ceilingS, ceilingS.isFinite, ceilingS > 0 else { return 0 }
        return intents.reduce(0) { result, intent in
            guard intent.sessionClass == .long,
                  let duration = estimatedDuration(intent), duration > ceilingS else { return result }
            return result + Int(ceil((duration - ceilingS) / 60))
        }
    }

    static func estimatedDuration(_ intent: SessionIntent) -> Double? {
        if let duration = intent.workDose.durationS, duration.isFinite, duration > 0 { return duration }
        guard let distance = intent.workDose.distanceM, distance.isFinite, distance > 0,
              let pace = intent.workDose.paceSPerKm, pace.isFinite, pace > 0 else { return nil }
        return distance / 1_000 * pace
    }

    static func preferenceState(score: Score,
                                request: PlanningRequest,
                                hasAdherenceEvidence: Bool)
        -> (decisions: [RunningSchedulePreferenceDecision], relaxed: Set<RunningRelaxedPreference>) {
        let hasExplicit = !request.availability.preferredDayOffsets.isEmpty
            || !request.availability.preferredWeekdays.isEmpty
        let hasExisting = request.existingPlan != nil
        let hasCeiling = request.availability.sessionTimeCeilingS != nil
        let values: [(RunningRelaxedPreference, Bool, String)] = [
            (.preferredWeekday, !hasExplicit || score.explicitDayPenalty == 0,
             hasExplicit ? "All possible sessions use explicit athlete days." : "No explicit athlete days were supplied."),
            (.learnedAvoidWeekday, !hasAdherenceEvidence || score.adherencePenalty == 0,
             hasAdherenceEvidence ? "Placement follows supported execution-history evidence where feasible." : "No supported schedule-adherence evidence was available."),
            (.existingPlanPlacement, !hasExisting || score.existingMovementPenalty == 0,
             hasExisting ? "Existing placements are preserved where higher-order constraints allow." : "This is a new plan with no current placement to preserve."),
            (.evenRecoverySpacing, score.recoverySpacingPenalty == 0,
             "Hard/long load adjacency is minimized after higher-order preferences."),
            (.sessionTimeCeilingForLongRun, !hasCeiling || score.durationFitPenalty == 0,
             hasCeiling ? "Long-run duration is compared with the athlete's session ceiling." : "No session-time ceiling was supplied."),
        ]
        var relaxed = Set<RunningRelaxedPreference>()
        let decisions = values.map { preference, satisfied, detail in
            if !satisfied { relaxed.insert(preference) }
            return RunningSchedulePreferenceDecision(
                preference: preference,
                isSatisfied: satisfied,
                detail: satisfied ? detail : "Relaxed after higher-order constraints: \(detail)"
            )
        }
        return (decisions, relaxed)
    }
}
