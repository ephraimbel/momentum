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
    private let endpointOverride: URL?
    private let bearerOverride: String?
    private let accessToken: () async -> String?
    private let refreshAccessToken: () async -> String?
    /// A server-rejected row is retried on the next app launch, but never on every foreground sweep
    /// of this one. The UUID stays on-device; diagnostics receive only bounded error categories.
    private var rejectedThisSession: Set<UUID> = []
    private let logger = Logger(subsystem: "com.ephraimbel.momentum.app", category: "sync")

    init(session: URLSession = .shared,
         analytics: (any AnalyticsServing)? = nil,
         endpointOverride: URL? = nil,
         bearerOverride: String? = nil,
         accessToken: @escaping () async -> String? = { await SupabaseClientProvider.accessToken() },
         refreshAccessToken: @escaping () async -> String? = {
             await SupabaseClientProvider.refreshAccessToken()
         }) {
        self.session = session
        self.analytics = analytics
        self.endpointOverride = endpointOverride
        self.bearerOverride = bearerOverride
        self.accessToken = accessToken
        self.refreshAccessToken = refreshAccessToken
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
            .filter { $0.syncedAt == nil && $0.id != live && !rejectedThisSession.contains($0.id) }
            .sorted { $0.startedAt < $1.startedAt }
        guard !pending.isEmpty else { return }

        // Owner-only RLS needs the user's session JWT — the anon key cannot satisfy
        // `user_id = auth.uid()`. A guest therefore has nothing useful to send: leave the rows
        // dirty and return without making a request. They are re-marked and uploaded after the
        // first cloud session (MomentumApp.onFirstCloudSession).
        guard var token = await accessToken() else { return }
        var mayRefreshToken = true

        var batch: [(workout: Workout, dto: SyncEngine.WorkoutSyncDTO)] = []
        var points = 0

        for workout in pending {
            // Building the DTO faults this workout's `samples` relationship, so it has to run on the
            // context's actor. Doing it one row at a time (rather than mapping all of `pending` up
            // front) is what keeps peak memory at one batch of geometry instead of all of history.
            let dto = SyncEngine.dto(for: workout)
            let routePoints = dto.route?.count ?? 0

            if SyncEngine.shouldCloseBatch(count: batch.count, points: points, adding: routePoints) {
                let progress = await send(batch, to: endpoint, key: bearer, token: token,
                                          mayRefreshToken: mayRefreshToken, in: context)
                token = progress.token
                mayRefreshToken = progress.mayRefreshToken
                guard progress.shouldContinue else { return }
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
            _ = await send(batch, to: endpoint, key: bearer, token: token,
                           mayRefreshToken: mayRefreshToken, in: context)
        }
    }

    private struct SendProgress {
        let shouldContinue: Bool
        let token: String
        let mayRefreshToken: Bool
    }

    private struct PostgRESTError: Decodable {
        let code: String?
    }

    /// Upload one batch and stamp it synced. Authentication gets exactly one forced refresh for the
    /// whole sweep. A row-scoped 400 or a 413 is bisected until the rejecting row is isolated; good
    /// siblings still back up, while the bad row remains local and is retried next launch. Global
    /// contract errors (for example a stale/missing column) are NOT bisected — turning one schema
    /// problem into 25 requests would make the outage worse.
    private func send(_ batch: [(workout: Workout, dto: SyncEngine.WorkoutSyncDTO)],
                      to endpoint: URL, key: String, token: String, mayRefreshToken: Bool,
                      in context: ModelContext) async -> SendProgress {
        guard !batch.isEmpty else {
            return SendProgress(shouldContinue: true, token: token,
                                mayRefreshToken: mayRefreshToken)
        }
        guard let body = await Self.encode(batch.map { $0.dto }) else {
            // DTOs already drop non-finite numbers, so this should be unreachable. Isolate rather
            // than let one corrupt legacy row prevent newer workouts from backing up.
            if batch.count > 1 {
                return await splitAndSend(batch, to: endpoint, key: key, token: token,
                                          mayRefreshToken: mayRefreshToken, in: context)
            }
            rejectedThisSession.insert(batch[0].workout.id)
            logger.error("sync encode failed count=1")
            SentryMonitor.capture(.syncEncodingFailed, tags: ["count_bucket": "one"])
            return SendProgress(shouldContinue: true, token: token,
                                mayRefreshToken: mayRefreshToken)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")  // upsert on id
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return SendProgress(shouldContinue: false, token: token,
                                    mayRefreshToken: mayRefreshToken)
            }
            let status = http.statusCode
            if (200..<300).contains(status) {
                let now = Date()
                for row in batch { row.workout.syncedAt = now }
                try? context.save()
                return SendProgress(shouldContinue: true, token: token,
                                    mayRefreshToken: mayRefreshToken)
            }

            let errorCode = Self.postgrestCode(in: data)

            // A token may expire after `auth.session` hands it to us. Force one refresh for this
            // sweep, retry the exact same body once, and carry the new token into later batches.
            if status == 401, mayRefreshToken,
               let refreshed = await refreshAccessToken(), !refreshed.isEmpty, refreshed != token {
                return await send(batch, to: endpoint, key: key, token: refreshed,
                                  mayRefreshToken: false, in: context)
            }

            if Self.isRowScoped(status: status, errorCode: errorCode) {
                if batch.count > 1 {
                    return await splitAndSend(batch, to: endpoint, key: key, token: token,
                                              mayRefreshToken: mayRefreshToken, in: context)
                }
                // Keep the rejected workout dirty. Only suppress more attempts during this app
                // session; a new build or server migration gets another chance next launch.
                rejectedThisSession.insert(batch[0].workout.id)
                reportRejection(status: status, errorCode: errorCode, count: 1,
                                bytes: body.count, authRetried: !mayRefreshToken)
                return SendProgress(shouldContinue: true, token: token,
                                    mayRefreshToken: mayRefreshToken)
            }

            // Auth, rate-limit, server, and global schema failures stop the sweep. All rows remain
            // dirty. We deliberately do not fan a global failure out across the rest of the queue.
            reportRejection(status: status, errorCode: errorCode, count: batch.count,
                            bytes: body.count, authRetried: status == 401 && !mayRefreshToken)
            return SendProgress(shouldContinue: false, token: token,
                                mayRefreshToken: mayRefreshToken)
        } catch {
            // Offline / transient — rows stay dirty and sync on the next attempt. Not an analytics
            // event: being offline is the normal state of a phone, not a defect worth counting.
            return SendProgress(shouldContinue: false, token: token,
                                mayRefreshToken: mayRefreshToken)
        }
    }

    private func splitAndSend(_ batch: [(workout: Workout, dto: SyncEngine.WorkoutSyncDTO)],
                              to endpoint: URL, key: String, token: String,
                              mayRefreshToken: Bool, in context: ModelContext) async -> SendProgress {
        let middle = batch.count / 2
        let left = Array(batch[..<middle])
        let right = Array(batch[middle...])
        let first = await send(left, to: endpoint, key: key, token: token,
                               mayRefreshToken: mayRefreshToken, in: context)
        guard first.shouldContinue else { return first }
        return await send(right, to: endpoint, key: key, token: first.token,
                          mayRefreshToken: first.mayRefreshToken, in: context)
    }

    private func reportRejection(status: Int, errorCode: String?, count: Int, bytes: Int,
                                 authRetried: Bool) {
        logger.error("sync rejected status=\(status, privacy: .public) code=\(errorCode ?? "unknown", privacy: .public) count=\(count, privacy: .public) bytes=\(bytes, privacy: .public)")
        analytics?.log(.syncFailed(status: status))
        let issue: SentryMonitor.Issue = switch status {
        case 401: .syncUnauthorized
        case 400, 413: .syncPayloadRejected
        default: .syncRejected
        }
        SentryMonitor.capture(issue, tags: [
            "status": String(status),
            "error_code": errorCode ?? "unknown",
            "count_bucket": Self.countBucket(count),
            "byte_bucket": Self.byteBucket(bytes),
            "auth_retried": String(authRetried),
        ])
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

    /// Coarse context only — enough to distinguish one bad row from a backlog without transmitting
    /// an athlete's exact workout count.
    private static func countBucket(_ count: Int) -> String {
        switch count {
        case ..<2: "one"
        case 2...5: "two_to_five"
        default: "six_plus"
        }
    }

    private static func byteBucket(_ bytes: Int) -> String {
        switch bytes {
        case ..<32_768: "under_32k"
        case ..<262_144: "32k_to_256k"
        case ..<1_048_576: "256k_to_1m"
        default: "over_1m"
        }
    }

    /// Only the bounded PostgREST/SQLSTATE code leaves the response body. Free-form messages,
    /// details and hints can echo rejected values, so they are deliberately never logged or sent.
    private static func postgrestCode(in data: Data) -> String? {
        guard data.count <= 16_384,
              let raw = try? JSONDecoder().decode(PostgRESTError.self, from: data).code else { return nil }
        let code = raw.uppercased()
        guard !code.isEmpty, code.count <= 32,
              code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
        else { return nil }
        return code
    }

    /// SQLSTATE class 22 = data exception; 23 = integrity constraint. Those failures can belong to
    /// one row and are safe to isolate. 413 is body-size-specific and is likewise divisible. A
    /// PGRST schema/query error is global and must stop, not explode into one request per workout.
    private static func isRowScoped(status: Int, errorCode: String?) -> Bool {
        if status == 413 { return true }
        guard status == 400, let errorCode else { return false }
        return errorCode.hasPrefix("22") || errorCode.hasPrefix("23")
    }

    private var endpoint: URL? {
        if let endpointOverride { return endpointOverride }
        guard let base = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String, !base.isEmpty,
              let url = URL(string: base) else { return nil }
        return url.appendingPathComponent("rest/v1/workouts")
    }
    private var bearer: String? {
        if let bearerOverride { return bearerOverride }
        return (Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}
