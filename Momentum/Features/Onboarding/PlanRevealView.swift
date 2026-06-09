import SwiftUI

/// The unified plan reveal (PRD §4.1 step 4, §7.1): the personalized week laid out, a projected
/// outcome, and the goal ring glowing in iridescence. The moment the user is sold.
struct PlanRevealView: View {
    let vm: OnboardingViewModel
    let profile: UserProfile?
    var onContinue: () -> Void

    private var weekOne: [PlannedSession] {
        guard let sessions = profile?.plan?.sessions else { return [] }
        let sorted = sessions.sorted { $0.date < $1.date }
        guard let firstDate = sorted.first?.date else { return [] }
        let end = Calendar.current.date(byAdding: .day, value: 7, to: firstDate) ?? firstDate
        return sorted.filter { $0.date < end }
    }

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            ZStack {
                ProgressRing(progress: 1.0).frame(width: 120, height: 120)
                VStack(spacing: 0) {
                    Text("\(vm.daysPerWeek)").font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("days/wk").font(.system(size: Theme.FontSize.caption)).foregroundStyle(Theme.inkTertiary)
                }
            }
            VStack(spacing: Theme.Space.xs) {
                Text("Your plan is ready").font(.system(size: Theme.FontSize.title, weight: .bold))
                Text(vm.projectedOutcome()).font(.system(size: Theme.FontSize.body)).foregroundStyle(Theme.inkSecondary)
            }

            ScrollView {
                VStack(spacing: Theme.Space.sm) {
                    ForEach(weekOne, id: \.persistentModelID) { session in
                        sessionRow(session)
                    }
                }
            }

            OversizedButton(title: "This looks great") { onContinue() }
        }
        .frame(maxWidth: .infinity)
    }

    private func sessionRow(_ s: PlannedSession) -> some View {
        HStack(spacing: Theme.Space.md) {
            Text(s.date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.system(size: Theme.FontSize.caption, weight: .bold))
                .foregroundStyle(Theme.inkTertiary)
                .frame(width: 40, alignment: .leading)
            Image(systemName: icon(s))
                .foregroundStyle(Theme.ink).frame(width: 24)
            Text(summary(s))
                .font(.system(size: Theme.FontSize.body))
                .foregroundStyle(Theme.ink)
            Spacer()
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(s.date.formatted(.dateTime.weekday(.wide))): \(summary(s))")
    }

    private func icon(_ s: PlannedSession) -> String {
        switch s.discipline {
        case .running: "figure.run"; case .cycling: "bicycle"; case .walking: "figure.walk"; case .strength: "dumbbell.fill"
        }
    }

    private func summary(_ s: PlannedSession) -> String {
        if s.discipline == .strength {
            return "\(s.strengthTargets.first?.exercise == nil ? "Strength" : (planLabel(s))) · \(s.strengthTargets.count) exercises"
        }
        let dist = s.targetDistanceM.map { Formatters.distance(meters: $0, unit: .auto) } ?? ""
        let type = s.runType?.rawValue.capitalized ?? "Session"
        return "\(type) \(dist)"
    }

    private func planLabel(_ s: PlannedSession) -> String {
        // Strength label isn't stored on PlannedSession; infer a friendly name from exercise count.
        s.strengthTargets.count >= 5 ? "Full body" : "Strength"
    }
}
