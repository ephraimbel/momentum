import Testing
import Foundation
import SwiftData
@testable import Momentum

/// RecordsBook — the persisted record book: best-per-type reduction and the one-time history
/// backfill (idempotent, progression-only).
@MainActor
struct RecordsBookTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "records-tests-\(UUID().uuidString)")!
        d.removePersistentDomain(forName: "records-tests")
        return d
    }

    /// A run with evenly-paced samples: `paceSPerKm` over `distanceM`.
    private func run(in ctx: ModelContext, daysAgo: Int, distanceM: Double, paceSPerKm: Double) -> Workout {
        let start = Date().addingTimeInterval(Double(-daysAgo) * 86_400)
        let w = Workout()
        w.type = .run
        w.startedAt = start
        w.durationS = distanceM / 1000 * paceSPerKm
        let gps = GPSDetail()
        gps.distanceM = distanceM
        // Straight-north track, one sample per ~100 m at constant pace.
        let step = 100.0
        var samples: [LocationSample] = []
        for i in 0...Int(distanceM / step) {
            let s = LocationSample()
            s.t = start.addingTimeInterval(Double(i) * step / 1000 * paceSPerKm)
            s.lat = 30.0 + Double(i) * step / HeatmapBinning.metersPerDegLat
            s.lon = -97.0
            s.accepted = true
            samples.append(s)
        }
        gps.samples = samples
        w.gps = gps
        ctx.insert(w)
        return w
    }

    @Test func bestsReduceAcrossHistory() {
        let now = Date()
        let prs = [
            PersonalRecord(type: .fastest5k, value: 1500, achievedAt: now.addingTimeInterval(-86400)),
            PersonalRecord(type: .fastest5k, value: 1450, achievedAt: now),     // faster wins
            PersonalRecord(type: .longestRun, value: 8000, achievedAt: now.addingTimeInterval(-86400)),
            PersonalRecord(type: .longestRun, value: 12000, achievedAt: now),   // longer wins
        ]
        let bests = RecordsBook.currentBests(prs)
        #expect(bests.first { $0.type == .fastest5k }?.value == 1450)
        #expect(bests.first { $0.type == .longestRun }?.value == 12000)
    }

    @Test func backfillPersistsProgressionOnly() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = UserProfile(); ctx.insert(profile)
        // Oldest → newest: 5k @ 5:00, then a slower 5k (no time record), then a faster, longer
        // run (new fastest 5k + longest). 5.1k not 5.0k: haversine step sums land a hair under
        // the nominal distance, and a window needs the full 5000 m.
        _ = run(in: ctx, daysAgo: 20, distanceM: 5100, paceSPerKm: 300)
        _ = run(in: ctx, daysAgo: 10, distanceM: 5100, paceSPerKm: 330)
        _ = run(in: ctx, daysAgo: 2, distanceM: 6000, paceSPerKm: 290)
        try ctx.save()

        RecordsBook.backfillIfNeeded(in: ctx, defaults: defaults())

        let bests = RecordsBook.currentBests(profile.prs)
        let f5k = try #require(bests.first { $0.type == .fastest5k })
        #expect(abs(f5k.value - 5 * 290) < 30)                       // the day-2 run holds it
        let longest = try #require(bests.first { $0.type == .longestRun })
        #expect(longest.value == 6000)
        // The slower middle run must not have logged a fastest-5k row.
        let f5kRows = profile.prs.filter { $0.type == .fastest5k }
        #expect(f5kRows.count == 2)                                  // day-20 set it, day-2 beat it
    }

    @Test func backfillIsIdempotent() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = UserProfile(); ctx.insert(profile)
        _ = run(in: ctx, daysAgo: 5, distanceM: 5000, paceSPerKm: 300)
        try ctx.save()

        let d = defaults()
        RecordsBook.backfillIfNeeded(in: ctx, defaults: d)
        let countAfterFirst = profile.prs.count
        RecordsBook.backfillIfNeeded(in: ctx, defaults: d)           // flag short-circuits
        RecordsBook.backfillIfNeeded(in: ctx, defaults: defaults())  // even a re-replay dedupes
        #expect(profile.prs.count == countAfterFirst)
    }
}
