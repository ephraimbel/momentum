import SwiftUI
import SwiftData

/// Today / Home (PRD §7.2) — the captivating, light-aesthetic home. A display-type greeting, the
/// prescribed-session hero, aesthetic quick-start workout tiles, and a "done today" section that
/// shows completed workouts Strava-style (route snapshot for cardio).
struct TodayView: View {
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]
    @Query private var workouts: [Workout]

    @State private var showingChooser = false
    @State private var launch: LiveLaunch?
    @State private var summary: PresentedWorkout?

    private var profile: UserProfile? { profiles.first }
    private var plan: TrainingPlan? { profile?.plan }
    private var today: [PlannedSession] { PlanCoaching.todaySessions(plan, on: Date()) }
    private var pendingToday: PlannedSession? { today.first { $0.status != .completed } }
    private var completedToday: [Workout] {
        workouts.filter { Calendar.current.isDateInToday($0.startedAt) }.sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header
                if let session = pendingToday {
                    planHero(session)
                } else if plan != nil && completedToday.isEmpty {
                    restCard
                }
                quickStart
                if !completedToday.isEmpty { doneToday }
            }
            .padding(Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationBarHidden(true)
        .onAppear { PlanCoaching.reconcileMissed(plan, today: Date(), in: context) }
        .sheet(isPresented: $showingChooser) {
            ActivityChooserView { type in showingChooser = false; launch = .free(type) }
                .presentationDetents([.medium])
        }
        .fullScreenCover(item: $launch) { launch in liveScreen(launch) }
        .fullScreenCover(item: $summary) { presented in
            if presented.type == .strength {
                StrengthSummaryView(workoutId: presented.id) { summary = nil }
            } else {
                CardioSummaryView(workoutId: presented.id) { summary = nil }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        let stats = ProfileStats(workouts: workouts)
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(.display(32, weight: .black))
                    .foregroundStyle(Theme.ink)
                Text(Date().formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
            }
            Spacer()
            StreakChip(days: stats.currentStreak)
        }
        .padding(.top, Theme.Space.sm)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Hello"
        }
    }

    // MARK: Plan hero / rest

    private func planHero(_ session: PlannedSession) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            HStack(spacing: Theme.Space.sm) {
                glyphBadge(disciplineIcon(session.discipline))
                Text("TODAY'S SESSION").font(.rounded(Theme.FontSize.label, weight: .bold))
                    .tracking(1.6).foregroundStyle(Theme.inkTertiary)
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(PlanCoaching.brief(for: session))
                    .font(.display(26, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                if let why = session.rationale {
                    Text(why).font(.rounded(Theme.FontSize.body, weight: .regular)).foregroundStyle(Theme.inkSecondary)
                }
            }
            OversizedButton(title: "Start", systemImage: "play.fill") { launch = .planned(session) }
        }
        .padding(Theme.Space.lg)
        .background(heroBackground)
    }

    private var restCard: some View {
        VStack(spacing: Theme.Space.sm) {
            IridescentOrb(size: 64)
            Text("Rest day").font(.display(24, weight: .heavy)).foregroundStyle(Theme.ink)
            Text("Recovery is training too. Or log something light below.")
                .font(.rounded(Theme.FontSize.body, weight: .regular)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.xl)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
    }

    // MARK: Quick start tiles

    private var quickStart: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            sectionTitle("Start a workout")
            let cols = [GridItem(.flexible(), spacing: Theme.Space.md), GridItem(.flexible(), spacing: Theme.Space.md)]
            LazyVGrid(columns: cols, spacing: Theme.Space.md) {
                ForEach([WorkoutType.run, .ride, .walk, .strength]) { type in
                    QuickStartTile(type: type) { launch = .free(type) }
                }
            }
        }
    }

    // MARK: Done today

    private var doneToday: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            sectionTitle("Done today")
            ForEach(completedToday, id: \.persistentModelID) { workout in
                Button { summary = PresentedWorkout(id: workout.id, type: workout.type) } label: {
                    CompletedWorkoutCard(workout: workout)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Shared bits

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.rounded(Theme.FontSize.label, weight: .bold))
            .tracking(1.4).foregroundStyle(Theme.inkTertiary)
    }

    private func glyphBadge(_ system: String) -> some View {
        Image(systemName: system)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(Theme.ink)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Theme.background))
    }

    private var heroBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.sheet).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.sheet).stroke(Theme.hairline)
        }
    }

    @ViewBuilder
    private func liveScreen(_ launch: LiveLaunch) -> some View {
        let planned = launch.plannedSession
        let finish: (UUID?) -> Void = { id in
            self.launch = nil
            guard let id else { return }
            if let workout = fetchWorkout(id) {
                if let planned { PlanCoaching.markComplete(planned, with: workout, in: context) }
                else { PlanCoaching.creditWorkout(workout, to: plan, in: context) }
            }
            summary = PresentedWorkout(id: id, type: launch.type)
        }
        if launch.type == .strength {
            StrengthLiveView(container: context.container, plannedSession: planned, onFinish: finish)
        } else {
            CardioRecordView(initialType: launch.type, container: context.container, onFinish: finish)
        }
    }

    private func fetchWorkout(_ id: UUID) -> Workout? {
        ((try? context.fetch(FetchDescriptor<Workout>())) ?? []).first { $0.id == id }
    }

    private func disciplineIcon(_ d: Discipline) -> String {
        switch d { case .running: "figure.run"; case .cycling: "bicycle"; case .walking: "figure.walk"; case .strength: "dumbbell.fill" }
    }
}

// MARK: - Components

/// A streak chip — flame + count; lights up iridescent when the streak is alive.
private struct StreakChip: View {
    let days: Int
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill")
            Text("\(days)").font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit()
        }
        .foregroundStyle(days > 0 ? Theme.ink : Theme.inkTertiary)
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background {
            Capsule().fill(Theme.surface)
            if days > 0 {
                Capsule().fill(IridescentMaterial()).opacity(0.22)
            }
            Capsule().stroke(Theme.hairline)
        }
        .accessibilityLabel("Streak")
        .accessibilityValue("\(days) days")
    }
}

/// A captivating quick-start workout tile.
private struct QuickStartTile: View {
    let type: WorkoutType
    let action: () -> Void
    @State private var pressed = false

    var body: some View {
        Button { Haptics.selection(); action() } label: {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                ZStack {
                    Circle().fill(IridescentMaterial()).opacity(0.30)
                    Image(systemName: type.systemImage)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.ink)
                }
                .frame(width: 48, height: 48)
                Spacer(minLength: 0)
                Text(type.title)
                    .font(.rounded(Theme.FontSize.headline, weight: .bold))
                    .foregroundStyle(Theme.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 116)
            .padding(Theme.Space.md)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(pressed ? 0.97 : 1)
        .animation(Motion.lively, value: pressed)
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in pressed = true }.onEnded { _ in pressed = false })
    }
}

/// A soft iridescent fill for accents (chips, tile glyph backings) — static, low-opacity.
struct IridescentMaterial: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        LinearGradient(colors: Theme.iridescent, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Identifiable launch + presented wrappers

enum LiveLaunch: Identifiable {
    case free(WorkoutType)
    case planned(PlannedSession)
    var id: String {
        switch self {
        case .free(let t): "free-\(t.rawValue)"
        case .planned(let s): "planned-\(s.id.uuidString)"
        }
    }
    var type: WorkoutType {
        switch self {
        case .free(let t): t
        case .planned(let s):
            switch s.discipline { case .strength: .strength; case .cycling: .ride; case .walking: .walk; case .running: .run }
        }
    }
    var plannedSession: PlannedSession? {
        if case .planned(let s) = self { return s }
        return nil
    }
}

struct PresentedWorkout: Identifiable {
    let id: UUID
    let type: WorkoutType
}
