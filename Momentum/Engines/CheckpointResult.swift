import Foundation

/// Reading a checkpoint out of the run that carried it.
///
/// The athlete warms up first, so the recording is usually longer than the test. The test is then
/// the fastest window of the test distance inside the recording, from the same reduction the
/// records book uses for a fastest mile or 5K. A recording that IS the test (within ten percent of
/// the distance) reads as a whole. Deterministic; nothing here touches the store.
enum CheckpointResult {
    struct Reading: Equatable, Sendable {
        var distanceM: Double
        var timeS: Double
    }

    nonisolated static func read(workout: Workout, testDistanceM: Double) -> Reading? {
        guard let gps = workout.gps, gps.distanceM.isFinite, workout.durationS.isFinite,
              testDistanceM.isFinite, testDistanceM > 0,
              gps.distanceM >= testDistanceM * 0.98, workout.durationS > 0 else { return nil }
        if gps.distanceM <= testDistanceM * 1.1 {
            return Reading(distanceM: gps.distanceM, timeS: workout.durationS)
        }
        let points = gps.samplePoints(type: workout.type)
        if let t = CardioMetrics.fastestWindow(points, distanceM: testDistanceM), t > 0 {
            return Reading(distanceM: testDistanceM, timeS: t)
        }
        // A longer recording without a readable test window is not a measured checkpoint.
        return nil
    }
}
