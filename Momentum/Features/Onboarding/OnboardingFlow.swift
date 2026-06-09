import SwiftUI
import SwiftData

/// Onboarding → plan reveal (PRD §4.1, §7.1) — the conversion engine. One question per screen,
/// springy transitions, the iridescent "building your plan" beat, then the reveal. Paywall slots
/// in here in Phase 3; for now it flows into permission primers → Today.
struct OnboardingFlow: View {
    var onComplete: () -> Void

    @Environment(\.modelContext) private var context
    @State private var vm = OnboardingViewModel()
    @State private var profile: UserProfile?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: Theme.Space.lg) {
                if isQuestion { progressBar }
                content
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .opacity))
                    .id(vm.step)
            }
            .padding(Theme.Space.lg)
        }
        .animation(Motion.lively, value: vm.step)
    }

    private var isQuestion: Bool {
        (OnboardingViewModel.Step.disciplines.rawValue...OnboardingViewModel.Step.calibration.rawValue)
            .contains(vm.step.rawValue)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline).frame(height: 4)
                Capsule().fill(Theme.ink).frame(width: geo.size.width * vm.progress, height: 4)
            }
        }
        .frame(height: 4)
    }

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
        case .building: BuildingPlanView()
                .task { await buildPlan() }
        case .reveal: PlanRevealView(vm: vm, profile: profile) { vm.advance() }
        case .primers: primersStep
        }
    }

    // MARK: Steps

    private var coldOpen: some View {
        VStack(spacing: Theme.Space.xl) {
            Spacer()
            ZStack {
                IridescentView(intensity: 0.5).frame(width: 160, height: 160).clipShape(Circle()).blur(radius: 4)
                Text("momentum")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.ink)
            }
            Text("keep moving.").font(.system(size: Theme.FontSize.headline)).foregroundStyle(Theme.inkSecondary)
            Spacer()
            OversizedButton(title: "Get started") { vm.advance() }
        }
    }

    private var disciplinesStep: some View {
        questionScaffold("What do you want to do?", subtitle: "Pick all that apply.") {
            VStack(spacing: Theme.Space.sm) {
                ForEach([Discipline.running, .cycling, .walking, .strength], id: \.self) { d in
                    SelectionCard(title: label(d), systemImage: icon(d),
                                  isSelected: vm.disciplines.contains(d)) {
                        if vm.disciplines.contains(d) { vm.disciplines.remove(d) } else { vm.disciplines.insert(d) }
                    }
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
            VStack(spacing: Theme.Space.sm) {
                ForEach(goals, id: \.0) { g in
                    SelectionCard(title: g.1, systemImage: g.2, isSelected: vm.goal == g.0) { vm.goal = g.0 }
                }
            }
        }
    }

    private var experienceStep: some View {
        questionScaffold("How experienced are you?") {
            VStack(spacing: Theme.Space.sm) {
                ForEach([ExperienceLevel.new, .some, .experienced], id: \.self) { e in
                    SelectionCard(title: e == .new ? "New" : e == .some ? "Some experience" : "Experienced",
                                  isSelected: vm.experience == e) { vm.experience = e }
                }
            }
        }
    }

    private var daysStep: some View {
        questionScaffold("How many days a week?") {
            HStack(spacing: Theme.Space.sm) {
                ForEach([2, 3, 4, 5, 6], id: \.self) { n in
                    chip("\(n)\(n == 6 ? "+" : "")", selected: vm.daysPerWeek == n) { vm.daysPerWeek = n }
                }
            }
        }
    }

    private var equipmentStep: some View {
        let opts: [(Equipment, String)] = [(.fullGym, "Full gym"), (.dumbbellsOnly, "Dumbbells only"),
                                           (.homeMinimal, "Home minimal"), (.bodyweight, "Bodyweight")]
        return questionScaffold("What equipment do you have?") {
            VStack(spacing: Theme.Space.sm) {
                ForEach(opts, id: \.0) { o in
                    SelectionCard(title: o.1, isSelected: vm.equipment == o.0) { vm.equipment = o.0 }
                }
            }
        }
    }

    private var sessionStep: some View {
        questionScaffold("How long per session?") {
            HStack(spacing: Theme.Space.sm) {
                ForEach([30, 45, 60, 75], id: \.self) { m in
                    chip("\(m)\(m == 75 ? "+" : "") min", selected: vm.sessionMinutes == m) { vm.sessionMinutes = m }
                }
            }
        }
    }

    private var whyStep: some View {
        let reasons = ["clear head", "health", "look better", "compete", "me-time"]
        return questionScaffold("Why are you doing this?", subtitle: "It sets your coach's tone.") {
            VStack(spacing: Theme.Space.sm) {
                ForEach(reasons, id: \.self) { r in
                    SelectionCard(title: r.capitalized, isSelected: vm.reason == r) { vm.reason = r }
                }
            }
        }
    }

    private var calibrationStep: some View {
        questionScaffold("Calibrate?", subtitle: "Optional — seeds your paces. You can skip.") {
            VStack(spacing: Theme.Space.md) {
                Toggle("Add a recent run", isOn: $vm.addRecentRun).tint(Theme.ink)
                if vm.addRecentRun {
                    HStack {
                        Text("5 km in")
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
            Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(Theme.ink)
            Text("You're all set").font(.system(size: Theme.FontSize.title, weight: .semibold))
            Text("momentum will ask for location, motion, and notifications only when a feature needs them — never up front.")
                .font(.system(size: Theme.FontSize.body)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
            Spacer()
            OversizedButton(title: "Start training") { onComplete() }
        }
    }

    // MARK: Scaffolding

    @ViewBuilder
    private func questionScaffold<C: View>(_ title: String, subtitle: String? = nil,
                                           @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title).font(.system(size: Theme.FontSize.title, weight: .bold)).foregroundStyle(Theme.ink)
                if let subtitle { Text(subtitle).font(.system(size: Theme.FontSize.body)).foregroundStyle(Theme.inkSecondary) }
            }
            content()
            Spacer()
            OversizedButton(title: "Continue", isEnabled: vm.canAdvance) { vm.advance() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { Haptics.selection(); action() } label: {
            Text(text)
                .font(.system(size: Theme.FontSize.body, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 52)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(selected ? Theme.ink : Theme.surface)
                    RoundedRectangle(cornerRadius: Theme.Radius.chip).stroke(Theme.hairline)
                }
                .foregroundStyle(selected ? Theme.background : Theme.ink)
        }
        .buttonStyle(.plain)
    }

    private func label(_ d: Discipline) -> String {
        switch d { case .running: "Run"; case .cycling: "Ride"; case .walking: "Walk"; case .strength: "Lift weights" }
    }
    private func icon(_ d: Discipline) -> String {
        switch d { case .running: "figure.run"; case .cycling: "bicycle"; case .walking: "figure.walk"; case .strength: "dumbbell.fill" }
    }

    private func buildPlan() async {
        if profile == nil { profile = vm.finish(in: context) }
        try? await Task.sleep(for: .seconds(2.5))
        vm.advance()
    }
}
