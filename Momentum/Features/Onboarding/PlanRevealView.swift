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
    @State private var bloom = 0.0          // iridescent celebration bloom behind the goal ring
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var weekOne: [PlannedSession] {
        guard let sessions = profile?.plan?.sessions else { return [] }
        let sorted = sessions.sorted { $0.date < $1.date }
        guard let firstDate = sorted.first?.date else { return [] }
        let end = Calendar.current.date(byAdding: .day, value: 7, to: firstDate) ?? firstDate
        return sorted.filter { $0.date < end }
    }

    var body: some View {
        // One scroll for the whole page — the first-week cards flow with everything else rather than
        // scrolling in their own nested region.
        ScrollView {
            VStack(spacing: Theme.Space.lg) {
                hero
                reflectionChips.reveal(0.24)
                firstWorkoutCard.reveal(0.27)
                if let weeks = vm.weeksToRace { raceCountdown(weeks).reveal(0.29) }
                projectionCard.reveal(0.3)
                if vm.includesStrength { anatomySection.reveal(0.33) }
                sessionList
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Space.md)
            .padding(.bottom, Theme.Space.sm)
        }
        .scrollIndicators(.hidden)
        // Pin the CTA so it's visible the moment the page opens; the plan scrolls above it.
        .safeAreaInset(edge: .bottom) {
            OversizedButton(title: "This looks great") { onContinue() }
                .reveal(0.4)
                .padding(.top, Theme.Space.sm)
                .padding(.bottom, Theme.Space.sm)
                .frame(maxWidth: .infinity)
                .background(Theme.background)
        }
        .onAppear(perform: animateIn)
    }

    /// One consistent section label for every block below the hero — left-aligned, same weight/tracking.
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.rounded(Theme.FontSize.label, weight: .bold))
            .tracking(1.4)
            .foregroundStyle(Theme.inkTertiary)
    }

    // MARK: Hero — iridescent goal ring + count-up + headline

    private var hero: some View {
        VStack(spacing: Theme.Space.lg) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: Theme.iridescent, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 150, height: 150)
                    .blur(radius: 30)
                    .opacity(0.35 * bloom)
                    .scaleEffect(0.8 + 0.2 * bloom)
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
                Text(planReadyTitle)
                    .font(.display(30, weight: .black))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                Text(vm.projectedOutcome())
                    .font(.rounded(Theme.FontSize.body, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .reveal(0.18)
        }
    }

    // MARK: Reflections — the inputs the plan was built around (research: reflect each answer back)

    private var reflectionChips: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionLabel("BUILT AROUND YOU")
            ScrollView(.horizontal) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(vm.reflections(), id: \.self) { chip in
                        Text(chip)
                            .font(.rounded(Theme.FontSize.caption, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, Theme.Space.md).padding(.vertical, 8)
                            .background(Capsule().fill(Theme.surface))
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Projection — the self-drawing trajectory (the welcome route, now pointed forward)

    /// Cumulative planned training hours across 12 weeks — derived purely from the user's own
    /// commitment (days × minutes). Real magnitudes, no outcome/medical claim; the curve only renders.
    private var projectionValues: [Double] {
        let weeklyHours = Double(vm.daysPerWeek * vm.sessionMinutes) / 60
        return (1...12).map { weeklyHours * Double($0) }
    }
    private var projectedHours: Int {
        Int((Double(vm.daysPerWeek * vm.sessionMinutes) / 60 * 12).rounded())
    }

    private var projectionCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionLabel("YOUR NEXT 12 WEEKS")
            ProjectionCurve(values: projectionValues,
                            endpointLabel: "~\(projectedHours)h",
                            weeksLabel: "12 weeks")
                .frame(height: 100)
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Your plan is ready, Maya" when we have a first name, else the generic version.
    private var planReadyTitle: String {
        let first = vm.name.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
        return first.map { "Your plan is ready, \($0)" } ?? "Your plan is ready"
    }

    // MARK: First workout — a concrete, completable session (the "do this" moment)

    @ViewBuilder
    private var firstWorkoutCard: some View {
        // Prefer a strength session (its exercises read as a real, doable workout); else the first session.
        if let s = weekOne.first(where: { !$0.strengthTargets.isEmpty }) ?? weekOne.first {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                sectionLabel("YOUR FIRST WORKOUT")
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    HStack(spacing: Theme.Space.sm) {
                        Image(systemName: PlanCoaching.icon(for: s)).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
                            .frame(width: 38, height: 38).background { Circle().fill(Theme.background); Circle().stroke(Theme.hairline) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(PlanCoaching.brief(for: s)).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                            Text(s.date.formatted(.dateTime.weekday(.wide))).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    if !s.strengthTargets.isEmpty {
                        Divider().overlay(Theme.hairline)
                        ForEach(s.strengthTargets.sorted { $0.order < $1.order }, id: \.persistentModelID) { ex in
                            HStack {
                                Text(ex.exercise?.name ?? "Exercise").font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                                Spacer(minLength: Theme.Space.sm)
                                if let w = StrengthSuggest.label(for: ex, profile: profile) {
                                    Text(w).font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.inkTertiary)
                                }
                                Text("\(ex.targetSets) × \(ex.targetRepLow)–\(ex.targetRepHigh)")
                                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).monospacedDigit().foregroundStyle(Theme.inkSecondary)
                            }
                        }
                    }
                }
                .padding(Theme.Space.lg)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Race countdown (dated race goals)

    private func raceCountdown(_ weeks: Int) -> some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "flag.checkered").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44).background(Circle().fill(IridescentMaterial()).opacity(0.32))
            VStack(alignment: .leading, spacing: 1) {
                Text(weeks == 0 ? "Race week" : "\(weeks) week\(weeks == 1 ? "" : "s") to race day")
                    .font(.display(20, weight: .black)).foregroundStyle(Theme.ink).monospacedDigit()
                if let r = vm.raceDistance {
                    Text("\(r.label) · \(vm.raceDate.formatted(.dateTime.weekday(.wide).month().day()))")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(IridescentMaterial()).opacity(0.12)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
    }

    // MARK: Anatomy — where the plan will build you (strength/hybrid)

    private var anatomySection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionLabel("WHERE YOU'LL GROW")
            AnatomyGlowView(activation: vm.targetMuscles(), sex: vm.bodySex)
                .frame(height: 230)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.md)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: First-week cascade

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionLabel("YOUR FIRST WEEK").reveal(0.28)
            VStack(spacing: Theme.Space.sm) {
                ForEach(Array(weekOne.enumerated()), id: \.element.persistentModelID) { index, session in
                    sessionRow(session).reveal(rowDelay(index))
                }
            }
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
            bloom = 1
            return
        }
        withAnimation(.easeOut(duration: 1.1)) { ringProgress = 1 }
        withAnimation(.easeOut(duration: 0.9).delay(0.15)) { bloom = 1 }
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
