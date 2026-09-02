import SwiftUI
import MapboxMaps
import SwiftData
import CoreLocation
import Combine
import UIKit

/// The immersive cardio recording experience (PRD §4.3) — presented after the user picks an
/// activity + goal on the map-first Today. Runs a 3-2-1 countdown, then records: a solid route
/// trace on the map, and a Strava-style stats page over it — distance as the hero, then time, then
/// average / current pace, then heart rate.
///
/// Rendering is split so a GPS fix, a clock tick and a page drag each invalidate only their own
/// slice (perf pass 2026-08-26):
/// - `CardioTrackingView` (this root) owns phase, the page, the camera and the top chrome. Its body
///   reads NOTHING that changes per fix.
/// - `LiveMapLayer` owns the Mapbox map, the puck feed and the trace; it is the only view that
///   observes the engine snapshot (`routePointCount` / `puckPoint`).
/// - `LivePager` owns the drag (a transform only) and hosts `LiveStatsPage` + `LiveMapPeek`, which
///   read only `vm.readout` (pre-formatted strings, published once per fix) and `vm.coachLine`.
/// - `LiveClockText` is the one thing that ticks every second, on its own `TimelineView`.
struct CardioTrackingView: View, Equatable {
    let type: WorkoutType
    let goalMeters: Double?
    let container: ModelContainer
    var distanceUnit: DistanceUnit = .auto
    /// An optional suggested loop to follow — drawn as a faint dashed guide beneath the live trace.
    var guideRoute: [GeoPoint] = []
    /// An optional guided structured session (warm-up → reps → cool-down) to coach through in real time.
    var structured: StructuredWorkout? = nil
    /// The plan's prescribed pace for a *non-structured* planned run (easy/long) — shown as a quiet
    /// target on the goal bar so "run easy at ~9:40" lives on the screen, not in the athlete's
    /// memory. Structured sessions carry their own per-step targets and ignore this.
    var targetPaceSPerKm: Double? = nil
    var onFinish: (UUID?) -> Void

    enum Phase { case acquiring, countdown, tracking }

    /// Equal on the launch's VALUE inputs only. The shell above (`RootView` / `WorkoutRunner`)
    /// holds `@Query`s whose result sets include the run being recorded, so every persisted GPS
    /// sample rebuilds the overlay and hands this view a fresh value (a new `onFinish` closure
    /// every time). Mounted through `.equatable()`, that rebuild never re-evaluates the recorder.
    static func == (a: Self, b: Self) -> Bool {
        a.type == b.type && a.goalMeters == b.goalMeters && a.distanceUnit == b.distanceUnit
            && a.guideRoute == b.guideRoute && a.structured == b.structured
            && a.targetPaceSPerKm == b.targetPaceSPerKm
    }

    /// The newest few workouts, ONLY to frame the map on the athlete's last route until a live fix
    /// lands. Fetched ONCE in `onAppear` — never a `@Query`: the row being recorded is itself in
    /// the result set, so a live query re-rendered this whole screen on every persisted GPS sample
    /// for the entire run (perf pass 2026-08-26; the same finding for `UserProfile`).
    static var recentRoutes: FetchDescriptor<Workout> {
        var d = FetchDescriptor<Workout>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        d.fetchLimit = 5
        return d
    }
    @State private var phase: Phase = .acquiring
    @State private var countdown = 3
    /// Where the run began — captured from the athlete's known position the INSTANT recording arms,
    /// so the green start pin drops immediately on "GO" rather than waiting for the first accepted
    /// route point (which lands up to a fix interval later, and read as a delayed dot).
    @State private var startCoordinate: CLLocationCoordinate2D?
    @State private var viewport: Viewport = .idle
    @State private var confirmStop = false
    @State private var finishing = false   // one finish per run (see the Finish dialog)
    @State private var vm: CardioViewModel?
    @State private var acquirePulse = false
    @State private var acquireTimedOut = false
    /// Set when the user backs out via X — gates the countdown task so a cancelled start can't arm.
    @State private var dismissed = false
    // Shared app-wide base-map choice (see MapStyleOption.storageKey) — the style picked on Today
    // is the style the run records with, and vice versa.
    @AppStorage(MapStyleOption.storageKey) private var mapStyle: MapStyleOption = .realistic
    /// The athlete's 2D/3D choice from the Today map's toggle — the run's follow camera honors it.
    @AppStorage(MapPerspective.storageKey) private var mapPerspectiveRaw = ""
    @State private var offRoute = false        // drifted off the guide loop (hysteresis-gated)
    @State private var deviationM = 0.0
    @State private var rejoinBearing = 0.0     // compass bearing to the nearest loop point (north-up)
    /// While true the camera stays locked on the athlete (zoomed in, north-up). A pan/pinch drops it;
    /// the recenter arrow re-engages it.
    @State private var followsUser = true
    /// Re-engages the follow camera a few beats after the athlete stops touching the map — a
    /// mid-run pan is a glance, not a decision to fly free forever (Strava's behavior). Rearmed on
    /// every touch; recenter/finish cancels it.
    @State private var refollowTask: Task<Void, Never>?
    /// Stats-over-map paging (see `LivePage`). The drag itself lives in `LivePager`.
    @State private var page: LivePage = .stats
    /// True while a finger is actively pulling the stats page down (`LivePager` signals the 0→drag
    /// transition, never per frame). The map is progressively visible under the page for that whole
    /// pull, so the puck throttle must release NOW — waiting for `page` to commit at drag end left
    /// the dot up to 3 s + a glide stale, then a visible ~40 m catch-up on release.
    @State private var mapRevealing = false
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(Services.self) private var services

    /// Locked-on zoom, tuned per discipline: street-tight for foot sports, one step wider for
    /// cycling so 30-50 km/h doesn't scroll the world past faster than it reads.
    private var followZoom: Double { type.discipline == .cycling ? 15 : 16 }

    /// The locked-on follow viewport — follows the location puck, north-up, at a tight running zoom.
    /// Tilted only when the athlete chose 3D on the Today map (`MapPerspective`): a follow camera
    /// over a pitched basemap re-renders terrain/buildings on every fix, so it is opt-in here and
    /// a style's own tilt never applies on the run (the 2D behaviour every run had before).
    private var followViewport: Viewport {
        .followPuck(zoom: followZoom, bearing: .constant(0),
                    pitch: MapPerspective(rawValue: mapPerspectiveRaw)?.pitch ?? 0)
    }

    /// What the LIVE map actually renders: the flat 2D equivalent of the athlete's chosen style, so
    /// a follow-camera over a heavy 3D/satellite basemap can't jank the run screen. Their real
    /// choice (`mapStyle`) still drives the layers picker and the saved run's snapshot.
    private var liveStyle: MapStyleOption { mapStyle.liveTrackingStyle }

    /// Most recent prior route's location, used to frame the map until a live fix arrives — so we
    /// never show the whole country while waiting for GPS. Cached: reading it faults the prior
    /// workout's whole `samples` relationship, and doing that per body pass froze the start
    /// screen after a long previous run (audit 2026-08-11) — computed ONCE in onAppear.
    @State private var lastKnownCoordinate: CLLocationCoordinate2D?

    private func computeLastKnownCoordinate() -> CLLocationCoordinate2D? {
        // Never the recording in progress: its `samples` array is the one growing under us.
        let live = ActiveWorkoutMarker.pendingID
        let workouts = (try? container.mainContext.fetch(Self.recentRoutes)) ?? []
        return workouts
            .lazy
            .filter { $0.id != live }
            .compactMap { $0.gps?.samples.first(where: { $0.accepted }) }
            .first
            .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    /// Which page owns the screen while tracking. Stats is the primary page: it rises over the map
    /// the moment recording arms. Pulling it down (or the map button) reveals the map page, where a
    /// compact peek card keeps the numbers and the SAME controls in reach; the peek's grabber (or a
    /// pull up) brings the stats page back. Both pages are always mounted — the swap is a
    /// transform (offset + opacity), never a layout change.
    enum LivePage { case stats, map }

    var body: some View {
        ZStack(alignment: .bottom) {
            // The app background under the map: the cover presents faster than Mapbox paints its
            // first styled frame, and a raw engine clear-color flash reads as a glitch. The map
            // fades in over this the moment the style lands (usually instantly — Today's map has
            // already warmed the style cache).
            Theme.background.ignoresSafeArea()
            if let vm {
                LiveMapLayer(vm: vm, type: type, guideRoute: guideRoute, liveStyle: liveStyle,
                             viewport: $viewport, startCoordinate: startCoordinate,
                             tracking: phase == .tracking,
                             covered: phase == .tracking && page == .stats && !mapRevealing,
                             offRoute: $offRoute, deviationM: $deviationM, rejoinBearing: $rejoinBearing,
                             onUserGesture: dropFollow)
            }
            topBar
            switch phase {
            case .acquiring: acquiringOverlay
            case .countdown: countdownOverlay
            case .tracking:
                if let vm {
                    LivePager(vm: vm, page: $page, type: type, distanceUnit: distanceUnit,
                              structured: structured, goalMeters: goalMeters,
                              targetPaceSPerKm: targetPaceSPerKm, sessionLine: sessionLine,
                              hasGuide: guideRoute.count > 1,
                              onDragReveal: { mapRevealing = $0 },
                              onClose: { confirmStop = true }, onFinish: { confirmStop = true })
                        .equatable()
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom))
                }
            }
        }
        // Finishing is the goal, not a loss. A destructive role paints the primary action red and
        // frames crossing your own finish line as damage — the last thing the athlete should read
        // before the reveal. The confirmation stays (a mis-tap mid-run is real); the alarm goes.
        .confirmationDialog("Finish this \(type.title.lowercased())?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Finish") {
                // One finish per run: re-opening the dialog during the finish await used to
                // re-run the whole finish path — second store save, second snapshot render,
                // second `onFinish` into the presenter (audit 2026-08-11).
                guard let vm, !finishing else { return }
                finishing = true
                Task { onFinish(await vm.finish()) }
            }
            Button("Keep going", role: .cancel) {}
        }
        .task {
            if vm == nil {
                // Voice coach is Pro (PRD §10) — pass it only when entitled, else nil (silent).
                let voice = services.paywall.isEntitled(to: .voiceCoach) ? services.voiceCoach : nil
                var profile = FetchDescriptor<UserProfile>(); profile.fetchLimit = 1
                let maxHR = (try? container.mainContext.fetch(profile))?.first?.maxHR
                let model = CardioViewModel(type: type, container: container, distanceUnit: distanceUnit,
                                            goalMeters: goalMeters, structured: structured,
                                            targetPaceSPerKm: targetPaceSPerKm, voice: voice,
                                            motion: services.motion, maxHR: maxHR)
                model.beginAcquiring()
                vm = model
            }
        }
        // Leave the acquiring gate the instant we have a usable lock (Strava's "GPS Signal Acquired")
        // — unless the app is BACKGROUNDED. Fixes keep flowing back there (the location session
        // opens at acquiring), so a lock landing after the athlete pocketed the phone
        // mid-"Searching…" would run the countdown and arm a recording nobody started. Only
        // `.background` holds: `.inactive` is the launch transition / a system alert / control
        // center — the athlete is still looking at the phone, and gating on it stalled the gate
        // whenever the lock arrived under an alert (no later phase CHANGE ever re-fired it).
        .onChange(of: vm?.hasGPSLock ?? false) { _, locked in
            if locked, phase == .acquiring, scenePhase != .background { proceedToCountdown() }
        }
        .onChange(of: scenePhase) { _, p in
            if p == .active, phase == .acquiring, vm?.hasGPSLock == true { proceedToCountdown() }
        }
        #if DEBUG
        // Marketing shot: frame the WHOLE clean loop (overview) instead of the tight follow zoom.
        // Set it as a few one-shots AFTER the loop has drawn — doing it per-fix starves the engine
        // (map thrash) and leaves the lap half-run.
        .task {
            guard LocationService.isMidway else { return }
            // Let the whole lap draw first under the fast follow-cam (per-fix map work is cheap while
            // zoomed in), THEN frame the finished loop — and re-frame a few times so the final shot
            // always fits the complete loop.
            try? await Task.sleep(for: .seconds(16))
            for _ in 0..<5 {
                if let coords = vm?.coordinates, coords.count > 2 {
                    withAnimation(.easeInOut(duration: 0.7)) {
                        viewport = .overview(geometry: LineString(coords),
                                             geometryPadding: EdgeInsets(top: 90, leading: 52, bottom: 300, trailing: 52))
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        // `--live-page-cycle`: script the stats ⇄ map pages and a pause so every live state can be
        // captured by timed screenshots / recordVideo (XCUITest fast-forwards animations, so a
        // scripted cycle is how the real motion gets judged). Timeline from arming: 6 s map,
        // 12 s pause (on the map page), 18 s stats (still paused), 24 s resume + a sample coach line.
        .task(id: phase == .tracking) {
            guard phase == .tracking, ProcessInfo.processInfo.arguments.contains("--live-page-cycle") else { return }
            try? await Task.sleep(for: .seconds(6));  setPage(.map)
            try? await Task.sleep(for: .seconds(6));  await vm?.pause()
            try? await Task.sleep(for: .seconds(6));  setPage(.stats)
            try? await Task.sleep(for: .seconds(6));  await vm?.resume()
            vm?.cue(CoachingCueBuilder.milestone(unitCount: 1, splitSecPerUnit: 512, unit: distanceUnit), priority: .transition)
        }
        #endif
        // The moment recording starts: drop the start pin at the athlete's known position (instant,
        // no wait for the first route point) and snap the camera in to follow.
        .onChange(of: phase) { _, newPhase in
            if newPhase == .tracking {
                if startCoordinate == nil, let p = vm?.puckPoint {
                    startCoordinate = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
                }
                recenterOnUser()
            }
        }
        // Never imply we're still searching forever: after a beat, soften the copy to nudge "Start now".
        .task {
            try? await Task.sleep(for: .seconds(12))
            if phase == .acquiring { withAnimation(Motion.standard) { acquireTimedOut = true } }
        }
        .onAppear {
            if mapStyle.requiresPro, !services.paywall.isEntitled(to: .mapStyles) { mapStyle = .realistic }

            // Open exactly where the athlete already is. First choice: the OS's cached live fix —
            // the position Today's map was just showing — so the recorder's map continues the map
            // they launched from instead of hopping to an older neighborhood and back (the seam
            // audit's "three cameras" finding). Fall back to their last route's neighborhood; once
            // tracking begins we follow the location puck (see `recenterOnUser`).
            if lastKnownCoordinate == nil { lastKnownCoordinate = computeLastKnownCoordinate() }
            if case .idle = viewport {
                let liveFix = CLLocationManager().location?.coordinate
                // Match Today's `flyIntoRecordingFrame` zoom exactly (16 run/walk, 15 ride) — the
                // crossfade hands off between two maps, and a one-level zoom step is visible.
                let zoom: CGFloat = type.discipline == .cycling ? 15 : 16
                viewport = (liveFix ?? lastKnownCoordinate).map { .camera(center: $0, zoom: zoom) }
                    ?? followViewport
            }
            Haptics.warm()   // the countdown's ticks are seconds away — wake the Taptic Engine now
        }
    }

    /// A touch broke the follow lock. Every touch also rearms a short idle timer that quietly
    /// re-locks the camera onto the athlete — a mid-run glance at the route shouldn't leave the
    /// map parked elsewhere until they remember the recenter arrow.
    private func dropFollow() {
        followsUser = false
        refollowTask?.cancel()
        refollowTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, phase == .tracking, !followsUser else { return }
            recenterOnUser()
        }
    }

    private var recenterButton: some View {
        // Filled when locked on the athlete, hollow once the user has panned away — so the arrow
        // reads as "tap to snap back."
        Image(systemName: followsUser ? "location.fill" : "location")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(followsUser ? Theme.ink : Theme.inkSecondary)
            .frame(width: 44, height: 44).momentumGlass(in: Circle())
            .mapSafeTap("Recenter on me") { Haptics.light(); recenterOnUser() }
    }

    /// Lock the camera back onto the athlete at the tight running zoom (north-up). Falls back to
    /// native user-location framing until the first fix lands.
    private func recenterOnUser() {
        followsUser = true
        withAnimation(.easeInOut(duration: 0.4)) { viewport = followViewport }
    }

    private func setPage(_ p: LivePage) {
        guard p != page else { return }
        Haptics.selection()
        withAnimation(reduceMotion ? nil : Motion.travel) { page = p }
    }

    private var topBar: some View {
        VStack {
            HStack(alignment: .top) {
                Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                    .frame(width: 38, height: 38).momentumGlass(in: Circle())
                    .mapSafeTap("Close") { phase == .tracking ? (confirmStop = true) : cancelAndDismiss() }
                Spacer()
                // The right-side control column (matches Today): layers over recenter. Recenter lives
                // HERE — the old bottom-right placement hid behind the stats panel, so an athlete who
                // panned away had no visible way to lock back onto themselves.
                VStack(spacing: Theme.Space.sm) {
                    // Preview center from values that never change per fix (the live tip would
                    // re-render this chrome on every GPS sample).
                    MapLayersButton(style: $mapStyle, previewCenter: startCoordinate ?? lastKnownCoordinate)
                    if phase == .tracking { recenterButton }
                }
            }
            .padding(Theme.Space.md)
            if phase == .tracking, let vm, vm.locationDenied {
                deniedBanner.padding(.horizontal, Theme.Space.md)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if phase == .tracking, offRoute {
                offRouteBanner.padding(.horizontal, Theme.Space.md)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .animation(Motion.standard, value: vm?.locationDenied)
        .animation(Motion.standard, value: offRoute)
        // Under the opaque stats page these controls are invisible and unreachable; keep VoiceOver
        // from finding a second "Close" there.
        .accessibilityHidden(phase == .tracking && page == .stats)
    }

    /// No-shame nudge when the athlete drifts off the suggested loop — neutral, never a red "wrong."
    private var offRouteBanner: some View {
        HStack(spacing: Theme.Space.sm) {
            // Points toward the nearest loop point. The live map is north-up, so the compass bearing
            // is also the on-screen rotation.
            Image(systemName: "arrow.up").font(.system(size: 17, weight: .heavy)).foregroundStyle(Theme.ink)
                .rotationEffect(.degrees(rejoinBearing))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: rejoinBearing)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Off the loop").font(.rounded(Theme.FontSize.caption, weight: .bold))
                Text("\(Int(deviationM)) m. Head this way to rejoin.")
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.ink)
        .padding(Theme.Space.md)
        .momentumGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    /// Shown mid-recording when location is off — the time still counts, but no route is captured.
    private var deniedBanner: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "location.slash.fill").font(.system(size: 15, weight: .bold))
            VStack(alignment: .leading, spacing: 1) {
                Text("Location is off").font(.rounded(Theme.FontSize.caption, weight: .bold))
                Text("Time still counts. Enable location to map your route.")
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            }
            Spacer(minLength: 0)
            Button("Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
        }
        .foregroundStyle(Theme.ink)
        .padding(Theme.Space.md)
        .momentumGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    /// Pre-start gate: hold on the user's position while GPS locks, so the trace begins clean rather
    /// than teleporting from a bad first fix. Auto-advances on lock; "Start now" overrides. If location
    /// is off, says so honestly (with Settings) instead of pretending to search forever.
    private var acquiringOverlay: some View {
        let denied = vm?.locationDenied == true
        return VStack(spacing: Theme.Space.lg) {
            Spacer()
            VStack(spacing: Theme.Space.md) {
                ZStack {
                    Circle().fill(IridescentMaterial()).frame(width: 64, height: 64).opacity(denied ? 0.25 : 0.5)
                        .scaleEffect(acquirePulse && !denied ? 1.12 : 0.92)
                        .animation(reduceMotion || denied ? nil : .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                                   value: acquirePulse)
                    Image(systemName: denied ? "location.slash.fill" : "location.fill")
                        .font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.ink)
                }
                VStack(spacing: 4) {
                    Text(denied ? "Location is off" : acquiringTitle)
                        .font(.display(20, weight: .bold)).foregroundStyle(Theme.ink)
                    Text(denied ? "Enable location to map your route, or start now. Time still counts."
                                : acquiringSubtitle)
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                if denied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
                }
            }
            .padding(Theme.Space.xl)
            .momentumGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
            .padding(.horizontal, Theme.Space.xl)
            Spacer()
            OversizedButton(title: denied ? "Start without route" : "Start now",
                            systemImage: "bolt.fill", kind: .glass) { proceedToCountdown() }
                .padding(Theme.Space.md)
        }
        .onAppear { acquirePulse = true }
    }

    /// Reflects live signal quality while acquiring, so the user understands the wait.
    private var acquiringTitle: String {
        guard let vm, vm.lastAccuracyM != nil else {
            return acquireTimedOut ? "Still searching…" : "Searching for GPS…"
        }
        return vm.gpsStrength > 0.66 ? "Strong GPS" : vm.gpsStrength > 0.33 ? "Getting GPS…" : "Weak signal"
    }

    private var acquiringSubtitle: String {
        acquireTimedOut ? "You can start now. Your route picks up once GPS locks."
                        : "Finding your position for an accurate route."
    }

    private var countdownOverlay: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()
            Text(countdown > 0 ? "\(countdown)" : "GO")
                .font(.display(96, weight: .black)).foregroundStyle(.white)
                .id(countdown)
                .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
        }
        // Purely visual — the dimmer must not eat taps, or the X behind it can't abort the
        // countdown and an accidental start arms no matter what the athlete does.
        .allowsHitTesting(false)
    }

    /// A plan pace is a range, not a number: shown to the nearest 5 s ("about 10:00 /mi", never
    /// "about 9:59 /mi"), the same figure the coach's opening line says.
    private func aboutPace(_ secPerKm: Double) -> String {
        "\(CoachingCueBuilder.clockPace(secPerKm: secPerKm, unit: distanceUnit, roundTo: 5)) \(distanceUnit.resolved() == .imperial ? "/mi" : "/km")"
    }

    /// One line naming the session: the structured title, else the goal + target pace, else free.
    /// Fixed for the whole run — computed here once and handed down as a plain string.
    private var sessionLine: String {
        if let structured { return structured.title }
        if let goalMeters {
            let dist = Formatters.distance(meters: goalMeters, unit: distanceUnit)
            if let pace = targetPaceSPerKm {
                return "\(dist) · about \(aboutPace(pace))"
            }
            return "\(dist) goal"
        }
        return guideRoute.count > 1 ? "Your loop" : "Free \(type.title.lowercased())"
    }

    /// Run the 3-2-1 countdown, then arm the recording. Reached once we have a GPS lock (auto) or
    /// the user taps "Start now" from the acquiring gate.
    private func proceedToCountdown() {
        guard phase == .acquiring else { return }   // ignore a late lock once we've already advanced
        services.analytics.log(.workoutStarted(type: type.rawValue))
        withAnimation(Motion.standard) { phase = .countdown }
        Task {
            // 0.7 s ticks and no dead hold after GO — the old 0.8×3 + 0.5 shape put a fixed 2.9 s
            // between the lock and the first recorded second. The ceremony stays; the wait doesn't
            // (recording still arms exactly at GO, so no standing-around seconds ever count).
            for n in [3, 2, 1] {
                withAnimation(Motion.lively) { countdown = n }
                Haptics.light()
                try? await Task.sleep(for: .seconds(0.7))
            }
            withAnimation(Motion.lively) { countdown = 0 }
            try? await Task.sleep(for: .seconds(0.15))   // GO lands, then the panel rises through it
            // The user can tap X mid-countdown; arming after that teardown would create an orphan
            // workout (and re-set the recovery marker) with nothing on screen to finish it. Same
            // for a countdown that outlived the foreground: never arm in the pocket — fall back to
            // the gate, and the scenePhase observer restarts the countdown when they return.
            guard !dismissed else { return }
            guard scenePhase != .background else {
                phase = .acquiring
                countdown = 3
                return
            }
            await vm?.arm()
            Haptics.success()
            withAnimation(Motion.standard) { phase = .tracking }
        }
    }

    private func cancelAndDismiss() {
        dismissed = true
        vm?.cancelAcquiring()
        onFinish(nil)
    }
}

// MARK: - Map layer (the only view that observes the engine snapshot)

/// The Mapbox map, the puck feed and the live trace. Owns every per-fix side effect so a GPS
/// sample invalidates this view alone — never the stats page, the peek, or the root chrome.
private struct LiveMapLayer: View {
    let vm: CardioViewModel
    let type: WorkoutType
    let guideRoute: [GeoPoint]
    let liveStyle: MapStyleOption
    @Binding var viewport: Viewport
    let startCoordinate: CLLocationCoordinate2D?
    let tracking: Bool
    /// True while the opaque stats page fully covers the map — and false from the FIRST frame of a
    /// pull-down (`LivePager.onDragReveal` via the root), not just when the page commits, because
    /// the map is progressively visible under the page for the whole pull. Puck pushes are
    /// throttled while covered (the follow camera re-renders the whole map for ~1.1 s per push,
    /// for nobody to see) and the held newest position is pushed on the first reveal frame — one
    /// normal glide, no jump, never a late catch-up sprint on release.
    let covered: Bool
    @Binding var offRoute: Bool
    @Binding var deviationM: Double
    @Binding var rejoinBearing: Double
    let onUserGesture: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Incremental live spline (O(tail) per fix — a full re-smooth is O(n) and turns O(n²) over a
    /// multi-hour session). Frozen chunks are appended to the Mapbox source once and never re-sent;
    /// only the short live tail is replaced per fix, so map payloads stay constant-size too.
    @State private var smoother = RouteSmoothing.LiveSmoother()
    /// Mapbox interpolates the location puck toward each pushed position over ~1.1 s, so the dot's
    /// *visual* position trails the newest fix. If we drew the trace to that newest fix immediately,
    /// the line would race ahead of the dot (badly, on fast descents or dense fixes — the dot ends up
    /// mid-trace instead of at the tip). So we hold the trace's leading tip back by the same lag: the
    /// smoother is fed only points that arrived ≥ `puckLagS` ago, which is ≈ where the puck has
    /// actually interpolated to — so the athlete's dot always sits exactly at the tip of the line.
    private static let puckLagS: TimeInterval = 0.5
    /// (wall-clock arrival, route-point count) samples, so we can look up how many points existed
    /// ≈`puckLagS` ago and draw the trace only that far — pruned to a small trailing window.
    @State private var traceReleaseLog: [(t: Date, count: Int)] = []
    /// Rearmed on every fix; fires only when route points stop, releasing the held-back tail so the
    /// line ends exactly under the parked dot (see the trailing flush in `onChange`).
    @State private var traceFlushTask: Task<Void, Never>?
    /// Drives the puck (and its follow camera) from our Kalman-filtered position instead of raw
    /// CoreLocation — the dot, the camera, and the trace all track the same clean track, so a
    /// rejected GPS spike can't teleport the dot into a building while the line stays put.
    @State private var puckFeed = PuckFeed()
    /// While covered: the newest position not yet pushed, and when the last push went out.
    @State private var pendingPuck: CardioViewModel.LivePoint?
    @State private var lastPuckPush = Date.distantPast
    private static let coveredPuckIntervalS: TimeInterval = 3
    /// True once the basemap style has loaded — the map fades in over the app background instead
    /// of flashing whatever half-loaded frame Mapbox paints first.
    @State private var mapReady = false
    /// Where to insert route layers so the puck stays on top — resolved ONCE per style load and
    /// cached. The lookup scans every layer identifier in the style, and it used to run on every
    /// single GPS fix for the whole session: a linear main-actor walk of a ~100-layer style at 1 Hz,
    /// for nothing (the style's layer stack doesn't change mid-run).
    @State private var belowPuckPosition: LayerPosition?

    /// Off-route hysteresis: flag once past `offRouteM`, clear only back under `onRouteM` — so a fix
    /// hovering near the edge doesn't flicker the cue.
    private static let offRouteM = 35.0
    private static let onRouteM = 20.0

    private var routePointCount: Int { vm.routePointCount }

    var body: some View {
        // North-up (rotation disabled) so the rejoin arrow's compass bearing reads as screen rotation.
        MapReader { proxy in
            Map(viewport: $viewport) {
                // A green dot where the run began (one stable annotation — no churn). Uses the
                // position captured at "GO" so it appears instantly; falls back to the first route
                // point if that capture was ever missed. Never triggers a spline recompute.
                if let start = startCoordinate ?? vm.firstCoordinate {
                    MapViewAnnotation(coordinate: start) { startDot }.allowOverlap(true)
                }
                // The athlete's purple location puck ("you") is configured imperatively in
                // `.onStyleLoaded` (BrandPuck.apply) — the SwiftUI `Puck2D` crashes on devices where
                // Mapbox's default puck asset won't load.
            }
            .mapStyle(liveStyle.mapboxStyle(for: colorScheme))
            .ornamentOptions(MapChrome.minimal)
            .gestureOptions(GestureOptions(rotateEnabled: false, pitchEnabled: false))
            .onStyleLoaded { _ in
                BrandPuck.apply(to: proxy)
                puckFeed.attach(to: proxy)
                belowPuckPosition = nil                  // fresh style → re-resolve the puck layer
                syncRouteLayers(proxy.map, delta: nil)   // style reload wiped sources → full rebuild
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { mapReady = true }
            }
            // Incremental: feed only the new points to the smoother; append the newly-frozen chunks
            // and replace the short live tail. No full re-smooth, no full re-upload — per-fix work
            // stays constant no matter how long the session gets.
            .onChange(of: routePointCount) {
                let coords = vm.coordinates
                let now = Date()
                traceReleaseLog.append((now, coords.count))
                traceReleaseLog.removeAll { $0.t < now.addingTimeInterval(-Self.puckLagS - 1) }
                // Draw only up to where the puck has interpolated to (the point count as of ~puckLagS
                // ago), so the trace tip tracks the dot instead of racing ahead of it. Fewer, calmer
                // tail updates also keep the line from flickering into gaps under a fast fix stream.
                let visibleCount = traceReleaseLog.last { $0.t <= now.addingTimeInterval(-Self.puckLagS) }?.count ?? 0
                if visibleCount > 0 {
                    let delta = smoother.ingest(coords.prefix(visibleCount))
                    syncRouteLayers(proxy.map, delta: delta)
                }
                // Trailing flush: when route points STOP arriving (pause, standing still past the
                // movement gate, GPS loss, the final fix before Finish), no further onChange fires —
                // without this, the held-back newest point never releases and the line permanently
                // ends one fix short of the parked dot. 1.2 s ≈ the dot's 1.1 s glide: the tip snaps
                // in right as the dot settles. Cancelled and rearmed by every new fix, so it's a
                // no-op while fixes flow.
                traceFlushTask?.cancel()
                traceFlushTask = Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    guard !Task.isCancelled else { return }
                    let delta = smoother.ingest(coords)
                    syncRouteLayers(proxy.map, delta: delta)
                }
                updateOffRoute()
            }
            // Feed the puck the engine's filtered position per fix (raw while acquiring so "you"
            // shows instantly; Kalman tip once recording). Mapbox's LocationManager interpolates the
            // puck between these over ~1.1 s on its own optimized display link, and the follow camera
            // tracks that smooth position — so the dot and map glide without us driving a second
            // 60 fps loop (which saturated the GPU and janked the whole map).
            .onChange(of: vm.puckPoint) { _, point in
                guard let point else { return }
                if covered, Date().timeIntervalSince(lastPuckPush) < Self.coveredPuckIntervalS {
                    pendingPuck = point          // nobody can see the map; hold the newest fix
                } else {
                    pushPuck(point)
                }
            }
            // The page starts to reveal the map: push the held position NOW, before a pixel of the
            // map is visible, so the dot is already gliding onto the tip as the page slides away.
            .onChange(of: covered) { _, isCovered in
                if !isCovered, let p = pendingPuck { pushPuck(p) }
            }
            .ignoresSafeArea()
            // We keep the camera locked on the athlete (follows the puck) so we control the zoom. A
            // manual pan or pinch drops the lock; the recenter arrow — or a few seconds of not
            // touching the map — re-engages it.
            .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in onUserGesture() })
            .simultaneousGesture(MagnifyGesture().onChanged { _ in onUserGesture() })
        }
        .opacity(mapReady ? 1 : 0)
    }

    private func pushPuck(_ point: CardioViewModel.LivePoint) {
        puckFeed.push(lat: point.lat, lon: point.lon)
        lastPuckPush = Date()
        pendingPuck = nil
    }

    /// Builds/updates the route layers: a dashed guide loop beneath the live trace (white casing +
    /// solid purple). The trace is solid, not a gradient — Mapbox's `line-gradient` crashes when its
    /// source is updated live, so the gradient lives on the completed-route maps (`RouteMapView`).
    ///
    /// The trace source is a FeatureCollection: frozen spline chunks are **appended once**
    /// (`addGeoJSONSourceFeatures`) and only the short live tail is **replaced** per fix
    /// (`updateGeoJSONSourceFeatures`) — so the payload handed to Mapbox each second is
    /// constant-size, not the whole ever-growing route. Chunks share their boundary point, so the
    /// line renders continuous; a data-gap split simply yields disjoint features (no chord).
    /// `delta == nil` means the style reloaded → rebuild the source from the smoother's full state.
    private func syncRouteLayers(_ map: MapboxMap?, delta: RouteSmoothing.LiveSmoother.Delta?) {
        guard let map, map.isStyleLoaded else { return }

        // Insert route layers *below* the location puck so the athlete's purple dot always sits on top
        // of the forming trace (rather than the growing line painting over "you"). The puck renders on
        // a `location-indicator` layer; find it by type so we don't depend on Mapbox's internal id.
        // Cached per style load (see `belowPuckPosition`) — never re-scanned per fix.
        if belowPuckPosition == nil {
            belowPuckPosition = map.allLayerIdentifiers.first { $0.type == "location-indicator" }
                .map { LayerPosition.below($0.id) }
        }
        let belowPuck = belowPuckPosition

        // Dashed guide loop (the static suggested route), under the trace.
        if guideRoute.count > 1 {
            let data = GeoJSONSourceData.geometry(.lineString(LineString(guideRoute.map(\.clCoordinate))))
            if map.sourceExists(withId: "guide-src") {
                try? map.updateGeoJSONSource(withId: "guide-src", data: data)
            } else {
                var source = GeoJSONSource(id: "guide-src"); source.data = data
                try? map.addSource(source)
                var layer = LineLayer(id: "guide-line", source: "guide-src")
                    .lineColor(StyleColor(UIColor(guideColor)))
                    .lineWidth(4).lineCap(.round).lineJoin(.round)
                    .lineEmissiveStrength(1)   // self-lit — night-lit Standard scenes dim unlit layers
                layer.lineDasharray = .constant([1.6, 2.4])
                try? map.addLayer(layer, layerPosition: belowPuck)
            }
        }

        // Live trace — nothing to draw until there's a line.
        guard !smoother.allChunks.isEmpty || smoother.tail.count > 1 else { return }

        if !map.sourceExists(withId: "trace-src") {
            // Fresh style (first draw, or a mid-run style switch wiped the sources): rebuild the
            // whole trace from the smoother's retained state.
            var features = smoother.allChunks.enumerated().map { chunkFeature($1, index: $0) }
            features.append(tailFeature(smoother.tail))
            var source = GeoJSONSource(id: "trace-src")
            source.data = .featureCollection(FeatureCollection(features: features))
            try? map.addSource(source)
            let casing = LineLayer(id: "trace-casing", source: "trace-src")
                .lineColor(StyleColor(UIColor.white))
                .lineWidth(8.5).lineCap(.round).lineJoin(.round)
                .lineEmissiveStrength(1)
            try? map.addLayer(casing, layerPosition: belowPuck)
            let line = LineLayer(id: "trace-line", source: "trace-src")
                .lineColor(StyleColor(UIColor(Theme.route)))
                .lineWidth(5.5).lineCap(.round).lineJoin(.round)
                .lineEmissiveStrength(1)
            try? map.addLayer(line, layerPosition: belowPuck)
            return
        }

        guard let delta else { return }
        if !delta.newChunks.isEmpty {
            let start = smoother.allChunks.count - delta.newChunks.count
            let features = delta.newChunks.enumerated().map { chunkFeature($1, index: start + $0) }
            map.addGeoJSONSourceFeatures(forSourceId: "trace-src", features: features)
        }
        // A just-split segment can briefly have a sub-2-point tail; the finalized chunk already
        // renders that geometry, so skipping the update never leaves a visible hole.
        if delta.tail.count > 1 {
            map.updateGeoJSONSourceFeatures(forSourceId: "trace-src", features: [tailFeature(delta.tail)])
        }
    }

    // `MapboxMaps.Feature` spelled out — the app has its own `Feature` type (paywall gating).
    private func chunkFeature(_ coords: [CLLocationCoordinate2D], index: Int) -> MapboxMaps.Feature {
        var f = MapboxMaps.Feature(geometry: .lineString(LineString(coords)))
        f.identifier = .string("trace-chunk-\(index)")
        return f
    }

    private func tailFeature(_ coords: [CLLocationCoordinate2D]) -> MapboxMaps.Feature {
        var f = MapboxMaps.Feature(geometry: .lineString(LineString(coords)))
        f.identifier = .string("trace-tail")
        return f
    }

    /// The guide line reads as a quiet dashed path — lighter over satellite imagery for contrast.
    /// Keyed to the LIVE style actually on screen, not the (possibly 3D) chosen one.
    private var guideColor: Color { liveStyle.isImagery ? .white.opacity(0.65) : Theme.ink.opacity(0.28) }

    /// Green "start" dot (white ring) marking where the run began — matches the completed-route map.
    private var startDot: some View {
        ZStack {
            Circle().fill(.white).frame(width: 16, height: 16)
            Circle().fill(Theme.success).frame(width: 10, height: 10)
        }
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .accessibilityLabel("Start")
    }

    /// Distance + direction from the current position to the nearest point on the guide loop, with
    /// hysteresis so the cue doesn't flicker.
    private func updateOffRoute() {
        guard tracking, guideRoute.count > 1, let here = vm.lastCoordinate else {
            if offRoute { offRoute = false }
            return
        }
        let p = GeoPoint(lat: here.latitude, lon: here.longitude)
        guard let nearest = RouteDeviation.nearest(on: guideRoute, to: p) else { return }
        let d = nearest.distanceM
        let bearing = RouteDeviation.bearing(from: p, to: nearest.point)
        if !offRoute, d > Self.offRouteM {
            deviationM = d; rejoinBearing = bearing
            offRoute = true
            Haptics.light()
        } else if offRoute {
            // Only while the banner is showing do its numbers need to move (every write here
            // re-renders the root chrome).
            if abs(d - deviationM) >= 1 { deviationM = d }
            if abs(bearing - rejoinBearing) >= 1 { rejoinBearing = bearing }
            if d < Self.onRouteM { offRoute = false }
        }
    }
}

// MARK: - Pager (stats over map; the drag is a transform, never a layout change)

/// Hosts the two live pages. The stats page rises over the map the moment recording arms; pulling
/// it down ≥140 pt (or the map button) reveals the map page with its peek card; the peek's grabber
/// (or a pull up) brings the stats page back. Owns the in-flight drag so a drag frame invalidates
/// this small view only — the pages themselves are Equatable leaves that skip re-evaluation.
private struct LivePager: View, Equatable {
    let vm: CardioViewModel
    @Binding var page: CardioTrackingView.LivePage
    let type: WorkoutType
    let distanceUnit: DistanceUnit
    let structured: StructuredWorkout?
    let goalMeters: Double?
    let targetPaceSPerKm: Double?
    let sessionLine: String
    let hasGuide: Bool
    /// Fired with `true` on the FIRST frame of a pull-down (and `false` when the drag ends or the
    /// page settles) — never per frame. The root relays it to `LiveMapLayer.covered` so the puck
    /// throttle releases the moment the map starts to show under the sliding page, not at commit.
    let onDragReveal: (Bool) -> Void
    let onClose: () -> Void
    let onFinish: () -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.vm === b.vm && a.page == b.page && a.type == b.type && a.sessionLine == b.sessionLine
            && a.goalMeters == b.goalMeters && a.targetPaceSPerKm == b.targetPaceSPerKm
            && a.hasGuide == b.hasGuide && (a.structured == nil) == (b.structured == nil)
    }

    @State private var pageDrag: CGFloat = 0
    /// Whether this drag has already signalled `onDragReveal(true)` — the edge detector that keeps
    /// the signal to two calls per gesture instead of one per frame.
    @State private var dragRevealing = false
    @State private var screenHeight: CGFloat = 900
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The stats page's vertical travel while it's off: the full measured screen plus a margin.
    private var statsOffset: CGFloat {
        switch page {
        case .stats: max(0, pageDrag)
        case .map: screenHeight + 40
        }
    }

    /// The peek card fades in as the stats page is pulled away, and is fully present on the map page.
    private var peekOpacity: Double {
        page == .map ? 1 : min(1, Double(max(0, pageDrag)) / 220)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // The peek is mounted only once it can be seen (map page, or mid-pull); its controls
            // would otherwise shadow the stats page's for assistive tech.
            if page == .map || pageDrag > 0 {
                LiveMapPeek(vm: vm, type: type, active: page == .map,
                            onShowStats: { setPage(.stats) }, onFinish: onFinish)
                    .equatable()
                    .opacity(peekOpacity)
                    .gesture(peekDragGesture)
                    // Unmounts the instant `page` flips back to stats (mid-slide) — without
                    // a fade it vanished in one frame under the rising page.
                    .transition(.opacity)
            }
            LiveStatsPage(vm: vm, type: type, distanceUnit: distanceUnit, structured: structured,
                          goalMeters: goalMeters, targetPaceSPerKm: targetPaceSPerKm,
                          sessionLine: sessionLine, hasGuide: hasGuide, active: page == .stats,
                          onClose: onClose, onShowMap: { setPage(.map) }, onFinish: onFinish)
                .equatable()
                .offset(y: statsOffset)
                .gesture(pageDragGesture)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { screenHeight = $0 })
    }

    private func setPage(_ p: CardioTrackingView.LivePage) {
        guard p != page else { return }
        Haptics.selection()
        if dragRevealing { dragRevealing = false; onDragReveal(false) }
        withAnimation(reduceMotion ? nil : Motion.travel) {
            page = p
            pageDrag = 0
        }
    }

    /// Pull the stats page down to reveal the map. The page is opaque and sits above the map, so
    /// this drag never competes with Mapbox's own pan (the lesson from the Today deck). The drag
    /// writes a raw offset (no implicit animation — a spring fighting the finger reads as lag);
    /// only the release springs.
    private var pageDragGesture: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .onChanged { v in
                guard page == .stats else { return }
                pageDrag = max(0, v.translation.height)
                // Edge-detected reveal signal: the map becomes visible under the page from the
                // very first pulled point, so the puck must resume right here — not at commit.
                let revealing = pageDrag > 0
                if revealing != dragRevealing { dragRevealing = revealing; onDragReveal(revealing) }
            }
            .onEnded { v in
                guard page == .stats else { return }
                if dragRevealing { dragRevealing = false; onDragReveal(false) }
                let commit = v.translation.height > 140 || v.predictedEndTranslation.height > 360
                withAnimation(reduceMotion ? nil : Motion.travel) {
                    pageDrag = 0
                    if commit { page = .map }
                }
                if commit { Haptics.selection() }
            }
    }

    /// Pull the peek card up to bring the stats back. Attached to the whole peek (the card is
    /// opaque and sits over the map), so the gesture never reaches Mapbox's pan.
    private var peekDragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onEnded { v in
                if v.translation.height < -40 || v.predictedEndTranslation.height < -160 { setPage(.stats) }
            }
    }
}

// MARK: - Stats page (Strava's record-screen stack, in our language)

/// The primary live page: a vertical stack of full-width stat rows — a small uppercase caption over
/// a large tabular numeral, hairlines between — with DISTANCE dominant at the top, then TIME, then
/// AVG PACE | CURRENT PACE, then HEART RATE when a monitor is live. Structured sessions keep their
/// step strip at the top and planned runs their goal strip; one coach line sits in a fixed slot so
/// its arrival never moves the numbers; the shared controls ride at the thumb.
///
/// Equatable on its VALUE inputs only: `vm` is observed inside (a fix still re-renders the rows via
/// `vm.readout`), and the closures never change meaning — so a page drag or a root re-render
/// doesn't re-evaluate the page.
private struct LiveStatsPage: View, Equatable {
    let vm: CardioViewModel
    let type: WorkoutType
    let distanceUnit: DistanceUnit
    let structured: StructuredWorkout?
    let goalMeters: Double?
    let targetPaceSPerKm: Double?
    let sessionLine: String
    let hasGuide: Bool
    let active: Bool
    let onClose: () -> Void
    let onShowMap: () -> Void
    let onFinish: () -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.vm === b.vm && a.type == b.type && a.sessionLine == b.sessionLine && a.active == b.active
            && a.goalMeters == b.goalMeters && a.targetPaceSPerKm == b.targetPaceSPerKm
            && a.hasGuide == b.hasGuide && (a.structured == nil) == (b.structured == nil)
    }

    var body: some View {
        let r = vm.readout
        VStack(spacing: 0) {
            Capsule().fill(Theme.hairline).frame(width: 36, height: 5)
                .padding(.top, Theme.Space.sm).padding(.bottom, Theme.Space.xs)
            header
            VStack(spacing: 0) {
                if structured != nil {
                    LiveStructuredStrip(vm: vm).padding(.bottom, Theme.Space.md)
                } else if let goalMeters {
                    LiveGoalStrip(vm: vm, goal: goalMeters, distanceUnit: distanceUnit,
                                  targetPaceSPerKm: targetPaceSPerKm, hasGuide: hasGuide)
                        .padding(.bottom, Theme.Space.md)
                }
                LiveCoachLine(vm: vm, style: .page)
                Spacer(minLength: 0)
                statStack(r)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, Theme.Space.sm)
            LiveControls(vm: vm, onDark: false, active: active, onFinish: onFinish)
                .padding(.horizontal, Theme.Space.md)
                .padding(.bottom, Theme.Space.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .contentShape(Rectangle())
        .accessibilityHidden(!active)
        .allowsHitTesting(active)
    }

    /// Close · what today is · map. The middle line is the plan's shape up front ("14 mi easy,
    /// about 9:40 /mi"), so the athlete never has to remember what they set out to do.
    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.sm) {
            Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 38, height: 38).momentumGlass(in: Circle())
                .mapSafeTap("Close", action: onClose)
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Text(type.title.uppercased())
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                    .foregroundStyle(Theme.inkTertiary)
                Text(sessionLine)
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            Image(systemName: "map").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 38, height: 38).momentumGlass(in: Circle())
                .mapSafeTap("Show map", action: onShowMap)
        }
        .padding(.horizontal, Theme.Space.md)
    }

    /// The stack. Numbers dim while paused — the figures themselves say "held"; never a red state.
    private func statStack(_ r: CardioViewModel.Readout) -> some View {
        VStack(spacing: 0) {
            // DISTANCE — the hero: the largest numeral on the screen, unit riding small beside it.
            VStack(spacing: Theme.Space.xs) {
                LiveCaption("Distance")
                StatNumeral(value: r.distance, unit: r.distanceUnit, size: 92)
                    .accessibilityLabel("Distance")
                    .accessibilityValue("\(r.distance) \(r.distanceUnit)")
                    // Pinned by the run-flow UI tripwire (the live number must actually move):
                    // the recorder sits behind `.equatable()` walls, so a frozen page would pass
                    // every control-flip assertion while showing 0.00 forever.
                    .accessibilityIdentifier("liveDistance")
            }
            .padding(.bottom, Theme.Space.xs)
            rule
            // TIME
            VStack(spacing: Theme.Space.xs) {
                if let word = r.pausedWord {
                    Text(word.uppercased())
                        .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                        .foregroundStyle(Theme.inkSecondary)
                        .accessibilityLabel(word)
                } else {
                    LiveCaption("Time")
                }
                LiveClockText(vm: vm, size: 48, ink: r.isPaused ? Theme.inkTertiary : Theme.ink)
            }
            .padding(.vertical, Theme.Space.sm)
            rule
            // AVG PACE | CURRENT PACE (speed on a ride)
            HStack(alignment: .top, spacing: 0) {
                statCell("Avg " + r.paceLabel, value: r.avgPace, unit: r.avgPaceUnit)
                columnRule
                // A guided step's target rides under the live pace — the number to hold, right
                // where the athlete is reading the number they're holding.
                statCell(structured != nil ? r.paceLabel : "Current " + r.paceLabel, value: r.pace, unit: r.paceUnit,
                         note: structured != nil ? vm.stepTargetPaceText.map { "target \($0)" } : nil)
            }
            .padding(.vertical, Theme.Space.sm)
            // HEART RATE / ZONE — only once a monitor has been live. If the source then goes
            // stale (strap dropout, Watch out of range) the row HOLDS with the same placeholder
            // the pace cells use — never the last number (a reading nobody took), and never a
            // mid-run layout jump from the row unmounting.
            if r.bpm != nil || r.hrStale {
                rule
                HStack(spacing: 0) {
                    statCell("Heart rate", value: r.bpm.map { "\($0)" } ?? "--", unit: "bpm")
                    if let zone = r.zone {
                        columnRule
                        statCell("Zone", value: zone, unit: nil)
                    }
                }
                .padding(.vertical, Theme.Space.sm)
            }
            rule
            // The quiet row: cadence + signal.
            HStack(spacing: Theme.Space.lg) {
                if let cad = r.cadence {
                    quiet("\(cad) spm", "Cadence")
                }
                quiet(r.gpsWord, "Signal")
            }
            .padding(.top, Theme.Space.sm)
        }
        .opacity(r.isPaused ? 0.45 : 1)
        .animation(Motion.standard, value: r.isPaused)
    }

    private var rule: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
    /// Fixed height: a bare Rectangle is greedy and would stretch its whole row to fill the page.
    private var columnRule: some View { Rectangle().fill(Theme.hairline).frame(width: 1, height: 44) }

    private func statCell(_ caption: String, value: String, unit: String?, note: String? = nil) -> some View {
        VStack(spacing: Theme.Space.xs) {
            LiveCaption(caption)
            StatNumeral(value: value, unit: unit, size: 36)
            if let note {
                Text(note)
                    .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityValue("\(value) \(unit ?? "")" + (note.map { ", \($0)" } ?? ""))
    }

    private func quiet(_ value: String, _ caption: String) -> some View {
        HStack(spacing: 6) {
            Text(caption.uppercased())
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1)
                .foregroundStyle(Theme.inkTertiary)
            Text(value)
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The small uppercase caption above every stat row.
private struct LiveCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
            .foregroundStyle(Theme.inkTertiary)
            .lineLimit(1).minimumScaleFactor(0.8)
    }
}

// MARK: - Clock (the only thing that ticks)

/// Elapsed time on its own one-second `TimelineView`, so the tick invalidates this text alone.
/// Reads only the clock's inputs (start + pause spans) — never the snapshot.
private struct LiveClockText: View {
    let vm: CardioViewModel
    let size: CGFloat
    let ink: Color

    var body: some View {
        TimelineView(.periodic(from: vm.startedAt, by: 1)) { ctx in
            let text = Formatters.duration(s: vm.elapsed(at: ctx.date))
            Text(text)
                .font(.display(size, weight: .heavy)).monospacedDigit()
                .foregroundStyle(ink)
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.6)
                .accessibilityLabel("Time")
                .accessibilityValue(text)
                // Only one instance is ever accessible (the covered page hides its whole tree),
                // so the identifier stays unique for the run-flow UI tripwire.
                .accessibilityIdentifier("liveClock")
        }
    }
}

// MARK: - Coach line

/// The one coach line. A fixed slot so its arrival never moves the numbers; the text itself
/// crossfades in and fades out on the view model's own clock (one line at a time, ever). The chip
/// variant floats over the map above the peek card.
private struct LiveCoachLine: View {
    enum Style { case page, chip }
    let vm: CardioViewModel
    let style: Style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let line = vm.coachLine {
                HStack(alignment: .top, spacing: Theme.Space.sm) {
                    Circle().fill(Theme.purple).frame(width: 6, height: 6).padding(.top, style == .page ? 7 : 6)
                    Text(line)
                        .font(.rounded(style == .page ? Theme.FontSize.body : Theme.FontSize.caption,
                                       weight: style == .page ? .medium : .semibold))
                        .monospacedDigit()
                        .foregroundStyle(style == .page ? Theme.ink : .white)
                        .lineLimit(2).minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                    if style == .page { Spacer(minLength: 0) }
                }
                .padding(.horizontal, style == .chip ? Theme.Space.md : 0)
                .padding(.vertical, style == .chip ? Theme.Space.sm : 0)
                .background {
                    if style == .chip {
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(LivePeekPalette.card)
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                                .stroke(.white.opacity(0.08), lineWidth: 1))
                    }
                }
                .id(line)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Coach: \(line)")
            }
        }
        .frame(maxWidth: .infinity, minHeight: style == .page ? 44 : 0, alignment: style == .page ? .topLeading : .center)
        // A crossfade is the one motion Reduce Motion keeps (static iridescence + crossfades); the
        // line still never slides.
        .animation(.easeInOut(duration: reduceMotion ? 0.2 : 0.35), value: vm.coachLine)
    }
}

// MARK: - Shared controls (identical on both pages)

/// One primary action (the CTA rule): Pause is the lavender pill — the thing happening now.
/// Finish rides beside it as a small glass stop while running (a mis-tap mid-run is real; the
/// confirmation still guards it) and grows to a full ink pill on pause, when finishing is the
/// likely next move. Rendered by BOTH pages from this one view so they can never drift.
private struct LiveControls: View {
    let vm: CardioViewModel
    let onDark: Bool
    let active: Bool
    let onFinish: () -> Void

    var body: some View {
        let paused = vm.readout.isPaused
        HStack(spacing: Theme.Space.sm) {
            Button {
                Task {
                    if paused { await vm.resume(); Haptics.success() }
                    else { await vm.pause(); Haptics.medium() }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                    Text(paused ? "Resume" : "Pause")
                }
                .font(.rounded(Theme.FontSize.body, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 56)
                .background(Capsule().fill(Theme.purple))
                .contentShape(Capsule())
            }
            .buttonStyle(PressableScaleStyle(scale: 0.97))
            .accessibilityLabel(paused ? "Resume" : "Pause")

            if paused {
                Button(action: onFinish) {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                        Text("Finish")
                    }
                    .font(.rounded(Theme.FontSize.body, weight: .semibold))
                    // On the charcoal peek the ink pill inverts (white on dark) so Finish reads.
                    .foregroundStyle(onDark ? Color(hex: "1E1D1B") : Theme.background)
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .background(Capsule().fill(onDark ? Color.white : Theme.ink))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableScaleStyle(scale: 0.97))
                .accessibilityLabel("Finish")
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                // On the fixed-charcoal peek, glass would vanish into the card in dark mode — the
                // stop wears a fixed white-on-charcoal treatment there instead.
                Group {
                    if onDark {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(Circle().fill(.white.opacity(0.14)))
                            .overlay(Circle().stroke(.white.opacity(0.22)))
                    } else {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
                            .frame(width: 56, height: 56).momentumGlass(in: Circle())
                    }
                }
                .mapSafeTap("Finish", action: onFinish)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(Motion.standard, value: paused)
        // Only the page that owns the screen exposes its Pause/Finish — the other set is invisible
        // and must be invisible to VoiceOver + XCUITest too (one "Pause" at a time).
        .accessibilityHidden(!active)
    }
}

// MARK: - Map page peek

/// Peek card palette — fixed warm charcoal in BOTH schemes (media rooms are dark), the same
/// #1E1D1B / #2A2926 pair the dark canvas uses, so nothing re-anodizes on toggle.
private enum LivePeekPalette {
    static let card = Color(hex: "1E1D1B").opacity(0.98)
    static let ink = Color.white
    static let inkSecondary = Color.white.opacity(0.62)
}

/// The compact card over the map: the coach chip above it, then grabber, the step/sport line with
/// the signal, and the same hierarchy as the stats page in miniature — distance leading, time and
/// pace beside it — over the same controls. One opaque warm-charcoal panel in BOTH schemes so it
/// stays legible on every basemap — glass would inherit whatever map is under it.
private struct LiveMapPeek: View, Equatable {
    let vm: CardioViewModel
    let type: WorkoutType
    let active: Bool
    let onShowStats: () -> Void
    let onFinish: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.vm === b.vm && a.type == b.type && a.active == b.active }

    var body: some View {
        let r = vm.readout
        VStack(spacing: Theme.Space.sm) {
            // The coach speaks on this page too: the same one line, as a chip floating over the map
            // above the card. Stacked above a bottom-aligned card it grows upward, so the card and
            // its controls never move when a line arrives.
            LiveCoachLine(vm: vm, style: .chip)
            VStack(spacing: Theme.Space.md) {
                VStack(spacing: Theme.Space.sm) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(LivePeekPalette.inkSecondary)
                        .frame(maxWidth: .infinity).frame(height: 24)
                        .contentShape(Rectangle())
                        .mapSafeTap("Show stats", action: onShowStats)
                    HStack(spacing: Theme.Space.sm) {
                        LivePeekLeading(vm: vm, type: type)
                        Spacer(minLength: 0)
                        HStack(spacing: 3) {
                            Image(systemName: r.gpsLost ? "location.slash" : "location.fill")
                            Text(r.gpsWord)
                        }
                        .font(.rounded(Theme.FontSize.label, weight: .bold)).foregroundStyle(LivePeekPalette.inkSecondary)
                    }
                    HStack(alignment: .lastTextBaseline, spacing: Theme.Space.md) {
                        // Distance leads, at the largest size on the card.
                        VStack(alignment: .leading, spacing: 2) {
                            StatNumeral(value: r.distance, unit: r.distanceUnit, size: 44, ink: LivePeekPalette.ink)
                            peekCaption("Distance")
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Distance")
                        .accessibilityValue("\(r.distance) \(r.distanceUnit)")
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 2) {
                            LiveClockText(vm: vm, size: 26, ink: r.isPaused ? LivePeekPalette.inkSecondary : LivePeekPalette.ink)
                            if let word = r.pausedWord {
                                Text(word.uppercased())
                                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1)
                                    .foregroundStyle(LivePeekPalette.inkSecondary)
                                    .accessibilityLabel(word)
                            } else {
                                peekCaption("Time")
                            }
                        }
                        VStack(alignment: .trailing, spacing: 2) {
                            StatNumeral(value: r.pace, unit: r.paceUnit, size: 26, ink: LivePeekPalette.ink)
                            peekCaption(r.paceLabel)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(r.paceLabel)
                        .accessibilityValue("\(r.pace) \(r.paceUnit ?? "")")
                    }
                    .opacity(r.isPaused ? 0.45 : 1)
                    .animation(Motion.standard, value: r.isPaused)
                }
                .padding(.horizontal, Theme.Space.md)
                LiveControls(vm: vm, onDark: true, active: active, onFinish: onFinish)
                    .padding(.horizontal, Theme.Space.sm)
            }
            .padding(.bottom, Theme.Space.sm)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous).fill(LivePeekPalette.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        }
        .padding(Theme.Space.md)
        .accessibilityHidden(!active)
        .allowsHitTesting(active)
    }

    private func peekCaption(_ text: String) -> some View {
        Text(text.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1)
            .foregroundStyle(LivePeekPalette.inkSecondary)
    }
}

/// The peek's leading slot: the current guided step ("REP 3 / 6 · 240 m") when there is one,
/// else the sport glyph. Its own view so the per-second step countdown touches nothing else.
private struct LivePeekLeading: View {
    let vm: CardioViewModel
    let type: WorkoutType

    var body: some View {
        if vm.currentStep != nil {
            TimelineView(.periodic(from: vm.startedAt, by: 1)) { _ in
                let rem = vm.stepRemaining
                Text("\(vm.stepTitle.uppercased()) · \(rem.value) \(rem.caption.replacingOccurrences(of: " LEFT", with: ""))")
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(0.8).monospacedDigit()
                    .foregroundStyle(LivePeekPalette.inkSecondary).lineLimit(1)
            }
        } else {
            Image(systemName: type.discipline == .cycling ? "bicycle" : "figure.run")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(LivePeekPalette.inkSecondary)
        }
    }
}

// MARK: - Structured-workout strip (R1)

/// The guided session as one compact strip inside the stats page, not a panel of its own: step
/// name, what's left, the target, a Skip; under it a slim progress bar (iridescent while you're
/// inside the pace band — hitting the prescription is progress) with the rep dots and the next
/// step. Once every step is done the strip becomes the completion line. Ticks on its own
/// one-second timeline (timed steps count down between fixes).
private struct LiveStructuredStrip: View {
    let vm: CardioViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if vm.currentStep != nil {
            TimelineView(.periodic(from: vm.startedAt, by: 1)) { _ in
                let onPace = vm.stepAdherence == .onPace
                let rem = vm.stepRemaining
                VStack(spacing: Theme.Space.sm) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                        Text(vm.stepTitle.uppercased())
                            .font(.rounded(Theme.FontSize.caption, weight: .bold)).tracking(1.2)
                            .foregroundStyle(Theme.ink)
                            .accessibilityIdentifier("structuredStepTitle")
                        Text("\(rem.value) \(rem.caption.lowercased())")
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Theme.inkSecondary)
                        if let pace = vm.stepTargetPaceText {
                            Text("target \(pace)")
                                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(Theme.inkSecondary)
                        }
                        Spacer(minLength: 0)
                        Button { Haptics.light(); vm.skipStep() } label: {
                            Label("Skip step", systemImage: "forward.fill")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.ink)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(Theme.surface))
                                .overlay(Circle().stroke(Theme.hairline))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Skip step")
                    }
                    stepProgressBar(vm.stepProgress, onPace: onPace)
                    HStack {
                        if let reps = vm.repProgress { repDots(done: reps.done, total: reps.total) }
                        if let hint = adherenceHint(vm.stepAdherence) {
                            Text(hint).font(.rounded(Theme.FontSize.label, weight: .semibold))
                                .foregroundStyle(Theme.inkSecondary)
                        }
                        Spacer(minLength: 0)
                        if let next = vm.stepNextText {
                            Text(next).font(.rounded(Theme.FontSize.label, weight: .semibold))
                                .foregroundStyle(Theme.inkTertiary)
                        }
                    }
                }
                .animation(Motion.standard, value: onPace)
                .accessibilityHint(onPace ? "On pace" : "")
            }
        } else if vm.structuredComplete {
            structuredCompletePill
        }
    }

    /// A slim step-progress capsule — iridescent while you're on pace, monochrome otherwise.
    private func stepProgressBar(_ progress: Double, onPace: Bool) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule()
                    .fill(onPace ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.ink))
                    .frame(width: max(6, geo.size.width * min(1, max(0, progress))))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: progress)
            }
        }
        .frame(height: 5)
    }

    /// A dot per rep — filled for completed reps, iridescent for the one in progress.
    private func repDots(done: Int, total: Int) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<total, id: \.self) { i in
                Circle()
                    .fill(i < done ? AnyShapeStyle(Theme.ink)
                          : i == done ? AnyShapeStyle(IridescentMaterial())
                          : AnyShapeStyle(Theme.hairline))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityLabel("Rep \(min(done + 1, total)) of \(total)")
    }

    /// A quiet fact mirroring the audio cue; nil when on pace / no target. Never a red state.
    private func adherenceHint(_ a: StructuredRunTracker.Adherence) -> String? {
        switch a { case .tooFast: "a touch quick"; case .tooSlow: "a touch slow"; default: nil }
    }

    /// Shown once every step is done — the prescription is complete. Earned iridescent tint.
    private var structuredCompletePill: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 15, weight: .bold))
            Text("Workout complete")
                .font(.rounded(Theme.FontSize.caption, weight: .bold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
        .background(IridescentMaterial().opacity(0.22), in: Capsule())
        .overlay(Capsule().strokeBorder(IridescentMaterial(), lineWidth: 1))
        .accessibilityIdentifier("structuredComplete")
    }
}

// MARK: - Goal strip (planned easy/long + free runs with a distance)

/// Progress toward the distance goal with the plan's pace beside it — the day's shape stays on
/// the page, not in the athlete's memory. Iridescent once the goal is reached.
private struct LiveGoalStrip: View {
    let vm: CardioViewModel
    let goal: Double
    let distanceUnit: DistanceUnit
    let targetPaceSPerKm: Double?
    let hasGuide: Bool
    @State private var goalReached = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var goalText: String {
        Formatters.distance(meters: goal, unit: distanceUnit).components(separatedBy: " ").first ?? "0"
    }

    private var targetText: String? {
        targetPaceSPerKm.map {
            "\(CoachingCueBuilder.clockPace(secPerKm: $0, unit: distanceUnit, roundTo: 5)) \(distanceUnit.resolved() == .imperial ? "/mi" : "/km")"
        }
    }

    var body: some View {
        let r = vm.readout
        let progress = r.goalProgress
        let percent = Int((progress * 100).rounded())
        let trailing: String = goalReached ? "Goal reached"
            : targetText.map { "target \($0)" } ?? (hasGuide ? "your loop" : "\(percent)%")
        let spokenTarget = targetText.map { ", target pace \($0)" } ?? ""
        VStack(spacing: Theme.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(r.distance) / \(goalText) \(r.distanceUnit)")
                    .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                Text(trailing)
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    Capsule()
                        .fill(goalReached ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.ink))
                        .frame(width: max(6, geo.size.width * progress))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: progress)
                }
            }
            .frame(height: 5)
        }
        .onChange(of: progress) { if progress >= 1 && !goalReached { goalReached = true; Haptics.celebration() } }
        // The capsule fill is the visual progress; VoiceOver gets the percent + numbers so the
        // iridescent "reached" state is never the sole signal (PRD §13.4).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(goalReached ? "Goal reached" : "Goal progress")
        .accessibilityValue("\(r.distance) of \(goalText) \(r.distanceUnit), \(percent) percent" + spokenTarget)
    }
}

/// Bridges our filtered position into the Mapbox puck. By default the puck (and the `.followPuck`
/// camera) render raw CoreLocation, independent of the accept gate and Kalman filter that protect
/// the trace — so a rejected GPS spike would teleport the dot and lurch the camera while the line
/// correctly ignored it. Overriding the map's `LocationDataModel` puts dot, camera, and trace on
/// the SAME clean track. Heading still comes from the system so the direction cone keeps working.
@MainActor
private final class PuckFeed {
    private let subject = CurrentValueSubject<[Location], Never>([])
    private let heading = AppleLocationProvider()   // heading only; position comes from `subject`

    func attach(to proxy: MapProxy) {
        proxy.location?.dataModel = LocationDataModel(
            location: subject.eraseToAnyPublisher(),
            heading: heading.onHeadingUpdate.eraseToAnyPublisher())
    }

    func push(lat: Double, lon: Double) {
        subject.send([Location(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                               timestamp: Date())])
    }
}
