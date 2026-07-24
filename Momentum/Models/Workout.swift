import Foundation
import SwiftData

/// Unified workout record — cardio *or* strength (PRD §8.7). Carries **exactly one** of
/// `gps`/`strength`, determined by `type` (GPS for run/ride/walk/hike; strength for strength).
@Model
final class Workout {
    var id: UUID = UUID()
    var type: WorkoutType = WorkoutType.run
    var startedAt: Date = Date()
    var durationS: Double = 0       // moving (cardio) / active (strength)
    var elapsedS: Double = 0
    var calories: Double?
    var perceivedEffort: Int?       // 1–10 RPE, optional one-tap
    var title: String = ""          // user-given activity name (Strava-style)
    var note: String = ""           // user description
    var privacy: WorkoutPrivacy = WorkoutPrivacy.private
    var aiSummary: String?
    var syncedAt: Date?
    /// When this workout's social post was last published (nil = not published). The publish
    /// sweep (`SocialSyncEngine.publishActions`) treats it exactly like `syncedAt`: shared+nil →
    /// publish; private+set → unpublish (privacy downgrade deletes the post). Cleared on first
    /// cloud sign-in so guest-era history re-publishes under the new account. Additive-only.
    var postPublishedAt: Date?
    var plannedSession: PlannedSession?
    /// Legacy single photo (pre multi-photo, 2026-07). Kept as-is for lightweight migration — never
    /// rename/retype it. New photos go to `photos`; this field is folded in lazily on the next photo
    /// edit (see `WorkoutPhotoSection`). Read through `orderedPhotosData`, not directly.
    @Attribute(.externalStorage) var photoData: Data?

    @Relationship(deleteRule: .cascade) var gps: GPSDetail?
    @Relationship(deleteRule: .cascade) var strength: StrengthSession?
    /// Photos the athlete attached, Strava-style (cap `Workout.photoCap`, ordered; first is the hero).
    /// Each is its own external-storage blob so grids can fault just the hero.
    @Relationship(deleteRule: .cascade) var photos: [WorkoutPhoto] = []

    init() {}

    /// UI cap on attached photos per workout (a calm, premium card — not an album).
    static let photoCap = 5

    /// The workout's photos in display order — the multi-photo set when present, else the legacy
    /// single photo. First element is always the hero. Faults every blob — feed cards/pagers only;
    /// grids and tiles must read `heroPhotoData` instead.
    var orderedPhotosData: [Data] {
        let ordered = photos.sorted { $0.order < $1.order }.map(\.data)
        if !ordered.isEmpty { return ordered }
        return photoData.map { [$0] } ?? []
    }

    /// The hero photo alone — faults a single blob (what grid tiles render while scrolling).
    var heroPhotoData: Data? {
        if let first = photos.min(by: { $0.order < $1.order }) { return first.data }
        return photoData
    }
}

/// One attached workout photo — a child row so each blob lives in its own external storage and is
/// faulted only when actually rendered (the feed card / pager), never en masse by a workouts query.
@Model
final class WorkoutPhoto {
    var id: UUID = UUID()
    var order: Int = 0
    @Attribute(.externalStorage) var data: Data = Data()

    init(order: Int = 0, data: Data = Data()) {
        self.order = order
        self.data = data
    }
}

@Model
final class GPSDetail {
    var distanceM: Double = 0
    var avgPaceSPerKm: Double = 0   // run/walk
    var avgSpeedMS: Double = 0      // ride
    var elevationGainM: Double = 0
    var avgHR: Int?
    var avgCadence: Int?            // steps/min (run) or rpm (ride)
    var mapSnapshotData: Data?      // true-B/W PNG
    /// The basemap this workout's map renders with — chosen on the save screen (nil = the athlete's
    /// app-wide persisted style at render time). Raw string for SwiftData migration safety.
    var mapStyleRaw: String?
    /// Route snapped to the road/path network by Mapbox Map Matching (§8.5), stored as JSON
    /// `[[lat, lon]]`. Present only when matching succeeded above the confidence gate; display falls
    /// back to the Kalman-filtered raw trace when nil. The raw `samples` are always retained.
    var matchedRouteData: Data?
    var isManualTrim: Bool = false

    @Relationship(deleteRule: .cascade) var samples: [LocationSample] = []
    @Relationship(deleteRule: .cascade) var splits: [Split] = []
    @Relationship(deleteRule: .cascade) var hrSamples: [HeartRateSample] = []
    /// Per-rep results from a guided structured run (JSON-encoded `[RepResult]`) — the post-run
    /// adherence breakdown. nil for a plain run.
    var structuredRepsData: Data?
    var structuredReps: [RepResult] {
        structuredRepsData.flatMap { try? JSONDecoder().decode([RepResult].self, from: $0) } ?? []
    }

    /// The workout's map style, resolved: the saved per-run choice, else the app-wide style.
    var mapStyle: MapStyleOption {
        mapStyleRaw.flatMap(MapStyleOption.init(rawValue:)) ?? .persisted
    }

    init() {}
}

/// A live heart-rate reading captured during the workout (running-excellence R3) — from a BLE strap
/// or an Apple Watch workout session via Health. Persisted as it arrives (durability), powering the
/// post-run HR chart + time-in-zones for runs recorded by us (Health only has series for *imported*
/// workouts).
@Model
final class HeartRateSample {
    var t: Date = Date()
    var bpm: Int = 0

    init() {}
}

/// Durability: persist each accepted fix immediately. **Never deleted on edit** — mark, don't destroy.
@Model
final class LocationSample {
    var t: Date = Date()
    var lat: Double = 0
    var lon: Double = 0
    var accuracyM: Double = 0
    var altitudeM: Double = 0
    var speedMS: Double = 0
    var accepted: Bool = true

    init() {}
}

@Model
final class Split {
    var index: Int = 0
    var distanceM: Double = 0
    var durationS: Double = 0
    var avgHR: Int?
    var avgCadence: Int?
    var elevDeltaM: Double = 0
    var isPartial: Bool = false

    init() {}
}

/// Cheap content signature over already-materialized scalars — the cache key for aggregates
/// that must refresh on equal-count mutations (edit a saved workout's sport, delete one and
/// import another in the same session). A count-only key silently replays stale charts through
/// exactly those edits. Scalars only — never faults relationships (sets, GPS samples).
extension Array where Element == Workout {
    var contentSignature: Int {
        var h = Hasher()
        h.combine(count)
        for w in self {
            h.combine(w.startedAt)
            h.combine(w.type.rawValue)
            h.combine(w.durationS)
        }
        return h.finalize()
    }
}
