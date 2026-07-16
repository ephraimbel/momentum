import SwiftUI
import MapboxMaps
import SwiftData
import CoreLocation
import Combine
import UIKit

/// The immersive cardio recording experience (PRD §4.3) — presented after the user picks an
/// activity + goal on the map-first Today. Runs a 3-2-1 countdown, then records: a solid black
/// route trace, distance-in-miles hero, a continuous elapsed timer, and goal progress.
struct CardioTrackingView: View {
    let type: WorkoutType
    let goalMeters: Double?
    let container: ModelContainer
    var distanceUnit: DistanceUnit = .auto
    /// An optional suggested loop to follow — drawn as a faint dashed guide beneath the live trace.
    var guideRoute: [GeoPoint] = []
    /// An optional guided structured session (warm-up → reps → cool-down) to coach through in real time.
    var structured: StructuredWorkout? = nil
    var onFinish: (UUID?) -> Void

    enum Phase { case acquiring, countdown, tracking }

    @Query private var workouts: [Workout]
    @Environment(\.colorScheme) private var colorScheme
    @Query private var profiles: [UserProfile]   // for max HR → live zone banding
    @State private var phase: Phase = .acquiring
    @State private var countdown = 3
    /// Where the run began — captured from the athlete's known position the INSTANT recording arms,
    /// so the green start pin drops immediately on "GO" rather than waiting for the first accepted
    /// route point (which lands up to a fix interval later, and read as a delayed dot).
    @State private var startCoordinate: CLLocationCoordinate2D?
    @State private var viewport: Viewport = .idle
    @State private var confirmStop = false
    @State private var vm: CardioViewModel?
    @State private var goalReached = false
    @State private var acquirePulse = false
    @State private var acquireTimedOut = false
    /// Set when the user backs out via X — gates the countdown task so a cancelled start can't arm.
    @State private var dismissed = false
    // Shared app-wide base-map choice (see MapStyleOption.storageKey) — the style picked on Today
    // is the style the run records with, and vice versa.
    @AppStorage(MapStyleOption.storageKey) private var mapStyle: MapStyleOption = .realistic
    @State private var offRoute = false        // drifted off the guide loop (hysteresis-gated)
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
    @State private var deviationM = 0.0
    @State private var rejoinBearing = 0.0     // compass bearing to the nearest loop point (north-up)
    /// While true the camera stays locked on the athlete (zoomed in, north-up). A pan/pinch drops it;
    /// the recenter arrow re-engages it.
    @State private var followsUser = true
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(Services.self) private var services

    /// Off-route hysteresis: flag once past `offRouteM`, clear only back under `onRouteM` — so a fix
    /// hovering near the edge doesn't flicker the cue.
    private static let offRouteM = 35.0
    private static let onRouteM = 20.0

    /// Locked-on zoom, tuned per discipline: street-tight for foot sports, one step wider for
    /// cycling so 30-50 km/h doesn't scroll the world past faster than it reads.
    private var followZoom: Double { type.discipline == .cycling ? 15 : 16 }

    /// The locked-on follow viewport — follows the location puck, north-up, at a tight running zoom.
    private var followViewport: Viewport { .followPuck(zoom: followZoom, bearing: .constant(0)) }

    /// What the LIVE map actually renders: the flat 2D equivalent of the athlete's chosen style, so
    /// a follow-camera over a heavy 3D/satellite basemap can't jank the run screen. Their real
    /// choice (`mapStyle`) still drives the layers picker and the saved run's snapshot.
    private var liveStyle: MapStyleOption { mapStyle.liveTrackingStyle }

    private var unitLabel: String { distanceUnit.resolved() == .imperial ? "mi" : "km" }
    private var routeCoords: [CLLocationCoordinate2D] { vm?.coordinates ?? [] }

    /// Most recent prior route's location, used to frame the map until a live fix arrives — so we
    /// never show the whole country while waiting for GPS.
    private var lastKnownCoordinate: CLLocationCoordinate2D? {
        workouts
            .sorted { $0.startedAt > $1.startedAt }
            .lazy
            .compactMap { $0.gps?.samples.first(where: { $0.accepted }) }
            .first
            .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer
            topBar
            switch phase {
            case .acquiring: acquiringOverlay
            case .countdown: countdownOverlay
            case .tracking:
                if let vm {
                    trackingPanel(vm)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .task {
            if vm == nil {
                // Voice coach is Pro (PRD §10) — pass it only when entitled, else nil (silent).
                let voice = services.paywall.isEntitled(to: .voiceCoach) ? services.voiceCoach : nil
                let model = CardioViewModel(type: type, container: container, distanceUnit: distanceUnit,
                                            goalMeters: goalMeters, structured: structured, voice: voice,
                                            motion: services.motion, maxHR: profiles.first?.maxHR)
                model.beginAcquiring()
                vm = model
            }
        }
        // Leave the acquiring gate the instant we have a usable lock (Strava's "GPS Signal Acquired").
        .onChange(of: vm?.hasGPSLock ?? false) { _, locked in
            if locked, phase == .acquiring { proceedToCountdown() }
        }
        // Each new fix: re-evaluate the off-route cue and, while locked on, slide the camera to keep
        // the athlete centered at the tight running zoom.
        .onChange(of: routeCoords.count) { updateOffRoute() }   // followPuck keeps the camera centered
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
                if routeCoords.count > 2 {
                    withAnimation(.easeInOut(duration: 0.7)) {
                        viewport = .overview(geometry: LineString(routeCoords),
                                             geometryPadding: EdgeInsets(top: 90, leading: 52, bottom: 300, trailing: 52))
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
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

            // Open over the athlete's last route's neighborhood until a live fix lands; once tracking
            // begins we follow the location puck (see `recenterOnUser`).
            if case .idle = viewport {
                viewport = lastKnownCoordinate.map { .camera(center: $0, zoom: 15) } ?? followViewport
            }
        }
    }

    private var mapLayer: some View {
        // North-up (rotation disabled) so the rejoin arrow's compass bearing reads as screen rotation.
        MapReader { proxy in
            Map(viewport: $viewport) {
                // A green dot where the run began (one stable annotation — no churn). Uses the
                // position captured at "GO" so it appears instantly; falls back to the first route
                // point if that capture was ever missed. Never triggers a spline recompute.
                if let start = startCoordinate ?? routeCoords.first {
                    MapViewAnnotation(coordinate: start) { startDot }.allowOverlap(true)
                }
                // The athlete's purple location puck ("you") is configured imperatively in
                // `.onStyleLoaded` (BrandPuck.apply) — the SwiftUI `Puck2D` crashes on devices where
                // Mapbox's default puck asset won't load.
            }
            .mapStyle(liveStyle.mapboxStyle(for: colorScheme))
            .ornamentOptions(MapChrome.hidden)
            .gestureOptions(GestureOptions(rotateEnabled: false, pitchEnabled: false))
            .onStyleLoaded { _ in
                BrandPuck.apply(to: proxy)
                puckFeed.attach(to: proxy)
                syncRouteLayers(proxy.map, delta: nil)   // style reload wiped sources → full rebuild
            }
            // Incremental: feed only the new points to the smoother; append the newly-frozen chunks
            // and replace the short live tail. No full re-smooth, no full re-upload — per-fix work
            // stays constant no matter how long the session gets.
            .onChange(of: routeCoords.count) {
                let coords = routeCoords
                let now = Date()
                traceReleaseLog.append((now, coords.count))
                traceReleaseLog.removeAll { $0.t < now.addingTimeInterval(-Self.puckLagS - 1) }
                // Draw only up to where the puck has interpolated to (the point count as of ~puckLagS
                // ago), so the trace tip tracks the dot instead of racing ahead of it. Fewer, calmer
                // tail updates also keep the line from flickering into gaps under a fast fix stream.
                let visibleCount = traceReleaseLog.last { $0.t <= now.addingTimeInterval(-Self.puckLagS) }?.count ?? 0
                if visibleCount > 0 {
                    let delta = smoother.ingest(Array(coords.prefix(visibleCount)))
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
            }
            // Feed the puck the engine's filtered position per fix (raw while acquiring so "you"
            // shows instantly; Kalman tip once recording). Mapbox's LocationManager interpolates the
            // puck between these over ~1.1 s on its own optimized display link, and the follow camera
            // tracks that smooth position — so the dot and map glide without us driving a second
            // 60 fps loop (which saturated the GPU and janked the whole map).
            .onChange(of: vm?.puckPoint) { _, point in
                if let point { puckFeed.push(lat: point.lat, lon: point.lon) }
            }
            .ignoresSafeArea()
            // We keep the camera locked on the athlete (follows the puck) so we control the zoom. A
            // manual pan or pinch drops the lock; the recenter arrow re-engages it.
            .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in followsUser = false })
            .simultaneousGesture(MagnifyGesture().onChanged { _ in followsUser = false })

        }
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
        let belowPuck = map.allLayerIdentifiers.first { $0.type == "location-indicator" }
            .map { LayerPosition.below($0.id) }

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

    private var topBar: some View {
        VStack {
            HStack(alignment: .top) {
                Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                    .frame(width: 38, height: 38).momentumGlass(in: Circle())
                    .mapSafeTap("Close") { phase == .tracking ? (confirmStop = true) : cancelAndDismiss() }
                Spacer()
                if phase == .tracking, let vm {
                    HStack(spacing: 4) {
                        Image(systemName: vm.gpsLost ? "location.slash" : "location.fill")
                        Text(vm.gpsLost ? "Searching…"
                             : vm.gpsStrength > 0.66 ? "Strong" : vm.gpsStrength > 0.33 ? "OK" : "Weak")
                    }
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 10).padding(.vertical, Theme.Space.chipV).momentumGlass()
                }
                // The right-side control column (matches Today): layers over recenter. Recenter lives
                // HERE — the old bottom-right placement hid behind the stats panel, so an athlete who
                // panned away had no visible way to lock back onto themselves.
                VStack(spacing: Theme.Space.sm) {
                    MapLayersButton(style: $mapStyle, previewCenter: routeCoords.last ?? lastKnownCoordinate)
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
                Text("\(Int(deviationM)) m — head this way to rejoin")
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.ink)
        .padding(Theme.Space.md)
        .momentumGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    /// Distance + direction from the current position to the nearest point on the guide loop, with
    /// hysteresis so the cue doesn't flicker.
    private func updateOffRoute() {
        guard phase == .tracking, guideRoute.count > 1, let here = routeCoords.last else {
            if offRoute { offRoute = false }
            return
        }
        let p = GeoPoint(lat: here.latitude, lon: here.longitude)
        guard let nearest = RouteDeviation.nearest(on: guideRoute, to: p) else { return }
        deviationM = nearest.distanceM
        rejoinBearing = RouteDeviation.bearing(from: p, to: nearest.point)
        if !offRoute, deviationM > Self.offRouteM {
            offRoute = true
            Haptics.light()
        } else if offRoute, deviationM < Self.onRouteM {
            offRoute = false
        }
    }

    /// Shown mid-recording when location is off — the time still counts, but no route is captured.
    private var deniedBanner: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "location.slash.fill").font(.system(size: 15, weight: .bold))
            VStack(alignment: .leading, spacing: 1) {
                Text("Location is off").font(.rounded(Theme.FontSize.caption, weight: .bold))
                Text("Time still counts — enable location to map your route.")
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
                    Text(denied ? "Enable location to map your route — or start now, time still counts."
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
                            systemImage: "bolt.fill", kind: .outline) { proceedToCountdown() }
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
        acquireTimedOut ? "You can start now — your route picks up once GPS locks."
                        : "Finding your position for an accurate route."
    }

    private var countdownOverlay: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()
            Text(countdown > 0 ? "\(countdown)" : "GO")
                .font(.display(96, weight: .black)).foregroundStyle(.white)
                .id(countdown).transition(.scale.combined(with: .opacity))
        }
    }

    private func trackingPanel(_ vm: CardioViewModel) -> some View {
        VStack(spacing: Theme.Space.md) {
            if vm.currentStep != nil {
                stepBanner(vm).transition(.move(edge: .top).combined(with: .opacity))
            } else if vm.structuredComplete {
                structuredCompletePill.transition(.opacity)
            }
            VStack(spacing: Theme.Space.sm) {
                if vm.isPaused {
                    Text(vm.state == .autoPaused ? "Auto-paused" : "Paused")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                }
                HeroMetric(value: distanceNumber(forMeters: vm.distanceM),
                           label: unitLabel == "mi" ? "Miles" : "Kilometers")
                TimelineView(.periodic(from: vm.startedAt, by: 1)) { ctx in
                    HStack(spacing: Theme.Space.xl) {
                        stat(Formatters.duration(s: vm.elapsed(at: ctx.date)), "Time")
                        stat(vm.heroValue, vm.heroLabel)
                        // Cadence (steps/min) from CoreMotion — run/walk only, once the hardware reports.
                        if type.discipline != .cycling, let cad = vm.cadence {
                            stat("\(cad)", "spm")
                        }
                        // Live heart rate + zone from a paired BLE strap, once it reports.
                        if let hr = vm.bpm {
                            stat("\(hr)", vm.hrZone ?? "bpm")
                        }
                    }
                }
                if let goalMeters, structured == nil { goalBar(distance: vm.distanceM, goal: goalMeters) }
            }
            .padding(.vertical, Theme.Space.md).frame(maxWidth: .infinity)
            .momentumGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))

            HStack(spacing: Theme.Space.md) {
                OversizedButton(title: vm.isPaused ? "Resume" : "Pause",
                                systemImage: vm.isPaused ? "play.fill" : "pause.fill", kind: .outline) {
                    Task { vm.isPaused ? await vm.resume() : await vm.pause() }
                }
                OversizedButton(title: "Finish", systemImage: "stop.fill") { confirmStop = true }
            }
        }
        .animation(Motion.standard, value: vm.stepTitle)
        .padding(Theme.Space.md)
        .confirmationDialog("End this \(type.title.lowercased())?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Finish", role: .destructive) { Task { onFinish(await vm.finish()) } }
            Button("Keep going", role: .cancel) {}
        }
    }

    // MARK: Structured-workout guidance (R1)

    /// The guided-step panel above the metrics: current step, big remaining count-down, target pace,
    /// rep dots, next-step preview, and a Skip control. When you're inside the target pace band the
    /// card earns an iridescent border — hitting the prescription is progress, so it glows.
    private func stepBanner(_ vm: CardioViewModel) -> some View {
        TimelineView(.periodic(from: vm.startedAt, by: 1)) { _ in
            let onPace = vm.stepAdherence == .onPace
            let rem = vm.stepRemaining
            VStack(spacing: Theme.Space.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text(vm.stepTitle.uppercased())
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).tracking(1.2)
                        .foregroundStyle(Theme.ink)
                        .accessibilityIdentifier("structuredStepTitle")
                    Spacer()
                    if let pace = vm.stepTargetPaceText {
                        Text("target \(pace)")
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    if let hint = adherenceHint(vm.stepAdherence) {
                        Text("· \(hint)")
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(rem.value).font(.display(48, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                    Text(rem.caption).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1)
                        .foregroundStyle(Theme.inkTertiary)
                    Spacer()
                }
                stepProgressBar(vm.stepProgress, onPace: onPace)
                HStack {
                    if let reps = vm.repProgress { repDots(done: reps.done, total: reps.total) }
                    Spacer()
                    if let next = vm.stepNextText {
                        Text(next).font(.rounded(Theme.FontSize.label, weight: .semibold))
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
                Button { Haptics.light(); vm.skipStep() } label: {
                    Label("Skip step", systemImage: "forward.fill")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                }
                .padding(.top, 2)
            }
            .padding(Theme.Space.md).frame(maxWidth: .infinity)
            .momentumGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous)
                    .strokeBorder(onPace ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Color.clear),
                                  lineWidth: 2)
            )
            .animation(Motion.standard, value: onPace)
            // Children stay individually accessible (VoiceOver reads step, remaining, target in order;
            // UI tests query the step title by identifier).
            .accessibilityHint(onPace ? "On pace" : "")
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
        .frame(height: 6)
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

    /// A quiet no-shame nudge string mirroring the audio cue; nil when on pace / no target.
    private func adherenceHint(_ a: StructuredRunTracker.Adherence) -> String? {
        switch a { case .tooFast: "ease back"; case .tooSlow: "pick it up"; default: nil }
    }

    /// Shown once every step is done — cool-down finished, ready to finish. Earned iridescent tint.
    private var structuredCompletePill: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 15, weight: .bold))
            Text("Workout complete — strong session")
                .font(.rounded(Theme.FontSize.caption, weight: .bold))
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
        .background(IridescentMaterial().opacity(0.22), in: Capsule())
        .overlay(Capsule().strokeBorder(IridescentMaterial(), lineWidth: 1))
        .accessibilityIdentifier("structuredComplete")
    }

    private func goalBar(distance: Double, goal: Double) -> some View {
        let progress = min(1, goal > 0 ? distance / goal : 0)
        let goalNum = distanceNumber(forMeters: goal)
        return VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    Capsule()
                        .fill(goalReached ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.ink))
                        .frame(width: max(6, geo.size.width * progress))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: progress)
                }
            }
            .frame(height: 6)
            Text("\(distanceNumber(forMeters: distance)) / \(goalNum) \(unitLabel)\(guideRoute.count > 1 ? " · your loop" : "")")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.inkTertiary)
        }
        .padding(.horizontal, Theme.Space.lg)
        .onChange(of: progress) { if progress >= 1 && !goalReached { goalReached = true; Haptics.celebration() } }
        // The capsule fill is the visual progress; VoiceOver gets the percent + numbers so the
        // iridescent "reached" state is never the sole signal (PRD §13.4).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(goalReached ? "Goal reached" : "Goal progress")
        .accessibilityValue("\(distanceNumber(forMeters: distance)) of \(goalNum) \(unitLabel), \(Int((progress * 100).rounded())) percent")
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.display(20, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1).foregroundStyle(Theme.inkTertiary)
        }
    }

    private func distanceNumber(forMeters m: Double) -> String {
        Formatters.distance(meters: m, unit: distanceUnit).components(separatedBy: " ").first ?? "0"
    }

    /// Run the 3-2-1 countdown, then arm the recording. Reached once we have a GPS lock (auto) or
    /// the user taps "Start now" from the acquiring gate.
    private func proceedToCountdown() {
        guard phase == .acquiring else { return }   // ignore a late lock once we've already advanced
        services.analytics.log(.workoutStarted(type: type.rawValue))
        withAnimation(Motion.standard) { phase = .countdown }
        Task {
            for n in [3, 2, 1] {
                withAnimation(Motion.lively) { countdown = n }
                Haptics.light()
                try? await Task.sleep(for: .seconds(0.8))
            }
            withAnimation(Motion.lively) { countdown = 0 }
            try? await Task.sleep(for: .seconds(0.5))
            // The user can tap X mid-countdown; arming after that teardown would create an orphan
            // workout (and re-set the recovery marker) with nothing on screen to finish it.
            guard !dismissed else { return }
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

