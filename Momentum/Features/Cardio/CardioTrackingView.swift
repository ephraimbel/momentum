import SwiftUI
import MapKit
import SwiftData
import CoreLocation

/// The immersive cardio recording experience (PRD §4.3) — presented after the user picks an
/// activity + goal on the map-first Today. Runs a 3-2-1 countdown, then records: a solid black
/// route trace, distance-in-miles hero, a continuous elapsed timer, and goal progress.
struct CardioTrackingView: View {
    let type: WorkoutType
    let goalMeters: Double?
    let container: ModelContainer
    var distanceUnit: DistanceUnit = .auto
    var onFinish: (UUID?) -> Void

    enum Phase { case countdown, tracking }

    @State private var phase: Phase = .countdown
    @State private var countdown = 3
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var confirmStop = false
    @State private var vm: CardioViewModel?
    @State private var goalReached = false

    private var unitLabel: String { distanceUnit.resolved() == .imperial ? "mi" : "km" }
    private var routeCoords: [CLLocationCoordinate2D] { vm?.coordinates ?? [] }

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer
            topBar
            if phase == .countdown { countdownOverlay }
            else if let vm { trackingPanel(vm) }
        }
        .task { if vm == nil { beginCountdown() } }
    }

    private var mapLayer: some View {
        Map(position: $camera) {
            UserAnnotation()
            if routeCoords.count > 1 {
                MapPolyline(coordinates: routeCoords)
                    .stroke(Theme.route, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            if let last = routeCoords.last {
                Annotation("", coordinate: last) { BreathingDot() }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .ignoresSafeArea()
        .onChange(of: routeCoords.count) {
            guard let last = routeCoords.last else { return }
            withAnimation(.easeInOut(duration: 0.5)) {
                camera = .region(MKCoordinateRegion(center: last,
                    span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)))
            }
        }
    }

    private var topBar: some View {
        VStack {
            HStack {
                Button { phase == .tracking ? (confirmStop = true) : onFinish(nil) } label: {
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
            Spacer()
        }
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
                    Capsule().fill(Theme.ink).frame(width: max(6, geo.size.width * progress))
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

    private func beginCountdown() {
        Task {
            for n in [3, 2, 1] {
                withAnimation(Motion.lively) { countdown = n }
                Haptics.light()
                try? await Task.sleep(for: .seconds(0.8))
            }
            withAnimation(Motion.lively) { countdown = 0 }
            try? await Task.sleep(for: .seconds(0.5))
            let model = CardioViewModel(type: type, container: container, distanceUnit: distanceUnit)
            await model.start()
            Haptics.success()
            vm = model
            withAnimation(Motion.standard) { phase = .tracking }
        }
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
