#if DEBUG
import Foundation
import SwiftData
import CoreLocation

/// DEBUG-only sample data for visual iteration. Runs **only** when launched with `--seed-demo`
/// and the store has no profile yet. Never ships behavior in release builds.
@MainActor
enum DemoSeed {
    static func seedIfRequested(_ context: ModelContext) {
        // --reset-fuel: hermetic FuelFlow UI tests — start with an empty meal journal.
        if ProcessInfo.processInfo.arguments.contains("--reset-fuel") {
            for meal in (try? context.fetch(FetchDescriptor<Meal>())) ?? [] { context.delete(meal) }
            try? context.save()
        }
        seedInterruptedWorkoutIfRequested(context)
        // --seed-empty: a genuine JUST-ONBOARDED user — a profile + a generated plan and NOTHING else
        // (zero workouts, PRs, notifications, coaching history), so the true new-user empty slate can be
        // screenshotted deterministically without driving the onboarding UI. DEBUG-only, like the rest.
        if ProcessInfo.processInfo.arguments.contains("--seed-empty") { seedEmptyProfile(context); return }
        guard ProcessInfo.processInfo.arguments.contains("--seed-demo") else { return }
        let existing = (try? context.fetch(FetchDescriptor<UserProfile>())) ?? []
        guard existing.isEmpty else { return }

        let profile = UserProfile()
        profile.displayName = "Alex Rivera"
        profile.handle = "alexrivera"   // display name and @handle are distinct (username vs name)
        profile.publicRouteMaps = true  // DEBUG demo shares (fuzzed) routes so feed posts show the run's map
        profile.disciplines = ["running", "strength"]
        profile.goal = .buildMuscle
        profile.daysPerWeek = 4
        profile.experience = ["running": "some", "strength": "some"]
        profile.weightUnit = WeightUnit.default().rawValue   // locale display units (lb in US/UK)
        profile.maxHR = 188                                  // HR zones (Karvonen) render personalized
        profile.restingHR = 52
        // Alex Rivera's profile photo — the same portrait everywhere (Today header avatar + Profile).
        if let url = Bundle.main.url(forResource: "demo-avatar", withExtension: "jpg"),
           let data = try? Data(contentsOf: url) {
            profile.avatarData = data
        }
        context.insert(profile)
        // --seed-race-plan: a dated half-marathon race THIS week (2 days out) — the race-day
        // session, shakeout, and taper phases all render on the current week's Plan board.
        if ProcessInfo.processInfo.arguments.contains("--seed-race-plan") {
            profile.goal = .raceDistance
            profile.raceDistanceM = RaceDistance.half.meters
            profile.raceDate = Calendar.current.date(byAdding: .day, value: 2, to: Date())
            profile.goalFinishTimeS = 5_400   // chasing 1:30
        }
        PlanService.regenerate(for: profile, in: context)
        // --plan-renewal: regenerate the rolling block starting ~6 weeks back so "today" lands at the
        // end of the block, surfacing the Plan page's block-renewal checkpoint card for verification.
        if ProcessInfo.processInfo.arguments.contains("--plan-renewal"),
           let back = Calendar.current.date(byAdding: .weekOfYear, value: -6, to: Date()) {
            PlanService.regenerate(for: profile, startDate: back, in: context)
        }
        // --seed-plan-name: exercise the named-plan experience (Plan title + Today's banner eyebrow).
        if ProcessInfo.processInfo.arguments.contains("--seed-plan-name") {
            profile.plan?.name = "Austin Marathon"
        }

        // A small demo lift library with real muscle mapping, so strength posts light the body map
        // (chest/back/legs/shoulders) instead of falling back to a glyph.
        let lifts = demoLifts()
        lifts.forEach(context.insert)

        // --marketing-profile: seed a full, established athlete (hundreds of real-route posts, a deep
        // lifetime, dense consistency) for the website's Profile screenshot — the "full account" look.
        // Follower/Following counts are overridden marketing-only in ProfileScreen (the shipping app
        // never fabricates an audience). Everything else here is a genuine, coherent training history.
        if ProcessInfo.processInfo.arguments.contains("--marketing-profile") {
            seedMarketingProfile(context, profile: profile, lifts: lifts)
            return
        }

        // --marathon-hero: one finished Austin Marathon (the real course + finish data) for the
        // website hero's post-run summary — the "you just ran a marathon" moment (Runna-style).
        if ProcessInfo.processInfo.arguments.contains("--marathon-hero") {
            seedMarathonRun(context)
            return
        }

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
                gps.avgCadence = 182 - Int(week * 2) + (daysAgo % 3)   // steps/min — powers the cadence trend
                gps.samples = loopSamples(start: start, variant: runIndex)   // a distinct route per run
                gps.hrSamples = hrTrace(start: start, durationS: run.durationS, variant: runIndex)
                gps.avgHR = RunSignals.mean(gps.hrSamples.map(\.bpm))
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
        // A few coaching-history entries so the "How your plan adapted" timeline populates.
        let cal = Calendar.current
        let demoEvents: [(CoachingEvent.Kind, String, String, Int)] = [
            (.recalibrate, "Your paces got faster", "That tempo showed real fitness, so I sharpened your target paces by about 6 s/km. You've earned it.", 2),
            (.recover, "Banking some recovery", "Your easy run felt like an honest 8/10 — that's your body asking for rest, so your next session is now a recovery day.", 9),
            (.ease, "Eased your week", "Your recent load spiked, so I trimmed this week's volume to keep you fresh and healthy.", 16),
        ]
        for (kind, h, d, daysAgo) in demoEvents {
            let date = cal.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
            context.insert(CoachingEvent(kind: kind, headline: h, detail: d, date: date))
        }
        // A few inbox notifications so the bell has real content.
        let demoNotifs: [(AppNotification.Kind, String, String, Int)] = [
            (.reminder, "Today's session is ready", "Long run · 6.2 mi at an easy pace.", 0),
            (.streak, "3-day streak going", "Keep it alive — a session today makes it four.", 1),
            (.coaching, "Your paces got faster", "That tempo showed real fitness, so I sharpened your target paces by about 6 s/km.", 2),
            (.achievement, "New longest run", "You just logged your longest run yet. Nice work.", 4),
        ]
        for (kind, title, body, daysAgo) in demoNotifs {
            let date = cal.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
            context.insert(AppNotification(kind: kind, title: title, body: body, date: date))
        }
        try? context.save()

        // Render a real Mapbox route snapshot for every run so each grid tile shows the actual map +
        // route (the production path — real runs snapshot on finish). Sequential to be gentle on the GPU.
        let runs = ((try? context.fetch(FetchDescriptor<Workout>())) ?? [])
            .filter { $0.type == .run && !($0.gps?.samples.isEmpty ?? true) }
        Task { @MainActor in
            for run in runs {
                guard let gps = run.gps else { continue }
                // SwiftData to-many relationships come back UNORDERED on refetch — connect the dots
                // by timestamp or the snapshot draws a scribble instead of the route.
                let coords = gps.samples.sorted { $0.t < $1.t }
                    .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                // Same basemap the app renders everywhere (the persisted app-wide style) — seeded
                // tiles must look like real saves, not a mismatched light map. Portrait tile-native
                // size + the style stamped, exactly like a real save.
                // Tiles stay the light persisted basemap even in dark mode: they read as full-colour
                // "photos" on the dark profile canvas (Instagram-style), and the on-appear snapshot
                // healer renders light too — matching it avoids a half-light/half-dark grid.
                let seedStyle = MapStyleOption.persisted
                if let data = await RouteSnapshotter.snapshot(
                    coordinates: coords, size: RouteSnapshotter.workoutTileSize,
                    styleURI: seedStyle.styleURI(for: .light),
                    insets: RouteSnapshotter.workoutTileInsets) {
                    gps.mapSnapshotData = data
                    gps.mapStyleRaw = seedStyle.rawValue
                    try? context.save()
                }
            }
        }
    }

    // MARK: Marketing (full account)

    /// The website's "full, vibrant account" seed: an established marathoner with a deep body of work.
    /// The visible top of the grid is a rotation of real city street-loops (rendered Mapbox tiles);
    /// the long tail backfills the Posts count and lifetime totals with lighter route silhouettes.
    private static func seedMarketingProfile(_ context: ModelContext, profile: UserProfile, lifts: [Exercise]) {
        profile.bio = "Marathon build in full swing — chasing a sub-3 and logging every mile of it."
        profile.city = "Austin, TX"
        profile.locationGranularity = LocationGranularity.city.rawValue
        // (avatarData is set in the common seed path — same portrait everywhere.)

        let cal = Calendar.current
        func date(_ daysAgo: Double) -> Date { Date().addingTimeInterval(-daysAgo * 86_400 - 3 * 3600) }

        // Build one run post from a real city loop, repeated `laps` times for the long ones. `dense`
        // keeps full route fidelity + HR (the featured tiles we render maps for); the backfill runs
        // downsample and skip HR so seeding 200 posts stays quick.
        func addRun(city: String, laps: Int, daysAgo: Double, dense: Bool, variant: Int) {
            guard let loop = CommunityRoutes.loop(city: city, discipline: .run, nearestKm: 10) else { return }
            let laps = max(1, laps)
            let start = date(daysAgo)
            let distanceM = loop.km * 1000 * Double(laps)
            let pace = 288.0 + Double(variant % 5) * 7      // ~4:48–5:16 /km, varying run to run
            let durationS = distanceM / 1000 * pace
            let run = Workout(); run.type = .run; run.startedAt = start; run.durationS = durationS
            let gps = GPSDetail()
            gps.distanceM = distanceM
            gps.elevationGainM = 40 + Double(variant % 6) * 22 * Double(laps)
            gps.avgPaceSPerKm = pace
            gps.avgCadence = 178 + variant % 8
            gps.samples = samplesFromLoop(loop, laps: laps, start: start,
                                          durationS: durationS, speedMS: 1000 / pace, dense: dense)
            if dense {
                gps.hrSamples = hrTrace(start: start, durationS: durationS, variant: variant)
                gps.avgHR = RunSignals.mean(gps.hrSamples.map(\.bpm))
            }
            run.gps = gps
            context.insert(run)
        }

        // ── Featured, most-recent posts: real scenic street loops, a marathoner's mix of easy runs
        //    (1 lap ≈ 10 km) and long runs (2–3 laps ≈ 20–30 km). These get rendered Mapbox tiles.
        let featured: [(String, Int)] = [
            ("Austin, TX", 3), ("San Francisco, CA", 1), ("Boston, MA", 2), ("Austin, TX", 1),
            ("Vancouver", 1), ("New York, NY", 3), ("Seattle, WA", 2), ("Boulder, CO", 1),
            ("Chicago, IL", 1), ("Portland, OR", 2), ("London", 1), ("San Diego, CA", 3),
            ("Sydney", 1), ("Denver, CO", 2), ("Barcelona", 1), ("Brooklyn, NY", 1),
            ("Cape Town", 2), ("Oakland, CA", 1), ("Nashville, TN", 1), ("Miami, FL", 2),
        ]
        for (i, spec) in featured.enumerated() {
            addRun(city: spec.0, laps: spec.1, daysAgo: 1 + Double(i) * 3, dense: true, variant: i)
        }

        // A few strength sessions threaded into the recent weeks so the grid also shows iridescent
        // muscle-map tiles (strength-for-runners), not only routes.
        for (k, daysAgo) in [3.0, 10.0, 17.0].enumerated() {
            let sw = Workout(); sw.type = .strength; sw.startedAt = date(daysAgo + 0.4)
            sw.durationS = 2_700 + Double(k) * 240
            sw.strength = strengthSession(lifts: lifts, week: Double(k))
            context.insert(sw)
        }

        // ── Backfill: ~185 older posts across many cities to make Posts, lifetime distance, and the
        //    consistency grid read as a real ~16-month history. Light routes (no HR, no map render).
        let cities = ["Austin, TX", "Denver, CO", "Boulder, CO", "San Diego, CA", "Portland, OR",
                      "Seattle, WA", "Chicago, IL", "New York, NY", "Boston, MA", "San Francisco, CA",
                      "Nashville, TN", "Atlanta, GA", "Miami, FL", "Dallas, TX", "Houston, TX",
                      "Philadelphia, PA", "Washington, DC", "Brooklyn, NY", "Oakland, CA", "Phoenix, AZ",
                      "Salt Lake City, UT", "Minneapolis, MN", "Charlotte, NC", "Raleigh, NC", "Richmond, VA"]
        var rng = SeededRNG(7)
        for j in 0..<185 {
            let city = cities[j % cities.count]
            // Mostly single-loop training runs; a weekly long run of 2–3 laps.
            let laps = (j % 7 == 0) ? rng.int(2...3) : 1
            let daysAgo = 60 + Double(j) * 2.25 + rng.double(-0.6, 0.6)
            addRun(city: city, laps: laps, daysAgo: daysAgo, dense: false, variant: j)
        }

        // A couple of inbox notifications + coaching history so the rest of the app looks lived-in too.
        let notifs: [(AppNotification.Kind, String, String, Int)] = [
            (.achievement, "New longest run", "You just logged your longest run yet — 32.1 km. Huge.", 0),
            (.streak, "18-week streak", "You've trained every week since your build began. Incredible.", 1),
            (.coaching, "Your paces got faster", "That tempo showed real fitness, so I sharpened your targets by ~6 s/km.", 2),
        ]
        for (kind, title, body, daysAgo) in notifs {
            context.insert(AppNotification(kind: kind, title: title, body: body,
                                           date: cal.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()))
        }
        try? context.save()

        // Render real Mapbox tiles for just the most-recent runs (the visible grid) — snapshotting all
        // ~200 would be needlessly slow; the rest ride the drawn silhouette + the on-appear healer.
        let recent = ((try? context.fetch(FetchDescriptor<Workout>())) ?? [])
            .filter { $0.type == .run && !($0.gps?.samples.isEmpty ?? true) }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(22)
        Task { @MainActor in
            for run in recent {
                guard let gps = run.gps else { continue }
                let coords = gps.samples.sorted { $0.t < $1.t }
                    .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                // Tiles stay the light persisted basemap even in dark mode: they read as full-colour
                // "photos" on the dark profile canvas (Instagram-style), and the on-appear snapshot
                // healer renders light too — matching it avoids a half-light/half-dark grid.
                let seedStyle = MapStyleOption.persisted
                if let data = await RouteSnapshotter.snapshot(
                    coordinates: coords, size: RouteSnapshotter.workoutTileSize,
                    styleURI: seedStyle.styleURI(for: .light),
                    insets: RouteSnapshotter.workoutTileInsets) {
                    gps.mapSnapshotData = data
                    gps.mapStyleRaw = seedStyle.rawValue
                    try? context.save()
                }
            }
        }
    }

    /// Map a real bundled loop (repeated `laps` times for long runs) into timed `LocationSample`s.
    /// `dense: false` downsamples to ~24 points — enough for a route silhouette, cheap to seed en masse.
    private static func samplesFromLoop(_ loop: CommunityRoutes.Loop, laps: Int, start: Date,
                                        durationS: Double, speedMS: Double, dense: Bool) -> [LocationSample] {
        var pts: [[Double]] = []
        for _ in 0..<max(1, laps) { pts.append(contentsOf: loop.pts) }
        if !dense, pts.count > 24 {
            let step = pts.count / 24
            pts = stride(from: 0, to: pts.count, by: max(1, step)).map { pts[$0] }
        }
        guard pts.count > 1 else { return [] }
        var out: [LocationSample] = []
        let last = Double(pts.count - 1)
        for (i, p) in pts.enumerated() where p.count >= 2 {
            let s = LocationSample()
            s.t = start.addingTimeInterval(durationS * Double(i) / last)
            s.lat = p[0]; s.lon = p[1]
            s.speedMS = speedMS
            s.altitudeM = 150
            s.accuracyM = 6
            s.accepted = true
            out.append(s)
        }
        return out
    }

    // MARK: Marathon (post-run hero)

    /// One completed Austin Marathon — the real bundled course as the GPS trace, with a sub-3 finish
    /// so the post-run summary reads a genuine 26.2 mi race (route map + distance/time/pace/HR).
    private static func seedMarathonRun(_ context: ModelContext) {
        guard let url = Bundle.main.url(forResource: "austin-marathon", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONDecoder().decode([String: [[Double]]].self, from: data),
              let pts = obj["pts"], pts.count > 1 else { return }
        let start = Date().addingTimeInterval(-4 * 3600)      // finished this morning
        let durationS = 10_721.0                              // 2:58:41 (sub-3)
        let distanceM = 42_195.0                              // 26.2 mi
        let run = Workout(); run.type = .run; run.startedAt = start; run.durationS = durationS
        let gps = GPSDetail()
        gps.distanceM = distanceM
        gps.elevationGainM = 178
        gps.avgPaceSPerKm = durationS / (distanceM / 1000)    // ~4:14 /km ≈ 6:49 /mi
        gps.avgCadence = 183
        let speed = distanceM / durationS                     // ~3.94 m/s
        let last = Double(pts.count - 1)
        gps.samples = pts.enumerated().compactMap { i, p in
            guard p.count >= 2 else { return nil }
            let s = LocationSample()
            s.t = start.addingTimeInterval(durationS * Double(i) / last)
            s.lat = p[0]; s.lon = p[1]
            s.speedMS = speed
            s.altitudeM = 150 + 30 * sin(Double(i) / 9)       // rolling Austin hills
            s.accuracyM = 5
            s.accepted = true
            return s
        }
        gps.hrSamples = hrTrace(start: start, durationS: durationS, variant: 1)
        gps.avgHR = RunSignals.mean(gps.hrSamples.map(\.bpm))
        gps.mapStyleRaw = MapStyleOption.dark.rawValue        // route map on the flat dark basemap
        run.gps = gps
        context.insert(run)
        try? context.save()
    }

    // MARK: Strength

    /// Four compound lifts spanning the body so the muscle map reads as a full-body session.
    /// `--recovery-demo`: simulate a run the app died in the middle of — a half-loop of samples,
    /// checkpointed aggregates, and the live marker still set — so the cold-launch "unfinished
    /// workout found" prompt can be exercised on the simulator without killing a live recording.
    private static func seedInterruptedWorkoutIfRequested(_ context: ModelContext) {
        guard ProcessInfo.processInfo.arguments.contains("--recovery-demo"),
              ActiveWorkoutMarker.pendingID == nil else { return }
        let start = Date().addingTimeInterval(-40 * 60)
        let w = Workout()
        w.type = .run
        w.startedAt = start
        w.durationS = 22 * 60                                  // the last 5s checkpoint that stuck
        let gps = GPSDetail()
        gps.distanceM = 4_200
        gps.avgPaceSPerKm = (22 * 60) / 4.2
        gps.samples = loopSamples(start: start, variant: 2)
        w.gps = gps
        context.insert(w)
        try? context.save()
        ActiveWorkoutMarker.set(w.id)
    }

    /// The minimal state of a user who JUST finished onboarding: a profile they filled in + the plan the
    /// engine generated from it, and nothing else. No workouts, PRs, notifications, or coaching history —
    /// so every screen renders its true empty state. Mirrors what `OnboardingViewModel.finish()` produces
    /// in release (profile + `PlanService.regenerate`), minus the AI memory notes/coach hello.
    private static func seedEmptyProfile(_ context: ModelContext) {
        guard ((try? context.fetch(FetchDescriptor<UserProfile>())) ?? []).isEmpty else { return }
        let profile = UserProfile()
        profile.displayName = "Sam Rivera"      // a name the user typed — not fabricated history
        profile.handle = "samrivera"
        profile.disciplines = ["running"]
        profile.goal = .generalFitness
        profile.daysPerWeek = 4
        profile.experience = ["running": "some"]
        profile.weightUnit = WeightUnit.default().rawValue
        context.insert(profile)
        PlanService.regenerate(for: profile, in: context)   // prescriptions only, all dated from today
        try? context.save()
    }

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
            // Per-lift strength ratios so the athlete's numbers look real (squat > bench > row > OHP),
            // scaled by a gently-building base.
            let ratio: Double = {
                switch lift.name {
                case "Back Squat": 1.6
                case "Barbell Bench Press": 1.05
                case "Barbell Row": 0.95
                case "Overhead Press": 0.62
                default: 1.0
                }
            }()
            let base = (60 + (5 - week) * 2) * ratio           // heavier as the athlete builds
            let entries = (0..<4).map { _ -> SetEntry in
                let s = SetEntry(); s.weightKg = (base / 2.5).rounded() * 2.5; s.reps = 6
                s.isComplete = true; s.type = .working
                volume += s.weightKg! * 6; sets += 1
                return s
            }
            row.sets = entries
            session.exercises.append(row)
        }
        session.totalVolumeKg = volume
        session.totalSets = sets
        return session
    }

    /// A believable HR trace for a seeded run — a ~2 min warm-up ramp into a steady aerobic effort
    /// with a slow wander, one reading every 5 s — so the HR chart + time-in-zones render from local
    /// data exactly like a live-captured run (R3).
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
}
#endif
