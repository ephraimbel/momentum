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
        profile.weightUnit = WeightUnit.default().rawValue   // locale display units (lb in US/UK)
        context.insert(profile)
        PlanService.regenerate(for: profile, in: context)

        let bench = (try? context.fetch(FetchDescriptor<Exercise>()))?.first(where: { $0.name == "Barbell Bench Press" })

        // ~5 weeks of history with a gently building trend, so Progress charts + ACWR populate.
        for daysAgo in [0, 2, 4, 7, 9, 11, 14, 16, 18, 21, 24, 26, 30, 33] {
            let start = Date().addingTimeInterval(Double(-daysAgo) * 86_400 - 3 * 3600)
            let week = Double(daysAgo) / 7
            if daysAgo % 4 == 0 {
                let sw = Workout(); sw.type = .strength; sw.startedAt = start
                sw.durationS = 2700 + Double(14 - daysAgo) * 20
                let session = StrengthSession()
                session.totalVolumeKg = 4800 + (5 - week) * 250
                session.totalSets = 16
                if let bench {
                    let row = WorkoutExercise(); row.exercise = bench
                    let set = SetEntry(); set.weightKg = 62 + (5 - week) * 2; set.reps = 6; set.isComplete = true; set.type = .working
                    row.sets = [set]; session.exercises = [row]
                }
                sw.strength = session; context.insert(sw)
            } else {
                let run = Workout(); run.type = .run; run.startedAt = start
                let dist = 5000 + (5 - week) * 400 + Double((daysAgo * 137) % 1200)
                let pace = 290 + week * 9   // an improving athlete: older runs slower, recent faster
                run.durationS = dist / 1000 * pace
                let gps = GPSDetail(); gps.distanceM = dist; gps.elevationGainM = 30 + Double(daysAgo % 5) * 8
                gps.avgPaceSPerKm = pace
                gps.samples = loopSamples(start: start)   // every run gets a route to draw
                run.gps = gps; context.insert(run)
            }
        }
        try? context.save()

        // Render a real route snapshot for today's run so the Strava-style image is visible.
        if let todayGPS = ((try? context.fetch(FetchDescriptor<Workout>())) ?? [])
            .first(where: { $0.type == .run && !($0.gps?.samples.isEmpty ?? true) })?.gps {
            let coords = todayGPS.samples.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            Task { @MainActor in
                if let data = await RouteSnapshotter.snapshot(coordinates: coords) {
                    todayGPS.mapSnapshotData = data
                    try? context.save()
                }
            }
        }
    }

    /// ~24 samples tracing a rough loop near downtown Austin for a believable route.
    private static func loopSamples(start: Date) -> [LocationSample] {
        let centerLat = 30.2672, centerLon = -97.7431, r = 0.004
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
