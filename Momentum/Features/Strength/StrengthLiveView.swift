import SwiftUI
import SwiftData

/// The strength logging screen (PRD §4.4, §7.5) — the fastest, calmest lifting log on iOS.
/// Owns a `StrengthViewModel`; presents the library to add exercises and a summary on finish.
struct StrengthLiveView: View {
    let container: ModelContainer
    var type: WorkoutType = .strength
    var plannedSession: PlannedSession? = nil
    var onFinish: (UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(Services.self) private var services
    @State private var vm: StrengthViewModel?
    @State private var showingLibrary = false
    @State private var showingPlates = false
    @State private var confirmExit = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let vm {
                content(vm)
                if vm.restEndsAt != nil {
                    RestBar(vm: vm)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            } else {
                ProgressView()
            }
        }
        .animation(Motion.standard, value: vm?.restEndsAt)
        .task {
            guard vm == nil else { return }
            let model = StrengthViewModel(container: container, type: type)
            await model.start()
            services.analytics.log(.workoutStarted(type: type.rawValue))
            if let plannedSession { await model.loadPlanned(plannedSession) }
            vm = model
            // Free start with nothing loaded → open the library straight away so the user picks
            // from our exercise catalog instead of staring at an empty log.
            if plannedSession == nil && model.exercises.isEmpty {
                try? await Task.sleep(for: .milliseconds(350))   // let the cover settle first
                showingLibrary = true
            }
        }
    }

    @ViewBuilder
    private func content(_ vm: StrengthViewModel) -> some View {
        VStack(spacing: 0) {
            header(vm)
            if vm.exercises.isEmpty {
                emptyState(vm)
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.Space.lg) {
                        MuscleMapView(activation: vm.muscleActivation)
                            .frame(height: 150)
                            .frame(maxWidth: .infinity)
                            .padding(.top, Theme.Space.xs)
                            .animation(Motion.standard, value: vm.completedSetCount)
                        ForEach(vm.exercises) { exercise in
                            ExerciseSection(vm: vm, exercise: exercise)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        addExerciseButton(vm).padding(.top, Theme.Space.sm)
                    }
                    .padding(Theme.Space.md)
                    .padding(.bottom, 120)
                    .animation(Motion.standard, value: vm.exercises.count)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar(vm) }
        .sheet(isPresented: $showingLibrary) {
            ExerciseLibraryView { exercises in
                Task { for exercise in exercises { await vm.addExercise(exercise) } }
            }
        }
        .sheet(isPresented: $showingPlates) {
            PlateCalculatorView(weightUnit: vm.weightUnit)
        }
        .confirmationDialog("End this workout?", isPresented: $confirmExit, titleVisibility: .visible) {
            if vm.completedSetCount > 0 {
                Button("Finish & save") { Task { onFinish(await vm.finish()) } }
            }
            Button("Discard workout", role: .destructive) { Task { await vm.discard(); onFinish(nil) } }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text(vm.completedSetCount > 0
                 ? "Save your \(vm.completedSetCount) logged set\(vm.completedSetCount == 1 ? "" : "s"), or discard the workout."
                 : "Nothing's logged yet. Discard this workout?")
        }
    }

    private func header(_ vm: StrengthViewModel) -> some View {
        HStack(alignment: .top) {
            Button {
                // Never silently lose a workout: confirm if there's anything logged; the timer keeps
                // running until the user explicitly finishes or discards.
                if vm.hasContent { confirmExit = true } else { Task { await vm.discard(); onFinish(nil) } }
            } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            Spacer()
            TimelineView(.periodic(from: vm.startedAt, by: 1)) { ctx in
                let elapsed = ctx.date.timeIntervalSince(vm.startedAt)
                VStack(spacing: 2) {
                    Text(Formatters.duration(s: elapsed))
                        .font(.display(Theme.FontSize.title, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                    Text("\(Int(vm.liveVolumeDisplay)) \(vm.weightUnitLabel) vol · \(vm.completedSetCount) sets")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.inkTertiary)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.3), value: vm.completedSetCount)
                }
            }
            Spacer()
            Button { showingPlates = true } label: {
                Image(systemName: "rectangle.split.3x1").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
    }

    private func emptyState(_ vm: StrengthViewModel) -> some View {
        VStack(spacing: Theme.Space.lg) {
            Spacer()
            MuscleMapView(activation: [:])
                .frame(height: 220)
                .frame(maxWidth: .infinity)
            Text("Add your first exercise")
                .font(.rounded(Theme.FontSize.body, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
            addExerciseButton(vm).frame(maxWidth: 260)
            Spacer()
        }
    }

    private func addExerciseButton(_ vm: StrengthViewModel) -> some View {
        OversizedButton(title: "Add exercise", systemImage: "plus", kind: .outline) {
            showingLibrary = true
        }
    }

    private func bottomBar(_ vm: StrengthViewModel) -> some View {
        OversizedButton(title: "Finish", isEnabled: vm.completedSetCount > 0) {
            Task {
                let id = await vm.finish()
                onFinish(id)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.bottom, Theme.Space.sm)
        .momentumGlass(in: Rectangle(), stroke: false)
    }
}

/// One exercise: header + its set rows + add-set.
private struct ExerciseSection: View {
    let vm: StrengthViewModel
    let exercise: StrengthSessionEngine.LiveExercise

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(exercise.name)
                .font(.rounded(Theme.FontSize.headline, weight: .bold))
                .foregroundStyle(Theme.ink)
            ForEach(exercise.sets) { set in
                SetRowView(vm: vm, rowId: exercise.id, set: set)
                Divider().overlay(Theme.hairline)
            }
            Button {
                Task { await vm.addSet(rowId: exercise.id) }
            } label: {
                Label("Add set", systemImage: "plus")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
        .animation(Motion.standard, value: exercise.sets.count)
    }
}

/// Floating rest-timer ring (PRD §4.4) — depletes with an iridescent edge; medium haptic at zero.
private struct RestBar: View {
    let vm: StrengthViewModel
    @Environment(Services.self) private var services
    @State private var now = Date()
    @State private var didPulse = false
    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        let remaining = vm.restRemaining(at: now) ?? 0
        let progress = vm.restTotal > 0 ? remaining / vm.restTotal : 0
        VStack {
            Spacer()
            HStack(spacing: Theme.Space.lg) {
                Button { vm.adjustRest(by: -15) } label: {
                    Image(systemName: "gobackward.15").frame(width: 56, height: 56).contentShape(Rectangle())
                }
                .accessibilityLabel("Subtract 15 seconds")
                RestTimerRing(progress: progress, remainingText: Formatters.duration(s: remaining),
                              isComplete: remaining <= 0)
                    .frame(width: 96, height: 96)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Rest timer")
                    .accessibilityValue(remaining <= 0 ? "Done" : "\(Formatters.duration(s: remaining)) remaining")
                Button { vm.adjustRest(by: 15) } label: {
                    Image(systemName: "goforward.15").frame(width: 56, height: 56).contentShape(Rectangle())
                }
                .accessibilityLabel("Add 15 seconds")
            }
            .font(.system(size: 22))
            .foregroundStyle(Theme.ink)
            .padding(Theme.Space.lg)
            .momentumGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button { vm.skipRest() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.inkTertiary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Skip rest")
            }
            .padding(.bottom, 100)
        }
        .onReceive(tick) { date in
            now = date
            let remaining = vm.restRemaining(at: date) ?? 0
            if remaining > 0 {
                // A new rest is running — re-arm the completion pulse. Without this, only the FIRST
                // rest of a continuous bar session ever buzzed/announced (the view instance survives
                // between sets, so a one-way flag stayed latched).
                didPulse = false
            } else if !didPulse {
                Haptics.medium()
                services.analytics.log(.restTimerComplete)
                if services.paywall.isEntitled(to: .voiceCoach) {
                    services.voiceCoach.announce(CoachingCueBuilder.restComplete())
                }
                didPulse = true
            }
        }
    }
}
