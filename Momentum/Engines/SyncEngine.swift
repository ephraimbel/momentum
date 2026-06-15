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

    /// Rows that still need pushing, oldest first.
    static func pendingUploads(_ workouts: [Workout]) -> [WorkoutSyncDTO] {
        workouts
            .filter { $0.syncedAt == nil }
            .sorted { $0.startedAt < $1.startedAt }
            .map(dto(for:))
    }

    /// Build the upload row for a workout, applying the privacy + raw-log rules.
    static func dto(for w: Workout) -> WorkoutSyncDTO {
        let isPrivate = w.privacy == .private
        let route: [[Double]]? = {
            guard !isPrivate, let gps = w.gps else { return nil }            // private ⇒ geometry stays home
            let path = gps.samples.filter(\.accepted).map { [$0.lat, $0.lon] }
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
