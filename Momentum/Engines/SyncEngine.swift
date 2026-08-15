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

    /// Build the upload row for a workout, applying the privacy + raw-log rules.
    /// (SyncService owns the pending selection — the old `pendingUploads` wrapper was
    /// superseded by its live-marker-aware filter and deleted 2026-08-06.)
    static func dto(for w: Workout) -> WorkoutSyncDTO {
        let isPrivate = w.privacy == .private
        let route: [[Double]]? = {
            guard !isPrivate, let gps = w.gps else { return nil }            // private ⇒ geometry stays home
            // Sort by time: SwiftData to-many relationships are unordered on fetch, and an
            // unordered path uploads as a scribble.
            let path = gps.samples.filter(\.accepted).sorted { $0.t < $1.t }.map { [$0.lat, $0.lon] }
            return path.count > 1 ? path : nil
        }()
        return WorkoutSyncDTO(
            id: w.id.uuidString, type: w.type.rawValue, startedAt: w.startedAt,
            durationS: w.durationS, calories: w.calories, perceivedEffort: w.perceivedEffort,
            title: w.title, note: w.note, privacy: w.privacy.rawValue,
            distanceM: w.gps?.distanceM, avgPaceSPerKm: w.gps?.avgPaceSPerKm,
            elevationGainM: w.gps?.elevationGainM,
            totalVolumeKg: w.strength?.totalVolumeKg, totalSets: w.strength?.totalSets,
            route: route)
    }
}
