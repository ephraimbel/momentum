import SwiftUI

/// The unified plan reveal (PRD §4.1 step 4, §7.1) — the moment the user is sold. Glass pass
/// 2026-08-27 (owner: "Bevel-level, get creative"): the block is shown as a self-drawing volume
/// CURVE (the plan's real build → peak → taper, never a made-up line), the plan's shape as raised
/// stat tiles with count-ups, the first week as a seven-day strip and browsable session rows,
/// and every later week as a quiet ladder. Built from `OnboardingKit`'s raised surfaces so it
/// reads as the same object as the questions before it. Restrained, premium, honest.
struct PlanRevealView: View {
    let vm: OnboardingViewModel
    let profile: UserProfile?
    var onContinue: () -> Void

    @State private var shownWeeks = 0.0
    @State private var shownDays = 0.0
    @State private var shownSessions = 0.0
    @State private var curveIn = 0.0        // the volume curve draws itself 0…1
    @State private var calloutIn = false    // peak callout pops once the pen reaches it
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var totalSessions: Int { profile?.plan?.sessions.count ?? 0 }

    private var distanceUnit: DistanceUnit { DistanceUnit(rawValue: profile?.distanceUnit ?? "auto") ?? .auto }

    // MARK: One-pass derivation (perf audit 2026-08-13)
    //
    // Every week-bucketed read below comes from ONE pass, memoized in a reference box (invisible
    // to SwiftUI). Safe to hold `PlannedSession` refs: the reveal only exists in onboarding, after
    // generation — nothing can rebuild (and so delete) the plan underneath it.
    private struct Derived {
        var weekCount = 0
        var weeksGrouped: [(week: Int, sessions: [PlannedSession])] = []
    }
    private final class DerivedBox { var value: Derived? }
    @State private var derivedBox = DerivedBox()
    private var derived: Derived {
        if let v = derivedBox.value { return v }
        var v = Derived()
        if let sessions = profile?.plan?.sessions, !sessions.isEmpty {
            let cal = Calendar.current
            let start = cal.startOfDay(for: sessions.map(\.date).min() ?? Date())
            var groups: [Int: [PlannedSession]] = [:]
            for s in sessions {
                let w = max(0, (cal.dateComponents([.day], from: start,
                                                   to: cal.startOfDay(for: s.date)).day ?? 0) / 7)
                groups[w, default: []].append(s)
            }
            v.weekCount = (groups.keys.max() ?? 0) + 1
            v.weeksGrouped = groups.keys.sorted().map { w in
                (week: w + 1, sessions: groups[w]!.sorted { $0.date < $1.date })
            }
        }
        derivedBox.value = v
        return v
    }

    private var planWeekCount: Int { derived.weekCount }
    private var weeksGrouped: [(week: Int, sessions: [PlannedSession])] { derived.weeksGrouped }

    var body: some View {
        // The outer reader respects the safe area, so it can tell the full-bleed scroll below how
        // deep the status bar is; the scroll itself runs under it.
        GeometryReader { outer in
        let topInset = outer.safeAreaInsets.top
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: Theme.Space.lg) {
                hero
                blockCurveCard.reveal(0.18)
                statTiles.reveal(0.24)
                if let weeks = vm.weeksToRace { raceCountdown(weeks).reveal(0.28) }
                reflectionChips.reveal(0.31)
                if vm.intensity == .podium, vm.running { podiumOutlook.reveal(0.34).id("podium") }
                firstWeek.reveal(0.37)
                laterWeeks.id("plan").reveal(0.42)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, topInset + Theme.Space.sm)
            .padding(.bottom, Theme.Space.lg)
            // The crown: a soft aurora falling from the very top of the screen, part of the
            // CONTENT so it scrolls away with the hero (owner call 2026-08-27: not sticky, subtle).
            .background(alignment: .top) {
                LinearGradient(stops: [
                    .init(color: Theme.iridescent[0].opacity(colorScheme == .dark ? 0.26 : 0.42), location: 0),
                    .init(color: Theme.iridescent[1].opacity(colorScheme == .dark ? 0.12 : 0.2), location: 0.45),
                    .init(color: Theme.iridescent[2].opacity(0.07), location: 0.78),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .frame(height: 440 + topInset)
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea(edges: .top)
        // Status-bar scrim: scrolled content dissolves under the clock instead of colliding with it.
        .overlay(alignment: .top) {
            LinearGradient(colors: [OnboardingStyle.canvas(colorScheme).opacity(0.92),
                                    OnboardingStyle.canvas(colorScheme).opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: topInset + 10)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
        .scrollIndicators(.hidden)
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--reveal-scroll-plan") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { proxy.scrollTo("plan", anchor: .top) }
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--reveal-scroll-podium") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { proxy.scrollTo("podium", anchor: .center) }
                }
            }
        }
        #endif
        }
        .safeAreaInset(edge: .bottom) {
            OnboardingCTA(title: "This looks great") { onContinue() }
                .reveal(0.4)
                .padding(.horizontal, Theme.Space.lg)
                .padding(.top, Theme.Space.sm)
                .padding(.bottom, Theme.Space.sm)
                // ONE fade, owned by the button: clear → canvas rising above it, bled past the
                // column and under the home indicator. (A separate scroll-edge overlay plus an
                // opaque button background left a hairline seam between the two while scrolling —
                // owner report 2026-08-27.)
                .background {
                    LinearGradient(stops: [.init(color: OnboardingStyle.canvas(colorScheme).opacity(0), location: 0),
                                           .init(color: OnboardingStyle.canvas(colorScheme), location: 0.55),
                                           .init(color: OnboardingStyle.canvas(colorScheme), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .padding(.top, -Theme.Space.xl)
                        .padding(.horizontal, -Theme.Space.xxl)
                        .ignoresSafeArea(edges: .bottom)
                }
        }
        .onAppear(perform: animateIn)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.rounded(Theme.FontSize.label, weight: .bold))
            .tracking(1.4)
            .foregroundStyle(Theme.inkTertiary)
    }

    // MARK: Hero — the sold moment

    /// No wordmark (owner call 2026-08-27): the page opens on the athlete, not the brand. A quiet
    /// "plan ready" eyebrow with a lit dot, then the headline in the display face — "Your plan,"
    /// and the athlete's name on its own line in the brand gradient, the one place color enters
    /// the type. Below it, the outcome sentence.
    private var hero: some View {
        VStack(spacing: Theme.Space.md) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white, Theme.purple)
                Text("PLAN READY")
                    .font(.rounded(11, weight: .bold)).tracking(1.6)
                    .foregroundStyle(Theme.inkSecondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .raised(Capsule())
            .reveal(0.04)
            VStack(spacing: 0) {
                Text("Your plan,")
                    .font(.display(40, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(heroName)
                    .font(.display(40, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [Theme.purple, Color(hex: "B48CF2"), Theme.iridescent[1]],
                                                    startPoint: .leading, endPoint: .trailing))
            }
            .tracking(-1.0)
            .lineLimit(1).minimumScaleFactor(0.7)
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(planReadyTitle)
            .accessibilityAddTraits(.isHeader)
            .reveal(0.08)
            Text(vm.projectedOutcome())
                .font(.rounded(18, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Space.sm)
                .reveal(0.12)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.md)
    }

    /// "Maya." when we have a first name, "ready." otherwise.
    private var heroName: String {
        let first = vm.name.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
        return (first.map { "\($0)." } ?? "ready.")
    }

    /// Kept for the walkers, which look for this text on the page.
    private var planReadyTitle: String {
        let first = vm.name.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
        return first.map { "Your plan is ready, \($0)" } ?? "Your plan is ready"
    }

    // MARK: The block, as a curve

    /// Per-week planned volume across the block: run distance for runners, else session count.
    /// The plan's actual periodization — never a decorative line.
    private var weekly: (values: [Double], caption: String, raceWeek: Int?) {
        let weeks = derived.weeksGrouped
        guard !weeks.isEmpty else { return ([], "", nil) }
        let totalWeeks = derived.weekCount
        let weekCount = min(20, totalWeeks)
        guard weekCount > 0 else { return ([], "", nil) }
        let truncationNote = totalWeeks > weekCount ? " · first \(weekCount) of \(totalWeeks) weeks shown" : ""
        var raceWeek: Int?
        if vm.running {
            var m = [Double](repeating: 0, count: weekCount)
            for group in weeks where group.week <= weekCount {
                for s in group.sessions where s.discipline == .running {
                    if s.runType == .race { raceWeek = group.week; continue }
                    m[group.week - 1] += s.targetDistanceM ?? 0
                }
            }
            let peak = m.max() ?? 0
            let cap = "Peaks at \(Formatters.distance(meters: peak, unit: distanceUnit)) in week \((m.firstIndex(of: peak) ?? 0) + 1)"
            return (m, peak > 0 ? cap + truncationNote : "", raceWeek)
        } else {
            var c = [Double](repeating: 0, count: weekCount)
            for group in weeks where group.week <= weekCount {
                c[group.week - 1] += Double(group.sessions.count)
            }
            return (c, "\(Int(c.max() ?? 0)) sessions at your busiest week" + truncationNote, nil)
        }
    }

    @ViewBuilder
    private var blockCurveCard: some View {
        let data = weekly
        if data.values.count > 1, (data.values.max() ?? 0) > 0 {
            let maxV = data.values.max() ?? 1
            let peakIdx = data.values.firstIndex(of: maxV) ?? 0
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        sectionLabel("YOUR TRAINING BLOCK")
                        Text(vm.running ? "Weekly distance" : "Sessions per week")
                            .font(.rounded(17, weight: .semibold)).foregroundStyle(Theme.ink)
                    }
                    Spacer()
                    Text("\(data.values.count) weeks")
                        .font(.rounded(13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.inkSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Theme.tintedField))
                }
                VolumeCurve(values: data.values, peakIndex: peakIdx, raceWeek: data.raceWeek,
                            peakLabel: peakLabel(maxV), progress: curveIn, calloutIn: calloutIn)
                    .frame(height: 170)
                if !data.caption.isEmpty {
                    Text(data.caption)
                        .font(.rounded(Theme.FontSize.caption, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Space.md + 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .raised(RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous))
        }
    }

    private func peakLabel(_ v: Double) -> String {
        vm.running ? Formatters.distance(meters: v, unit: distanceUnit) : "\(Int(v.rounded())) sessions"
    }

    // MARK: Stat tiles

    private var statTiles: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                statTile(shownWeeks, "WEEKS") { "\(Int($0.rounded()))" }
                statTile(shownDays, "DAYS A WEEK") { "\(Int($0.rounded()))" }
                statTile(shownSessions, "SESSIONS") { "\(Int($0.rounded()))" }
            }
            if vm.running, let s = peakWeekStats {
                HStack(spacing: 12) {
                    textTile(Formatters.distance(meters: s.volumeM, unit: distanceUnit), "PEAK WEEK")
                    textTile(Formatters.distance(meters: s.longestM, unit: distanceUnit), "LONGEST RUN")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(planWeekCount) weeks, \(vm.daysPerWeek) days per week, \(totalSessions) sessions")
    }

    private func statTile(_ value: Double, _ label: String, _ format: @escaping (Double) -> String) -> some View {
        VStack(spacing: 4) {
            AnimatedCounter(value: value, format: format)
                .font(.display(30, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label).font(.rounded(10, weight: .bold)).tracking(1.0).foregroundStyle(Theme.inkTertiary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity).frame(height: 84)
        .raised(RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous))
    }

    private func textTile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.display(24, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.rounded(10, weight: .bold)).tracking(1.0).foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity).frame(height: 78)
        .raised(RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous))
    }

    // MARK: Reflections

    private var reflectionChips: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm + 2) {
            sectionLabel("BUILT AROUND YOU")
            FlowLayout(spacing: 10) {
                ForEach(vm.reflections(), id: \.self) { chip in
                    Text(chip)
                        .font(.rounded(14, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .raised(Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The Podium outlook (podium tier only)

    private var podiumOutlook: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionLabel("THE PODIUM OUTLOOK")
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                if let line = outlookProjectionLine {
                    Text(line)
                        .font(.rounded(16, weight: .semibold)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let s = peakWeekStats {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    HStack(spacing: 0) {
                        outlookCell(Formatters.distance(meters: s.volumeM, unit: distanceUnit), "PEAK WEEK")
                        Rectangle().fill(Theme.hairline).frame(width: 1, height: 34)
                        outlookCell(Formatters.distance(meters: s.longestM, unit: distanceUnit), "LONGEST RUN")
                        Rectangle().fill(Theme.hairline).frame(width: 1, height: 34)
                        outlookCell("\(s.hardDays)", "HARD DAYS / WK")
                    }
                }
                Text("Projected from your logged fitness. The work still has to happen.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            }
            .padding(Theme.Space.md + 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .raised(RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous))
            // The tier's signature ring rides the raised card — the one iridescent surface here.
            .overlay(RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous)
                .strokeBorder(IridescentMaterial(), lineWidth: 1.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var outlookProjectionLine: String? {
        guard let p5k = profile?.plan?.p5kSPerKm, p5k > 0 else { return nil }
        let weeks = planWeekCount
        if vm.goal == .raceDistance, let r = vm.raceDistance {
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

    private var peakWeekStats: (volumeM: Double, longestM: Double, hardDays: Int)? {
        let weeks = weeksGrouped
        guard !weeks.isEmpty else { return nil }
        func runVol(_ ss: [PlannedSession]) -> Double {
            ss.filter { $0.discipline == .running && $0.runType != .race }
                .compactMap(\.targetDistanceM).reduce(0, +)
        }
        let vols = weeks.map { runVol($0.sessions) }
        guard let peakIdx = vols.indices.max(by: { vols[$0] < vols[$1] }) else { return nil }
        let peak = weeks[peakIdx]
        let vol = vols[peakIdx]
        guard vol > 0 else { return nil }
        let longest = profile?.plan?.sessions
            .filter { $0.discipline == .running && $0.runType != .race }
            .compactMap(\.targetDistanceM).max() ?? 0
        let hard = peak.sessions.filter { $0.runType?.isQuality == true }.count
        return (volumeM: vol, longestM: longest, hardDays: hard)
    }

    private func outlookCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.display(20, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label).font(.rounded(10, weight: .bold)).tracking(1.0).foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Race countdown

    private func raceCountdown(_ weeks: Int) -> some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "flag.checkered").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 46, height: 46)
                .background(Circle().fill(Theme.tintedField))
            VStack(alignment: .leading, spacing: 2) {
                Text(weeks == 0 ? "Race week" : "\(weeks) week\(weeks == 1 ? "" : "s") to race day")
                    .font(.display(20, weight: .bold)).foregroundStyle(Theme.ink).monospacedDigit()
                if let r = vm.raceDistance {
                    Text("\(r.label) · \(vm.raceDate.formatted(.dateTime.weekday(.wide).month().day()))")
                        .font(.rounded(14, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raised(RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous))
    }

    // MARK: Week 1 — the seven-day strip + the sessions

    @ViewBuilder
    private var firstWeek: some View {
        if let first = weeksGrouped.first {
            VStack(alignment: .leading, spacing: Theme.Space.sm + 2) {
                sectionLabel("YOUR FIRST WEEK")
                WeekStrip(sessions: first.sessions)
                VStack(spacing: 10) {
                    ForEach(Array(first.sessions.enumerated()), id: \.element.persistentModelID) { i, session in
                        SessionDisclosureRow(session: session, profile: profile, distanceUnit: distanceUnit,
                                             startExpanded: i == 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Later weeks — the ladder

    @ViewBuilder
    private var laterWeeks: some View {
        let rest = Array(weeksGrouped.dropFirst())
        if !rest.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.sm + 2) {
                sectionLabel("THE WEEKS AHEAD")
                VStack(spacing: 0) {
                    ForEach(Array(rest.enumerated()), id: \.element.week) { i, group in
                        if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 18) }
                        HStack(spacing: Theme.Space.md) {
                            Text("Week \(group.week)")
                                .font(.rounded(15, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.ink)
                            Spacer(minLength: Theme.Space.sm)
                            WeekStrip(sessions: group.sessions, compact: true)
                            Text(weekSummary(group.sessions))
                                .font(.rounded(13, weight: .medium)).monospacedDigit()
                                .foregroundStyle(Theme.inkSecondary)
                                .frame(width: 64, alignment: .trailing)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 12)
                    }
                }
                .raised(RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func weekSummary(_ sessions: [PlannedSession]) -> String {
        if vm.running {
            let m = sessions.reduce(0.0) { $0 + ($1.discipline == .running ? ($1.targetDistanceM ?? 0) : 0) }
            if m > 0 { return Formatters.distance(meters: m, unit: distanceUnit) }
        }
        return "\(sessions.count) sess."
    }

    // MARK: Reveal orchestration

    private func animateIn() {
        guard !reduceMotion else {
            shownWeeks = Double(planWeekCount); shownDays = Double(vm.daysPerWeek)
            shownSessions = Double(totalSessions); curveIn = 1; calloutIn = true
            return
        }
        withAnimation(.easeOut(duration: 1.1).delay(0.3)) {
            shownWeeks = Double(planWeekCount)
            shownDays = Double(vm.daysPerWeek)
            shownSessions = Double(totalSessions)
        }
        withAnimation(Motion.pen(1.4).delay(0.35)) { curveIn = 1 }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(1.5)) { calloutIn = true }
        Haptics.celebration()
    }
}

// MARK: - The volume curve

/// The block's weekly volume as a smooth curve with a soft lavender fill under it, faint week
/// gridlines, the peak called out, race week flagged. Draws itself with `trim` (a path
/// transform, never a layout change). Reduce Motion: fully drawn on arrival.
private struct VolumeCurve: View {
    let values: [Double]
    let peakIndex: Int
    let raceWeek: Int?
    let peakLabel: String
    let progress: Double
    let calloutIn: Bool

    private let inset: CGFloat = 8
    private let top: CGFloat = 30      // room for the callout pill
    private let axis: CGFloat = 22     // room for week labels

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let pts = points(in: CGSize(width: w, height: h))
            let curve = smoothPath(pts)
            let n = values.count
            let stroke = LinearGradient(colors: [Theme.iridescent[1], Theme.purple, Theme.iridescent[0]],
                                        startPoint: .leading, endPoint: .trailing)
            ZStack(alignment: .topLeading) {
                // Week gridlines.
                ForEach(0..<n, id: \.self) { i in
                    Rectangle().fill(Theme.ink.opacity(0.05)).frame(width: 1)
                        .frame(height: h - axis - top, alignment: .top)
                        .offset(x: pts[i].x, y: top)
                }
                // Fill under the curve, revealed with the pen.
                fillPath(curve, base: h - axis, last: pts.last!, first: pts.first!)
                    .fill(LinearGradient(colors: [Theme.purple.opacity(0.22), Theme.purple.opacity(0.0)],
                                         startPoint: .top, endPoint: .bottom))
                    .mask(Rectangle().frame(width: w * progress).frame(maxWidth: .infinity, alignment: .leading))
                // The curve itself.
                curve.trim(from: 0, to: progress)
                    .stroke(stroke, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .shadow(color: Theme.purple.opacity(0.35), radius: 6, y: 3)
                // Pen head.
                if progress < 1 {
                    Circle().fill(.white).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Theme.purple, lineWidth: 2.5))
                        .position(pointAlong(curve, progress))
                }
                // Peak: dot + pill.
                let p = pts[peakIndex]
                Circle().fill(.white).frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Theme.purple, lineWidth: 3))
                    .position(p)
                    .opacity(calloutIn ? 1 : 0)
                Text(peakLabel)
                    .font(.rounded(12, weight: .bold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Capsule().fill(Color(hex: "1C1C1E")))
                    .fixedSize()
                    .position(x: min(max(p.x, 44), w - 44), y: max(12, p.y - 24))
                    .scaleEffect(calloutIn ? 1 : 0.7, anchor: .bottom)
                    .opacity(calloutIn ? 1 : 0)
                // Race day flag.
                if let rw = raceWeek, rw - 1 < n {
                    let rx = pts[rw - 1].x
                    Image(systemName: "flag.checkered.circle.fill")
                        .font(.system(size: 16)).foregroundStyle(Theme.ink)
                        .position(x: rx, y: h - axis - 10)
                        .opacity(calloutIn ? 1 : 0)
                }
                // Week labels: first, peak, last, plus sparse ticks.
                ForEach(0..<n, id: \.self) { i in
                    let tickEvery = n <= 8 ? 1 : (n <= 12 ? 2 : 4)
                    if i == 0 || i == n - 1 || i == peakIndex || i.isMultiple(of: tickEvery) {
                        Text(i == 0 ? "Wk 1" : "\(i + 1)")
                            .font(.rounded(11, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(i == peakIndex ? Theme.ink : Theme.inkTertiary)
                            .position(x: pts[i].x, y: h - 8)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let n = max(2, values.count)
        let maxV = max(values.max() ?? 1, 0.0001)
        let usableW = size.width - inset * 2
        let usableH = size.height - axis - top
        return values.enumerated().map { i, v in
            CGPoint(x: inset + usableW * CGFloat(i) / CGFloat(n - 1),
                    y: top + usableH * (1 - CGFloat(v / maxV)))
        }
    }

    /// Catmull-Rom through the points, so the build reads as one continuous line.
    private func smoothPath(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard pts.count > 1 else { return path }
        path.move(to: pts[0])
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    private func fillPath(_ curve: Path, base: CGFloat, last: CGPoint, first: CGPoint) -> Path {
        var p = curve
        p.addLine(to: CGPoint(x: last.x, y: base))
        p.addLine(to: CGPoint(x: first.x, y: base))
        p.closeSubpath()
        return p
    }

    private func pointAlong(_ path: Path, _ t: Double) -> CGPoint {
        let trimmed = path.trimmedPath(from: 0, to: max(0.001, t))
        return trimmed.currentPoint ?? .zero
    }
}

// MARK: - Seven-day strip

/// Mon…Sun as dots — lavender for a run, ink for a lift, sky for anything else, hollow for rest —
/// so a week's shape reads at a glance without a single word.
private struct WeekStrip: View {
    let sessions: [PlannedSession]
    var compact = false

    private var days: [(letter: String, sessions: [PlannedSession])] {
        let cal = Calendar.current
        let letters = ["M", "T", "W", "T", "F", "S", "S"]
        // ISO week: Monday first.
        var buckets = Array(repeating: [PlannedSession](), count: 7)
        for s in sessions {
            let wd = cal.component(.weekday, from: s.date)   // 1 = Sunday
            let idx = (wd + 5) % 7
            buckets[idx].append(s)
        }
        return (0..<7).map { (letters[$0], buckets[$0]) }
    }

    var body: some View {
        HStack(spacing: compact ? 5 : 0) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                VStack(spacing: 6) {
                    if !compact {
                        Text(day.letter).font(.rounded(11, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    }
                    dot(day.sessions)
                }
                .frame(maxWidth: compact ? nil : .infinity)
            }
        }
        .padding(.horizontal, compact ? 0 : 4)
        .accessibilityHidden(true)
    }

    private func dot(_ ss: [PlannedSession]) -> some View {
        let size: CGFloat = compact ? 7 : 12
        let color: Color? = ss.first.map { s in
            switch s.discipline {
            case .running: Theme.purple
            case .strength: Theme.ink
            default: Theme.iridescent[1]
            }
        }
        return ZStack {
            if let color {
                Circle().fill(color)
            } else {
                Circle().stroke(Theme.ink.opacity(0.14), lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Expandable session card

/// A plan session that expands to the concrete work: every lift's sets/reps, or a run's mileage,
/// pace, rep breakdown and — for long runs — fueling guidance.
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
                    VStack(spacing: 1) {
                        Text(session.date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                            .font(.rounded(10, weight: .bold)).tracking(0.5).foregroundStyle(Theme.inkTertiary)
                        Text(session.date.formatted(.dateTime.day()))
                            .font(.display(18, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                    }
                    .frame(width: 34)
                    Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(session.discipline == .running ? Theme.purpleDeep : Theme.ink)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(session.discipline == .running ? Theme.purpleTint : Theme.tintedField))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(primary).font(.rounded(16, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text(detail).font(.rounded(13, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.inkTertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Divider().overlay(Theme.hairline)
                    if session.discipline == .strength { strengthDetail } else { runDetail }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .transition(.opacity)
            }
        }
        .raised(RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous))
        .onAppear { if startExpanded { expanded = true } }
    }

    private var strengthDetail: some View {
        ForEach(session.strengthTargets.sorted { $0.order < $1.order }, id: \.persistentModelID) { ex in
            HStack {
                Text(ex.exercise?.name ?? "Exercise").font(.rounded(14, weight: .semibold))
                    .foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: Theme.Space.sm)
                Text(ex.prescriptionText)
                    .font(.rounded(14, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary).frame(width: 66, alignment: .trailing)
            }
        }
    }

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
            Text(why).font(.rounded(14, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        fuelTip
    }

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
                        Text(g.headline).font(.rounded(13, weight: .bold)).foregroundStyle(Theme.ink)
                    }
                    fuelLine("BEFORE", g.before)
                    fuelLine("DURING", g.during)
                    fuelLine("AFTER", g.after)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.tintedField))
            }
        }
    }

    private func fuelLine(_ label: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Text(label).font(.rounded(9, weight: .black)).tracking(0.7).foregroundStyle(Theme.inkTertiary)
                .frame(width: 46, alignment: .leading).padding(.top, 2)
            Text(text).font(.rounded(12, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.rounded(14, weight: .semibold)).foregroundStyle(Theme.ink)
            Spacer(minLength: Theme.Space.sm)
            Text(value).font(.rounded(14, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.inkSecondary).multilineTextAlignment(.trailing)
        }
    }

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
            return "\(n) exercise\(n == 1 ? "" : "s")"
        }
        if let dist = session.targetDistanceM {
            return Formatters.distance(meters: dist, unit: distanceUnit)
        }
        return session.discipline.rawValue.capitalized
    }
}
