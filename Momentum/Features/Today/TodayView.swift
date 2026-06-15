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

    // Defaults to Run (map-first home). `--ui-test-strength` opens straight into strength so the
    // strength-logging UI test can drive the set logger deterministically (no picker navigation).
    @State private var activity: WorkoutType =
        ProcessInfo.processInfo.arguments.contains("--ui-test-strength") ? .strength : .run
    @State private var goalKind: GoalKind = .open
    @State private var goalValue = 3.0
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var launch: TodayLaunch?
    @State private var summary: PresentedWorkout?
    @State private var locator = LocationService()
    @State private var confirmingPlan: PlannedSession?      // plan session awaiting confirmation
    @State private var pendingPlanStart: PlannedSession?    // start after the confirm sheet dismisses
    @State private var mapStyle: MapStyleOption = .standard
    @State private var showSuggest = false
    @State private var showSportPicker = false

    enum GoalKind { case open, distance }

    private let distanceUnit: DistanceUnit = .auto
    private var plan: TrainingPlan? { profiles.first?.plan }
    private var pendingToday: PlannedSession? {
        PlanCoaching.todaySessions(plan, on: Date()).first { $0.status != .completed }
    }
    private var isCardio: Bool { activity.isGPS }
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
            // Keep next-workout reminders in sync with the (possibly moved) plan; asks for
            // notification permission on first run.
            services.notifications.schedulePlannedReminders(plan)
            // The rest of the notification taxonomy (PRD §24): the weekly recap nudge, and a gentle
            // streak-protection nudge when a real streak is at risk on a planned, not-yet-trained day.
            services.notifications.scheduleWeeklyCheckIn()
            let stats = ProfileStats(workouts: workouts)
            let plannedToday = !PlanCoaching.todaySessions(plan, on: Date()).isEmpty
            let workedOutToday = workouts.contains { Calendar.current.isDateInToday($0.startedAt) }
            services.notifications.scheduleStreakNudge(streak: stats.currentStreak,
                                                       isPlannedDayToday: plannedToday,
                                                       hasWorkedOutToday: workedOutToday)
            // Lock the map onto the athlete. `.userLocation` centers on them once a fix lands; until
            // then fall back to their last route's neighborhood (never the whole-world `.automatic`).
            let fallback: MapCameraPosition = lastKnownCoordinate
                .map { .region(region(around: $0)) } ?? .automatic
            camera = .userLocation(fallback: fallback)
            // Show the athlete on their map. Only prompts if still undetermined (onboarding's primer
            // usually settled this); requesting also pulls a one-shot fix to center the map on them.
            locator.requestAuthorization()
        }
        // Center on the athlete the moment a fix lands (the blue dot is theirs).
        .onChange(of: locator.lastLocation?.latitude) {
            if let loc = locator.lastLocation {
                withAnimation(Motion.standard) { camera = .region(region(around: loc)) }
            }
        }
        .fullScreenCover(item: $launch) { liveScreen($0) }
        .fullScreenCover(item: $summary) { presented in
            // Strava-style: name + describe the workout, Save → celebration → back to Today.
            if presented.type.isStrengthStyle {
                StrengthSaveView(workoutId: presented.id) { summary = nil }
            } else if presented.type.isTimed {
                TimedSaveView(workoutId: presented.id) { summary = nil }
            } else {
                CardioSaveView(workoutId: presented.id) { summary = nil }
            }
        }
        .sheet(item: $confirmingPlan, onDismiss: {
            if let session = pendingPlanStart { pendingPlanStart = nil; startPlanned(session) }
        }) { session in
            planConfirmSheet(session)
        }
        .sheet(isPresented: $showSportPicker) {
            SportPicker(selection: $activity) { showSportPicker = false }
        }
        // Suggest a distance-targeted loop from the athlete's current spot.
        .sheet(isPresented: $showSuggest) {
            if let loc = locator.lastLocation {
                RouteSuggestionView(
                    start: GeoPoint(lat: loc.latitude, lon: loc.longitude),
                    targetM: goalMeters ?? 5000,
                    distanceUnit: distanceUnit,
                    onUse: { loop in
                        showSuggest = false
                        locator.requestAuthorization()
                        launch = .cardio(type: activity, goalMeters: loop.distanceM, planned: nil, guideRoute: loop.polyline)
                    },
                    onClose: { showSuggest = false })
            }
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

    /// Best guess at where the athlete is before a live fix lands — a cached fix, else their most
    /// recent route's neighborhood — so the cardio map never opens on the whole world.
    private var lastKnownCoordinate: CLLocationCoordinate2D? {
        if let live = locator.lastLocation { return live }
        return workouts
            .sorted { $0.startedAt > $1.startedAt }
            .lazy
            .compactMap { $0.gps?.samples.first(where: { $0.accepted }) }
            .first
            .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    private var mapLayer: some View {
        Map(position: $camera) { UserAnnotation() }
            .mapStyle(mapStyle.mapStyle)
            .ignoresSafeArea()
    }

    /// The strength "home" backdrop — shown instead of the map when Strength is the chosen activity,
    /// so lifting has its own identity (the brand orb + a quiet last-session readout), not a dead map.
    private var strengthHome: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: Theme.Space.lg) {
                Spacer()
                if activity.isStrengthStyle {
                    // The lifting identity: a body map glowing with the muscles from your last session
                    // (a quiet empty silhouette before your first lift), then the readout below.
                    MuscleMapView(activation: lastStrengthActivation)
                        .frame(height: 300)
                        .frame(maxWidth: .infinity)
                    lastStrengthReadout
                } else {
                    IridescentOrb(size: 132)   // timed sports (yoga, etc.) keep the brand orb
                }
                Spacer(); Spacer()   // bias the figure to the upper-middle, clear of the bottom panel
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
        workouts.filter { $0.type.isStrengthStyle }.max(by: { $0.startedAt < $1.startedAt })
    }

    /// Muscles worked in the most recent strength session — drives the strength-home body map.
    /// Empty (a faint silhouette) before the athlete's first lift.
    private var lastStrengthActivation: [MuscleGroup: Double] {
        guard let session = lastStrength?.strength else { return [:] }
        return MuscleActivation.from(session: session)
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
                StreakChip(days: ProfileStats(workouts: workouts).currentStreak)
            }
            .padding(Theme.Space.md)
            Spacer()
        }
    }


    private var activitySelector: some View {
        Button { Haptics.light(); showSportPicker = true } label: {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: activity.systemImage).font(.system(size: 15, weight: .bold))
                Text(activity.title).font(.rounded(Theme.FontSize.body, weight: .bold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
            }
            .fixedSize()
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.pillV)
            .momentumGlass()
        }
        .buttonStyle(.plain)
    }

    // MARK: Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: Theme.Space.sm) {
            if isCardio {
                HStack(spacing: Theme.Space.sm) { Spacer(); MapLayersButton(style: $mapStyle); recenterButton }
            }
            if let session = pendingToday { plannedBanner(session) }
            startCard
        }
        .padding(Theme.Space.md)
    }

    /// One clean card: an optional goal, then the single primary action. Distance is opt-in, so the
    /// default state is just "Start" — calm and obvious.
    private var startCard: some View {
        VStack(spacing: Theme.Space.md) {
            if isCardio { goalControl }
            OversizedButton(title: startTitle, systemImage: "play.fill") { startFree() }
            if isCardio, activity.discipline != .cycling, locator.lastLocation != nil { suggestLoopButton }
        }
        .padding(Theme.Space.lg)
        .momentumGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
    }

    /// Secondary action: get a distance-targeted loop to run from here (MapKit-native).
    private var suggestLoopButton: some View {
        Button { Haptics.light(); showSuggest = true } label: {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "arrow.triangle.capsulepath")
                Text("Suggest a loop")
            }
            .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity).frame(height: 46)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }


    private func region(around c: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.014, longitudeDelta: 0.014))
    }

    private var recenterButton: some View {
        Button {
            Haptics.light()
            locator.refreshLocation()
            withAnimation(Motion.standard) {
                if let loc = locator.lastLocation { camera = .region(region(around: loc)) }
                else { camera = .userLocation(fallback: .automatic) }
            }
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44)
                .momentumGlass(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recenter on my location")
    }

    private var startTitle: String {
        activity.isStrengthStyle ? "Start workout" : "Start \(activity.title.lowercased())"
    }

    /// A slim, proactive line of what Momentum has learned (ATHLETE-MODEL.md §8 — Today teaser).
    /// Reads the already-persisted `AthleteModel` — no recompute on the map-heavy Today screen.
    @ViewBuilder
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
            .momentumGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var goalControl: some View {
        VStack(spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.sm) {
                goalToggle(.open, "Open")
                goalToggle(.distance, "Distance")
            }
            if goalKind == .distance {
                HStack(spacing: Theme.Space.lg) {
                    stepperButton("minus") { goalValue = max(0.5, goalValue - 0.5) }
                    VStack(spacing: -2) {
                        Text(goalValue.formatted(.number.precision(.fractionLength(goalValue == goalValue.rounded() ? 0 : 1))))
                            .font(.display(34, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                            .contentTransition(.numericText())
                        Text(unitLabel.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
                    }.frame(minWidth: 90)
                    stepperButton("plus") { goalValue += 0.5 }
                }
                .animation(.snappy(duration: 0.2), value: goalValue)
            }
        }
    }

    private func goalToggle(_ kind: GoalKind, _ title: String) -> some View {
        let on = goalKind == kind
        return Button { Haptics.selection(); goalKind = kind } label: {
            Text(title)
                .font(.rounded(Theme.FontSize.body, weight: .bold))
                .frame(maxWidth: .infinity).frame(height: 46)
                .foregroundStyle(on ? Theme.background : Theme.ink)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.card).fill(on ? Theme.ink : Color.clear)
                    RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(on ? Color.clear : Theme.hairline, lineWidth: 1.5)
                }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: on)
    }

    private func stepperButton(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.light(); action() } label: {
            Image(systemName: system).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 50, height: 50).background { Circle().fill(Theme.background); Circle().stroke(Theme.hairline) }
        }.buttonStyle(.plain)
    }

    // MARK: Launch

    private func startFree() {
        if activity.isStrengthStyle { launch = .strength(type: activity, planned: nil) }
        else if activity.isTimed { launch = .timed(type: activity) }
        else {
            locator.requestAuthorization()   // ask for GPS exactly when they Start — never up front
            launch = .cardio(type: activity, goalMeters: goalMeters, planned: nil, guideRoute: [])
        }
    }

    private func startPlanned(_ session: PlannedSession) {
        let t = workoutType(for: session.discipline)
        if t.isStrengthStyle { launch = .strength(type: t, planned: session) }
        else {
            locator.requestAuthorization()
            launch = .cardio(type: t, goalMeters: session.targetDistanceM, planned: session, guideRoute: [])
        }
    }

    @ViewBuilder
    private func liveScreen(_ launch: TodayLaunch) -> some View {
        switch launch {
        case let .cardio(type, goal, planned, guide):
            CardioTrackingView(type: type, goalMeters: goal, container: context.container, guideRoute: guide) { id in
                finish(id, type: type, planned: planned)
            }
        case let .strength(type, planned):
            StrengthLiveView(container: context.container, type: type, plannedSession: planned) { id in
                finish(id, type: type, planned: planned)
            }
        case let .timed(type):
            TimedTrackingView(type: type, container: context.container) { id in
                finish(id, type: type, planned: nil)
            }
        }
    }

    private func finish(_ id: UUID?, type: WorkoutType, planned: PlannedSession?) {
        launch = nil
        guard let id else { return }
        var didNudge = false
        if let workout = fetchWorkout(id) {
            // Deterministic active-energy estimate (body-mass aware) — drives the calorie stat and the
            // Apple Health energy sample. Recomputed on save if the sport type is corrected.
            workout.calories = CalorieEstimator.kcal(for: workout, bodyMassKg: profiles.first?.bodyMassKg)
            try? context.save()   // persist now so the fresh-context strength summary reader sees it
            if let planned { PlanCoaching.markComplete(planned, with: workout, in: context) }
            else { PlanCoaching.creditWorkout(workout, to: plan, in: context) }
            // Adaptive coaching: a strong run re-calibrates future paces (deterministic + bounded),
            // and the coach tells you about it.
            if workout.type.discipline == .running,
               let rec = PlanCoaching.recalibratePaces(from: workout, plan: plan, in: context),
               rec.sessionsUpdated > 0 {
                let easy = PlanEngine.pace(.easy, p5k: rec.newP5kSPerKm)
                services.notifications.notifyPlanUpdated(
                    title: "Your paces just got faster",
                    body: "Strong run — I updated your plan. Easy runs are now ~\(Formatters.pace(secPerKm: easy, unit: distanceUnit)).")
                didNudge = true
            }
        }
        // Let the Athlete Model learn from this session (local, never blocks the summary).
        if let profile = profiles.first {
            services.athleteModel.ingest(profile: profile, in: context)
        }
        // Auto-protect from overreaching (ACWR-driven, ≤1×/week, never auto-increases load).
        let recent = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
        if let rec = PlanCoaching.autoAdapt(plan, workouts: recent, in: context), !didNudge {
            services.notifications.notifyPlanUpdated(
                title: rec == .rest ? "Recovery banked" : "Eased your upcoming sessions",
                body: rec == .rest
                    ? "Your load's been climbing — I pulled the next sessions back so it lands. No streak lost."
                    : "Your load's been climbing — I eased the next sessions ~15%. Still on track.")
        }
        // Refresh next-workout reminders so they reflect the completed/credited/recalibrated/eased plan.
        services.notifications.schedulePlannedReminders(plan)
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
        .momentumGlass()
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
        .momentumGlass(iridescent: days > 0 ? .chip : nil)
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
