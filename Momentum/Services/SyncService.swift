import Foundation
import os
import SwiftData

/// Pushes locally-created workouts to Supabase (PRD §8.9, §27) over PostgREST + URLSession — the same
/// no-SDK approach `AIService` uses. Offline-first: a failure is harmless (the row stays dirty and
/// retries). A no-op until `SupabaseURL` + `SupabaseAnonKey` are set (Info.plist) — see
/// docs/SYNC-SETUP.md. Upload-only for v1; bidirectional merge (last-write-wins scalars, never
/// overwrite sets/sample logs) is the next layer.
///
/// **The sweep uploads in batches** (`SyncEngine.shouldCloseBatch`), and that is load-bearing rather
/// than tidy. Until 2026-08-21 it encoded every dirty row into one request body with the full route
/// geometry inline. In the steady state that is one workout; on the guest → sign-in upgrade it is the
/// entire training history, and a hundred runs of inlined `[[lat, lon]]` is a multi-megabyte POST
/// that the server rejects — after which nothing ever synced again, silently, because a non-2xx just
/// returned. Batching gives the sweep three properties it lacked: bounded request size, **durable
/// partial progress** (each batch stamps `syncedAt` on success, so an interrupted sweep resumes
/// where it stopped instead of restarting), and a failure that is visible in logs and analytics.
@MainActor
final class SyncService: SyncServing {
    private let session: URLSession
    private let analytics: (any AnalyticsServing)?
    private let logger = Logger(subsystem: "com.ephraimbel.momentum.app", category: "sync")

    init(session: URLSession = .shared, analytics: (any AnalyticsServing)? = nil) {
        self.session = session
        self.analytics = analytics
    }

    var isConfigured: Bool { endpoint != nil && bearer != nil }

    /// Push every dirty (never-synced) workout, then stamp `syncedAt` so it isn't sent again.
    func sync(_ workouts: [Workout], in context: ModelContext) async {
        guard let endpoint, let bearer else { return }              // unconfigured → no-op
        // Never upload the recording that is still being captured. Its row exists from the first
        // second (durability), so a sweep firing mid-run — or on the launch right after a crash,
        // before recovery has finalized it — used to ship a 0 km husk AND stamp it, after which the
        // finished workout could never be sent. The marker is exactly "the workout that isn't done".
        let live = ActiveWorkoutMarker.pendingID
        // Oldest first, so a sweep that dies partway leaves a contiguous synced history behind it
        // rather than holes scattered through the athlete's log.
        let pending = workouts
            .filter { $0.syncedAt == nil && $0.id != live }
            .sorted { $0.startedAt < $1.startedAt }
        guard !pending.isEmpty else { return }

        // Owner-only RLS needs the user's session JWT — the anon key can't satisfy
        // `user_id = auth.uid()`. Guests fall back to the anon key, the insert fails RLS,
        // and rows simply stay dirty until they sign in (offline-first by design).
        let token = await SupabaseClientProvider.accessToken() ?? bearer

        var batch: [(workout: Workout, dto: SyncEngine.WorkoutSyncDTO)] = []
        var points = 0

        for workout in pending {
            // Building the DTO faults this workout's `samples` relationship, so it has to run on the
            // context's actor. Doing it one row at a time (rather than mapping all of `pending` up
            // front) is what keeps peak memory at one batch of geometry instead of all of history.
            let dto = SyncEngine.dto(for: workout)
            let routePoints = dto.route?.count ?? 0

            if SyncEngine.shouldCloseBatch(count: batch.count, points: points, adding: routePoints) {
                guard await send(batch, to: endpoint, key: bearer, token: token, in: context) else { return }
                batch.removeAll(keepingCapacity: true)
                points = 0
                // The DTO build above is the one unavoidably main-actor part of this sweep. Yielding
                // between batches keeps a large backlog from holding the main thread for a stretch
                // long enough to drop frames on the map behind it.
                await Task.yield()
            }

            batch.append((workout, dto))
            points += routePoints
        }

        if !batch.isEmpty {
            _ = await send(batch, to: endpoint, key: bearer, token: token, in: context)
        }
    }

    /// Upload one batch and stamp it synced. Returns `false` when the sweep should stop — a failed
    /// batch means offline or a rejecting server, and firing the remaining batches at it would just
    /// be a burst of doomed requests. The rows stay dirty and ride the next sweep.
    private func send(_ batch: [(workout: Workout, dto: SyncEngine.WorkoutSyncDTO)],
                      to endpoint: URL, key: String, token: String,
                      in context: ModelContext) async -> Bool {
        guard !batch.isEmpty else { return true }
        guard let body = await Self.encode(batch.map { $0.dto }) else {
            // Encoding can only fail on a value the DTO shouldn't be able to hold (a non-finite
            // Double from a corrupt sample). Skip the batch rather than wedge the whole sweep on it.
            logger.error("sync encode failed count=\(batch.count, privacy: .public)")
            return true
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")  // upsert on id
        request.httpBody = body

        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status) else {
                // The failure that used to be invisible. A 413 (body too large) or a 401 (expired
                // session) here means sync is permanently stuck for this athlete, and without a
                // signal there is nothing to notice it by.
                logger.error("sync rejected status=\(status, privacy: .public) count=\(batch.count, privacy: .public) bytes=\(body.count, privacy: .public)")
                analytics?.log(.syncFailed(status: status))
                return false
            }
        } catch {
            // Offline / transient — rows stay dirty and sync on the next attempt. Not an analytics
            // event: being offline is the normal state of a phone, not a defect worth counting.
            return false
        }

        let now = Date()
        for row in batch { row.workout.syncedAt = now }
        try? context.save()
        return true
    }

    /// Serialize a batch off the main actor. The DTOs are `Sendable` value types and route geometry
    /// is the bulk of the payload, so this is the expensive half of the sweep and the half that has
    /// no reason to run on the thread drawing the map. `Task.detached` (not a plain `nonisolated`
    /// call) is what actually gets it off `@MainActor`.
    private static func encode(_ dtos: [SyncEngine.WorkoutSyncDTO]) async -> Data? {
        await Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.keyEncodingStrategy = .convertToSnakeCase
            return try? encoder.encode(dtos)
        }.value
    }

    private var endpoint: URL? {
        guard let base = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String, !base.isEmpty,
              let url = URL(string: base) else { return nil }
        return url.appendingPathComponent("rest/v1/workouts")
    }
    private var bearer: String? {
        (Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
