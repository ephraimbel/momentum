import SwiftUI

/// The unified plan reveal (PRD §4.1 step 4, §7.1) — the moment the user is sold. The goal ring
/// fills in iridescence (the earned accent), the days-per-week tally counts up, and the first week
/// cascades into place one session at a time. Restrained, premium, celebratory.
struct PlanRevealView: View {
    let vm: OnboardingViewModel
    let profile: UserProfile?
    var onContinue: () -> Void

    @State private var ringProgress = 0.0
    @State private var shownDays = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var weekOne: [PlannedSession] {
        guard let sessions = profile?.plan?.sessions else { return [] }
        let sorted = sessions.sorted { $0.date < $1.date }
        guard let firstDate = sorted.first?.date else { return [] }
        let end = Calendar.current.date(byAdding: .day, value: 7, to: firstDate) ?? firstDate
        return sorted.filter { $0.date < end }
    }

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            hero
            sessionList
            OversizedButton(title: "This looks great") { onContinue() }
                .reveal(rowDelay(weekOne.count) + 0.05)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.md)
        .onAppear(perform: animateIn)
    }

    // MARK: Hero — iridescent goal ring + count-up + headline

    private var hero: some View {
        VStack(spacing: Theme.Space.lg) {
            ZStack {
                ProgressRing(progress: ringProgress).frame(width: 132, height: 132)
                VStack(spacing: -2) {
                    AnimatedCounter(value: shownDays) { "\(Int($0.rounded()))" }
                        .font(.display(46, weight: .black))
                        .foregroundStyle(Theme.ink)
                    Text("DAYS / WEEK")
                        .font(.rounded(Theme.FontSize.label, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(Theme.inkTertiary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(vm.daysPerWeek) days per week")
            }
            VStack(spacing: Theme.Space.xs) {
                Text("Your plan is ready")
                    .font(.display(30, weight: .black))
                    .foregroundStyle(Theme.ink)
                Text(vm.projectedOutcome())
                    .font(.rounded(Theme.FontSize.body, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .reveal(0.18)
        }
    }

    // MARK: First-week cascade

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("YOUR FIRST WEEK")
                .font(.rounded(Theme.FontSize.label, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(Theme.inkTertiary)
                .reveal(0.28)
            ScrollView {
                VStack(spacing: Theme.Space.sm) {
                    ForEach(Array(weekOne.enumerated()), id: \.element.persistentModelID) { index, session in
                        sessionRow(session).reveal(rowDelay(index))
                    }
                }
                .padding(.bottom, Theme.Space.xs)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowDelay(_ index: Int) -> Double { 0.36 + Double(index) * 0.07 }

    private func sessionRow(_ s: PlannedSession) -> some View {
        HStack(spacing: Theme.Space.md) {
            Text(s.date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.rounded(Theme.FontSize.caption, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.inkTertiary)
                .frame(width: 38, alignment: .leading)
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Theme.background)
                Image(systemName: icon(s))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(primary(s))
                    .font(.rounded(Theme.FontSize.body, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text(detail(s))
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(s.date.formatted(.dateTime.weekday(.wide))): \(primary(s)), \(detail(s))")
    }

    // MARK: Reveal orchestration

    private func animateIn() {
        guard !reduceMotion else {
            ringProgress = 1
            shownDays = Double(vm.daysPerWeek)
            return
        }
        withAnimation(.easeOut(duration: 1.1)) { ringProgress = 1 }
        withAnimation(.easeOut(duration: 1.0).delay(0.1)) { shownDays = Double(vm.daysPerWeek) }
        Haptics.celebration()   // the earned, sold moment
    }

    // MARK: Copy

    private func icon(_ s: PlannedSession) -> String {
        switch s.discipline {
        case .running: "figure.run"; case .cycling: "bicycle"; case .walking: "figure.walk"; case .strength: "dumbbell.fill"
        }
    }

    private func primary(_ s: PlannedSession) -> String {
        if s.discipline == .strength {
            return s.strengthTargets.count >= 5 ? "Full body" : "Strength"
        }
        return s.runType?.rawValue.capitalized ?? "Session"
    }

    private func detail(_ s: PlannedSession) -> String {
        if s.discipline == .strength {
            let n = s.strengthTargets.count
            return "\(n) exercise\(n == 1 ? "" : "s")"
        }
        if let dist = s.targetDistanceM {
            return Formatters.distance(meters: dist, unit: .auto)
        }
        return s.discipline.rawValue.capitalized
    }
}
