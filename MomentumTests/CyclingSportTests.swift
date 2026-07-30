import Foundation
import Testing
@testable import Momentum

/// Cycling is FOUR sports, and six display surfaces used to check `type == .ride` exactly.
///
/// The effect was invisible on a plain Ride and wrong on every other bike: a mountain, gravel or
/// e-bike ride reported a running **pace in min/mi** — on the profile pager's stat row, the workout
/// summary's "Avg pace", the share card, and Progress trends — and `RunCharts` drew it a pace chart
/// and a per-mile splits card besides. `WorkoutType.isCycling` is the single answer those surfaces
/// ask now; this pins it so the exact-match shortcut can't creep back one call site at a time.
struct CyclingSportTests {

    @Test func everyBikeIsCycling() {
        for type in [WorkoutType.ride, .mountainBikeRide, .gravelRide, .eBikeRide] {
            #expect(type.isCycling, "\(type) is a bike and must report speed, not pace")
        }
    }

    @Test func nothingElseIsCycling() {
        for type in [WorkoutType.run, .trailRun, .walk, .hike, .strength, .swimming, .rowing] {
            #expect(!type.isCycling, "\(type) is not a bike")
        }
    }

    /// `isCycling` must agree with the planning vocabulary — it exists so display code doesn't have
    /// to import `Discipline`, not so it can drift from it.
    @Test func matchesTheCyclingDiscipline() {
        for type in WorkoutType.allCases {
            #expect(type.isCycling == (type.discipline == .cycling),
                    "\(type): isCycling and discipline disagree")
        }
    }

    /// Every bike carries a GPS route, which is what makes the profile grid and its pager render a
    /// map for one exactly as they do for a run.
    @Test func everyBikeIsAMapWorkout() {
        for type in [WorkoutType.ride, .mountainBikeRide, .gravelRide, .eBikeRide] {
            #expect(type.isGPS, "\(type) must take the GPS/map path in the profile grid")
        }
    }
}
