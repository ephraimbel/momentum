import SwiftUI
import SwiftData
import CoreLocation
import MapboxMaps

/// Today — the map-first home (PRD §4.2/§7.2). A full-screen map for instant access to starting a
/// run/ride/walk/hike, an activity selector, today's plan banner, and a goal customizer. Start →
/// the immersive recording cover (cardio) or the strength logger.
struct TodayView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme
    @Environment(Services.self) private var services
    @Environment(CoachPresenter.self) private var coach
    @Environment(AppRouter.self) private var router   // morning readout → Progress · Health
    @Query private var profiles: [UserProfile]
    // Coach-button badge: only the newest coach message matters, so fetch exactly that instead of
    // materializing the whole thread on Today (the map re-evaluates this body constantly).
    @Query(TodayView.latestCoachMessage) private var latestCoachMessage: [ChatMessage]
    @Query private var workouts: [Workout]
    // Bell badge: the unread filter lives in the query (live, updated on read-flips) — filtering
    // the full inbox per body pass was a per-frame walk while the map panned.
    @Query(filter: #Predicate<AppNotification> { $0.read == false })
    private var unreadNotifications: [AppNotification]

    private static var latestCoachMessage: FetchDescriptor<ChatMessage> {
        let coachRaw = ChatMessage.Role.coach.rawValue
        var d = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.roleRaw == coachRaw },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        d.fetchLimit = 1
        return d
    }
    @Query private var checkins: [DailyCheckin]
    // Reactive read of today's adaptation receipt (ease/cutback) — the morning readout's footer
    // appears the moment the bootstrap's recovery pass records one (RECOVERY-HUB-PLAN §2 entry 2).
    @Query(sort: \CoachingEvent.date, order: .reverse) private var coachingEvents: [CoachingEvent]

    // Defaults to Run (map-first home). `--ui-test-strength` opens straight into strength so the
    // strength-logging UI test can drive the set logger deterministically (no picker navigation).
    @State private var activity: WorkoutType =
        debugFlag("--ui-test-strength") ? .strength : .run
    @State private var goalKind: GoalKind = .open
    @State private var goalValue = 3.0
    @State private var viewport: Viewport = .idle
    @State private var launch: TodayLaunch?
    @State private var locator = LocationService()
    /// Where the map opens for an athlete we haven't located yet — no stored fix, no permission.
    /// Deliberately NOT a city: this used to be hardcoded to San Francisco, so the first frame of the
    /// product showed a stranger's neighbourhood to everyone in London, Lagos or Tokyo — a guess the
    /// athlete can see straight through. Instead we centre their own meridian, read off the device
    /// time zone (no permission, always available), and pull back far enough that no neighbourhood is
    /// implied. The map reads as "not located yet" rather than "located, wrongly".
    /// Never the puck here: that viewport spins up Mapbox's location provider and would prompt on
    /// arrival. The ask stays contextual — Start and recenter do it, and fly to them.
    private static var unlocatedViewport: Viewport {
        // Earth turns 15°/hour ⇒ one degree of longitude per 240 s of UTC offset. Zones legitimately
        // run past ±12 h (Kiritimati is +14), so clamp rather than wrap into the wrong hemisphere.
        let longitude = min(180, max(-180, Double(TimeZone.current.secondsFromGMT()) / 240))
        // Flat: pitch on a world-scale camera reads as a tilted globe, not a map.
        return .camera(center: CLLocationCoordinate2D(latitude: 28, longitude: longitude),
                       zoom: 3.0, pitch: 0)
    }
    @State private var confirmingPlan: PlannedSession?      // plan session awaiting confirmation
    @State private var pendingPlanStart: PlannedSession?    // start after the confirm sheet dismisses
    // The athlete's app-wide base-map choice — persists across launches and stays in sync with every
    // other map surface (run screen, heatmap). Realistic (Mapbox Standard 3D) is the default.
    @AppStorage(MapStyleOption.storageKey) private var mapStyle: MapStyleOption = .realistic
    // Inline loop suggester — runs ON the Today map (no separate page), like world mode. `loopVM` holds
    // the candidates; the selected loop draws in brand purple beneath the live purple puck.
    @State private var loopMode = false
    @State private var loopVM: RouteSuggestionViewModel?
    // Spots is hidden for now; reachable only via the `--spots` deep link. "Loop here" from it enters
    // inline loop mode after the sheet dismisses (presenting/transitioning on one tick misbehaves).
    @State private var showSpots = false
    @State private var showNotifications = false
    @State private var showProfile = false
    @State private var showLogWorkout = false
    /// The offline-log composer (say/type what you did → receipt → confirm).
    @State private var showLogActivity = false
    /// The composer's "Adjust details" hand-off — set after its sheet dismisses, presents the
    /// full manual form pre-filled with the parse.
    @State private var manualPrefill: LogWorkoutPrefill?
    /// DEBUG deep link only (`--log-activity-draft`): opens the composer holding this text.
    @State private var logActivityDraft: String?
    @State private var showInjuryReport = false
    @State private var showCheckin = false
    /// The morning readout for the deck's utility line — one honest 0–100, computed off-render.
    @State private var morningReadiness: MorningReadiness?
    /// Throttles the appear-time orchestration — `onAppear` re-fires on every tab switch.
    @State private var lastBootstrap: (at: Date, day: Date)?
    /// True once the map backdrop has been mounted — it then stays warm for the session (a
    /// strength-only athlete who never shows the map never pays for it).
    @State private var mapWasShown = false
    /// The header streak, computed once per data change instead of on every body evaluation
    /// (the map re-evaluates the body constantly while panning).
    @State private var cachedStreak: Int?
    /// Today's pending plan session, memoized for the same reason (see `pendingToday`).
    @State private var cachedPendingToday: PlannedSession?
    @State private var pendingTodayToken: Int = 0
    /// The deck's plan story when nothing is left to start — "today's done" or "rest day, next up
    /// Thursday". Cached beside `cachedPendingToday` (same invalidation token) because the deck body
    /// re-evaluates per frame while the map pans, and filtering the full session list per frame is
    /// the exact anti-pattern the memoized plan row exists to avoid.
    @State private var cachedPlanState: PlanStateLine?
    @State private var confirmResume = false
    @State private var pendingLoopStart: GeoPoint?
    @State private var showSportPicker = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // The Today map zoomed all the way out to the globe of everyone on Momentum (no separate tab).
    // `--world` opens straight on the globe (DEBUG deep link for deterministic sim verification).
    @State private var worldMode = debugFlag("--world")
    // Basemap is decoupled from `worldMode` so the satellite↔light swap never lands mid-fly (a style
    // reload during a camera animation cancels it). We flip this only when the fly has settled.
    @State private var mapShowsGlobe = debugFlag("--world")
    @State private var liveCount = 0
    @State private var selectedAthlete: CommunityAthlete?
    // DEBUG marketing capture (--marketing-hero, pair with --seed-demo): trace a real seeded run's
    // route on the Today map + overview it, so the website header shows a route AND today's plan
    // card in one authentic app shot.
    @State private var marketingHero = debugFlag("--marketing-hero")
    // One-shot: the hero course is framed in `.onStyleLoaded` (once the map is actually ready), not
    // on a fixed onAppear delay that raced the tile load and left the camera on the puck.
    @State private var heroFramed = false

    enum GoalKind { case open, distance }

    /// The real Austin Marathon course for the marketing hero — the actual race route traced on the
    /// Today map (bundled `austin-marathon.json`, street-snapped from the official course).
    private var heroRouteCoordinates: [CLLocationCoordinate2D] {
        guard marketingHero else { return [] }
        #if DEBUG
        return Self.austinMarathon.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
        #else
        return []
        #endif
    }

    #if DEBUG
    /// The bundled Austin Marathon course points ([[lat, lon]]), loaded once for the marketing hero.
    private static let austinMarathon: [[Double]] = {
        guard let url = Bundle.main.url(forResource: "austin-marathon", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONDecoder().decode([String: [[Double]]].self, from: data)
        else { return [] }
        return obj["pts"] ?? []
    }()

    /// Frame the full hero course once the style/tiles are ready. One-shot (guarded). A direct camera
    /// on the course centroid — not `.overview` from an uninitialized `.idle` camera, which fails to
    /// fit and falls back to a world-zoom globe. Centroid + a fixed zoom reliably centers the whole
    /// course between the floating header and the plan card.
    private func frameMarketingHero() {
        guard marketingHero, !heroFramed, heroRouteCoordinates.count > 1 else { return }
        heroFramed = true
        let coords = heroRouteCoordinates
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        // Nudge the centre slightly north so the plan card at the bottom doesn't crowd the course.
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2 + 0.012,
                                            longitude: (lons.min()! + lons.max()!) / 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            viewport = .camera(center: center, zoom: 11.6, pitch: 0)
        }
    }
    #endif

    private let distanceUnit: DistanceUnit = .auto
    private var plan: TrainingPlan? { profiles.first?.plan }
    /// Today's pending plan session, memoized behind a cheap signature — the map re-evaluates the
    /// body continuously while panning, and filtering the full session list (per-session calendar
    /// math, ×2 reads per eval) per frame is the exact anti-pattern the Plan board fixed. The token
    /// covers every way the answer changes: a regenerated plan (new id), sessions added/removed,
    /// a workout landing (completion credits the session), and the local day rolling over. Never
    /// serves a cached ref when the signature mismatches, so a cascade-deleted session is never read.
    private var pendingToday: PlannedSession? {
        pendingTodayToken == currentPendingToken ? cachedPendingToday : computePendingToday()
    }
    private var currentPendingToken: Int {
        var h = Hasher()
        h.combine(plan?.persistentModelID)
        h.combine(plan?.sessions.count ?? 0)
        h.combine(workouts.count)
        h.combine(Calendar.current.startOfDay(for: Date()))
        return h.finalize()
    }
    private func computePendingToday() -> PlannedSession? {
        PlanCoaching.todaySessions(plan, on: Date()).first { $0.status != .completed }
    }
    private func refreshPendingToday() {
        cachedPendingToday = computePendingToday()
        cachedPlanState = computePlanState()
        pendingTodayToken = currentPendingToken
    }

    /// One quiet line that keeps the deck honest about the plan when there's no session to start —
    /// the deck used to go silent on rest days and after the day's work, exactly when "what's next"
    /// is the question. Tap-through lands on the Plan tab.
    struct PlanStateLine: Equatable {
        let icon: String
        let text: String
    }
    private var planState: PlanStateLine? {
        pendingTodayToken == currentPendingToken ? cachedPlanState : computePlanState()
    }
    private func computePlanState() -> PlanStateLine? {
        guard plan != nil else { return nil }
        let today = PlanCoaching.todaySessions(plan, on: Date())
        if !today.isEmpty, today.allSatisfy({ $0.status == .completed }) {
            return PlanStateLine(icon: "checkmark.circle.fill",
                                 text: today.count == 1 ? "Today's session is done — nice work."
                                                        : "Today's sessions are done — nice work.")
        }
        guard today.isEmpty, let next = nextPlannedSession() else { return nil }
        let day = Calendar.current.isDateInTomorrow(next.date)
            ? "tomorrow" : next.date.formatted(.dateTime.weekday(.wide))
        return PlanStateLine(icon: "moon.zzz",
                             text: "Rest day — next up \(day): \(PlanCoaching.brief(for: next, distanceUnit: distanceUnit))")
    }
    /// The nearest upcoming planned session (within a week, not today) — the "next up" of a rest day.
    private func nextPlannedSession() -> PlannedSession? {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        guard let horizon = cal.date(byAdding: .day, value: 8, to: todayStart) else { return nil }
        return plan?.sessions
            .filter { $0.status != .completed && !cal.isDateInToday($0.date)
                      && $0.date > todayStart && $0.date < horizon }
            .min { $0.date < $1.date }
    }
    private var isCardio: Bool { activity.isGPS }
    private var unitLabel: String { distanceUnit.resolved() == .imperial ? "mi" : "km" }
    private var goalMeters: Double? {
        goalKind == .distance ? goalValue * (distanceUnit.resolved() == .imperial ? Formatters.metersPerMile : 1000) : nil
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Discipline-adaptive backdrop: a live map for cardio, a strength home for lifting — and
            // the *same* map for the world globe, so it zooms out continuously instead of being a
            // separate screen. Once the map has been shown it stays MOUNTED (hidden behind the
            // strength home) — tearing the engine down on a strength switch made returning to a
            // cardio sport re-download the style and repopulate tiles: seconds of blank map.
            let mapActive = isCardio || worldMode || loopMode || marketingHero
            if mapActive || mapWasShown {
                mapLayer.opacity(mapActive ? 1 : 0).allowsHitTesting(mapActive)
            }
            if !mapActive { strengthHome }
            if worldMode {
                worldTopChrome.transition(.opacity)
                worldBottomChrome.transition(.opacity)
            } else if loopMode {
                loopTopChrome.transition(.opacity)
                loopBottomPanel.transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                topBar.transition(.opacity)
                bottomPanel.transition(.opacity)
            }
        }
        .navigationBarHidden(true)
        .navigationDestination(item: $selectedAthlete) { AthleteProfileView(athlete: $0) }
        .onAppear {
            bootstrapIfNeeded()
            // AFTER bootstrap (its reconcile pass can move sessions): snapshot today's plan row so
            // body reads stay cheap. Every appear, so plan-tab edits show the moment you return.
            refreshPendingToday()
            // Refresh the Home Screen widget's snapshot whenever Today surfaces — the write is
            // change-guarded, so an identical snapshot never wakes the widget.
            WidgetBridge.publish(profile: profiles.first, workouts: workouts)
            if isCardio || worldMode || loopMode || marketingHero { mapWasShown = true }
            // Marketing hero frames the course in `.onStyleLoaded` (once tiles are ready). Return here
            // so the puck-follow / last-known camera logic below never steals the camera.
            if marketingHero { return }
            // Open over the athlete's last-known neighborhood (never the whole world); once a live fix
            // lands we switch to following the puck. We only *follow the puck* up front when location is
            // already granted — otherwise Mapbox would prompt on arrival, so we sit on a static camera
            // (last-known, else a neutral default) until they grant it via Start/recenter.
            if case .idle = viewport {
                if let coord = lastKnownCoordinate {
                    viewport = .camera(center: coord, zoom: 13.5, pitch: mapStyle.explorePitch)
                } else if locator.isAuthorized {
                    viewport = .followPuck(zoom: 14, pitch: mapStyle.explorePitch)
                } else {
                    viewport = Self.unlocatedViewport
                }
            }
            runAppearDeepLinks()
            // Never prompt for location on arrival — the map opens at the last-known neighborhood and
            // the GPS ask happens contextually (Start a run, or tap recenter). If they've already
            // granted it, just pull a fresh fix to center on them.
            if locator.isAuthorized { locator.refreshLocation() }
        }
        // A finished/deleted workout invalidates the caches and re-runs the coaching pass promptly.
        .onChange(of: workouts.count) { cachedStreak = nil; lastBootstrap = nil; bootstrapIfNeeded() }
        // Any signature change (new plan, session added/removed, workout landed, day rollover)
        // re-snapshots the deck's plan row.
        .onChange(of: currentPendingToken) { refreshPendingToday() }
        // The morning readout's number, computed off the render path (page-load-perf rule — the
        // Health reads are async and `RecoveryModel` folds a month of workouts). Recomputes when a
        // workout lands or today's check-in is answered. Banded `HealthBaselines` + the learned
        // sleep need/debt thread in with the Health-segment integration; until then the engine's
        // ratio fallbacks and defaults carry the score honestly (same banding either way).
        .task(id: "\(workouts.count)-\(checkins.count)") {
            await Task.yield()   // let the first frame paint before any engine work
            let signals = await services.health.recoverySignals()
            morningReadiness = MorningReadiness(load: RecoveryModel(workouts: workouts),
                                                signals: signals,
                                                checkin: DailyCheckin.today(in: checkins))
        }
        .onChange(of: activity) { if isCardio { mapWasShown = true } }
        // Follow the athlete's puck the moment a fix lands — but never while zoomed out to the globe,
        // and never while a suggested loop owns the frame (a late fix would yank the camera off it).
        .onChange(of: locator.lastLocation?.latitude) {
            if !worldMode, !marketingHero, !loopMode, locator.lastLocation != nil {
                withAnimation(Motion.standard) { viewport = .followPuck(zoom: 15, pitch: mapStyle.explorePitch) }
            }
        }
        // A persisted Pro style with no entitlement (lapse, restore on a new device) self-heals
        // back to the free default rather than rendering a locked look.
        .onAppear {
            if mapStyle.requiresPro, !services.paywall.isEntitled(to: .mapStyles) { mapStyle = .realistic }
        }
        // Re-tilt the camera when switching to/from 3D Satellite (and other layers reset it flat).
        // Never via followPuck without authorization — the puck viewport spins up Mapbox's location
        // provider, which would prompt for permission from a style change (the ask stays contextual:
        // Start or recenter, never a re-skin).
        .onChange(of: mapStyle) {
            if !worldMode, !marketingHero {
                // Re-tilting only makes sense over a place we can actually point at — an un-located
                // athlete keeps the flat world view rather than being tipped into a pitched globe.
                let target: Viewport
                if locator.isAuthorized {
                    target = .followPuck(zoom: 15, pitch: mapStyle.explorePitch)
                } else if let coord = lastKnownCoordinate {
                    target = .camera(center: coord, zoom: 13.5, pitch: mapStyle.explorePitch)
                } else {
                    target = Self.unlocatedViewport
                }
                withAnimation(Motion.standard) { viewport = target }
            }
        }
        // Frame the loop as soon as the first candidate streams in (and whenever the selection changes).
        .onChange(of: loopVM?.selectedID) { if loopMode { frameLoop() } }
        .workoutRunner(launch: $launch)
        .sheet(item: $confirmingPlan, onDismiss: {
            if let session = pendingPlanStart { pendingPlanStart = nil; startPlanned(session) }
        }) { session in
            planConfirmSheet(session)
        }
        .sheet(isPresented: $showSportPicker) {
            SportPicker(selection: $activity) { showSportPicker = false }
        }
        .sheet(isPresented: $showNotifications) { NotificationsView() }
        .sheet(isPresented: $showLogWorkout) { LogWorkoutView(initialType: activity) }
        .sheet(isPresented: $showLogActivity) {
            LogActivityView(initialDraft: logActivityDraft ?? "") { prefill in
                // Sheet swap: let the composer finish dismissing before the editor presents
                // (the same beat the deep links use — same-tick presentation misbehaves).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { manualPrefill = prefill }
            }
        }
        .sheet(item: $manualPrefill) { LogWorkoutView(prefill: $0) }
        .sheet(isPresented: $showInjuryReport) { InjuryReportSheet(profile: profiles.first) }
        .sheet(isPresented: $showCheckin) {
            CheckinSheet(profile: profiles.first) {
                // "Something hurts" routes straight into the injury loop.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showInjuryReport = true }
            }
        }
        .confirmationDialog("Feeling better?", isPresented: $confirmResume, titleVisibility: .visible) {
            Button("Yes — ease me back in") {
                if let profile = profiles.first {
                    _ = InjuryResponse.resume(profile: profile, in: context)
                    Haptics.success()
                }
            }
            Button("Not yet", role: .cancel) {}
        } message: {
            Text("We'll start with a short recovery run and easy miles — quality work returns once you're settled.")
        }
        // The profile opens as a FULL page pushed onto the tab's stack — a real destination with a
        // back chevron (ProfileScreen's own header), not a sheet (user call 2026-07-16; the sheet
        // read as a popup once Profile lost its tab to Fuel).
        .navigationDestination(isPresented: $showProfile) {
            ProfileScreen(showsBackButton: true)
        }
        // Spots is hidden; reachable via the `--spots` deep link. On dismiss, a "Loop here" choice
        // enters inline loop mode at that spot (transitioning to it on the same tick misbehaves).
        .sheet(isPresented: $showSpots, onDismiss: {
            if let point = pendingLoopStart { pendingLoopStart = nil; enterLoopMode(start: point) }
        }) {
            spotsSheet
        }
    }

    /// Real running/hiking spots nearby (hidden for now); "Loop here" hands a spot to the inline loop
    /// suggester once this sheet dismisses.
    @ViewBuilder
    private var spotsSheet: some View {
        if let origin = spotsOrigin {
            SpotsView(
                origin: origin,
                provider: services.spots,
                distanceUnit: distanceUnit,
                activity: activity.discipline == .walking ? .hike : .run,
                analytics: services.analytics,
                onLoopHere: { point in pendingLoopStart = point; showSpots = false },
                onClose: { showSpots = false })
        }
    }

    /// The expensive appear-time orchestration (plan reconciliation, reminders, inbox posts,
    /// sync, recovery adaptation). `onAppear` re-fires on EVERY tab switch and sheet dismissal —
    /// re-running all of this each time is why switching back to Today stuttered. It now runs when
    /// it matters: first arrival, a new local day, a workout-count change, or after minutes away.
    private func bootstrapIfNeeded() {
        let day = Calendar.current.startOfDay(for: Date())
        if let last = lastBootstrap, last.day == day,
           Date().timeIntervalSince(last.at) < 240 { return }
        lastBootstrap = (at: Date(), day: day)

        // Post-race continuation first: once race day has passed, the result recalibrates paces and
        // the plan rolls into a recovery-lead-in block — BEFORE reconcile could touch the old plan.
        if let p = profiles.first { PlanService.completeRace(for: p, today: Date(), in: context) }
        PlanCoaching.reconcileMissed(plan, today: Date(), in: context)
        // Keep next-workout reminders in sync with the (possibly moved) plan; asks for
        // notification permission on first run.
        services.notifications.schedulePlannedReminders(plan)
        // The rest of the notification taxonomy (PRD §24): the weekly recap nudge, and a gentle
        // streak-protection nudge when a real streak is at risk on a planned, not-yet-trained day.
        services.notifications.scheduleWeeklyCheckIn()
        let stats = ProfileStats(workouts: workouts, plan: profiles.first?.plan)
        cachedStreak = stats.currentStreak
        let plannedToday = !PlanCoaching.todaySessions(plan, on: Date()).isEmpty
        let workedOutToday = workouts.contains { Calendar.current.isDateInToday($0.startedAt) }
        services.notifications.scheduleStreakNudge(streak: stats.currentStreak,
                                                   isPlannedDayToday: plannedToday,
                                                   hasWorkedOutToday: workedOutToday)
        // Mirror the day's messages into the in-app inbox (the bell), deduped so they don't stack.
        if let s = PlanCoaching.todaySessions(plan, on: Date()).first {
            AppNotification.post(kind: .reminder, title: "Today's session is ready",
                                 body: PlanCoaching.brief(for: s), in: context, dedupeToken: "reminder-today")
        }
        AppNotification.post(kind: .system, title: "Welcome to momentum",
                             body: "Your plan is set. Tap Start whenever you're ready to move.",
                             in: context, dedupeToken: "welcome", daily: false)
        // The proactive coach: at most one seeded thought in the chat per pass (earned load bump,
        // Monday recap), badged on the coach button and mirrored to the bell. Deduped inside.
        CoachProactive.sweep(profile: profiles.first, workouts: workouts, in: context)
        // Pre-week load recheck (§11.1.1): if next week is PLANNED well above what the athlete has
        // ACTUALLY been absorbing (misses/pauses drift the two apart), seed one consent-gated trim.
        _ = CoachProactive.seedPlannedLoadRecheck(plan: profiles.first?.plan,
                                                  workouts: workouts, in: context)
        // Race week: the coach's briefing lands in the inbox for each of the final days (taper →
        // carb-load → kit → race-day fueling), each posted once.
        if let profile = profiles.first, let raceDate = profile.raceDate,
           let distanceM = profile.raceDistanceM, distanceM > 0,
           let daysOut = Calendar.current.dateComponents(
               [.day], from: Calendar.current.startOfDay(for: Date()),
               to: Calendar.current.startOfDay(for: raceDate)).day,
           let briefing = RaceBriefing.build(distanceM: distanceM,
                                             p5kSPerKm: plan?.p5kSPerKm ?? 0, daysOut: daysOut) {
            AppNotification.post(kind: .coaching, title: briefing.title, body: briefing.body,
                                 in: context, dedupeToken: "race-briefing-\(daysOut)", daily: false)
        }
        // Back up any never-synced workouts to the cloud (no-op until Supabase is configured).
        Task { await services.sync.sync(workouts, in: context) }
        // Recovery-driven adaptation (§8.1). The overtraining tripwire outranks the daily ease:
        // load in the danger zone + the body agreeing forces a real cutback week (throttled to
        // one/week); otherwise two warning signs just ease *today's* quality session.
        Task {
            let signals = await services.health.recoverySignals()
            let acwr = ProgressInsights(workouts: workouts).acwr
            if let cutback = RecoveryAdaptation.tripwire(acwr: acwr, signals: signals) {
                if RecoveryAdaptation.applyCutback(cutback, plan: plan, in: context) != nil { return }
            }
            let tier = PlanIntensity(rawValue: profiles.first?.planIntensity ?? "") ?? .balanced
            if let decision = RecoveryAdaptation.decide(signals: signals, intensity: tier,
                                                        checkin: DailyCheckin.today(in: checkins)) {
                _ = RecoveryAdaptation.applyToToday(decision, plan: plan, in: context)
            }
        }
    }

    /// DEBUG deep links for deterministic sim verification — cheap string checks, so these stay in
    /// every `onAppear` (unlike the throttled bootstrap above).
    private func runAppearDeepLinks() {
        #if DEBUG
        // --world deep link: let the map bind, then fly out to the globe (same path as the button).
        if worldMode {
            worldMode = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { enterWorld() }
        }
        // --spots deep link: open "Spots near you" straight away for deterministic sim verification.
        if ProcessInfo.processInfo.arguments.contains("--spots") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showSpots = true }
        }
        // --notifications: open the bell inbox for verification.
        if ProcessInfo.processInfo.arguments.contains("--notifications") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showNotifications = true }
        }
        if ProcessInfo.processInfo.arguments.contains("--today-profile") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showProfile = true }
        }
        if ProcessInfo.processInfo.arguments.contains("--sportpicker") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showSportPicker = true }
        }
        if ProcessInfo.processInfo.arguments.contains("--log-workout") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showLogWorkout = true }
        }
        if ProcessInfo.processInfo.arguments.contains("--log-activity") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showLogActivity = true }
        }
        // --log-activity-draft "<text>": open the composer pre-filled — the only way a screenshot
        // run can exercise the live receipt (simctl can't type).
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--log-activity-draft"), i + 1 < args.count {
            logActivityDraft = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showLogActivity = true }
        }
        if ProcessInfo.processInfo.arguments.contains("--injury-report") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showInjuryReport = true }
        }
        if ProcessInfo.processInfo.arguments.contains("--checkin") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showCheckin = true }
        }
        // --loop deep link: open the inline loop suggester straight away (deterministic verification).
        if ProcessInfo.processInfo.arguments.contains("--loop") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { enterLoopMode(start: nil) }
        }
        // --plan-confirm: open the confirm sheet for the next strength session (else today's
        // pending) — verifies the full-workout preview without tapping the plan row.
        if ProcessInfo.processInfo.arguments.contains("--plan-confirm") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let strength = plan?.sessions
                    .filter { $0.discipline == .strength && $0.status != .completed && !$0.strengthTargets.isEmpty }
                    .min(by: { $0.date < $1.date })
                if let target = strength ?? pendingToday { confirmingPlan = target }
            }
        }
        // --ui-test-structured-run: launch straight into a guided 6×400 m interval session so the
        // structured-workout flow (step banner + Skip advancement + cues) is drivable deterministically.
        if ProcessInfo.processInfo.arguments.contains("--ui-test-structured-run") {
            let variety = ProcessInfo.processInfo.arguments.contains("--ui-test-variety")
            let session = PlannedSession()
            session.discipline = .running
            session.runType = variety ? .hills : .intervals
            session.targetDistanceM = 3000
            session.targetPaceSPerKm = variety ? 380 : 300
            session.intervals = variety ? "8×45sec hills" : "6×400m @ 5K pace"
            session.date = Date()
            context.insert(session)   // inserted so post-run crediting behaves like a real plan session
            // 2 s, not 0.4: a cover presented inside the first-appear churn (map bind, bootstrap
            // sweeps, query invalidations) is silently dropped by SwiftUI — by 2 s Today has settled.
            // Only these launch deep-links race that window; a user's tap always lands after it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                launch = .cardio(type: .run, goalMeters: session.targetDistanceM, planned: session, guideRoute: [])
            }
        }
        // --live-run: straight into a free run (pair with --ui-test-route for a synthetic GPS feed) —
        // verifies the live screen and the lock-screen Live Activity without UI choreography.
        if ProcessInfo.processInfo.arguments.contains("--live-run") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                launch = .cardio(type: .run, goalMeters: nil, planned: nil, guideRoute: [])
            }
        }
        #endif
    }

    // MARK: Plan confirmation

    /// A calm confirmation before a planned session begins — review the prescription, then Start.
    /// Strength sessions list the ENTIRE workout (every exercise, sets × reps, suggested start
    /// weight) so the athlete sees exactly what's ahead before "Start lifting"; the sheet grows to
    /// fit and long sessions scroll inside it.
    private func planConfirmSheet(_ session: PlannedSession) -> some View {
        let exercises = session.strengthTargets.sorted { $0.order < $1.order }
        // A quality run's shape — warm-up / reps / recovery / cool-down — in the detail sheet's
        // row grammar. Strength always listed its whole prescription here while an interval day
        // showed one line; the athlete confirming "Start run" deserves the same full picture.
        let structure = StructuredWorkoutBuilder.build(from: session, p5kSPerKm: plan?.p5kSPerKm,
                                                       raceDistanceM: profiles.first?.raceDistanceM)?
            .summaryLines(distanceUnit: distanceUnit) ?? []
        let scrolls = !exercises.isEmpty || !structure.isEmpty
        return VStack(spacing: Theme.Space.lg) {
            if !scrolls { Spacer(minLength: 0) }
            ZStack {
                Circle().fill(IridescentMaterial()).opacity(0.3).frame(width: 72, height: 72)
                Image(systemName: PlanCoaching.icon(for: session))
                    .font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.ink)
            }
            VStack(spacing: Theme.Space.xs) {
                Text(planEyebrow)
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
                Text(planTitle(session))
                    .font(.display(28, weight: .black)).foregroundStyle(Theme.ink)
                Text(PlanCoaching.brief(for: session))
                    .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            if let rationale = session.rationale, !rationale.isEmpty {
                Text(rationale)
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            if !scrolls {
                Spacer(minLength: 0)
            } else {
                // The whole prescription, in the Plan detail sheet's row grammar — exercises with
                // sets × reps and a suggested opening weight, or a guided run's step breakdown.
                ScrollView {
                    VStack(spacing: Theme.Space.sm) {
                        ForEach(exercises, id: \.persistentModelID) { confirmExerciseRow($0) }
                        ForEach(Array(structure.enumerated()), id: \.offset) { _, line in
                            confirmStructureRow(line)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            VStack(spacing: Theme.Space.sm) {
                OversizedButton(title: planStartCTA(session)) {
                    pendingPlanStart = session
                    confirmingPlan = nil
                }
                Button("Not now") { confirmingPlan = nil }
                    .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            }
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity)
        .presentationDetents([.height(confirmSheetHeight(rowCount: exercises.count + structure.count,
                                                         hasRationale: !(session.rationale ?? "").isEmpty))])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
    }

    /// 380pt for the calm cardio confirm; prescription rows grow it (~66pt for a tall strength row,
    /// which bounds the run rows too), capped so a big session scrolls inside the sheet instead of
    /// swallowing the screen. A rationale line buys a little extra so it never squeezes the CTA.
    private func confirmSheetHeight(rowCount: Int, hasRationale: Bool) -> CGFloat {
        let base: CGFloat = hasRationale ? 420 : 380
        guard rowCount > 0 else { return base }
        return min(700, base + CGFloat(rowCount) * 66)
    }

    /// One structured-run step line — same content as SessionDetailSheet's Workout section rows.
    private func confirmStructureRow(_ line: (label: String, detail: String)) -> some View {
        HStack {
            Text(line.label).font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
            Spacer(minLength: Theme.Space.sm)
            Text(line.detail).font(.rounded(Theme.FontSize.caption, weight: .semibold))
                .monospacedDigit().foregroundStyle(Theme.inkSecondary)
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.chip).stroke(Theme.hairline)
        }
    }

    /// One prescribed exercise: name + suggested start weight on the left, sets × reps on the right
    /// (mirrors SessionDetailSheet's row so the prescription reads identically everywhere).
    private func confirmExerciseRow(_ ex: PlannedExercise) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(ex.exercise?.name ?? "Exercise")
                    .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if let w = StrengthSuggest.label(for: ex, profile: profiles.first) {
                    Text("Start \(w)")
                        .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            Text("\(ex.targetSets) × \(ex.targetRepLow)–\(ex.targetRepHigh)")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.chip).stroke(Theme.hairline)
        }
    }

    /// What marks a session as PLAN work wherever it surfaces — the plan's own name when the
    /// athlete gave it one ("AUSTIN MARATHON"), else the generic banner.
    private var planEyebrow: String {
        let name = plan?.name.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "TODAY'S PLAN" : name.uppercased()
    }

    private func planTitle(_ s: PlannedSession) -> String {
        // The precise sport wins when set — planned yoga/golf/swim roll up to a coaching DISCIPLINE
        // (strength/running) for analytics, but the confirm sheet must say what it actually is.
        // A plain run keeps its quality label; engine-prescribed sessions have no sportType.
        if let wt = s.workoutType {
            return wt == .run ? "\(s.runType?.rawValue.capitalized ?? "Easy") Run" : wt.title
        }
        if s.discipline == .strength { return s.strengthTargets.count >= 5 ? "Full Body" : "Strength" }
        switch s.discipline {
        case .running: return "\(s.runType?.rawValue.capitalized ?? "Easy") Run"
        case .cycling: return "Ride"
        case .walking: return "Walk"
        case .strength: return "Strength"
        }
    }

    private func planStartCTA(_ s: PlannedSession) -> String {
        // Same rule as the title: the precise sport wins ("Start lifting" for a planned yoga
        // session read wrong). Timed sports get the stopwatch's generic verb.
        if let wt = s.workoutType, !wt.isStrengthStyle, wt != .run {
            return wt.isTimed ? "Start session" : "Start \(wt.title.lowercased())"
        }
        switch s.discipline {
        case .strength: return "Start lifting"
        case .running: return "Start run"
        case .cycling: return "Start ride"
        case .walking: return "Start walk"
        }
    }

    // MARK: Map

    /// Best guess at where the athlete is before a live fix lands — a cached fix, else their most
    /// recent route's neighborhood — so the cardio map never opens on the whole world.
    private var lastKnownCoordinate: CLLocationCoordinate2D? {
        if let live = locator.lastLocation { return live }
        return workouts
            .sorted { $0.startedAt > $1.startedAt }
            .lazy
            .compactMap { $0.gps?.samples.first(where: { $0.accepted }) }
            .first
            .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    private var mapLayer: some View {
        MapReader { proxy in
        Map(viewport: $viewport) {
            // The purple location puck ("you") is configured imperatively in `.onStyleLoaded` below —
            // the SwiftUI `Puck2D` content force-unwraps a Mapbox bundled asset that fails to load on
            // some devices and hard-crashes (PuckType.makeDefault).
            // Zoomed out to the world: every athlete on Momentum as a glowing iridescent dot at their
            // (city-level, fuzzed) location. Tap one to open that athlete. Honest presence — the real
            // community only, no fabricated crowd. Gated on `mapShowsGlobe` (not `worldMode`) so the dots
            // aren't added/removed mid-fly — a map content change interrupts the camera animation.
            if mapShowsGlobe {
                CircleAnnotationGroup(communityAthletes) { athlete in
                    CircleAnnotation(centerCoordinate: CLLocationCoordinate2D(latitude: athlete.lat, longitude: athlete.lon))
                        .circleColor(StyleColor(UIColor(Theme.route)))
                        .circleRadius(6)
                        .circleBlur(0.6)
                        .circleStrokeColor(StyleColor(UIColor.white.withAlphaComponent(0.85)))
                        .circleStrokeWidth(1)
                        .onTapGesture { selectedAthlete = athlete }
                }
            }
            // Marketing hero (--marketing-hero): a real seeded run traced on the map — white casing
            // under the brand-purple line, exactly the app's route styling — for the website header.
            if marketingHero, heroRouteCoordinates.count > 1 {
                // Explicit RGB, not UIColor(Theme.route): Mapbox's StyleColor doesn't resolve a
                // dynamic asset colour and renders it near-black on the dark basemap. Bright
                // periwinkle (route dark-variant #D0D6FF) over a crisp white casing pops on any style.
                PolylineAnnotation(lineCoordinates: heroRouteCoordinates)
                    .lineColor(StyleColor(UIColor.white))
                    .lineWidth(13).lineJoin(.round)
                PolylineAnnotation(lineCoordinates: heroRouteCoordinates)
                    .lineColor(StyleColor(UIColor(red: 0.816, green: 0.839, blue: 1.0, alpha: 1)))
                    .lineWidth(7).lineJoin(.round)
            }
            // Inline loop suggester — draw the candidates right on the Today map. The unselected loops
            // are a faint hairline; the selected one wears the brand purple (matching the live puck),
            // over a white casing so it reads on any basemap.
            if loopMode, let vm = loopVM {
                PolylineAnnotationGroup(vm.candidates.filter { $0.id != vm.selectedID }) { loop in
                    PolylineAnnotation(lineCoordinates: loop.polyline.map(\.clCoordinate))
                        .lineColor(StyleColor(UIColor(Theme.inkTertiary.opacity(0.45))))
                        .lineWidth(4).lineJoin(.round)
                }
                if let sel = vm.selected {
                    PolylineAnnotation(lineCoordinates: sel.polyline.map(\.clCoordinate))
                        .lineColor(StyleColor(UIColor.white.withAlphaComponent(0.7)))
                        .lineWidth(11).lineJoin(.round)
                    PolylineAnnotation(lineCoordinates: sel.polyline.map(\.clCoordinate))
                        .lineColor(StyleColor(UIColor(Theme.route)))
                        .lineWidth(6).lineJoin(.round)
                }
            }
        }
        .mapStyle(activeMapboxStyle)
        .ornamentOptions(MapChrome.hidden)
        // Enabling the puck activates Mapbox's location provider, which prompts for permission — so we
        // only turn it on once the athlete has actually granted location (never up front on arrival).
        .onStyleLoaded { _ in
            #if DEBUG
            // The marathon hero owns the camera (frame the course) and shows no puck — a "you are
            // here" dot parked downtown only distracts from the course.
            if marketingHero { frameMarketingHero(); return }
            #endif
            if locator.isAuthorized { BrandPuck.apply(to: proxy) }
        }
        .onChange(of: locator.isAuthorized) { _, granted in if granted { BrandPuck.apply(to: proxy) } }
        .ignoresSafeArea()
        }
    }

    /// The globe wears Mapbox Standard — a vivid, *living* vector Earth: bright blue oceans, green/tan
    /// land, soft clouds and an atmospheric halo over black space (globe projection at low zoom). It's
    /// brighter and livelier than satellite imagery (whose oceans read dark). The one place we leave the
    /// monochrome basemap — a *world* view should feel alive. The street map keeps the chosen explore style.
    private var activeMapboxStyle: MapboxMaps.MapStyle {
        if mapShowsGlobe { return .standard }
        // Marketing hero in dark: the Standard *night* preset dims overlaid route annotations to
        // near-black. The flat Dark basemap renders the periwinkle route at full brightness, so the
        // hero's route pops — the website header's whole point. (Light mode is unaffected.)
        #if DEBUG
        if marketingHero, colorScheme == .dark { return .dark }
        #endif
        return mapStyle.mapboxStyle(for: colorScheme)
    }

    /// The strength "home" backdrop — shown instead of the map when Strength is the chosen activity,
    /// so lifting has its own identity (the brand orb + a quiet last-session readout), not a dead map.
    private var strengthHome: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            // A scroll view so the muscle map + last-session card always clear the floating header and
            // deck — nothing gets cut off, and a tall session just scrolls. The insets reserve the
            // space the header (top) and control deck (bottom) float over.
            ScrollView {
                VStack(spacing: Theme.Space.md) {
                    if activity.isStrengthStyle {
                        // The lifting identity: a body map glowing with the muscles from your last
                        // session (a quiet empty silhouette before your first lift), then the readout.
                        MuscleMapView(activation: lastStrengthActivation)
                            .frame(height: 236)
                            .frame(maxWidth: .infinity)
                        lastStrengthReadout
                    } else {
                        BrandMark(size: 124).padding(.top, Theme.Space.xl)   // timed sports show the brand mark
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.Space.lg)
                .padding(.top, 148)      // clear the floating header card
                .padding(.bottom, 220)   // clear the floating control deck
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var lastStrengthReadout: some View {
        if let last = lastStrength, let s = last.strength, !s.exercises.isEmpty {
            let unit = WeightUnit.default()
            let rows = s.exercises.sorted { $0.order < $1.order }
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("LAST SESSION · \(relativeDay(last.startedAt).uppercased())")
                    .font(.rounded(Theme.FontSize.label, weight: .bold))
                    .tracking(1.4).foregroundStyle(Theme.inkTertiary)
                ForEach(rows.prefix(4), id: \.persistentModelID) { row in
                    HStack {
                        Text(row.exercise?.name ?? "Exercise")
                            .font(.rounded(Theme.FontSize.body, weight: .semibold))
                            .foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer(minLength: Theme.Space.md)
                        Text(setSummary(row, unit: unit))
                            .font(.rounded(Theme.FontSize.caption, weight: .medium)).monospacedDigit()
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
                if rows.count > 4 {
                    Text("+\(rows.count - 4) more")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                }
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: 340)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
        } else {
            Text("Your first lift starts here.")
                .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
        }
    }

    /// "3 × 6 · 62 kg" — working sets × reps and the top weight (rep range shown if reps varied).
    private func setSummary(_ row: WorkoutExercise, unit: WeightUnit) -> String {
        let working = row.sets.filter { $0.isComplete && $0.type == .working }
        guard !working.isEmpty else { return "—" }
        let n = working.count
        let reps = working.compactMap(\.reps)
        let repText: String
        if let first = reps.first, reps.allSatisfy({ $0 == first }) { repText = "\(first)" }
        else if let lo = reps.min(), let hi = reps.max() { repText = "\(lo)–\(hi)" }
        else { repText = "" }
        let weight = working.compactMap(\.weightKg).max().map { " · \(Formatters.weight(kg: $0, unit: unit))" } ?? ""
        return repText.isEmpty ? "\(n) set\(n == 1 ? "" : "s")\(weight)" : "\(n) × \(repText)\(weight)"
    }

    private var lastStrength: Workout? {
        workouts.filter { $0.type.isStrengthStyle }.max(by: { $0.startedAt < $1.startedAt })
    }

    /// Muscles worked in the most recent strength session — drives the strength-home body map.
    /// Empty (a faint silhouette) before the athlete's first lift.
    private var lastStrengthActivation: [MuscleGroup: Double] {
        guard let session = lastStrength?.strength else { return [:] }
        return MuscleActivation.from(session: session)
    }

    private func relativeDay(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "today" }
        if cal.isDateInYesterday(date) { return "yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
        if days < 7 { return "\(days) days ago" }
        let weeks = days / 7
        return weeks == 1 ? "1 week ago" : "\(weeks) weeks ago"
    }

    private var topBar: some View {
        VStack {
            headerCard
            Spacer()
        }
    }

    /// A clean header card floating over the map (Runna-style): profile + notifications on the left, the
    /// live streak centered, the world on the right — and a week strip below that dots the days you
    /// train and marks today. The map shows through everywhere else.
    /// The floating header — individual glass elements over the map (the Apple Maps / AllTrails
    /// convention), not an opaque slab. Avatar + bell left, the sport pill center, streak right; the
    /// week lives with the plan in the deck, where data belongs.
    private var headerCard: some View {
        HStack(spacing: Theme.Space.sm) {
            AvatarView(photo: profiles.first?.avatarData, name: profiles.first?.displayName ?? "", size: 44)
                .background(Circle().fill(.regularMaterial).padding(-3))
                .mapSafeTap("Your profile") { Haptics.light(); showProfile = true }
            bellButton
            Spacer(minLength: Theme.Space.xs)
            activitySelector
            Spacer(minLength: Theme.Space.xs)
            coachButton
            StreakChip(days: cachedStreak ?? ProfileStats(workouts: workouts, plan: profiles.first?.plan).currentStreak)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.sm)
    }

    /// The coach, one tap from home — same glass circle language as the bell. Free to talk; plan
    /// changes gate on Pro at Apply time, inside the chat. A quiet dot marks a seeded thought
    /// (proactive proposal / weekly recap) the athlete hasn't seen yet.
    private var coachButton: some View {
        BrandMark(size: 26)
            .frame(width: 44, height: 44).momentumGlass(in: Circle())
            .overlay(alignment: .topTrailing) {
                if hasUnseenCoachNews {
                    Circle().fill(Theme.ink)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Theme.background, lineWidth: 1.5))
                        .offset(x: 1, y: -1)
                }
            }
            // The label stays STABLE ("Ask your coach") whatever the badge shows — a changing
            // label breaks element identity for assistive tech and UI tests alike; the unseen
            // news rides on the accessibility VALUE instead.
            .mapSafeTap("Ask your coach") {
                Haptics.light(); coach.open()
            }
            .accessibilityValue(hasUnseenCoachNews ? "New message waiting" : "")
    }

    /// A coach message landed after the chat was last on screen (proactive seeds arrive closed).
    private var hasUnseenCoachNews: Bool {
        (latestCoachMessage.first?.createdAt ?? .distantPast) > coach.lastSeenAt
    }

    private var unreadCount: Int { unreadNotifications.count }

    private var bellButton: some View {
        Image(systemName: "bell").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
            .frame(width: 44, height: 44).momentumGlass(in: Circle())
            .overlay(alignment: .topTrailing) {
                if unreadCount > 0 {
                    Text("\(min(unreadCount, 9))")
                        .font(.rounded(9, weight: .black)).foregroundStyle(Theme.background)
                        .frame(width: 17, height: 17)
                        .background(Circle().fill(Theme.ink))
                        .overlay(Circle().stroke(Theme.background, lineWidth: 1.5))
                        .offset(x: 3, y: -3)
                }
            }
            .mapSafeTap("Notifications\(unreadCount > 0 ? ", \(unreadCount) unread" : "")") {
                Haptics.light(); showNotifications = true
            }
    }



    /// A compact label for the header pill — the long enum titles ("Weight Training", "Mountain Bike
    /// Ride") would push the streak off the row, so the pill uses short forms.
    private var activityShortLabel: String {
        switch activity {
        case .strength: "Strength"
        case .mountainBikeRide: "MTB"
        case .eBikeRide: "E-Bike"
        case .gravelRide: "Gravel"
        case .trailRun: "Trail"
        default: activity.title
        }
    }

    private var activitySelector: some View {
        HStack(spacing: 6) {
            Image(systemName: activity.systemImage).font(.system(size: 15, weight: .bold))
            Text(activityShortLabel).font(.rounded(Theme.FontSize.body, weight: .bold)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
        }
        .fixedSize()
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.pillV)
        .momentumGlass()
        .mapSafeTap("Change activity — \(activityShortLabel) selected") {
            Haptics.light(); showSportPicker = true
        }
    }

    // MARK: Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: Theme.Space.sm) {
            if isCardio {
                HStack {
                    Spacer()
                    VStack(spacing: Theme.Space.sm) {
                        // No World/globe entry — the social layer is gone (2026-07-16); the picker
                        // is purely map styles. The globe machinery below stays back-burnered
                        // (reachable only via the DEBUG --world deep link).
                        MapLayersButton(style: $mapStyle,
                                        previewCenter: locator.lastCoordinate)
                        recenterButton
                    }
                }
            }
            deck
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.bottom, Theme.Space.sm)     // sit closer to the tab bar so more map shows
    }

    /// The control deck — ONE glass surface, not a stack of cards. Reads top-to-bottom as a single
    /// thought: today's plan (coaching) → goal (setting) → Start (the one hero) → discovery (explore).
    /// A single hairline divides the coaching context from the action zone; Start is the only filled
    /// element so the hierarchy never competes.
    /// The deck holds exactly three thoughts: today's plan, Start, and ONE quiet utility line
    /// (injury state ▸ morning check-in ▸ small actions — whichever matters right now). The week
    /// lives on the Plan tab; the free-run goal picker appears only when there's no plan to follow.
    private var deck: some View {
        VStack(spacing: 0) {
            if let session = pendingToday {
                planRow(session)
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                    .padding(.horizontal, Theme.Space.md)
            } else if let state = planState {
                planStateRow(state)
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                    .padding(.horizontal, Theme.Space.md)
            }
            VStack(spacing: Theme.Space.md) {
                if isCardio && pendingToday == nil { goalControl }
                HStack(spacing: Theme.Space.sm) {
                    logButton
                    OversizedButton(title: startTitle, systemImage: "play.fill") { startFree() }
                }
                utilityLine
                // Discovery chips (Suggest a loop / Spots) are HIDDEN for now — the loop quality isn't
                // good enough yet (lopsided, backtracking) and Spots is parked. All the code stays
                // (inline loop mode + `discoverChip` + `--loop`/`--spots` deep links); re-add a chip
                // here to bring either back once it's ready.
            }
            .padding(Theme.Space.md)
        }
        .momentumGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
    }

    /// One utility line under Start — whichever matters right now: an active injury (with the way
    /// back), the unanswered morning check-in, else the morning readout (readiness + its biggest
    /// driver, RECOVERY-HUB-PLAN §2 entry 2). Never more than one; the quiet actions remain only
    /// as the beat while the readout computes.
    @ViewBuilder
    private var utilityLine: some View {
        if profiles.first?.activeInjuryArea != nil {
            injuryBanner
        } else if DailyCheckin.today(in: checkins) == nil {
            checkinChip
        } else if let readout = morningReadiness {
            MorningReadinessLine(readiness: readout, adjustedToday: adaptedToday, onTap: openHealthSegment)
        } else {
            quietActionsRow
        }
    }

    /// A recovery adaptation (eased day / cutback week) recorded today — the readout wears the receipt.
    private var adaptedToday: Bool {
        coachingEvents.contains {
            ($0.kind == .ease || $0.kind == .recover) && Calendar.current.isDateInToday($0.date)
        }
    }

    /// Tap-through from the morning readout → Progress → Health. One-shot mailbox: RootView
    /// consumes the tab, ProgressScreen consumes the segment (RECOVERY-HUB-PLAN §2).
    private func openHealthSegment() {
        router.pendingProgressSegment = ProgressScreen.Segment.health.rawValue
        router.pendingTab = .progress
    }

    /// The offline half of the action row — for the workout that already happened (a lift, a
    /// treadmill run, anything untracked). Hairline-quiet by design: Start stays the deck's only
    /// filled element, so the hierarchy never competes.
    private var logButton: some View {
        Button {
            Haptics.light()
            showLogActivity = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil").font(.system(size: 15, weight: .semibold))
                Text("Log").font(.rounded(Theme.FontSize.body, weight: .semibold))
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 20)
            .frame(height: 56)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.inkTertiary.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Log a workout you already did")
    }

    /// The one quiet action beneath Start — tell the coach something hurts (the injury loop,
    /// ENDURANCE-FOCUS §8.2). Logging moved up beside Start as the deck's second action.
    private var quietActionsRow: some View {
        quietAction("bandage.fill", "Something hurts?", a11y: "Report a pain or injury — your plan adjusts") {
            showInjuryReport = true
        }
    }

    private func quietAction(_ icon: String, _ title: String, a11y: String, action: @escaping () -> Void) -> some View {
        Button { Haptics.light(); action() } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .bold))
                Text(title).font(.rounded(Theme.FontSize.caption, weight: .semibold))
            }
            .foregroundStyle(Theme.inkSecondary)
            .frame(maxWidth: .infinity).frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a11y)
    }

    /// The morning check-in nudge — one quiet line, gone the moment today's answered (or an injury is
    /// already active, which outranks it).
    @ViewBuilder
    private var checkinChip: some View {
        if DailyCheckin.today(in: checkins) == nil, profiles.first?.activeInjuryArea == nil {
            Button { Haptics.light(); showCheckin = true } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "sun.max.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("How are you feeling today?")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
                    Spacer(minLength: 0)
                    Text("10 sec").font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                }
                .padding(.horizontal, Theme.Space.md).padding(.vertical, 10)
                .background {
                    Capsule().fill(Theme.surface)
                    Capsule().stroke(Theme.hairline)
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Morning check-in — how are you feeling today? Takes ten seconds.")
        }
    }

    /// While an injury is active: the plan's protective state + the way back — "feeling better?" is the
    /// gate into the gentle return (InjuryResponse.resume). Empty when healthy.
    @ViewBuilder
    private var injuryBanner: some View {
        if let profile = profiles.first, let areaRaw = profile.activeInjuryArea,
           let area = InjuryArea(rawValue: areaRaw) {
            Button { Haptics.light(); confirmResume = true } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "bandage.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.purple)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Training around your \(area.label.lowercased())")
                            .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
                        Text("Feeling better? Tap to ease back in.")
                            .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                }
                .padding(.horizontal, Theme.Space.md).padding(.vertical, 10)
                .background {
                    Capsule().fill(Theme.purple.opacity(0.08))
                    Capsule().stroke(Theme.purple.opacity(0.25))
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Training around your \(area.label). Feeling better? Tap to ease back into running.")
        }
    }

    /// A small, soft secondary action — icon + short label, capsule, muted ink. Deliberately lighter
    /// than the Start hero so discovery reads as "or, explore…", not a competing primary button.
    private func discoverChip(_ title: String, icon: String, a11y: String, action: @escaping () -> Void) -> some View {
        Button { Haptics.light(); action() } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .bold))
                Text(title).font(.rounded(Theme.FontSize.caption, weight: .semibold))
            }
            .foregroundStyle(Theme.inkSecondary)
            .frame(maxWidth: .infinity).frame(height: 38)
            .background(Capsule().fill(Theme.surface))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a11y)
    }

    /// Where to look for spots: the live fix, else the athlete's last-known neighborhood. In DEBUG,
    /// `--spots` falls back to a fixed location so the sheet can be verified on the sim deterministically.
    private var spotsOrigin: GeoPoint? {
        if let loc = locator.lastLocation { return GeoPoint(lat: loc.latitude, lon: loc.longitude) }
        if let last = lastKnownCoordinate { return GeoPoint(lat: last.latitude, lon: last.longitude) }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--spots") { return GeoPoint(lat: 30.2672, lon: -97.7431) }
        #endif
        return nil
    }

    private var recenterButton: some View {
        Image(systemName: "location.fill")
            .font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
            .frame(width: 44, height: 44)
            .momentumGlass(in: Circle())
            .mapSafeTap("Recenter on my location") { recenterOnMe() }
    }

    /// Snap the camera back to the **live** location puck and resume following it — even after the
    /// athlete has panned the map away. Always prefers the live puck (where you actually are *now*),
    /// not the stale one-shot fix; if location isn't granted yet, ask and let the incoming fix center.
    private func recenterOnMe() {
        Haptics.light()
        locator.refreshLocation()
        guard locator.isAuthorized || locator.lastLocation != nil else {
            locator.requestAuthorization()   // not granted — prompt; the fix recenters via onChange
            return
        }
        let me: Viewport = .followPuck(zoom: 16, pitch: mapStyle.explorePitch)
        if reduceMotion { viewport = me }
        else { withViewportAnimation(.easeInOut(duration: 0.55)) { viewport = me } }
    }

    // MARK: Inline loop suggester (on the Today map)

    /// Enter loop mode right on the Today map — no separate page. Spins up a `RouteSuggestionViewModel`
    /// at the athlete's location (or a chosen spot), shows the controls immediately with a loading state,
    /// and fills the loops in as they route (fast: candidates route in parallel).
    private func enterLoopMode(start: GeoPoint?) {
        guard let origin = start ?? spotsOrigin else { locator.requestAuthorization(); return }
        Haptics.light()
        let vm = RouteSuggestionViewModel(start: origin, targetM: goalMeters ?? 5000, distanceUnit: distanceUnit)
        loopVM = vm
        withAnimation(Motion.standard) { loopMode = true }
        Task { await vm.suggest() }   // the map frames the loop when the first candidate arrives (onChange)
    }

    /// Leave loop mode and fly the camera back to the athlete.
    private func exitLoopMode() {
        Haptics.light()
        withAnimation(Motion.standard) { loopMode = false }
        let me = locator.lastLocation ?? lastKnownCoordinate
        let home: Viewport = me.map { .camera(center: $0, zoom: 15, pitch: mapStyle.explorePitch) }
            ?? .followPuck(zoom: 15, pitch: mapStyle.explorePitch)
        if reduceMotion { viewport = home }
        else { withViewportAnimation(.easeInOut(duration: 0.6)) { viewport = home } }
    }

    /// Frame the selected loop in view (leaving room for the bottom controls).
    private func frameLoop() {
        guard let loop = loopVM?.selected, loop.polyline.count > 1 else { return }
        let coords = loop.polyline.map(\.clCoordinate)
        let overview = Viewport.overview(geometry: LineString(coords),
                                         geometryPadding: EdgeInsets(top: 120, leading: 48, bottom: 300, trailing: 48))
        if reduceMotion { viewport = overview }
        else { withViewportAnimation(.easeInOut(duration: 0.6)) { viewport = overview } }
    }

    private func selectLoop(_ loop: SuggestedLoop) {
        Haptics.light()
        loopVM?.selectedID = loop.id   // frameLoop() runs via onChange(selectedID)
    }

    /// Floating top control: a back chip to leave loop mode (claims the tap over the live map).
    private var loopTopChrome: some View {
        VStack {
            HStack {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44).momentumGlass(in: Circle())
                    .contentShape(Circle())
                    .highPriorityGesture(TapGesture().onEnded { exitLoopMode() })
                    .accessibilityElement()
                    .accessibilityLabel("Close loop suggestions")
                    .accessibilityAddTraits(.isButton)
                Spacer()
                Text("Suggest a loop").font(.display(17, weight: .bold)).foregroundStyle(Theme.ink)
                    .shadow(color: Theme.background.opacity(0.8), radius: 6)
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(Theme.Space.md)
            Spacer()
        }
    }

    /// The loop controls, floating over the Today map: distance segmented control, then the candidate
    /// picker + stats + actions (or a loading / empty state).
    private var loopBottomPanel: some View {
        VStack(spacing: Theme.Space.md) {
            loopDistancePicker
            loopContent
        }
        .padding(Theme.Space.md)
        .momentumGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
        .padding(.horizontal, Theme.Space.md)
        .padding(.bottom, Theme.Space.sm)
    }

    private var loopDistancePicker: some View {
        HStack(spacing: 4) {
            ForEach([3000.0, 5000.0, 10000.0], id: \.self) { meters in
                let on = loopVM?.targetM == meters
                Button {
                    Haptics.selection()
                    Task { await loopVM?.setDistance(meters) }
                } label: {
                    Text("\(Int(meters / 1000))K")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .foregroundStyle(on ? Theme.background : Theme.inkSecondary)
                        .background(Capsule().fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Color.clear)))
                }
                .buttonStyle(.plain)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: on)
            }
        }
        .padding(4)
        .background(Capsule().fill(Theme.surface))
    }

    @ViewBuilder
    private var loopContent: some View {
        if let vm = loopVM {
            if vm.isLoading {
                HStack(spacing: Theme.Space.sm) {
                    ProgressView()
                    Text("Finding loops near you…")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                }
                .frame(maxWidth: .infinity).frame(height: 72)
            } else if vm.didFail {
                VStack(spacing: 4) {
                    Text("No loop found here").font(.display(16, weight: .bold)).foregroundStyle(Theme.ink)
                    Text("Try a different distance, or move to a more connected area.")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).frame(height: 72)
            } else if let sel = vm.selected {
                loopCandidatePicker(vm)
                HStack(alignment: .firstTextBaseline) {
                    Text(Formatters.distance(meters: sel.distanceM, unit: distanceUnit))
                        .font(.display(22, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
                    Text("DISTANCE").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1).foregroundStyle(Theme.inkTertiary)
                    Spacer()
                }
                HStack(spacing: Theme.Space.sm) {
                    Button {
                        Haptics.light(); Task { await vm.shuffle() }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    Button { useLoop(sel) } label: {
                        Label("Use this route", systemImage: "figure.run")
                            .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.ink))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// One pill per candidate loop — tap to highlight it on the map.
    private func loopCandidatePicker(_ vm: RouteSuggestionViewModel) -> some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach(Array(vm.candidates.enumerated()), id: \.element.id) { idx, loop in
                let on = loop.id == vm.selectedID
                Button { selectLoop(loop) } label: {
                    Text("Loop \(idx + 1)")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold))
                        .foregroundStyle(on ? Theme.background : Theme.inkSecondary)
                        .padding(.horizontal, Theme.Space.md).frame(height: 34)
                        .background(Capsule().fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.surface)))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private func useLoop(_ loop: SuggestedLoop) {
        Haptics.light()
        let route = loop.polyline
        let dist = loop.distanceM
        exitLoopMode()
        locator.requestAuthorization()
        launch = .cardio(type: activity, goalMeters: dist, planned: nil, guideRoute: route)
    }

    private var startTitle: String {
        activity.isStrengthStyle ? "Start workout" : "Start \(activity.title.lowercased())"
    }

    /// The coaching row at the top of the deck — what's prescribed today. The iridescent dot is the
    /// *earned* accent (this is the plan/progress). Tapping it opens the confirm-and-start sheet for
    /// the planned session; it's a slim row, not a competing CTA, so the Start hero below stays primary.
    private func planRow(_ session: PlannedSession) -> some View {
        Button { Haptics.light(); confirmingPlan = session } label: {
            HStack(spacing: Theme.Space.sm + 2) {
                ZStack {
                    Circle().fill(IridescentMaterial()).opacity(0.32).frame(width: 36, height: 36)
                    Image(systemName: PlanCoaching.icon(for: session))
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(planEyebrow).font(.rounded(Theme.FontSize.label, weight: .bold))
                        .tracking(1.4).foregroundStyle(Theme.inkTertiary)
                        .lineLimit(1)
                    Text(PlanCoaching.brief(for: session)).font(.rounded(Theme.FontSize.body, weight: .semibold))
                        .foregroundStyle(Theme.ink).lineLimit(1)
                    // The why, right on the deck — an eased/moved/rebuild session must never show
                    // its changed prescription without its one-line reason ("Eased today — poor
                    // sleep…"). The row grows only on mornings the coach actually did something.
                    if let why = session.rationale, !why.isEmpty {
                        Text(why).font(.rounded(Theme.FontSize.label, weight: .medium))
                            .foregroundStyle(Theme.inkTertiary).lineLimit(2)
                            .padding(.top, 1)
                    }
                    // Fuel at a glance, only when today's session is long enough to need it (≥1h) —
                    // the row grows a third line exactly on the mornings fueling matters. Tap-through
                    // lands on the session sheet, which carries the full before/during/after guidance.
                    if let fuel = planFuelLine(session) {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.purple)
                            Text(fuel).font(.rounded(Theme.FontSize.label, weight: .semibold))
                                .foregroundStyle(Theme.inkSecondary).lineLimit(1)
                        }
                        .padding(.top, 1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.inkTertiary)
            }
            .padding(Theme.Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The plan's one-line state when there is no session to start — "rest day, next up Thursday"
    /// or "today's done". Same slim grammar as `planRow`; tap lands on the Plan tab.
    private func planStateRow(_ state: PlanStateLine) -> some View {
        Button { Haptics.light(); router.pendingTab = .plan } label: {
            HStack(spacing: Theme.Space.sm + 2) {
                Image(systemName: state.icon)
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                    .frame(width: 36, height: 36)
                    .background { Circle().fill(Theme.surface); Circle().stroke(Theme.hairline) }
                Text(state.text)
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.inkTertiary)
            }
            .padding(Theme.Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.text)
    }

    /// "30–60 g carbs/hr · drink to thirst" — today's fuel line, from the same deterministic
    /// `FuelingGuide` gate as the session sheet (running, ≥1h estimated). nil on shorter days so
    /// the plan row stays slim except when fueling actually matters. Fueling, not dieting.
    private func planFuelLine(_ session: PlannedSession) -> String? {
        guard session.discipline == .running,
              let dur = FuelingGuide.estimatedDurationS(distanceM: session.targetDistanceM,
                                                        paceSPerKm: session.targetPaceSPerKm,
                                                        durationS: session.targetDurationS) else { return nil }
        let g = FuelingGuide.guidance(durationS: dur, isRace: session.runType == .race)
        guard let carbs = g.carbsPerHour else { return nil }
        return "\(carbs.lowerBound)–\(carbs.upperBound) g carbs/hr · drink to thirst"
    }

    private var goalControl: some View {
        VStack(spacing: Theme.Space.md) {
            // iOS-native segmented look: a light track with a white "thumb" on the selected option.
            // Deliberately NOT a black fill — Start is the only filled element, so it stays the hero.
            HStack(spacing: 0) {
                goalSegment(.open, "Open")
                goalSegment(.distance, "Distance")
            }
            .padding(3)
            .background(Capsule().fill(Theme.surface))
            if goalKind == .distance {
                // Compact, confident stepper — big tabular numeral with the unit set inline beside it.
                HStack(spacing: Theme.Space.lg) {
                    stepperButton("minus") { goalValue = max(0.5, goalValue - 0.5) }
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(goalValue.formatted(.number.precision(.fractionLength(goalValue == goalValue.rounded() ? 0 : 1))))
                            .font(.display(30, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                            .contentTransition(.numericText())
                        Text(unitLabel.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold))
                            .tracking(1).foregroundStyle(Theme.inkTertiary)
                    }
                    .frame(minWidth: 104)
                    stepperButton("plus") { goalValue += 0.5 }
                }
                .animation(.snappy(duration: 0.2), value: goalValue)
            }
        }
    }

    private func goalSegment(_ kind: GoalKind, _ title: String) -> some View {
        let on = goalKind == kind
        return Button { Haptics.selection(); goalKind = kind } label: {
            Text(title)
                .font(.rounded(Theme.FontSize.caption, weight: .bold))
                .frame(maxWidth: .infinity).frame(height: 32)
                .foregroundStyle(on ? Theme.ink : Theme.inkSecondary)
                .background {
                    if on {
                        Capsule().fill(Theme.background)
                            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: on)
    }

    private func stepperButton(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.light(); action() } label: {
            Image(systemName: system).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44).background(Circle().fill(Theme.surface))
        }.buttonStyle(.plain)
    }

    // MARK: World globe (the Today map zoomed out)

    /// Community back-burnered from v1 (2026-07-16): the globe stays — a beautiful zoom-out of
    /// YOUR world — but the seeded community pins are gone with the rest of the social layer.
    /// Restore `CommunityDirectory.all()` (moderation-filtered) when community returns.
    private var communityAthletes: [CommunityAthlete] { [] }
    private var onMap: Bool { profiles.first?.appearOnMap ?? false }

    /// Slide the cards away and fly the camera from the street all the way out to the globe. Mapbox's
    /// native `.fly` runs the cinematic zoom-out → arc → settle, so the planet eases into frame instead
    /// of a flat linear zoom.
    private func enterWorld() {
        Haptics.light()
        let target = lastKnownCoordinate ?? CLLocationCoordinate2D(latitude: 20, longitude: 0)
        let globe = Viewport.camera(center: target, zoom: 1.3, pitch: 0)
        withAnimation(Motion.reversible) { worldMode = true }
        mapShowsGlobe = true   // satellite earth; set before the fly so it's loaded as we pull back
        if reduceMotion {
            viewport = globe
        } else {
            withViewportAnimation(.fly(duration: 2.4)) { viewport = globe }
        }
        Task { liveCount = await services.presence.refresh(appearOnMap: onMap) }
    }

    /// Fly back in to the user's position and bring the cards back. The basemap stays on the satellite
    /// style for the whole fly (swapping it mid-animation cancels the fly), then crossfades to the
    /// street style once the camera has settled.
    private func exitWorld() {
        Haptics.light()
        // Target the user's position — the live puck if we have a fix, else their last workout's
        // neighborhood — so the camera reliably leaves the globe (followPuck alone does nothing without
        // a live location).
        let me = locator.lastLocation ?? lastKnownCoordinate
        let home: Viewport = me.map { .camera(center: $0, zoom: 15, pitch: mapStyle.explorePitch) }
            ?? .followPuck(zoom: 15, pitch: mapStyle.explorePitch)
        withAnimation(Motion.reversible) { worldMode = false }
        if reduceMotion {
            viewport = home
            mapShowsGlobe = false
        } else {
            let fly = 1.8
            withViewportAnimation(.fly(duration: fly)) { viewport = home }
            // Swap satellite → street only after the camera lands, so the fly is never interrupted.
            DispatchQueue.main.asyncAfter(deadline: .now() + fly) {
                guard !worldMode else { return }   // didn't re-enter the globe meanwhile
                withAnimation(.easeInOut(duration: 0.4)) { mapShowsGlobe = false }
            }
        }
    }

    /// Top chrome over the globe: a back-to-Today control + the honest community header. White ink with
    /// a soft shadow, legible over the realistic satellite globe and its dark space backdrop.
    private var worldTopChrome: some View {
        VStack {
            HStack(alignment: .top) {
                exitButton
                Spacer()
            }
            .padding(Theme.Space.md)
            Spacer()
        }
        .overlay(alignment: .top) { worldHeader }
    }

    /// The "back to Today" control. A live Mapbox map's tap recognizer wins the gesture race against a
    /// plain SwiftUI `Button`, so this uses a solid hit shape + `highPriorityGesture` to claim the tap.
    private var exitButton: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
            .frame(width: 46, height: 46)
            .background(Circle().fill(.black.opacity(0.45)))
            .overlay(Circle().stroke(.white.opacity(0.35)))
            .shadow(color: .black.opacity(0.4), radius: 6, y: 1)
            .contentShape(Circle())
            .highPriorityGesture(TapGesture().onEnded { exitWorld() })
            .accessibilityElement()
            .accessibilityLabel("Back to Today")
            .accessibilityAddTraits(.isButton)
    }

    private var worldHeader: some View {
        VStack(spacing: 2) {
            Text("Around the world").font(.display(24, weight: .black)).foregroundStyle(.white)
            if let subtitle = worldSubtitle {
                Text(subtitle)
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 8, y: 1)   // legible over the bright/dark globe
        .padding(.top, Theme.Space.sm)
        .allowsHitTesting(false)
    }

    /// Honest presence only — never a fabricated crowd, and never a sad "0 in the community" while
    /// the community layer is back-burnered. No real numbers → no subtitle at all.
    private var worldSubtitle: String? {
        let count = communityAthletes.count
        if count > 0 {
            let base = "\(count) in the Momentum community"
            return liveCount > 0 ? "\(base) · \(liveCount) live now" : base
        }
        return liveCount > 0 ? "\(liveCount) live now" : nil
    }

    /// Bottom chrome over the globe: legend + the "appear on the map" opt-in (off by default).
    private var worldBottomChrome: some View {
        VStack(spacing: Theme.Space.md) {
            // The dot legend only makes sense when there are dots (community is back-burnered).
            if !communityAthletes.isEmpty {
                HStack(spacing: Theme.Space.sm) {
                    Circle().fill(Theme.route).frame(width: 8, height: 8)
                    Text("Community").font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    Spacer(minLength: 0)
                }
            }
            worldOptInRow
        }
        .padding(Theme.Space.lg)
        .padding(.bottom, Theme.Space.lg)
        .frame(maxWidth: .infinity)
        // Fade to deep space so the chrome reads over the satellite globe (not a white wash over it).
        .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
    }

    @ViewBuilder
    private var worldOptInRow: some View {
        if onMap {
            Label("You're on the map", systemImage: "checkmark.circle.fill")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Button {
                profiles.first?.appearOnMap = true; try? context.save(); Haptics.light()
            } label: {
                Label("Appear on the map", systemImage: "mappin.and.ellipse")
                    .font(.rounded(Theme.FontSize.body, weight: .bold))
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .foregroundStyle(Theme.background)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.ink))
            }
            .buttonStyle(.plain)
            .disabled(profiles.first == nil)
            .accessibilityHint("Show as a fuzzed dot. Never your exact location.")
        }
    }

    // MARK: Launch

    private func startFree() {
        if activity.isStrengthStyle { launch = .strength(type: activity, planned: nil) }
        else if activity.isTimed { launch = .timed(type: activity) }
        else {
            locator.requestAuthorization()   // ask for GPS exactly when they Start — never up front
            launch = .cardio(type: activity, goalMeters: goalMeters, planned: nil, guideRoute: [])
        }
    }

    private func startPlanned(_ session: PlannedSession) {
        // Use the session's precise sport (swim/yoga/row…) when set; fall back to the discipline bucket.
        let t = session.workoutType ?? workoutType(for: session.discipline)
        if t.isStrengthStyle { launch = .strength(type: t, planned: session) }
        else if t.isTimed { launch = .timed(type: t) }
        else {
            locator.requestAuthorization()
            launch = .cardio(type: t, goalMeters: session.targetDistanceM, planned: session, guideRoute: [])
        }
    }

    private func workoutType(for d: Discipline) -> WorkoutType {
        switch d { case .strength: .strength; case .cycling: .ride; case .walking: .walk; case .running: .run }
    }

}

// MARK: - Launch + presentation wrappers

enum TodayLaunch: Identifiable {
    case cardio(type: WorkoutType, goalMeters: Double?, planned: PlannedSession?, guideRoute: [GeoPoint])
    case strength(type: WorkoutType, planned: PlannedSession?)
    case timed(type: WorkoutType)
    var id: String {
        switch self {
        case let .cardio(t, _, p, _): "c-\(t.rawValue)-\(p?.id.uuidString ?? "free")"
        case let .strength(t, p): "s-\(t.rawValue)-\(p?.id.uuidString ?? "free")"
        case let .timed(t): "t-\(t.rawValue)"
        }
    }
}

struct PresentedWorkout: Identifiable { let id: UUID; let type: WorkoutType }

/// A streak chip — a clean monochrome pill: flame glyph + day count. Static and restrained (the earned
/// celebration lives on the finish/summary screen, not this passive header chip).
struct StreakChip: View {
    let days: Int

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "flame.fill").font(.system(size: 13, weight: .semibold))
            Text("\(days)").font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit()
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, Theme.Space.md).padding(.vertical, 12)
        .momentumGlass()
        .accessibilityLabel("Streak")
        .accessibilityValue("\(days) days")
    }
}

/// Today's morning readout (RECOVERY-HUB-PLAN §2 entry 2, §5) — the deck's utility line once the
/// check-in is answered: a 44pt mini readiness ring, the score, the band word, and the single
/// biggest driver in plain words. When the plan adapted this morning, a hairline footer carries the
/// receipt. Mint is the readiness ink (§6, `Theme.Health`); iridescence stays EARNED — the ring fill
/// renders iridescent only at `.primed` (≥ 80, the engine's cut). The ring draws itself via `trim`
/// (transform-only); Reduce Motion renders it complete and the iridescence static.
struct MorningReadinessLine: View {
    let readiness: MorningReadiness
    var adjustedToday = false
    var onTap: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    private var progress: Double { drawn ? Double(readiness.score) / 100 : 0 }

    var body: some View {
        Button { Haptics.light(); onTap() } label: {
            VStack(spacing: Theme.Space.sm) {
                HStack(spacing: Theme.Space.sm + 2) {
                    miniRing
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(readiness.score)")
                                .font(.display(20, weight: .black)).monospacedDigit()
                                .foregroundStyle(Theme.ink)
                            Text(readiness.band.rawValue)
                                .font(.rounded(Theme.FontSize.caption, weight: .bold))
                                .foregroundStyle(Theme.inkSecondary)
                        }
                        Text(driver)
                            .font(.rounded(Theme.FontSize.caption, weight: .medium))
                            .foregroundStyle(Theme.inkTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                }
                if adjustedToday {
                    VStack(spacing: 6) {
                        Rectangle().fill(Theme.hairline).frame(height: 0.5)
                        Text("Today adjusted — tap to see why.")
                            .font(.rounded(Theme.FontSize.label, weight: .semibold))
                            .foregroundStyle(Theme.inkTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear {
            if reduceMotion { drawn = true }
            else { withAnimation(Motion.pen(0.9)) { drawn = true } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel)
        .accessibilityAddTraits(.isButton)
    }

    /// Track = the readiness pastel at ring-track level (§6: tracks 20–25%); fill = mint ink,
    /// going iridescent only when the band is earned-`primed`.
    private var miniRing: some View {
        ZStack {
            Circle().stroke(Theme.Health.recoveryWash.opacity(0.22), lineWidth: 4.5)
            if readiness.band == .primed {
                IridescentView(intensity: 0.95).mask { ringArc }
            } else {
                ringArc.foregroundStyle(Theme.Health.recoveryInk)
            }
        }
        .frame(width: 44, height: 44)
    }

    private var ringArc: some View {
        Circle()
            .trim(from: 0, to: max(0.0001, min(1, progress)))
            .stroke(style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }

    /// The single biggest driver in plain words — the pillar with the largest |points| (the pillar
    /// points sum to `blend − 50`, so the max is honestly "what moved the score most"). No-shame
    /// voice: states the signal, never scolds.
    private var driver: String {
        guard let top = readiness.pillars.max(by: { abs($0.points) < abs($1.points) }),
              abs(top.points) >= 1 else {
            return "Signals steady — an ordinary day"
        }
        let up = top.points >= 0
        return switch top.kind {
        case .load:      up ? "Training load well absorbed" : "The last few days are still in your legs"
        case .hrv:       up ? "HRV above your norm" : "HRV below your norm"
        case .sleep:     up ? "A solid night's sleep" : "A short night"
        case .restingHR: up ? "Resting HR right at its norm" : "Resting HR above your norm"
        case .checkin:   up ? "You're feeling good today" : "You said today feels heavy"
        }
    }

    private var a11yLabel: String {
        var label = "Readiness \(readiness.score), \(readiness.band.rawValue). \(driver)."
        if adjustedToday { label += " Today's plan was adjusted — tap to see why." }
        return label
    }
}

/// A soft iridescent fill for accents — static, low-opacity.
struct IridescentMaterial: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        LinearGradient(colors: Theme.iridescent, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
