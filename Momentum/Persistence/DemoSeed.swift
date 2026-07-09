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
        profile.maxHR = 190          // what onboarding's Tanaka estimate would set — enables HR zones
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
                gps.hrSamples = hrTrace(start: start, durationS: run.durationS, variant: runIndex)
                gps.avgHR = RunSignals.mean(gps.hrSamples.map(\.bpm))
                // Every third run is a "guided" interval session with recorded step results, so the
                // Pace Insights card renders in history (verdict varies by variant).
                if runIndex % 3 == 0 {
                    gps.stepResultsData = try? JSONEncoder().encode(stepResults(variant: runIndex, pace: pace))
                }
                run.gps = gps; context.insert(run)
                runIndex += 1
            }
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

    /// Recorded step results for a seeded "guided" 5×400 m interval run — achieved paces scatter
    /// around the target so Pace Insights has something honest to say (variant shifts the story:
    /// on-point / ahead / ran-hot).
    private static func stepResults(variant: Int, pace: Double) -> [StepResult] {
        let target = pace - 60                                   // interval pace, faster than avg run pace
        let bias = [0.0, -14.0, 16.0][variant % 3]               // on point / ahead / review
        var out = [StepResult(kind: "warmup", targetPaceSPerKm: target + 80, toleranceSPerKm: 12,
                              repIndex: nil, repTotal: nil, distanceM: 1000,
                              durationS: (target + 85) / 1000 * 1000, skipped: false)]
        for i in 1...5 {
            let achieved = target + bias + Double((i * 7) % 11) - 5   // deterministic scatter
            out.append(StepResult(kind: "work", targetPaceSPerKm: target, toleranceSPerKm: 12,
                                  repIndex: i, repTotal: 5, distanceM: 400,
                                  durationS: achieved * 0.4, skipped: false))
            if i < 5 {
                out.append(StepResult(kind: "recovery", targetPaceSPerKm: nil, toleranceSPerKm: 12,
                                      repIndex: nil, repTotal: nil, distanceM: 180, durationS: 90, skipped: false))
            }
        }
        out.append(StepResult(kind: "cooldown", targetPaceSPerKm: target + 80, toleranceSPerKm: 12,
                              repIndex: nil, repTotal: nil, distanceM: 1000,
                              durationS: (target + 85) / 1000 * 1000, skipped: false))
        return out
    }

    /// A believable HR trace for a seeded run — a ~2 min warm-up ramp into a steady aerobic effort
    /// with a slow wander, one reading every 5 s — so the HR line + zone distribution render (R2/R3).
    private static func hrTrace(start: Date, durationS: Double, variant: Int) -> [HeartRateSample] {
        let steady = 148.0 + Double(variant % 4) * 5     // effort varies run to run
        var out: [HeartRateSample] = []
        var t = 0.0
        while t <= durationS {
            let ramp = min(1.0, t / 120)
            let bpm = 95 + (steady - 95) * ramp + 5 * sin(t / 47 + Double(variant)) + 2 * sin(t / 9)
            let s = HeartRateSample()
            s.t = start.addingTimeInterval(t)
            s.bpm = Int(bpm.rounded())
            out.append(s)
            t += 5
        }
        return out
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

    /// Plant an interrupted (still-recording) run so the cold-launch recovery prompt can be exercised
    /// by hand: a durable partial workout + the recovery marker, exactly as a force-quit would leave.
    /// Launch with `--seed-demo --seed-interrupted-run` (demo seeds the profile so Today renders).
    static func seedInterruptedIfRequested(_ context: ModelContext) {
        guard ProcessInfo.processInfo.arguments.contains("--seed-interrupted-run"),
              ActiveWorkoutMarker.pendingID == nil else { return }
        let start = Date().addingTimeInterval(-18 * 60 - 42)
        let w = Workout(); w.type = .run; w.startedAt = start
        w.durationS = 18 * 60 + 42          // 18:42 of moving time banked before the crash
        let gps = GPSDetail()
        gps.samples = loopSamples(start: start, variant: 0)
        gps.distanceM = 3720                // ~2.31 mi, as the last checkpoint would have stored
        gps.elevationGainM = 44
        w.gps = gps
        context.insert(w)
        try? context.save()
        ActiveWorkoutMarker.set(w.id)
    }
}
#endif
