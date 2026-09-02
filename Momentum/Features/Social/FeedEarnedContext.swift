import Foundation

/// One quiet, truthful line explaining why a workout matters. The resolver is deterministic and
/// chooses at most one label per post: a persisted record wins, then a first distance milestone,
/// then meaningful plan context. It never invents social proof or compares athletes.
enum FeedEarnedContext {
    struct WorkoutFacts: Sendable, Equatable {
        let id: UUID
        let date: Date
        let type: WorkoutType
        let distanceM: Double
        let plannedLabel: String?
    }

    static func resolve(workouts: [WorkoutFacts], recordLabels: [UUID: String]) -> [UUID: String] {
        var result: [UUID: String] = [:]
        var longestRunM = 0.0
        var crossed: Set<Int> = []
        let milestones = [5_000, 10_000, 21_097, 42_195, 50_000]

        for workout in workouts.sorted(by: { $0.date < $1.date }) {
            if let record = recordLabels[workout.id], !record.isEmpty {
                result[workout.id] = record
            } else if workout.type == .run {
                // One workout can cross several thresholds (a first logged 10K is also, in the
                // literal sense, the first recorded 5K). Surface the HIGHEST newly-earned mark so
                // the context describes what the athlete actually completed instead of
                // understating it, then mark every crossed threshold below it as seen.
                if let first = milestones.last(where: {
                    workout.distanceM >= Double($0) && !crossed.contains($0)
                }) {
                    result[workout.id] = milestoneLabel(first)
                } else if longestRunM > 0, workout.distanceM > longestRunM * 1.01 {
                    result[workout.id] = "Longest run"
                } else if let planned = workout.plannedLabel {
                    result[workout.id] = planned
                }
            } else if let planned = workout.plannedLabel {
                result[workout.id] = planned
            }

            if workout.type == .run {
                longestRunM = max(longestRunM, workout.distanceM)
                for mark in milestones where workout.distanceM >= Double(mark) { crossed.insert(mark) }
            }
        }
        return result
    }

    /// Main-actor adapter for the local SwiftData graph. The pure overload above owns every rule;
    /// this one only snapshots model objects into values so both the wall and publish sweep use the
    /// exact same labels.
    @MainActor
    static func resolve(workouts: [Workout], records: [PersonalRecord]) -> [UUID: String] {
        var recordLabels: [UUID: String] = [:]
        for record in records.sorted(by: { $0.achievedAt > $1.achievedAt }) {
            guard let id = record.workout?.id else { continue }
            recordLabels[id] = recordLabels[id] ?? record.type.recordLabel
        }
        let facts = workouts.map {
            WorkoutFacts(id: $0.id, date: $0.startedAt, type: $0.type,
                         distanceM: $0.gps?.distanceM ?? 0,
                         plannedLabel: plannedLabel(for: $0.plannedSession))
        }
        return resolve(workouts: facts, recordLabels: recordLabels)
    }

    static func plannedLabel(for session: PlannedSession?) -> String? {
        guard let session else { return nil }
        if let strength = session.strengthLabel, !strength.isEmpty { return "Planned \(strength.lowercased()) day" }
        if let run = session.runType { return "Planned \(run.rawValue.replacingOccurrences(of: "_", with: " "))" }
        let sport = WorkoutType.forPlanned(session).title.lowercased()
        return "Planned \(sport)"
    }

    private static func milestoneLabel(_ meters: Int) -> String {
        switch meters {
        case 5_000: "First 5K"
        case 10_000: "First 10K"
        case 21_097: "First half marathon"
        case 42_195: "First marathon"
        default: "First 50K"
        }
    }
}
