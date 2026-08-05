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

    /// Every OUTDOOR bike carries a GPS route, which is what makes the profile grid and its pager
    /// render a map for one exactly as they do for a run. E-bike is the deliberate exception
    /// (owner call 2026-08-05): picking it means a STATIONARY e-bike, so it captures like the
    /// timed sports — glyph over glow, stopwatch, no map.
    @Test func everyOutdoorBikeIsAMapWorkout() {
        for type in [WorkoutType.ride, .mountainBikeRide, .gravelRide] {
            #expect(type.isGPS, "\(type) must take the GPS/map path in the profile grid")
        }
        #expect(WorkoutType.eBikeRide.isTimed, "e-bike is stationary — stopwatch capture, no map")
        #expect(!WorkoutType.eBikeRide.isGPS, "e-bike must never take the map path")
        // …but stationary is not metric-free: the console's miles/speed/elevation still enter
        // and display everywhere distance does (owner ask 2026-08-05).
        #expect(WorkoutType.eBikeRide.tracksDistance, "e-bike still records console distance")
        for type in WorkoutType.allCases where type.isGPS {
            #expect(type.tracksDistance, "\(type): every GPS sport tracks distance")
        }
    }

    /// The stationary e-bike's manual log stores console readouts exactly like an indoor ride:
    /// a sample-less GPSDetail carrying distance and AVG SPEED (never pace — it's a bike).
    @Test func manualEbikeLogCarriesSpeedNotPace() {
        let w = LogWorkoutBuilder.make(type: .eBikeRide, date: .now, durationS: 1800,
                                       distanceM: 16_093.4, indoor: false, effort: nil, note: "",
                                       exercises: [], resolveExercise: { _ in Exercise() })
        let gps = try! #require(w.gps)
        #expect(abs(gps.distanceM - 16_093.4) < 0.1)
        #expect(gps.avgSpeedMS > 0, "bike logs report speed")
        #expect(gps.avgPaceSPerKm == 0, "a bike never reports running pace")
        #expect(gps.samples.isEmpty, "no samples — nothing can ever render a map")

        // Duration-only e-bike stays a plain timed session — no phantom zero-distance payload.
        let bare = LogWorkoutBuilder.make(type: .eBikeRide, date: .now, durationS: 1800,
                                          distanceM: 0, indoor: false, effort: nil, note: "",
                                          exercises: [], resolveExercise: { _ in Exercise() })
        #expect(bare.gps == nil)
    }
}
