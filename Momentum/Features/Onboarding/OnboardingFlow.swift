import SwiftUI
import SwiftData

/// Onboarding → plan reveal (PRD §4.1, §7.1) — the conversion engine. Cal-AI-grade structure
/// (continuous progress, back chevron, one bold question per screen, tactile cards, a pinned
/// Continue, an anticipation "building" beat, a celebratory reveal) rendered in momentum's
/// monochrome + earned-iridescence identity.
struct OnboardingFlow: View {
    var onComplete: () -> Void

    @Environment(\.modelContext) private var context
    @State private var vm = OnboardingViewModel()
    @State private var profile: UserProfile?
    @State private var goingBack = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: Theme.Space.lg) {
                if isQuestion { header }
                content
                    .transition(.asymmetric(
                        insertion: .move(edge: goingBack ? .leading : .trailing).combined(with: .opacity),
                        removal: .move(edge: goingBack ? .trailing : .leading).combined(with: .opacity)))
                    .id(vm.step)
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, Theme.Space.sm)
        }
        .safeAreaInset(edge: .bottom) {
            if isQuestion { continueBar }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: vm.step)
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
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    Capsule().fill(Theme.ink)
                        .frame(width: max(8, geo.size.width * vm.progress))
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
        case .coldOpen: coldOpen
        case .disciplines: disciplinesStep
        case .goal: goalStep
        case .experience: experienceStep
        case .days: daysStep
        case .equipment: equipmentStep
        case .session: sessionStep
        case .why: whyStep
        case .calibration: calibrationStep
        case .building: BuildingPlanView().task { await buildPlan() }
        case .reveal: PlanRevealView(vm: vm, profile: profile) { goNext() }
        case .primers: primersStep
        }
    }

    // MARK: Cold open

    private var coldOpen: some View {
        VStack(spacing: Theme.Space.lg) {
            Spacer()
            IridescentOrb(size: 128)
            VStack(spacing: Theme.Space.sm) {
                Text("momentum")
                    .font(.display(42, weight: .black))
                    .foregroundStyle(Theme.ink)
                Text("keep moving.")
                    .font(.rounded(Theme.FontSize.headline, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .reveal(0.15)
            Spacer()
            OversizedButton(title: "Get started") { goNext() }
                .reveal(0.3)
        }
    }

    // MARK: Question steps

    private var disciplinesStep: some View {
        questionScaffold("What do you want to do?", subtitle: "Pick all that apply.") {
            ForEach([Discipline.running, .cycling, .walking, .strength], id: \.self) { d in
                SelectionCard(title: label(d), systemImage: icon(d),
                              isSelected: vm.disciplines.contains(d)) {
                    if vm.disciplines.contains(d) { vm.disciplines.remove(d) } else { vm.disciplines.insert(d) }
                }
            }
        }
    }

    private var goalStep: some View {
        let goals: [(Goal, String, String)] = [
            (.loseFat, "Lose fat / get fit", "flame"), (.buildMuscle, "Build muscle", "figure.strengthtraining.traditional"),
            (.getStronger, "Get stronger", "dumbbell.fill"), (.raceDistance, "Run a distance", "figure.run"),
            (.endurance, "Improve endurance", "wind"), (.stayConsistent, "Stay consistent", "calendar")]
        return questionScaffold("What's your main goal?") {
            ForEach(goals, id: \.0) { g in
                SelectionCard(title: g.1, systemImage: g.2, isSelected: vm.goal == g.0) { vm.goal = g.0 }
            }
        }
    }

    private var experienceStep: some View {
        questionScaffold("How experienced are you?") {
            ForEach([ExperienceLevel.new, .some, .experienced], id: \.self) { e in
                SelectionCard(title: e == .new ? "New to this" : e == .some ? "Some experience" : "Experienced",
                              isSelected: vm.experience == e) { vm.experience = e }
            }
        }
    }

    private var daysStep: some View {
        questionScaffold("How many days a week?", subtitle: "We'll shape your week around this.") {
            chipRow([2, 3, 4, 5, 6], selected: vm.daysPerWeek, suffix: { $0 == 6 ? "+" : "" }) { vm.daysPerWeek = $0 }
        }
    }

    private var equipmentStep: some View {
        let opts: [(Equipment, String, String)] = [
            (.fullGym, "Full gym", "building.2"), (.dumbbellsOnly, "Dumbbells only", "dumbbell"),
            (.homeMinimal, "Home minimal", "house"), (.bodyweight, "Bodyweight", "figure.cooldown")]
        return questionScaffold("What equipment do you have?") {
            ForEach(opts, id: \.0) { o in
                SelectionCard(title: o.1, systemImage: o.2, isSelected: vm.equipment == o.0) { vm.equipment = o.0 }
            }
        }
    }

    private var sessionStep: some View {
        questionScaffold("How long per session?") {
            chipRow([30, 45, 60, 75], selected: vm.sessionMinutes, suffix: { $0 == 75 ? "+ min" : " min" }) { vm.sessionMinutes = $0 }
        }
    }

    private var whyStep: some View {
        let reasons = ["clear head", "health", "look better", "compete", "me-time"]
        return questionScaffold("Why are you doing this?", subtitle: "It sets your coach's tone.") {
            ForEach(reasons, id: \.self) { r in
                SelectionCard(title: r.capitalized, isSelected: vm.reason == r) { vm.reason = r }
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
        }
    }

    private var primersStep: some View {
        VStack(spacing: Theme.Space.lg) {
            Spacer()
            IridescentOrb(size: 96)
            VStack(spacing: Theme.Space.sm) {
                Text("You're all set")
                    .font(.display(Theme.FontSize.title, weight: .black)).foregroundStyle(Theme.ink)
                Text("momentum asks for location, motion, and notifications only when a feature needs them — never up front.")
                    .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .reveal(0.15)
            Spacer()
            OversizedButton(title: "Start training") { onComplete() }
                .reveal(0.3)
        }
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

    private func chipRow(_ values: [Int], selected: Int, suffix: @escaping (Int) -> String,
                         action: @escaping (Int) -> Void) -> some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach(values, id: \.self) { v in
                Button { Haptics.selection(); action(v) } label: {
                    Text("\(v)\(suffix(v))")
                        .font(.rounded(Theme.FontSize.headline, weight: .bold))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity).frame(height: 64)
                        .background {
                            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(selected == v ? Theme.ink : Theme.surface)
                            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
                        }
                        .foregroundStyle(selected == v ? Theme.background : Theme.ink)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func label(_ d: Discipline) -> String {
        switch d { case .running: "Run"; case .cycling: "Ride"; case .walking: "Walk"; case .strength: "Lift weights" }
    }
    private func icon(_ d: Discipline) -> String {
        switch d { case .running: "figure.run"; case .cycling: "bicycle"; case .walking: "figure.walk"; case .strength: "dumbbell.fill" }
    }

    private func buildPlan() async {
        if profile == nil { profile = vm.finish(in: context) }
        try? await Task.sleep(for: .seconds(2.6))
        goNext()
    }
}
