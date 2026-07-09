import SwiftUI
import SwiftData

/// Onboarding → plan reveal (PRD §4.1, §7.1) — the conversion engine. Cal-AI-grade structure
/// (continuous progress, back chevron, one bold question per screen, tactile cards, a pinned
/// Continue, an anticipation "building" beat, a celebratory reveal) rendered in momentum's
/// monochrome + earned-iridescence identity.
struct OnboardingFlow: View {
    var onComplete: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(Services.self) private var services
    @State private var vm = OnboardingViewModel()
    @State private var profile: UserProfile?
    @State private var goingBack = false
    @State private var locator = LocationService()   // request location on the final primer
    @State private var touchedSteps: Set<OnboardingViewModel.Step> = []  // first-pick affirmation, once per screen
    @State private var affirmation: String?          // the gentle "got it" micro-reward toast
    @State private var showPaywall = false           // the `onboarding_complete` paywall, after the reveal
    @State private var showTimeEntry = false         // calibration: reveal the "recent time" entry
    @State private var healthImport: HealthImportState = .idle   // calibration: the Health baseline card

    enum HealthImportState { case idle, importing, done(BaselineEstimator.RunningBaseline), empty }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if vm.step == .building {
                // The hero beat renders full-bleed (the map must escape the flow's padding). Strength
                // and hybrid plans build over the body lighting up; pure cardio over the route draw.
                BuildingPlanView(lines: vm.buildingLines(),
                                 anatomy: vm.includesStrength ? vm.targetMuscles() : nil,
                                 sex: vm.bodySex)
                    .task { await buildPlan() }
                    .transition(.opacity)
            } else {
                VStack(spacing: Theme.Space.lg) {
                    if isQuestion { header }
                    content
                        // The screen travels in the direction of motion (forward from the right, back
                        // from the left), then each element cascades up — directionality + the
                        // "assemble" entrance reads more premium than a flat crossfade.
                        .transition(stepTransition)
                        .id(vm.step)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, Theme.Space.lg)
                .padding(.top, Theme.Space.sm)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isQuestion { continueBar }
        }
        .overlay(alignment: .bottom) { if isQuestion { affirmationToast } }
        .animation(Motion.travel, value: vm.step)
        .onAppear {
            // No name prefill — onboarding is guest-first now (Sign in with Apple comes later), so the
            // athlete types their own name on a clean field instead of inheriting a placeholder.
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--onboarding-volume") { vm.activities = [.run]; vm.experience = .some; vm.step = .runVolume }
            if args.contains("--onboarding-hybrid") { vm.activities = [.run, .strength]; vm.step = .hybridFocus }
            if args.contains("--onboarding-disciplines") { vm.step = .disciplines }
            if args.contains("--onboarding-notifications") { vm.step = .notifications }
            if args.contains("--onboarding-reveal"), let demo = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first {
                profile = demo
                // --onboarding-reveal-runs hides the anatomy block so the first-week dropdowns sit higher.
                vm.activities = args.contains("--reveal-runs") ? [.run] : [.run, .strength]
                vm.daysPerWeek = demo.daysPerWeek; vm.goal = demo.goal
                vm.name = "Maya"; vm.step = .reveal
            }
            if args.contains("--onboarding-goaltime") {
                vm.activities = [.run]; vm.goal = .raceDistance; vm.raceDistance = .marathon; vm.step = .raceGoalTime
            }
            if args.contains("--onboarding-intensity") {
                vm.activities = [.run]; vm.goal = .raceDistance; vm.raceDistance = .half; vm.hasRace = true
                vm.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 18, to: Date()) ?? Date()
                vm.experience = .some; vm.calibrationMode = .feel; vm.paceFeel = .regular; vm.weeklyRunVolumeM = 35_000
                vm.step = .intensity
            }
            if args.contains("--onboarding-injuries") { vm.activities = [.run]; vm.step = .injuries }
            if args.contains("--onboarding-health") { vm.activities = [.run]; vm.step = .health }
            if args.contains("--onboarding-calibration") {
                vm.activities = [.run]; vm.experience = .some; vm.step = .calibration
                // With the Health demo flag, exercise the import path automatically (sim can't tap).
                if args.contains("--health-baseline-demo") {
                    Task {
                        if let b = await services.health.runningBaseline() {
                            vm.importedBaseline = b
                            withAnimation(Motion.standard) { healthImport = .done(b) }
                        }
                    }
                }
            }
            if args.contains("--onboarding-intensity-short") {
                vm.activities = [.run]; vm.goal = .raceDistance; vm.raceDistance = .marathon; vm.hasRace = true
                vm.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 6, to: Date()) ?? Date()
                vm.experience = .new; vm.weeklyRunVolumeM = 15_000
                vm.step = .intensity
            }
            #endif
        }
        .onChange(of: vm.step) { _, step in services.analytics.log(.onboardingStep(index: step.rawValue)) }
        // The plan reveal sells Pro (PRD §10, `onboarding_complete`). Honest + skippable: closing it
        // continues to the primers and into the app on the free tier.
        .fullScreenCover(isPresented: $showPaywall, onDismiss: { goNext() }) {
            PaywallView(feature: .fullPlan)
        }
    }

    /// A whisper-quiet "got it" toast on the first pick of a screen — the research's positive-
    /// reinforcement beat, kept monochrome and brief so it stays sleek, not chatty.
    @ViewBuilder
    private var affirmationToast: some View {
        if let affirmation {
            Text(affirmation)
                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, 8)
                .background(Capsule().fill(Theme.surface))
                .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
                .transition(.opacity.combined(with: .offset(y: 10)))
                .padding(.bottom, 92)
        }
    }

    private var isQuestion: Bool { vm.isQuestionStep }

    // MARK: Header (back + progress)

    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            Button { goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 28, height: 28)
            }
            GeometryReader { geo in
                let w = max(10, geo.size.width * vm.progress)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    // Earned iridescence on a genuine progress surface — the same accent as the
                    // welcome route, with a glowing leading cap that echoes the comet head.
                    Capsule()
                        .fill(LinearGradient(colors: Theme.iridescent, startPoint: .leading, endPoint: .trailing))
                        .frame(width: w)
                        .shadow(color: Theme.iridescent[3].opacity(0.55), radius: 4)
                        .overlay(alignment: .trailing) {
                            Circle().fill(.white).frame(width: 6, height: 6)
                                .shadow(color: Theme.iridescent[0].opacity(0.9), radius: 5)
                        }
                }
            }
            .frame(height: 6)
        }
        .padding(.top, Theme.Space.xs)
    }

    private var continueBar: some View {
        OversizedButton(title: "Continue", isEnabled: vm.canAdvance) { goNext() }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, Theme.Space.sm)
            .padding(.bottom, Theme.Space.sm)
            .background(Theme.background)
    }

    private func goNext() { goingBack = false; vm.advance() }
    private func goBack() { goingBack = true; vm.back() }

    // MARK: Content router

    @ViewBuilder
    private var content: some View {
        switch vm.step {
        case .name: nameStep
        case .goal: goalStep
        case .disciplines: disciplinesStep
        case .race: raceStep
        case .raceGoalTime: raceGoalTimeStep
        case .muscleFocus: muscleFocusStep
        case .experience: experienceStep
        case .injuries: injuriesStep
        case .runVolume: runVolumeStep
        case .days: daysStep
        case .preferredDays: preferredDaysStep
        case .session: sessionStep
        case .equipment: equipmentStep
        case .hybridFocus: hybridFocusStep
        case .metrics: metricsStep
        case .why: whyStep
        case .calibration: calibrationStep
        case .health: healthStep
        case .intensity: intensityStep
        case .building: EmptyView()   // rendered full-bleed in `body`
        case .reveal: PlanRevealView(vm: vm, profile: profile) { showPaywall = true }
        case .notifications: notificationsStep
        case .primers: primersStep
        }
    }


    // MARK: Question steps

    private var disciplinesStep: some View {
        let programmed = ActivityChoice.allCases.filter(\.isProgrammed)
        let extras = ActivityChoice.allCases.filter { !$0.isProgrammed }
        return questionScaffold("What do you want to do?", subtitle: "Pick all that apply — we'll build your plan around these.") {
            activitySectionLabel("TRAIN")
            ForEach(Array(programmed.enumerated()), id: \.element) { i, a in
                activityCard(a).reveal(cascade(i))
            }
            activitySectionLabel("ALSO TRACK").padding(.top, Theme.Space.xs)
            Text("Logged as cross-training and added to your weeks — your call.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(extras.enumerated()), id: \.element) { i, a in
                activityCard(a).reveal(cascade(programmed.count + i))
            }
        }
    }

    private func activityCard(_ a: ActivityChoice) -> some View {
        SelectionCard(title: a.title, systemImage: a.icon, isSelected: vm.activities.contains(a)) {
            pick { if vm.activities.contains(a) { vm.activities.remove(a) } else { vm.activities.insert(a) } }
        }
    }

    private func activitySectionLabel(_ text: String) -> some View {
        Text(text).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var nameStep: some View {
        questionScaffold("What should we call you?", subtitle: "We'll make the plan feel like it's yours.") {
            TextField("Your name", text: $vm.name)
                .font(.display(24, weight: .bold)).foregroundStyle(Theme.ink)
                .textInputAutocapitalization(.words).autocorrectionDisabled()
                .submitLabel(.done)
                .padding(Theme.Space.md)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                    RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
                }
                .reveal(cascade(0))
        }
    }

    private var goalStep: some View {
        // Running-first ordering (ENDURANCE-FOCUS Phase 0): the racing + endurance goals lead — this is
        // a running app. Strength/body-composition goals remain, as the supporting pillar.
        let goals: [(Goal, String, String)] = [
            (.raceDistance, "Run a race", "flag.checkered"), (.endurance, "Run farther & faster", "wind"),
            (.stayConsistent, "Stay consistent", "calendar"), (.loseFat, "Lose fat / get fit", "flame"),
            (.buildMuscle, "Build muscle", "figure.strengthtraining.traditional"), (.getStronger, "Get stronger", "dumbbell.fill")]
        return questionScaffold("What's your main goal?", subtitle: "This shapes everything that follows.") {
            ForEach(Array(goals.enumerated()), id: \.element.0) { i, g in
                SelectionCard(title: g.1, systemImage: g.2, isSelected: vm.goal == g.0) {
                    pick { vm.goal = g.0 }
                }
                .reveal(cascade(i))
            }
        }
    }

    private var experienceStep: some View {
        questionScaffold("How experienced are you?",
                         subtitle: vm.hybrid ? "We'll set running and lifting separately." : nil) {
            if vm.hybrid {
                expSegment("Running", vm.experience) { vm.experience = $0 }.reveal(cascade(0))
                expSegment("Lifting", vm.liftExperience) { vm.liftExperience = $0 }.reveal(cascade(1))
            } else {
                ForEach(Array([ExperienceLevel.new, .some, .experienced].enumerated()), id: \.element) { i, e in
                    SelectionCard(title: e == .new ? "New to this" : e == .some ? "Some experience" : "Experienced",
                                  isSelected: vm.experience == e) { pick { vm.experience = e } }
                        .reveal(cascade(i))
                }
            }
        }
    }

    /// Current running load — seeds the plan's starting volume so it meets the athlete where they are.
    private var runVolumeStep: some View {
        questionScaffold("How much are you running now?",
                         subtitle: "So your plan starts where you are — challenging, not crushing.") {
            metricRow("Per week", volumeLabel(vm.weeklyRunVolumeM),
                      { setWeekly(volumeDisplay(vm.weeklyRunVolumeM) - 5) },
                      { setWeekly(volumeDisplay(vm.weeklyRunVolumeM) + 5) }).reveal(cascade(0))
            metricRow("Longest run", volumeLabel(vm.longestRunM),
                      { setLongest(volumeDisplay(vm.longestRunM) - 1) },
                      { setLongest(volumeDisplay(vm.longestRunM) + 1) }).reveal(cascade(1))
        }
        .onAppear(perform: seedVolumeDefaultsIfNeeded)
    }

    // Volume is entered in the athlete's locale unit (mi in the US/UK, km elsewhere) but stored in meters.
    private var useMetricDistance: Bool { Locale.current.measurementSystem != .us }
    private var metersPerUnit: Double { useMetricDistance ? 1000 : 1609.344 }
    private var distanceUnitLabel: String { useMetricDistance ? "km" : "mi" }
    private func volumeDisplay(_ meters: Double?) -> Double { (meters ?? 0) / metersPerUnit }
    private func volumeLabel(_ meters: Double?) -> String { "\(Int(volumeDisplay(meters).rounded())) \(distanceUnitLabel)" }
    private func setWeekly(_ d: Double) { Haptics.light(); vm.weeklyRunVolumeM = min(200, max(0, d.rounded())) * metersPerUnit }
    private func setLongest(_ d: Double) { Haptics.light(); vm.longestRunM = min(60, max(1, d.rounded())) * metersPerUnit }
    /// Anchor the steppers on a sensible starting guess by experience (the athlete adjusts from there).
    private func seedVolumeDefaultsIfNeeded() {
        guard vm.weeklyRunVolumeM == nil else { return }
        let (weekly, longest): (Double, Double) = vm.experience == .experienced ? (40_000, 16_000) : (20_000, 8_000)
        vm.weeklyRunVolumeM = weekly
        vm.longestRunM = longest
    }

    /// A compact labelled 3-way experience selector (used per-discipline for hybrids).
    private func expSegment(_ title: String, _ current: ExperienceLevel,
                            _ set: @escaping (ExperienceLevel) -> Void) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2).foregroundStyle(Theme.inkTertiary)
            HStack(spacing: Theme.Space.sm) {
                ForEach([ExperienceLevel.new, .some, .experienced], id: \.self) { e in
                    let on = current == e
                    Button { pick { set(e) } } label: {
                        Text(e == .new ? "New" : e == .some ? "Some" : "Pro")
                            .font(.rounded(Theme.FontSize.body, weight: .bold))
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .foregroundStyle(on ? Theme.background : Theme.ink)
                            .background {
                                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(on ? Theme.ink : Theme.surface)
                                if !on { RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline) }
                            }
                    }
                    .buttonStyle(.plain)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: on)
                }
            }
        }
    }

    private var daysStep: some View {
        let opts: [(Int, String, String)] = [
            (2, "2 days", "Light week"), (3, "3 days", "A steady base"),
            (4, "4 days", "Consistent"), (5, "5 days", "High volume"), (6, "6+ days", "All in")]
        return questionScaffold("How many days a week?", subtitle: "We'll shape your week around this.") {
            ForEach(Array(opts.enumerated()), id: \.element.0) { i, o in
                SelectionCard(title: o.1, subtitle: o.2, isSelected: vm.daysPerWeek == o.0) { pick { vm.daysPerWeek = o.0 } }
                    .reveal(cascade(i))
            }
        }
    }

    private var equipmentStep: some View {
        let opts: [(Equipment, String, String)] = [
            (.fullGym, "Full gym", "building.2"), (.dumbbellsOnly, "Dumbbells only", "dumbbell"),
            (.homeMinimal, "Home minimal", "house"), (.bodyweight, "Bodyweight", "figure.cooldown")]
        return questionScaffold("What equipment do you have?") {
            ForEach(Array(opts.enumerated()), id: \.element.0) { i, o in
                SelectionCard(title: o.1, systemImage: o.2, isSelected: vm.equipment == o.0) { pick { vm.equipment = o.0 } }
                    .reveal(cascade(i))
            }
        }
    }

    private var sessionStep: some View {
        let opts: [(Int, String, String)] = [
            (30, "30 min", "In and out"), (45, "45 min", "A balanced session"),
            (60, "60 min", "A full workout"), (75, "75+ min", "Go long")]
        return questionScaffold("How long per session?") {
            ForEach(Array(opts.enumerated()), id: \.element.0) { i, o in
                SelectionCard(title: o.1, subtitle: o.2, isSelected: vm.sessionMinutes == o.0) { pick { vm.sessionMinutes = o.0 } }
                    .reveal(cascade(i))
            }
        }
    }

    private var whyStep: some View {
        let reasons = ["clear head", "health", "look better", "compete", "me-time"]
        return questionScaffold("Why are you doing this?", subtitle: "It sets your coach's tone.") {
            ForEach(Array(reasons.enumerated()), id: \.element) { i, r in
                SelectionCard(title: r.capitalized, isSelected: vm.reason == r) { pick { vm.reason = r } }
                    .reveal(cascade(i))
            }
        }
    }

    private var calibrationStep: some View {
        questionScaffold("How's your running pace?",
                         subtitle: "So your easy runs feel easy and the hard ones land right. Not sure? Just continue — we'll learn from your first runs.") {
            healthImportCard.reveal(cascade(0))
            ForEach(Array(PaceFeel.allCases.enumerated()), id: \.element) { i, f in
                SelectionCard(title: f.title, subtitle: f.subtitle, systemImage: f.icon,
                              isSelected: vm.calibrationMode == .feel && vm.paceFeel == f) {
                    pick { vm.calibrationMode = .feel; vm.paceFeel = f }
                }
                .reveal(cascade(i + 1))
            }
            timeEntryCard.reveal(cascade(PaceFeel.allCases.count + 1))
        }
    }

    /// "It already understands me" — estimate the baseline from their Apple Health run history
    /// (Watch/Garmin/Oura all sync into Health, so one tap covers every device). Read-only.
    @ViewBuilder
    private var healthImportCard: some View {
        switch healthImport {
        case .done(let b):
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text("Got it — we found your runs").font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                }
                Text("\(b.runCount) runs in 8 weeks · ~\(Formatters.distance(meters: b.weeklyVolumeM, unit: .auto))/week · longest \(Formatters.distance(meters: b.longestRunM, unit: .auto)) · est. 5K \(PlanFeasibility.hms(b.p5kSPerKm * 5))")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your paces and starting volume are set from what you actually run.")
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(IridescentMaterial(), lineWidth: 1.5)   // earned — real history read
            }
        case .empty:
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "heart.text.square").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                Text("Not enough recent runs in Apple Health — pick how your pace feels below.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface))
        case .idle, .importing:
            Button {
                Haptics.light()
                healthImport = .importing
                Task {
                    _ = await services.health.requestAuthorization()
                    if let baseline = await services.health.runningBaseline() {
                        vm.importedBaseline = baseline
                        withAnimation(Motion.standard) { healthImport = .done(baseline) }
                    } else {
                        withAnimation(Motion.standard) { healthImport = .empty }
                    }
                }
            } label: {
                HStack(spacing: Theme.Space.md) {
                    Image(systemName: "heart.text.square.fill")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.purple)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Theme.purple.opacity(0.1)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use my run history").font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                        Text("Apple Health — Watch, Garmin & Oura sync there too. Read-only.")
                            .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if case .importing = healthImport {
                        ProgressView().tint(Theme.inkSecondary)
                    } else {
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                    }
                }
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface)
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).stroke(Theme.hairline)
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// Past injuries — multi-select body areas the plan will train around (ENDURANCE-FOCUS §8.2).
    /// Optional and shame-free; empty = none. Feeds the protective ramp + the injury loop's watch list.
    private var injuriesStep: some View {
        questionScaffold("Anything to train around?",
                         subtitle: "Past injuries shape a safer ramp — we'll build up gently where you've been hurt. Skip if you're all clear.") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.sm), GridItem(.flexible())],
                      spacing: Theme.Space.sm) {
                ForEach(Array(InjuryArea.allCases.enumerated()), id: \.element) { i, area in
                    let on = vm.injuryAreas.contains(area)
                    Button {
                        Haptics.selection()
                        withAnimation(Motion.lively) {
                            if on { vm.injuryAreas.remove(area) } else { vm.injuryAreas.insert(area) }
                        }
                    } label: {
                        Text(area.label)
                            .font(.rounded(Theme.FontSize.body, weight: .semibold))
                            .foregroundStyle(on ? Theme.background : Theme.ink)
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background {
                                Capsule().fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.surface))
                                if !on { Capsule().stroke(Theme.hairline) }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .reveal(cascade(i / 2))
                }
            }
            if !vm.injuryAreas.isEmpty {
                Text("We'll ease the impact around \(vm.injuryAreas.count == 1 ? "this area" : "these areas") and watch for early warning signs.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
    }

    /// The recovery consent beat (ENDURANCE-FOCUS §7) — connect Apple Health so the plan adapts to how
    /// the athlete is *actually* recovering. Benefit-first, names their devices, read-only reassurance.
    private var healthStep: some View {
        VStack(spacing: Theme.Space.lg) {
            Spacer(minLength: 0)
            VStack(spacing: Theme.Space.sm) {
                Text("Train with your whole picture")
                    .font(.serif(30, weight: .semibold)).foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text("Connect Apple Health and momentum learns how you're actually recovering — so each week adapts to you, not a template.")
                    .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .reveal(0.05)
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                healthBenefitRow("bed.double.fill", "Sleep & heart rate", "Rough night? Your week eases off before you overdo it.")
                healthBenefitRow("applewatch", "Your devices, one tap", "Oura, Garmin, Whoop & Apple Watch already sync to Apple Health — no separate logins.")
                healthBenefitRow("lock.fill", "Read-only, always", "It stays on your device, in your control. Disconnect anytime.")
            }
            .padding(Theme.Space.md)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface.opacity(0.6)))
            .reveal(0.15)
            Spacer(minLength: 0)
            VStack(spacing: Theme.Space.sm) {
                OversizedButton(title: "Connect Apple Health") {
                    Task {
                        _ = await services.health.requestAuthorization()
                        goNext()
                    }
                }
                Button { Haptics.light(); goNext() } label: {
                    Text("Maybe later").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                }
                .buttonStyle(.plain)
            }
            .reveal(0.28)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.bottom, Theme.Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func healthBenefitRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.purple)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.purple.opacity(0.1)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                Text(detail).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// How hard to push — led by the honesty banner (what the calendar + current fitness actually
    /// allow), then the three tiers with the recommended one marked. This is our edge over generic
    /// plan apps: we tell the truth before we sell the plan.
    private var intensityStep: some View {
        let f = vm.feasibility
        return questionScaffold("How hard do you want to push?",
                                subtitle: "Same goal — your pace. You can change this anytime.") {
            feasibilityBanner(f).reveal(cascade(0))
            ForEach(Array(PlanIntensity.allCases.enumerated()), id: \.element) { i, tier in
                SelectionCard(title: tier == f.recommended ? "\(tier.label)  ·  Recommended" : tier.label,
                              subtitle: tier.riskNote ?? tier.subtitle,
                              isSelected: vm.intensity == tier) {
                    pick { vm.intensity = tier }
                }
                .reveal(cascade(i + 1))
            }
        }
        .onAppear { if !touchedSteps.contains(.intensity) { vm.intensity = f.recommended } }
    }

    /// The truth about the goal vs. the calendar — the icon carries the verdict; monochrome otherwise.
    @ViewBuilder
    private func feasibilityBanner(_ f: PlanFeasibility) -> some View {
        let icon: String = {
            switch f.verdict {
            case .onTrack: "checkmark.seal.fill"
            case .tight: "exclamationmark.triangle.fill"
            case .tooShort: "hand.raised.fill"
            case .noRace: "infinity"
            }
        }()
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: icon).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
                Text(f.headline).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
            }
            if !f.detail.isEmpty {
                Text(f.detail).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !f.options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(f.options, id: \.self) { opt in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.purple).padding(.top, 2)
                            Text(opt).font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).stroke(Theme.hairline)
        }
    }

    /// The optional precise path — expand to enter a recent time over a distance you know.
    private var timeEntryCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Button { Haptics.light(); withAnimation(Motion.standard) { showTimeEntry.toggle() } } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: vm.calibrationMode == .time ? "checkmark.circle.fill" : "stopwatch")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(vm.calibrationMode == .time ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.inkSecondary))
                    Text(vm.calibrationMode == .time ? "\(vm.benchmark.label) in \(Formatters.duration(s: vm.recentRunSeconds))" : "I know a recent time")
                        .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                    Spacer(minLength: 0)
                    Image(systemName: showTimeEntry ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showTimeEntry {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(RunBenchmark.allCases) { b in
                        let on = vm.benchmark == b
                        Button {
                            Haptics.selection()
                            vm.benchmark = b; vm.recentRunSeconds = b.defaultSeconds; vm.calibrationMode = .time
                        } label: {
                            Text(b.label).font(.rounded(Theme.FontSize.caption, weight: .bold))
                                .frame(maxWidth: .infinity).frame(height: 40)
                                .foregroundStyle(on ? Theme.background : Theme.ink)
                                .background {
                                    Capsule().fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.background))
                                    if !on { Capsule().stroke(Theme.hairline) }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: Theme.Space.md) {
                    Text("Time").font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    Spacer()
                    Button { Haptics.light(); adjustTime(-vm.benchmark.step) } label: { metricStep("minus") }.buttonStyle(.plain)
                    Text(Formatters.duration(s: vm.recentRunSeconds))
                        .font(.display(20, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                        .frame(minWidth: 84).contentTransition(.numericText())
                    Button { Haptics.light(); adjustTime(vm.benchmark.step) } label: { metricStep("plus") }.buttonStyle(.plain)
                }
                .animation(.snappy(duration: 0.2), value: vm.recentRunSeconds)
                Text(paceHint).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(Theme.Space.md)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
    }

    private func adjustTime(_ delta: Double) {
        vm.calibrationMode = .time
        vm.recentRunSeconds = min(vm.benchmark.range.upperBound, max(vm.benchmark.range.lowerBound, vm.recentRunSeconds + delta))
    }

    /// "Easy runs ≈ 6:10 /mi" — the resulting easy pace, so the number feels meaningful.
    private var paceHint: String {
        let p5k = PlanEngine.riegelP5k(distanceM: vm.benchmark.meters, timeS: vm.recentRunSeconds)
        return "Easy runs ≈ \(Formatters.pace(secPerKm: PlanEngine.pace(.easy, p5k: p5k), unit: .auto))"
    }

    // MARK: Race setup (racers) — distance + optional date

    private var raceStep: some View {
        questionScaffold("Which race?", subtitle: "We'll point your long runs and taper at it.") {
            ForEach(Array(RaceDistance.allCases.enumerated()), id: \.element) { i, d in
                SelectionCard(title: d.label, subtitle: raceSubtitle(d), isSelected: vm.raceDistance == d) {
                    pick { vm.raceDistance = d }
                }
                .reveal(cascade(i))
            }
            raceDateCard.reveal(cascade(RaceDistance.allCases.count))
        }
    }

    private func raceSubtitle(_ d: RaceDistance) -> String {
        switch d {
        case .fiveK: "Fast and punchy"; case .tenK: "Speed meets stamina"
        case .half: "The endurance test"; case .marathon: "The big one"
        }
    }

    private var raceDateCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Toggle(isOn: $vm.hasRace) {
                Text("I have a race date").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
            }
            .tint(Theme.ink)
            if vm.hasRace {
                DatePicker("Race day", selection: $vm.raceDate, in: Date()..., displayedComponents: .date)
                    .datePickerStyle(.compact).tint(Theme.ink)
            } else {
                Text("No date is fine — we'll build a rolling block you can race off anytime.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
    }

    // MARK: Muscle focus (build-muscle) — live anatomy

    private struct FocusOption { let title: String; let muscles: [MuscleGroup] }
    private var focusOptions: [FocusOption] {
        [.init(title: "Chest", muscles: [.chest]), .init(title: "Back", muscles: [.back]),
         .init(title: "Shoulders", muscles: [.shoulders]), .init(title: "Arms", muscles: [.biceps, .triceps]),
         .init(title: "Legs", muscles: [.quads, .hamstrings]), .init(title: "Glutes", muscles: [.glutes]),
         .init(title: "Core", muscles: [.core])]
    }

    private var muscleFocusStep: some View {
        questionScaffold("Where do you want to grow?", subtitle: "Pick areas to emphasize — your plan adds volume there.") {
            AnatomyGlowView(activation: vm.targetMuscles(), sex: vm.bodySex, sequential: false)
                .frame(height: 200).frame(maxWidth: .infinity)
                .reveal(cascade(0))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.sm), GridItem(.flexible())],
                      spacing: Theme.Space.sm) {
                ForEach(focusOptions, id: \.title) { opt in
                    let on = !vm.muscleFocus.isDisjoint(with: Set(opt.muscles))
                    Button { pick { toggleFocus(opt) } } label: {
                        Text(opt.title)
                            .font(.rounded(Theme.FontSize.body, weight: .bold))
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .foregroundStyle(on ? Theme.background : Theme.ink)
                            .background {
                                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.surface))
                                if !on { RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline) }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .reveal(cascade(1))
        }
    }

    private func toggleFocus(_ opt: FocusOption) {
        let on = !vm.muscleFocus.isDisjoint(with: Set(opt.muscles))
        if on { opt.muscles.forEach { vm.muscleFocus.remove($0) } }
        else { opt.muscles.forEach { vm.muscleFocus.insert($0) } }
    }

    // MARK: Preferred days (optional)

    private var preferredDaysStep: some View {
        questionScaffold("Any preferred days?",
                         subtitle: "Optional — we'll fit your \(vm.daysPerWeek)-day week to these. Skip to auto-spread.") {
            HStack(spacing: 6) {
                ForEach(1...7, id: \.self) { wd in
                    let on = vm.preferredDays.contains(wd)
                    Button { pick { if on { vm.preferredDays.remove(wd) } else { vm.preferredDays.insert(wd) } } } label: {
                        Text(weekdayLetter(wd))
                            .font(.rounded(Theme.FontSize.body, weight: .bold))
                            .frame(maxWidth: .infinity).frame(height: 56)
                            .foregroundStyle(on ? Theme.background : Theme.ink)
                            .background {
                                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.surface))
                                if !on { RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline) }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .reveal(cascade(0))
        }
    }

    private func weekdayLetter(_ wd: Int) -> String { ["S", "M", "T", "W", "T", "F", "S"][(wd - 1) % 7] }

    // MARK: Body metrics (optional)

    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }
    private var ageDisplay: Int { vm.birthYear.map { currentYear - $0 } ?? 30 }
    // Weight is entered imperial (lb) but stored SI (kg) per the units rule.
    private var weightLb: Double { (vm.bodyMassKg ?? 72.5748) * Formatters.lbPerKg } // default 160 lb

    private var metricsStep: some View {
        questionScaffold("A bit about you", subtitle: "Optional — sharpens your calorie + heart-rate targets. Skip if you'd rather.") {
            sexSelector.reveal(cascade(0))
            metricRow("Age", "\(ageDisplay)", { setAge(ageDisplay - 1) }, { setAge(ageDisplay + 1) }).reveal(cascade(1))
            metricRow("Weight", "\(Int(weightLb.rounded())) lb",
                      { setWeight(lb: weightLb - 5) }, { setWeight(lb: weightLb + 5) }).reveal(cascade(2))
        }
    }

    private func setAge(_ a: Int) { vm.birthYear = currentYear - min(90, max(13, a)) }
    private func setWeight(lb: Double) { vm.bodyMassKg = min(400, max(80, lb.rounded())) * Formatters.kgPerLb }

    private var sexSelector: some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach(BiologicalSex.allCases) { s in
                let on = vm.sex == s
                Button { pick { vm.sex = on ? nil : s } } label: {
                    Text(s.label)
                        .font(.rounded(Theme.FontSize.body, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .foregroundStyle(on ? Theme.background : Theme.ink)
                        .background {
                            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.surface))
                            if !on { RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline) }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func metricRow(_ label: String, _ value: String, _ minus: @escaping () -> Void, _ plus: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.Space.md) {
            Text(label).font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
            Spacer()
            Button { Haptics.light(); minus() } label: { metricStep("minus") }.buttonStyle(.plain)
                .accessibilityLabel("Decrease \(label)")
            Text(value).font(.display(20, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                .frame(minWidth: 76).contentTransition(.numericText())
                .accessibilityLabel("\(label), \(value)")
            Button { Haptics.light(); plus() } label: { metricStep("plus") }.buttonStyle(.plain)
                .accessibilityLabel("Increase \(label)")
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
        .animation(.snappy(duration: 0.2), value: value)
    }

    private func metricStep(_ s: String) -> some View {
        Image(systemName: s).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
            .frame(width: 44, height: 44).background { Circle().fill(Theme.background); Circle().stroke(Theme.hairline) }
    }

    // MARK: Commitment (the investment beat — hold the iridescent ring to commit)

    /// Hybrid athletes: where the week's emphasis sits (biases the run/lift day split) — the question
    /// that makes momentum understand a run-*and*-lift athlete instead of guessing from the goal.
    private var hybridFocusStep: some View {
        let opts: [(HybridPriority, String, String, String)] = [
            (.running, "Running comes first", "Lift to support the miles", "figure.run"),
            (.balanced, "Balanced", "Both matter, side by side", "figure.run.circle"),
            (.lifting, "Lifting comes first", "Run to stay conditioned", "dumbbell.fill")]
        return questionScaffold("Run and lift — where's your focus?",
                                subtitle: "We'll weight your week toward it. Change it anytime.") {
            ForEach(Array(opts.enumerated()), id: \.element.0) { i, o in
                SelectionCard(title: o.1, subtitle: o.2, systemImage: o.3, isSelected: vm.hybridPriority == o.0) {
                    pick { vm.hybridPriority = o.0 }
                }
                .reveal(cascade(i))
            }
        }
    }

    /// Race goal time — the target the athlete is chasing (drives the reveal + the race outlook).
    private var raceGoalTimeStep: some View {
        let raceLabel = vm.raceDistance?.label ?? "race"
        return questionScaffold("Chasing a time?",
                                subtitle: "Optional — your goal for the \(raceLabel). We'll point the plan at it.") {
            metricRow("Hours", "\(vm.goalHours)",
                      { vm.goalHours = max(0, vm.goalHours - 1) }, { vm.goalHours = min(8, vm.goalHours + 1) }).reveal(cascade(0))
            metricRow("Minutes", String(format: "%02d", vm.goalMinutes),
                      { vm.goalMinutes = (vm.goalMinutes + 55) % 60 }, { vm.goalMinutes = (vm.goalMinutes + 5) % 60 }).reveal(cascade(1))
            if let t = vm.goalFinishTimeS, let m = vm.raceDistance?.meters, m > 0 {
                Text("That's about \(Formatters.pace(secPerKm: t / (m / 1000), unit: .auto)) — a strong target.")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading).reveal(cascade(2))
            }
        }
    }

    /// Notification opt-in — a Runna-style beat: an iPhone showing a real momentum workout reminder,
    /// the retention hook, and a single "Turn on reminders" that asks for permission.
    private var notificationsStep: some View {
        VStack(spacing: Theme.Space.lg) {
            Spacer(minLength: 0)
            phoneNotificationMockup.reveal(0.05)
            VStack(spacing: Theme.Space.sm) {
                (Text("You're ") + Text("2× more likely").fontWeight(.bold) + Text(" to finish your plan with reminders"))
                    .font(.serif(27, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("A quiet nudge before each session keeps you on track. No spam — just your plan.")
                    .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .reveal(0.18)
            Spacer(minLength: 0)
            VStack(spacing: Theme.Space.sm) {
                OversizedButton(title: "Turn on reminders") {
                    services.notifications.requestAuthorization()
                    goNext()
                }
                Button { Haptics.light(); goNext() } label: {
                    Text("Maybe later").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                }
                .buttonStyle(.plain)
            }
            .reveal(0.3)
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A tilted iPhone showing a momentum workout-reminder notification on a soft lock screen — reads as
    /// a real device, not a flat card.
    private var phoneNotificationMockup: some View {
        VStack(spacing: 0) {
            // Notification banner (frosted, like a real iOS lock-screen alert).
            HStack(spacing: 10) {
                Image("BrandIcon").resizable().scaledToFit().frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text("MOMENTUM").font(.rounded(10, weight: .bold)).tracking(0.4).foregroundStyle(.secondary)
                        Spacer()
                        Text("now").font(.rounded(10, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Text("Time for today's run").font(.rounded(13, weight: .semibold)).foregroundStyle(.primary)
                    Text("Easy run · 5 km, ~30 min").font(.rounded(12, weight: .regular)).foregroundStyle(.secondary)
                }
            }
            .padding(11)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.top, 44)
            // Faint app-grid placeholders so the screen reads as a home/lock screen.
            VStack(spacing: 14) {
                ForEach(0..<3) { _ in
                    HStack(spacing: 14) {
                        ForEach(0..<4) { _ in
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.white.opacity(0.16)).frame(width: 42, height: 42)
                        }
                    }
                }
            }
            .padding(.top, 22)
            Spacer(minLength: 0)
        }
        .frame(width: 236, height: 340)
        .background(
            LinearGradient(colors: [Color(white: 0.34), Color(white: 0.14)], startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
        .overlay(alignment: .top) {
            Capsule().fill(.black).frame(width: 82, height: 22).padding(.top, 11)   // dynamic island
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 46, style: .continuous).fill(.black))   // bezel
        .shadow(color: .black.opacity(0.22), radius: 26, y: 14)
        .rotationEffect(.degrees(-2.5))
        .accessibilityHidden(true)
    }

    private var primersStep: some View {
        VStack(spacing: Theme.Space.lg) {
            Spacer()
            IridescentOrb(size: 96)
            VStack(spacing: Theme.Space.sm) {
                Text("You're all set")
                    .font(.serif(Theme.FontSize.title, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("We use your location to map your runs and rides. Allow it and your map opens right where you are.")
                    .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .reveal(0.15)
            Spacer()
            OversizedButton(title: "Start training") { onComplete() }
                .reveal(0.3)
        }
        // Ask for location here so the app opens with the map already centered on the athlete.
        .onAppear { locator.requestAuthorization() }
    }

    // MARK: Scaffolding

    @ViewBuilder
    private func questionScaffold<C: View>(_ title: String, subtitle: String? = nil,
                                           @ViewBuilder _ content: () -> C) -> some View {
        // One scroll for the whole question (title + options together) — the reliable pattern that
        // always scrolls when the content overflows (the disciplines picker etc.). The serif title
        // carries the welcome page's editorial voice through the flow; options stay in the clean UI face.
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text(title)
                        .font(.serif(33, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(spacing: Theme.Space.sm) { content() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Theme.Space.md)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Staggered entrance delay for the i-th element on a screen — the assemble cascade.
    private func cascade(_ i: Int) -> Double { 0.08 + Double(i) * 0.06 }

    /// Apply a selection and, on the *first* pick of a screen, flash the affirmation micro-reward.
    private func pick(_ apply: () -> Void) {
        let firstTouch = !touchedSteps.contains(vm.step)
        apply()
        guard firstTouch else { return }
        touchedSteps.insert(vm.step)
        let lines = ["Got it.", "Nice pick.", "That shapes your plan.", "Noted."]
        let line = lines[abs(vm.step.rawValue) % lines.count]
        withAnimation(Motion.standard) { affirmation = line }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            if affirmation == line { withAnimation(Motion.exit) { affirmation = nil } }
        }
    }

    /// Directional travel between steps: forward slides in from the right, back from the left.
    /// Reduce Motion drops the offset to a plain crossfade.
    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let dx: CGFloat = 28
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: goingBack ? -dx : dx)),
            removal: .opacity.combined(with: .offset(x: goingBack ? dx : -dx))
        )
    }

    private func buildPlan() async {
        if profile == nil { profile = vm.finish(in: context) }
        services.analytics.log(.planGenerated(disciplines: profile?.disciplines.count ?? 0))
        // Long enough for the route to finish drawing and the head to pulse before the reveal.
        try? await Task.sleep(for: .seconds(3.1))
        goNext()
    }
}
