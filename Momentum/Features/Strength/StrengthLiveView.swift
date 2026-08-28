import SwiftUI
import SwiftData

/// The strength logging screen (PRD §4.4, §7.5) — the fastest, calmest lifting log on iOS.
/// Owns a `StrengthViewModel`; presents the library to add exercises and a summary on finish.
struct StrengthLiveView: View {
    let container: ModelContainer
    var type: WorkoutType = .strength
    var plannedSession: PlannedSession? = nil
    var onFinish: (UUID?) -> Void

    @Environment(Services.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var vm: StrengthViewModel?
    @State private var showingLibrary = false
    @State private var showingPlates = false
    @State private var confirmExit = false
    @State private var confirmFinishWithDrafts = false
    /// One finish per workout: the buttons stayed live during the finish await, so a double-tap
    /// (or re-opening the exit dialog mid-save) ran the whole finish path — and `onFinish` —
    /// twice (audit 2026-08-11). Every finish/discard route funnels through `finishOnce`.
    @State private var finishing = false
    /// The exercise waiting for its superset partner — presents the library in pick-one mode.
    @State private var supersetAnchor: SupersetAnchor?
    /// The live muscle map animates only while visible — see its `.onScrollVisibilityChange`.
    @State private var mapOnScreen = true
    private struct SupersetAnchor: Identifiable { let id: UUID }

    /// Display groups: superset members render as one card, everything else as singles.
    /// Members are adjacent by construction (the engine reorders on pairing).
    private func exerciseGroups(_ vm: StrengthViewModel) -> [[StrengthSessionEngine.LiveExercise]] {
        var groups: [[StrengthSessionEngine.LiveExercise]] = []
        for ex in vm.exercises {
            if let g = ex.supersetGroup, let last = groups.last, last.first?.supersetGroup == g {
                groups[groups.count - 1].append(ex)
            } else {
                groups.append([ex])
            }
        }
        return groups
    }

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
            #if DEBUG
            // --superset-demo: pair the first two exercises for screenshot verification
            // (simctl can't drive the library picker).
            if ProcessInfo.processInfo.arguments.contains("--superset-demo"),
               model.exercises.count >= 2 {
                await model.pairExisting(model.exercises[0].id, model.exercises[1].id)
            }
            #endif
            vm = model
            #if DEBUG
            // --superset-picker-demo: open the partner picker on the first exercise.
            if ProcessInfo.processInfo.arguments.contains("--superset-picker-demo"),
               let first = model.exercises.first {
                try? await Task.sleep(for: .milliseconds(600))   // let the cover settle first
                supersetAnchor = SupersetAnchor(id: first.id)
            }
            #endif
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: Theme.Space.lg) {
                            // Frozen once scrolled past (the AthletePanel pattern, perf audit
                            // 2026-08-13): the live mesh otherwise burned 30 fps under the whole
                            // session while the athlete worked far down the exercise list.
                            MuscleMapView(activation: vm.muscleActivation, forceStatic: !mapOnScreen)
                                .frame(height: 150)
                                .frame(maxWidth: .infinity)
                                .padding(.top, Theme.Space.xs)
                                .animation(Motion.standard, value: vm.completedSetCount)
                                .onScrollVisibilityChange(threshold: 0.05) { mapOnScreen = $0 }
                            ForEach(exerciseGroups(vm), id: \.first!.id) { group in
                                if group.count > 1 {
                                    SupersetSection(vm: vm, members: group)
                                        .id(group.first!.id)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                } else {
                                    ExerciseSection(vm: vm, exercise: group[0],
                                                    onSuperset: group[0].supersetGroup == nil
                                                        ? { supersetAnchor = SupersetAnchor(id: group[0].id) }
                                                        : nil)
                                        .id(group[0].id)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                            addExerciseButton(vm).padding(.top, Theme.Space.sm)
                        }
                        .padding(Theme.Space.md)
                        .padding(.bottom, 120)
                        .animation(Motion.standard, value: vm.exercises.count)
                    }
                    // Number pads have no Return key — without this, the keyboard can only be
                    // dismissed by logging a set or focusing elsewhere, and it buries the Finish bar.
                    .scrollDismissesKeyboard(.interactively)
                    // The checklist advances itself: when an exercise's (or superset pair's) last
                    // set is checked, the next unfinished card scrolls into place (after the ✓
                    // bounce has its moment). Supersets anchor on their first member.
                    .onChange(of: vm.lastCompletedRowId) { _, completed in
                        guard completed != nil, let next = vm.firstIncompleteRowId else { return }
                        let anchor = exerciseGroups(vm)
                            .first(where: { $0.contains { $0.id == next } })?.first?.id ?? next
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            withAnimation(reduceMotion ? nil : Motion.standard) {
                                proxy.scrollTo(anchor, anchor: .top)
                            }
                        }
                    }
                    // Mid-superset-round the next move is the PARTNER'S set — in a tall pair
                    // card it can sit a screen away, so it presents itself (centered).
                    .onChange(of: vm.roundNextSetId) { _, nextSet in
                        guard let nextSet else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            withAnimation(reduceMotion ? nil : Motion.standard) {
                                proxy.scrollTo(nextSet, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar(vm) }
        .sheet(isPresented: $showingLibrary) {
            ExerciseLibraryView { exercises in
                Task { for exercise in exercises { await vm.addExercise(exercise) } }
            }
        }
        .sheet(item: $supersetAnchor) { anchor in
            // The partner picker names the anchor and leads with what's easiest: link an
            // exercise already on the list, take an antagonist suggestion, or browse.
            SupersetPickerView(vm: vm, anchorRowId: anchor.id) { supersetAnchor = nil }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingPlates) {
            PlateCalculatorView(weightUnit: vm.weightUnit)
        }
        .confirmationDialog("End this workout?", isPresented: $confirmExit, titleVisibility: .visible) {
            if vm.completedSetCount > 0 {
                Button("Finish & save") { finishOnce { onFinish(await vm.finish()) } }
            }
            Button("Discard workout", role: .destructive) { finishOnce { await vm.discard(); onFinish(nil) } }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text(vm.completedSetCount > 0
                 ? "Save your \(vm.completedSetCount) logged set\(vm.completedSetCount == 1 ? "" : "s"), or discard the workout."
                 : "Nothing's logged yet. Discard this workout?")
        }
    }

    /// Runs a finish/discard route exactly once — later taps no-op while the first is in
    /// flight (and the view never un-latches: `onFinish` tears it down).
    private func finishOnce(_ work: @escaping () async -> Void) {
        guard !finishing else { return }
        finishing = true
        Task { await work() }
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
        OversizedButton(title: "Finish", isEnabled: vm.completedSetCount > 0 && !finishing) {
            // A filled-in set that was never ✓-logged would silently vanish from the summary —
            // the most natural end-of-workout gesture (type last set → Finish) must not lose it.
            if pendingDraftSets(vm).isEmpty {
                finishOnce { onFinish(await vm.finish()) }
            } else {
                confirmFinishWithDrafts = true
            }
        }
        .confirmationDialog("Some filled-in sets aren't logged yet",
                            isPresented: $confirmFinishWithDrafts, titleVisibility: .visible) {
            Button("Log them and finish") {
                finishOnce {
                    for p in pendingDraftSets(vm) { await vm.completeSet(rowId: p.rowId, setId: p.setId) }
                    onFinish(await vm.finish())
                }
            }
            Button("Finish without them") {
                finishOnce { onFinish(await vm.finish()) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.bottom, Theme.Space.sm)
        .momentumGlass(in: Rectangle(), stroke: false)
    }

    /// Sets the athlete TYPED INTO but never ✓-logged — what Finish would silently drop.
    /// Untouched plan prefill deliberately doesn't count: an unchecked target is work not done,
    /// and bulk-logging it would write sets the athlete never performed.
    private func pendingDraftSets(_ vm: StrengthViewModel) -> [(rowId: UUID, setId: UUID)] {
        vm.pendingEditedSets
    }
}

/// One exercise's header + rows + actions — the shared body of the single card and each half
/// of a superset card.
private struct ExerciseContent: View {
    let vm: StrengthViewModel
    let exercise: StrengthSessionEngine.LiveExercise
    /// Present when this exercise can still be paired (standalone cards only — pairs stay pairs).
    var onSuperset: (() -> Void)? = nil

    private var doneCount: Int { exercise.sets.filter(\.isComplete).count }
    private var isDone: Bool { !exercise.sets.isEmpty && doneCount == exercise.sets.count }

    /// Working sets number 1…N regardless of warm-ups above them ("W, W, 1, 2, 3") — the set
    /// number is a training fact ("set 3 of 4"), not a list position.
    private func workingNumber(of set: StrengthSessionEngine.LiveSet) -> Int? {
        guard set.type == .working else { return nil }
        let working = exercise.sets.filter { $0.type == .working }
        guard let i = working.firstIndex(where: { $0.id == set.id }) else { return nil }
        return i + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                Text(exercise.name)
                    .font(.rounded(Theme.FontSize.headline, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.success)
                        .symbolEffect(.bounce, value: isDone)
                        .accessibilityLabel("Exercise complete")
                } else {
                    Text("\(doneCount)/\(exercise.sets.count)")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Theme.inkTertiary)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.3), value: doneCount)
                        .accessibilityLabel("\(doneCount) of \(exercise.sets.count) sets logged")
                }
            }
            // The plan's ask, visible while you do the work — the checklist's "what am I
            // supposed to do" line (free sessions have no prescription and show nothing).
            if let line = vm.prescriptionLine(rowId: exercise.id) {
                Text(line)
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
                    .padding(.bottom, 2)
            }
            ForEach(exercise.sets) { set in
                SetRowView(vm: vm, rowId: exercise.id, set: set,
                           displayNumber: workingNumber(of: set))
                    .id(set.id)
                Divider().overlay(Theme.hairline)
            }
            HStack(spacing: Theme.Space.lg) {
                Button {
                    Task { await vm.addSet(rowId: exercise.id) }
                } label: {
                    Label("Add set", systemImage: "plus")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }
                // Prep work is part of the list too — a warm-up set slots in above the working
                // sets, wears the W marker, and stays out of volume/PR math.
                Button {
                    Task { await vm.addWarmupSet(rowId: exercise.id) }
                } label: {
                    Label("Warm-up", systemImage: "plus")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }
                .accessibilityLabel("Add warm-up set")
                if let onSuperset {
                    Button(action: onSuperset) {
                        Label("Superset", systemImage: "link")
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                            .foregroundStyle(Theme.inkTertiary)
                            .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Pair with another exercise as a superset")
                }
            }
        }
        .animation(Motion.standard, value: exercise.sets.count)
    }
}

/// One standalone exercise card.
private struct ExerciseSection: View {
    let vm: StrengthViewModel
    let exercise: StrengthSessionEngine.LiveExercise
    var onSuperset: (() -> Void)? = nil

    private var isDone: Bool {
        !exercise.sets.isEmpty && exercise.sets.allSatisfy(\.isComplete)
    }

    var body: some View {
        ExerciseContent(vm: vm, exercise: exercise, onSuperset: onSuperset)
            .padding(Theme.Space.md)
            .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(isDone ? Theme.success.opacity(0.35) : .clear, lineWidth: 1))
            .animation(Motion.standard, value: isDone)
    }
}

/// A superset: the pair in ONE card so the alternating flow reads at a glance. Rest comes after
/// the round (both partners' set), which `StrengthViewModel.completeSet` enforces — this card
/// just makes the back-and-forth visible: A's set, straight into B's right below.
private struct SupersetSection: View {
    let vm: StrengthViewModel
    let members: [StrengthSessionEngine.LiveExercise]

    private var isDone: Bool {
        members.allSatisfy { !$0.sets.isEmpty && $0.sets.allSatisfy(\.isComplete) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 10, weight: .bold))
                Text("SUPERSET").tracking(1.2)
                Text("· no rest between exercises").textCase(nil).tracking(0)
                Spacer(minLength: 0)
                Button {
                    if let first = members.first {
                        Task { await vm.unlinkSuperset(rowId: first.id) }
                    }
                } label: {
                    Text("Unlink")
                        .font(.rounded(Theme.FontSize.label, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(minHeight: 32).contentShape(Rectangle())
                }
                .accessibilityLabel("Unlink this superset")
            }
            .font(.rounded(Theme.FontSize.label, weight: .bold))
            .foregroundStyle(Theme.inkTertiary)
            ForEach(Array(members.enumerated()), id: \.element.id) { i, member in
                if i > 0 {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                        .padding(.vertical, Theme.Space.xs)
                }
                ExerciseContent(vm: vm, exercise: member)
            }
        }
        .padding(Theme.Space.md)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .stroke(isDone ? Theme.success.opacity(0.35) : Theme.hairline, lineWidth: 1))
        .animation(Motion.standard, value: isDone)
    }
}

/// Floating rest-timer ring (PRD §4.4) — depletes with an iridescent edge; medium haptic at zero.
/// The 10 Hz clock lives in `RestRingTicker`, the leaf that actually depletes — as one view, every
/// tick re-composited the glass panel and buttons too (perf audit 2026-08-13; the MicLevelBars
/// leaf rule: high-frequency state is read only by the smallest view that needs it).
private struct RestBar: View {
    let vm: StrengthViewModel

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: Theme.Space.lg) {
                Button { vm.adjustRest(by: -15) } label: {
                    Image(systemName: "gobackward.15").frame(width: 56, height: 56).contentShape(Rectangle())
                }
                .accessibilityLabel("Subtract 15 seconds")
                RestRingTicker(vm: vm)
                    .frame(width: 96, height: 96)
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
    }
}

/// The depleting ring itself — the ONLY reader of the 10 Hz tick.
private struct RestRingTicker: View {
    let vm: StrengthViewModel
    @Environment(Services.self) private var services
    @State private var now = Date()
    @State private var didPulse = false
    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        let remaining = vm.restRemaining(at: now) ?? 0
        let progress = vm.restTotal > 0 ? remaining / vm.restTotal : 0
        RestTimerRing(progress: progress, remainingText: Formatters.duration(s: remaining),
                      isComplete: remaining <= 0)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rest timer")
            .accessibilityValue(remaining <= 0 ? "Done" : "\(Formatters.duration(s: remaining)) remaining")
            .onReceive(tick) { date in
                now = date
                let remaining = vm.restRemaining(at: date) ?? 0
                if remaining > 0 {
                    // A new rest is running — re-arm the completion pulse. Without this, only the
                    // FIRST rest of a continuous bar session ever buzzed/announced (the view
                    // instance survives between sets, so a one-way flag stayed latched).
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
