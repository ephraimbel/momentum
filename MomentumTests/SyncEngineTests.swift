import Testing
import Foundation
import SwiftData
@testable import Momentum

/// The sync contract (PRD §8.9/§27): dirty selection + the privacy/raw-log rules for what uploads.
@Suite(.serialized)
@MainActor
struct SyncEngineTests {

    private final class RequestRecorderURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var requests: [URLRequest] = []
        nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            // URLSession commonly hands a custom URLProtocol an upload stream rather than keeping
            // `httpBody` populated. Materialize it so assertions and responders inspect the bytes
            // that production actually sent instead of accidentally treating every body as empty.
            var received = request
            if received.httpBody == nil, let stream = received.httpBodyStream {
                let body = Self.read(stream)
                // `httpBody` and `httpBodyStream` are mutually exclusive. Explicitly clear the
                // stream first; otherwise Foundation can keep returning nil from `httpBody` even
                // after the assignment, causing body-aware stubs to accept every request.
                received.httpBodyStream = nil
                received.httpBody = body
            }
            Self.requests.append(received)
            let stub = Self.responder?(received) ?? (201, Data())
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.0,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.1)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        private static func read(_ stream: InputStream) -> Data {
            stream.open()
            defer { stream.close() }
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                result.append(buffer, count: count)
            }
            return result
        }
    }

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

    private func recordingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestRecorderURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func guestSyncMakesNoDoomedNetworkRequest() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workout = gpsRun(context, privacy: .private, synced: false)
        try context.save()
        RequestRecorderURLProtocol.requests = []
        RequestRecorderURLProtocol.responder = nil

        let service = SyncService(
            session: recordingSession(),
            endpointOverride: URL(string: "https://example.invalid/rest/v1/workouts"),
            bearerOverride: "anon-key",
            accessToken: { nil }
        )
        await service.sync([workout], in: context)

        #expect(RequestRecorderURLProtocol.requests.isEmpty)
        #expect(workout.syncedAt == nil)
    }

    @Test func signedInSyncStillUsesTheUserJWT() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workout = gpsRun(context, privacy: .private, synced: false)
        try context.save()
        RequestRecorderURLProtocol.requests = []
        RequestRecorderURLProtocol.responder = nil

        let service = SyncService(
            session: recordingSession(),
            endpointOverride: URL(string: "https://example.invalid/rest/v1/workouts"),
            bearerOverride: "anon-key",
            accessToken: { "user-jwt" }
        )
        await service.sync([workout], in: context)

        #expect(RequestRecorderURLProtocol.requests.count == 1)
        #expect(RequestRecorderURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer user-jwt")
        #expect(workout.syncedAt != nil)
    }

    @Test func unauthorizedSyncRefreshesOnceAndCarriesTheNewJWT() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workout = gpsRun(context, privacy: .private, synced: false)
        try context.save()
        RequestRecorderURLProtocol.requests = []
        RequestRecorderURLProtocol.responder = { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-jwt" {
                return (201, Data())
            }
            return (401, Data(#"{"code":"PGRST301","message":"JWT expired"}"#.utf8))
        }
        var refreshes = 0

        let service = SyncService(
            session: recordingSession(),
            endpointOverride: URL(string: "https://example.invalid/rest/v1/workouts"),
            bearerOverride: "anon-key",
            accessToken: { "stale-jwt" },
            refreshAccessToken: { refreshes += 1; return "fresh-jwt" }
        )
        await service.sync([workout], in: context)

        #expect(refreshes == 1)
        #expect(RequestRecorderURLProtocol.requests.count == 2)
        #expect(RequestRecorderURLProtocol.requests.last?.value(forHTTPHeaderField: "Authorization")
                == "Bearer fresh-jwt")
        #expect(workout.syncedAt != nil)
    }

    @Test func unauthorizedAfterRefreshStopsWithoutLoopingOrStampingRows() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workouts = [
            gpsRun(context, privacy: .private, synced: false),
            gpsRun(context, privacy: .private, synced: false),
        ]
        try context.save()
        RequestRecorderURLProtocol.requests = []
        RequestRecorderURLProtocol.responder = { _ in
            (401, Data(#"{"code":"PGRST301","message":"JWT rejected"}"#.utf8))
        }
        var refreshes = 0

        let service = SyncService(
            session: recordingSession(),
            endpointOverride: URL(string: "https://example.invalid/rest/v1/workouts"),
            bearerOverride: "anon-key",
            accessToken: { "stale-jwt" },
            refreshAccessToken: { refreshes += 1; return "fresh-jwt" }
        )
        await service.sync(workouts, in: context)

        #expect(refreshes == 1)
        #expect(RequestRecorderURLProtocol.requests.count == 2)
        #expect(workouts.allSatisfy { $0.syncedAt == nil })
    }

    @Test func rowScoped400IsolatesBadWorkoutAndContinuesGoodBackups() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let first = gpsRun(context, privacy: .private, synced: false)
        let bad = gpsRun(context, privacy: .private, synced: false)
        let last = gpsRun(context, privacy: .private, synced: false)
        first.startedAt = Date(timeIntervalSince1970: 1)
        bad.startedAt = Date(timeIntervalSince1970: 2)
        last.startedAt = Date(timeIntervalSince1970: 3)
        try context.save()
        let rejectedID = bad.id.uuidString
        RequestRecorderURLProtocol.requests = []
        RequestRecorderURLProtocol.responder = { request in
            let objects = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()))
                as? [[String: Any]] ?? []
            if objects.contains(where: { $0["id"] as? String == rejectedID }) {
                return (400, Data(#"{"code":"22P02","message":"invalid input syntax"}"#.utf8))
            }
            return (201, Data())
        }

        let service = SyncService(
            session: recordingSession(),
            endpointOverride: URL(string: "https://example.invalid/rest/v1/workouts"),
            bearerOverride: "anon-key",
            accessToken: { "user-jwt" }
        )
        await service.sync([first, bad, last], in: context)

        #expect(first.syncedAt != nil)
        #expect(bad.syncedAt == nil)
        #expect(last.syncedAt != nil)

        // The bad row remains recoverable and dirty, but it cannot hammer the server on every
        // foreground sweep of this app session.
        let requestsAfterIsolation = RequestRecorderURLProtocol.requests.count
        await service.sync([bad], in: context)
        #expect(RequestRecorderURLProtocol.requests.count == requestsAfterIsolation)
    }

    @Test func global400StopsWithoutFanningOutOneRequestPerWorkout() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workouts = (0..<3).map { index -> Workout in
            let workout = gpsRun(context, privacy: .private, synced: false)
            workout.startedAt = Date(timeIntervalSince1970: TimeInterval(index))
            return workout
        }
        try context.save()
        RequestRecorderURLProtocol.requests = []
        RequestRecorderURLProtocol.responder = { _ in
            (400, Data(#"{"code":"PGRST204","message":"column not found"}"#.utf8))
        }

        let service = SyncService(
            session: recordingSession(),
            endpointOverride: URL(string: "https://example.invalid/rest/v1/workouts"),
            bearerOverride: "anon-key",
            accessToken: { "user-jwt" }
        )
        await service.sync(workouts, in: context)

        #expect(RequestRecorderURLProtocol.requests.count == 1)
        #expect(workouts.allSatisfy { $0.syncedAt == nil })
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
