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

    @Test func onlyNeverSyncedRowsArePending() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        _ = gpsRun(ctx, privacy: .public, synced: false)   // dirty
        _ = gpsRun(ctx, privacy: .public, synced: true)     // already synced
        try ctx.save()
        let pending = SyncEngine.pendingUploads(try ctx.fetch(FetchDescriptor<Workout>()))
        #expect(pending.count == 1)
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
}
