import CryptoKit
import Foundation

/// Versioned, narrative-free representation of a generated plan.
///
/// This is the Stage-A adapter around the legacy `GeneratedPlan`. It intentionally carries only
/// training meaning: phases, schedule, intent and numeric prescriptions. Rationale text, UUIDs,
/// timestamps and persistence details never enter the digest, so copy edits cannot look like a
/// coaching change.
struct PlanSemanticSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var p5kMillisecondsPerKm: PlanSemanticQuantity
    var goalRacePaceMillisecondsPerKm: PlanSemanticQuantity?
    var weeks: [Week]

    init(_ plan: GeneratedPlan) {
        schemaVersion = Self.currentSchemaVersion
        p5kMillisecondsPerKm = PlanSemanticQuantity(plan.p5kSPerKm, scale: 1_000)
        goalRacePaceMillisecondsPerKm = plan.goalRacePaceSPerKm.map {
            PlanSemanticQuantity($0, scale: 1_000)
        }
        weeks = plan.weeks.map(Week.init).sorted {
            $0.index == $1.index ? $0.sortKey < $1.sortKey : $0.index < $1.index
        }
    }

    /// Canonical bytes are suitable for local fixtures and hashing. Arrays are normalized by the
    /// adapter and dictionary-shaped data is deliberately avoided.
    func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    func digest() throws -> PlanSemanticDigest {
        let bytes = SHA256.hash(data: try canonicalData())
        return PlanSemanticDigest(
            schemaVersion: schemaVersion,
            value: bytes.map { String(format: "%02x", $0) }.joined()
        )
    }

    struct Week: Codable, Equatable, Sendable {
        var index: Int
        var phase: String
        var isDeload: Bool
        var isTaper: Bool
        var sessions: [Session]

        init(_ week: GeneratedWeek) {
            index = week.index
            phase = week.phase.rawValue
            isDeload = week.isDeload
            isTaper = week.isTaper
            sessions = week.sessions.map(Session.init).sorted {
                $0.sortKey < $1.sortKey
            }
        }

        fileprivate var sortKey: String {
            "\(phase)|\(isDeload)|\(isTaper)|" + sessions.map(\.sortKey).joined(separator: ";")
        }
    }

    struct Session: Codable, Equatable, Sendable {
        var dayOffset: Int
        var discipline: String
        var runType: String?
        var targetDistanceMeters: PlanSemanticQuantity?
        var targetDurationMilliseconds: PlanSemanticQuantity?
        var targetPaceMillisecondsPerKm: PlanSemanticQuantity?
        var intervalPrescription: String?
        var strengthLabel: String?
        var strengthTargets: [Exercise]
        var isHardLowerLift: Bool
        var isHardRun: Bool

        init(_ session: GeneratedSession) {
            dayOffset = session.dayOffset
            discipline = session.discipline.rawValue
            runType = session.runType?.rawValue
            targetDistanceMeters = session.targetDistanceM.map { PlanSemanticQuantity($0) }
            targetDurationMilliseconds = session.targetDurationS.map {
                PlanSemanticQuantity($0, scale: 1_000)
            }
            targetPaceMillisecondsPerKm = session.targetPaceSPerKm.map {
                PlanSemanticQuantity($0, scale: 1_000)
            }
            intervalPrescription = Self.normalized(session.intervals)
            strengthLabel = Self.normalized(session.strengthLabel)
            // Exercise order is part of the prescription and is therefore preserved.
            strengthTargets = session.strengthTargets.map(Exercise.init)
            isHardLowerLift = session.isHardLowerLift
            isHardRun = session.isHardRun
        }

        fileprivate var sortKey: String {
            [
                String(format: "%02d", dayOffset), discipline, runType ?? "-",
                targetDistanceMeters?.rawValue ?? "-", targetDurationMilliseconds?.rawValue ?? "-",
                targetPaceMillisecondsPerKm?.rawValue ?? "-", intervalPrescription ?? "-",
                strengthLabel ?? "-", strengthTargets.map(\.sortKey).joined(separator: ","),
                isHardLowerLift ? "1" : "0", isHardRun ? "1" : "0",
            ].joined(separator: "|")
        }

        private static func normalized(_ text: String?) -> String? {
            guard let text else { return nil }
            let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return collapsed.isEmpty ? nil : collapsed
        }
    }

    struct Exercise: Codable, Equatable, Sendable {
        var name: String
        var targetSets: Int
        var repLow: Int
        var repHigh: Int
        var targetRPEHundredths: PlanSemanticQuantity?
        var targetPctRMMillionths: PlanSemanticQuantity?
        var progression: String

        init(_ exercise: GeneratedExercise) {
            name = exercise.exerciseName.trimmingCharacters(in: .whitespacesAndNewlines)
            targetSets = exercise.targetSets
            repLow = exercise.repLow
            repHigh = exercise.repHigh
            targetRPEHundredths = exercise.targetRPE.map {
                PlanSemanticQuantity($0, scale: 100)
            }
            targetPctRMMillionths = exercise.targetPctRM.map {
                PlanSemanticQuantity($0, scale: 1_000_000)
            }
            progression = exercise.progression
        }

        fileprivate var sortKey: String {
            [
                name, String(targetSets), String(repLow), String(repHigh),
                targetRPEHundredths?.rawValue ?? "-", targetPctRMMillionths?.rawValue ?? "-",
                progression,
            ].joined(separator: "|")
        }
    }
}

/// String-backed so malformed legacy output (NaN, infinity or overflow) remains digestible and can
/// be reported by the validator instead of trapping during integer conversion.
struct PlanSemanticQuantity: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    var rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ value: Double, scale: Double = 1) {
        guard value.isFinite else {
            rawValue = value.isNaN ? "nan" : (value.sign == .minus ? "-infinity" : "+infinity")
            return
        }
        let scaled = value * scale
        guard scaled.isFinite, scaled <= Double(Int64.max), scaled >= Double(Int64.min) else {
            rawValue = scaled.sign == .minus ? "-overflow" : "+overflow"
            return
        }
        rawValue = String(Int64(scaled.rounded()))
    }
}

struct PlanSemanticDigest: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    static let algorithm = "sha256"

    var schemaVersion: Int
    var value: String

    var description: String { "v\(schemaVersion):\(Self.algorithm):\(value)" }
}

extension GeneratedPlan {
    func semanticSnapshot() -> PlanSemanticSnapshot {
        PlanSemanticSnapshot(self)
    }

    func semanticDigest() throws -> PlanSemanticDigest {
        try semanticSnapshot().digest()
    }
}
