import SwiftUI
import SwiftData

/// Today / Home (PRD §7.2). Answers "what do I do today?" in one glance: the prescribed session
/// (or a warm rest day), the streak and week ring quietly above, and Start anchored. Free training
/// is always one tap away via the chooser.
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

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.xl) {
                header
                mainCard
            }
            .padding(Theme.Space.md)
        }
        .background(Theme.background)
        .navigationTitle("Today")
        .safeAreaInset(edge: .bottom) { startBar }
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

    // MARK: Header — streak + week ring

    private var header: some View {
        let stats = ProfileStats(workouts: workouts)
        let week = PlanCoaching.weekSessions(plan, containing: Date())
        let done = week.filter { $0.status == .completed }.count
        let adherence = week.isEmpty ? 0 : Double(done) / Double(week.count)
        return HStack(spacing: Theme.Space.lg) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "flame.fill")
                Text("\(stats.currentStreak)").monospacedDigit().fontWeight(.semibold)
            }
            .foregroundStyle(Theme.ink)
            Spacer()
            if !week.isEmpty {
                HStack(spacing: Theme.Space.sm) {
                    Text("\(done)/\(week.count) this week")
                        .font(.system(size: Theme.FontSize.caption)).foregroundStyle(Theme.inkSecondary)
                    ProgressRing(progress: adherence, lineWidth: 5).frame(width: 28, height: 28)
                }
            }
        }
    }

    // MARK: Main card

    @ViewBuilder
    private var mainCard: some View {
        if let session = today.first {
            todayCard(session, secondary: today.count > 1 ? today[1] : nil)
        } else if plan != nil {
            restCard
        } else {
            readyCard
        }
    }

    private func todayCard(_ session: PlannedSession, secondary: PlannedSession?) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: disciplineIcon(session.discipline))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Theme.background))
                Text(session.status == .completed ? "DONE TODAY ✓" : "TODAY")
                    .font(.system(size: Theme.FontSize.label, weight: .semibold)).tracking(1.4)
                    .foregroundStyle(Theme.inkTertiary)
            }
            Text(PlanCoaching.brief(for: session))
                .font(.system(size: Theme.FontSize.title, weight: .bold))
                .foregroundStyle(Theme.ink)
            if let why = session.rationale {
                Text(why).font(.system(size: Theme.FontSize.body)).foregroundStyle(Theme.inkSecondary)
            }
            if let secondary {
                Label(PlanCoaching.brief(for: secondary), systemImage: "plus")
                    .font(.system(size: Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
                    .padding(.top, Theme.Space.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.lg)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
    }

    private var restCard: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "moon.stars").font(.system(size: 32)).foregroundStyle(Theme.inkSecondary)
            Text("Rest day").font(.system(size: Theme.FontSize.title, weight: .bold)).foregroundStyle(Theme.ink)
            Text("Recovery is training too. Come back tomorrow — or log something light if you feel good.")
                .font(.system(size: Theme.FontSize.body)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.lg)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
    }

    private var readyCard: some View {
        VStack(spacing: Theme.Space.sm) {
            Text("Ready to train?").font(.system(size: Theme.FontSize.title, weight: .bold)).foregroundStyle(Theme.ink)
            Text("Pick a session and momentum will track it.")
                .font(.system(size: Theme.FontSize.body)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.xl)
    }

    // MARK: Start

    private var startBar: some View {
        Group {
            if let session = today.first, session.status != .completed {
                OversizedButton(title: "Start today's session", systemImage: "play.fill") {
                    launch = .planned(session)
                }
            } else {
                OversizedButton(title: "Start", systemImage: "play.fill") { showingChooser = true }
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.bottom, Theme.Space.sm)
    }

    // MARK: Live + finish

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
            CardioLiveView(type: launch.type, container: context.container, onFinish: finish)
        }
    }

    private func fetchWorkout(_ id: UUID) -> Workout? {
        ((try? context.fetch(FetchDescriptor<Workout>())) ?? []).first { $0.id == id }
    }

    private func disciplineIcon(_ d: Discipline) -> String {
        switch d { case .running: "figure.run"; case .cycling: "bicycle"; case .walking: "figure.walk"; case .strength: "dumbbell.fill" }
    }
}

/// What the live cover is launching — a free session or a prescribed one.
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

/// Identifiable wrapper so a finished workout id can drive `fullScreenCover(item:)`.
struct PresentedWorkout: Identifiable {
    let id: UUID
    let type: WorkoutType
}
