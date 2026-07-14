import Testing
import HealthKit
@testable import Momentum

/// The pure WorkoutType → HealthKit activity mapping (PRD §8.6). No HealthKit store needed.
@MainActor
struct HealthMappingTests {

    @Test func mapsTypesToHealthKitActivities() {
        #expect(HealthService.activityType(for: .run) == .running)
        #expect(HealthService.activityType(for: .trailRun) == .running)
        #expect(HealthService.activityType(for: .ride) == .cycling)
        #expect(HealthService.activityType(for: .mountainBikeRide) == .cycling)
        #expect(HealthService.activityType(for: .eBikeRide) == .cycling)
        #expect(HealthService.activityType(for: .walk) == .walking)
        #expect(HealthService.activityType(for: .hike) == .hiking)
        #expect(HealthService.activityType(for: .strength) == .traditionalStrengthTraining)
        #expect(HealthService.activityType(for: .hiit) == .highIntensityIntervalTraining)
        #expect(HealthService.activityType(for: .yoga) == .yoga)
        #expect(HealthService.activityType(for: .other) == .other)
    }

    @Test func everyTypeMapsTotally() {
        for type in WorkoutType.allCases {
            #expect(HealthService.activityType(for: type) != HKWorkoutActivityType.americanFootball)  // sanity: real value
        }
    }

    // MARK: Import — reverse mapping (HealthKit activity → our WorkoutType)

    @Test func mapsHealthKitActivitiesBackToTypes() {
        #expect(HealthService.workoutType(for: .running) == .run)
        #expect(HealthService.workoutType(for: .walking) == .walk)
        #expect(HealthService.workoutType(for: .hiking) == .hike)
        #expect(HealthService.workoutType(for: .cycling) == .ride)
        #expect(HealthService.workoutType(for: .traditionalStrengthTraining) == .strength)
        #expect(HealthService.workoutType(for: .functionalStrengthTraining) == .strength)
        #expect(HealthService.workoutType(for: .highIntensityIntervalTraining) == .hiit)
        #expect(HealthService.workoutType(for: .swimming) == .swimming)
        #expect(HealthService.workoutType(for: .americanFootball) == .other)  // unmapped → other
    }

    /// The core round-trip: a workout we save out and then read back lands on the same discipline.
    @Test func coreTypesRoundTrip() {
        for type in [WorkoutType.run, .walk, .hike, .ride, .strength, .swimming, .rowing, .tennis] {
            let back = HealthService.workoutType(for: HealthService.activityType(for: type))
            #expect(back.discipline == type.discipline)
        }
    }

    // MARK: Import — assembly

    @Test func assemblesRunWithDerivedPace() {
        let w = HealthService.assembleImport(type: .run, start: .now, duration: 1800, elapsed: 1850,
                                             calories: 320, distanceM: 5000, avgHR: 158)
        #expect(w.type == .run)
        #expect(w.calories == 320)
        #expect(w.elapsedS == 1850)
        #expect(w.gps != nil)
        #expect(w.gps?.distanceM == 5000)
        #expect(w.gps?.avgPaceSPerKm == 1800 / 5.0)   // 360 s/km
        #expect(w.gps?.avgSpeedMS == 0)               // pace, not speed, for run
        #expect(w.gps?.avgHR == 158)
    }

    @Test func assemblesRideWithDerivedSpeed() {
        let w = HealthService.assembleImport(type: .ride, start: .now, duration: 2400, elapsed: 2400,
                                             calories: 410, distanceM: 16000, avgHR: 142)
        #expect(w.gps?.avgSpeedMS == 16000.0 / 2400.0)   // ~6.67 m/s
        #expect(w.gps?.avgPaceSPerKm == 0)            // speed, not pace, for ride
    }

    @Test func assemblesStrengthWithoutGPS() {
        let w = HealthService.assembleImport(type: .strength, start: .now, duration: 2700, elapsed: 2700,
                                             calories: 260, distanceM: 0, avgHR: 121)
        #expect(w.gps == nil)                          // strength carries no route
        #expect(w.calories == 260)
    }

    @Test func dropsNonPositiveCaloriesAndElapsedNeverBelowDuration() {
        let w = HealthService.assembleImport(type: .run, start: .now, duration: 1800, elapsed: 0,
                                             calories: 0, distanceM: 5000, avgHR: nil)
        #expect(w.calories == nil)                     // 0 kcal → nil, not a bogus zero
        #expect(w.elapsedS == 1800)                    // elapsed floored to duration
    }

    // MARK: Import — filter (own-echo + dedupe)

    @Test func skipsOurOwnEchoedWrites() {
        let mine = "com.ephraimbel.momentum.app"
        let withMarker: [String: Any] = [HKMetadataKeyExternalUUID: UUID().uuidString]
        // Same bundle + our marker → it's a workout already in our store; don't re-import.
        #expect(HealthService.shouldImport(sourceBundle: mine, ownBundle: mine,
                                           metadata: withMarker, alreadyImported: [], uuid: "A") == false)
    }

    @Test func importsForeignWorkouts() {
        let mine = "com.ephraimbel.momentum.app"
        // A Garmin/Watch workout: different bundle, no marker → import it.
        #expect(HealthService.shouldImport(sourceBundle: "com.garmin.connect", ownBundle: mine,
                                           metadata: [:], alreadyImported: [], uuid: "B") == true)
    }

    @Test func skipsAlreadyImported() {
        let mine = "com.ephraimbel.momentum.app"
        #expect(HealthService.shouldImport(sourceBundle: "com.garmin.connect", ownBundle: mine,
                                           metadata: [:], alreadyImported: ["C"], uuid: "C") == false)
    }

    @Test func importsOurBundleWorkoutsLackingMarker() {
        // Same bundle but no marker (e.g. a sim seed, or a workout we didn't author via save()) → import.
        let mine = "com.ephraimbel.momentum.app"
        #expect(HealthService.shouldImport(sourceBundle: mine, ownBundle: mine,
                                           metadata: [:], alreadyImported: [], uuid: "D") == true)
    }
}
