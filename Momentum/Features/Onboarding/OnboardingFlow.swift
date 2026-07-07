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
            if args.contains("--onboarding-goaltime") {
                vm.activities = [.run]; vm.goal = .raceDistance; vm.raceDistance = .marathon; vm.step = .raceGoalTime
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
        case .runVolume: runVolumeStep
        case .days: daysStep
        case .preferredDays: preferredDaysStep
        case .session: sessionStep
        case .equipment: equipmentStep
        case .hybridFocus: hybridFocusStep
        case .metrics: metricsStep
        case .why: whyStep
        case .calibration: calibrationStep
        case .building: EmptyView()   // rendered full-bleed in `body`
        case .reveal: PlanRevealView(vm: vm, profile: profile) { showPaywall = true }
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
        let goals: [(Goal, String, String)] = [
            (.loseFat, "Lose fat / get fit", "flame"), (.buildMuscle, "Build muscle", "figure.strengthtraining.traditional"),
            (.getStronger, "Get stronger", "dumbbell.fill"), (.raceDistance, "Run a race", "flag.checkered"),
            (.endurance, "Improve endurance", "wind"), (.stayConsistent, "Stay consistent", "calendar")]
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
            ForEach(Array(PaceFeel.allCases.enumerated()), id: \.element) { i, f in
                SelectionCard(title: f.title, subtitle: f.subtitle, systemImage: f.icon,
                              isSelected: vm.calibrationMode == .feel && vm.paceFeel == f) {
                    pick { vm.calibrationMode = .feel; vm.paceFeel = f }
                }
                .reveal(cascade(i))
            }
            timeEntryCard.reveal(cascade(PaceFeel.allCases.count))
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

    private var primersStep: some View {
        VStack(spacing: Theme.Space.lg) {
            Spacer()
            IridescentOrb(size: 96)
            VStack(spacing: Theme.Space.sm) {
                Text("You're all set")
                    .font(.display(Theme.FontSize.title, weight: .black)).foregroundStyle(Theme.ink)
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
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text(title)
                    .font(.display(32, weight: .black))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                }
            }
            ScrollView {
                VStack(spacing: Theme.Space.sm) { content() }
                    .padding(.bottom, Theme.Space.md)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)   // only rubber-bands when there's actually overflow
        }
        // Fill the available height so the ScrollView above is height-bounded and can actually scroll
        // on tall steps (e.g. the disciplines picker) instead of overflowing off-screen.
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
