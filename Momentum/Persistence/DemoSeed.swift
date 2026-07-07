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

        // A small demo lift library with real muscle mapping, so strength posts light the body map
        // (chest/back/legs/shoulders) instead of falling back to a glyph.
        let lifts = demoLifts()
        lifts.forEach(context.insert)

        // ~5 weeks of history with a gently building trend, so Progress charts + ACWR populate.
        var runIndex = 0
        for daysAgo in [0, 2, 4, 7, 9, 11, 14, 16, 18, 21, 24, 26, 30, 33] {
            let start = Date().addingTimeInterval(Double(-daysAgo) * 86_400 - 3 * 3600)
            let week = Double(daysAgo) / 7
            if daysAgo % 4 == 0 {
                let sw = Workout(); sw.type = .strength; sw.startedAt = start
                sw.durationS = 2700 + Double(14 - daysAgo) * 20
                sw.strength = strengthSession(lifts: lifts, week: week)
                context.insert(sw)
            } else {
                let run = Workout(); run.type = .run; run.startedAt = start
                let dist = 5000 + (5 - week) * 400 + Double((daysAgo * 137) % 1200)
                let pace = 290 + week * 9   // an improving athlete: older runs slower, recent faster
                run.durationS = dist / 1000 * pace
                let gps = GPSDetail(); gps.distanceM = dist; gps.elevationGainM = 30 + Double(daysAgo % 5) * 8
                gps.avgPaceSPerKm = pace
                gps.samples = loopSamples(start: start, variant: runIndex)   // a distinct route per run
                run.gps = gps; context.insert(run)
                runIndex += 1
            }
        }
        // Give the most recent run a guided-session rep breakdown so the summary's Reps section shows.
        if let recent = ((try? context.fetch(FetchDescriptor<Workout>())) ?? [])
            .filter({ $0.type == .run && $0.gps != nil })
            .sorted(by: { $0.startedAt > $1.startedAt }).first, let gps = recent.gps {
            let achieved: [Double] = [296, 302, 291, 315, 305, 288]   // 6×400 @ 5K pace (300); one slow rep
            let reps = achieved.enumerated().map { i, a in
                RepResult(repIndex: i + 1, repTotal: achieved.count, title: nil, targetPaceSPerKm: 300,
                          achievedPaceSPerKm: a, distanceM: 400, durationS: a * 0.4)
            }
            gps.structuredRepsData = try? JSONEncoder().encode(reps)
            // Link a prescribed session so the post-run read names it ("your speed session done ✓").
            let ps = PlannedSession()
            ps.discipline = .running; ps.runType = .intervals; ps.date = recent.startedAt
            ps.status = .completed; ps.intervals = "6×400m @ 5K"
            context.insert(ps); recent.plannedSession = ps
        }
        try? context.save()

        // Render a real Mapbox route snapshot for every run so each grid tile shows the actual map +
        // route (the production path — real runs snapshot on finish). Sequential to be gentle on the GPU.
        let runs = ((try? context.fetch(FetchDescriptor<Workout>())) ?? [])
            .filter { $0.type == .run && !($0.gps?.samples.isEmpty ?? true) }
        Task { @MainActor in
            for run in runs {
                guard let gps = run.gps else { continue }
                let coords = gps.samples.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                if let data = await RouteSnapshotter.snapshot(coordinates: coords) {
                    gps.mapSnapshotData = data
                    try? context.save()
                }
            }
        }
    }

    // MARK: Strength

    /// Four compound lifts spanning the body so the muscle map reads as a full-body session.
    private static func demoLifts() -> [Exercise] {
        [
            Exercise(name: "Barbell Bench Press", primaryMuscles: [.chest], secondaryMuscles: [.triceps, .shoulders],
                     equipment: .barbell, category: .compound),
            Exercise(name: "Barbell Row", primaryMuscles: [.back], secondaryMuscles: [.biceps],
                     equipment: .barbell, category: .compound),
            Exercise(name: "Back Squat", primaryMuscles: [.quads, .glutes], secondaryMuscles: [.hamstrings],
                     equipment: .barbell, category: .compound),
            Exercise(name: "Overhead Press", primaryMuscles: [.shoulders], secondaryMuscles: [.triceps],
                     equipment: .barbell, category: .compound),
        ]
    }

    private static func strengthSession(lifts: [Exercise], week: Double) -> StrengthSession {
        let session = StrengthSession()
        var volume = 0.0, sets = 0
        for lift in lifts {
            let row = WorkoutExercise(); row.exercise = lift
            let base = 60 + (5 - week) * 2                     // heavier as the athlete builds
            let entries = (0..<4).map { _ -> SetEntry in
                let s = SetEntry(); s.weightKg = base; s.reps = 6; s.isComplete = true; s.type = .working
                volume += base * 6; sets += 1
                return s
            }
            row.sets = entries
            session.exercises.append(row)
        }
        session.totalVolumeKg = volume
        session.totalSets = sets
        return session
    }

    // MARK: Routes

    /// A distinct 2-lap loop (shape + location vary by `variant`) with realistic per-sample speed and
    /// rolling altitude, so the post-run pace/elevation/splits charts have believable data to draw.
    private static func loopSamples(start: Date, variant: Int) -> [LocationSample] {
        // Scatter each run around a different Austin neighbourhood so the maps look different.
        let centers = [(30.2672, -97.7431), (30.2849, -97.7341), (30.2530, -97.7594),
                       (30.2711, -97.7539), (30.2456, -97.7688)]
        let (centerLat, centerLon) = centers[variant % centers.count]
        let r = 0.0032 + Double(variant % 3) * 0.0008        // vary the size
        let squash = 1.15 + Double(variant % 4) * 0.18       // vary the aspect so no two are identical
        let wobble = 0.00035                                  // gentle irregularity → not a perfect circle
        let laps = 2, perLap = 44, n = laps * perLap
        var out: [LocationSample] = []
        var elapsed = 0.0
        var prevLat = 0.0, prevLon = 0.0
        for i in 0..<n {
            let a = Double(i) / Double(perLap) * 2 * .pi
            let lat = centerLat + r * sin(a) + wobble * sin(a * 3 + Double(variant))
            let lon = centerLon + r * cos(a) * squash + wobble * cos(a * 2)
            // Cruise ~3.1 m/s (≈5:22/km) with rolling variation + a surge each lap.
            let speed = 3.1 + 0.5 * sin(a * 2 + Double(variant)) + 0.25 * sin(a * 5)
            if i > 0 { elapsed += Geo.distance(lat1: prevLat, lon1: prevLon, lat2: lat, lon2: lon) / max(1.5, speed) }
            let s = LocationSample()
            s.t = start.addingTimeInterval(elapsed)
            s.lat = lat; s.lon = lon
            s.speedMS = speed
            s.altitudeM = 150 + 20 * sin(a) + 7 * cos(a * 3 + Double(variant))   // rolling hills
            s.accuracyM = 6
            s.accepted = true
            out.append(s)
            prevLat = lat; prevLon = lon
        }
        return out
    }
}
#endif
