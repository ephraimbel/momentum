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
    var isManualTrim: Bool = false

    @Relationship(deleteRule: .cascade) var samples: [LocationSample] = []
    @Relationship(deleteRule: .cascade) var splits: [Split] = []

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
