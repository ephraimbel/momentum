import SwiftUI
import SwiftData
import MapKit

/// Today — the map-first home (PRD §4.2/§7.2). A full-screen map for instant access to starting a
/// run/ride/walk/hike, an activity selector, today's plan banner, and a goal customizer. Start →
/// the immersive recording cover (cardio) or the strength logger.
struct TodayView: View {
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]
    @Query private var workouts: [Workout]

    @State private var activity: WorkoutType = .run
    @State private var goalKind: GoalKind = .open
    @State private var goalValue = 3.0
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var launch: TodayLaunch?
    @State private var summary: PresentedWorkout?
    @State private var locator = LocationService()

    enum GoalKind { case open, distance }

    private let distanceUnit: DistanceUnit = .auto
    private var plan: TrainingPlan? { profiles.first?.plan }
    private var pendingToday: PlannedSession? {
        PlanCoaching.todaySessions(plan, on: Date()).first { $0.status != .completed }
    }
    private var isCardio: Bool { activity != .strength }
    private var unitLabel: String { distanceUnit.resolved() == .imperial ? "mi" : "km" }
    private var goalMeters: Double? {
        goalKind == .distance ? goalValue * (distanceUnit.resolved() == .imperial ? Formatters.metersPerMile : 1000) : nil
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer
            topBar
            bottomPanel
        }
        .navigationBarHidden(true)
        .onAppear { PlanCoaching.reconcileMissed(plan, today: Date(), in: context) }
        .fullScreenCover(item: $launch) { liveScreen($0) }
        .fullScreenCover(item: $summary) { presented in
            if presented.type == .strength {
                StrengthSummaryView(workoutId: presented.id) { summary = nil }
            } else {
                CardioSummaryView(workoutId: presented.id) { summary = nil }
            }
        }
    }

    // MARK: Map

    private var mapLayer: some View {
        Map(position: $camera) { UserAnnotation() }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
            .ignoresSafeArea()
    }

    private var topBar: some View {
        VStack {
            HStack {
                activitySelector
                Spacer()
                StreakChip(days: ProfileStats(workouts: workouts).currentStreak)
            }
            .padding(Theme.Space.md)
            Spacer()
        }
    }

    private var activitySelector: some View {
        Menu {
            ForEach([WorkoutType.run, .walk, .ride, .hike, .strength]) { a in
                Button { Haptics.selection(); activity = a } label: { Label(a.title, systemImage: a.systemImage) }
            }
        } label: {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: activity.systemImage).font(.system(size: 15, weight: .bold))
                Text(activity.title).font(.rounded(Theme.FontSize.body, weight: .bold))
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Theme.Space.md).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
        }
    }

    // MARK: Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: Theme.Space.md) {
            if let session = pendingToday { plannedBanner(session) }
            VStack(spacing: Theme.Space.lg) {
                if isCardio { goalSection }
                OversizedButton(title: startTitle, systemImage: "play.fill") { startFree() }
            }
            .padding(Theme.Space.lg)
            .background(panelBackground)
        }
        .padding(Theme.Space.md)
    }

    private var startTitle: String { isCardio ? "Start \(activity.title.lowercased())" : "Start strength" }

    private func plannedBanner(_ session: PlannedSession) -> some View {
        Button { startPlanned(session) } label: {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: disciplineIcon(session.discipline))
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                    .frame(width: 36, height: 36).background(Circle().fill(IridescentMaterial()).opacity(0.3))
                VStack(alignment: .leading, spacing: 1) {
                    Text("TODAY'S PLAN").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
                    Text(PlanCoaching.brief(for: session)).font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill").font(.system(size: 26)).foregroundStyle(Theme.ink)
            }
            .padding(Theme.Space.md)
            .background(panelBackground)
        }
        .buttonStyle(.plain)
    }

    private var goalSection: some View {
        VStack(spacing: Theme.Space.md) {
            HStack {
                Text("Goal").font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                Spacer()
                Picker("", selection: $goalKind) {
                    Text("Open").tag(GoalKind.open); Text("Distance").tag(GoalKind.distance)
                }.pickerStyle(.segmented).frame(width: 170)
            }
            if goalKind == .distance {
                HStack(spacing: Theme.Space.lg) {
                    stepperButton("minus") { goalValue = max(0.5, goalValue - 0.5) }
                    VStack(spacing: 0) {
                        Text(goalValue.formatted(.number.precision(.fractionLength(goalValue == goalValue.rounded() ? 0 : 1))))
                            .font(.display(32, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                        Text(unitLabel.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
                    }.frame(minWidth: 84)
                    stepperButton("plus") { goalValue += 0.5 }
                }
            }
        }
    }

    private func stepperButton(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.light(); action() } label: {
            Image(systemName: system).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 50, height: 50).background { Circle().fill(Theme.background); Circle().stroke(Theme.hairline) }
        }.buttonStyle(.plain)
    }

    private var panelBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.sheet).fill(.regularMaterial)
            RoundedRectangle(cornerRadius: Theme.Radius.sheet).stroke(Theme.hairline)
        }
    }

    // MARK: Launch

    private func startFree() {
        if activity == .strength { launch = .strength(planned: nil) }
        else {
            locator.requestAuthorization()   // ask for GPS exactly when they Start — never up front
            launch = .cardio(type: activity, goalMeters: goalMeters, planned: nil)
        }
    }

    private func startPlanned(_ session: PlannedSession) {
        let t = workoutType(for: session.discipline)
        if t == .strength { launch = .strength(planned: session) }
        else {
            locator.requestAuthorization()
            launch = .cardio(type: t, goalMeters: session.targetDistanceM, planned: session)
        }
    }

    @ViewBuilder
    private func liveScreen(_ launch: TodayLaunch) -> some View {
        switch launch {
        case let .cardio(type, goal, planned):
            CardioTrackingView(type: type, goalMeters: goal, container: context.container) { id in
                finish(id, type: type, planned: planned)
            }
        case let .strength(planned):
            StrengthLiveView(container: context.container, plannedSession: planned) { id in
                finish(id, type: .strength, planned: planned)
            }
        }
    }

    private func finish(_ id: UUID?, type: WorkoutType, planned: PlannedSession?) {
        launch = nil
        guard let id else { return }
        if let workout = fetchWorkout(id) {
            if let planned { PlanCoaching.markComplete(planned, with: workout, in: context) }
            else { PlanCoaching.creditWorkout(workout, to: plan, in: context) }
        }
        summary = PresentedWorkout(id: id, type: type)
    }

    private func fetchWorkout(_ id: UUID) -> Workout? {
        ((try? context.fetch(FetchDescriptor<Workout>())) ?? []).first { $0.id == id }
    }

    private func workoutType(for d: Discipline) -> WorkoutType {
        switch d { case .strength: .strength; case .cycling: .ride; case .walking: .walk; case .running: .run }
    }

    private func disciplineIcon(_ d: Discipline) -> String {
        switch d { case .running: "figure.run"; case .cycling: "bicycle"; case .walking: "figure.walk"; case .strength: "dumbbell.fill" }
    }
}

// MARK: - Launch + presentation wrappers

enum TodayLaunch: Identifiable {
    case cardio(type: WorkoutType, goalMeters: Double?, planned: PlannedSession?)
    case strength(planned: PlannedSession?)
    var id: String {
        switch self {
        case let .cardio(t, _, p): "c-\(t.rawValue)-\(p?.id.uuidString ?? "free")"
        case let .strength(p): "s-\(p?.id.uuidString ?? "free")"
        }
    }
}

struct PresentedWorkout: Identifiable { let id: UUID; let type: WorkoutType }

/// A streak chip — flame + count; lights up iridescent when the streak is alive.
struct StreakChip: View {
    let days: Int
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill")
            Text("\(days)").font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit()
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
        .background {
            Capsule().fill(.regularMaterial)
            if days > 0 { Capsule().fill(IridescentMaterial()).opacity(0.22) }
        }
        .accessibilityLabel("Streak")
        .accessibilityValue("\(days) days")
    }
}

/// A soft iridescent fill for accents — static, low-opacity.
struct IridescentMaterial: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        LinearGradient(colors: Theme.iridescent, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
