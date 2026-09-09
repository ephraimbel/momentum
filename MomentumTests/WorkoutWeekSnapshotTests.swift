import Foundation
import SwiftData
import Testing
@testable import Momentum

@MainActor
struct WorkoutWeekSnapshotTests {
    private func store() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    @Test func chartValuesSurviveDeletionFromAnotherContext() throws {
        let store = try store(), context = store.mainContext, now = Date()
        let run = Workout(); run.startedAt = now
        let gps = GPSDetail(); gps.distanceM = 5000; run.gps = gps
        let lift = Workout(); lift.startedAt = now.addingTimeInterval(-86400)
        let strength = StrengthSession(); strength.totalVolumeKg = 2300; lift.strength = strength
        context.insert(run); context.insert(lift); try context.save()
        let snapshot = try WorkoutWeekSnapshot.load(anchor: now, container: store)
        let writer = ModelContext(store)
        for w in try writer.fetch(FetchDescriptor<Workout>()) { writer.delete(w) }
        try writer.save()
        #expect(snapshot.count == 2)
        #expect(snapshot.reduce(0) { $0 + $1.distanceM } == 5000)
        #expect(snapshot.reduce(0) { $0 + $1.volumeKg } == 2300)
        #expect(try WorkoutWeekSnapshot.load(anchor: now, container: store).isEmpty)
    }

    @Test func aReloadReadsReplacedDetailsWithoutReusingTheOldModel() throws {
        let store = try store(), context = store.mainContext, now = Date()
        let run = Workout(); run.startedAt = now
        let gps = GPSDetail(); gps.distanceM = 5000; run.gps = gps
        context.insert(run); try context.save()
        let first = try WorkoutWeekSnapshot.load(anchor: now, container: store)
        let writer = ModelContext(store)
        let edited = try #require(writer.fetch(FetchDescriptor<Workout>()).first)
        let old = edited.gps
        let replacement = GPSDetail(); replacement.distanceM = 3000; writer.insert(replacement)
        edited.gps = replacement
        if let old { writer.delete(old) }
        try writer.save()
        let reloaded = try WorkoutWeekSnapshot.load(anchor: now, container: store)
        #expect(first.first?.distanceM == 5000)
        #expect(reloaded.first?.distanceM == 3000)
    }

    @Test func missingDetailsAreHarmlessAndWindowExcludesTomorrow() throws {
        let store = try store(), context = store.mainContext, now = Date()
        let window = try #require(WorkoutWeekSnapshot.window(anchor: now))
        for date in [window.start.addingTimeInterval(-1), window.start, now, window.end] {
            let w = Workout(); w.startedAt = date; context.insert(w)
        }
        try context.save()
        let rows = try WorkoutWeekSnapshot.load(anchor: now, container: store)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.distanceM == 0 && $0.volumeKg == 0 })
    }

    @Test func weekWindowFollowsLocalDaysAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let anchor = try #require(ISO8601DateFormatter().date(from: "2026-03-09T12:00:00Z"))
        let window = try #require(WorkoutWeekSnapshot.window(anchor: anchor, calendar: calendar))
        #expect(window.duration == 167 * 3600)
        #expect(calendar.component(.hour, from: window.start) == 0)
        #expect(calendar.component(.hour, from: window.end) == 0)
    }
}
