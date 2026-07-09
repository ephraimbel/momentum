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
    var plannedSession: PlannedSession?
    /// An optional photo the athlete attached to this workout (Strava-style). Stored outside the row
    /// (external storage) since it's a large blob; only the public projection ever syncs.
    @Attribute(.externalStorage) var photoData: Data?

    @Relationship(deleteRule: .cascade) var gps: GPSDetail?
    @Relationship(deleteRule: .cascade) var strength: StrengthSession?

    init() {}
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
