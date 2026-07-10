import Foundation
import SwiftData

/// Pushes locally-created workouts to Supabase (PRD §8.9, §27) over PostgREST + URLSession — the same
/// no-SDK approach `AIService` uses. Offline-first: a failure is harmless (the row stays dirty and
/// retries). A no-op until `SupabaseURL` + `SupabaseAnonKey` are set (Info.plist) — see
/// docs/SYNC-SETUP.md. Upload-only for v1; bidirectional merge (last-write-wins scalars, never
/// overwrite sets/sample logs) is the next layer.
@MainActor
final class SyncService: SyncServing {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    var isConfigured: Bool { endpoint != nil && bearer != nil }

    /// Push every dirty (never-synced) workout, then stamp `syncedAt` so it isn't sent again.
    func sync(_ workouts: [Workout], in context: ModelContext) async {
        guard let endpoint, let bearer else { return }              // unconfigured → no-op
        let pending = workouts.filter { $0.syncedAt == nil }
        guard !pending.isEmpty else { return }

        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(bearer, forHTTPHeaderField: "apikey")
            // Owner-only RLS needs the user's session JWT — the anon key can't satisfy
            // `user_id = auth.uid()`. Guests fall back to the anon key, the insert fails RLS,
            // and rows simply stay dirty until they sign in (offline-first by design).
            let token = await SupabaseClientProvider.accessToken() ?? bearer
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")  // upsert on id

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.keyEncodingStrategy = .convertToSnakeCase
            request.httpBody = try encoder.encode(pending.map(SyncEngine.dto(for:)))

            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }

            let now = Date()
            for workout in pending { workout.syncedAt = now }
            try? context.save()
        } catch {
            // Offline / transient — rows stay dirty and sync on the next attempt.
        }
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
