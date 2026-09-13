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
///
/// Interview grammar (2026-09-12): this is the SAME product as the onboarding interview, so it is
/// assembled from the same kit — one bold question per screen with a subtitle
/// (`OnboardingHeading`), the artwork that answers the question (`OnboardingScene`, driven here by
/// the blueprint), `ChoiceCard` picks, the continuous progress line with its lavender cap, a
/// floating glass back chevron, a pinned `OnboardingCTA` that turns ink the moment the step is
/// answerable, a per-element entrance cascade, directional step travel, and a build beat that hands
/// over to a reveal-shaped last page. Nothing about the lifecycle changed: the debounced real
/// generator still owns the preview, and drafts/schedules/starts commit exactly as before.
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
    @Environment(\.dynamicTypeSize) private var typeSize
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
        /// The chapter word over the progress line, the interview's own orientation cue.
        var chapter: String {
            switch self {
            case .goal: "THE PLAN"
            case .target: "THE TARGET"
            case .fitness: "WHERE YOU ARE"
            case .week: "YOUR WEEK"
            case .training: "HOW TO TRAIN"
            case .preview: "YOUR PLAN"
            }
        }
    }

    @State private var step: Step = .goal
    /// Which way the page travels: forward from the right, back from the left.
    @State private var goingBack = false
    @State private var path: Path?
    @State private var blueprint: PlanBlueprint
    @State private var hasGoalTime: Bool
    @State private var goalHours: Int
    @State private var goalMinutes: Int
    @State private var raceDay: Date
    @State private var showRacePicker = false
    @State private var showGoalTime = false
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
    /// The build beat's ring and its one checked line, paced by `schedulePreview` — the same
    /// shape the interview's building beat has, so the wait reads as the plan being written.
    @State private var buildRing = 0.0
    @State private var buildCompleted = 0
    /// The preview page's seal, bounced once after the page lands.
    @State private var sealed = false
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
        VStack(spacing: 0) {
            masthead
            stepPage
                .id(step)
                .transition(stepTransition)
        }
        // One implicit scope for the step change, the way the interview travels. The footer is a
        // safe-area inset applied BELOW this modifier, so its swap never animates layout.
        .animation(reduceMotion ? Motion.crossfade : OnboardingStyle.pageTransition, value: step)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) { footer }
        .sheet(isPresented: $showRacePicker) {
            RacePickerSheet { race, pickedDistance, date in
                blueprint.name = race.name
                blueprint.raceDistanceM = pickedDistance.meters
                raceDay = date
                if hasGoalTime { seedGoalTime() }
                syncTarget()
            }
        }
        .sheet(isPresented: $showGoalTime) { goalTimeSheet }
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
            // --plan-builder-step <0…5>: open the race door on a given step, for screenshots.
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "--plan-builder-step"), i + 1 < args.count,
               let raw = Int(args[i + 1]), let target = Step(rawValue: raw), draft == nil {
                choose(.race)
                blueprint.name = "Berlin Marathon"
                blueprint.raceDistanceM = RaceDistance.marathon.meters
                raceDay = Calendar.current.date(byAdding: .weekOfYear, value: 16, to: Date()) ?? Date()
                syncTarget()
                step = target
            }
            #endif
        }
        // A beat after the step transition, so the generator never runs under the animation.
        .onChange(of: step) { _, new in
            if new == .preview { PerfMark.start("builder-preview"); schedulePreview(delay: 0.3) }
        }
        .onChange(of: blueprint) { _, _ in if step == .preview { schedulePreview(delay: 0.35) } }
        .onDisappear { previewTask?.cancel() }
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

    // MARK: - Masthead (back · title · leave) + progress

    private var masthead: some View {
        VStack(spacing: Theme.Space.sm) {
            ZStack {
                Text(draft == nil ? "new plan" : "edit plan")
                    .font(.display(20, weight: .bold)).foregroundStyle(Theme.ink)
                    .accessibilityLabel(draft == nil ? "New plan" : "Edit plan")
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: Theme.Space.xs) {
                    GlassCircleButton(systemName: "chevron.left", label: "Back") { back() }
                        .opacity(step == .goal ? 0 : 1)
                        .disabled(step == .goal)
                        .accessibilityHidden(step == .goal)
                    Spacer(minLength: 0)
                    // Labelled "Cancel": the word for leaving a plan that has not been written.
                    Button { leave() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Theme.surface))
                            // The disc reads at 36; the target stays at the 44pt floor.
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel")
                }
            }
            HStack(spacing: Theme.Space.sm) {
                Text(step.chapter)
                    .font(.rounded(10, weight: .semibold)).tracking(1.4)
                    .foregroundStyle(Theme.purple)
                    .contentTransition(.opacity)
                    .animation(Motion.crossfade, value: step)
                Spacer(minLength: 0)
            }
            progressLine
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.md)
        .padding(.bottom, Theme.Space.xs)
    }

    /// One continuous line with a lavender cap, the interview's progress language. Lavender because
    /// progress is "happening now", which is the only thing the brand colour ever means.
    private var progressLine: some View {
        let fraction = Double(step.rawValue + 1) / Double(Step.allCases.count)
        return Capsule().fill(Theme.hairline)
            .overlay(alignment: .leading) {
                Capsule().fill(Theme.purple)
                    .scaleEffect(x: fraction, y: 1, anchor: .leading)
                    .animation(reduceMotion ? nil : OnboardingStyle.progress, value: fraction)
            }
            .frame(height: 3)
            .overlay {
                GeometryReader { geometry in
                    Circle().fill(Theme.purple)
                        .overlay(Circle().strokeBorder(Theme.background, lineWidth: 1.5))
                        .frame(width: 9, height: 9)
                        .offset(x: max(0, min(geometry.size.width - 7,
                                              geometry.size.width * fraction - 3.5)), y: -2)
                        .animation(reduceMotion ? nil : OnboardingStyle.progress, value: fraction)
                }
                .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    private func leave() {
        // Nothing chosen yet, or a draft opened and left as it was: just leave. Anything else is
        // an edit worth a word before it is thrown away.
        if hasUnsavedEdits { confirmingDiscard = true }
        else { previewTask?.cancel(); onFinish(.cancelled) }
    }

    // MARK: - The page

    /// The interview's scaffold: the artwork that answers the question, the question, the controls.
    @ViewBuilder
    private var stepPage: some View {
        if step == .preview, previewing, preview == nil {
            buildBeat
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let scene = sceneStep, sceneLeadsThePage { artwork(scene) }
                    if step != .preview {
                        OnboardingHeading(title: question, subtitle: questionSubtitle)
                            .padding(.top, 8)
                            .padding(.horizontal, Theme.Space.xs)
                            .onboardingEntrance(0.02, lift: 10)
                    }
                    if let scene = sceneStep, !sceneLeadsThePage { artwork(scene) }
                    VStack(alignment: .leading, spacing: 10) { stepContent }
                        // Room for the floating cards' drop shadows — the scroll view clips otherwise.
                        .padding(.horizontal, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.lg)
                .padding(.bottom, Theme.Space.md)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
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

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let dx: CGFloat = 20
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: goingBack ? -dx : dx)),
            removal: .opacity.combined(with: .offset(x: goingBack ? dx : -dx)))
    }

    /// Each element arrives after the one above it. Clamped so a long step never stalls its last row.
    private func cascade(_ index: Int) -> Double { 0.04 + Double(min(index, 4)) * 0.03 }

    // MARK: - The artwork (the interview's own, driven by the blueprint)

    /// Where a builder step asks an onboarding question, it carries that question's illustration:
    /// the lap around the track for the goal, the race bib for the target, the baseline cards for
    /// current running, the week calendar for availability. `OnboardingScene` reads an
    /// `OnboardingViewModel`, so the blueprint is projected onto a throwaway one: the scene only
    /// ever reads it, and every value below is an answer the athlete gave here.
    private var sceneModel: OnboardingViewModel {
        let vm = OnboardingViewModel()
        vm.name = profile.displayName
        // Until a door is picked the track is unrun: the blueprint opens on the athlete's standing
        // profile goal, which is not an answer to THIS question and must not be drawn as one.
        vm.goal = path == nil ? .generalFitness : blueprint.goal
        vm.raceDistance = blueprint.raceDistanceM.map(RaceDistance.nearest(toMeters:))
        vm.hasRace = path == .race
        vm.raceDate = blueprint.raceDate ?? raceDay
        let named = blueprint.name.trimmingCharacters(in: .whitespacesAndNewlines)
        vm.plannedRaceName = named.isEmpty ? nil : named
        vm.weeklyRunVolumeM = blueprint.weeklyRunVolumeM
        vm.longestRunM = blueprint.longestRunM
        vm.daysPerWeek = blueprint.daysPerWeek
        vm.preferredDays = Set(blueprint.preferredDays)
        vm.equipment = blueprint.equipment
        vm.hybridPriority = blueprint.hybridPriority ?? .balanced
        vm.intensity = blueprint.intensity
        vm.experience = blueprint.runningExperience
        vm.distanceUnitChoice = distanceUnit.rawValue
        return vm
    }

    /// The onboarding step whose artwork answers THIS question. The steps onboarding leaves bare
    /// (its own starting-point and approach beats, where the cards are the illustration) stay bare
    /// here too.
    private var sceneStep: OnboardingViewModel.Step? {
        switch step {
        case .goal: .goal
        case .target:
            switch path {
            case .race, .improve: .race
            case .general: .goal
            case .start, .none: nil
            }
        case .fitness: .runVolume
        // The week and the approach draw nothing, exactly as in the interview: there the calendar
        // IS the control, so an illustration of it would be a second, dead copy of the answer.
        case .week, .training, .preview: nil
        }
    }

    /// The bib hangs ABOVE the question, the way it does in the interview; everything else sits
    /// under it.
    private var sceneLeadsThePage: Bool { sceneStep == .race }

    private func artwork(_ scene: OnboardingViewModel.Step) -> some View {
        OnboardingScene(vm: sceneModel, step: scene)
            .frame(height: typeSize.isAccessibilitySize ? 100 : (scene == .race ? 148 : 136))
            // A fresh scene per answer on the goal step, so the lap runs again from the start line.
            .id(step == .goal || step == .target ? "\(scene)-\(path?.rawValue ?? "none")" : "\(scene)")
    }

    // MARK: - The question

    private var question: String {
        switch step {
        case .goal: "What is this plan for?"
        case .target:
            switch path {
            case .race: "What's your next finish line?"
            case .improve: "Which distance are you chasing?"
            case .start: "Where are you starting from?"
            case .general, .none: "What shape should it take?"
            }
        case .fitness: "Where is your running right now?"
        case .week: "Let's shape your training week."
        case .training: "How hard should this push?"
        case .preview: "Your plan"
        }
    }

    private var questionSubtitle: String? {
        switch step {
        case .goal: "Each door builds a different plan. Strength for runners can be added to any of them."
        case .target:
            switch path {
            case .race: "Choose the race and the day. A target time is optional."
            case .improve: "Long runs and quality work are shaped for it, and every block ends with a checkpoint."
            case .start: "Easy running first. Nothing to prove."
            case .general, .none: "Rolling blocks either way. Point them at a race whenever you like."
            }
        case .fitness: "This sets your starting point. The runs you log from here refine it."
        case .week: "The coach has a pick for this goal. Change it only if your week needs something different."
        case .training: "Your answers set the starting point. The coach owns the progression."
        case .preview: nil
        }
    }

    // MARK: - Footer (the pinned CTA)

    private var footer: some View {
        VStack(spacing: Theme.Space.xs) {
            if step == .preview {
                OnboardingCTA(title: "Start now", isEnabled: preview != nil) { startNow() }
                    .accessibilityIdentifier("builder-start")
                HStack(spacing: Theme.Space.sm) {
                    quietAction("Schedule", identifier: "builder-schedule") { scheduling = true }
                    quietAction(draft == nil ? "Save as draft" : (draft?.status == .upcoming ? "Save changes" : "Save draft"),
                                identifier: "builder-draft") { saveDraft() }
                }
            } else {
                OnboardingCTA(title: step == .training ? "See the plan" : "Continue", isEnabled: canAdvance) { advance() }
                    .accessibilityIdentifier("builder-continue")
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.sm)
        .padding(.bottom, Theme.Space.sm)
        // A soft rise into the page so scrolled content dissolves under the button, never an edge.
        .background(
            LinearGradient(colors: [Theme.background.opacity(0), Theme.background, Theme.background],
                           startPoint: .top, endPoint: .bottom)
                .padding(.top, -Theme.Space.lg)
                .ignoresSafeArea())
    }

    /// The two real alternatives to starting now. Quieter than the CTA, still unmistakably buttons.
    private func quietAction(_ title: String, identifier: String, _ action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Text(title)
                .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).frame(minHeight: 46)
                .raised(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(RaisedPressStyle(scale: 0.98))
        .accessibilityIdentifier(identifier)
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
        goingBack = false
        step = next
    }

    private func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        goingBack = true
        step = previous
    }

    // MARK: - Step 1: goal

    private var goalStep: some View {
        ForEach(Array(Path.allCases.enumerated()), id: \.element) { index, door in
            ChoiceCard(title: door.title, subtitle: door.subtitle, systemImage: door.systemImage,
                       isSelected: path == door) {
                choose(door)
            }
            .accessibilityIdentifier("builder-path-\(door.rawValue)")
            .onboardingEntrance(cascade(index))
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
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            raceSearchRow.onboardingEntrance(cascade(0))
            section("RACE DISTANCE") { distanceChips }
                .onboardingEntrance(cascade(1))
            raceDayCard.onboardingEntrance(cascade(2))
            targetTimeRow.onboardingEntrance(cascade(3))
            if let f = feasibility { feasibilityCard(f).onboardingEntrance(cascade(4)) }
        }
    }

    private var raceSearchRow: some View {
        Button { Haptics.light(); showRacePicker = true } label: {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text(blueprint.name.isEmpty ? "Find your race" : blueprint.name)
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                    Text(blueprint.name.isEmpty
                         ? "Boston, Chicago, Hong Kong. The big ones, with dates."
                         : "Locked in. Distance and day are set below.")
                        .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkTertiary)
            }
            .padding(Theme.Space.md)
            .onboardingCard()
        }
        .buttonStyle(RaisedPressStyle(scale: 0.99))
    }

    private var raceDayCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            DatePicker(selection: $raceDay, in: Date()..., displayedComponents: .date) {
                Text("Race day").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
            }
            .datePickerStyle(.compact)
            .onChange(of: raceDay) { _, _ in syncTarget() }
            if raceDayIsValid {
                Text("The block builds, peaks and tapers to this day.")
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            } else {
                Text("Pick a day after today.")
                    .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.ink)
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCard()
    }

    private var improveTarget: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            section("THE DISTANCE") { distanceChips }
                .onboardingEntrance(cascade(0))
            targetTimeRow.onboardingEntrance(cascade(1))
        }
    }

    private var startTarget: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ChoiceCard(title: "New to running", subtitle: "Three easy days a week. Time on feet before anything else.",
                       systemImage: "figure.walk", isSelected: blueprint.runningExperience == .new) {
                blueprint.runningExperience = .new
                blueprint.daysPerWeek = min(blueprint.daysPerWeek, 3)
            }
            .onboardingEntrance(cascade(0))
            ChoiceCard(title: "Coming back", subtitle: "You have run before. A gentle ramp back to a regular week.",
                       systemImage: "arrow.uturn.backward", isSelected: blueprint.runningExperience != .new) {
                blueprint.runningExperience = .some
            }
            .onboardingEntrance(cascade(1))
            Text("If you are returning from an injury, the plan trains around it and never rushes the way back. Anything that persists or worries you is a question for a professional.")
                .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .onboardingEntrance(cascade(2))
        }
    }

    private var generalTarget: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ChoiceCard(title: Goal.generalFitness.planLabel, subtitle: Goal.generalFitness.planSubtitle,
                       systemImage: Goal.generalFitness.planSystemImage, isSelected: blueprint.goal == .generalFitness) {
                blueprint.goal = .generalFitness
            }
            .onboardingEntrance(cascade(0))
            ChoiceCard(title: Goal.endurance.planLabel, subtitle: Goal.endurance.planSubtitle,
                       systemImage: Goal.endurance.planSystemImage, isSelected: blueprint.goal == .endurance) {
                blueprint.goal = .endurance
            }
            .onboardingEntrance(cascade(1))
        }
    }

    /// The five distances as one compact row, wrapping rather than clipping at large type (the
    /// app is vertical only, so nothing here ever scrolls sideways).
    private var distanceChips: some View {
        let values = RaceDistance.allCases
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                ForEach(values) { distanceChip($0).fixedSize(horizontal: true, vertical: false) }
            }
            FlowLayout(spacing: 6) {
                ForEach(values) { distanceChip($0).fixedSize(horizontal: true, vertical: false) }
            }
        }
    }

    private func distanceChip(_ distance: RaceDistance) -> some View {
        let on = blueprint.raceDistanceM == distance.meters
        return Button {
            Haptics.selection()
            blueprint.raceDistanceM = distance.meters
            if hasGoalTime { seedGoalTime() }
            syncTarget()
        } label: {
            Text(shortLabel(distance))
                .font(.rounded(13, weight: .semibold))
                .foregroundStyle(on ? Theme.background : Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity).frame(minHeight: 46)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.surface))
                    if !on { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline) }
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(RaisedPressStyle(scale: 0.98))
        .accessibilityLabel(distance.label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("builder-distance-\(distance.rawValue)")
    }

    private func shortLabel(_ distance: RaceDistance) -> String {
        switch distance {
        case .fiveK: "5K"
        case .tenK: "10K"
        case .half: "Half"
        case .marathon: "Marathon"
        case .fiftyK: "50K"
        }
    }

    /// Optional precision lives in its own panel, the way the interview keeps a target time out of
    /// the question's way.
    private var targetTimeRow: some View {
        detailRow(path == .improve ? "A time to chase" : "Target finish time",
                  value: hasGoalTime && (goalHours > 0 || goalMinutes > 0)
                      ? PlanFeasibility.hms(Double(goalHours * 3600 + goalMinutes * 60))
                      : "Optional",
                  systemImage: "timer") { showGoalTime = true }
    }

    private func detailRow(_ title: String, value: String, systemImage: String,
                           action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage).font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary).frame(width: 28)
                Text(title).font(.rounded(15, weight: .medium)).foregroundStyle(Theme.ink)
                Spacer(minLength: 4)
                Text(value).font(.rounded(12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .padding(.horizontal, 16).frame(minHeight: 52)
            .onboardingCard()
        }
        .buttonStyle(RaisedPressStyle(scale: 0.99))
    }

    /// The target-time panel. Its own sheet rather than the onboarding one, which is pinned to the
    /// light interview; in the app this has to follow the athlete's appearance setting.
    private var goalTimeSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    OnboardingHeading(title: "Your target time",
                                      subtitle: "We assess it against your starting point and say so honestly.",
                                      size: 26)
                    Toggle(isOn: $hasGoalTime) {
                        Text(path == .improve ? "I have a time in mind" : "Set a target finish time")
                            .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                    }
                    .padding(Theme.Space.md)
                    .onboardingCard()
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
                        .frame(height: 130)
                        .onboardingCard()
                        .onChange(of: goalHours) { _, _ in syncTarget() }
                        .onChange(of: goalMinutes) { _, _ in syncTarget() }
                    } else {
                        Text("No target is fine. The plan still builds to the distance.")
                            .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    }
                }
                .padding(Theme.Space.lg)
            }
            .background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showGoalTime = false }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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
        .onboardingCard()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Step 3: fitness

    private var fitnessStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            section("RUNNING EXPERIENCE") {
                VStack(spacing: Theme.Space.sm) {
                    experienceCard(.new, "New to running", "Under a year, or a long way from regular running")
                    experienceCard(.some, "Some experience", "Regular running, a race or two")
                    experienceCard(.experienced, "Experienced", "Years of consistent training and racing")
                }
            }
            .onboardingEntrance(cascade(0))
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
                        .onboardingCard()
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
            .onboardingEntrance(cascade(1))
        }
    }

    private func experienceCard(_ level: ExperienceLevel, _ title: String, _ subtitle: String) -> some View {
        ChoiceCard(title: title, subtitle: subtitle, isSelected: blueprint.runningExperience == level) {
            blueprint.runningExperience = level
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
                        if current == nil { Capsule().fill(Theme.ink) } else { Capsule().strokeBorder(Theme.hairline) }
                    }
                    .contentShape(Capsule())
            }.buttonStyle(.plain).accessibilityAddTraits(current == nil ? .isSelected : [])
            ForEach(values, id: \.self) { v in
                let on = current.map { abs($0 - v) < 1 } ?? false
                Button { Haptics.selection(); set(v) } label: {
                    Text(v == 0 ? "Not running" : "\(Int((v / metersPerUnit).rounded())) \(unitLabel)")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
                        .foregroundStyle(on ? Theme.background : Theme.ink)
                        .padding(.horizontal, 14).frame(minHeight: 44)
                        .background {
                            if on { Capsule().fill(Theme.ink) } else { Capsule().strokeBorder(Theme.hairline) }
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

    /// The interview's week question: the count as the hero figure that reacts to the tap, the
    /// calendar that IS the preference control, and the session length under them.
    private var weekStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(blueprint.daysPerWeek)")
                        .font(.display(42, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.ink)
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                        // The count rolls AND lifts: the number is the answer, so the number reacts.
                        .onboardingAcknowledge(trigger: blueprint.daysPerWeek, scale: 1.1)
                    Text("training days / week").font(.rounded(14)).foregroundStyle(Theme.inkSecondary)
                    Spacer(minLength: 0)
                }
                segmented([2, 3, 4, 5, 6], current: blueprint.daysPerWeek, label: { "\($0)" },
                          spoken: { "\($0) training days" }) { blueprint.daysPerWeek = $0 }
                Text(blueprint.daysPerWeek == recommendedDays
                     ? "The coach's pick for this goal."
                     : "The coach's pick for this goal is \(recommendedDays). Your call.")
                    .font(.rounded(13)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Text("PREFERRED DAYS · OPTIONAL")
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
                // The same negative inset the interview gives it, so the seven days hold one row
                // inside the card before the picker's own ViewThatFits breaks them in two.
                OnboardingWeekPicker(selectedDays: preferredDaysBinding) {}
                    .padding(.horizontal, -12)
                Text(tooFewDaysChosen
                     ? "Pick at least \(blueprint.daysPerWeek) days, or leave them all off and the coach spreads the week."
                     : (blueprint.preferredDays.isEmpty
                        ? "Leave them all off and the coach spreads the week. The long run lands on Sunday when it is in."
                        : "The long run lands on Sunday when it is chosen, else Saturday, else the chosen day with the most rest after it. Hard days never sit beside it."))
                    .font(.rounded(13, weight: tooFewDaysChosen ? .semibold : .regular))
                    .foregroundStyle(tooFewDaysChosen ? Theme.ink : Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.hairline) }
            .onboardingEntrance(cascade(0), lift: 8)
            section("TIME PER SESSION") {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    segmented([30, 45, 60, 75, 90], current: blueprint.sessionMinutes, label: { "\($0)m" },
                              spoken: { "\($0) minutes" }) { blueprint.sessionMinutes = $0 }
                    Text("Your usual sessions. Long runs are planned around your goal and your current fitness.")
                        .font(.rounded(13)).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onboardingEntrance(cascade(1))
        }
    }

    /// The interview's week picker keeps a `Set`; the blueprint stores a sorted array.
    private var preferredDaysBinding: Binding<Set<Int>> {
        Binding(get: { Set(blueprint.preferredDays) },
                set: { blueprint.preferredDays = $0.sorted() })
    }

    // MARK: - Step 5: training

    private var trainingStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                ForEach(Array(PlanIntensity.allCases.enumerated()), id: \.element) { index, level in
                    ChoiceCard(title: level == recommendedIntensity ? "\(level.label)  ·  Recommended" : level.label,
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
                    .onboardingEntrance(cascade(index))
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
                .onboardingEntrance(cascade(4))
            }
            section("STRENGTH FOR RUNNERS") {
                VStack(spacing: Theme.Space.sm) {
                    Toggle(isOn: Binding(get: { blueprint.lifts }, set: { on in
                        blueprint.includesStrength = on
                        if !on, blueprint.goal == .getStronger || blueprint.goal == .buildMuscle { blueprint.goal = .generalFitness }
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add strength days").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                            Text("Lifts that support the miles, never instead of them.")
                                .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                        }
                    }
                    .padding(Theme.Space.md)
                    .onboardingCard()
                    if blueprint.lifts {
                        balanceCards
                        equipmentCards
                    }
                }
            }
            .onboardingEntrance(cascade(4))
            section("PLAN NAME · OPTIONAL") {
                TextField(blueprint.displayName, text: $blueprint.name)
                    .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .padding(Theme.Space.md)
                    .onboardingCard()
                    .accessibilityIdentifier("builder-name")
            }
            .onboardingEntrance(cascade(4))
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
            }
            .pickerStyle(.menu)
            .padding(.horizontal, Theme.Space.md).frame(minHeight: 52)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onboardingCard()
            .accessibilityIdentifier("builder-weekly-ceiling")
        }
    }

    private var balanceCards: some View {
        let opts: [(HybridPriority, String, String, String)] = [
            (.running, "Running comes first", "Lift to support the miles", "figure.run"),
            (.balanced, "Balanced runner", "More strength, with running still leading", "figure.run.circle"),
            (.lifting, "More strength support", "Near-even split; the extra day stays a run", "dumbbell.fill")]
        return VStack(spacing: Theme.Space.sm) {
            ForEach(opts, id: \.0) { o in
                ChoiceCard(title: o.1, subtitle: o.2, systemImage: o.3,
                           isSelected: (blueprint.hybridPriority ?? .balanced) == o.0) {
                    blueprint.hybridPriority = o.0
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
                ChoiceCard(title: o.1, systemImage: o.2, isSelected: blueprint.equipment == o.0) {
                    blueprint.equipment = o.0
                }
            }
        }
    }

    // MARK: - Step 6: the build beat, then the plan

    /// The wait, as the interview draws it: the ring filling behind the brand mark and one line
    /// that checks off when the generator has handed back a real week. Composed here rather than
    /// reusing the interview's own beat, which paints its full-bleed white canvas over the sheet.
    private var buildBeat: some View {
        VStack(spacing: 0) {
            ZStack {
                ProgressRing(progress: buildRing, lineWidth: 7, isStatic: reduceMotion)
                BrandMark(size: 46)
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            }
            .frame(width: 100, height: 100)
            .background {
                RadialGradient(colors: [Theme.iridescent[0].opacity(0.42), Theme.iridescent[1].opacity(0.12), .clear],
                               center: .center, startRadius: 8, endRadius: 110)
                    .frame(width: 220, height: 220)
            }
            .padding(.bottom, Theme.Space.xl)
            VStack(spacing: Theme.Space.xs) {
                Text("Building your plan")
                    .font(.display(30, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("Shaped around your answers, not averages.")
                    .font(.rounded(17)).foregroundStyle(Theme.inkSecondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xl)
            HStack(spacing: Theme.Space.sm) {
                ZStack {
                    if buildCompleted > 0 {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white, Theme.purple)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.4)))
                    } else if !reduceMotion {
                        ProgressView().controlSize(.small).tint(Theme.inkTertiary)
                    } else {
                        Image(systemName: "circle").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.hairline)
                    }
                }
                .frame(width: 20, height: 20)
                Text("Writing your week")
                    .font(.rounded(Theme.FontSize.body, weight: .semibold))
                    .foregroundStyle(buildCompleted > 0 ? Theme.ink : Theme.inkSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
            .frame(maxWidth: 320, alignment: .leading)
            .raised(RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous))
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.62), value: buildCompleted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Building your plan")
    }

    /// The last page reads like the plan reveal rather than a form's last field: the seal, the
    /// plan's name in the display face, the commitment in the same cards the shelf's review sheet
    /// draws, and the one line that says nothing has happened yet. Monochrome: the reveal earns
    /// its one accent in the seal, and the plan is not an achievement until it is run.
    private var previewStep: some View {
        VStack(spacing: Theme.Space.lg) {
            PlanPreviewHero(title: blueprint.displayName, goalLine: blueprint.goalLine(),
                            datesLine: startingLine, ceremonial: true, sealed: sealed)
                .padding(.top, Theme.Space.sm)
                .onboardingEntrance(cascade(0), lift: 10)
            PlanPreviewContent(blueprint: blueprint, preview: preview, distanceUnit: distanceUnit)
                .opacity(previewing ? 0.6 : 1)
                .animation(Motion.crossfade, value: previewing)
                .onboardingEntrance(cascade(1))
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .onboardingEntrance(cascade(2))
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("builder-preview")
        .task {
            // After the page's own cascade has landed; a no-op under Reduce Motion.
            do { try await Task.sleep(for: .seconds(0.55)) } catch { return }
            sealed = true
        }
    }

    /// When the plan would begin, in the words the athlete uses.
    private var startingLine: String? {
        guard let preview else { return nil }
        let f = Date.FormatStyle().day().month(.abbreviated)
        let cal = Calendar.current
        let when = cal.isDateInToday(preview.startDate) ? "Starting today"
            : cal.isDateInTomorrow(preview.startDate) ? "Starting tomorrow"
            : "Starting \(preview.startDate.formatted(.dateTime.weekday(.wide)))"
        return "\(when): \(preview.startDate.formatted(f)) to \(preview.endDate.formatted(f)) · \(preview.durationLine)"
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
        // The beat opens on an empty ring that fills while the generator works; the line checks
        // off only when a real week has come back.
        buildCompleted = 0
        buildRing = 0
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 1.1)) { buildRing = 0.88 }
        previewTask = Task { @MainActor in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, token == previewToken else { return }
            let start = previewStart
            let built = PlanLifecycleService.preview(for: snapshot, profile: profile, startDate: start, in: context)
            guard !Task.isCancelled, token == previewToken else { return }
            PerfMark.end("builder-preview")
            withAnimation(reduceMotion ? nil : Motion.crossfade) {
                buildRing = 1
                buildCompleted = 1
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
    /// so "120 mi" never clips (the owner's wrap-never-scroll rule). Cells stay at the 44pt floor:
    /// the interview's own segmented capsule is chrome-sized, and these are the answer.
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
                    if !on { RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline) }
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
