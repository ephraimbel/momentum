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
    @Environment(ModerationStore.self) private var moderation   // globe dots honor blocks (community)
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
    @State private var activity: WorkoutType = {
        #if DEBUG
        // --today-sport <raw> opens on any sport (face verification: tennis badge, unlocated
        // cardio, …); --ui-test-strength remains the strength shorthand the UI tests use.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--today-sport"), args.indices.contains(i + 1),
           let sport = WorkoutType(rawValue: args[i + 1]) { return sport }
        #endif
        return debugFlag("--ui-test-strength") ? .strength : .run
    }()
    /// Set the moment the athlete picks a sport themselves. Until then the picker follows today's
    /// plan; afterwards it stays where they put it for the rest of the session.
    @State private var pickerIsAthletesChoice = false
    @State private var goalKind: GoalKind = .open
    @State private var goalValue = 3.0
    @State private var viewport: Viewport = .idle
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
    @State private var pendingTreadmillLog: PlannedSession? // log indoors after the confirm sheet dismisses
    // The athlete's app-wide base-map choice — persists across launches and stays in sync with every
    // other map surface (run screen, heatmap). Realistic (Mapbox Standard 3D) is the default.
    @AppStorage(MapStyleOption.storageKey) private var mapStyle: MapStyleOption = .realistic
    @State private var showNotifications = false
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
    @State private var showLifeHappens = false
    /// The morning readout for the deck's utility line — one honest 0–100, computed off-render.
    @State private var morningReadiness: MorningReadiness?
    /// Throttles the appear-time orchestration — `onAppear` re-fires on every tab switch.
    @State private var lastBootstrap: (at: Date, day: Date)?
    /// True once the map backdrop has been mounted — it then stays warm for the session (a
    /// strength-only athlete who never shows the map never pays for it).
    @State private var mapWasShown = false
    /// True once the basemap style has actually loaded. Until then the map renders at opacity 0
    /// over the app background — the first frames of a cold launch used to be whatever Mapbox
    /// paints while the style downloads, with the glass chrome already floating on top of it.
    @State private var mapStyleReady = false
    /// Frame-morphs the Start control between the deck and the collapsed peek, so collapsing
    /// reads as ONE button traveling rather than two buttons trading places.
    @Namespace private var startMorph
    // The deck collapses so the map can have the whole screen. Remembered across launches: an
    // athlete who wants the map uninterrupted shouldn't have to say so every morning.
    @AppStorage("todayDeckCollapsed") private var deckCollapsed = false
    /// The deck's own measured height — the exact distance it must travel to clear the screen.
    @State private var deckHeight: CGFloat = 0
    /// The collapsed pill's height, so the map controls can rest just above it.
    @State private var peekHeight: CGFloat = 0
    /// The strength home's muscle map animates only while visible (see its visibility gate).
    @State private var strengthMapOnScreen = true
    /// The newest GPS fix from history, memoized (non-observed box, invisible to SwiftUI): the raw
    /// form sorted the whole workout table AND faulted a run's thousands of `LocationSample` rows
    /// on every body evaluation — and the map re-evaluates body constantly while panning.
    private final class HistoryFixMemo {
        var count = -1
        var coord: CLLocationCoordinate2D?
    }
    @State private var historyFixMemo = HistoryFixMemo()
    /// The globe's athlete dots, snapshotted when world mode opens — the directory filter ran
    /// ~3× per render (annotations + subtitle + legend) through the whole ~950-entry list while
    /// the camera was mid-flight.
    @State private var globeDots: [CommunityAthlete] = []
    /// "A recovery adaptation landed today", memoized per (events, day) — the raw `contains` did
    /// per-element calendar math over the whole CoachingEvent table on every readout render.
    private final class AdaptedTodayMemo {
        var key: Int = .min
        var value = false
    }
    @State private var adaptedTodayMemo = AdaptedTodayMemo()
    /// Today's pending plan session, memoized for the same reason (see `pendingToday`).
    @State private var cachedPendingToday: PlannedSession?
    @State private var pendingTodayToken: Int = 0
    /// The strength home's memoized reads — see `lastStrength`.
    @State private var cachedLastStrength: Workout?
    @State private var cachedLastActivation: [MuscleGroup: Double] = [:]
    @State private var strengthMemoToken: Int = 0
    /// The deck's plan story when nothing is left to start — "today's done" or "rest day, next up
    /// Thursday". Cached beside `cachedPendingToday` (same invalidation token) because the deck body
    /// re-evaluates per frame while the map pans, and filtering the full session list per frame is
    /// the exact anti-pattern the memoized plan row exists to avoid.
    @State private var cachedPlanState: PlanStateLine?
    @State private var confirmResume = false
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
            // The map leads only when it has SOMEWHERE to stand — a live fix, granted permission,
            // or the athlete's own GPS history. A brand-new install with location undecided used
            // to fall back to a zoom-3 world camera, which read as "the globe randomly popped up"
            // on every cardio sport (owner report 2026-07-30, first seen on e-bike). Until a
            // location exists, the sport home leads; Start asks for location contextually and the
            // map takes over the moment it can center.
            let mapActive = (isCardio && canCenterMap) || worldMode || marketingHero
            // Always something painted behind the map: it holds the first frames while the style
            // loads (the map fades in over it via `mapStyleReady`) instead of a raw engine flash.
            Theme.background.ignoresSafeArea()
            if mapActive || mapWasShown {
                mapLayer.opacity(mapActive && mapStyleReady ? 1 : 0).allowsHitTesting(mapActive)
                    .animation(Motion.standard, value: mapStyleReady)
                    .animation(Motion.standard, value: mapActive)
            }
            if !mapActive { strengthHome }
            if worldMode {
                worldTopChrome.transition(.opacity)
                worldBottomChrome.transition(.opacity)
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
            refreshStrengthMemo()
            matchPickerToTodaysPlan()
            #if DEBUG
            if debugFlag("--sport-picker") { showSportPicker = true }   // picker face verification
            #endif
            if isCardio || worldMode || marketingHero { mapWasShown = true }
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
        .onChange(of: workouts.count) { lastBootstrap = nil; bootstrapIfNeeded() }
        // Any signature change (new plan, session added/removed, workout landed, day rollover)
        // re-snapshots the deck's plan row.
        .onChange(of: currentPendingToken) { refreshPendingToday() }
        .onChange(of: currentStrengthToken) { refreshStrengthMemo() }
        // The morning readout's number, computed off the render path (page-load-perf rule — the
        // Health reads are async and `RecoveryModel` folds a month of workouts). Recomputes when a
        // workout lands or today's check-in is answered. `ReadinessToday` is the ONE full-blend
        // recipe (banded baselines + learned sleep need/debt) shared with the Health hub — the
        // deck's ring and the hub's hero can never read different numbers. Publishing keeps the
        // Trends strip on the same score before the hub's first visit.
        // The published cache score joins the id: when another surface (the Health hub, after a
        // late sleep/HRV backfill) recomputes and republishes a DIFFERENT number, this task
        // re-fires and the deck re-reads the fresh signals — otherwise Today held its 7am score
        // while Progress showed the 9am one, the exact split-number the one-recipe work killed.
        .task(id: "\(workouts.count)-\(checkins.count)-\(ReadinessTodayCache.today()?.score ?? -1)") {
            // A real pause, not `Task.yield()` — a single suspension hop resumed before the first
            // frame finished, so the month-of-workouts RecoveryModel fold and 60 days of Health
            // reads still landed under Mapbox's tile load (perf audit 2026-08-13). Cancellation on
            // a mid-sleep re-fire (or tab switch) exits before any engine work runs.
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            let r = await ReadinessToday.compute(health: services.health,
                                                 workouts: workouts, checkins: checkins)
            morningReadiness = r
            if let r { ReadinessToday.publish(r) }
        }
        .onChange(of: activity) { if isCardio { mapWasShown = true } }
        // Follow the athlete's puck the moment a fix lands — but never while zoomed out to the globe.
        .onChange(of: locator.lastLocation?.latitude) {
            if !worldMode, !marketingHero, locator.lastLocation != nil {
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
        // The recorder itself is no longer attached here: launch state lives on
        // `router.workoutLaunch` and the ONE `WorkoutRunner` overlay is mounted above the whole
        // tab shell in `RootView` (shared-map pass 2026-08-19) — Today and Plan write the same
        // mailbox and the run crossfades up over whatever tab started it.
        .sheet(item: $confirmingPlan, onDismiss: {
            if let session = pendingPlanStart { pendingPlanStart = nil; startPlanned(session) }
            // Ran it indoors → open the quick log pre-filled with today's prescription (reuses the
            // manual-log presentation). Sequenced through onDismiss so we never stack two sheets.
            if let session = pendingTreadmillLog { pendingTreadmillLog = nil; manualPrefill = treadmillPrefill(session) }
        }) { session in
            planConfirmSheet(session)
        }
        .sheet(isPresented: $showSportPicker) {
            // Picking a sport by hand is a deliberate choice — from here on, today's plan stops
            // moving the picker (see `matchPickerToTodaysPlan`).
            SportPicker(selection: Binding(get: { activity },
                                           set: { activity = $0; pickerIsAthletesChoice = true })) {
                showSportPicker = false
            }
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
            CheckinSheet(profile: profiles.first, onPain: {
                // "Something hurts" routes straight into the injury loop.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showInjuryReport = true }
            }, onLife: {
                // "Life's in the way" routes into the pause/ease sheet.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showLifeHappens = true }
            })
        }
        .sheet(isPresented: $showLifeHappens) { LifeHappensSheet(profile: profiles.first) }
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
        // No profile destination lives here any more: the header avatar SELECTS the Profile tab
        // (see `headerCard`). A push would be a second instance of the same screen, and that is
        // what cost it the Community slider.
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
        // These two stay SYNCHRONOUS: `refreshPendingToday` runs right after this and must see the
        // reconciled plan, or the deck's row shows a session that has already been moved.
        if let p = profiles.first { PlanService.completeRace(for: p, today: Date(), in: context) }
        PlanCoaching.reconcileMissed(plan, today: Date(), in: context)
        // Everything below is observational (notifications, widget snapshot, inbox posts, proactive
        // coach, cloud sync, Health import, recovery adaptation) — nothing on screen waits for it,
        // and running it inline made the first Today frame pay a full ProfileStats history walk plus
        // three notification-scheduling passes while Mapbox was loading (perf audit 2026-08-13).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            // Keep next-workout reminders in sync with the (possibly moved) plan; asks for
            // notification permission on first run.
            services.notifications.schedulePlannedReminders(plan)
            // The rest of the notification taxonomy (PRD §24): the weekly recap nudge, and a gentle
            // streak-protection nudge when a real streak is at risk on a planned, not-yet-trained day.
            services.notifications.scheduleWeeklyCheckIn()
            let stats = ProfileStats(workouts: workouts, plan: profiles.first?.plan)
            // One `todaySessions` pass for the whole bootstrap (it filters the full session list).
            let sessionsToday = PlanCoaching.todaySessions(plan, on: Date())
            let workedOutToday = workouts.contains { Calendar.current.isDateInToday($0.startedAt) }
            services.notifications.scheduleStreakNudge(streak: stats.currentStreak,
                                                       isPlannedDayToday: !sessionsToday.isEmpty,
                                                       hasWorkedOutToday: workedOutToday)
            // The Home Screen widget snapshot rides the throttled pass. The write is change-guarded,
            // so an identical snapshot never wakes the widget. Reuses this pass's `stats` — the
            // bridge used to run its own full-history ProfileStats walk back-to-back with ours.
            WidgetBridge.publish(profile: profiles.first, workouts: workouts, stats: stats)
            // Mirror the day's messages into the in-app inbox (the bell), deduped so they don't stack.
            if let s = sessionsToday.first {
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
            // The community publish sweep rides the same moment (docs/COMMUNITY-FEED-REDESIGN.md §6):
            // posts for newly-SHARED workouts go up, privacy-downgrades come down, `postPublishedAt`
            // stamps on success only so failures retry next pass. Inert while community is off, and a
            // no-op when the backend is dark (guard inside the sweep).
            if CommunityAccess.enabled {
                Task { await services.social.runPublishSweep(workouts: workouts, profile: profiles.first, in: context) }
            }
            // No workout import sweep. Apple Health is a source of *signals* — sleep, HRV, resting
            // heart rate — not a source of workouts: connecting it never backfills a journal, and
            // nothing recorded elsewhere becomes a Momentum workout. The journal is what the athlete
            // logs here, and the recovery picture builds up day by day from the moment they connect.
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
        // --enter-world: press the globe button from WHATEVER state the launch args produced —
        // unlike --world (which pre-mounts the map at init), this exercises the never-mounted
        // path: `--ui-test-strength --enter-world` reproduces the strength-day glitch exactly
        // (sim taps can't reach the button reliably enough to verify a 2.4 s camera animation).
        // --deck-cycle: collapse then re-expand the deck on a timer — the Start morph and the
        // move/opacity swap are sub-second motions no sim tap can reliably frame; a scripted cycle
        // makes them recordable (`simctl io recordVideo`) without XCUITest in the loop.
        if ProcessInfo.processInfo.arguments.contains("--deck-cycle") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { setDeck(collapsed: true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { setDeck(collapsed: false) }
        }
        if ProcessInfo.processInfo.arguments.contains("--enter-world") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { enterWorld() }
        }
        // --notifications: open the bell inbox for verification.
        if ProcessInfo.processInfo.arguments.contains("--notifications") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showNotifications = true }
        }
        // --today-profile: press the header avatar. Routes through the SAME mailbox the button
        // writes, so this verifies the real tab jump rather than a harness-only presentation.
        if ProcessInfo.processInfo.arguments.contains("--today-profile") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { router.pendingTab = .profile }
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
        // --life-happens: straight to the pause/ease sheet (normally reached through the check-in's
        // "Life's in the way" door) — deterministic screenshot without choreographing the door tap.
        if ProcessInfo.processInfo.arguments.contains("--life-happens") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showLifeHappens = true }
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
                router.workoutLaunch = .cardio(type: .run, goalMeters: session.targetDistanceM,
                                               planned: session, guideRoute: [])
            }
        }
        // --live-run: straight into a free run (pair with --ui-test-route for a synthetic GPS feed) —
        // verifies the live screen and the lock-screen Live Activity without UI choreography.
        if ProcessInfo.processInfo.arguments.contains("--live-run") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                router.workoutLaunch = .cardio(type: .run, goalMeters: nil, planned: nil, guideRoute: [])
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
                // Ran it (or plan to) on a treadmill? Log it instead of tracking a GPS run — the
                // quick form opens pre-filled with today's distance and expected time, so it's a
                // confirm-and-save, not a blank form. Runs only (treadmill = a run indoors).
                if session.discipline == .running {
                    Button {
                        pendingTreadmillLog = session
                        confirmingPlan = nil
                    } label: {
                        Label("I ran this on a treadmill", systemImage: "figure.run")
                            .font(.rounded(Theme.FontSize.body, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
                    }
                    .buttonStyle(.plain)
                }
                Button("Not now") { confirmingPlan = nil }
                    .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            }
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity)
        .presentationDetents([.height(confirmSheetHeight(rowCount: exercises.count + structure.count,
                                                         hasRationale: !(session.rationale ?? "").isEmpty,
                                                         hasTreadmill: session.discipline == .running))])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
    }

    /// The planned run, ready to log as a treadmill session: today's date, the prescribed distance,
    /// marked indoor, with the EXPECTED time pre-filled from the target pace — so the athlete
    /// confirms or tweaks two numbers rather than facing a blank form. LogWorkoutView's save credits
    /// the plan, so logging it here closes today's session exactly like a tracked run would.
    private func treadmillPrefill(_ session: PlannedSession) -> LogWorkoutPrefill {
        let dist = session.targetDistanceM ?? 0
        let expectedS: Double = (dist > 0 && (session.targetPaceSPerKm ?? 0) > 0)
            ? (dist / 1000) * (session.targetPaceSPerKm ?? 0) : 0
        return LogWorkoutPrefill(type: .run, date: Date(), durationS: expectedS,
                                 distanceM: dist, indoor: true, effort: nil, exercises: [])
    }

    /// 380pt for the calm cardio confirm; prescription rows grow it (~66pt for a tall strength row,
    /// which bounds the run rows too), capped so a big session scrolls inside the sheet instead of
    /// swallowing the screen. A rationale line buys a little extra so it never squeezes the CTA.
    private func confirmSheetHeight(rowCount: Int, hasRationale: Bool, hasTreadmill: Bool = false) -> CGFloat {
        let base: CGFloat = (hasRationale ? 420 : 380) + (hasTreadmill ? 62 : 0)   // room for the treadmill option
        guard rowCount > 0 else { return base }
        return min(760, base + CGFloat(rowCount) * 66)
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

    /// One prescribed exercise: name on the left, sets × reps on the right — no weight; the athlete
    /// picks a load they can hit the rep range with, and the plan calibrates from what they log
    /// (mirrors SessionDetailSheet's row so the prescription reads identically everywhere).
    private func confirmExerciseRow(_ ex: PlannedExercise) -> some View {
        HStack {
            Text(ex.exercise?.name ?? "Exercise")
                .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.sm)
            Text(ex.prescriptionText)
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
        if s.discipline == .strength {
            // The split label wins ("Push Day"); pre-label plans keep the count heuristic.
            if let day = StrengthSplit.dayTitle(forLabel: s.strengthLabel) { return day.capitalized }
            return s.strengthTargets.count >= 5 ? "Full Body" : "Strength"
        }
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
    /// Whether the Today map has anything meaningful to frame. Without this, the only camera left
    /// is the world view — and Today never shows the globe uninvited (world mode is a deliberate
    /// zoom-out, not a fallback).
    private var canCenterMap: Bool { locator.isAuthorized || lastKnownCoordinate != nil }

    /// Persisted last-known fix: `[count]` (computed, no GPS history) or `[count, lat, lon]`.
    /// The history walk below faults an entire route's `LocationSample` rows, and it used to run
    /// inside the FIRST body pass of every cold launch — this cache makes that a once-per-new-
    /// workout cost instead (perf audit 2026-08-13). A same-count-different-workout edit serves a
    /// slightly stale neighborhood, which is all this camera ever promised.
    private static let lastFixKey = "com.momentum.today.lastKnownFix"

    private var lastKnownCoordinate: CLLocationCoordinate2D? {
        if let live = locator.lastLocation { return live }
        if historyFixMemo.count != workouts.count {
            historyFixMemo.count = workouts.count
            if let stored = UserDefaults.standard.array(forKey: Self.lastFixKey) as? [Double],
               stored.first.map({ Int($0) }) == workouts.count {
                historyFixMemo.coord = stored.count == 3
                    ? CLLocationCoordinate2D(latitude: stored[1], longitude: stored[2]) : nil
            } else {
                historyFixMemo.coord = workouts
                    .sorted { $0.startedAt > $1.startedAt }
                    .lazy
                    .compactMap { $0.gps?.samples.first(where: { $0.accepted }) }
                    .first
                    .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                let record = historyFixMemo.coord.map { [Double(workouts.count), $0.latitude, $0.longitude] }
                    ?? [Double(workouts.count)]
                UserDefaults.standard.set(record, forKey: Self.lastFixKey)
            }
        }
        return historyFixMemo.coord
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
            if mapShowsGlobe, CommunityAccess.enabled {
                CircleAnnotationGroup(globeDots) { athlete in
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
                // dynamic asset colour and renders it near-black on the dark basemap. The brand
                // trace purple #7C63F0 over a crisp white casing pops on any style.
                PolylineAnnotation(lineCoordinates: heroRouteCoordinates)
                    .lineColor(StyleColor(UIColor.white))
                    .lineWidth(13).lineJoin(.round)
                PolylineAnnotation(lineCoordinates: heroRouteCoordinates)
                    .lineColor(StyleColor(UIColor(red: 0.486, green: 0.388, blue: 0.941, alpha: 1)))
                    .lineWidth(7).lineJoin(.round)
            }
        }
        .mapStyle(activeMapboxStyle)
        .ornamentOptions(MapChrome.hidden)
        // Enabling the puck activates Mapbox's location provider, which prompts for permission — so we
        // only turn it on once the athlete has actually granted location (never up front on arrival).
        .onStyleLoaded { _ in
            mapStyleReady = true   // animated by the opacity binding in `body` — fade, don't pop
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
    ///
    /// The day preset is PINNED (user call 2026-07-30): a bare `.standard` lets the SDK adapt the
    /// light preset to the system appearance, so dark-mode athletes got a blacked-out night Earth —
    /// but this globe is a physical object, not a UI surface. Like the medallion badges, it doesn't
    /// re-anodize with the theme: Earth from space is lit by the sun, in either appearance.
    private var activeMapboxStyle: MapboxMaps.MapStyle {
        if mapShowsGlobe { return .standard(lightPreset: .day) }
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
                        MuscleMapView(activation: lastStrengthActivation,
                                      forceStatic: !strengthMapOnScreen)
                            .frame(height: 236)
                            .frame(maxWidth: .infinity)
                            // Frozen when scrolled off (AthletePanel pattern) — the mesh otherwise
                            // kept animating at 30 fps behind the readout for the whole visit.
                            .onScrollVisibilityChange(threshold: 0.05) { strengthMapOnScreen = $0 }
                        lastStrengthReadout
                    } else if activity.isGPS {
                        // A cardio sport before any location exists: the sport leads, never a
                        // world-zoom map (owner call 2026-07-30 — "just show the icon, and they
                        // can log it"). One quiet line says how the map arrives; the deck below
                        // already carries Start and Log.
                        VStack(spacing: Theme.Space.lg) {
                            sportBadge
                            Text("Your map arrives with your first start —\nor log a session from below.")
                                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                                .foregroundStyle(Theme.inkTertiary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, Theme.Space.xl)
                    } else {
                        // Timed sports lead with THEIR OWN icon, not the app's (owner call
                        // 2026-07-30) — tennis day looks like tennis.
                        sportBadge.padding(.top, Theme.Space.xl)
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

    /// The sport's identity mark for non-map faces: its own glyph floating over a soft iridescent
    /// glow (owner ask 2026-07-30 — "a glow right behind the icon, very subtle"). Not a chip: no
    /// circle, no hairline — just the brand's five hues swept into a halo and blurred until they
    /// read as light coming from behind the mark. Static by construction (Reduce Motion safe);
    /// opacity tuned per scheme so it breathes on white and doesn't curdle on warm charcoal.
    private var sportBadge: some View {
        Image(systemName: activity.systemImage)
            .font(.system(size: 54, weight: .bold))
            .foregroundStyle(Theme.ink)
            .frame(width: 148, height: 148)
            .background {
                // The brand hues are pastels — on charcoal they average out to a gray fog unless
                // the chroma is pushed back up; on white they need no help.
                Circle()
                    .fill(AngularGradient(colors: Theme.iridescent + [Theme.iridescent[0]],
                                          center: .center))
                    .frame(width: 165, height: 165)
                    .blur(radius: 38)
                    .saturation(colorScheme == .dark ? 2.6 : 1.25)
                    .opacity(colorScheme == .dark ? 0.38 : 0.8)
            }
            .accessibilityLabel(activity.title)
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

    /// The most recent lift, memoized behind the same cheap signature `pendingToday` uses (perf
    /// 2026-08-14). Both this and `lastStrengthActivation` are read from `body` — the readout
    /// reads one, the body map the other — so on the strength home EVERY body pass (the scroll
    /// offset changing, the deck animating, any store change) re-walked the whole workout table
    /// and re-ran the activation engine. That is the jank the athlete feels while scrolling.
    private var lastStrength: Workout? {
        strengthMemoToken == currentStrengthToken ? cachedLastStrength : computeLastStrength()
    }

    /// Muscles worked in the most recent strength session — drives the strength-home body map.
    /// Empty (a faint silhouette) before the athlete's first lift.
    private var lastStrengthActivation: [MuscleGroup: Double] {
        strengthMemoToken == currentStrengthToken ? cachedLastActivation : computeLastActivation()
    }

    /// Cheap signature — read off the CACHED workout, never a fresh table walk:
    /// - `workouts.count` catches a session appearing or being deleted;
    /// - the cached session's `totalSets` catches sets landing on the session we're already
    ///   showing. That second term is load-bearing: a live lift inserts its workout row FIRST and
    ///   persists sets as they happen, so a count-only token would leave Today's body map showing
    ///   an empty silhouette for the session that just finished.
    private var currentStrengthToken: Int {
        var h = Hasher()
        h.combine(workouts.count)
        h.combine(cachedLastStrength?.persistentModelID)
        h.combine(cachedLastStrength?.strength?.totalSets ?? -1)
        return h.finalize()
    }
    private func computeLastStrength() -> Workout? {
        workouts.filter { $0.type.isStrengthStyle }.max(by: { $0.startedAt < $1.startedAt })
    }
    private func computeLastActivation() -> [MuscleGroup: Double] {
        guard let session = computeLastStrength()?.strength else { return [:] }
        return MuscleActivation.from(session: session)
    }
    /// Refill both caches together — called from the same lifecycle hooks as `refreshPendingToday`.
    private func refreshStrengthMemo() {
        cachedLastStrength = computeLastStrength()
        cachedLastActivation = computeLastActivation()
        strengthMemoToken = currentStrengthToken
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
                // A second DOOR to the Profile tab, never a second profile screen (fix 2026-07-30).
                // This used to push its own `ProfileScreen(showsBackButton: true)` onto Today's
                // stack, and being a push rather than the tab root is exactly what suppressed the
                // Profile ↔ Community slider — the athlete tapped their own face and landed on a
                // profile with no way through to the community wall, plus a back chevron implying
                // they were somewhere else. Routing through `AppRouter.pendingTab` (the shell's
                // cross-tab mailbox) makes this button and the tab-bar item the identical
                // destination: one live screen, one set of state.
                .mapSafeTap("Your profile") { Haptics.light(); router.pendingTab = .profile }
            bellButton
            Spacer(minLength: Theme.Space.xs)
            activitySelector
            Spacer(minLength: Theme.Space.xs)
            coachButton
            globeButton
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.sm)
    }

    /// The whole planet, one tap from home (owner call, 2026-07-29: the globe took the streak
    /// chip's slot — the streak still lives in the widget and Progress). Same glass circle language
    /// as the bell and coach; `enterWorld()` flies the SAME map out to the satellite globe, so it
    /// reads as a zoom, not a screen change. Athlete dots up there stay gated on `CommunityAccess`
    /// — until real users exist, a globe of dots is a fabricated crowd.
    private var globeButton: some View {
        Image(systemName: "globe")
            .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
            .frame(width: 44, height: 44).momentumGlass(in: Circle())
            .mapSafeTap("See the world") { enterWorld() }
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
            // The selector glyph, not chevron.down: the picker slides UP, so a down-arrow pointed
            // the wrong way (owner catch 2026-07-30). This is iOS's standard "tap to choose"
            // mark (popup pickers, Menu labels) — it promises a choice, not a direction.
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.inkSecondary)
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

    /// Where the map controls rest, measured up from the screen's bottom edge: just above the peek
    /// when collapsed, just above the deck when expanded. Both measured heights already include their
    /// own bottom padding, so this is the whole distance (double-counting it made them collide with
    /// the Start pill the first time round).
    private var mapControlsLift: CGFloat {
        (deckCollapsed ? peekHeight : deckHeight) + Theme.Space.sm
    }

    /// Both heights start at 0 and only arrive after the first layout pass, which would park the
    /// controls down on the tab bar for a frame and then jump them up. They fade in once they know
    /// where they belong — imperceptible when measurement lands on the first pass, and no jump when
    /// it doesn't.
    private var mapControlsPositioned: Bool {
        (deckCollapsed ? peekHeight : deckHeight) > 0
    }

    private func setDeck(collapsed: Bool) {
        guard collapsed != deckCollapsed else { return }
        Haptics.light()
        if reduceMotion {
            deckCollapsed = collapsed
        } else {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { deckCollapsed = collapsed }
        }
    }

    private var bottomPanel: some View {
        ZStack(alignment: .bottom) {
            // Collapsed state: one glass pill carrying the only two things worth the space when the
            // map owns the screen — what's on today, and Start.
            // Exactly ONE of the peek and the deck is mounted at a time. They both carry a Start
            // control with the same spoken label, and keeping the hidden one alive at opacity 0 put
            // TWO "Start run" buttons in the tree: VoiceOver read both, and every XCUITest that taps
            // `buttons["Start run"]` broke with "Multiple matching elements found" (6 suites).
            // `.accessibilityHidden()` did NOT collapse the query — only not rendering it does.
            if deckCollapsed {
                collapsedPeek
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.bottom, Theme.Space.sm)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { peekHeight = $0 }
                    // Same edge as the deck's exit, so collapse/expand reads as one surface
                    // condensing at the bottom of the screen — not two unrelated crossfades.
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                deck
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.bottom, Theme.Space.sm)   // sit closer to the tab bar, more map shows
                    // Measure once per size change; the map controls anchor to this, and the deck
                    // grows on mornings the coach added a rationale or a fueling line.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { deckHeight = $0 }
                    // Slides down as it leaves, so collapsing still reads as the deck getting out of
                    // the map's way rather than a bare cross-fade.
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // The map's own controls sit OUTSIDE that branch — they belong to the map, not to either
            // deck state. Collapsing is the moment the athlete most wants layers and recenter, and
            // riding the deck down took them off-screen exactly then. They anchor to whichever
            // surface is showing instead.
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
                .padding(.horizontal, Theme.Space.md)
                .offset(y: -mapControlsLift)
                .opacity(mapControlsPositioned ? 1 : 0)
            }
        }
    }

    /// The collapsed deck: expand on the left, Start on the right. Start stays the only filled
    /// element here too, so the hierarchy survives the collapse.
    private var collapsedPeek: some View {
        HStack(spacing: Theme.Space.sm) {
            Button { setDeck(collapsed: false) } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                    Text(peekTitle)
                        .font(.rounded(Theme.FontSize.body, weight: .semibold))
                        .foregroundStyle(Theme.ink).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show today's deck")

            Button { Haptics.light(); startFree() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.system(size: 13, weight: .bold))
                    Text("Start").font(.rounded(Theme.FontSize.body, weight: .bold))
                }
                .foregroundStyle(Theme.background)
                .padding(.horizontal, 18).frame(height: 44)
                .background(Capsule().fill(Theme.ink))
            }
            .buttonStyle(.plain)
            // Exactly one live source per state (`isSource`), so the outgoing Start travels to the
            // incoming one's frame — one button in motion, and no double-source ambiguity.
            .matchedGeometryEffect(id: "todayStartCTA", in: startMorph, isSource: deckCollapsed)
            .accessibilityLabel(startTitle)
            // Same spoken label as the deck's Start (they are the same action), so tests need an
            // identifier to tell the two states apart.
            .accessibilityIdentifier("todayPeekStart")
        }
        .padding(.leading, Theme.Space.md)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .momentumGlass(in: Capsule())
    }

    /// What the collapsed pill says: today's prescription when there is one, else the neutral date.
    private var peekTitle: String {
        if let session = pendingToday { return PlanCoaching.brief(for: session) }
        return activity.isStrengthStyle ? "Today" : "Ready when you are"
    }

    /// The control deck — ONE glass surface, not a stack of cards. Reads top-to-bottom as a single
    /// thought: today's plan (coaching) → goal (setting) → Start (the one hero) → discovery (explore).
    /// A single hairline divides the coaching context from the action zone; Start is the only filled
    /// element so the hierarchy never competes.
    /// The deck holds exactly three thoughts: today's plan, Start, and ONE quiet utility line
    /// (injury state ▸ morning check-in ▸ small actions — whichever matters right now). The week
    /// lives on the Plan tab; the free-run goal picker appears only when there's no plan to follow.
    private var deck: some View {
        // One signature check per deck render — the getters each re-hash the pending-today token
        // (plan fault + sessions count), and the deck read them 3× per body pass while the map
        // pans re-evaluate continuously.
        let session = pendingToday
        let state = session == nil ? planState : nil
        return VStack(spacing: 0) {
            deckGrabber
            if let session {
                planRow(session)
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                    .padding(.horizontal, Theme.Space.md)
            } else if let state {
                planStateRow(state)
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                    .padding(.horizontal, Theme.Space.md)
            }
            VStack(spacing: Theme.Space.md) {
                if isCardio && session == nil { goalControl }
                HStack(spacing: Theme.Space.sm) {
                    logButton
                    OversizedButton(title: startTitle, systemImage: "play.fill") { startFree() }
                        .matchedGeometryEffect(id: "todayStartCTA", in: startMorph, isSource: !deckCollapsed)
                        .accessibilityIdentifier("todayDeckStart")
                }
                utilityLine
            }
            .padding(Theme.Space.md)
        }
        .momentumGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
    }

    /// Collapse control: one plain button at the top of the card. This was briefly a drag handle with
    /// a card-wide swipe, and it glitched — the deck fought the map's own pan and the deck's buttons
    /// for the same touches (owner report 2026-08-14). A tap has none of that ambiguity, so the arrow
    /// is the whole affordance: down to hide the deck, up (on the peek) to bring it back.
    private var deckGrabber: some View {
        Button { setDeck(collapsed: true) } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.inkTertiary)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hide today's deck for a full map")
        .accessibilityIdentifier("todayDeckCollapse")
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
        var h = Hasher()
        h.combine(coachingEvents.count)
        h.combine(Calendar.current.startOfDay(for: Date()))
        let key = h.finalize()
        if adaptedTodayMemo.key != key {
            adaptedTodayMemo.key = key
            adaptedTodayMemo.value = coachingEvents.contains {
                ($0.kind == .ease || $0.kind == .recover) && Calendar.current.isDateInToday($0.date)
            }
        }
        return adaptedTodayMemo.value
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
    private var checkinChip: some View {
        // No re-guard: `utilityLine` is the only caller and has already proven both conditions —
        // the duplicate `DailyCheckin.today` here was a second full-table scan per render.
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

    /// While an injury is active: the plan's protective state + the way back — "feeling better?" is the
    /// gate into the gentle return (InjuryResponse.resume). Empty when healthy.
    @ViewBuilder
    private var injuryBanner: some View {
        if let profile = profiles.first, let areaRaw = profile.activeInjuryArea,
           let area = InjuryArea(rawValue: areaRaw) {
            Button { Haptics.light(); confirmResume = true } label: {
                HStack(spacing: Theme.Space.sm) {
                    // Injury wears calm monochrome, not the brand lavender (rebrand 2026-08-16):
                    // lavender now means interactive/brand, and an injury banner is neither a
                    // celebration nor a highlight — ink keeps it quiet, no-shame style.
                    Image(systemName: "bandage.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
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
                    Capsule().fill(Theme.surface)
                    Capsule().stroke(Theme.hairline)
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Training around your \(area.label). Feeling better? Tap to ease back into running.")
        }
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
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.Fuel.carbs)
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

    /// The athletes on the globe. Empty in the solo app — until real users exist a globe of dots
    /// is a fabricated crowd — and the moderation-filtered directory behind `CommunityAccess`
    /// (restored 2026-07-29, exactly as the back-burner stub prescribed). Blocked athletes vanish
    /// from the planet too, not just the feed: a block is a block everywhere.
    private var communityAthletes: [CommunityAthlete] {
        guard CommunityAccess.enabled else { return [] }
        return CommunityDirectory.all().filter { !moderation.isBlocked($0.handle) }
    }
    private var onMap: Bool { profiles.first?.appearOnMap ?? false }

    /// Slide the cards away and fly the camera from the street all the way out to the globe. Mapbox's
    /// native `.fly` runs the cinematic zoom-out → arc → settle, so the planet eases into frame instead
    /// of a flat linear zoom.
    private func enterWorld() {
        Haptics.light()
        // Snapshot the globe's dots once per entry — filtering the ~950-athlete directory through
        // the blocklist on every mid-flight render was 3 full passes per frame.
        globeDots = communityAthletes
        let target = lastKnownCoordinate ?? CLLocationCoordinate2D(latitude: 20, longitude: 0)
        let globe = Viewport.camera(center: target, zoom: 1.3, pitch: 0)
        // On a strength day the map has never MOUNTED (the strength home replaces it, and
        // `mapWasShown` only flips for cardio) — SwiftUI inserts it in this very transaction, and
        // a viewport animation scheduled against a Map that doesn't exist yet is dropped on the
        // floor: the map appeared already parked at the globe, no zoom-out, mid-load flash (owner
        // report 2026-07-30). Mount it first at the street camera and give the insertion one beat;
        // the same cinematic fly then runs from the street exactly as it does from the cardio map.
        let needsMount = !mapWasShown
        mapWasShown = true
        if needsMount, case .idle = viewport {
            // Belt-and-braces: onAppear normally seeds this, but the fly must never start from
            // `.idle` (an uninitialized camera flies from nowhere).
            viewport = .camera(center: target, zoom: 13.5, pitch: 0)
        }
        withAnimation(Motion.reversible) { worldMode = true }
        mapShowsGlobe = true   // satellite earth; set before the fly so it's loaded as we pull back
        if reduceMotion {
            viewport = globe
        } else if needsMount {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard worldMode else { return }   // exited again within the mount beat
                withViewportAnimation(.fly(duration: 2.4)) { viewport = globe }
            }
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
        let count = globeDots.count
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
            if !globeDots.isEmpty {
                HStack(spacing: Theme.Space.sm) {
                    Circle().fill(Theme.route).frame(width: 8, height: 8)
                    Text("Community").font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    Spacer(minLength: 0)
                }
            }
            // Presence opt-in is a community feature: with community off there is no map to
            // appear on, and a solo athlete tapping "Appear on the map" would be opting into an
            // audience of nobody — a promise the app can't keep (CommunityAccess is the one gate).
            if CommunityAccess.enabled {
                worldOptInRow
            }
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
        if activity.isStrengthStyle { router.workoutLaunch = .strength(type: activity, planned: nil) }
        else if activity.isTimed { router.workoutLaunch = .timed(type: activity) }
        else {
            locator.requestAuthorization()   // ask for GPS exactly when they Start — never up front
            flyIntoRecordingFrame(for: activity)
            router.workoutLaunch = .cardio(type: activity, goalMeters: goalMeters, planned: nil, guideRoute: [])
        }
    }

    private func startPlanned(_ session: PlannedSession) {
        // Use the session's precise sport (swim/yoga/row…) when set; fall back to the discipline bucket.
        let t = session.workoutType ?? workoutType(for: session.discipline)
        if t.isStrengthStyle { router.workoutLaunch = .strength(type: t, planned: session) }
        else if t.isTimed { router.workoutLaunch = .timed(type: t) }
        else {
            locator.requestAuthorization()
            flyIntoRecordingFrame(for: t)
            router.workoutLaunch = .cardio(type: t, goalMeters: session.targetDistanceM, planned: session, guideRoute: [])
        }
    }

    /// The launch beat's camera half (shared-map pass 2026-08-19): as the recorder crossfades up,
    /// Today's own camera flies to the live screen's follow framing — so the visible motion at
    /// Start is the athlete's map tightening onto them, and the recorder's map (seeded at the same
    /// fix and zoom) takes over invisibly. Also means the run *ends* on a map already framing the
    /// athlete. Only with permission — this viewport spins up Mapbox's location provider.
    private func flyIntoRecordingFrame(for type: WorkoutType) {
        guard locator.isAuthorized else { return }
        let zoom: CGFloat = type.discipline == .cycling ? 15 : 16
        if reduceMotion { viewport = .followPuck(zoom: zoom, pitch: 0) }
        else { withViewportAnimation(.easeInOut(duration: 0.6)) { viewport = .followPuck(zoom: zoom, pitch: 0) } }
    }

    private func workoutType(for d: Discipline) -> WorkoutType {
        WorkoutType.forDiscipline(d)
    }

    /// Point the sport picker at whatever today's plan actually prescribes.
    ///
    /// The picker used to be hardcoded to `.run` forever, which was invisible on a running day and
    /// wrong on every other one: on a strength day the deck read "TODAY'S PLAN — Strength — 4
    /// exercises" while the big black button underneath said "Start run" and, via `startFree()`,
    /// launched an untracked free run that credited the plan nothing. The most prominent control on
    /// the home screen did the opposite of what the card above it advertised.
    ///
    /// Only ever moves the picker BEFORE the athlete touches it (`pickerIsAthletesChoice`), so a
    /// deliberate "actually I want to ride today" is never stomped on the next appear.
    private func matchPickerToTodaysPlan() {
        guard !pickerIsAthletesChoice, !marketingHero else { return }
        guard !debugFlag("--ui-test-strength") else { return }   // the UI test pins its own sport
        #if DEBUG
        // --today-sport pins the picker the same way a tester's own tap would.
        guard !ProcessInfo.processInfo.arguments.contains("--today-sport") else { return }
        #endif
        guard let session = pendingToday else { return }
        activity = WorkoutType.forPlanned(session)
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
                            // Two lines, because the confidence qualifier rides on the end of this
                            // string: at one line "Recent load still settling · partial signal"
                            // truncates away the exact clause that makes the score honest.
                            .lineLimit(2)
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

    /// ONE phrasing for every surface — `displayDriverLine` is what the strip and the hub speak;
    /// a second hand-maintained copy here drifted into different words (and a different
    /// threshold) for the same pillar, visibly contradicting the "one number" story.
    /// Carries the confidence qualifier: on a phone-only morning this line is the ONLY place the
    /// athlete is told the score was built on thin signal, since Today has no room for the hub's
    /// fuller footnote.
    private var driver: String { readiness.displayDriverWithConfidence }

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
