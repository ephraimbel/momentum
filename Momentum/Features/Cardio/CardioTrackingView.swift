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
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Tight street-level framing (~400m across) for running.
    private static let runSpan = MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)

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
                let model = CardioViewModel(type: type, container: container, distanceUnit: distanceUnit)
                model.beginAcquiring()
                vm = model
            }
        }
        // Leave the acquiring gate the instant we have a usable lock (Strava's "GPS Signal Acquired").
        .onChange(of: vm?.hasGPSLock ?? false) { _, locked in
            if locked, phase == .acquiring { proceedToCountdown() }
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
        Map(position: $camera) {
            UserAnnotation()
            if smoothedRoute.count > 1 {
                // Earned-iridescence live route (PRD §6): a soft white halo makes the gradient read
                // as glowing on the light map. The gradient is static — safe under Reduce Motion.
                MapPolyline(coordinates: smoothedRoute)
                    .stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: smoothedRoute)
                    .stroke(routeGradient, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            if let last = routeCoords.last {
                Annotation("", coordinate: last) { BreathingDot() }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .ignoresSafeArea()
        // MapKit follows the user natively in `.userLocation` mode — smooth and jitter-free. We no
        // longer re-issue a region animation per fix (overlapping animations fought each other and
        // snapped the camera to raw, noisy points). If the user pans away, MapKit drops follow; the
        // recenter button re-engages it.
        .overlay(alignment: .bottomTrailing) { if phase == .tracking { recenterButton } }
    }

    /// The live trace, corner-rounded so the sparse (≥2m) accepted points read as a fluid GPS track.
    private var smoothedRoute: [CLLocationCoordinate2D] { RouteSmoothing.smooth(routeCoords) }

    /// Oil-slick gradient for the live route — the earned-progress accent (PRD §6, §18).
    private var routeGradient: LinearGradient {
        LinearGradient(colors: Theme.iridescent, startPoint: .leading, endPoint: .trailing)
    }

    private var recenterButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.4)) { camera = .userLocation(fallback: .automatic) }
        } label: {
            Image(systemName: "location.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 40, height: 40).background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(Theme.hairline))
        }
        .padding(.trailing, Theme.Space.md)
        .padding(.bottom, 220) // clear the stats panel
        .accessibilityLabel("Recenter map")
    }

    private var topBar: some View {
        VStack {
            HStack {
                Button { phase == .tracking ? (confirmStop = true) : cancelAndDismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(width: 38, height: 38).background(.regularMaterial, in: Circle())
                }
                Spacer()
                if phase == .tracking, let vm {
                    HStack(spacing: 4) {
                        Image(systemName: "location.fill")
                        Text(vm.gpsStrength > 0.66 ? "Strong" : vm.gpsStrength > 0.33 ? "OK" : "Weak")
                    }
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 10).padding(.vertical, 6).background(.regularMaterial, in: Capsule())
                }
            }
            .padding(Theme.Space.md)
            if phase == .tracking, let vm, vm.locationDenied {
                deniedBanner.padding(.horizontal, Theme.Space.md)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .animation(Motion.standard, value: vm?.locationDenied)
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.sheet))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sheet).stroke(Theme.hairline))
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
            .background(panelBackground)

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
            Text("\(distanceNumber(forMeters: distance)) / \(goalNum) \(unitLabel)")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.inkTertiary)
        }
        .padding(.horizontal, Theme.Space.lg)
        .onChange(of: progress) { if progress >= 1 && !goalReached { goalReached = true; Haptics.celebration() } }
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

    private var panelBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.sheet).fill(.regularMaterial)
            RoundedRectangle(cornerRadius: Theme.Radius.sheet).stroke(Theme.hairline)
        }
    }

    /// Run the 3-2-1 countdown, then arm the recording. Reached once we have a GPS lock (auto) or
    /// the user taps "Start now" from the acquiring gate.
    private func proceedToCountdown() {
        guard phase == .acquiring else { return }   // ignore a late lock once we've already advanced
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
