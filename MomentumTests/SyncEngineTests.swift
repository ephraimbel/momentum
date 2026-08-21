import Testing
import Foundation
import SwiftData
@testable import Momentum

/// The sync contract (PRD §8.9/§27): dirty selection + the privacy/raw-log rules for what uploads.
@MainActor
struct SyncEngineTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func gpsRun(_ ctx: ModelContext, privacy: WorkoutPrivacy, synced: Bool) -> Workout {
        let w = Workout(); w.type = .run; w.privacy = privacy
        if synced { w.syncedAt = Date() }
        let g = GPSDetail(); g.distanceM = 5000
        let a = LocationSample(); a.lat = 37.0; a.lon = -122.0; a.accepted = true
        let b = LocationSample(); b.lat = 37.001; b.lon = -122.001; b.accepted = true
        g.samples = [a, b]
        w.gps = g
        ctx.insert(w)
        return w
    }

    @Test func publicRouteUploadsButPrivateStaysOnDevice() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let pub = gpsRun(ctx, privacy: .public, synced: false)
        let priv = gpsRun(ctx, privacy: .private, synced: false)
        try ctx.save()

        #expect(SyncEngine.dto(for: pub).route?.count == 2)   // geometry uploads when public
        #expect(SyncEngine.dto(for: priv).route == nil)        // private ⇒ no geometry leaves the device
    }

    @Test func carriesScalarsAndStrengthSummary() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let w = Workout(); w.type = .strength; w.title = "Push day"; w.calories = 350
        let s = StrengthSession(); s.totalVolumeKg = 4200; s.totalSets = 18
        w.strength = s; ctx.insert(w); try ctx.save()

        let dto = SyncEngine.dto(for: w)
        #expect(dto.type == "strength")
        #expect(dto.title == "Push day")
        #expect(dto.calories == 350)
        #expect(dto.totalVolumeKg == 4200)
        #expect(dto.totalSets == 18)
        #expect(dto.route == nil)   // no GPS
    }

    /// A NaN pace (a zero-distance row divides by zero) used to make `JSONEncoder` throw — which
    /// doesn't drop the field, it kills the whole request that value rode in, on every sweep
    /// forever. The DTO drops non-finite numbers instead, so the batch still encodes.
    @Test func nonFiniteNumbersDropRatherThanPoisonTheBatch() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let w = Workout(); w.type = .run; w.privacy = .public
        w.durationS = .nan
        let g = GPSDetail(); g.distanceM = 0; g.avgPaceSPerKm = .nan; g.elevationGainM = .infinity
        w.gps = g; ctx.insert(w); try ctx.save()

        let dto = SyncEngine.dto(for: w)
        #expect(dto.avgPaceSPerKm == nil)
        #expect(dto.elevationGainM == nil)
        #expect(dto.durationS == 0)          // required on the wire, so it floors rather than vanishes

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        #expect(throws: Never.self) { try encoder.encode([dto]) }
    }

    // MARK: Batching (the guest → sign-in backlog)

    /// The steady state: one new workout is one batch, never split.
    @Test func singleRowNeverClosesABatch() {
        #expect(SyncEngine.shouldCloseBatch(count: 0, points: 0, adding: 3_000) == false)
    }

    /// The workout cap closes a batch of small (strength / short) rows.
    @Test func workoutCapClosesTheBatch() {
        let cap = SyncEngine.batchWorkoutCap
        #expect(SyncEngine.shouldCloseBatch(count: cap - 1, points: 0, adding: 0) == false)
        #expect(SyncEngine.shouldCloseBatch(count: cap, points: 0, adding: 0) == true)
    }

    /// The point cap closes a batch of long runs well before the workout cap would — the case the
    /// count cap alone can't bound (25 ultras is a far bigger body than 25 strength sessions).
    @Test func routePointCapClosesTheBatchEarly() {
        let points = SyncEngine.batchRoutePointCap - 1_000
        #expect(SyncEngine.shouldCloseBatch(count: 3, points: points, adding: 500) == false)
        #expect(SyncEngine.shouldCloseBatch(count: 3, points: points, adding: 2_000) == true)
    }

    /// One workout bigger than the whole point cap still ships — alone. Without the `count > 0`
    /// guard it would close an empty batch forever and the sweep would never advance past it.
    @Test func oversizedSingleWorkoutStillShips() {
        #expect(SyncEngine.shouldCloseBatch(count: 0, points: 0,
                                            adding: SyncEngine.batchRoutePointCap * 2) == false)
    }

    /// Driving the real rule over a backlog: every row lands in exactly one batch, in order, and no
    /// batch exceeds either cap. This is the guest-signs-in shape the single-request sweep died on.
    @Test func backlogSplitsIntoBoundedBatchesCoveringEveryRow() {
        // 120 runs of ~1,800 route points each — a year of training, all dirty at once.
        let rows = Array(repeating: 1_800, count: 120)
        var batches: [[Int]] = []
        var batch: [Int] = []
        var points = 0
        for r in rows {
            if SyncEngine.shouldCloseBatch(count: batch.count, points: points, adding: r) {
                batches.append(batch); batch = []; points = 0
            }
            batch.append(r); points += r
        }
        if !batch.isEmpty { batches.append(batch) }

        #expect(batches.count > 1)                                   // it actually split
        #expect(batches.flatMap(\.self).count == rows.count)         // nothing dropped or duplicated
        for b in batches {
            #expect(b.count <= SyncEngine.batchWorkoutCap)
            #expect(b.reduce(0, +) <= SyncEngine.batchRoutePointCap)
            #expect(b.isEmpty == false)                              // no empty request
        }
    }
}
