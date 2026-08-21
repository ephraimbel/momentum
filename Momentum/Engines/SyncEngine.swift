import Foundation

/// The deterministic sync **contract** (PRD §8.9, §27): which rows are dirty, and exactly what
/// leaves the device. Pure + testable — the network transport (`SyncService`) just ships what this
/// produces. Rules encoded here:
///  • **Dirty = never-synced** (`syncedAt == nil`) for v1; an edit clears `syncedAt` to re-sync.
///  • **Raw `LocationSample` logs stay on-device** — only the route *geometry* (lat/lon path) syncs.
///  • **Route geometry uploads only when the workout isn't private** (§8.9).
enum SyncEngine {

    /// One workout row to upsert (mirrors the Supabase `workouts` table). Child detail (full set
    /// rows) is a later layer; this carries the row scalars, a strength summary, and — privacy
    /// permitting — the route geometry.
    struct WorkoutSyncDTO: Codable, Equatable, Sendable {
        let id: String
        let type: String
        let startedAt: Date
        let durationS: Double
        let calories: Double?
        let perceivedEffort: Int?
        let title: String
        let note: String
        let privacy: String
        let distanceM: Double?
        let avgPaceSPerKm: Double?
        let elevationGainM: Double?
        let totalVolumeKg: Double?
        let totalSets: Int?
        /// [[lat, lon]] path — `nil` when private or non-GPS. Never includes raw sample metadata.
        let route: [[Double]]?
    }

    // MARK: Batching

    /// Max workouts in one upload request. The sweep used to POST **every** dirty row in a single
    /// body, which is fine for the steady state (one new workout) and fatal for the case that
    /// actually matters: a guest signing in, where the whole training history is dirty at once.
    static let batchWorkoutCap = 25

    /// Max route points in one upload request. The workout cap alone doesn't bound the body — a
    /// batch of 25 ultras carries far more geometry than 25 strength sessions — so whichever cap
    /// trips first closes the batch. ~20k points ≈ 600 KB of JSON, comfortably inside any
    /// PostgREST/proxy body limit.
    static let batchRoutePointCap = 20_000

    /// Should the batch accumulated so far be sent *before* adding a row carrying `adding` route
    /// points? The whole batching rule, kept pure so it is testable without a store or a network.
    ///
    /// A single row larger than the point cap still goes out alone (`count > 0` guard) — one
    /// oversized workout must not deadlock the sweep behind an empty batch that never fills.
    static func shouldCloseBatch(count: Int, points: Int, adding: Int) -> Bool {
        count > 0 && (count >= batchWorkoutCap || points + adding > batchRoutePointCap)
    }

    // MARK: Encodability

    /// Drop a non-finite Double. `JSONEncoder` **throws** on NaN and infinity by default, and a
    /// throw here doesn't fail one field — it fails the entire request the value happened to ride
    /// in, permanently, on every future sweep. Non-finite values are reachable in ordinary data:
    /// `avgPaceSPerKm` is a division by distance, so a zero-distance row carries NaN. Uploading the
    /// field as absent is honest (the value genuinely isn't a number) and keeps one bad row from
    /// taking its whole batch down with it.
    static func finite(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return v
    }

    /// Build the upload row for a workout, applying the privacy + raw-log rules.
    /// (SyncService owns the pending selection — the old `pendingUploads` wrapper was
    /// superseded by its live-marker-aware filter and deleted 2026-08-06.)
    static func dto(for w: Workout) -> WorkoutSyncDTO {
        let isPrivate = w.privacy == .private
        let route: [[Double]]? = {
            guard !isPrivate, let gps = w.gps else { return nil }            // private ⇒ geometry stays home
            // Sort by time: SwiftData to-many relationships are unordered on fetch, and an
            // unordered path uploads as a scribble.
            let path = gps.samples
                .filter { $0.accepted && $0.lat.isFinite && $0.lon.isFinite }
                .sorted { $0.t < $1.t }
                .map { [$0.lat, $0.lon] }
            return path.count > 1 ? path : nil
        }()
        return WorkoutSyncDTO(
            id: w.id.uuidString, type: w.type.rawValue, startedAt: w.startedAt,
            durationS: finite(w.durationS) ?? 0,   // non-optional on the wire: absent isn't a choice
            calories: finite(w.calories), perceivedEffort: w.perceivedEffort,
            title: w.title, note: w.note, privacy: w.privacy.rawValue,
            distanceM: finite(w.gps?.distanceM), avgPaceSPerKm: finite(w.gps?.avgPaceSPerKm),
            elevationGainM: finite(w.gps?.elevationGainM),
            totalVolumeKg: finite(w.strength?.totalVolumeKg), totalSets: w.strength?.totalSets,
            route: route)
    }
}
