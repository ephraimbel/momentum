import Foundation

enum PlanDifferenceCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case planStructure
    case calibration
    case goalTarget
    case phase
    case schedule
    case sessionIntent
    case enduranceDose
    case paceTarget
    case strengthPrescription
}

struct PlanDifferenceLocation: Codable, Equatable, Hashable, Sendable {
    var weekIndex: Int?
    var dayOffset: Int?
    var occurrence: Int?

    static let plan = PlanDifferenceLocation()
}

struct PlanSemanticChange: Codable, Equatable, Sendable {
    var category: PlanDifferenceCategory
    var location: PlanDifferenceLocation
    var field: String
    var oldValue: String?
    var newValue: String?
}

/// Detailed values are for local development/review only. Product analytics may emit category counts
/// but must never emit these exact prescriptions, paces or schedule locations.
struct PlanSemanticDiff: Codable, Equatable, Sendable {
    var oldDigest: PlanSemanticDigest
    var newDigest: PlanSemanticDigest
    var changes: [PlanSemanticChange]

    var isEquivalent: Bool { changes.isEmpty }

    var categories: [PlanDifferenceCategory] {
        let present = Set(changes.map(\.category))
        return PlanDifferenceCategory.allCases.filter(present.contains)
    }

    var categoryCounts: [PlanDifferenceCategory: Int] {
        Dictionary(grouping: changes, by: \.category).mapValues(\.count)
    }
}

enum PlanSemanticDiffer {
    static func compare(_ old: GeneratedPlan, _ new: GeneratedPlan) throws -> PlanSemanticDiff {
        try compare(old.semanticSnapshot(), new.semanticSnapshot())
    }

    static func compare(_ old: PlanSemanticSnapshot,
                        _ new: PlanSemanticSnapshot) throws -> PlanSemanticDiff {
        var changes: [PlanSemanticChange] = []

        append(&changes, .planStructure, .plan, "schemaVersion",
               String(old.schemaVersion), String(new.schemaVersion))
        append(&changes, .calibration, .plan, "p5kMillisecondsPerKm",
               old.p5kMillisecondsPerKm.rawValue, new.p5kMillisecondsPerKm.rawValue)
        append(&changes, .goalTarget, .plan, "goalRacePaceMillisecondsPerKm",
               old.goalRacePaceMillisecondsPerKm?.rawValue,
               new.goalRacePaceMillisecondsPerKm?.rawValue)
        append(&changes, .planStructure, .plan, "weekCount",
               String(old.weeks.count), String(new.weeks.count))

        let oldWeeks = indexedWeeks(old.weeks)
        let newWeeks = indexedWeeks(new.weeks)
        for key in Set(oldWeeks.keys).union(newWeeks.keys).sorted() {
            let location = PlanDifferenceLocation(weekIndex: key.index, occurrence: key.occurrence)
            guard let lhs = oldWeeks[key], let rhs = newWeeks[key] else {
                changes.append(PlanSemanticChange(
                    category: .planStructure,
                    location: location,
                    field: "week",
                    oldValue: oldWeeks[key].map(weekSummary),
                    newValue: newWeeks[key].map(weekSummary)
                ))
                continue
            }
            append(&changes, .phase, location, "phase", lhs.phase, rhs.phase)
            append(&changes, .phase, location, "isDeload", String(lhs.isDeload), String(rhs.isDeload))
            append(&changes, .phase, location, "isTaper", String(lhs.isTaper), String(rhs.isTaper))
        }

        let oldSessions = indexedSessions(old.weeks)
        let newSessions = indexedSessions(new.weeks)
        for key in Set(oldSessions.keys).union(newSessions.keys).sorted() {
            let location = PlanDifferenceLocation(
                weekIndex: key.weekIndex,
                dayOffset: key.dayOffset,
                occurrence: key.occurrence
            )
            guard let lhs = oldSessions[key], let rhs = newSessions[key] else {
                changes.append(PlanSemanticChange(
                    category: .schedule,
                    location: location,
                    field: "session",
                    oldValue: oldSessions[key].map(sessionSummary),
                    newValue: newSessions[key].map(sessionSummary)
                ))
                continue
            }

            append(&changes, .sessionIntent, location, "discipline", lhs.discipline, rhs.discipline)
            append(&changes, .sessionIntent, location, "runType", lhs.runType, rhs.runType)
            append(&changes, .sessionIntent, location, "strengthLabel", lhs.strengthLabel, rhs.strengthLabel)
            append(&changes, .sessionIntent, location, "isHardRun", String(lhs.isHardRun), String(rhs.isHardRun))
            append(&changes, .sessionIntent, location, "isHardLowerLift",
                   String(lhs.isHardLowerLift), String(rhs.isHardLowerLift))
            append(&changes, .enduranceDose, location, "targetDistanceMeters",
                   lhs.targetDistanceMeters?.rawValue, rhs.targetDistanceMeters?.rawValue)
            append(&changes, .enduranceDose, location, "targetDurationMilliseconds",
                   lhs.targetDurationMilliseconds?.rawValue, rhs.targetDurationMilliseconds?.rawValue)
            append(&changes, .paceTarget, location, "targetPaceMillisecondsPerKm",
                   lhs.targetPaceMillisecondsPerKm?.rawValue,
                   rhs.targetPaceMillisecondsPerKm?.rawValue)
            append(&changes, .paceTarget, location, "intervalPrescription",
                   lhs.intervalPrescription, rhs.intervalPrescription)
            append(&changes, .strengthPrescription, location, "strengthTargets",
                   exerciseSummary(lhs.strengthTargets), exerciseSummary(rhs.strengthTargets))
        }

        changes.sort(by: changeOrder)
        return PlanSemanticDiff(
            oldDigest: try old.digest(),
            newDigest: try new.digest(),
            changes: changes
        )
    }

    private static func append(_ changes: inout [PlanSemanticChange],
                               _ category: PlanDifferenceCategory,
                               _ location: PlanDifferenceLocation,
                               _ field: String,
                               _ oldValue: String?,
                               _ newValue: String?) {
        guard oldValue != newValue else { return }
        changes.append(PlanSemanticChange(
            category: category,
            location: location,
            field: field,
            oldValue: oldValue,
            newValue: newValue
        ))
    }

    private struct WeekKey: Hashable, Comparable {
        var index: Int
        var occurrence: Int

        static func < (lhs: WeekKey, rhs: WeekKey) -> Bool {
            lhs.index == rhs.index ? lhs.occurrence < rhs.occurrence : lhs.index < rhs.index
        }
    }

    private struct SessionKey: Hashable, Comparable {
        var weekIndex: Int
        var dayOffset: Int
        var occurrence: Int

        static func < (lhs: SessionKey, rhs: SessionKey) -> Bool {
            if lhs.weekIndex != rhs.weekIndex { return lhs.weekIndex < rhs.weekIndex }
            if lhs.dayOffset != rhs.dayOffset { return lhs.dayOffset < rhs.dayOffset }
            return lhs.occurrence < rhs.occurrence
        }
    }

    private static func indexedWeeks(_ weeks: [PlanSemanticSnapshot.Week])
        -> [WeekKey: PlanSemanticSnapshot.Week] {
        var counts: [Int: Int] = [:]
        var result: [WeekKey: PlanSemanticSnapshot.Week] = [:]
        for week in weeks {
            let occurrence = counts[week.index, default: 0]
            counts[week.index] = occurrence + 1
            result[WeekKey(index: week.index, occurrence: occurrence)] = week
        }
        return result
    }

    private static func indexedSessions(_ weeks: [PlanSemanticSnapshot.Week])
        -> [SessionKey: PlanSemanticSnapshot.Session] {
        var result: [SessionKey: PlanSemanticSnapshot.Session] = [:]
        for week in weeks {
            var counts: [Int: Int] = [:]
            for session in week.sessions {
                let occurrence = counts[session.dayOffset, default: 0]
                counts[session.dayOffset] = occurrence + 1
                let key = SessionKey(
                    weekIndex: week.index,
                    dayOffset: session.dayOffset,
                    occurrence: occurrence
                )
                result[key] = session
            }
        }
        return result
    }

    private static func weekSummary(_ week: PlanSemanticSnapshot.Week) -> String {
        "\(week.phase)|deload:\(week.isDeload)|taper:\(week.isTaper)|sessions:\(week.sessions.count)"
    }

    private static func sessionSummary(_ session: PlanSemanticSnapshot.Session) -> String {
        [session.discipline, session.runType ?? "-", session.strengthLabel ?? "-"].joined(separator: "|")
    }

    private static func exerciseSummary(_ exercises: [PlanSemanticSnapshot.Exercise]) -> String {
        exercises.map {
            [
                $0.name, String($0.targetSets), String($0.repLow), String($0.repHigh),
                $0.targetRPEHundredths?.rawValue ?? "-",
                $0.targetPctRMMillionths?.rawValue ?? "-", $0.progression,
            ].joined(separator: "|")
        }.joined(separator: ";")
    }

    private static func changeOrder(_ lhs: PlanSemanticChange, _ rhs: PlanSemanticChange) -> Bool {
        let l = (
            lhs.location.weekIndex ?? -1,
            lhs.location.dayOffset ?? -1,
            lhs.location.occurrence ?? -1,
            lhs.category.rawValue,
            lhs.field
        )
        let r = (
            rhs.location.weekIndex ?? -1,
            rhs.location.dayOffset ?? -1,
            rhs.location.occurrence ?? -1,
            rhs.category.rawValue,
            rhs.field
        )
        if l.0 != r.0 { return l.0 < r.0 }
        if l.1 != r.1 { return l.1 < r.1 }
        if l.2 != r.2 { return l.2 < r.2 }
        if l.3 != r.3 { return l.3 < r.3 }
        return l.4 < r.4
    }
}
