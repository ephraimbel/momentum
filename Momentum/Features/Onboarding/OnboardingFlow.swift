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
    @State private var vm = OnboardingViewModel()
    @State private var profile: UserProfile?
    @State private var goingBack = false
    @State private var locator = LocationService()   // request location on the final primer
    @State private var brandRevealed = false         // cold open plays the route map, then dissolves to brand
    @State private var touchedSteps: Set<OnboardingViewModel.Step> = []  // first-pick affirmation, once per screen
    @State private var affirmation: String?          // the gentle "got it" micro-reward toast
    @State private var showPaywall = false           // the `onboarding_complete` paywall, after the reveal

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if vm.step == .building {
                // The hero beat renders full-bleed (the map must escape the flow's padding).
                BuildingPlanView(lines: vm.buildingLines())
                    .task { await buildPlan() }
                    .transition(.opacity)
            } else if vm.step == .coldOpen {
                coldOpen.transition(.opacity)   // full-bleed welcome map
            } else if vm.step == .commitment {
                commitmentStep.transition(.opacity)   // full-bleed hold-to-commit beat
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
                .padding(.horizontal, Theme.Space.lg)
                .padding(.top, Theme.Space.sm)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isQuestion { continueBar }
        }
        .overlay(alignment: .bottom) { if isQuestion { affirmationToast } }
        .animation(Motion.travel, value: vm.step)
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

    private var isQuestion: Bool {
        (OnboardingViewModel.Step.disciplines.rawValue...OnboardingViewModel.Step.calibration.rawValue)
            .contains(vm.step.rawValue)
    }

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
        case .coldOpen: EmptyView()   // rendered full-bleed in `body`
        case .disciplines: disciplinesStep
        case .goal: goalStep
        case .experience: experienceStep
        case .days: daysStep
        case .equipment: equipmentStep
        case .session: sessionStep
        case .why: whyStep
        case .calibration: calibrationStep
        case .commitment: EmptyView()   // rendered full-bleed in `body`
        case .building: EmptyView()   // rendered full-bleed in `body`
        case .reveal: PlanRevealView(vm: vm, profile: profile) { showPaywall = true }
        case .primers: primersStep
        }
    }

    // MARK: Cold open

    private var coldOpen: some View {
        ZStack {
            // Phase 1: a real run path draws itself across the map — a cinematic intro. It signals when
            // the draw + arrival lands, so the handoff is synced rather than guessed at on a timer.
            RouteDrawMap(showsStats: true) {
                guard !brandRevealed else { return }
                withAnimation(.easeInOut(duration: 0.75)) { brandRevealed = true }
            }
            .ignoresSafeArea()
            // Rack-focus depth dissolve: the map pushes back + blurs out as the brand rises in.
            .scaleEffect(brandRevealed && !reduceMotion ? 1.08 : 1)
            .blur(radius: brandRevealed && !reduceMotion ? 10 : 0)
            .opacity(brandRevealed ? 0 : 1)

            // Phase 2: the clean brand canvas — orb + wordmark + Start.
            if brandRevealed {
                VStack(spacing: Theme.Space.lg) {
                    Spacer()
                    IridescentOrb(size: 124)
                    VStack(spacing: Theme.Space.sm) {
                        Text("momentum")
                            .font(.display(42, weight: .black))
                            .foregroundStyle(Theme.ink)
                        Text("keep moving.")
                            .font(.rounded(Theme.FontSize.headline, weight: .medium))
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    .reveal(0.12)
                    Spacer()
                    OversizedButton(title: "Get started") { goNext() }
                        .reveal(0.28)
                }
                .padding(.horizontal, Theme.Space.lg)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
    }

    // MARK: Question steps

    private var disciplinesStep: some View {
        questionScaffold("What do you want to do?", subtitle: "Pick all that apply.") {
            ForEach(Array([Discipline.running, .cycling, .walking, .strength].enumerated()), id: \.element) { i, d in
                SelectionCard(title: label(d), systemImage: icon(d),
                              isSelected: vm.disciplines.contains(d)) {
                    pick { if vm.disciplines.contains(d) { vm.disciplines.remove(d) } else { vm.disciplines.insert(d) } }
                }
                .reveal(cascade(i))
            }
        }
    }

    private var goalStep: some View {
        let goals: [(Goal, String, String)] = [
            (.loseFat, "Lose fat / get fit", "flame"), (.buildMuscle, "Build muscle", "figure.strengthtraining.traditional"),
            (.getStronger, "Get stronger", "dumbbell.fill"), (.raceDistance, "Run a distance", "figure.run"),
            (.endurance, "Improve endurance", "wind"), (.stayConsistent, "Stay consistent", "calendar")]
        return questionScaffold("What's your main goal?") {
            ForEach(Array(goals.enumerated()), id: \.element.0) { i, g in
                SelectionCard(title: g.1, systemImage: g.2, isSelected: vm.goal == g.0) { pick { vm.goal = g.0 } }
                    .reveal(cascade(i))
            }
        }
    }

    private var experienceStep: some View {
        questionScaffold("How experienced are you?") {
            ForEach(Array([ExperienceLevel.new, .some, .experienced].enumerated()), id: \.element) { i, e in
                SelectionCard(title: e == .new ? "New to this" : e == .some ? "Some experience" : "Experienced",
                              isSelected: vm.experience == e) { pick { vm.experience = e } }
                    .reveal(cascade(i))
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
        questionScaffold("Calibrate?", subtitle: "Optional — seeds your paces. Skip and we'll learn from your first sessions.") {
            VStack(spacing: Theme.Space.md) {
                Toggle("Add a recent run", isOn: $vm.addRecentRun).tint(Theme.ink)
                if vm.addRecentRun {
                    HStack {
                        Text("5 km in").font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        Spacer()
                        Stepper("\(Int(vm.recentRunSeconds / 60)) min",
                                value: $vm.recentRunSeconds, in: 600...3600, step: 30)
                    }
                    .onAppear { vm.recentRunMeters = 5000 }
                }
            }
            .padding(Theme.Space.md)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
            .reveal(cascade(0))
        }
    }

    // MARK: Commitment (the investment beat — hold the iridescent ring to commit)

    private var commitmentStep: some View {
        VStack(spacing: Theme.Space.xl) {
            Spacer()
            VStack(spacing: Theme.Space.sm) {
                Text("Commit to keep moving")
                    .font(.display(30, weight: .black))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                Text("Press and hold. This is the part that makes it stick.")
                    .font(.rounded(Theme.FontSize.body, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .reveal(0.1)
            HoldToCommitRing(size: 224) {
                // Let the checkmark land, then move on to building the plan.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.55))
                    goNext()
                }
            }
            .reveal(0.26)
            Text("Hold to commit")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
                .reveal(0.36)
            Spacer()
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func label(_ d: Discipline) -> String {
        switch d { case .running: "Run"; case .cycling: "Ride"; case .walking: "Walk"; case .strength: "Lift weights" }
    }
    private func icon(_ d: Discipline) -> String {
        switch d { case .running: "figure.run"; case .cycling: "bicycle"; case .walking: "figure.walk"; case .strength: "dumbbell.fill" }
    }

    private func buildPlan() async {
        if profile == nil { profile = vm.finish(in: context) }
        // Long enough for the route to finish drawing and the head to pulse before the reveal.
        try? await Task.sleep(for: .seconds(3.1))
        goNext()
    }
}
