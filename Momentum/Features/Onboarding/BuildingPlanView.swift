import SwiftUI

/// The "building your plan…" beat (PRD §4.1 step 3) — momentum's hero onboarding moment, where Cal AI's
/// theatrical "analyzing your answers" loader meets Strava's map: the shared `RouteDrawMap` flies in and
/// an iridescent route draws itself while personalized status lines — each reflecting one of the user's
/// answers — **tick to checkmarks** one at a time under a filling iridescent bar (the micro-reward loop
/// research calls for). Auto-advances after a couple of seconds. Honors Reduce Motion.
struct BuildingPlanView: View {
    /// Personalized status lines (from `OnboardingViewModel.buildingLines()`), completed one at a time.
    var lines: [String] = ["Balancing your week", "Spacing your efforts",
                           "Setting your paces", "Finalizing your plan"]

    /// When set, the hero is the human body lighting up muscle-by-muscle (strength/hybrid plans);
    /// otherwise the iridescent route draws itself (pure cardio).
    var anatomy: [MuscleGroup: Double]? = nil

    @State private var completed = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let lineTick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(lines: [String]? = nil, anatomy: [MuscleGroup: Double]? = nil) {
        if let lines { self.lines = lines }
        self.anatomy = anatomy
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            hero
            caption
        }
        .onReceive(lineTick) { _ in
            guard !reduceMotion, completed < lines.count else { return }
            withAnimation(.easeOut(duration: 0.35)) { completed += 1 }
        }
        .onAppear { if reduceMotion { completed = lines.count } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Building your plan")
    }

    @ViewBuilder
    private var hero: some View {
        if let anatomy {
            ZStack {
                Theme.background.ignoresSafeArea()
                AnatomyGlowView(activation: anatomy, loops: true, step: 0.18)
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.top, 56)
                    .padding(.bottom, 280)   // clear the caption block
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        } else {
            RouteDrawMap().ignoresSafeArea()
        }
    }

    /// Title + a personalization line, the per-answer checklist, and an iridescent progress bar — over
    /// a soft scrim so the dark ink reads on the light map.
    private var caption: some View {
        VStack(spacing: Theme.Space.lg) {
            VStack(spacing: Theme.Space.xs) {
                Text("Building your plan")
                    .font(.display(Theme.FontSize.title, weight: .black))
                    .foregroundStyle(Theme.ink)
                Text("Shaped around your answers, not averages.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
            }

            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                ForEach(lines.indices, id: \.self) { i in checklistRow(i) }
            }
            .frame(maxWidth: 320, alignment: .leading)

            iridescentBar(progress: Double(completed) / Double(max(1, lines.count)))
                .frame(maxWidth: 320)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.bottom, 56)
        .padding(.top, 72)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [.clear, Theme.background.opacity(0.85), Theme.background],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private func checklistRow(_ i: Int) -> some View {
        let done = i < completed
        return HStack(spacing: Theme.Space.sm) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(done ? Theme.ink : Theme.hairline)
                .contentTransition(.symbolEffect(.replace))
            Text(lines[i])
                .font(.rounded(Theme.FontSize.body, weight: .semibold))
                .foregroundStyle(done ? Theme.ink : Theme.inkTertiary)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .opacity(i <= completed ? 1 : 0.45)
        .animation(.easeOut(duration: 0.3), value: completed)
    }

    /// Earned iridescence on a genuine progress surface — matches the onboarding question bar.
    private func iridescentBar(progress: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule()
                    .fill(LinearGradient(colors: Theme.iridescent, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * min(1, progress)))
                    .shadow(color: Theme.iridescent[3].opacity(0.5), radius: 4)
            }
        }
        .frame(height: 5)
    }
}
