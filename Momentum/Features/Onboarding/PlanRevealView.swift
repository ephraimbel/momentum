import SwiftUI

/// The unified plan reveal (PRD §4.1 step 4, §7.1) — the moment the user is sold. Clean and monochrome:
/// centered brand wordmark, an editorial headline, a count-up plan summary, the real weekly-volume shape
/// of the block ahead, and the first week as tappable cards that expand to the actual work (every lift,
/// every run's mileage + pace). Restrained, premium, professional.
struct PlanRevealView: View {
    let vm: OnboardingViewModel
    let profile: UserProfile?
    var onContinue: () -> Void

    @State private var shownWeeks = 0.0
    @State private var shownDays = 0.0
    @State private var shownSessions = 0.0
    @State private var barsIn = false       // weekly-volume bars grow up on appear
    @State private var calloutIn = false    // peak-week callout pops in after the bars settle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

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

    /// The whole plan, grouped into weeks (1-based) so the athlete can browse every session ahead.
    private var weeksGrouped: [(week: Int, sessions: [PlannedSession])] {
        guard let sessions = profile?.plan?.sessions, !sessions.isEmpty else { return [] }
        let cal = Calendar.current
        let start = cal.startOfDay(for: sessions.map(\.date).min() ?? Date())
        func weekOf(_ d: Date) -> Int { max(0, (cal.dateComponents([.day], from: start, to: cal.startOfDay(for: d)).day ?? 0) / 7) }
        var groups: [Int: [PlannedSession]] = [:]
        for s in sessions { groups[weekOf(s.date), default: []].append(s) }
        return groups.keys.sorted().map { w in
            (week: w + 1, sessions: groups[w]!.sorted { $0.date < $1.date })
        }
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
                if vm.intensity == .podium, vm.running { podiumOutlook.reveal(0.33).id("podium") }
                fullPlanList.id("plan")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Space.sm)
            .padding(.bottom, Theme.Space.sm)
        }
        .scrollIndicators(.hidden)
        #if DEBUG
        .onAppear {
            // Deterministic sim verification of the lower half (simctl can't scroll).
            if ProcessInfo.processInfo.arguments.contains("--reveal-scroll-plan") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { proxy.scrollTo("plan", anchor: .top) }
                }
            }
            // --reveal-scroll-podium: frame the Podium outlook card (its iridescent border is a
            // design surface that needs screenshot verification).
            if ProcessInfo.processInfo.arguments.contains("--reveal-scroll-podium") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { proxy.scrollTo("podium", anchor: .center) }
                }
            }
        }
        #endif
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
        // Onboarding runs unconditionally dark (RootView, 2026-07-28), so in practice this is always
        // the white mark — kept conditional anyway so the reveal can't render an invisible black
        // wordmark if it's ever shown on a light canvas. Same idiom as CommunityView's masthead.
        Image(colorScheme == .dark ? "WordmarkWhite" : "WordmarkBlack")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(height: 22)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("momentum")
            .reveal(0.02)
    }

    // MARK: Hero — editorial headline + count-up summary

    private var hero: some View {
        VStack(spacing: Theme.Space.lg) {
            VStack(spacing: Theme.Space.sm) {
                Text(planReadyTitle)
                    .font(.serif(30, weight: .semibold))
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
            .padding(.top, Theme.Space.xs)
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
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
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
                            .padding(.horizontal, Theme.Space.md).padding(.vertical, 9)
                            .background(Capsule().fill(Theme.surface))
                            .overlay(Capsule().stroke(Theme.hairline))
                    }
                }
                // Parks the last chip clear of the trailing fade below when scrolled to the end.
                .padding(.trailing, Theme.Space.lg)
            }
            .scrollIndicators(.hidden)
            // Soft trailing fade at the clip edge: when the row overflows, the cut chip dissolves
            // instead of slicing mid-capsule (the same scrim idea the paywall CTA uses). The
            // leading edge stays crisp so the row reads left-aligned with the label above.
            .mask(
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.92),
                    .init(color: .clear, location: 1.0),
                ], startPoint: .leading, endPoint: .trailing)
            )
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

        // A long season charts its first 16 weeks — say so, or "30 WEEKS" in the stat strip above
        // sits over a 16-bar chart with no explanation.
        let totalWeeks = (sessions.map { weekOf($0.date) }.max() ?? 0) + 1
        let truncationNote = totalWeeks > weekCount ? " · first \(weekCount) of \(totalWeeks) weeks shown" : ""

        if vm.running {
            var m = [Double](repeating: 0, count: weekCount)
            for s in sessions where s.discipline == .running && weekOf(s.date) < weekCount {
                m[weekOf(s.date)] += s.targetDistanceM ?? 0
            }
            let peak = m.max() ?? 0
            let cap = "Peaks at \(Formatters.distance(meters: peak, unit: distanceUnit)) in week \((m.firstIndex(of: peak) ?? 0) + 1)"
            return (m, peak > 0 ? cap + truncationNote : "")
        } else {
            var c = [Double](repeating: 0, count: weekCount)
            for s in sessions where weekOf(s.date) < weekCount { c[weekOf(s.date)] += 1 }
            return (c, "\(Int(c.max() ?? 0)) sessions at your busiest week" + truncationNote)
        }
    }

    @ViewBuilder
    private var weeklyVolumeCard: some View {
        let data = weekly
        if data.values.count > 1, (data.values.max() ?? 0) > 0 {
            let maxV = data.values.max() ?? 1
            let peakIdx = data.values.firstIndex(of: maxV) ?? 0
            let count = data.values.count
            let tickEvery = count <= 8 ? 1 : (count <= 12 ? 2 : 3)
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                sectionLabel("YOUR TRAINING BLOCK")
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    // Elegant progression bars — a gray build with the peak week in the running-trace
                    // purple (Theme.route), its value called out on a pill that pops in once bars settle.
                    HStack(alignment: .bottom, spacing: barGap(count)) {
                        ForEach(Array(data.values.enumerated()), id: \.offset) { i, v in
                            VStack(spacing: 5) {
                                Spacer(minLength: 0)
                                if i == peakIdx {
                                    Text(peakLabel(maxV))
                                        .font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
                                        // `Theme.background`, not `.white`: the capsule is filled
                                        // with `Theme.ink`, which inverts to near-white in dark —
                                        // hardcoded white text on it would be invisible.
                                        .foregroundStyle(Theme.background)
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(Capsule().fill(Theme.ink))
                                        .fixedSize()
                                        .scaleEffect(calloutIn ? 1 : 0.7, anchor: .bottom)
                                        .opacity(calloutIn ? 1 : 0)
                                }
                                UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 0,
                                                       bottomTrailingRadius: 0, topTrailingRadius: 6, style: .continuous)
                                    .fill(i == peakIdx
                                          ? AnyShapeStyle(LinearGradient(colors: [Theme.route, Theme.route.opacity(0.78)],
                                                                         startPoint: .top, endPoint: .bottom))
                                          : AnyShapeStyle(LinearGradient(colors: [Theme.ink.opacity(0.18), Theme.ink.opacity(0.05)],
                                                                         startPoint: .top, endPoint: .bottom)))
                                    .frame(height: max(5, CGFloat(v / maxV) * 116) * (barsIn ? 1 : 0.02))
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 158, alignment: .bottom)
                    .animation(reduceMotion ? nil : .spring(response: 0.65, dampingFraction: 0.78), value: barsIn)

                    Rectangle().fill(Theme.hairline).frame(height: 1)

                    // Week axis — sparse ticks so it never crowds; the peak week always labeled.
                    HStack(spacing: barGap(count)) {
                        ForEach(Array(data.values.enumerated()), id: \.offset) { i, _ in
                            Text("\(i + 1)")
                                .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(i == peakIdx ? Theme.ink : Theme.inkTertiary)
                                .opacity((i % tickEvery == 0 || i == count - 1 || i == peakIdx) ? 1 : 0)
                                .frame(maxWidth: .infinity)
                        }
                    }

                    if !data.caption.isEmpty {
                        Text(data.caption)
                            .font(.rounded(Theme.FontSize.caption, weight: .medium))
                            .foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Tighter gaps as the block gets longer so 16 weeks still breathe.
    private func barGap(_ count: Int) -> CGFloat { count <= 6 ? 8 : (count <= 10 ? 6 : 4) }

    /// The peak week's value for the on-chart callout — distance for runners, session count otherwise.
    private func peakLabel(_ v: Double) -> String {
        vm.running ? Formatters.distance(meters: v, unit: distanceUnit) : "\(Int(v.rounded()))"
    }

    // MARK: The Podium outlook (podium tier only — the depth the commitment earned)

    /// Honest projections + the block's peak profile, for the athlete training to win. Wears the
    /// tier's iridescent border — the reveal stays monochrome (user call) EXCEPT the Podium
    /// signature, which follows the tier from its selection card to its promise.
    private var podiumOutlook: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionLabel("THE PODIUM OUTLOOK")
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                if let line = outlookProjectionLine {
                    Text(line)
                        .font(.rounded(Theme.FontSize.body, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let s = peakWeekStats {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    HStack(spacing: 0) {
                        outlookCell(Formatters.distance(meters: s.volumeM, unit: distanceUnit), "PEAK WEEK")
                        statDivider
                        outlookCell(Formatters.distance(meters: s.longestM, unit: distanceUnit), "LONGEST RUN")
                        statDivider
                        outlookCell("\(s.hardDays)", "HARD DAYS / WK")
                    }
                }
                Text("Projected from your logged fitness. The work still has to happen.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
            // strokeBorder, not stroke: a centered stroke overhangs the card by half its width, and
            // the scroll view clips that overhang on the left/right (full-width card) but not
            // top/bottom (open spacing) — the border rendered 0.75pt on the sides and 1.5pt+glow
            // above/below (owner report 2026-07-30). Inset fully inside, it's uniform everywhere.
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(IridescentMaterial(), lineWidth: 1.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Race path: today's predicted finish, then the goal the block is built to REACH — aiming at the
    /// athlete's actual target is the job, not hedging a lesser prediction. When the goal is a genuine
    /// stretch beyond one cycle's honest reach, we still point at it and name the real ground this
    /// block covers toward it. No-race: the athlete's 5K, now and where the block points it. All from
    /// `PodiumOutlook` (the verdict's own improvement model — never a promise the engine would refuse).
    private var outlookProjectionLine: String? {
        guard let p5k = profile?.plan?.p5kSPerKm, p5k > 0 else { return nil }
        let weeks = planWeekCount
        if vm.goal == .raceDistance, let r = vm.raceDistance {
            // Their own time at the race distance is the honest "now" — mirrors the feasibility
            // banner, so the reveal never contradicts the verdict the athlete just saw.
            let raceTimeS: Double? = {
                guard let rr = vm.calibration.recentRun, abs(rr.distanceM - r.meters) < 100 else { return nil }
                return rr.timeS
            }()
            guard let proj = PodiumOutlook.raceProjection(raceDistanceM: r.meters, p5kSPerKm: p5k,
                                                          goalFinishTimeS: vm.goalFinishTimeS,
                                                          experience: vm.experience, weeks: weeks,
                                                          currentRaceTimeS: raceTimeS) else { return nil }
            let now = PlanFeasibility.hms(proj.nowS)
            let race = r.label.lowercased()
            if let goalS = vm.goalFinishTimeS {
                // Built to reach it (goal within honest reach) vs. built to close on it (a stretch).
                if proj.builtS <= goalS + 1 {
                    return "Today's fitness runs a \(now) \(race). This block is built to get you to your \(PlanFeasibility.hms(goalS)) goal."
                }
                return "Today's fitness runs a \(now) \(race). This block drives you to \(PlanFeasibility.hms(proj.builtS)), real ground toward your \(PlanFeasibility.hms(goalS)) goal."
            }
            return "Today's fitness runs a \(now) \(race). This build is pointed at \(PlanFeasibility.hms(proj.builtS))."
        }
        guard let proj = PodiumOutlook.fiveKProjection(p5kSPerKm: p5k, experience: vm.experience,
                                                       weeks: weeks) else { return nil }
        return "Today you're a \(PlanFeasibility.hms(proj.nowS)) 5K runner. This block is built to move you toward \(PlanFeasibility.hms(proj.builtS))."
    }

    /// The block's biggest week: running volume, the single longest run anywhere in the block, and
    /// how many hard days that peak week holds.
    private var peakWeekStats: (volumeM: Double, longestM: Double, hardDays: Int)? {
        let weeks = weeksGrouped
        guard !weeks.isEmpty else { return nil }
        func runVol(_ ss: [PlannedSession]) -> Double {
            ss.filter { $0.discipline == .running && $0.runType != .race }
                .compactMap(\.targetDistanceM).reduce(0, +)
        }
        guard let peak = weeks.max(by: { runVol($0.sessions) < runVol($1.sessions) }) else { return nil }
        let vol = runVol(peak.sessions)
        guard vol > 0 else { return nil }
        let longest = profile?.plan?.sessions
            .filter { $0.discipline == .running && $0.runType != .race }
            .compactMap(\.targetDistanceM).max() ?? 0
        let hard = peak.sessions.filter { $0.runType?.isQuality == true }.count
        return (volumeM: vol, longestM: longest, hardDays: hard)
    }

    private func outlookCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.display(20, weight: .black)).monospacedDigit()
                .foregroundStyle(Theme.ink)
            Text(label)
                .font(.rounded(Theme.FontSize.label, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Race countdown (dated race goals)

    private func raceCountdown(_ weeks: Int) -> some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "flag.checkered").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.background)).overlay(Circle().stroke(Theme.hairline))
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
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
    }

    // MARK: The full plan — every week, collapsible; sessions expand to the actual work + fueling

    private var fullPlanList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            sectionLabel("YOUR PLAN, WEEK BY WEEK").reveal(0.34)
            // Week 1 carries the full browsable detail; the later weeks are HEADER-ONLY (week +
            // shape, no session content, not expandable) — owner call 2026-08-11: rendering every
            // week's disclosure tree made the reveal load glitchy, and the block's shape is
            // already told by the volume chart above. Week 1 is the sell; the rest is the promise.
            ForEach(Array(weeksGrouped.enumerated()), id: \.element.week) { i, group in
                WeekSection(week: group.week, sessions: group.sessions, profile: profile,
                            distanceUnit: distanceUnit, running: vm.running,
                            startExpanded: group.week == 1, browsable: group.week == 1)
                    .reveal(min(0.6, 0.38 + Double(i) * 0.05))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Reveal orchestration

    private func animateIn() {
        guard !reduceMotion else {
            shownWeeks = Double(planWeekCount); shownDays = Double(vm.daysPerWeek)
            shownSessions = Double(totalSessions); barsIn = true; calloutIn = true
            return
        }
        withAnimation(.easeOut(duration: 1.1).delay(0.2)) {
            shownWeeks = Double(planWeekCount)
            shownDays = Double(vm.daysPerWeek)
            shownSessions = Double(totalSessions)
        }
        withAnimation(.spring(response: 0.7, dampingFraction: 0.8).delay(0.5)) { barsIn = true }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(1.0)) { calloutIn = true }
        Haptics.celebration()   // the earned, sold moment
    }
}

// MARK: - Collapsible week

/// One week of the plan. Week 1 is browsable — its header expands to every session, each of which
/// expands again to the concrete work and — for long runs — fueling guidance. Later weeks render as
/// header-only rows (`browsable: false`): the week's shape without its content, so the reveal never
/// builds the whole block's disclosure tree (perf, owner call 2026-08-11).
private struct WeekSection: View {
    let week: Int
    let sessions: [PlannedSession]
    let profile: UserProfile?
    let distanceUnit: DistanceUnit
    let running: Bool
    let startExpanded: Bool
    var browsable = true

    @State private var expanded = false

    private var summary: String {
        let n = sessions.count
        if running {
            let m = sessions.reduce(0.0) { $0 + ($1.discipline == .running ? ($1.targetDistanceM ?? 0) : 0) }
            if m > 0 { return "\(n) · \(Formatters.distance(meters: m, unit: distanceUnit))" }
        }
        return "\(n) session\(n == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            if browsable {
                Button {
                    Haptics.selection()
                    withAnimation(.snappy(duration: 0.26)) { expanded.toggle() }
                } label: {
                    header(chevron: true)
                }
                .buttonStyle(.plain)
            } else {
                header(chevron: false)
            }

            if browsable, expanded {
                VStack(spacing: Theme.Space.sm) {
                    ForEach(Array(sessions.enumerated()), id: \.element.persistentModelID) { i, session in
                        SessionDisclosureRow(session: session, profile: profile, distanceUnit: distanceUnit,
                                             startExpanded: week == 1 && i == 0)
                    }
                }
                .transition(.opacity)
            }
        }
        .onAppear { if startExpanded { expanded = true } }
    }

    private func header(chevron: Bool) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Text("WEEK \(week)")
                .font(.rounded(Theme.FontSize.caption, weight: .black)).tracking(1.2)
                .foregroundStyle(Theme.ink)
            Spacer(minLength: Theme.Space.sm)
            Text(summary)
                .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.inkTertiary)
            if chevron {
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.inkTertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
        }
        .padding(.horizontal, Theme.Space.xs)
        .contentShape(Rectangle())
    }
}

// MARK: - Expandable session card

/// A plan session that expands to the concrete work: every lift's sets/reps/weight, or a run's mileage,
/// pace, rep breakdown and — for long runs — fueling guidance. The dropdown the athlete asked for.
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
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
        .onAppear { if startExpanded { expanded = true } }
    }

    // Strength: every exercise with its prescription.
    private var strengthDetail: some View {
        ForEach(session.strengthTargets.sorted { $0.order < $1.order }, id: \.persistentModelID) { ex in
            HStack {
                Text(ex.exercise?.name ?? "Exercise").font(.rounded(Theme.FontSize.caption, weight: .semibold))
                    .foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: Theme.Space.sm)
                Text(ex.prescriptionText)
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
        fuelTip
    }

    /// Fueling guidance for the longer runs (short runs stay silent) — the same evidence-based `FuelingGuide`
    /// the in-app session detail shows, so the athlete sees just how thorough the plan is.
    @ViewBuilder
    private var fuelTip: some View {
        if session.discipline == .running,
           let dur = FuelingGuide.estimatedDurationS(distanceM: session.targetDistanceM,
                                                     paceSPerKm: session.targetPaceSPerKm,
                                                     durationS: session.targetDurationS) {
            let g = FuelingGuide.guidance(durationS: dur, isRace: session.runType == .race)
            if g.carbsPerHour != nil {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.ink)
                        Text(g.headline).font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
                    }
                    fuelLine("BEFORE", g.before)
                    fuelLine("DURING", g.during)
                    fuelLine("AFTER", g.after)
                }
                .padding(Theme.Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Theme.background))
            }
        }
    }

    private func fuelLine(_ label: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Text(label).font(.rounded(9, weight: .black)).tracking(0.7).foregroundStyle(Theme.inkTertiary)
                .frame(width: 46, alignment: .leading).padding(.top, 2)
            Text(text).font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkSecondary)
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
