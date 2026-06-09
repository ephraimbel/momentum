import SwiftUI
import MapKit
import SwiftData
import CoreLocation

/// The cardio record flow (PRD §4.2/§4.3) — Strava-style. The map opens first showing your
/// location; you toggle Run/Walk/Ride and (optionally) set a distance goal; Start runs a 3-2-1
/// countdown, then records — drawing a solid black route trace and counting miles.
struct CardioRecordView: View {
    let initialType: WorkoutType
    let container: ModelContainer
    var distanceUnit: DistanceUnit = .auto
    var onFinish: (UUID?) -> Void

    @Environment(\.dismiss) private var dismiss

    enum Phase { case setup, countdown, tracking }
    enum GoalKind { case open, distance }

    @State private var type: WorkoutType
    @State private var phase: Phase = .setup
    @State private var goalKind: GoalKind = .open
    @State private var goalValue = 3.0          // in display unit
    @State private var countdown = 3
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var confirmStop = false
    @State private var vm: CardioViewModel?
    @State private var locator = LocationService()
    @State private var goalReached = false

    init(initialType: WorkoutType, container: ModelContainer,
         distanceUnit: DistanceUnit = .auto, onFinish: @escaping (UUID?) -> Void) {
        self.initialType = initialType
        self.container = container
        self.distanceUnit = distanceUnit
        self.onFinish = onFinish
        _type = State(initialValue: initialType)
    }

    private var unitLabel: String { distanceUnit.resolved() == .imperial ? "mi" : "km" }
    private var goalMeters: Double? {
        goalKind == .distance ? goalValue * (distanceUnit.resolved() == .imperial ? Formatters.metersPerMile : 1000) : nil
    }
    private var routeCoords: [CLLocationCoordinate2D] { phase == .tracking ? (vm?.coordinates ?? []) : [] }

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer
            topBar
            switch phase {
            case .setup: setupPanel
            case .countdown: countdownOverlay
            case .tracking: if let vm { trackingPanel(vm) }
            }
        }
        .task { locator.requestAuthorization() }
    }

    // MARK: Map

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
                Button { phase == .tracking ? (confirmStop = true) : dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(width: 38, height: 38).background(.regularMaterial, in: Circle())
                }
                Spacer()
                if phase == .tracking, let vm { gpsGlyph(vm.gpsStrength) }
            }
            .padding(Theme.Space.md)
            Spacer()
        }
    }

    private func gpsGlyph(_ strength: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "location.fill")
            Text(strength > 0.66 ? "Strong" : strength > 0.33 ? "OK" : "Weak")
        }
        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }

    // MARK: Setup panel (the customize popup)

    private var setupPanel: some View {
        VStack(spacing: Theme.Space.lg) {
            activityToggle
            goalSection
            OversizedButton(title: "Start", systemImage: "play.fill") { beginCountdown() }
        }
        .padding(Theme.Space.lg)
        .background(panelBackground)
        .padding(Theme.Space.md)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var activityToggle: some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach([WorkoutType.run, .walk, .ride], id: \.self) { t in
                Button { Haptics.selection(); type = t } label: {
                    VStack(spacing: 4) {
                        Image(systemName: t.systemImage).font(.system(size: 18, weight: .bold))
                        Text(t.title).font(.rounded(Theme.FontSize.caption, weight: .bold))
                    }
                    .frame(maxWidth: .infinity).frame(height: 60)
                    .foregroundStyle(type == t ? Theme.background : Theme.ink)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(type == t ? Theme.ink : Theme.background)
                        RoundedRectangle(cornerRadius: Theme.Radius.chip).stroke(Theme.hairline)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var goalSection: some View {
        VStack(spacing: Theme.Space.md) {
            HStack {
                Text("Goal").font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                Spacer()
                Picker("", selection: $goalKind) {
                    Text("Open").tag(GoalKind.open)
                    Text("Distance").tag(GoalKind.distance)
                }
                .pickerStyle(.segmented).frame(width: 180)
            }
            if goalKind == .distance {
                HStack(spacing: Theme.Space.lg) {
                    stepperButton("minus") { goalValue = max(0.5, goalValue - 0.5) }
                    VStack(spacing: 0) {
                        Text(goalValue.formatted(.number.precision(.fractionLength(goalValue == goalValue.rounded() ? 0 : 1))))
                            .font(.display(34, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                        Text(unitLabel.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold))
                            .tracking(1.4).foregroundStyle(Theme.inkTertiary)
                    }
                    .frame(minWidth: 90)
                    stepperButton("plus") { goalValue += 0.5 }
                }
            }
        }
    }

    private func stepperButton(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.light(); action() } label: {
            Image(systemName: system).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 52, height: 52)
                .background { Circle().fill(Theme.background); Circle().stroke(Theme.hairline) }
        }
        .buttonStyle(.plain)
    }

    // MARK: Countdown

    private var countdownOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            Text(countdown > 0 ? "\(countdown)" : "GO")
                .font(.display(96, weight: .black)).foregroundStyle(.white)
                .id(countdown)
                .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: Tracking panel

    private func trackingPanel(_ vm: CardioViewModel) -> some View {
        VStack(spacing: Theme.Space.md) {
            VStack(spacing: Theme.Space.sm) {
                if vm.isPaused {
                    Text(vm.state == .autoPaused ? "Auto-paused" : "Paused")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                }
                HeroMetric(value: distanceNumber(vm), label: unitLabel == "mi" ? "Miles" : "Kilometers")
                HStack(spacing: Theme.Space.xl) {
                    TimelineView(.periodic(from: vm.startedAt, by: 1)) { _ in
                        stat(Formatters.duration(s: vm.movingTimeS), "Time")
                    }
                    stat(vm.heroValue, vm.heroLabel)
                }
                if let goalMeters { goalBar(distance: vm.distanceM, goal: goalMeters) }
            }
            .padding(.vertical, Theme.Space.md)
            .frame(maxWidth: .infinity)
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
        let goalDisplay = goalValue.formatted(.number.precision(.fractionLength(goalValue == goalValue.rounded() ? 0 : 1)))
        return VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    Capsule().fill(Theme.ink).frame(width: max(6, geo.size.width * progress))
                }
            }
            .frame(height: 6)
            Text("\(distanceNumber(forMeters: distance)) / \(goalDisplay) \(unitLabel)")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.inkTertiary)
        }
        .padding(.horizontal, Theme.Space.lg)
        .onChange(of: progress) {
            if progress >= 1 && !goalReached { goalReached = true; Haptics.celebration() }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.display(20, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1).foregroundStyle(Theme.inkTertiary)
        }
    }

    private func distanceNumber(_ vm: CardioViewModel) -> String { distanceNumber(forMeters: vm.distanceM) }
    private func distanceNumber(forMeters m: Double) -> String {
        Formatters.distance(meters: m, unit: distanceUnit).components(separatedBy: " ").first ?? "0"
    }

    private var panelBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.sheet).fill(.regularMaterial)
            RoundedRectangle(cornerRadius: Theme.Radius.sheet).stroke(Theme.hairline)
        }
    }

    // MARK: Flow

    private func beginCountdown() {
        withAnimation(Motion.standard) { phase = .countdown }
        Task {
            for n in [3, 2, 1] {
                withAnimation(Motion.lively) { countdown = n }
                Haptics.light()
                try? await Task.sleep(for: .seconds(0.8))
            }
            withAnimation(Motion.lively) { countdown = 0 } // "GO"
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
private struct BreathingDot: View {
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
