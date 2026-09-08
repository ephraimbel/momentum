import SwiftUI
import SwiftData

/// How the builder ended, so the shelf can reopen or the board can repopulate.
enum PlanBuilderOutcome: Equatable {
    case cancelled, savedDraft, scheduled, activated
}

/// Create a plan without replaying onboarding (2026-09-07, docs/PLAN-AND-FUEL-UPGRADE.md §2.2):
/// goal → target → where you are → your week → how to train → preview → start, schedule, or keep
/// as a draft. Every step opens on what the athlete already told us. The preview is the real
/// generator run on the blueprint, debounced and cancelled on change, and nothing here touches the
/// current plan until Start now is confirmed.
struct PlanBuilderFlow: View {
    let profile: UserProfile
    /// Editing an existing draft or upcoming plan; nil is a fresh plan.
    let draft: PlanShelfRecord?
    let distanceUnit: DistanceUnit
    /// The host's already-fetched workouts, for propagation after a start (never the profile's
    /// whole relationship, which faults every workout ever logged).
    let workouts: [Workout]
    var onFinish: (PlanBuilderOutcome) -> Void

    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services
    @ReducedMotionPreference private var reduceMotion

    /// The four doors the engine can honestly tell apart: a dated race, a distance to improve at
    /// (rolling blocks shaped for it, with a checkpoint), a first or returning run (a repeatable
    /// week, no checkpoint, gentle recommended), and general fitness (rolling blocks).
    enum Path: String, CaseIterable, Identifiable {
        case race, improve, start, general
        var id: String { rawValue }
        var title: String {
            switch self {
            case .race: "Train for a race"
            case .improve: "Get faster at a distance"
            case .start: "Start or return to running"
            case .general: "Build running fitness"
            }
        }
        var subtitle: String {
            switch self {
            case .race: "A date on the calendar. The block builds, peaks and tapers to it."
            case .improve: "No race yet. Six-week blocks shaped for the distance, each ending with a checkpoint."
            case .start: "A week you can repeat. Easy running first, nothing to prove."
            case .general: "Rolling blocks that grow with you. Point them at a race whenever you like."
            }
        }
        var systemImage: String {
            switch self {
            case .race: "flag.checkered"
            case .improve: "stopwatch"
            case .start: "figure.walk"
            case .general: "figure.run.circle"
            }
        }
    }

    enum Step: Int, CaseIterable {
        case goal, target, fitness, week, training, preview
        var title: String {
            switch self {
            case .goal: "What is this plan for?"
            case .target: "The target"
            case .fitness: "Where you are"
            case .week: "Your week"
            case .training: "How to train"
            case .preview: "Your plan"
            }
        }
    }

    @State private var step: Step = .goal
    @State private var path: Path?
    @State private var blueprint: PlanBlueprint
    @State private var hasGoalTime: Bool
    @State private var goalHours: Int
    @State private var goalMinutes: Int
    @State private var raceDay: Date
    @State private var showRacePicker = false
    /// The coach's read of the athlete's logged running; the blueprint's declared numbers are the
    /// fallback the engine uses when there is no history.
    @State private var evidence: PlanFitnessSnapshot?
    @State private var preview: PlanPreview?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewToken = 0
    @State private var previewing = false
    @State private var scheduling = false
    @State private var overlap: PendingOverlap?
    @State private var failure: String?
    @State private var confirmingDiscard = false
    /// The record a fresh plan's first Schedule created, so a failed attempt retries on it.
    @State private var created: PlanShelfRecord?
    /// Podium (or any floor) emptied the chosen days: the note says so once.
    @State private var daysClearedByIntensity = false

    private struct PendingOverlap: Identifiable {
        let overlap: PlanLifecycle.Overlap
        /// The day the plan would start: activation's real start for Start now, or the scheduled day.
        let startDay: Date
        let startsNow: Bool
        var id: String { "\(overlap.currentEnd.timeIntervalSince1970)-\(startDay.timeIntervalSince1970)" }
    }

    init(profile: UserProfile, draft: PlanShelfRecord?, distanceUnit: DistanceUnit, workouts: [Workout] = [],
         onFinish: @escaping (PlanBuilderOutcome) -> Void) {
        self.profile = profile
        self.draft = draft
        self.distanceUnit = distanceUnit
        self.workouts = workouts
        self.onFinish = onFinish
        var b = draft?.blueprint ?? PlanBlueprint(profile: profile)
        if draft == nil {
            // A fresh plan keeps the athlete's availability and preferences, never the old finish line.
            b.name = ""
            b.raceDate = nil
            b.goalFinishTimeS = nil
            b.raceDistanceM = nil
        }
        _blueprint = State(initialValue: b)
        _hasGoalTime = State(initialValue: b.goalFinishTimeS != nil)
        let goalS = b.goalFinishTimeS ?? 0
        _goalHours = State(initialValue: Int(goalS) / 3600)
        _goalMinutes = State(initialValue: (Int(goalS) % 3600) / 60)
        let cal = Calendar.current
        _raceDay = State(initialValue: b.raceDate ?? cal.date(byAdding: .weekOfYear, value: 12, to: Date()) ?? Date())
        let initialPath: Path?
        if let draft, let blueprint = draft.blueprint {
            switch blueprint.goal {
            case .raceDistance: initialPath = blueprint.raceDate == nil ? .improve : .race
            case .stayConsistent: initialPath = .start
            default: initialPath = .general
            }
        } else {
            initialPath = nil
        }
        _path = State(initialValue: initialPath)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                stepStrip
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.xl) {
                        Text(step.title)
                            .font(.display(Theme.FontSize.headline, weight: .heavy)).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        // Keyed on the step and crossfaded: swapping the subtree under a spring
                        // animated the layout of a whole step (a graphical date picker and two
                        // wheels on the race step), which is the one kind of animation the house
                        // rule forbids.
                        stepContent
                            .id(step)
                            .transition(.opacity)
                    }
                    .padding(Theme.Space.lg)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background(Theme.background)
            .safeAreaInset(edge: .bottom) { footer }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(draft == nil ? "new plan" : "edit plan")
                        .font(.display(20, weight: .bold)).foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // Nothing chosen yet, or a draft opened and left as it was: just leave.
                        // Anything else is an edit worth a word before it is thrown away.
                        if hasUnsavedEdits { confirmingDiscard = true }
                        else { previewTask?.cancel(); onFinish(.cancelled) }
                    }
                }
            }
            .sheet(isPresented: $showRacePicker) {
                RacePickerSheet { race, pickedDistance, date in
                    withAnimation(reduceMotion ? nil : Motion.standard) {
                        blueprint.name = race.name
                        blueprint.raceDistanceM = pickedDistance.meters
                        raceDay = date
                        if hasGoalTime { seedGoalTime() }
                        syncTarget()
                    }
                }
            }
            .sheet(isPresented: $scheduling) {
                PlanScheduleSheet(initial: draft?.scheduledStart,
                                  currentEnd: PlanLifecycleService.currentSpan(for: profile)?.end,
                                  latest: blueprint.isRace ? blueprint.raceDate : nil) { day in
                    schedule(on: day)
                }
            }
            .sheet(item: $overlap) { pending in
                PlanOverlapSheet(planName: blueprint.displayName,
                                 currentName: currentPlanName,
                                 overlap: pending.overlap,
                                 startDay: pending.startDay,
                                 onReplace: {
                                     if pending.startsNow { activate() } else { commitSchedule(on: pending.startDay) }
                                 },
                                 onStartAfter: { commitSchedule(on: pending.overlap.nextFreeStart) })
            }
            .alert("That didn’t work", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "Please try again.") }
            .task(id: blueprint.fitnessDeclaredAt) { await loadEvidence() }
            .onAppear {
                #if DEBUG
                // --plan-builder-preview: a 10K in ten weeks, straight to the preview step.
                if ProcessInfo.processInfo.arguments.contains("--plan-builder-preview"), draft == nil {
                    choose(.race)
                    blueprint.name = "Faster 10K"
                    blueprint.raceDistanceM = RaceDistance.tenK.meters
                    raceDay = Calendar.current.date(byAdding: .weekOfYear, value: 10, to: Date()) ?? Date()
                    hasGoalTime = true
                    goalHours = 0; goalMinutes = 48
                    syncTarget()
                    step = .preview
                }
                #endif
            }
            // A beat after the step transition, so the generator never runs under the animation.
            .onChange(of: step) { _, new in
                if new == .preview { PerfMark.start("builder-preview"); schedulePreview(delay: 0.3) }
            }
            .onChange(of: blueprint) { _, _ in if step == .preview { schedulePreview(delay: 0.35) } }
            .onDisappear { previewTask?.cancel() }
        }
        .nestedPaywallHost()
        .onAppear { PerfMark.end("builder-open") }
        .presentationDetents([.large])
        // A swipe never bypasses the Cancel button's question or the shelf handoff behind it.
        .interactiveDismissDisabled(step != .goal || draft != nil)
        .confirmationDialog("Leave without saving?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button(draft == nil ? "Save as draft" : "Save changes") { saveDraft() }
            Button("Discard", role: .destructive) { previewTask?.cancel(); onFinish(.cancelled) }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text(draft == nil
                 ? "Nothing has been written yet. A draft keeps everything you chose."
                 : "The plan keeps its last saved version unless you save these changes.")
        }
        .trackScreen(.planBuilder)
    }

    private var stepStrip: some View {
        HStack(spacing: 4) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? Theme.ink : Theme.hairline)
                    .frame(height: 3)
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .goal: goalStep
        case .target: targetStep
        case .fitness: fitnessStep
        case .week: weekStep
        case .training: trainingStep
        case .preview: previewStep
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: Theme.Space.sm) {
            if step == .preview {
                previewActions
            } else {
                HStack(spacing: Theme.Space.sm) {
                    if step != .goal {
                        Button { back() } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                                .frame(width: 52, height: 52)
                                .background(Circle().stroke(Theme.ink, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Back")
                    }
                    Button { advance() } label: {
                        Text(step == .training ? "See the plan" : "Continue")
                            .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity).frame(minHeight: 52)
                            .raised(Capsule(), tone: .ink)
                    }
                    .buttonStyle(RaisedPressStyle())
                    .disabled(!canAdvance)
                    .opacity(canAdvance ? 1 : 0.45)
                    .accessibilityIdentifier("builder-continue")
                }
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.sm)
        .padding(.bottom, Theme.Space.sm)
        .background(Theme.background.opacity(0.96))
    }

    private var previewActions: some View {
        VStack(spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Button { back() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(width: 52, height: 52)
                        .background(Circle().stroke(Theme.ink, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                Button { startNow() } label: {
                    Text("Start now")
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity).frame(minHeight: 52)
                        .raised(Capsule(), tone: .ink)
                }
                .buttonStyle(RaisedPressStyle())
                .disabled(preview == nil)
                .opacity(preview == nil ? 0.45 : 1)
                .accessibilityIdentifier("builder-start")
            }
            HStack(spacing: Theme.Space.sm) {
                Button { scheduling = true } label: {
                    Text("Schedule")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity).frame(minHeight: 44)
                        .background(Capsule().stroke(Theme.ink, lineWidth: 1.25))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("builder-schedule")
                Button { saveDraft() } label: {
                    Text(draft == nil ? "Save as draft" : (draft?.status == .upcoming ? "Save changes" : "Save draft"))
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity).frame(minHeight: 44)
                        .background(Capsule().stroke(Theme.ink, lineWidth: 1.25))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("builder-draft")
            }
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .goal: path != nil
        case .target:
            switch path {
            case .race: blueprint.raceDistanceM != nil && raceDayIsValid
            case .improve: blueprint.raceDistanceM != nil
            default: true
            }
        case .week: !tooFewDaysChosen
        default: true
        }
    }

    /// The scheduler honours chosen days only when there are at least as many as the week has
    /// sessions; fewer and it spreads the week itself. The step says so instead of storing a
    /// choice the engine ignores.
    private var tooFewDaysChosen: Bool {
        !blueprint.preferredDays.isEmpty && blueprint.preferredDays.count < blueprint.daysPerWeek
    }

    private var raceDayIsValid: Bool {
        Calendar.current.startOfDay(for: raceDay) > Calendar.current.startOfDay(for: Date())
    }

    private func advance() {
        guard canAdvance, let next = Step(rawValue: step.rawValue + 1) else { return }
        Haptics.light()
        withAnimation(reduceMotion ? nil : Motion.crossfade) { step = next }
    }

    private func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        Haptics.light()
        withAnimation(reduceMotion ? nil : Motion.crossfade) { step = previous }
    }

    // MARK: - Step 1: goal

    private var goalStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Each door builds a different plan. Strength for runners can be added to any of them.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Path.allCases) { door in
                SelectionCard(title: door.title, subtitle: door.subtitle, systemImage: door.systemImage,
                              isSelected: path == door) {
                    withAnimation(reduceMotion ? nil : Motion.standard) { choose(door) }
                }
                .accessibilityIdentifier("builder-path-\(door.rawValue)")
            }
        }
    }

    private func choose(_ door: Path) {
        let changed = path != door
        path = door
        switch door {
        case .race:
            blueprint.goal = .raceDistance
        case .improve:
            blueprint.goal = .raceDistance
            blueprint.raceDate = nil
        case .start:
            blueprint.goal = .stayConsistent
            blueprint.raceDistanceM = nil; blueprint.raceDate = nil; blueprint.goalFinishTimeS = nil
            // Gentle defaults are the door's opening offer, applied once on the way in; a
            // re-tap or a draft being edited keeps what the athlete chose since.
            if changed {
                if blueprint.runningExperience == .experienced { blueprint.runningExperience = .some }
                blueprint.intensity = .gentle
            }
        case .general:
            if blueprint.goal != .endurance { blueprint.goal = .generalFitness }
            blueprint.raceDistanceM = nil; blueprint.raceDate = nil; blueprint.goalFinishTimeS = nil
        }
        syncTarget()
    }

    // MARK: - Step 2: target

    @ViewBuilder
    private var targetStep: some View {
        switch path {
        case .race: raceTarget
        case .improve: improveTarget
        case .start: startTarget
        case .general, .none: generalTarget
        }
    }

    private var raceTarget: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            section("YOUR RACE") {
                VStack(spacing: Theme.Space.sm) {
                    Button { showRacePicker = true } label: {
                        HStack(spacing: Theme.Space.md) {
                            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(blueprint.name.isEmpty ? "Find your race" : blueprint.name)
                                    .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                                Text("Boston, Chicago, Hong Kong. The big ones, with dates.")
                                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                        }
                        .padding(Theme.Space.md)
                        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    distanceCards
                }
            }
            section("RACE DAY") {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    DatePicker("Race day", selection: $raceDay, in: Date()..., displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .padding(Theme.Space.sm)
                        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        .onChange(of: raceDay) { _, _ in syncTarget() }
                    if !raceDayIsValid {
                        Text("Pick a day after today.")
                            .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                    }
                }
            }
            goalTimeSection
            if let f = feasibility { feasibilityCard(f) }
        }
    }

    private var improveTarget: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            section("THE DISTANCE") {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text("Long runs and quality work are shaped for it. Every block ends with a checkpoint so your paces move with you.")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    distanceCards
                }
            }
            goalTimeSection
        }
    }

    private var startTarget: some View {
        section("WHERE YOU ARE STARTING") {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                SelectionCard(title: "New to running", subtitle: "Three easy days a week. Time on feet before anything else.",
                              systemImage: "figure.walk", isSelected: blueprint.runningExperience == .new) {
                    withAnimation(reduceMotion ? nil : Motion.standard) { blueprint.runningExperience = .new; blueprint.daysPerWeek = min(blueprint.daysPerWeek, 3) }
                }
                SelectionCard(title: "Coming back", subtitle: "You have run before. A gentle ramp back to a regular week.",
                              systemImage: "arrow.uturn.backward", isSelected: blueprint.runningExperience != .new) {
                    withAnimation(reduceMotion ? nil : Motion.standard) { blueprint.runningExperience = .some }
                }
                Text("If you are returning from an injury, the plan trains around it and never rushes the way back. Anything that persists or worries you is a question for a professional.")
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var generalTarget: some View {
        section("THE SHAPE OF IT") {
            VStack(spacing: Theme.Space.sm) {
                SelectionCard(title: Goal.generalFitness.planLabel, subtitle: Goal.generalFitness.planSubtitle,
                              systemImage: Goal.generalFitness.planSystemImage, isSelected: blueprint.goal == .generalFitness) {
                    withAnimation(reduceMotion ? nil : Motion.standard) { blueprint.goal = .generalFitness }
                }
                SelectionCard(title: Goal.endurance.planLabel, subtitle: Goal.endurance.planSubtitle,
                              systemImage: Goal.endurance.planSystemImage, isSelected: blueprint.goal == .endurance) {
                    withAnimation(reduceMotion ? nil : Motion.standard) { blueprint.goal = .endurance }
                }
            }
        }
    }

    private var distanceCards: some View {
        ForEach(RaceDistance.allCases) { d in
            SelectionCard(title: d.label, isSelected: blueprint.raceDistanceM == d.meters) {
                withAnimation(reduceMotion ? nil : Motion.standard) {
                    blueprint.raceDistanceM = d.meters
                    if hasGoalTime { seedGoalTime() }
                    syncTarget()
                }
            }
            .accessibilityIdentifier("builder-distance-\(d.rawValue)")
        }
    }

    private var goalTimeSection: some View {
        section(path == .improve ? "A TIME TO CHASE · OPTIONAL" : "TARGET FINISH · OPTIONAL") {
            VStack(spacing: Theme.Space.sm) {
                Toggle(isOn: $hasGoalTime.animation(reduceMotion ? nil : Motion.standard)) {
                    Text(path == .improve ? "I have a time in mind" : "Target finish time")
                        .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                }
                .padding(Theme.Space.md)
                .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .onChange(of: hasGoalTime) { _, on in
                    // Seed only a blank wheel: a time the athlete already set survives a toggle.
                    if on, goalHours == 0, goalMinutes == 0 { seedGoalTime() }
                    syncTarget()
                }
                if hasGoalTime {
                    HStack(spacing: 0) {
                        Picker("Hours", selection: $goalHours) {
                            ForEach(0..<10, id: \.self) { Text("\($0) hr").tag($0) }
                        }
                        .pickerStyle(.wheel)
                        Picker("Minutes", selection: $goalMinutes) {
                            ForEach(0..<60, id: \.self) { Text(String(format: "%02d min", $0)).tag($0) }
                        }
                        .pickerStyle(.wheel)
                    }
                    .frame(height: 110)
                    .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .onChange(of: goalHours) { _, _ in syncTarget() }
                    .onChange(of: goalMinutes) { _, _ in syncTarget() }
                }
            }
        }
    }

    /// The wheels and the calendar write the blueprint; the blueprint is the one source the
    /// preview reads.
    private func syncTarget() {
        switch path {
        case .race:
            blueprint.raceDate = Calendar.current.startOfDay(for: raceDay)
        default:
            blueprint.raceDate = nil
        }
        let seconds = Double(goalHours * 3600 + goalMinutes * 60)
        blueprint.goalFinishTimeS = (path == .race || path == .improve) && hasGoalTime && seconds > 0 ? seconds : nil
    }

    private func seedGoalTime() {
        guard let distanceM = blueprint.raceDistanceM else { return }
        let seconds: Double
        if let p5k = profile.plan?.p5kSPerKm, p5k > 0 {
            seconds = PlanFeasibility.predictedFinishS(distanceM: distanceM, p5kSPerKm: p5k)
        } else {
            seconds = switch RaceDistance.nearest(toMeters: distanceM) {
            case .fiveK: 30 * 60
            case .tenK: 60 * 60
            case .half: 2 * 3_600
            case .marathon: 4 * 3_600
            case .fiftyK: 5.5 * 3_600
            }
        }
        let totalMinutes = min(9 * 60 + 59, max(1, Int((seconds / 60).rounded())))
        goalHours = totalMinutes / 60
        goalMinutes = totalMinutes % 60
    }

    private var feasibility: PlanFeasibility? {
        guard blueprint.isRace, blueprint.raceDate != nil else { return nil }
        var read = blueprint
        read.weeklyRunVolumeM = evidence?.weeklyM ?? blueprint.weeklyRunVolumeM
        return PlanLifecycleService.feasibility(for: read, profile: profile, today: previewStart)
    }

    private func feasibilityCard(_ f: PlanFeasibility) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: f.verdict == .onTrack ? "checkmark.seal.fill"
                  : f.verdict == .tight ? "exclamationmark.triangle.fill" : "hand.raised.fill")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(f.headline).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                Text(f.detail).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !f.options.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(f.options, id: \.self) { opt in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "arrow.turn.down.right").font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Theme.ink).padding(.top, 2)
                                Text(opt).font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Step 3: fitness

    private var fitnessStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            section("RUNNING EXPERIENCE") {
                VStack(spacing: Theme.Space.sm) {
                    experienceCard(.new, "New to running", "Under a year, or a long way from regular running")
                    experienceCard(.some, "Some experience", "Regular running, a race or two")
                    experienceCard(.experienced, "Experienced", "Years of consistent training and racing")
                }
            }
            section("A TYPICAL WEEK RIGHT NOW") {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    if let evidence, evidence.usesLoggedRuns {
                        HStack(spacing: 0) {
                            metric(evidence.weeklyM.map { Formatters.distance(meters: $0, unit: distanceUnit) } ?? "Not set", "PER WEEK")
                            Rectangle().fill(Theme.hairline).frame(width: 1, height: 38)
                            metric(evidence.longestM.map { Formatters.distance(meters: $0, unit: distanceUnit) } ?? "Not set", "LONGEST RUN")
                            if let p5k = profile.plan?.p5kSPerKm, p5k > 0 {
                                Rectangle().fill(Theme.hairline).frame(width: 1, height: 38)
                                metric(PlanFeasibility.hms(p5k * 5), "5K FITNESS")
                            }
                        }
                        .padding(Theme.Space.md)
                        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        Text("From your recent Momentum runs. Update the answers below if your current running has changed.")
                            .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Tell us what you averaged over the last four weeks. These answers set your starting point; future logged runs refine it. Choose Not sure if you do not know.")
                            .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("RUNNING PER WEEK").font(.rounded(10, weight: .bold)).tracking(1.2).foregroundStyle(Theme.inkTertiary)
                        .padding(.top, Theme.Space.xs)
                    distanceChoices(weeklyChoices, current: blueprint.weeklyRunVolumeM) {
                        blueprint.weeklyRunVolumeM = $0
                        if $0 == 0 { blueprint.longestRunM = 0 }
                        blueprint.fitnessDeclaredAt = Date()
                    }.accessibilityIdentifier("builder-weekly-running")
                    Text("LONGEST RECENT RUN").font(.rounded(10, weight: .bold)).tracking(1.2).foregroundStyle(Theme.inkTertiary)
                        .padding(.top, Theme.Space.xs)
                    distanceChoices(longestChoices, current: blueprint.longestRunM) {
                        blueprint.longestRunM = $0
                        if let value = $0, value > 0, blueprint.weeklyRunVolumeM == 0 {
                            blueprint.weeklyRunVolumeM = nil
                        }
                        blueprint.fitnessDeclaredAt = Date()
                    }.accessibilityIdentifier("builder-longest-running")
                }
            }
        }
    }

    private func experienceCard(_ level: ExperienceLevel, _ title: String, _ subtitle: String) -> some View {
        SelectionCard(title: title, subtitle: subtitle, isSelected: blueprint.runningExperience == level) {
            withAnimation(reduceMotion ? nil : Motion.standard) { blueprint.runningExperience = level }
        }
    }

    private var metersPerUnit: Double { distanceUnit == .metric ? 1_000 : 1609.344 }
    private var unitLabel: String { distanceUnit == .metric ? "km" : "mi" }

    private var weeklyChoices: [Double] {
        var values: [Double] = [0, 1, 3, 5, 8, 10, 20, 30, 40, 50, 60, 80].map { $0 * metersPerUnit }
        if let current = blueprint.weeklyRunVolumeM, !values.contains(where: { abs($0 - current) < 1 }) {
            values.append(current); values.sort()
        }
        return values
    }

    private var longestChoices: [Double] {
        var values: [Double] = [0, 1, 2, 3, 5, 8, 10, 13, 16, 20, 25, 30].map { $0 * metersPerUnit }
        if let current = blueprint.longestRunM, !values.contains(where: { abs($0 - current) < 1 }) {
            values.append(current); values.sort()
        }
        return values
    }

    private func distanceChoices(_ values: [Double], current: Double?, set: @escaping (Double?) -> Void) -> some View {
        FlowLayout(spacing: Theme.Space.sm) {
            Button { Haptics.selection(); set(nil) } label: {
                Text("Not sure")
                    .font(.rounded(Theme.FontSize.caption, weight: .bold))
                    .foregroundStyle(current == nil ? Theme.background : Theme.ink)
                    .padding(.horizontal, 14).frame(minHeight: 44)
                    .background {
                        if current == nil { Capsule().fill(Theme.ink) } else { Capsule().stroke(Theme.hairline) }
                    }
            }.buttonStyle(.plain).accessibilityAddTraits(current == nil ? .isSelected : [])
            ForEach(values, id: \.self) { v in
                let on = current.map { abs($0 - v) < 1 } ?? false
                Button { Haptics.selection(); set(v) } label: {
                    Text(v == 0 ? "Not running" : "\(Int((v / metersPerUnit).rounded())) \(unitLabel)")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
                        .foregroundStyle(on ? Theme.background : Theme.ink)
                        .padding(.horizontal, 14).frame(minHeight: 44)
                        .background {
                            if on { Capsule().fill(Theme.ink) } else { Capsule().stroke(Theme.hairline) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.display(17, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.65)
            Text(label).font(.rounded(9, weight: .bold)).tracking(0.8).foregroundStyle(Theme.inkTertiary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func loadEvidence() async {
        let worker = PlanFitnessWorker(modelContainer: context.container)
        guard let snapshot = try? await worker.snapshot(declaredWeeklyM: blueprint.fitnessDeclaredAt != nil ? blueprint.weeklyRunVolumeM : (blueprint.weeklyRunVolumeM ?? profile.weeklyRunVolumeM),
                                                        declaredLongestM: blueprint.fitnessDeclaredAt != nil ? blueprint.longestRunM : (blueprint.longestRunM ?? profile.longestRunM),
                                                        profileCreatedAt: profile.createdAt,
                                                        trainingEvidenceFrom: profile.continuity?.trainingEvidenceFrom,
                                                        declaredAt: blueprint.fitnessDeclaredAt ?? profile.fitnessDeclaredAt),
              !Task.isCancelled else { return }
        evidence = snapshot
        if draft == nil, blueprint.fitnessDeclaredAt == profile.fitnessDeclaredAt {
            blueprint.weeklyRunVolumeM = snapshot.weeklyM
            blueprint.longestRunM = snapshot.longestM
        }
    }

    // MARK: - Step 4: week

    private var recommendedDays: Int {
        PlanFeasibility.recommendedDays(goal: blueprint.goal, raceDistanceM: blueprint.isRace ? blueprint.raceDistanceM : nil,
                                        experience: blueprint.runningExperience, lifting: blueprint.lifts)
    }

    private var weekStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            section("DAYS A WEEK") {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    segmented([2, 3, 4, 5, 6], current: blueprint.daysPerWeek, label: { "\($0)" },
                              spoken: { "\($0) days a week" }) { blueprint.daysPerWeek = $0 }
                    Text(blueprint.daysPerWeek == recommendedDays
                         ? "The coach's pick for this goal."
                         : "The coach's pick for this goal is \(recommendedDays). Your call.")
                        .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                }
            }
            section("WHICH DAYS") {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    weekdayChips
                    Text(tooFewDaysChosen
                         ? "Pick at least \(blueprint.daysPerWeek) days, or leave them all off and the coach spreads the week."
                         : (blueprint.preferredDays.isEmpty
                            ? "Leave them all off and the coach spreads the week. The long run lands on Sunday when it is in."
                            : "The long run lands on Sunday when it is chosen, else Saturday, else the chosen day with the most rest after it. Hard days never sit beside it."))
                        .font(.rounded(Theme.FontSize.label, weight: .medium))
                        .foregroundStyle(tooFewDaysChosen ? Theme.ink : Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            section("TIME PER SESSION") {
                segmented([30, 45, 60, 75, 90], current: blueprint.sessionMinutes, label: { "\($0)m" },
                          spoken: { "\($0) minutes" }) { blueprint.sessionMinutes = $0 }
            }
        }
    }

    private var weekdayChips: some View {
        let symbols = Calendar.current.shortWeekdaySymbols
        let order = [2, 3, 4, 5, 6, 7, 1]
        return HStack(spacing: 6) {
            ForEach(order, id: \.self) { weekday in
                let on = blueprint.preferredDays.contains(weekday)
                Button {
                    Haptics.selection()
                    withAnimation(reduceMotion ? nil : Motion.selection) {
                        if on { blueprint.preferredDays.removeAll { $0 == weekday } }
                        else { blueprint.preferredDays.append(weekday) }
                    }
                } label: {
                    Text(String(symbols[weekday - 1].prefix(2)).uppercased())
                        .font(.rounded(Theme.FontSize.label, weight: .bold))
                        .foregroundStyle(on ? Theme.background : Theme.ink)
                        .frame(maxWidth: .infinity).frame(minHeight: 44)
                        .background {
                            if on { Capsule().fill(Theme.ink) } else { Capsule().stroke(Theme.hairline) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(symbols[weekday - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    // MARK: - Step 5: training

    private var trainingStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            section("HOW HARD TO PUSH") {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    ForEach(PlanIntensity.allCases) { level in
                        SelectionCard(title: level == recommendedIntensity ? "\(level.label)  ·  Recommended" : level.label,
                                      subtitle: level.subtitle, isSelected: blueprint.intensity == level,
                                      iridescent: level == .podium) {
                            blueprint.intensity = level
                            if blueprint.daysPerWeek < level.floorDays {
                                blueprint.daysPerWeek = level.floorDays
                                // Fewer chosen days than the week now holds would be ignored by
                                // the scheduler; clear them here and say so, never silently.
                                if !blueprint.preferredDays.isEmpty, blueprint.preferredDays.count < level.floorDays {
                                    blueprint.preferredDays = []
                                    daysClearedByIntensity = true
                                }
                            }
                        }
                    }
                    if blueprint.intensity == .podium {
                        Text("Podium trains \(PlanIntensity.podium.floorDays) or more days a week, so your week is set to \(blueprint.daysPerWeek).\(daysClearedByIntensity ? " Your chosen days were fewer than that, so the coach picks the days." : "") Every recovery guardrail still applies.")
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note = blueprint.intensity.riskNote {
                        Text(note).font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if blueprint.isRace || path == .improve {
                section("BUILD UP TO") {
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        ceilingChoices
                        Text(blueprint.targetWeeklyRunVolumeM == nil
                             ? "The most you are willing to run in a week. Left to the coach, the plan builds to what the goal needs."
                             : "The plan will not build past this. Every recovery guardrail still applies below it.")
                            .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            section("STRENGTH FOR RUNNERS") {
                VStack(spacing: Theme.Space.sm) {
                    Toggle(isOn: Binding(get: { blueprint.lifts }, set: { on in
                        withAnimation(reduceMotion ? nil : Motion.standard) {
                            blueprint.includesStrength = on
                            if !on, blueprint.goal == .getStronger || blueprint.goal == .buildMuscle { blueprint.goal = .generalFitness }
                        }
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add strength days").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                            Text("Lifts that support the miles, never instead of them.")
                                .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                        }
                    }
                    .padding(Theme.Space.md)
                    .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    if blueprint.lifts {
                        balanceCards
                        equipmentCards
                    }
                }
            }
            section("PLAN NAME · OPTIONAL") {
                TextField(blueprint.displayName, text: $blueprint.name)
                    .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .padding(Theme.Space.md)
                    .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .accessibilityIdentifier("builder-name")
            }
        }
    }

    private var recommendedIntensity: PlanIntensity {
        if let f = feasibility { return f.recommended }
        return blueprint.runningExperience == .new || !profile.injuryHistory.isEmpty ? .gentle : .balanced
    }

    private var ceilingChoices: some View {
        let weekly = Int((((evidence?.weeklyM ?? blueprint.weeklyRunVolumeM) ?? 0) / metersPerUnit / 5).rounded()) * 5
        var values = [0] + stride(from: 5, through: max(40, weekly + 40), by: 5).map { $0 }
        if let t = blueprint.targetWeeklyRunVolumeM {
            let v = Int((t / metersPerUnit).rounded())
            if !values.contains(v) { values.append(v); values.sort() }
        }
        let current = blueprint.targetWeeklyRunVolumeM.map { Int(($0 / metersPerUnit).rounded()) } ?? 0
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Picker("Weekly running ceiling", selection: Binding(get: { current }, set: { v in
                blueprint.targetWeeklyRunVolumeM = v == 0 ? nil : Double(v) * metersPerUnit
            })) {
                ForEach(values, id: \.self) { v in
                    Text(v == 0 ? "Let the coach choose" : "\(v) \(unitLabel) a week").tag(v)
                }
            }.pickerStyle(.menu).accessibilityIdentifier("builder-weekly-ceiling")
        }
    }

    private var balanceCards: some View {
        let opts: [(HybridPriority, String, String, String)] = [
            (.running, "Running comes first", "Lift to support the miles", "figure.run"),
            (.balanced, "Balanced runner", "More strength, with running still leading", "figure.run.circle"),
            (.lifting, "More strength support", "Near-even split; the extra day stays a run", "dumbbell.fill")]
        return VStack(spacing: Theme.Space.sm) {
            ForEach(opts, id: \.0) { o in
                SelectionCard(title: o.1, subtitle: o.2, systemImage: o.3,
                              isSelected: (blueprint.hybridPriority ?? .balanced) == o.0) {
                    withAnimation(reduceMotion ? nil : Motion.standard) { blueprint.hybridPriority = o.0 }
                }
            }
        }
    }

    private var equipmentCards: some View {
        let opts: [(Equipment, String, String)] = [
            (.fullGym, "Full gym", "building.2"), (.dumbbellsOnly, "Dumbbells only", "dumbbell"),
            (.homeMinimal, "Home minimal", "house"), (.bodyweight, "Bodyweight", "figure.cooldown")]
        return VStack(spacing: Theme.Space.sm) {
            ForEach(opts, id: \.0) { o in
                SelectionCard(title: o.1, systemImage: o.2, isSelected: blueprint.equipment == o.0) {
                    blueprint.equipment = o.0
                }
            }
        }
    }

    // MARK: - Step 6: preview

    private var previewStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: 4) {
                Text(blueprint.displayName)
                    .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                Text(blueprint.goalLine())
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                if let preview {
                    let f = Date.FormatStyle().day().month(.abbreviated)
                    let cal = Calendar.current
                    let when = cal.isDateInToday(preview.startDate) ? "Starting today"
                        : cal.isDateInTomorrow(preview.startDate) ? "Starting tomorrow"
                        : "Starting \(preview.startDate.formatted(.dateTime.weekday(.wide)))"
                    Text("\(when): \(preview.startDate.formatted(f)) to \(preview.endDate.formatted(f)) · \(preview.durationLine)")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).monospacedDigit().foregroundStyle(Theme.inkSecondary)
                }
            }
            if previewing && preview == nil {
                HStack(spacing: Theme.Space.sm) {
                    ProgressView().tint(Theme.ink)
                    Text("Building your week")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                }
                .padding(.vertical, Theme.Space.lg)
                .frame(maxWidth: .infinity)
            } else {
                PlanPreviewContent(blueprint: blueprint, preview: preview, distanceUnit: distanceUnit)
                    .opacity(previewing ? 0.6 : 1)
                    .animation(Motion.crossfade, value: previewing)
            }
            if IllnessResponse.state(for: profile) != nil {
                Text("Your recovery check-in still controls when and how you return. This is the underlying training block; starting it does not clear illness restrictions or make missed training due.")
                    .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                    .accessibilityIdentifier("builder-recovery-context")
            } else if profile.activeInjuryArea != nil {
                Text("Your current injury guidance stays active. Starting this plan keeps the affected sessions protected until you complete your return check-in.")
                    .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                    .accessibilityIdentifier("builder-recovery-context")
            }
            Text("Nothing changes until you start it. A draft never starts on its own; a scheduled plan starts on its day.")
                .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("builder-preview")
    }

    /// One generation per settled change: the previous task is cancelled, and a result that comes
    /// back for an older blueprint is dropped on its token. Runs the engine over already-fetched
    /// rows, so the wait is the debounce, not the work.
    private func schedulePreview(delay: Double) {
        previewTask?.cancel()
        previewToken &+= 1
        let token = previewToken
        let snapshot = blueprint
        previewing = true
        previewTask = Task { @MainActor in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, token == previewToken else { return }
            let start = previewStart
            let built = PlanLifecycleService.preview(for: snapshot, profile: profile, startDate: start, in: context)
            guard !Task.isCancelled, token == previewToken else { return }
            PerfMark.end("builder-preview")
            withAnimation(reduceMotion ? nil : Motion.crossfade) {
                preview = built
                previewing = false
            }
        }
    }

    // MARK: - Commit

    private var currentPlanName: String {
        guard let plan = profile.plan else { return "Your current plan" }
        return plan.name.isEmpty ? PlanBlueprint(profile: profile).displayName : plan.name
    }

    /// The day the preview is built for: an upcoming plan's scheduled day while that day is
    /// still ahead, otherwise the day activation would really start (tomorrow from 21:00).
    private var previewStart: Date {
        if let draft, draft.status == .upcoming, let day = draft.scheduledStart,
           PlanLifecycle.canSchedule(day, today: Date()) {
            return day
        }
        return PlanLifecycle.activationStart(now: Date())
    }

    /// Whether Cancel should ask first: a fresh plan past its first choice, or a draft that no
    /// longer matches what was saved.
    private var hasUnsavedEdits: Bool {
        if let draft { return draft.blueprint != blueprint }
        return step != .goal
    }

    private func saveDraft() {
        do {
            if let draft {
                try PlanLifecycleService.update(draft, blueprint: blueprint, preview: settledPreview, in: context)
                if draft.status == .upcoming, let day = draft.scheduledStart {
                    if PlanLifecycle.canSchedule(day, today: Date()) {
                        // Keep its day, and rebuild the cached preview FOR that day: the builder's
                        // own preview was built for it, but the service is the one place that
                        // knows the race-day clamp.
                        try PlanLifecycleService.schedule(draft, start: day, for: profile, in: context)
                    } else {
                        try PlanLifecycleService.moveToDrafts(draft, in: context)
                    }
                }
            } else if let created {
                try PlanLifecycleService.update(created, blueprint: blueprint, preview: settledPreview, in: context)
            } else {
                created = try PlanLifecycleService.saveDraft(blueprint, preview: settledPreview, for: profile, in: context)
            }
            Haptics.success()
            onFinish(.savedDraft)
        } catch PlanLifecycleService.Failure.startAfterRaceDay {
            failure = "The race now falls before the scheduled start. Pick a later race date, or move the start."
        } catch { failure = "The draft could not be saved. Please try again." }
    }

    private func schedule(on day: Date) {
        if let overlap = PlanLifecycle.overlap(current: PlanLifecycleService.currentSpan(for: profile), proposedStart: day) {
            self.overlap = PendingOverlap(overlap: overlap, startDay: day, startsNow: false)
            return
        }
        commitSchedule(on: day)
    }

    private func commitSchedule(on day: Date) {
        do {
            let record: PlanShelfRecord
            if let draft {
                try PlanLifecycleService.update(draft, blueprint: blueprint, preview: settledPreview, in: context)
                record = draft
            } else if let created {
                // A fresh plan whose first schedule attempt failed already has its record: reuse
                // it, never a second draft per retry.
                try PlanLifecycleService.update(created, blueprint: blueprint, preview: settledPreview, in: context)
                record = created
            } else {
                record = try PlanLifecycleService.saveDraft(blueprint, preview: settledPreview, for: profile, in: context)
                created = record
            }
            try PlanLifecycleService.schedule(record, start: day, for: profile, in: context)
            Haptics.success()
            onFinish(.scheduled)
        } catch PlanLifecycleService.Failure.scheduleMustBeInTheFuture {
            failure = "Pick a day after today. To start today, use Start now."
        } catch PlanLifecycleService.Failure.startAfterRaceDay {
            failure = "That day is after the race. Pick an earlier start, or move the race date."
        } catch { failure = "The schedule could not be saved. Please try again." }
    }

    /// Starting a plan is free, like "Start a new plan" on the masthead: the free tier's boundary
    /// is the board's locked future weeks. Overlap is measured from the day activation really
    /// starts (tomorrow from 21:00), so the sheet never names a cut that will not happen.
    private func startNow() {
        let start = PlanLifecycle.activationStart(now: Date())
        if let overlap = PlanLifecycle.overlap(current: PlanLifecycleService.currentSpan(for: profile), proposedStart: start) {
            self.overlap = PendingOverlap(overlap: overlap, startDay: start, startsNow: true)
            return
        }
        activate()
    }

    /// A preview still being built is not persisted (an older blueprint's numbers would be), and
    /// the task is cancelled only once the start has succeeded, so a failed start leaves the page live.
    private var settledPreview: PlanPreview? { previewing ? nil : preview }

    private func activate() {
        do {
            if let draft {
                try PlanLifecycleService.update(draft, blueprint: blueprint, preview: settledPreview, in: context)
            }
            let activation = try PlanLifecycleService.activate(blueprint, from: draft, for: profile, in: context)
            previewTask?.cancel()
            PlanLifecycleService.propagate(activation, profile: profile, workouts: workouts,
                                           notifications: services.notifications, in: context)
            Haptics.success()
            onFinish(.activated)
        } catch PlanLifecycleService.Failure.raceDateInThePast {
            failure = "Race day has passed. Pick a new date first."
        } catch {
            failure = "The plan could not be started. Nothing was changed."
        }
    }

    // MARK: - Building blocks

    /// Equal cells in one row while they fit; wrapped cells at larger type or with more values,
    /// so "120 mi" never clips (the owner's wrap-never-scroll rule).
    private func segmented(_ values: [Int], current: Int, label: @escaping (Int) -> String,
                           spoken: @escaping (Int) -> String, _ set: @escaping (Int) -> Void) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.sm) {
                ForEach(values, id: \.self) { v in
                    segmentCell(v, on: current == v, label: label, spoken: spoken, set: set)
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            FlowLayout(spacing: Theme.Space.sm) {
                ForEach(values, id: \.self) { v in
                    segmentCell(v, on: current == v, label: label, spoken: spoken, set: set)
                }
            }
        }
    }

    private func segmentCell(_ v: Int, on: Bool, label: @escaping (Int) -> String,
                             spoken: @escaping (Int) -> String, set: @escaping (Int) -> Void) -> some View {
        Button { Haptics.selection(); set(v) } label: {
            Text(label(v))
                .font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit()
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity).frame(minHeight: 50)
                .foregroundStyle(on ? Theme.background : Theme.ink)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.card).fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.surface))
                    if !on { RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline) }
                }
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken(v))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            content()
        }
    }
}
