import SwiftUI

/// The unified plan reveal (PRD §4.1 step 4, §7.1) — the moment the user is sold. Centered brand
/// wordmark, an iridescent goal ring that fills (the earned accent), a real weekly-volume shape for the
/// block ahead, and the first week as tappable cards that expand to the actual work (every lift, every
/// run's mileage + pace). Restrained, premium, celebratory.
struct PlanRevealView: View {
    let vm: OnboardingViewModel
    let profile: UserProfile?
    var onContinue: () -> Void

    @State private var shownWeeks = 0.0
    @State private var shownDays = 0.0
    @State private var shownSessions = 0.0
    @State private var bloom = 0.0          // soft iridescent celebration bloom behind the headline
    @State private var barsIn = false       // weekly-volume bars grow up on appear
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Number of distinct weeks the plan spans (for the "weeks" stat + the chart header).
    private var planWeekCount: Int {
        guard let sessions = profile?.plan?.sessions, !sessions.isEmpty else { return 0 }
        let cal = Calendar.current
        let start = cal.startOfDay(for: sessions.map(\.date).min() ?? Date())
        let maxW = sessions.map { max(0, (cal.dateComponents([.day], from: start, to: cal.startOfDay(for: $0.date)).day ?? 0) / 7) }.max() ?? 0
        return maxW + 1
    }
    private var totalSessions: Int { profile?.plan?.sessions.count ?? 0 }

    private var distanceUnit: DistanceUnit { DistanceUnit(rawValue: profile?.distanceUnit ?? "auto") ?? .auto }

    private var weekOne: [PlannedSession] {
        guard let sessions = profile?.plan?.sessions else { return [] }
        let sorted = sessions.sorted { $0.date < $1.date }
        guard let firstDate = sorted.first?.date else { return [] }
        let end = Calendar.current.date(byAdding: .day, value: 7, to: firstDate) ?? firstDate
        return sorted.filter { $0.date < end }
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: Theme.Space.lg) {
                brandmark
                hero
                reflectionChips.reveal(0.24)
                if let weeks = vm.weeksToRace { raceCountdown(weeks).reveal(0.27) }
                weeklyVolumeCard.reveal(0.30)
                // Running-first (ENDURANCE-FOCUS §13): runners get the road ahead — a route drawing
                // itself under the purple "you" puck. The anatomy body stays only for lift-only plans.
                if vm.running {
                    routeSection.reveal(0.33).id("road")
                } else if vm.includesStrength {
                    anatomySection.reveal(0.33)
                }
                firstWeekList
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Space.md)
            .padding(.bottom, Theme.Space.sm)
        }
        .scrollIndicators(.hidden)
        .onAppear {
            #if DEBUG
            // Deterministic sim verification of the road-ahead beat (simctl can't scroll).
            if ProcessInfo.processInfo.arguments.contains("--reveal-scroll-road") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    withAnimation { proxy.scrollTo("road", anchor: .center) }
                }
            }
            #endif
        }
        }
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

    /// One consistent section label for every block below the hero.
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.rounded(Theme.FontSize.label, weight: .bold))
            .tracking(1.4)
            .foregroundStyle(Theme.inkTertiary)
    }

    // MARK: Brand

    private var brandmark: some View {
        Image("WordmarkBlack")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(height: 22)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("momentum")
            .reveal(0.02)
    }

    // MARK: Hero — iridescent goal ring + count-up + headline

    private var hero: some View {
        VStack(spacing: Theme.Space.lg) {
            // Editorial headline over a soft iridescent bloom — the earned brand accent, kept restrained.
            ZStack {
                Ellipse()
                    .fill(LinearGradient(colors: Theme.iridescent, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 300, height: 170)
                    .blur(radius: 60)
                    .opacity(0.20 * bloom)
                    .scaleEffect(0.9 + 0.1 * bloom)
                VStack(spacing: Theme.Space.sm) {
                    Text(planReadyTitle)
                        .font(.serif(33, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(vm.projectedOutcome())
                        .font(.rounded(Theme.FontSize.body, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Theme.Space.md)
            }
            .padding(.top, Theme.Space.sm)
            statStrip.reveal(0.16)
        }
    }

    /// The plan's shape as clean data — weeks, frequency, total sessions — with a count-up. Replaces the
    /// arbitrary days/week dial; reads as a real plan summary, not a gauge.
    private var statStrip: some View {
        HStack(spacing: 0) {
            statCell(shownWeeks, "WEEKS")
            statDivider
            statCell(shownDays, "DAYS / WK")
            statDivider
            statCell(shownSessions, "SESSIONS")
        }
        .padding(.vertical, Theme.Space.md)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(planWeekCount) weeks, \(vm.daysPerWeek) days per week, \(totalSessions) sessions")
    }

    private func statCell(_ value: Double, _ label: String) -> some View {
        VStack(spacing: 2) {
            AnimatedCounter(value: value) { "\(Int($0.rounded()))" }
                .font(.display(30, weight: .black)).foregroundStyle(Theme.ink)
            Text(label).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.1).foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1, height: 34)
    }

    /// "Your plan is ready, Maya" when we have a first name, else the generic version.
    private var planReadyTitle: String {
        let first = vm.name.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
        return first.map { "Your plan is ready, \($0)" } ?? "Your plan is ready"
    }

    // MARK: Reflections — the inputs the plan was built around

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

    // MARK: Weekly volume — the real shape of the block ahead (replaces the meaningless hours curve)

    /// Per-week planned volume across the whole block: run distance for runners, else session count.
    /// This is the plan's *actual* periodization (build → deload → taper), not a made-up line.
    private var weekly: (values: [Double], caption: String) {
        guard let sessions = profile?.plan?.sessions, !sessions.isEmpty else { return ([], "") }
        let cal = Calendar.current
        let start = cal.startOfDay(for: sessions.map(\.date).min() ?? Date())
        func weekOf(_ d: Date) -> Int { max(0, (cal.dateComponents([.day], from: start, to: cal.startOfDay(for: d)).day ?? 0) / 7) }
        let weekCount = min(16, (sessions.map { weekOf($0.date) }.max() ?? 0) + 1)
        guard weekCount > 0 else { return ([], "") }

        if vm.running {
            var m = [Double](repeating: 0, count: weekCount)
            for s in sessions where s.discipline == .running && weekOf(s.date) < weekCount {
                m[weekOf(s.date)] += s.targetDistanceM ?? 0
            }
            let peak = m.max() ?? 0
            let cap = "Peaks at \(Formatters.distance(meters: peak, unit: distanceUnit)) in week \((m.firstIndex(of: peak) ?? 0) + 1)"
            return (m, peak > 0 ? cap : "")
        } else {
            var c = [Double](repeating: 0, count: weekCount)
            for s in sessions where weekOf(s.date) < weekCount { c[weekOf(s.date)] += 1 }
            return (c, "\(Int(c.max() ?? 0)) sessions at your busiest week")
        }
    }

    @ViewBuilder
    private var weeklyVolumeCard: some View {
        let data = weekly
        if data.values.count > 1, (data.values.max() ?? 0) > 0 {
            let maxV = data.values.max() ?? 1
            let peakIdx = data.values.firstIndex(of: maxV) ?? 0
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                sectionLabel("YOUR NEXT \(data.values.count) WEEKS")
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    HStack(alignment: .bottom, spacing: 5) {
                        ForEach(Array(data.values.enumerated()), id: \.offset) { i, v in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(i == peakIdx ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.ink.opacity(0.16)))
                                .frame(height: max(6, CGFloat(v / maxV) * 84) * (barsIn ? 1 : 0.02))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 88, alignment: .bottom)
                    .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.8), value: barsIn)
                    HStack {
                        Text("Week 1").font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                        Spacer()
                        if !data.caption.isEmpty {
                            Text(data.caption).font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                        }
                    }
                }
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: The road ahead — a real route drawing itself under the purple "you" puck (runners)

    private var routeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionLabel("THE ROAD AHEAD")
            RouteDrawMap(headStyle: .puck, frameInsets: (64, 22))
                .frame(height: 236)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).stroke(Theme.hairline))
                .accessibilityLabel("A running route drawing across a map — your training ahead")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Anatomy — where the plan will build you (lift-only plans)

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

    // MARK: First week — tappable cards that expand to the actual work

    private var firstWeekList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionLabel("YOUR FIRST WEEK").reveal(0.34)
            VStack(spacing: Theme.Space.sm) {
                ForEach(Array(weekOne.enumerated()), id: \.element.persistentModelID) { index, session in
                    SessionDisclosureRow(session: session, profile: profile, distanceUnit: distanceUnit,
                                         startExpanded: index == 0)
                        .reveal(0.38 + Double(index) * 0.06)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Reveal orchestration

    private func animateIn() {
        guard !reduceMotion else {
            shownWeeks = Double(planWeekCount); shownDays = Double(vm.daysPerWeek)
            shownSessions = Double(totalSessions); bloom = 1; barsIn = true
            return
        }
        withAnimation(.easeOut(duration: 0.9).delay(0.15)) { bloom = 1 }
        withAnimation(.easeOut(duration: 1.1).delay(0.2)) {
            shownWeeks = Double(planWeekCount)
            shownDays = Double(vm.daysPerWeek)
            shownSessions = Double(totalSessions)
        }
        withAnimation(.spring(response: 0.7, dampingFraction: 0.8).delay(0.45)) { barsIn = true }
        Haptics.celebration()   // the earned, sold moment
    }
}

// MARK: - Expandable session card

/// A first-week session that expands to the concrete work: every lift's sets/reps/weight, or a run's
/// mileage, pace and rep breakdown. The dropdown the athlete asked for.
private struct SessionDisclosureRow: View {
    let session: PlannedSession
    let profile: UserProfile?
    let distanceUnit: DistanceUnit
    let startExpanded: Bool

    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                Haptics.selection()
                withAnimation(.snappy(duration: 0.26)) { expanded.toggle() }
            } label: {
                HStack(spacing: Theme.Space.md) {
                    Text(session.date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Theme.inkTertiary).frame(width: 34, alignment: .leading)
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Theme.background)
                        Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                    }
                    .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(primary).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                        Text(detail).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.inkTertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(Theme.Space.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Divider().overlay(Theme.hairline)
                    if session.discipline == .strength {
                        strengthDetail
                    } else {
                        runDetail
                    }
                }
                .padding(.horizontal, Theme.Space.md)
                .padding(.bottom, Theme.Space.md)
                .transition(.opacity)
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
        .onAppear { if startExpanded { expanded = true } }
    }

    // Strength: every exercise with its prescription.
    private var strengthDetail: some View {
        ForEach(session.strengthTargets.sorted { $0.order < $1.order }, id: \.persistentModelID) { ex in
            HStack {
                Text(ex.exercise?.name ?? "Exercise").font(.rounded(Theme.FontSize.caption, weight: .semibold))
                    .foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: Theme.Space.sm)
                if let w = StrengthSuggest.label(for: ex, profile: profile) {
                    Text(w).font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.inkTertiary)
                }
                Text("\(ex.targetSets) × \(ex.targetRepLow)–\(ex.targetRepHigh)")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary).frame(width: 66, alignment: .trailing)
            }
        }
    }

    // Run: mileage, target pace, rep breakdown, and the coaching rationale.
    @ViewBuilder
    private var runDetail: some View {
        if let dist = session.targetDistanceM, dist > 0 {
            statRow("Distance", Formatters.distance(meters: dist, unit: distanceUnit))
        }
        if let pace = session.targetPaceSPerKm, pace > 0 {
            statRow("Target pace", Formatters.pace(secPerKm: pace, unit: distanceUnit))
        }
        if let iv = session.intervals, !iv.isEmpty {
            statRow("Session", iv)
        }
        if let why = session.rationale, !why.isEmpty {
            Text(why).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
            Spacer(minLength: Theme.Space.sm)
            Text(value).font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.inkSecondary).multilineTextAlignment(.trailing)
        }
    }

    // MARK: Copy

    private var icon: String {
        switch session.discipline {
        case .running: "figure.run"; case .cycling: "bicycle"; case .walking: "figure.walk"; case .strength: "dumbbell.fill"
        }
    }

    private var primary: String {
        if session.discipline == .strength {
            return session.strengthTargets.count >= 5 ? "Full body" : "Strength"
        }
        return session.runType?.rawValue.capitalized ?? "Session"
    }

    private var detail: String {
        if session.discipline == .strength {
            let n = session.strengthTargets.count
            return "\(n) exercise\(n == 1 ? "" : "s") · tap to see"
        }
        if let dist = session.targetDistanceM {
            return "\(Formatters.distance(meters: dist, unit: distanceUnit)) · tap for pace"
        }
        return session.discipline.rawValue.capitalized
    }
}
