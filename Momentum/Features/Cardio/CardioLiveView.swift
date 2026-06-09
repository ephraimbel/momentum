import SwiftUI
import MapKit
import SwiftData

/// The cardio live screen (PRD §4.3, §7.4): a muted monochrome map with a bright route drawn
/// behind a breathing dot, one hero metric, and an oversized pause/stop control.
struct CardioLiveView: View {
    let type: WorkoutType
    let container: ModelContainer
    var onFinish: (UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var vm: CardioViewModel?
    @State private var camera: MapCameraPosition = .automatic
    @State private var confirmStop = false
    @State private var bloomed = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Map grayscale "bloom" on start (PRD §6.2): the world eases up into view.
            mapLayer
                .opacity(bloomed ? 1 : 0)
                .saturation(bloomed ? 1 : 0)
                .scaleEffect(bloomed ? 1 : 1.04)
            topBar
            if let vm { controls(vm) }
            if vm?.state == .acquiring || vm == nil { acquiringOverlay }
        }
        .task {
            guard vm == nil else { return }
            let model = CardioViewModel(type: type, container: container)
            await model.start()
            vm = model
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { bloomed = true }
        }
    }

    @ViewBuilder
    private var mapLayer: some View {
        let coords = vm?.coordinates ?? []
        Map(position: $camera, interactionModes: [.zoom, .pan]) {
            if coords.count > 1 {
                MapPolyline(coordinates: coords)
                    .stroke(Theme.route, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let last = coords.last {
                Annotation("", coordinate: last) { BreathingDot() }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted,
                            pointsOfInterest: .excludingAll, showsTraffic: false))
        .ignoresSafeArea()
        .accessibilityLabel("Route map")
        .onChange(of: coords.count) {
            if let last = coords.last {
                withAnimation(.easeInOut(duration: 0.5)) {
                    camera = .region(MKCoordinateRegion(
                        center: last,
                        span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)))
                }
            }
        }
    }

    private var topBar: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
                gpsGlyph
            }
            .padding(.horizontal, Theme.Space.md)
            Spacer()
        }
        .foregroundStyle(Theme.ink)
    }

    private var gpsGlyph: some View {
        let strength = vm?.gpsStrength ?? 0
        return HStack(spacing: 4) {
            Image(systemName: "location.fill")
            Text(strength > 0.66 ? "Strong" : strength > 0.33 ? "OK" : "Weak")
                .font(.system(size: Theme.FontSize.caption, weight: .medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .opacity(strength > 0 ? 1 : 0.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("GPS signal")
        .accessibilityValue(strength > 0.66 ? "Strong" : strength > 0.33 ? "OK" : "Weak")
    }

    private func controls(_ vm: CardioViewModel) -> some View {
        VStack(spacing: Theme.Space.md) {
            // Hero metric panel
            VStack(spacing: Theme.Space.sm) {
                if vm.isPaused {
                    Text(vm.state == .autoPaused ? "Auto-paused" : "Paused")
                        .font(.system(size: Theme.FontSize.caption, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                }
                HeroMetric(value: vm.heroValue, label: vm.heroLabel)
                HStack(spacing: Theme.Space.xl) {
                    TimelineView(.periodic(from: vm.startedAt, by: 1)) { _ in
                        metric(Formatters.duration(s: vm.movingTimeS), "Time")
                    }
                    if vm.type != .walk { metric(vm.secondaryDistance, "Distance") }
                }
            }
            .padding(.vertical, Theme.Space.md)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.sheet))

            // Pause / stop
            HStack(spacing: Theme.Space.md) {
                OversizedButton(title: vm.isPaused ? "Resume" : "Pause",
                                systemImage: vm.isPaused ? "play.fill" : "pause.fill",
                                kind: .outline) {
                    Task { vm.isPaused ? await vm.resume() : await vm.pause() }
                }
                OversizedButton(title: "Stop", systemImage: "stop.fill") {
                    confirmStop = true
                }
            }
        }
        .padding(Theme.Space.md)
        .confirmationDialog("End this \(type.title.lowercased())?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Finish", role: .destructive) {
                Task { onFinish(await vm.finish()) }
            }
            Button("Keep going", role: .cancel) {}
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: Theme.FontSize.headline, weight: .semibold)).monospacedDigit()
            Text(label.uppercased()).font(.system(size: Theme.FontSize.label)).tracking(1).foregroundStyle(Theme.inkTertiary)
        }
        .foregroundStyle(Theme.ink)
    }

    private var acquiringOverlay: some View {
        VStack(spacing: Theme.Space.md) {
            ProgressView()
            Text("Acquiring GPS…").font(.system(size: Theme.FontSize.body)).foregroundStyle(Theme.inkSecondary)
        }
        .padding(Theme.Space.xl)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

/// The breathing route dot with a subtle iridescent edge (PRD §6.2).
private struct BreathingDot: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(IridescentMaterial()).frame(width: 26, height: 26).opacity(0.5)
            Circle().fill(Theme.route).frame(width: 14, height: 14)
        }
        .scaleEffect(pulse && !reduceMotion ? 1.15 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
        .accessibilityHidden(true)
    }
}

