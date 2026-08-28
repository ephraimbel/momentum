#if DEBUG
import Foundation
import SwiftData
import CoreLocation
import UIKit

/// DEBUG-only sample data for visual iteration. Runs **only** when launched with `--seed-demo`
/// and the store has no profile yet. Never ships behavior in release builds.
@MainActor
enum DemoSeed {
    /// ~4 months of journal days (roughly 5 of every 7), 1–3 meals each, from a small table of
    /// plausible athlete foods with full macro + micro numbers. Deterministic (seeded RNG) so
    /// History screenshots and manual browsing are repeatable. Skips if history already exists.
    private static func seedFuelHistory(_ context: ModelContext) {
        let existing = (try? context.fetchCount(FetchDescriptor<Meal>())) ?? 0
        guard existing < 10 else { return }
        // (text, kcal, carbs, protein, fat, sodium, K, Mg, Fe, Ca, fiber, sugar, satFat, nova)
        // NOVA rides along (2026-08-20) so seeded history behaves like LIVE history — the
        // estimator always itemizes with a processing class, and the Nutrition page's
        // processed-share section gates on NOVA being sampled at all.
        let foods: [(String, Int, Int, Int, Int, Int, Int, Int, Double, Int, Int, Int, Int, Int)] = [
            ("oatmeal with banana and honey", 420, 82, 10, 6, 120, 620, 90, 2.1, 80, 7, 28, 2, 1),
            ("2 eggs, toast, coffee", 350, 28, 18, 16, 480, 320, 40, 2.4, 90, 2, 3, 6, 3),
            ("chicken rice bowl", 620, 78, 42, 12, 740, 680, 70, 2.2, 60, 4, 4, 3, 1),
            ("big pasta dinner with chicken", 740, 96, 48, 14, 620, 720, 85, 3.4, 90, 6, 8, 4, 3),
            ("greek yogurt with granola", 380, 46, 22, 10, 140, 420, 55, 1.2, 260, 4, 18, 4, 3),
            ("turkey sandwich and a banana", 460, 58, 26, 9, 920, 760, 65, 2.6, 120, 6, 18, 3, 4),
            ("salmon, potatoes, greens", 640, 52, 40, 22, 380, 1240, 110, 2.0, 120, 7, 4, 5, 1),
            ("2 gels and a sports drink", 320, 74, 0, 0, 460, 140, 10, 0.2, 20, 0, 56, 0, 4),
            ("burrito with rice and beans", 780, 92, 30, 26, 1150, 830, 95, 4.2, 240, 12, 6, 9, 3),
            ("smoothie with berries and whey", 340, 44, 28, 5, 160, 540, 60, 1.4, 220, 6, 28, 1, 3),
            ("steak, sweet potato, broccoli", 690, 46, 48, 24, 420, 1180, 105, 4.6, 90, 8, 9, 8, 1),
            ("pancakes with maple syrup", 560, 94, 12, 12, 520, 280, 35, 2.2, 180, 2, 42, 5, 3),
        ]
        var rng = SeededRNG(20260716)
        let cal = Calendar.current
        for back in 1...120 {
            guard rng.int(0...6) < 5 else { continue }   // ~5 of 7 days logged
            guard let day = cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: Date())) else { continue }
            // 2–4 meals a logged day (was 1–3): the old draw averaged ~1,100 kcal/day, which
            // made every trend surface read like chronic under-fueling — real logged days
            // carry breakfast + lunch + dinner (nutrition-report pass 2026-08-20).
            for slot in 0..<(2 + rng.int(0...2)) {
                let f = foods[rng.int(0...(foods.count - 1))]
                let meal = Meal()
                meal.text = f.0
                meal.eatenAt = day.addingTimeInterval(Double(8 + slot * 5) * 3600 + Double(rng.int(0...50)) * 60)
                // One itemized entry per meal (the live estimator always itemizes) — the items
                // setter recomputes the scalar totals from the item, so numbers stay identical.
                meal.items = [MealItem(name: f.0, qty: 1, unit: "serving", kcal: f.1,
                                       carbsG: f.2, proteinG: f.3, fatG: f.4, sodiumMg: f.5,
                                       fluidsMl: 0, potassiumMg: f.6, magnesiumMg: f.7,
                                       ironMg: f.8, calciumMg: f.9, fiberG: f.10, sugarG: f.11,
                                       satFatG: f.12, nova: f.13)]
                meal.source = "ai"
                meal.confidence = 0.8
                context.insert(meal)
            }
        }
        try? context.save()
    }

    /// The screenshot-hero fueling day: staggered real-feel meals whose totals clear every floor
    /// (carbs ≈390 g, protein ≈138 g, fat ≈88 g, sodium ≈2,590 mg, ≈3,050 kcal) so the whole ring
    /// row earns its iridescence. DEBUG-only, like everything here.
    private static func seedFuelToday(_ context: ModelContext) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let existingToday = ((try? context.fetch(FetchDescriptor<Meal>())) ?? [])
            .filter { cal.isDateInToday($0.eatenAt) }
        guard existingToday.count < 2 else { return }
        // (hour, minute, text, kcal, carbs, protein, fat, sodium, fiber, sugar, satFat, fluids, nova, note?)
        // Itemized like live estimates (2026-08-20) — the detail sheet opens in items mode with
        // steppers + the add-an-item lane, exactly what a real logged day gives.
        let day: [(Double, Double, String, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, String?)] = [
            (7, 40, "oatmeal with banana, honey and coffee", 520, 92, 14, 9, 190, 7, 34, 2, 240, 1,
             "Strong carb start — this is the fuel today's session runs on."),
            (10, 15, "greek yogurt with berries and granola", 420, 52, 24, 11, 150, 5, 22, 3, 0, 3, nil),
            (12, 45, "chicken burrito bowl with rice and beans", 780, 88, 46, 22, 1150, 12, 6, 8, 400, 1,
             "Great mixed plate — carbs restocked, protein covered."),
            (15, 30, "2 gels and a sports drink", 320, 74, 0, 0, 460, 0, 56, 0, 500, 4, nil),
            (18, 50, "salmon, potatoes and greens with olive oil", 690, 54, 42, 28, 480, 7, 4, 6, 350, 1,
             "Recovery-forward dinner — protein and healthy fats where they count."),
            (20, 30, "dark chocolate and a glass of milk", 320, 30, 12, 18, 160, 3, 24, 10, 250, 3, nil),
        ]
        for m in day where m.0 <= Double(cal.component(.hour, from: Date())) || true {
            let meal = Meal()
            meal.text = m.2
            meal.eatenAt = start.addingTimeInterval(m.0 * 3600 + m.1 * 60)
            meal.items = [MealItem(name: m.2, qty: 1, unit: "serving", kcal: m.3,
                                   carbsG: m.4, proteinG: m.5, fatG: m.6, sodiumMg: m.7,
                                   fluidsMl: m.11, fiberG: m.8, sugarG: m.9, satFatG: m.10,
                                   nova: m.12)]
            meal.note = m.13
            meal.source = "ai"
            meal.confidence = 0.85
            context.insert(meal)
        }
        try? context.save()
    }

    static func seedIfRequested(_ context: ModelContext) {
        // --reset-store: empty the local store before seeding, so a launch gets the SAME container
        // a fresh install would.
        //
        // The UI suite has no isolation: XCUITest relaunches the app per test but the container
        // persists across a whole batch, and `--seed-demo` below bails the moment a profile exists
        // (`guard existing.isEmpty`). So every test after the first inherits whatever the previous
        // one left behind — and some of them mutate persisted state deliberately (the Settings units
        // test switches the athlete to Km/Kg, the sport picker switches them to Swim). Four suites
        // that pass individually failed in a 20-suite batch for exactly this reason, which is also
        // how a run-detail section that rendered nothing at all survived weeks of green runs.
        //
        // Ordered children-first so no delete strands a dangling reference mid-pass.
        if ProcessInfo.processInfo.arguments.contains("--reset-store") {
            try? context.delete(model: SetEntry.self);           try? context.delete(model: WorkoutExercise.self)
            try? context.delete(model: StrengthSession.self);    try? context.delete(model: LocationSample.self)
            try? context.delete(model: HeartRateSample.self);    try? context.delete(model: Split.self)
            try? context.delete(model: GPSDetail.self);          try? context.delete(model: WorkoutPhoto.self)
            try? context.delete(model: Workout.self);            try? context.delete(model: PlannedExercise.self)
            try? context.delete(model: PlannedSession.self);     try? context.delete(model: TrainingPlan.self)
            try? context.delete(model: MemoryNote.self);         try? context.delete(model: FitnessSnapshot.self)
            try? context.delete(model: AthleteModel.self);       try? context.delete(model: PersonalRecord.self)
            try? context.delete(model: EarnedAward.self);        try? context.delete(model: ChatMessage.self)
            try? context.delete(model: CoachingEvent.self);      try? context.delete(model: AppNotification.self)
            try? context.delete(model: DailyCheckin.self);       try? context.delete(model: Meal.self)
            try? context.delete(model: UserProfile.self)
            // NOT `Exercise`. The library is shared reference data, seeded by
            // `ExerciseLibrarySeed.seedIfNeeded` in `PersistenceController.init` — which already ran
            // for THIS launch by the time we get here, and won't run again. Deleting it left the app
            // with an empty exercise catalog and no way back, which is worse than the staleness this
            // whole reset exists to remove.
            try? context.save()
            // One-shot migrations gate on UserDefaults, not on the store, so wiping the rows alone
            // leaves them believing they already ran: the record book came back permanently empty
            // because `RecordsBook.backfillIfNeeded` had ticked its v4 flag on a previous launch.
            // A reset that only clears half the state is a worse lie than no reset at all.
            UserDefaults.standard.removeObject(forKey: "com.momentum.records.backfill.v4")
        }
        // --reset-fuel: hermetic FuelFlow UI tests — start with an empty meal journal.
        if ProcessInfo.processInfo.arguments.contains("--reset-fuel") {
            for meal in (try? context.fetch(FetchDescriptor<Meal>())) ?? [] { context.delete(meal) }
            try? context.save()
        }
        // --seed-fuel-history: months of plausible journal days (deterministic) so the History
        // page's month grouping + search can be exercised and screenshotted at real scale.
        if ProcessInfo.processInfo.arguments.contains("--seed-fuel-history") {
            seedFuelHistory(context)
        }
        // --seed-fuel-today: a curated FULL day (every floor met → every ring iridescent) for
        // the hero Fuel screenshot. Idempotent: skips if today already has meals.
        if ProcessInfo.processInfo.arguments.contains("--seed-fuel-today") {
            seedFuelToday(context)
        }
        // --seed-plan-name on an ALREADY-seeded container: name the existing plan too, so UI
        // tests get the named-plan experience regardless of which test seeded the store first.
        if ProcessInfo.processInfo.arguments.contains("--seed-plan-name"),
           let plan = try? context.fetch(FetchDescriptor<TrainingPlan>()).first, plan.name.isEmpty {
            plan.name = "Austin Marathon"
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
        // A filled-in location, so the "@handle · City" byline line renders on every surface that
        // draws it (own post pager, profile identity). Real athletes type this in Edit Profile;
        // typing it IS the opt-in, which is why the granularity moves with it.
        profile.city = "Austin, TX"
        profile.locationGranularity = LocationGranularity.city.rawValue
        // --seed-female: render the demo athlete as female (the true female anatomy figure) — a
        // deterministic path to verify the figure on every body surface.
        if ProcessInfo.processInfo.arguments.contains("--seed-female") { profile.sex = "female" }
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
            // --no-avatar: leave the seeded athlete photo-less so the monogram default and the
            // route-avatar offer are verifiable on the sim (the portrait otherwise wins everywhere).
            if !ProcessInfo.processInfo.arguments.contains("--no-avatar") {
                profile.avatarData = data
            }
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
        // --seed-plan-5day: the committed 5-day athlete — experienced, aggressive, 50 km/wk, half
        // marathon ~7 weeks out, with generation backdated 5 weeks so "this week" lands mid-BUILD.
        // The plan-texture showcase: the two-quality week (threshold cruise + VO₂ touch), the
        // medium-long/recovery-jog fill texture, and the plateau'd long-run wave all render on the
        // current week's board without any week-hopping.
        if ProcessInfo.processInfo.arguments.contains("--seed-plan-5day") {
            profile.disciplines = ["running"]
            profile.goal = .raceDistance
            profile.daysPerWeek = 5
            profile.experience = ["running": "experienced"]
            profile.planIntensity = PlanIntensity.aggressive.rawValue
            profile.weeklyRunVolumeM = 50_000
            profile.longestRunM = 16_000
            profile.raceDistanceM = RaceDistance.half.meters
            profile.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 7, to: Date())
        }
        // --seed-plan-long: a marathon 28 weeks out — the >26-week plan that exercises the Plan
        // page's PAGED week arc (7 bars per swipe). The one deterministic path to a long block.
        if ProcessInfo.processInfo.arguments.contains("--seed-plan-long") {
            profile.disciplines = ["running"]
            profile.goal = .raceDistance
            profile.daysPerWeek = 5
            profile.experience = ["running": "experienced"]
            profile.weeklyRunVolumeM = 50_000
            profile.longestRunM = 16_000
            profile.raceDistanceM = RaceDistance.marathon.meters
            profile.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 28, to: Date())
        }
        // --seed-split-ppl / --seed-split-upper: the demo athlete chose a strength split — the
        // hybrid week's 2 lift days rotate through it (PPL continues its cycle ACROSS weeks), so
        // the Plan board and Today deck render "Push day"/"Upper body" sessions for verification.
        if ProcessInfo.processInfo.arguments.contains("--seed-split-ppl") {
            profile.strengthSplit = StrengthSplitStyle.pushPullLegs.rawValue
        }
        if ProcessInfo.processInfo.arguments.contains("--seed-split-upper") {
            profile.strengthSplit = StrengthSplitStyle.upperLower.rawValue
        }
        PlanService.regenerate(for: profile, in: context)
        // --plan-renewal: regenerate the rolling block starting ~6 weeks back so "today" lands at the
        // end of the block, surfacing the Plan page's block-renewal checkpoint card for verification.
        if ProcessInfo.processInfo.arguments.contains("--plan-renewal"),
           let back = Calendar.current.date(byAdding: .weekOfYear, value: -6, to: Date()) {
            PlanService.regenerate(for: profile, startDate: back, in: context)
        }
        // The 5-day showcase backdates the same plan so today sits in a build week (see above).
        if ProcessInfo.processInfo.arguments.contains("--seed-plan-5day"),
           let back = Calendar.current.date(byAdding: .weekOfYear, value: -5, to: Date()) {
            PlanService.regenerate(for: profile, startDate: back, in: context)
            profile.plan?.name = "Berlin Half"
        }
        // --seed-plan-name: exercise the named-plan experience (Plan title + Today's banner eyebrow).
        if ProcessInfo.processInfo.arguments.contains("--seed-plan-name") {
            profile.plan?.name = "Austin Marathon"
        }

        // A small demo lift library with real muscle mapping, so strength posts light the body map
        // (chest/back/legs/shoulders) instead of falling back to a glyph.
        let lifts = demoLifts(in: context)

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
            if daysAgo.isMultiple(of: 4) {
                let sw = Workout(); sw.type = .strength; sw.startedAt = start
                sw.durationS = 2700 + Double(14 - daysAgo) * 20
                sw.strength = strengthSession(lifts: lifts, week: week)
                // Today's lift is the demo athlete's public post (see the run branch note), and it
                // carries two GENERATED placeholder photos so the multi-photo carousel (pager
                // paging + "1/2" pill) is sim-verifiable. DEBUG demo only — never ships.
                if daysAgo == 0 {
                    sw.privacy = .public
                    sw.photos = demoPhotos()
                }
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
                // The demo athlete shares their freshest run: with `--community` it joins today's
                // lift as the OWN posts on the wall (Friends scope shows exactly these), proving
                // the save→feed pipeline. Invisible in solo builds — nothing reads privacy there.
                if daysAgo == 2 { run.privacy = .friends }
                run.gps = gps; context.insert(run)
                runIndex += 1
            }
        }

        // One outdoor ride threaded in, so the ride summary's discipline-specific reading (speed
        // chart + speed-valued splits, 2026-08-13) always has a seeded specimen to verify against.
        // Distance and duration derive from the samples' own geometry, so the hero number and the
        // charts (which replay the samples) can never disagree.
        // 2.5 days back — BEHIND the freshest run, so plain `--save-screen` (and every UI test on
        // it) still resolves the run; `--save-screen-ride` is the door to this one.
        do {
            let start = Date().addingTimeInterval(-2.5 * 86_400 - 2 * 3600)
            let samples = loopSamples(start: start, variant: 2, speedScale: 2.5)
            var distanceM = 0.0
            for i in 1..<samples.count {
                distanceM += Geo.distance(lat1: samples[i - 1].lat, lon1: samples[i - 1].lon,
                                          lat2: samples[i].lat, lon2: samples[i].lon)
            }
            let durationS = samples.last.map { $0.t.timeIntervalSince(start) } ?? 0
            let ride = Workout(); ride.type = .ride; ride.startedAt = start; ride.durationS = durationS
            let gps = GPSDetail()
            gps.distanceM = distanceM
            gps.elevationGainM = 120
            gps.samples = samples
            gps.hrSamples = hrTrace(start: start, durationS: durationS, variant: 4)
            gps.avgHR = RunSignals.mean(gps.hrSamples.map(\.bpm))
            gps.avgPaceSPerKm = distanceM > 0 ? durationS / (distanceM / 1000) : 0
            ride.gps = gps
            context.insert(ride)
        }

        // --seed-dense-history: pack the trailing 16 weeks (the consistency graph's exact window)
        // with light training days so the profile's Consistency card reads like a daily athlete
        // (~4 of 5 days lit) instead of the 5-week starter history above. Composes with the other
        // seeds — the graph counts DAYS, so overlaps with the history above just merge.
        if ProcessInfo.processInfo.arguments.contains("--seed-dense-history") {
            var drng = SeededRNG(11)
            for daysAgo in 0..<112 {
                guard drng.double(0, 1) < 0.8 else { continue }   // ~4 in 5 days active
                let start = Date().addingTimeInterval(Double(-daysAgo) * 86_400 - 8 * 3600
                                                      + drng.double(-3600, 3600))
                if daysAgo % 5 == 4 {
                    let sw = Workout(); sw.type = .strength; sw.startedAt = start
                    sw.durationS = 2_400 + drng.double(0, 900)
                    sw.strength = strengthSession(lifts: lifts, week: Double(daysAgo) / 7)
                    context.insert(sw)
                } else {
                    let run = Workout(); run.type = .run; run.startedAt = start
                    let dist = 5_000 + drng.double(0, 9_000)
                    let pace = 285 + drng.double(0, 40)
                    run.durationS = dist / 1000 * pace
                    let gps = GPSDetail(); gps.distanceM = dist
                    gps.avgPaceSPerKm = pace
                    gps.elevationGainM = 20 + drng.double(0, 90)
                    gps.samples = loopSamples(start: start, variant: daysAgo)
                    run.gps = gps
                    context.insert(run)
                }
            }
        }

        // --seed-ultra-run: one finished 50K (~6:20/km, ten days back) with real accepted samples,
        // so the record-book backfill mints the Fastest 50K row through the genuine pipeline
        // (fastest-window over the samples — never a hand-planted PersonalRecord).
        if ProcessInfo.processInfo.arguments.contains("--seed-ultra-run") {
            let start = Date().addingTimeInterval(-10 * 86_400 - 7 * 3600)
            let w = Workout(); w.type = .run; w.startedAt = start
            let paceSPerKm = 380.0, distanceM = 50_500.0
            w.durationS = distanceM / 1000 * paceSPerKm
            let gps = GPSDetail(); gps.distanceM = distanceM
            gps.avgPaceSPerKm = paceSPerKm
            gps.elevationGainM = 260
            let step = 100.0
            var ultraSamples: [LocationSample] = []
            for i in 0...Int(distanceM / step) {
                let s = LocationSample()
                s.t = start.addingTimeInterval(Double(i) * step / 1000 * paceSPerKm)
                s.lat = 30.1 + Double(i) * step / HeatmapBinning.metersPerDegLat
                s.lon = -97.8
                s.accepted = true
                ultraSamples.append(s)
            }
            gps.samples = ultraSamples
            w.gps = gps
            context.insert(w)
        }

        // Give the most recent run a guided-session rep breakdown so the summary's Reps section shows.
        if let recent = ((try? context.fetch(FetchDescriptor<Workout>())) ?? [])
            .filter({ $0.type == .run && $0.gps != nil })
            .max(by: { $0.startedAt < $1.startedAt }), let gps = recent.gps {
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

        // --seed-route-history: five outings on ONE loop.
        //
        // Seeded AFTER the guided-session block above, deliberately. That block hands its rep
        // breakdown and prescribed session to "the most recent run" by refetching, so seeding these
        // first (they land an hour ago, ahead of the demo's newest) quietly stole both — and with
        // them what `--ui-test-run-detail` and `--save-screen` open. A verification flag must not
        // change what it is verifying.
        //
        // This is the shape a real athlete's history actually has and the one thing the standard
        // demo cannot produce: every run above is scattered around its own Austin neighbourhood so
        // the profile grid looks varied, which means no two of them ever retrace each other and
        // `RouteMatch` finds nothing. Seeded through the genuine pipeline (real accepted fixes,
        // distance accumulated from the trace) so the matcher does the same work it does on a run
        // that just finished.
        //
        // Tuned so the run on screen is the *verdict*, not a badge: distances sit just under 5 km
        // (below the demo's longest, and short of the 5K benchmark window) and paces well off its
        // quickest, so `CardioAchievements` stays quiet. The newest outing is the route best; the
        // one two weeks back is a shade slower than the outing before it at eight fewer beats,
        // which is the heart-rate rung.
        if ProcessInfo.processInfo.arguments.contains("--seed-route-history") {
            let outings: [(hoursAgo: Double, paceSPerKm: Double, hr: Int)] = [
                (35 * 24, 350, 168), (28 * 24, 345, 165), (21 * 24, 342, 160), (14 * 24, 348, 152), (1, 330, 158),
            ]
            for (i, o) in outings.enumerated() {
                let start = Date().addingTimeInterval(-o.hoursAgo * 3600)
                let w = Workout(); w.type = .run; w.startedAt = start
                let trace = repeatRouteSamples(start: start, paceSPerKm: o.paceSPerKm, jitterSeed: i)
                w.durationS = trace.distanceM / 1000 * o.paceSPerKm
                w.elapsedS = w.durationS
                let gps = GPSDetail()
                gps.distanceM = trace.distanceM
                gps.avgPaceSPerKm = o.paceSPerKm
                gps.elevationGainM = 44
                gps.avgHR = o.hr
                gps.avgCadence = 178
                gps.samples = trace.samples
                w.gps = gps
                context.insert(w)
            }
        }
        // --seed-trail-run: the Lady Bird Lake loop, finished this morning, so it is the newest
        // run and the post-run page opens on a trace that follows a real trail.
        if ProcessInfo.processInfo.arguments.contains("--seed-trail-run") {
            // Finished ~10 min ago. `--profile-open-run` opens the newest GPS workout, and
            // `--seed-route-history`'s newest outing lands an hour back, so the loop has to be
            // more recent than that to be the run the capture opens on.
            let start = Date().addingTimeInterval(-(10 * 60 + 90 * 60))
            let trace = traceSamples(ladyBirdLakeTrail, start: start, paceSPerKm: 331)
            let w = Workout(); w.type = .run; w.startedAt = start
            w.title = "Long Run"
            w.durationS = trace.distanceM / 1000 * 331
            w.elapsedS = w.durationS
            let gps = GPSDetail()
            gps.distanceM = trace.distanceM
            gps.avgPaceSPerKm = 331
            gps.elevationGainM = 62
            gps.avgHR = 158
            gps.avgCadence = 176
            gps.samples = trace.samples
            w.gps = gps
            context.insert(w)
        }
        // --seed-track-run: five miles of laps on a stadium oval, finished half an hour ago, so it is
        // the newest run on the profile and the post-run page opens on a trace that actually
        // follows a track (a marketing capture, 2026-08-28 — the neighbourhood loops above read
        // as blobs). Lane-1 geometry: two 84.39 m straights joined by 36.5 m-radius bends.
        if ProcessInfo.processInfo.arguments.contains("--seed-track-run") {
            let start = Date().addingTimeInterval(-(30 * 60 + 16 * 60))
            let trace = trackSamples(start: start, paceSPerKm: 300, laps: 19.35)   // ≈ 5.00 mi
            let w = Workout(); w.type = .run; w.startedAt = start
            w.durationS = trace.distanceM / 1000 * 300
            w.elapsedS = w.durationS
            let gps = GPSDetail()
            gps.distanceM = trace.distanceM
            gps.avgPaceSPerKm = 300
            gps.elevationGainM = 3
            gps.avgHR = 164
            gps.avgCadence = 182
            gps.samples = trace.samples
            w.gps = gps
            context.insert(w)
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
            (.streak, "3-day streak going", "Keep it alive. A session today makes it four.", 1),
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
                // Render each card on the basemap its own run was saved with — the same rule the
                // healer now follows, so a seeded tile and a real save are indistinguishable.
                // Portrait tile-native size, exactly like a real save.
                let seedStyle = gps.mapStyle
                if let data = await RouteSnapshotter.snapshot(
                    coordinates: coords, size: RouteSnapshotter.workoutTileSize,
                    styleURI: seedStyle.styleURI,
                    insets: RouteSnapshotter.workoutTileInsets) {
                    gps.mapSnapshotData = data
                    gps.mapSnapshotVersion = RouteSnapshotter.renderVersion
                    gps.mapStyleRaw = seedStyle.rawValue
                    try? context.save()
                }
            }
        }
    }

    /// The basemaps seeded runs are saved with, in rotation. Seven entries against a 3-column grid
    /// means the pattern never lines up into stripes. Curated, not all nine `MapStyleOption`s:
    /// Dusk and Night bake identically to Realistic (a `StyleURI` can't carry the Standard light
    /// preset), so including them would just repeat a look.
    static let cardStyleRotation: [MapStyleOption] =
        [.standard, .dark, .outdoors, .realistic, .satellite, .streets, .standardSatellite]

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
        func addRun(city: String, laps: Int, daysAgo: Double, dense: Bool, variant: Int,
                    style: MapStyleOption? = nil) {
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
            // Each run keeps the basemap it was "saved with" — cards render in their own style
            // since v5, so rotating here is what gives the grid its range instead of 200 tiles of
            // the same pale map. Rotation order alternates pale/dark/photographic so neighbouring
            // tiles never repeat: the mosaic is 3 columns, and 7 shares no factor with 3.
            gps.mapStyleRaw = (style ?? Self.cardStyleRotation[variant % Self.cardStyleRotation.count]).rawValue
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
        // The opening composition. The first screenful is the one anybody actually judges (and the
        // one that gets screenshotted), so these are hand-placed rather than left to the rotation:
        // pale · photographic · dark in the first row, then a green and a colour, so no two
        // neighbours share a canvas and the range is legible immediately. Strength tiles land at
        // days 3.4/10.4/17.4 and break the run of them up further.
        let opening: [MapStyleOption] = [.standard, .satellite, .dark, .outdoors, .streets,
                                         .standardSatellite, .realistic, .dark, .standard]
        for (i, spec) in featured.enumerated() {
            addRun(city: spec.0, laps: spec.1, daysAgo: 1 + Double(i) * 3, dense: true, variant: i,
                   style: i < opening.count ? opening[i] : nil)
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
            let laps = j.isMultiple(of: 7) ? rng.int(2...3) : 1
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
                // Each card on the basemap its own run was saved with — same rule the healer
                // follows since v5, so a seeded tile is indistinguishable from a real save. This
                // used to hardcode `.persisted` + `tileStyle` and then WRITE that back over
                // `mapStyleRaw`, which silently flattened the newest 22 tiles (the whole visible
                // grid) to one basemap while everything below them stayed varied.
                let seedStyle = gps.mapStyle
                if let data = await RouteSnapshotter.snapshot(
                    coordinates: coords, size: RouteSnapshotter.workoutTileSize,
                    styleURI: seedStyle.styleURI,
                    insets: RouteSnapshotter.workoutTileInsets) {
                    gps.mapSnapshotData = data
                    gps.mapSnapshotVersion = RouteSnapshotter.renderVersion
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
        gps.avgPaceSPerKm = CardioMetrics.averagePaceSPerKm(distanceM: distanceM, durationS: durationS)  // ~4:14 /km
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
        // The demo athlete shares their race: with `--community` this is the OWN post on the wall
        // (tile + pager byline), proving the save→feed pipeline end to end. Privacy is invisible
        // in solo builds, where no community surface exists to read it.
        run.privacy = .public
        run.gps = gps
        context.insert(run)
        try? context.save()
    }

    /// Two generated placeholder "photos" (soft dawn/dusk gradients with a horizon line) — enough
    /// to exercise the photo tile, the full-bleed carousel, and its counter pill without bundling
    /// stock imagery. Clearly synthetic, DEBUG-only.
    private static func demoPhotos() -> [WorkoutPhoto] {
        let palettes: [[UIColor]] = [
            [UIColor(red: 0.98, green: 0.82, blue: 0.65, alpha: 1), UIColor(red: 0.55, green: 0.60, blue: 0.85, alpha: 1)],
            [UIColor(red: 0.35, green: 0.42, blue: 0.60, alpha: 1), UIColor(red: 0.92, green: 0.65, blue: 0.55, alpha: 1)],
        ]
        return palettes.enumerated().map { i, colors in
            let size = CGSize(width: 900, height: 1200)
            let image = UIGraphicsImageRenderer(size: size).image { ctx in
                let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                          colors: colors.map(\.cgColor) as CFArray, locations: [0, 1])!
                ctx.cgContext.drawLinearGradient(gradient, start: .zero,
                                                 end: CGPoint(x: 0, y: size.height), options: [])
            }
            return WorkoutPhoto(order: i, data: image.jpegData(compressionQuality: 0.8) ?? Data())
        }
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

    /// The four demo lifts, taken FROM the shared library (which seeds before us) — inserting
    /// copies here is what once double-listed "Barbell Bench Press" in the exercise search.
    private static func demoLifts(in context: ModelContext) -> [Exercise] {
        let names = ["Barbell Bench Press", "Barbell Row", "Barbell Back Squat", "Overhead Press"]
        let all = (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
        return names.compactMap { name in all.first { $0.name == name && !$0.isCustom } }
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
                case "Barbell Back Squat": 1.6
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
    /// One fixed loop, run again on a different day. Roughly 5 km over two laps of a ~400 m-radius
    /// circle east of downtown, clear of the five neighbourhoods `loopSamples` uses so the repeat
    /// route can never be confused with them.
    ///
    /// Each outing is jittered by up to ten metres, deterministically per index. That matters: two
    /// runs of one loop are never the same fixes, and a fixture built from an identical trace would
    /// let `RouteMatch` pass without its tolerance ever being exercised. Distance is accumulated
    /// from the trace rather than assumed, so the seeded run is internally consistent the way a
    /// captured one is.
    private static func repeatRouteSamples(start: Date, paceSPerKm: Double,
                                           jitterSeed: Int) -> (samples: [LocationSample], distanceM: Double) {
        let centerLat = 30.2500, centerLon = -97.7300
        let radiusDeg = 0.003574                       // ≈ 398 m → ~2.5 km a lap
        let lonScale = 1 / cos(centerLat * .pi / 180)  // longitude degrees are shorter this far north
        let perLap = 90, laps = 2
        var out: [LocationSample] = []
        var distanceM = 0.0, elapsed = 0.0
        var prevLat = 0.0, prevLon = 0.0
        for i in 0..<(laps * perLap) {
            let a = Double(i) / Double(perLap) * 2 * .pi
            let driftLat = 10 * sin(Double(i) * 0.7 + Double(jitterSeed)) / HeatmapBinning.metersPerDegLat
            let driftLon = 10 * cos(Double(i) * 0.5 + Double(jitterSeed) * 1.3) * lonScale / HeatmapBinning.metersPerDegLat
            let lat = centerLat + radiusDeg * sin(a) + driftLat
            let lon = centerLon + radiusDeg * cos(a) * lonScale + driftLon
            if i > 0 {
                let step = Geo.distance(lat1: prevLat, lon1: prevLon, lat2: lat, lon2: lon)
                distanceM += step
                elapsed += step / 1000 * paceSPerKm
            }
            let s = LocationSample()
            s.t = start.addingTimeInterval(elapsed)
            s.lat = lat; s.lon = lon
            s.speedMS = 1000 / paceSPerKm
            s.altitudeM = 150 + 12 * sin(a * 2)
            s.accuracyM = 6
            s.accepted = true
            out.append(s)
            prevLat = lat; prevLon = lon
        }
        return (out, distanceM)
    }

    /// The Ann and Roy Butler Hike-and-Bike Trail, the full loop around Lady Bird Lake in Austin
    /// (Mopac to Longhorn Dam, both shores) — 10.16 mi, matching the owner's own Strava trace of
    /// the full trail. Both banks are separate shortest paths on the real OSM walking network
    /// (Butler-trail edges cost 1x, everything else 25x, and the return leg is blocked from the
    /// outbound one so it must take the far shore); the west anchor is tuned to the loop's length.
    /// A few metres of lateral sampling noise ride on top, which is what a GPS trace of a walked
    /// path actually measures against the idealised centreline.
    ///
    /// Every waypoint is an actual vertex of the trail: its 153 ways come from OpenStreetMap via
    /// Overpass, the loop's waypoints are SNAPPED onto them, and Mapbox Directions (walking) only
    /// bridges the gaps — including the real bridges, which OSM names separately, so the trail's
    /// own ways form a near-tree that never closes on its own. Verified against that geometry: a
    /// median 5 m off the real trail (p90 40 m).
    ///
    /// Two earlier attempts are worth not repeating. Guessed waypoints let Directions route
    /// BETWEEN them on the street grid, sending the run up through downtown along 6th. And
    /// stitching the OSM ways directly into a loop fails three ways: greedy endpoint-chaining
    /// walks onto spurs, bearing-sort breaks on a lake this elongated, and per-longitude
    /// north/south medians zigzag between parallel paths.
    private static let ladyBirdLakeTrail: [(Double, Double)] = [
        (30.275403, -97.772197), (30.275268, -97.771955), (30.275049, -97.771613), (30.275032, -97.771442),
        (30.275132, -97.771314), (30.275161, -97.771233), (30.274970, -97.770850), (30.274447, -97.770027),
        (30.273997, -97.769424), (30.273713, -97.769101), (30.272842, -97.769261), (30.272569, -97.769397),
        (30.272288, -97.769315), (30.272081, -97.768935), (30.271879, -97.768460), (30.271456, -97.767739),
        (30.271263, -97.767591), (30.271178, -97.767367), (30.270654, -97.766380), (30.270466, -97.766229),
        (30.270369, -97.765989), (30.270337, -97.765891), (30.270028, -97.765491), (30.269961, -97.765169),
        (30.269823, -97.764717), (30.269641, -97.764192), (30.269442, -97.763608), (30.269341, -97.763164),
        (30.269193, -97.762807), (30.269144, -97.762580), (30.269233, -97.762427), (30.269246, -97.762391),
        (30.269162, -97.762191), (30.269019, -97.761813), (30.268925, -97.761467), (30.268781, -97.761315),
        (30.268457, -97.760648), (30.268142, -97.759960), (30.267983, -97.759529), (30.267878, -97.759403),
        (30.267789, -97.759183), (30.267605, -97.758830), (30.267077, -97.757853), (30.267056, -97.757662),
        (30.266978, -97.757309), (30.266710, -97.756976), (30.266628, -97.756856), (30.266433, -97.756203),
        (30.266273, -97.755948), (30.266123, -97.755547), (30.266168, -97.755466), (30.266162, -97.755427),
        (30.266107, -97.755364), (30.266123, -97.755276), (30.266111, -97.755184), (30.266021, -97.755144),
        (30.265908, -97.754721), (30.265873, -97.754231), (30.265748, -97.753797), (30.265715, -97.753562),
        (30.265772, -97.753468), (30.265755, -97.753178), (30.265606, -97.752818), (30.265623, -97.752714),
        (30.265596, -97.752603), (30.265301, -97.752471), (30.265240, -97.752391), (30.265116, -97.752045),
        (30.265021, -97.751980), (30.264865, -97.751871), (30.264752, -97.751658), (30.264645, -97.751490),
        (30.264482, -97.751181), (30.264295, -97.750503), (30.264290, -97.750255), (30.264489, -97.750107),
        (30.264583, -97.750095), (30.264598, -97.749970), (30.264423, -97.749531), (30.264176, -97.748929),
        (30.264081, -97.748470), (30.263828, -97.747916), (30.263649, -97.747518), (30.263684, -97.747379),
        (30.263706, -97.747108), (30.263578, -97.746750), (30.263542, -97.746586), (30.263319, -97.746065),
        (30.263155, -97.745812), (30.262907, -97.745317), (30.262791, -97.745144), (30.262672, -97.745113),
        (30.262572, -97.745055), (30.262545, -97.744866), (30.262505, -97.744713), (30.262426, -97.744628),
        (30.262416, -97.744500), (30.262287, -97.744262), (30.261714, -97.743521), (30.261601, -97.743290),
        (30.261437, -97.743082), (30.261041, -97.742760), (30.260949, -97.742667), (30.260936, -97.742518),
        (30.260816, -97.742255), (30.260749, -97.741957), (30.260709, -97.741706), (30.260703, -97.741567),
        (30.260654, -97.741488), (30.260608, -97.741282), (30.260490, -97.741096), (30.260363, -97.741100),
        (30.260288, -97.741104), (30.260077, -97.741106), (30.260035, -97.741119), (30.259582, -97.740942),
        (30.259455, -97.740799), (30.259368, -97.740767), (30.259246, -97.740834), (30.258960, -97.740887),
        (30.258575, -97.740895), (30.258248, -97.740981), (30.258038, -97.740954), (30.257919, -97.740883),
        (30.257480, -97.740609), (30.257354, -97.740591), (30.257174, -97.740504), (30.257027, -97.740494),
        (30.256778, -97.740474), (30.256400, -97.740237), (30.256127, -97.740088), (30.255687, -97.740004),
        (30.255474, -97.739932), (30.255424, -97.739831), (30.255212, -97.739781), (30.255022, -97.739778),
        (30.254863, -97.739711), (30.254804, -97.739703), (30.254586, -97.739572), (30.254385, -97.739368),
        (30.254030, -97.738896), (30.253912, -97.738917), (30.253618, -97.738751), (30.253289, -97.738391),
        (30.253157, -97.737956), (30.253073, -97.737892), (30.253048, -97.737771), (30.253020, -97.737797),
        (30.252612, -97.737308), (30.252543, -97.737173), (30.252294, -97.737182), (30.252159, -97.737157),
        (30.252009, -97.736941), (30.252032, -97.736739), (30.251940, -97.736622), (30.251651, -97.735774),
        (30.251686, -97.735471), (30.251578, -97.735344), (30.251501, -97.735291), (30.251357, -97.735167),
        (30.251111, -97.734994), (30.250985, -97.734865), (30.250833, -97.734309), (30.250760, -97.733961),
        (30.250444, -97.733171), (30.250287, -97.732800), (30.250161, -97.732370), (30.249962, -97.732053),
        (30.249505, -97.731216), (30.249505, -97.731090), (30.249179, -97.730181), (30.249076, -97.729884),
        (30.249125, -97.729571), (30.248892, -97.729001), (30.248651, -97.728649), (30.248441, -97.728099),
        (30.248356, -97.727544), (30.248215, -97.727327), (30.247867, -97.726905), (30.247697, -97.726334),
        (30.247700, -97.726188), (30.247738, -97.726015), (30.247929, -97.725903), (30.248023, -97.725599),
        (30.247972, -97.725448), (30.247971, -97.725297), (30.247832, -97.724695), (30.247654, -97.724688),
        (30.247547, -97.724699), (30.247473, -97.724612), (30.247323, -97.724578), (30.247172, -97.724526),
        (30.247134, -97.724419), (30.247112, -97.724355), (30.247041, -97.724299), (30.247073, -97.724105),
        (30.247161, -97.723912), (30.247156, -97.723816), (30.247175, -97.723717), (30.247265, -97.723560),
        (30.247315, -97.723327), (30.247387, -97.722977), (30.247506, -97.722846), (30.247618, -97.722704),
        (30.247625, -97.722573), (30.247742, -97.722351), (30.247875, -97.722057), (30.247863, -97.721824),
        (30.248012, -97.721617), (30.248310, -97.721345), (30.248481, -97.721071), (30.248561, -97.720970),
        (30.248720, -97.720972), (30.248922, -97.720904), (30.249004, -97.720801), (30.249139, -97.720744),
        (30.249298, -97.720537), (30.249290, -97.720391), (30.249332, -97.720274), (30.249449, -97.720188),
        (30.249696, -97.719871), (30.249727, -97.719758), (30.249800, -97.719709), (30.249805, -97.719574),
        (30.249797, -97.719432), (30.249882, -97.719345), (30.249974, -97.719247), (30.250061, -97.719069),
        (30.250140, -97.719040), (30.250402, -97.718976), (30.250472, -97.718881), (30.250348, -97.718584),
        (30.250396, -97.718496), (30.250383, -97.718045), (30.250494, -97.717264), (30.250653, -97.715920),
        (30.250674, -97.715557), (30.250638, -97.715212), (30.250636, -97.714741), (30.250712, -97.714603),
        (30.250781, -97.714348), (30.251264, -97.713907), (30.251380, -97.713756), (30.251383, -97.713635),
        (30.251357, -97.713585), (30.251388, -97.713502), (30.251211, -97.713469), (30.249652, -97.713698),
        (30.249267, -97.713750), (30.248789, -97.713752), (30.248448, -97.713882), (30.248170, -97.714007),
        (30.247796, -97.714176), (30.247658, -97.714416), (30.247447, -97.714814), (30.246979, -97.715065),
        (30.246633, -97.715116), (30.246354, -97.715296), (30.246101, -97.715477), (30.245981, -97.715559),
        (30.245385, -97.716201), (30.245003, -97.716430), (30.244687, -97.716455), (30.244480, -97.716483),
        (30.244262, -97.716488), (30.244192, -97.716437), (30.243969, -97.716519), (30.243656, -97.716846),
        (30.243522, -97.717321), (30.243421, -97.717925), (30.243471, -97.718390), (30.243454, -97.718527),
        (30.243366, -97.718743), (30.243341, -97.718989), (30.243377, -97.719126), (30.243628, -97.719962),
        (30.243858, -97.720276), (30.244073, -97.720566), (30.244105, -97.721049), (30.244110, -97.721159),
        (30.244234, -97.721360), (30.244250, -97.721492), (30.244502, -97.722053), (30.244761, -97.722480),
        (30.244821, -97.722533), (30.245029, -97.722740), (30.245295, -97.722960), (30.245427, -97.723045),
        (30.245426, -97.723331), (30.245416, -97.723652), (30.245410, -97.724066), (30.245369, -97.724158),
        (30.245331, -97.724263), (30.245359, -97.724475), (30.245333, -97.724669), (30.245323, -97.725164),
        (30.245438, -97.725854), (30.245584, -97.726483), (30.245462, -97.726683), (30.245555, -97.726683),
        (30.245792, -97.726941), (30.245970, -97.727412), (30.246056, -97.727509), (30.246203, -97.727486),
        (30.246294, -97.727550), (30.246347, -97.727755), (30.246402, -97.727892), (30.246402, -97.728019),
        (30.246298, -97.728145), (30.246308, -97.728369), (30.246434, -97.728578), (30.246443, -97.728720),
        (30.246576, -97.729099), (30.246965, -97.729873), (30.246973, -97.730012), (30.246962, -97.730151),
        (30.247105, -97.730358), (30.247277, -97.730548), (30.247309, -97.730631), (30.247392, -97.730635),
        (30.247516, -97.730657), (30.247603, -97.730809), (30.247692, -97.731040), (30.247817, -97.731226),
        (30.247831, -97.731326), (30.247897, -97.731456), (30.248023, -97.731495), (30.248099, -97.731616),
        (30.248116, -97.731849), (30.248229, -97.731960), (30.248370, -97.732145), (30.248384, -97.732332),
        (30.248428, -97.732510), (30.248531, -97.732709), (30.248638, -97.732982), (30.248626, -97.733073),
        (30.248717, -97.733145), (30.248811, -97.733260), (30.248836, -97.733361), (30.248913, -97.733438),
        (30.248988, -97.733635), (30.248954, -97.734407), (30.249092, -97.734781), (30.249230, -97.734926),
        (30.249339, -97.735197), (30.249552, -97.735469), (30.249768, -97.735546), (30.249927, -97.735911),
        (30.249934, -97.736260), (30.250098, -97.736500), (30.250165, -97.736586), (30.250174, -97.736701),
        (30.250234, -97.736797), (30.250401, -97.737048), (30.250477, -97.737328), (30.250547, -97.737529),
        (30.250616, -97.737669), (30.250567, -97.737829), (30.250531, -97.737968), (30.250669, -97.738166),
        (30.250883, -97.738542), (30.250927, -97.738663), (30.250997, -97.738730), (30.251055, -97.738823),
        (30.251030, -97.738999), (30.251056, -97.739081), (30.251156, -97.739125), (30.251180, -97.739234),
        (30.251221, -97.739405), (30.251293, -97.739451), (30.251325, -97.739574), (30.251336, -97.739706),
        (30.251487, -97.739830), (30.251594, -97.739892), (30.251626, -97.740011), (30.251737, -97.740129),
        (30.251861, -97.740220), (30.251913, -97.740331), (30.252022, -97.740425), (30.252159, -97.740389),
        (30.252351, -97.740447), (30.252419, -97.740569), (30.252539, -97.740609), (30.252644, -97.740650),
        (30.252790, -97.740843), (30.252854, -97.740899), (30.252941, -97.740927), (30.253023, -97.741047),
        (30.253145, -97.741128), (30.253220, -97.741094), (30.253286, -97.741183), (30.253335, -97.741317),
        (30.253484, -97.741339), (30.253545, -97.741343), (30.253654, -97.741479), (30.253765, -97.741513),
        (30.253925, -97.741574), (30.253994, -97.741684), (30.254111, -97.741795), (30.254245, -97.741809),
        (30.254391, -97.741893), (30.254445, -97.741989), (30.254546, -97.742038), (30.254630, -97.742172),
        (30.254623, -97.742392), (30.254696, -97.742568), (30.254817, -97.742631), (30.254953, -97.742765),
        (30.255142, -97.742783), (30.255335, -97.742708), (30.255511, -97.742752), (30.256789, -97.743014),
        (30.257126, -97.743008), (30.258283, -97.743266), (30.258477, -97.743546), (30.259252, -97.743691),
        (30.259576, -97.743892), (30.259869, -97.744195), (30.260158, -97.744496), (30.260630, -97.745105),
        (30.260670, -97.745339), (30.260754, -97.745735), (30.260875, -97.745809), (30.261228, -97.746806),
        (30.261181, -97.746948), (30.261356, -97.747357), (30.261378, -97.747427), (30.261381, -97.747622),
        (30.261376, -97.747763), (30.261436, -97.747785), (30.261626, -97.747980), (30.261853, -97.748193),
        (30.262044, -97.748504), (30.262042, -97.748608), (30.262033, -97.748724), (30.262077, -97.748879),
        (30.262168, -97.749015), (30.262358, -97.749187), (30.262575, -97.749476), (30.262743, -97.749711),
        (30.262763, -97.749938), (30.262907, -97.750430), (30.263095, -97.750709), (30.263378, -97.751521),
        (30.263335, -97.751839), (30.263393, -97.751922), (30.263633, -97.752279), (30.263724, -97.752431),
        (30.263787, -97.752535), (30.263893, -97.752681), (30.263878, -97.752840), (30.263902, -97.753047),
        (30.263980, -97.753513), (30.264000, -97.753813), (30.263956, -97.754018), (30.263946, -97.754266),
        (30.263857, -97.754420), (30.263753, -97.754673), (30.263775, -97.754791), (30.263953, -97.755004),
        (30.264142, -97.755140), (30.264320, -97.755449), (30.264802, -97.756515), (30.265045, -97.757084),
        (30.265225, -97.757605), (30.265472, -97.757958), (30.265875, -97.758826), (30.265885, -97.758963),
        (30.266049, -97.759160), (30.266190, -97.759514), (30.266276, -97.759983), (30.266465, -97.760386),
        (30.266587, -97.760578), (30.266647, -97.760759), (30.266681, -97.760943), (30.266738, -97.761034),
        (30.266709, -97.761130), (30.266520, -97.761442), (30.266148, -97.762362), (30.265924, -97.762863),
        (30.265766, -97.763058), (30.265314, -97.764010), (30.265375, -97.764104), (30.265723, -97.764370),
        (30.266013, -97.763904), (30.266254, -97.763339), (30.266645, -97.762615), (30.267027, -97.762073),
        (30.267077, -97.761934), (30.267145, -97.761885), (30.267269, -97.762036), (30.267493, -97.762277),
        (30.267711, -97.762577), (30.267975, -97.763378), (30.268321, -97.764416), (30.268728, -97.765567),
        (30.269108, -97.766347), (30.269089, -97.766386), (30.269314, -97.766811), (30.269415, -97.767268),
        (30.269433, -97.767448), (30.269622, -97.767803), (30.269823, -97.768349), (30.270159, -97.769101),
        (30.270582, -97.769689), (30.271065, -97.770084), (30.271885, -97.771417), (30.272165, -97.771859),
        (30.272550, -97.771915), (30.272662, -97.771963), (30.272883, -97.772161), (30.273211, -97.772339),
        (30.273246, -97.772290), (30.275035, -97.771058), (30.275150, -97.771237), (30.275133, -97.771315),
        (30.275044, -97.771444), (30.275041, -97.771617), (30.275263, -97.771959), (30.275412, -97.772188)
    ]

    /// Walk a real polyline at a steady pace, emitting one sample per vertex.
    private static func traceSamples(_ route: [(Double, Double)], start: Date,
                                     paceSPerKm: Double) -> (samples: [LocationSample], distanceM: Double) {
        var out: [LocationSample] = []
        var distanceM = 0.0, elapsed = 0.0
        for (i, p) in route.enumerated() {
            if i > 0 {
                let step = Geo.distance(lat1: route[i - 1].0, lon1: route[i - 1].1, lat2: p.0, lon2: p.1)
                distanceM += step
                elapsed += step / 1000 * paceSPerKm
            }
            let s = LocationSample()
            s.t = start.addingTimeInterval(elapsed)
            s.lat = p.0; s.lon = p.1
            s.speedMS = 1000 / paceSPerKm
            s.altitudeM = 145 + 4 * sin(Double(i) * 0.3)
            s.accuracyM = 5
            s.accepted = true
            out.append(s)
        }
        return (out, distanceM)
    }

    /// Samples around a standard 400 m track, lane 1, long axis rotated by `headingDeg` (0 = the
    /// straights run north–south). Centre is the middle of the infield.
    private static func trackSamples(start: Date, paceSPerKm: Double, laps: Double,
                                     centerLat: Double = 30.27873, centerLon: Double = -97.75002,
                                     headingDeg: Double = -4) -> (samples: [LocationSample], distanceM: Double) {
        // Fitted to the ring as the basemap DRAWS it (measured off a capture: ~65 m wide, ~171 m
        // long) rather than to regulation lane-1 — a true 73 m-wide oval ran over the stands.
        let straight = 106.0, radius = 32.5
        let perLap = 80
        let mPerDegLat = HeatmapBinning.metersPerDegLat
        let mPerDegLon = mPerDegLat * cos(centerLat * .pi / 180)
        let h = headingDeg * .pi / 180
        var out: [LocationSample] = []
        var distanceM = 0.0, elapsed = 0.0
        var prevLat = 0.0, prevLon = 0.0
        for i in 0...Int((laps * Double(perLap)).rounded()) {
            // Walk the perimeter: straight (east side, heading north) → bend → straight → bend.
            let u = Double(i % perLap) / Double(perLap)          // 0…1 around the lap
            let lapLen = 2 * straight + 2 * .pi * radius
            let d = u * lapLen
            var x = 0.0, y = 0.0                                   // metres, before rotation
            if d < straight {                                      // right straight, northbound
                x = radius; y = -straight / 2 + d
            } else if d < straight + .pi * radius {                // top bend
                let t = (d - straight) / radius
                x = radius * cos(t); y = straight / 2 + radius * sin(t)
            } else if d < 2 * straight + .pi * radius {            // left straight, southbound
                x = -radius; y = straight / 2 - (d - straight - .pi * radius)
            } else {                                               // bottom bend
                let t = (d - 2 * straight - .pi * radius) / radius
                x = -radius * cos(t); y = -straight / 2 - radius * sin(t)
            }
            // A runner holds a line, but not a rail: a few decimetres of wander.
            let wobble = 0.35 * sin(Double(i) * 0.9)
            let rx = (x + wobble) * cos(h) - y * sin(h)
            let ry = (x + wobble) * sin(h) + y * cos(h)
            let lat = centerLat + ry / mPerDegLat
            let lon = centerLon + rx / mPerDegLon
            if i > 0 {
                let step = Geo.distance(lat1: prevLat, lon1: prevLon, lat2: lat, lon2: lon)
                distanceM += step
                elapsed += step / 1000 * paceSPerKm
            }
            let s = LocationSample()
            s.t = start.addingTimeInterval(elapsed)
            s.lat = lat; s.lon = lon
            s.speedMS = 1000 / paceSPerKm
            s.altitudeM = 149
            s.accuracyM = 4
            s.accepted = true
            out.append(s)
            prevLat = lat; prevLon = lon
        }
        return (out, distanceM)
    }

    private static func loopSamples(start: Date, variant: Int, speedScale: Double = 1.0) -> [LocationSample] {
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
            // Cruise ~3.1 m/s (≈5:22/km) with rolling variation + a surge each lap. `speedScale`
            // turns the same loop into a ride (~2.5 → ≈28 km/h) for the cycling summary's charts.
            let speed = (3.1 + 0.5 * sin(a * 2 + Double(variant)) + 0.25 * sin(a * 5)) * speedScale
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
