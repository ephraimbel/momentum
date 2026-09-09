import Foundation
import SwiftData

/// A summary chart owns values, never SwiftData relationships that a save/discard can invalidate.
/// MOMENTUM-IOS-E crashed while a retained GPSDetail was read during a later SwiftUI body pass.
enum WorkoutWeekSnapshot {
    struct Entry: Equatable, Sendable {
        let startedAt: Date
        let distanceM: Double
        let volumeKg: Double
    }

    static func window(anchor: Date, calendar: Calendar = .current) -> DateInterval? {
        let day = calendar.startOfDay(for: anchor)
        guard let start = calendar.date(byAdding: .day, value: -6, to: day),
              let end = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// A fresh context avoids returning objects cached before another context replaced a detail.
    /// Nothing escapes this synchronous read except scalars. Missing detail rows contribute zero.
    static func load(anchor: Date, container: ModelContainer, calendar: Calendar = .current) throws -> [Entry] {
        guard let window = window(anchor: anchor, calendar: calendar) else { return [] }
        let context = ModelContext(container)
        let start = window.start, end = window.end
        let workouts = try context.fetch(FetchDescriptor<Workout>(
            predicate: #Predicate { $0.startedAt >= start && $0.startedAt < end },
            sortBy: [SortDescriptor(\.startedAt)]))
        return try workouts.map { workout in
            var distance = 0.0, volume = 0.0
            // Reading an identifier does not fault the child's deleted backing data. Fetching
            // the actual row first also tolerates dangling relationships from an interrupted wipe.
            if let id = workout.gps?.persistentModelID {
                var query = FetchDescriptor<GPSDetail>(predicate: #Predicate { $0.persistentModelID == id })
                query.fetchLimit = 1
                distance = try context.fetch(query).first?.distanceM ?? 0
            }
            if let id = workout.strength?.persistentModelID {
                var query = FetchDescriptor<StrengthSession>(predicate: #Predicate { $0.persistentModelID == id })
                query.fetchLimit = 1
                volume = try context.fetch(query).first?.totalVolumeKg ?? 0
            }
            return Entry(startedAt: workout.startedAt,
                         distanceM: finiteNonnegative(distance), volumeKg: finiteNonnegative(volume))
        }
    }

    private static func finiteNonnegative(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 0
    }
}
