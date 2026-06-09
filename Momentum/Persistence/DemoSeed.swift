#if DEBUG
import Foundation
import SwiftData
import CoreLocation

/// DEBUG-only sample data for visual iteration. Runs **only** when launched with `--seed-demo`
/// and the store has no profile yet. Never ships behavior in release builds.
@MainActor
enum DemoSeed {
    static func seedIfRequested(_ context: ModelContext) {
        guard ProcessInfo.processInfo.arguments.contains("--seed-demo") else { return }
        let existing = (try? context.fetch(FetchDescriptor<UserProfile>())) ?? []
        guard existing.isEmpty else { return }

        let profile = UserProfile()
        profile.disciplines = ["running", "strength"]
        profile.goal = .buildMuscle
        profile.daysPerWeek = 4
        profile.experience = ["running": "some", "strength": "some"]
        context.insert(profile)
        PlanService.regenerate(for: profile, in: context)

        // A completed run earlier today (with a loop route for the silhouette/snapshot).
        let run = Workout()
        run.type = .run
        run.startedAt = Date().addingTimeInterval(-3 * 3600)
        run.durationS = 1750
        let gps = GPSDetail()
        gps.distanceM = 6050
        gps.elevationGainM = 42
        gps.avgPaceSPerKm = 289
        gps.samples = loopSamples(start: run.startedAt)
        run.gps = gps
        context.insert(run)

        // A completed strength session yesterday.
        if let bench = (try? context.fetch(FetchDescriptor<Exercise>()))?.first(where: { $0.name == "Barbell Bench Press" }) {
            let sw = Workout()
            sw.type = .strength
            sw.startedAt = Date().addingTimeInterval(-26 * 3600)
            sw.durationS = 3120
            let session = StrengthSession()
            session.totalVolumeKg = 5400
            session.totalSets = 18
            let row = WorkoutExercise()
            row.exercise = bench
            let set = SetEntry(); set.weightKg = 70; set.reps = 6; set.isComplete = true; set.type = .working
            row.sets = [set]
            session.exercises = [row]
            sw.strength = session
            context.insert(sw)
        }
        try? context.save()

        // Render a real route snapshot for the demo run so the Strava-style image is visible.
        let coords = gps.samples.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        Task { @MainActor in
            if let data = await RouteSnapshotter.snapshot(coordinates: coords) {
                gps.mapSnapshotData = data
                try? context.save()
            }
        }
    }

    /// ~24 samples tracing a rough loop near SF for a believable route.
    private static func loopSamples(start: Date) -> [LocationSample] {
        let centerLat = 37.7694, centerLon = -122.4862, r = 0.004
        return (0..<24).map { i in
            let a = Double(i) / 24 * 2 * .pi
            let s = LocationSample()
            s.t = start.addingTimeInterval(Double(i) * 70)
            s.lat = centerLat + r * sin(a)
            s.lon = centerLon + r * cos(a) * 1.3
            s.accuracyM = 6
            s.accepted = true
            return s
        }
    }
}
#endif
