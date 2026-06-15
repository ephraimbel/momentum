import SwiftUI
import MapKit
import SwiftData
import CoreLocation
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
    var onFinish: (UUID?) -> Void

    enum Phase { case acquiring, countdown, tracking }

    @Query private var workouts: [Workout]
    @State private var phase: Phase = .acquiring
    @State private var countdown = 3
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var confirmStop = false
    @State private var vm: CardioViewModel?
    @State private var goalReached = false
    @State private var acquirePulse = false
    @State private var acquireTimedOut = false
    @State private var mapStyle: MapStyleOption = .standard
    @State private var offRoute = false        // drifted off the guide loop (hysteresis-gated)
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

    /// Tight street-level framing (~400m across) for running.
    private static let runSpan = MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
    /// Camera-to-ground distance for the locked-on running view — a tight street-level zoom.
    private static let followDistanceM = 900.0

    /// A north-up camera zoomed in on `coord` — the locked-on follow framing.
    private func followCamera(on coord: CLLocationCoordinate2D) -> MapCameraPosition {
        .camera(MapCamera(centerCoordinate: coord, distance: Self.followDistanceM, heading: 0, pitch: 0))
    }

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
                let model = CardioViewModel(type: type, container: container, distanceUnit: distanceUnit, goalMeters: goalMeters)
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
        .onChange(of: routeCoords.count) {
            updateOffRoute()
            if followsUser, phase == .tracking, let here = routeCoords.last {
                withAnimation(.easeInOut(duration: 0.45)) { camera = followCamera(on: here) }
            }
        }
        // The moment recording starts, snap in to the athlete and follow.
        .onChange(of: phase) { _, newPhase in
            if newPhase == .tracking { recenterOnUser() }
        }
        // Never imply we're still searching forever: after a beat, soften the copy to nudge "Start now".
        .task {
            try? await Task.sleep(for: .seconds(12))
            if phase == .acquiring { withAnimation(Motion.standard) { acquireTimedOut = true } }
        }
        .onAppear {
            // Center on the user (follows live); until a fix lands, fall back to their last route's
            // neighborhood rather than the default country-wide view.
            let fallback: MapCameraPosition = lastKnownCoordinate
                .map { .region(MKCoordinateRegion(center: $0, span: Self.runSpan)) } ?? .automatic
            camera = .userLocation(fallback: fallback)
        }
    }

    private var mapLayer: some View {
        // North-up (no rotation gesture) so the rejoin arrow's compass bearing reads as screen rotation.
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            UserAnnotation()
            // The suggested loop to follow, drawn first so the live trace sits on top of it.
            if guideRoute.count > 1 {
                MapPolyline(coordinates: guideRoute.map(\.clCoordinate))
                    .stroke(guideColor, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round, dash: [2, 9]))
            }
            if smoothedRoute.count > 1 {
                // The light-purple trace (the onboarding accent) over a soft white halo so it glows
                // on the light map.
                MapPolyline(coordinates: smoothedRoute)
                    .stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: smoothedRoute)
                    .stroke(Theme.route, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            if let last = routeCoords.last {
                Annotation("", coordinate: last) { BreathingDot() }
            }
        }
        .mapStyle(mapStyle.mapStyle)
        .ignoresSafeArea()
        // We keep the camera locked on the athlete ourselves (see `recenterOnUser`) so we control the
        // zoom — `.userLocation` follow can't be pinned to a tight running framing. A manual pan or
        // pinch drops the lock so the athlete can look around; the recenter arrow re-engages it.
        .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in followsUser = false })
        .simultaneousGesture(MagnifyGesture().onChanged { _ in followsUser = false })
        .overlay(alignment: .bottomTrailing) { if phase == .tracking { recenterButton } }
    }

    /// The live trace, corner-rounded so the sparse (≥2m) accepted points read as a fluid GPS track.
    private var smoothedRoute: [CLLocationCoordinate2D] { RouteSmoothing.smooth(routeCoords) }

    /// The guide line reads as a quiet dashed path — lighter over satellite imagery for contrast.
    private var guideColor: Color { mapStyle.isImagery ? .white.opacity(0.65) : Theme.ink.opacity(0.28) }

    private var recenterButton: some View {
        Button { Haptics.light(); recenterOnUser() } label: {
            // Filled when locked on the athlete, hollow once the user has panned away — so the arrow
            // reads as "tap to snap back."
            Image(systemName: followsUser ? "location.fill" : "location")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(followsUser ? Theme.ink : Theme.inkSecondary)
                .frame(width: 40, height: 40).momentumGlass(in: Circle())
        }
        .padding(.trailing, Theme.Space.md)
        .padding(.bottom, 220) // clear the stats panel
        .accessibilityLabel("Recenter on me")
    }

    /// Lock the camera back onto the athlete at the tight running zoom (north-up). Falls back to
    /// native user-location framing until the first fix lands.
    private func recenterOnUser() {
        followsUser = true
        withAnimation(.easeInOut(duration: 0.4)) {
            if let here = routeCoords.last { camera = followCamera(on: here) }
            else { camera = .userLocation(fallback: .automatic) }
        }
    }

    private var topBar: some View {
        VStack {
            HStack {
                Button { phase == .tracking ? (confirmStop = true) : cancelAndDismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(width: 38, height: 38).momentumGlass(in: Circle())
                }
                Spacer()
                MapLayersButton(style: $mapStyle)
                if phase == .tracking, let vm {
                    HStack(spacing: 4) {
                        Image(systemName: "location.fill")
                        Text(vm.gpsStrength > 0.66 ? "Strong" : vm.gpsStrength > 0.33 ? "OK" : "Weak")
                    }
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 10).padding(.vertical, Theme.Space.chipV).momentumGlass()
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
            VStack(spacing: Theme.Space.sm) {
                if vm.isPaused {
                    Text(vm.state == .autoPaused ? "Auto-paused" : "Paused")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                }
                HeroMetric(value: distanceNumber(forMeters: vm.distanceM),
                           label: unitLabel == "mi" ? "Miles" : "Kilometers")
                HStack(spacing: Theme.Space.xl) {
                    TimelineView(.periodic(from: vm.startedAt, by: 1)) { ctx in
                        stat(Formatters.duration(s: vm.elapsed(at: ctx.date)), "Time")
                    }
                    stat(vm.heroValue, vm.heroLabel)
                }
                if let goalMeters { goalBar(distance: vm.distanceM, goal: goalMeters) }
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
        .padding(Theme.Space.md)
        .confirmationDialog("End this \(type.title.lowercased())?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Finish", role: .destructive) { Task { onFinish(await vm.finish()) } }
            Button("Keep going", role: .cancel) {}
        }
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
                        .animation(.easeOut(duration: 0.4), value: progress)
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
            await vm?.arm()
            Haptics.success()
            withAnimation(Motion.standard) { phase = .tracking }
        }
    }

    private func cancelAndDismiss() {
        vm?.cancelAcquiring()
        onFinish(nil)
    }
}

/// The breathing route dot with a soft iridescent edge (PRD §6.2).
struct BreathingDot: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(IridescentMaterial()).frame(width: 28, height: 28).opacity(0.6)
            Circle().fill(Theme.route).frame(width: 15, height: 15)
            Circle().strokeBorder(.white, lineWidth: 2).frame(width: 15, height: 15)
        }
        .scaleEffect(pulse && !reduceMotion ? 1.15 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
        .accessibilityHidden(true)
    }
}
