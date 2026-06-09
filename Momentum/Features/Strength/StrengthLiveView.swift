import SwiftUI
import SwiftData

/// The strength logging screen (PRD §4.4, §7.5) — the fastest, calmest lifting log on iOS.
/// Owns a `StrengthViewModel`; presents the library to add exercises and a summary on finish.
struct StrengthLiveView: View {
    let container: ModelContainer
    var onFinish: (UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var vm: StrengthViewModel?
    @State private var showingLibrary = false
    @State private var showingPlates = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let vm {
                content(vm)
                if vm.restEndsAt != nil { RestBar(vm: vm) }
            } else {
                ProgressView()
            }
        }
        .task {
            guard vm == nil else { return }
            let model = StrengthViewModel(container: container)
            await model.start()
            vm = model
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
                        ForEach(vm.exercises) { exercise in
                            ExerciseSection(vm: vm, exercise: exercise)
                        }
                        addExerciseButton(vm).padding(.top, Theme.Space.sm)
                    }
                    .padding(Theme.Space.md)
                    .padding(.bottom, 120)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar(vm) }
        .sheet(isPresented: $showingLibrary) {
            ExerciseLibraryView { exercise in
                Task { await vm.addExercise(exercise) }
            }
        }
        .sheet(isPresented: $showingPlates) {
            PlateCalculatorView(weightUnit: vm.weightUnit)
        }
    }

    private func header(_ vm: StrengthViewModel) -> some View {
        HStack(alignment: .top) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            TimelineView(.periodic(from: vm.startedAt, by: 1)) { ctx in
                let elapsed = ctx.date.timeIntervalSince(vm.startedAt)
                VStack(spacing: 2) {
                    Text(Formatters.duration(s: elapsed))
                        .font(.system(size: Theme.FontSize.title, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                    Text("\(Int(vm.liveVolumeDisplay)) \(vm.weightUnitLabel) vol · \(vm.completedSetCount) sets")
                        .font(.system(size: Theme.FontSize.caption))
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            Spacer()
            Button { showingPlates = true } label: {
                Image(systemName: "rectangle.split.3x1").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
    }

    private func emptyState(_ vm: StrengthViewModel) -> some View {
        VStack(spacing: Theme.Space.lg) {
            Spacer()
            Image(systemName: "dumbbell.fill").font(.system(size: 40)).foregroundStyle(Theme.inkTertiary)
            Text("Add your first exercise").foregroundStyle(Theme.inkSecondary)
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
        .background(.ultraThinMaterial)
    }
}

/// One exercise: header + its set rows + add-set.
private struct ExerciseSection: View {
    let vm: StrengthViewModel
    let exercise: StrengthSessionEngine.LiveExercise

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(exercise.name)
                .font(.system(size: Theme.FontSize.headline, weight: .semibold))
                .foregroundStyle(Theme.ink)
            ForEach(exercise.sets) { set in
                SetRowView(vm: vm, rowId: exercise.id, set: set)
                Divider().overlay(Theme.hairline)
            }
            Button {
                Task { await vm.addSet(rowId: exercise.id) }
            } label: {
                Label("Add set", systemImage: "plus")
                    .font(.system(size: Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .padding(.top, Theme.Space.xs)
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
    }
}

/// Floating rest-timer ring (PRD §4.4) — depletes with an iridescent edge; medium haptic at zero.
private struct RestBar: View {
    let vm: StrengthViewModel
    @State private var now = Date()
    @State private var didPulse = false
    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        let remaining = vm.restRemaining(at: now) ?? 0
        let progress = vm.restTotal > 0 ? remaining / vm.restTotal : 0
        VStack {
            Spacer()
            HStack(spacing: Theme.Space.lg) {
                Button { vm.adjustRest(by: -15) } label: { Image(systemName: "gobackward.15") }
                    .accessibilityLabel("Subtract 15 seconds")
                RestTimerRing(progress: progress, remainingText: Formatters.duration(s: remaining),
                              isComplete: remaining <= 0)
                    .frame(width: 96, height: 96)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Rest timer")
                    .accessibilityValue(remaining <= 0 ? "Done" : "\(Formatters.duration(s: remaining)) remaining")
                Button { vm.adjustRest(by: 15) } label: { Image(systemName: "goforward.15") }
                    .accessibilityLabel("Add 15 seconds")
            }
            .font(.system(size: 22))
            .foregroundStyle(Theme.ink)
            .padding(Theme.Space.lg)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.sheet))
            .overlay(alignment: .topTrailing) {
                Button { vm.skipRest() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.inkTertiary)
                }.padding(Theme.Space.sm)
                .accessibilityLabel("Skip rest")
            }
            .padding(.bottom, 100)
        }
        .onReceive(tick) { date in
            now = date
            if (vm.restRemaining(at: date) ?? 0) <= 0 && !didPulse {
                Haptics.medium()
                didPulse = true
            }
        }
    }
}
