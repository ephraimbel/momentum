import SwiftUI
import SwiftData
import MapKit

/// Today — the map-first home (PRD §4.2/§7.2). A full-screen map for instant access to starting a
/// run/ride/walk/hike, an activity selector, today's plan banner, and a goal customizer. Start →
/// the immersive recording cover (cardio) or the strength logger.
struct TodayView: View {
    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services
    @Query private var profiles: [UserProfile]
    @Query private var workouts: [Workout]

    @State private var activity: WorkoutType = .run
    @State private var goalKind: GoalKind = .open
    @State private var goalValue = 3.0
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var launch: TodayLaunch?
    @State private var summary: PresentedWorkout?
    @State private var locator = LocationService()
    @State private var confirmingPlan: PlannedSession?      // plan session awaiting confirmation
    @State private var pendingPlanStart: PlannedSession?    // start after the confirm sheet dismisses
    @State private var showCoach = false

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
            // Discipline-adaptive backdrop: a live map for cardio, a strength home for lifting —
            // so Strength isn't a second-class citizen staring at a meaningless map.
            if isCardio { mapLayer } else { strengthHome }
            topBar
            bottomPanel
        }
        .navigationBarHidden(true)
        .onAppear {
            PlanCoaching.reconcileMissed(plan, today: Date(), in: context)
            frameMapIfNeeded()
        }
        .fullScreenCover(item: $launch) { liveScreen($0) }
        .fullScreenCover(item: $summary) { presented in
            // Strava-style: name + describe the workout, Save → celebration → back to Today.
            if presented.type == .strength {
                StrengthSaveView(workoutId: presented.id) { summary = nil }
            } else {
                CardioSaveView(workoutId: presented.id) { summary = nil }
            }
        }
        .sheet(item: $confirmingPlan, onDismiss: {
            if let session = pendingPlanStart { pendingPlanStart = nil; startPlanned(session) }
        }) { session in
            planConfirmSheet(session)
        }
        .fullScreenCover(isPresented: $showCoach) {
            CoachChatView { showCoach = false }
        }
    }

    // MARK: Plan confirmation

    /// A calm confirmation before a planned session begins — review the prescription, then Start.
    private func planConfirmSheet(_ session: PlannedSession) -> some View {
        VStack(spacing: Theme.Space.lg) {
            Spacer(minLength: 0)
            ZStack {
                Circle().fill(IridescentMaterial()).opacity(0.3).frame(width: 72, height: 72)
                Image(systemName: disciplineIcon(session.discipline))
                    .font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.ink)
            }
            VStack(spacing: Theme.Space.xs) {
                Text("TODAY'S PLAN")
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
            Spacer(minLength: 0)
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
        .presentationDetents([.height(380)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
    }

    private func planTitle(_ s: PlannedSession) -> String {
        switch s.discipline {
        case .strength: s.strengthTargets.count >= 5 ? "Full Body" : "Strength"
        case .running: "\(s.runType?.rawValue.capitalized ?? "Easy") Run"
        case .cycling: "Ride"
        case .walking: "Walk"
        }
    }

    private func planStartCTA(_ s: PlannedSession) -> String {
        switch s.discipline {
        case .strength: "Start lifting"
        case .running: "Start run"
        case .cycling: "Start ride"
        case .walking: "Start walk"
        }
    }

    // MARK: Map

    private var mapLayer: some View {
        Map(position: $camera) { UserAnnotation() }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
            .ignoresSafeArea()
    }

    /// The strength "home" backdrop — shown instead of the map when Strength is the chosen activity,
    /// so lifting has its own identity (the brand orb + a quiet last-session readout), not a dead map.
    private var strengthHome: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: Theme.Space.lg) {
                Spacer()
                IridescentOrb(size: 132)
                lastStrengthReadout
                Spacer(); Spacer()   // bias the orb to the upper-middle, clear of the bottom panel
            }
            .padding(.horizontal, Theme.Space.xl)
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
        workouts.filter { $0.type == .strength }.max(by: { $0.startedAt < $1.startedAt })
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
            HStack(spacing: Theme.Space.sm) {
                activitySelector
                Spacer()
                // The one cross-discipline load read — same `ProgressInsights` the Progress tab speaks,
                // so runs and lifts roll into a single status the home surfaces too.
                if insights.acwr > 0 { TrainingLoadChip(status: insights.status) }
                coachButton
                StreakChip(days: ProfileStats(workouts: workouts).currentStreak)
            }
            .padding(Theme.Space.md)
            Spacer()
        }
    }

    private var insights: ProgressInsights { ProgressInsights(workouts: workouts) }

    /// Opens the AI coach chat.
    private var coachButton: some View {
        Button { Haptics.light(); showCoach = true } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                .padding(10)
                .background {
                    Circle().fill(.regularMaterial)
                    Circle().fill(IridescentMaterial()).opacity(0.22)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Coach")
    }

    private var activitySelector: some View {
        Menu {
            ForEach([WorkoutType.run, .walk, .ride, .hike, .strength]) { a in
                Button { Haptics.selection(); activity = a } label: { Label(a.title, systemImage: a.systemImage) }
            }
        } label: {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: activity.systemImage).font(.system(size: 15, weight: .bold))
                Text(activity.title).font(.rounded(Theme.FontSize.body, weight: .bold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
            }
            .fixedSize()
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Theme.Space.md).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
        }
    }

    // MARK: Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: Theme.Space.md) {
            learningTeaser
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

    private var startTitle: String { isCardio ? "Start \(activity.title.lowercased())" : "Start workout" }

    /// A slim, proactive line of what Momentum has learned (ATHLETE-MODEL.md §8 — Today teaser).
    /// Reads the already-persisted `AthleteModel` — no recompute on the map-heavy Today screen.
    @ViewBuilder
    private var learningTeaser: some View {
        if let line = topLearnedLine {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.ink)
                Text(line).font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
            }
            .padding(.horizontal, Theme.Space.md).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.sheet).fill(.regularMaterial)
                RoundedRectangle(cornerRadius: Theme.Radius.sheet).fill(IridescentMaterial()).opacity(0.18)
                RoundedRectangle(cornerRadius: Theme.Radius.sheet).stroke(Theme.hairline)
            }
        }
    }

    private var topLearnedLine: String? {
        guard let m = profiles.first?.athlete else {
            return profiles.first.map { AthleteModelService.identitySeed($0) }
        }
        let paceCount = m.signalSampleCounts[AthleteModelEngine.Signal.paceAtEffort.rawValue] ?? 0
        if m.paceAtEffortTrendPct <= -2, AthleteModelEngine.confidence(.paceAtEffort, count: paceCount) != .emerging {
            return "You're getting fitter — easy pace down \(Int(abs(m.paceAtEffortTrendPct).rounded()))%"
        }
        if let top = m.e1rmTrendByExercise.filter({ $0.value >= 2 }).max(by: { $0.value < $1.value }) {
            return "\(top.key) e1RM up \(Int(top.value.rounded()))% lately"
        }
        if let id = m.notes.first(where: { $0.isActive && $0.category == MemoryCategory.identity.rawValue })?.text {
            return id
        }
        return profiles.first.map { AthleteModelService.identitySeed($0) }
    }

    private func plannedBanner(_ session: PlannedSession) -> some View {
        Button { Haptics.light(); confirmingPlan = session } label: {
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

    /// Without a live fix (no permission yet, or still acquiring), `.userLocation` frames the whole
    /// continent. If the user has a prior route, fall back to its neighborhood instead — and still
    /// snap to their live location once a fix arrives.
    private func frameMapIfNeeded() {
        guard let c = lastKnownCoordinate else { return }
        camera = .userLocation(fallback: .region(MKCoordinateRegion(
            center: c, span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03))))
    }

    private var lastKnownCoordinate: CLLocationCoordinate2D? {
        workouts
            .sorted { $0.startedAt > $1.startedAt }
            .lazy
            .compactMap { $0.gps?.samples.first(where: { $0.accepted }) }
            .first
            .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

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
        // Let the Athlete Model learn from this session (local, never blocks the summary).
        if let profile = profiles.first {
            services.athleteModel.ingest(profile: profile, in: context)
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

/// A glanceable cross-discipline training-status pill — the home's read of the same ACWR-based
/// `ProgressInsights` the Progress tab uses, so runs + lifts roll into one status. Informational
/// (not an achievement) → monochrome, no iridescence.
struct TrainingLoadChip: View {
    let status: ProgressInsights.Status
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 13, weight: .bold))
            Text(status.rawValue).font(.rounded(Theme.FontSize.caption, weight: .bold)).lineLimit(1)
        }
        .fixedSize()
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
        .background(Capsule().fill(.regularMaterial))
        .accessibilityLabel("Training status")
        .accessibilityValue(status.rawValue)
    }
}

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
