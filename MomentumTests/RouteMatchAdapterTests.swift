import Testing
import Foundation
import SwiftData
@testable import Momentum

/// The seam between the pure matcher and the app: real `Workout`/`GPSDetail`/`LocationSample`
/// objects in a real store, walked the way `CardioSummaryView` walks them at the finish line.
///
/// The unit tests above prove the geometry. This proves the wiring — that the shared reference
/// latitude survives the round trip, that rejected fixes and other disciplines are excluded, and
/// that a run which retraces one in the history comes back with a verdict about the route rather
/// than about the distance.
@MainActor
struct RouteMatchAdapterTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private static let centerLat = 30.2500
    private static let centerLon = -97.7300
    private static let metersPerDegLat = 111_320.0

    /// A ~5 km two-lap loop with realistic per-outing drift, mirroring the seeded fixture.
    private func loopSamples(start: Date, paceSPerKm: Double, jitterSeed: Int,
                             centerLat: Double = centerLat, centerLon: Double = centerLon)
        -> (samples: [LocationSample], distanceM: Double) {
        let radiusDeg = 0.003574
        let lonScale = 1 / cos(centerLat * .pi / 180)
        var out: [LocationSample] = []
        var distanceM = 0.0, elapsed = 0.0
        var prevLat = 0.0, prevLon = 0.0
        for i in 0..<180 {
            let a = Double(i) / 90 * 2 * .pi
            let driftLat = 10 * sin(Double(i) * 0.7 + Double(jitterSeed)) / Self.metersPerDegLat
            let driftLon = 10 * cos(Double(i) * 0.5 + Double(jitterSeed) * 1.3) * lonScale / Self.metersPerDegLat
            let lat = centerLat + radiusDeg * sin(a) + driftLat
            let lon = centerLon + radiusDeg * cos(a) * lonScale + driftLon
            if i > 0 {
                let step = Geo.distance(lat1: prevLat, lon1: prevLon, lat2: lat, lon2: lon)
                distanceM += step
                elapsed += step / 1000 * paceSPerKm
            }
            let s = LocationSample()
            s.t = start.addingTimeInterval(elapsed)
            s.lat = lat; s.lon = lon
            s.accuracyM = 6
            s.accepted = true
            out.append(s)
            prevLat = lat; prevLon = lon
        }
        return (out, distanceM)
    }

    @discardableResult
    private func insertRun(_ ctx: ModelContext, daysAgo: Double, paceSPerKm: Double,
                           jitterSeed: Int, hr: Int? = nil, type: WorkoutType = .run,
                           centerLat: Double = centerLat, centerLon: Double = centerLon) -> Workout {
        let start = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(-daysAgo * 86_400)
        let trace = loopSamples(start: start, paceSPerKm: paceSPerKm, jitterSeed: jitterSeed,
                                centerLat: centerLat, centerLon: centerLon)
        let w = Workout(); w.type = type; w.startedAt = start
        w.durationS = trace.distanceM / 1000 * paceSPerKm
        let gps = GPSDetail()
        gps.distanceM = trace.distanceM
        gps.avgPaceSPerKm = paceSPerKm
        gps.avgHR = hr
        gps.samples = trace.samples
        w.gps = gps
        ctx.insert(w)
        return w
    }

    // MARK: The whole chain

    @Test func aRunOverGroundAlreadyCoveredIsJudgedAgainstTheRoute() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        for (i, daysAgo) in [35.0, 28, 21, 14].enumerated() {
            insertRun(ctx, daysAgo: daysAgo, paceSPerKm: 350 - Double(i) * 2, jitterSeed: i)
        }
        let today = insertRun(ctx, daysAgo: 0, paceSPerKm: 330, jitterSeed: 9)

        let priors = try ctx.fetch(FetchDescriptor<Workout>()).filter { $0.startedAt < today.startedAt }
        let gps = try #require(today.gps)
        let route = try #require(RouteMatch.context(for: today, gps: gps, priors: priors))
        #expect(route.priors.count == 4)
        #expect(route.isLoop)

        let run = RunVerdict.Run(date: today.startedAt, distanceM: gps.distanceM,
                                 durationS: today.durationS)
        #expect(RunVerdict.verdict(for: run, priors: route.priors, route: route, unit: .metric)?.text
                == "Fastest you've run this loop.")
    }

    @Test func aRunSomewhereNewGetsNoRouteContextAtAll() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        for (i, daysAgo) in [21.0, 14, 7].enumerated() {
            insertRun(ctx, daysAgo: daysAgo, paceSPerKm: 340, jitterSeed: i)
        }
        // Same city, same distance, half a kilometre away: the near miss that must not match.
        let today = insertRun(ctx, daysAgo: 0, paceSPerKm: 330, jitterSeed: 9,
                              centerLat: Self.centerLat + 500 / Self.metersPerDegLat,
                              centerLon: Self.centerLon)
        let priors = try ctx.fetch(FetchDescriptor<Workout>()).filter { $0.startedAt < today.startedAt }
        let gps = try #require(today.gps)
        #expect(RouteMatch.context(for: today, gps: gps, priors: priors) == nil)
    }

    @Test func heartRateTravelsFromTheStoreIntoTheVerdict() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        insertRun(ctx, daysAgo: 28, paceSPerKm: 345, jitterSeed: 0, hr: 168)
        insertRun(ctx, daysAgo: 21, paceSPerKm: 342, jitterSeed: 1, hr: 165)
        insertRun(ctx, daysAgo: 14, paceSPerKm: 340, jitterSeed: 2, hr: 160)
        let today = insertRun(ctx, daysAgo: 0, paceSPerKm: 344, jitterSeed: 9, hr: 152)

        let priors = try ctx.fetch(FetchDescriptor<Workout>()).filter { $0.startedAt < today.startedAt }
        let gps = try #require(today.gps)
        let route = try #require(RouteMatch.context(for: today, gps: gps, priors: priors))
        let run = RunVerdict.Run(date: today.startedAt, distanceM: gps.distanceM,
                                 durationS: today.durationS, avgHR: gps.avgHR)
        #expect(RunVerdict.verdict(for: run, priors: route.priors, route: route, unit: .metric)?.text
                == "Fourth time on this loop, at 8 fewer beats than last time.")
    }

    // MARK: What must never be counted

    @Test func anotherDisciplineOverTheSameGroundIsNotAPriorRun() throws {
        // Riding the loop is not running it. Ranking a run against a ride would be nonsense of
        // exactly the kind this engine exists to avoid.
        let container = try makeContainer()
        let ctx = container.mainContext
        for (i, daysAgo) in [21.0, 14, 7].enumerated() {
            insertRun(ctx, daysAgo: daysAgo, paceSPerKm: 340, jitterSeed: i, type: .ride)
        }
        let today = insertRun(ctx, daysAgo: 0, paceSPerKm: 330, jitterSeed: 9)
        let priors = try ctx.fetch(FetchDescriptor<Workout>()).filter { $0.startedAt < today.startedAt }
        let gps = try #require(today.gps)
        #expect(RouteMatch.context(for: today, gps: gps, priors: priors) == nil)
    }

    @Test func rejectedFixesAreNotPartOfTheFootprint() throws {
        // The accept gate exists because a spike lands the athlete a kilometre away. A footprint
        // built from rejected fixes would smear across half the city and match anything.
        let container = try makeContainer()
        let ctx = container.mainContext
        let prior = insertRun(ctx, daysAgo: 7, paceSPerKm: 340, jitterSeed: 0)
        let today = insertRun(ctx, daysAgo: 0, paceSPerKm: 335, jitterSeed: 1)

        let gps = try #require(today.gps)
        let clean = RouteMatch.trace(gps).count
        let spike = LocationSample()
        spike.lat = Self.centerLat + 5_000 / Self.metersPerDegLat
        spike.lon = Self.centerLon
        spike.accepted = false
        gps.samples.append(spike)
        #expect(RouteMatch.trace(gps).count == clean)
        #expect(RouteMatch.context(for: today, gps: gps, priors: [prior]) != nil)
    }

    @Test func theTraceIsOrderedByTimeNoMatterHowTheStoreHandsItBack() throws {
        // SwiftData gives a to-many relationship back unordered on a refetch. The footprint is a
        // set and does not care, but `isLoop` reads the first and last fix — so an unordered array
        // made the verdict pick "loop" or "route" at random over identical geometry.
        let container = try makeContainer()
        let ctx = container.mainContext
        let w = insertRun(ctx, daysAgo: 0, paceSPerKm: 340, jitterSeed: 3)
        let gps = try #require(w.gps)
        let ordered = RouteMatch.trace(gps)

        gps.samples.shuffle()
        let reshuffled = RouteMatch.trace(gps)
        #expect(reshuffled == ordered)

        let ref = RouteMatch.referenceLat(ordered)
        #expect(RouteMatch.signature(coords: ordered, distanceM: gps.distanceM, referenceLat: ref)
                == RouteMatch.signature(coords: reshuffled, distanceM: gps.distanceM, referenceLat: ref))
        #expect(RouteMatch.signature(coords: reshuffled, distanceM: gps.distanceM, referenceLat: ref).isLoop)
    }

    @Test func aRunWithNoStoredTraceNeverMatches() throws {
        // Apple Health imports arrive as a summary with no fixes. No geometry, no claim.
        let container = try makeContainer()
        let ctx = container.mainContext
        let prior = insertRun(ctx, daysAgo: 7, paceSPerKm: 340, jitterSeed: 0)
        let imported = Workout()
        imported.type = .run
        imported.startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        imported.durationS = 1_700
        let gps = GPSDetail(); gps.distanceM = 5_000
        imported.gps = gps
        ctx.insert(imported)

        #expect(RouteMatch.context(for: imported, gps: gps, priors: [prior]) == nil)
        // And in the other direction: a traced run is not matched against a traceless one.
        let today = insertRun(ctx, daysAgo: 0, paceSPerKm: 335, jitterSeed: 1)
        let todayGPS = try #require(today.gps)
        let route = RouteMatch.context(for: today, gps: todayGPS, priors: [prior, imported])
        #expect(route?.priors.count == 1)
    }
}
