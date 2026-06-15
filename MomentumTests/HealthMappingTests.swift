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
}
