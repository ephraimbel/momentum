import SwiftUI

/// The unified plan reveal (PRD §4.1 step 4, §7.1) — the moment the athlete is sold.
///
/// Rebuilt 2026-09-02 as one choreographed arrival in three acts, every beat a transform
/// (opacity / scale / offset / rotation / trim), never a layout change:
///
///  1. **The overture.** A full-screen title card: the athlete's own name lands one letter at a
///     time out of blur in the display face, a start line draws beneath it, one specular pass
///     runs through the letters, and the whole card lifts away as the page rises under it.
///  2. **The ascent.** The seal draws its check, the headline arrives, and the path card lands
///     with one spent aurora pulse. The block's weekly volume is drawn as terrain that a runner
///     glyph runs along — a comet tail behind it, each week's gridline lighting as it passes,
///     the peak flaring once and the runner arriving at the goal beacon.
///     The stat tiles stand up off the page one after another and tally in the order the light
///     crosses them; the CTA rises and catches that light once.
///  3. **With the reader.** One scroll holds the briefing, complete first week and block outlook.
///     Every session is open; the path and later sections arrive when they enter the viewport.
///
/// Every light on this page travels ONCE and ends off its own view, so the settled page is
/// perfectly still and readable. Reduce Motion: no overture, no motion — the finished page.
/// Uses `OnboardingKit` surfaces to match the interview and its optional detail sheets.
struct PlanRevealView: View {
    let vm: OnboardingViewModel
    let profile: UserProfile?
    var onContinue: () -> Void

    // MARK: Act I — the overture
    @State private var overtureMounted = true
    @State private var arrivalStarted = false
    @State private var pathStarted = false
    @State private var pathReached = false
    @State private var pathIn = 0.0
    @State private var titleLetters = 0.0   // one clock; each letter reads its own eased slice
    @State private var titleLine = 0.0      // the start line drawing outward from the centre
    @State private var titleSheen = 0.0     // one specular pass through the letters
    @State private var overtureExit = 0.0   // the card lifting away, 0…1
    @State private var pageIn = 0.0         // the page rising under it, 0…1

    // MARK: Act II — the ascent
    @State private var heroIn = 0.0
    @State private var checkDraw = 0.0      // the PLAN READY tick drawing itself
    @State private var arrivalHalo = 0.0
    @State private var nameSheen = 0.0      // specular pass across the athlete's name
    @State private var artifactIn = 0.0
    @State private var artifactGlow = 0.0   // one aurora pulse as the card lands, then spent
    @State private var curveIn = 0.0        // the runner's progress along the terrain, 0…1
    @State private var calloutIn = false    // peak callout pops once the runner has passed it
    @State private var pathArrival = 0.0    // goal beacon lands once, then is perfectly still
    @State private var curveGleam = 0.0     // a highlight running the finished line, after the runner
    @State private var statsIn = 0.0        // the tiles standing up, one after another
    /// The tiles stand up when the athlete REACHES them: on a tall phone that is during the
    /// arrival, on a smaller one it is the first scroll. `revealClock` is when the arrival began
    /// and `statsBeat` where the tiles sit in it, so an early reach still waits its turn.
    @State private var statsStarted = false
    @State private var statsReached = false
    @State private var revealClock: Date?
    @State private var statsBeat = 0.0
    @State private var shownWeeks = 0.0
    @State private var shownDays = 0.0
    @State private var shownSessions = 0.0
    @State private var tileSheen = 0.0      // light crossing the stat tiles, left to right
    @State private var ctaIn = 0.0
    @State private var ctaSheen = 0.0       // the ink capsule catching the light once

    // MARK: Act III — with the reader
    @State private var stripFill = 0.0      // the first week's day dots lighting in order
    @State private var chipsIn = 0.0        // "built around you" arriving one chip at a time

    /// The choreography's clocks, held so they can be cancelled if the page goes away mid-sequence.
    @State private var sequence: Task<Void, Never>?
    /// Whether the stat tiles are on screen. Their ghosts are the only continuous clocks on this
    /// page, and a `TimelineView` running behind six weeks of plan the athlete has scrolled to is
    /// pure heat — the paywall gates its own tile arts the same way.
    @State private var tilesOnScreen = false
    @ReducedMotionPreference private var reduceMotion
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

    /// A narrow specular band travelling left to right, for masking onto whatever should catch the
    /// light. `progress` runs 0…1 and the band starts and ends fully off the view, so both ends of
    /// the animation are a clean no-op — nothing to fade in or out.
    ///
    /// `plusLighter` rather than a white fill: on the raised tiles it reads as light moving across
    /// a surface, and on the name it brightens the gradient instead of painting over it.
    private func sheenBand(_ clock: Double, index: Int? = nil, strength: Double = 0.9) -> some View {
        SheenBand(clock: clock, index: index, strength: strength)
    }

    var body: some View {
        // The outer reader respects the safe area, so it can tell the full-bleed scroll below how
        // deep the status bar is; the scroll itself runs under it.
        GeometryReader { outer in
        let topInset = outer.safeAreaInsets.top
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: Theme.Space.lg) {
                hero
                animatedTrainingPath
                trainingBriefing
                    .opacity(reduceMotion ? 1 : artifactIn)
                    .offset(y: reduceMotion ? 0 : 16 * (1 - artifactIn))
                detailedPlan
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, topInset + Theme.Space.sm)
            .padding(.bottom, Theme.Space.lg)
            // The crown: the PAYWALL'S OWN FIELD, falling from the very top of the screen and
            // part of the CONTENT, so it still scrolls away with the hero (owner call 2026-08-27:
            // not sticky, subtle). `AiryField` is the paywall's premium feel — separated hues
            // reading as air rather than as one purple wash — and `paintsBackground: false` keeps
            // onboarding's lighter canvas underneath. The mask dissolves it into that canvas.
            .background(alignment: .top) {
                AiryField(intensity: colorScheme == .dark ? 0.55 : 0.85, paintsBackground: false)
                    .frame(height: 440 + topInset)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                                 .init(color: .black, location: 0.58),
                                                 .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea(edges: .top)
        // Status-bar scrim: scrolled content dissolves under the clock instead of colliding with it.
        .overlay(alignment: .top) {
            LinearGradient(stops: [
                .init(color: OnboardingStyle.canvas(colorScheme), location: 0),
                .init(color: OnboardingStyle.canvas(colorScheme), location: topInset / (topInset + 16)),
                .init(color: OnboardingStyle.canvas(colorScheme).opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
                .frame(height: topInset + 16)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("onboarding.reveal.scroll")
        #if DEBUG
        .task {
            let args = ProcessInfo.processInfo.arguments
            let target = args.contains("--reveal-scroll-plan") ? "plan"
                : args.contains("--reveal-scroll-podium") ? "podium"
                : args.contains("--reveal-scroll-week-one") ? "week-one" : nil
            if let target {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                proxy.scrollTo(target, anchor: .top)
            }
        }
        #endif
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Theme.Space.sm) {
                Text("Your plan is the start. Coaching continues as you train.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                OnboardingCTA(title: "Continue with Momentum Pro") { onContinue() }
                    .accessibilityIdentifier("onboarding.reveal.continue")
                    // The ink capsule catches the light once as it settles — the same band that
                    // crossed the tiles, so the page's one light source is consistent.
                    .overlay { sheenBand(ctaSheen, strength: 0.28).clipShape(Capsule()) }
            }
            .opacity(reduceMotion ? 1 : ctaIn)
            .scaleEffect(reduceMotion ? 1 : 0.97 + ctaIn * 0.03)
            .offset(y: reduceMotion ? 0 : 14 * (1 - ctaIn))
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, Theme.Space.md)
            .padding(.bottom, Theme.Space.sm)
            // ONE fade, owned by the inset: clear → canvas rising above it, bled past the
            // column and under the home indicator. (A separate scroll-edge overlay plus an
            // opaque button background left a hairline seam between the two while scrolling —
            // owner report 2026-08-27.) The stop is pulled all the way up to 0.24 — roughly
            // where the inset's own content starts, given the `-xl` bleed above it, so the CTA
            // always lands on a clean bed instead of plan content ghosting underneath it.
            .background {
                LinearGradient(stops: [.init(color: OnboardingStyle.canvas(colorScheme).opacity(0), location: 0),
                                       .init(color: OnboardingStyle.canvas(colorScheme), location: 0.24),
                                       .init(color: OnboardingStyle.canvas(colorScheme), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .padding(.top, -Theme.Space.xl)
                    .padding(.horizontal, -Theme.Space.xxl)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        // The page rises under the overture: a transform on the whole page, so the first frame
        // the athlete sees of it is already in motion toward its rest.
        .opacity(reduceMotion ? 1 : pageIn)
        .scaleEffect(reduceMotion ? 1 : 0.94 + pageIn * 0.06)
        .offset(y: reduceMotion ? 0 : 28 * (1 - pageIn))
        // Act I, over everything. Taps pass straight through: nothing on this page ever waits
        // on a flourish, and the walkers tap the CTA the moment it exists.
        .overlay {
            if overtureMounted, !reduceMotion {
                RevealOverture(name: overtureName, letters: titleLetters, line: titleLine,
                               sheen: titleSheen, exit: overtureExit)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .onAppear(perform: animateIn)
        .onDisappear {
            sequence?.cancel()
            settleArrival()
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced {
                sequence?.cancel()
                settleArrival()
            }
        }
        }
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
    /// "plan ready" seal with a drawn check, then the headline in the display face — "Your plan,"
    /// and the athlete's name on its own line in the brand gradient, the one place color enters
    /// the type. Below it, the outcome sentence.
    private var hero: some View {
        Clocked(t: heroIn) { h in
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                // Drawn, not stamped. This badge is the first thing on the page and its whole job
                // is to say "done" — so it does the gesture rather than asserting it.
                DrawnCheck(progress: checkDraw).frame(width: 14, height: 14)
                Text("PLAN READY")
                    .font(.rounded(11, weight: .bold)).tracking(1.6)
                    .foregroundStyle(Theme.inkSecondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .raised(Capsule())
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(colors: [Theme.iridescent[1], Theme.purple.opacity(0.72),
                                            Theme.iridescent[2]],
                                   startPoint: .leading, endPoint: .trailing),
                    lineWidth: 1
                )
                .opacity(0.72)
            }
            // The halo is ceremonial motion, not layout. Keeping it in the background lets its
            // rings breathe outside the seal without leaving a 92-point hole in the settled page.
            .background {
                PlanArrivalHalo(progress: arrivalHalo)
                    .frame(width: 180, height: 72)
            }
            .opacity(revealStage(h, 0.00, 0.32))
            .scaleEffect(0.82 + revealStage(h, 0.00, 0.32) * 0.18)
            VStack(spacing: 0) {
                Text("Your plan,")
                    .font(.display(44, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                // The one moment on this page that is purely about THEM, so it is the one thing
                // given a specular pass. The band is masked to the letterforms, so the light moves
                // through the name rather than over a rectangle containing it.
                heroNameText
                    .foregroundStyle(LinearGradient(colors: [Theme.purple, Color(hex: "B48CF2"), Theme.iridescent[1]],
                                                    startPoint: .leading, endPoint: .trailing))
                    .overlay { sheenBand(nameSheen).mask(heroNameText) }
            }
            .tracking(-1.0)
            .lineLimit(1).minimumScaleFactor(0.7)
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(planReadyTitle)
            .accessibilityAddTraits(.isHeader)
            .opacity(revealStage(h, 0.16, 0.42))
            .scaleEffect(0.965 + revealStage(h, 0.16, 0.42) * 0.035)
            .offset(y: 12 * (1 - revealStage(h, 0.16, 0.42)))
            Text(vm.projectedOutcome())
                .font(.rounded(15, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Space.sm)
                .opacity(revealStage(h, 0.42, 0.42))
                .offset(y: 10 * (1 - revealStage(h, 0.42, 0.42)))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.md)
        }
    }

    /// Stagger one coordinated 0…1 hero animation without starting independent animations that
    /// can drift apart under load. The values stay clamped, including during spring overshoot.
    /// `clock` is the INTERPOLATED hero value (from `Clocked`), never the state itself.
    private func revealStage(_ clock: Double, _ start: Double, _ span: Double) -> Double {
        if reduceMotion { return 1 }
        return min(1, max(0, (clock - start) / max(0.001, span)))
    }

    /// "Maya." when we have a first name, "ready." otherwise.
    /// One definition, drawn twice: once as the name, once as the mask its light travels through.
    private var heroNameText: some View {
        Text(heroName).font(.display(44, weight: .semibold))
    }

    private var firstName: String? {
        vm.name.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
    }

    private var heroName: String { firstName.map { "\($0)." } ?? "ready." }

    /// The overture writes the name alone, large. Without one it writes the word the page is
    /// about instead — "Ready" — rather than a placeholder that admits the field was empty.
    private var overtureName: String { firstName ?? "Ready" }

    /// Kept for the walkers, which look for this text on the page.
    private var planReadyTitle: String {
        firstName.map { "Your plan is ready, \($0)" } ?? "Your plan is ready"
    }

    // MARK: The block, as terrain

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
            let cap = "Peaks at \(planDistance(peak)) in week \((m.firstIndex(of: peak) ?? 0) + 1)"
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
            VStack(alignment: .leading, spacing: Theme.Space.md + 2) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        sectionLabel("YOUR PATH")
                        Spacer()
                        Text("\(data.values.count) weeks")
                            .font(.rounded(13, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Theme.inkSecondary)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Theme.tintedField))
                    }
                    Text(pathGoalTitle)
                        .font(.display(24, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(vm.goal.planSubtitle)
                        .font(.rounded(14, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                AscentCurve(values: data.values, peakIndex: peakIdx, raceWeek: data.raceWeek,
                            peakLabel: vm.running ? planDistance(maxV) : "\(Int(maxV)) sessions",
                            destinationLabel: pathGoalLabel,
                            destinationSystemImage: vm.goal.planSystemImage,
                            progress: reduceMotion ? 1 : curveIn,
                            calloutIn: reduceMotion || calloutIn,
                            arrival: reduceMotion ? 1 : pathArrival,
                            gleam: reduceMotion ? 1 : curveGleam)
                    .frame(height: 192)
                if !data.caption.isEmpty {
                    // "Peaks at 13.5 mi in week 6" is the pill's own sentence, so it arrives WITH
                    // the pill. Reading the caption before the chart has said anything is reading
                    // the answer before the question.
                    Text(data.caption)
                        .font(.rounded(Theme.FontSize.caption, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(calloutIn || reduceMotion ? 1 : 0)
                }
            }
            .padding(Theme.Space.md + 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .raised(RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous))
        }
    }

    /// Short enough to sit at the end of the curve. The longer coaching rationale lives above it.
    private var pathGoalLabel: String {
        if vm.goal == .raceDistance, let race = vm.raceDistance {
            return vm.goalTimeLabel.map { "\($0) \(race.label)" } ?? race.label
        }
        return switch vm.goal {
        case .endurance: "MORE ENDURANCE"
        case .stayConsistent: "CONSISTENCY"
        case .generalFitness: "RUNNING FITNESS"
        case .loseFat: "FITTER + LEANER"
        case .buildMuscle: "MORE MUSCLE"
        case .getStronger: "STRONGER RUNNER"
        case .raceDistance: "RACE READY"
        }
    }

    private var pathGoalTitle: String {
        if vm.goal == .raceDistance, let race = vm.raceDistance {
            return "Road to your \(race.label)"
        }
        return vm.goal.planLabel
    }

    /// A planned weekly volume, written the way a coach writes one.
    ///
    /// `Formatters.distance` carries significant precision because it is built for LOGGED runs,
    /// where 5.03 mi is a fact. A week's planned volume is a target, so two decimals on it claim
    /// an accuracy the plan does not have and never intended. Half-unit steps below ten, whole
    /// units above — the same grammar `RunRounding` already uses for the sessions these totals
    /// are made of.
    private func planDistance(_ meters: Double) -> String {
        let imperial = distanceUnit.resolved() == .imperial
        let value = imperial ? meters / Formatters.metersPerMile : meters / 1_000
        let step = value >= 10 ? 1.0 : 0.5
        let snapped = (value / step).rounded() * step
        let numeral = snapped == snapped.rounded()
            ? String(Int(snapped.rounded()))
            : String(format: "%.1f", snapped)
        return "\(numeral) \(imperial ? "mi" : "km")"
    }

    // MARK: Stat tiles

    private var statTiles: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                statTile(shownWeeks, "WEEKS", 0) { "\(Int($0.rounded()))" }
                statTile(shownDays, "DAYS A WEEK", 1) { "\(Int($0.rounded()))" }
                statTile(shownSessions, "SESSIONS", 2) { "\(Int($0.rounded()))" }
            }
            if vm.running, let s = peakWeekStats {
                HStack(spacing: 12) {
                    textTile(planDistance(s.volumeM), "PEAK WEEK", 3)
                    textTile(planDistance(s.longestM), "LONGEST RUN", 4)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(planWeekCount) weeks, \(vm.daysPerWeek) days per week, \(totalSessions) sessions")
        .onScrollVisibilityChange(threshold: 0.2) { visible in
            tilesOnScreen = visible
            guard visible, !statsReached else { return }
            statsReached = true
            startStats()
        }
    }

    /// Deal the tiles, then tally them in the order the light crosses them. Runs once, at the
    /// later of "the athlete can see them" and "their beat in the arrival" — so a tall phone gets
    /// them in sequence and a small one gets them the moment they scroll up, never a page that
    /// has already finished counting behind the fold.
    private func startStats() {
        guard !statsStarted, !reduceMotion, statsReached, let began = revealClock else { return }
        statsStarted = true
        let d = max(0, statsBeat - Date().timeIntervalSince(began))
        withAnimation(.easeOut(duration: 1.05).delay(d)) { statsIn = 1 }
        withAnimation(.easeOut(duration: 0.92).delay(d + 0.24)) { shownWeeks = Double(planWeekCount) }
        withAnimation(.easeOut(duration: 0.92).delay(d + 0.37)) { shownDays = Double(vm.daysPerWeek) }
        withAnimation(.easeOut(duration: 0.92).delay(d + 0.50)) { shownSessions = Double(totalSessions) }
        withAnimation(.easeInOut(duration: 1.15).delay(d + 0.54)) { tileSheen = 1 }
    }

    /// The tiles' light and their deal are both derived from ONE clock each, inside animatable
    /// views (`SheenBand`, `TileDeal`, `RevealTileGhost`), so every tile reads its own slice per
    /// frame: one wave crossing the row, each tile a beat behind the last.
    private var tileSheenClock: Double { reduceMotion ? 10 : tileSheen }
    private var tileDealClock: Double { reduceMotion ? 10 : statsIn }

    /// The band is clipped to the tile's OWN shape rather than the tile being clipped to the band:
    /// clipping the tile would take its contact shadow with it, and the raised material is the
    /// whole reason these read as objects.
    private func tileShape() -> RoundedRectangle {
        RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous)
    }

    /// What each tile is actually counting, drawn as quiet texture under its number.
    private func ghost(for label: String) -> RevealTileGhost.Kind? {
        switch label {
        case "WEEKS": .weeks(weekly.values)
        case "DAYS A WEEK": .days(trainingWeekdays)
        case "SESSIONS": .sessions(totalSessions)
        default: nil
        }
    }

    /// The weekday indices (0 = Monday) the athlete actually trains, read off week one rather than
    /// assumed from the count — a 4-day athlete's four days are a specific four.
    private var trainingWeekdays: Set<Int> {
        guard let first = weeksGrouped.first else { return [] }
        let cal = Calendar.current
        return Set(first.sessions.map { (cal.component(.weekday, from: $0.date) + 5) % 7 })
    }

    private func statTile(_ value: Double, _ label: String, _ index: Int,
                          _ format: @escaping (Double) -> String) -> some View {
        // The art is a ROW OF THE STACK, not a background. It used to be a `.background`, which
        // meant it shared the tile's box with the type and the label sat on top of the bars —
        // "WEEKS" across the first two weeks, "SESSIONS" across the dot grid (owner, 2026-08-29).
        // Laid out in sequence it cannot collide, whatever the label's length.
        VStack(spacing: 4) {
            AnimatedCounter(value: value, format: format)
                .font(.display(30, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label).font(.rounded(10, weight: .bold)).tracking(1.0).foregroundStyle(Theme.inkTertiary)
                .lineLimit(1).minimumScaleFactor(0.8)
            if let kind = ghost(for: label) {
                RevealTileGhost(kind: kind, clock: tileSheenClock, index: index, alive: tilesOnScreen)
                    .frame(height: 15)
                    .padding(.horizontal, 12)
                    .padding(.top, 3)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity).frame(height: 104)
        .raised(tileShape())
        .overlay { sheenBand(tileSheenClock, index: index).clipShape(tileShape()) }
        .modifier(TileDeal(clock: tileDealClock, index: index))
    }

    private func textTile(_ value: String, _ label: String, _ index: Int) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.display(24, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.rounded(10, weight: .bold)).tracking(1.0).foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity).frame(height: 84)
        .raised(tileShape())
        .overlay { sheenBand(tileSheenClock, index: index).clipShape(tileShape()) }
        .modifier(TileDeal(clock: tileDealClock, index: index))
    }

    // MARK: Reflections

    private var reflectionChips: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm + 2) {
            sectionLabel("BUILT AROUND YOU")
            // One at a time, in order. These are the athlete's own answers handed back to them,
            // and a block of them appearing at once reads as a list that was already written.
            // Arriving one after another reads as the plan being assembled out of what they said.
            Clocked(t: chipsIn) { c in
            FlowLayout(spacing: 10) {
                ForEach(Array(vm.reflections().enumerated()), id: \.element) { i, chip in
                    let lit = reduceMotion ? 1 : min(1, max(0, (c - Double(i) * 0.09) / 0.34))
                    Text(chip)
                        .font(.rounded(14, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .raised(Capsule())
                        .scaleEffect(0.88 + 0.12 * lit)
                        .opacity(lit)
                }
            }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The one-at-a-time cascade belongs to the SECTION's arrival, not to the page's — these
        // chips are usually below the fold, and a stagger that already ran is just a block.
        .onScrollVisibilityChange(threshold: 0.12) { visible in
            guard visible, chipsIn == 0, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.5)) { chipsIn = 1 }
        }
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

    /// Use the generated opening schedule, including any split or availability compromises.
    @ViewBuilder
    private var trainingBriefing: some View {
        if let first = weeksGrouped.first {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                sectionLabel("YOUR TRAINING BRIEFING")
                Text(openingSchedule(first.sessions))
                    .font(.rounded(15, weight: .semibold))
                    .monospacedDigit().foregroundStyle(Theme.ink)
                Text(vm.calibrationMode == .time
                     ? "Starting paces from your recent result. Refined through your sessions and feedback."
                     : "Starting effort from your answers. Refined through your sessions and feedback.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.md)
            .onboardingCard()
        }
    }

    private func openingSchedule(_ sessions: [PlannedSession]) -> String {
        let days = Set(sessions.map { Calendar.current.startOfDay(for: $0.date) }).sorted()
        let labels = days.map { $0.formatted(.dateTime.weekday(.abbreviated)) }.joined(separator: " · ")
        return "\(days.count) training days to begin\n\(labels)"
    }

    private var animatedTrainingPath: some View {
        blockCurveCard
            .opacity(reduceMotion ? 1 : pathIn)
            .scaleEffect(reduceMotion ? 1 : 0.955 + pathIn * 0.045, anchor: .top)
            .offset(y: reduceMotion ? 0 : 26 * (1 - pathIn))
            .onScrollVisibilityChange(threshold: 0.08) { visible in
                pathReached = visible
                if visible { startPath() }
            }
            // A single aurora pulse makes the generated plan feel like the thing that just
            // arrived, then spends itself completely so the chart is quiet and readable.
            // One bell-shaped flash: invisible at 0, brightest halfway, invisible at rest.
            // Derived per FRAME (`Clocked`) — computed in the body it would read sin(π) = 0
            // on the very first frame and the pulse would never exist.
            .background {
                Clocked(t: artifactGlow) { g in
                    RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous)
                        .fill(LinearGradient(colors: Theme.iridescentDeep,
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .blur(radius: 26)
                        .scaleEffect(0.94 + g * 0.10)
                        .opacity(max(0, sin(g * .pi)) * 0.36)
                }
            }
            .overlay {
                Clocked(t: artifactGlow) { g in
                    RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous)
                        .strokeBorder(LinearGradient(colors: Theme.iridescentDeep,
                                                     startPoint: .leading, endPoint: .trailing),
                                      lineWidth: 1.5)
                        .scaleEffect(0.99 + g * 0.025)
                        .opacity(max(0, sin(g * .pi)) * 0.85)
                }
            }
    }

    private var detailedPlan: some View {
        VStack(spacing: Theme.Space.lg) {
                firstWeek.id("week-one")
                statTiles
                // Below the fold, everything arrives WHEN THE ATHLETE DOES. `.reveal()` runs off
                // `onAppear`, and in a non-lazy stack inside a ScrollView that fires for every
                // child at mount — so the chips, the first week and the whole ladder used to play
                // their entrance against the inside of the screen, seconds before anyone scrolled
                // to them. Arriving to find it already finished is the difference between a page
                // that assembles for you and a page that was assembled before you got there.
                if let weeks = vm.weeksToRace { raceCountdown(weeks).revealOnScroll() }
                reflectionChips.revealOnScroll()
                if vm.intensity == .podium, vm.running { podiumOutlook.revealOnScroll().id("podium") }
                laterWeeks.id("plan").revealOnScroll()
        }
    }

    // MARK: Week 1 — the seven-day strip + the sessions

    @ViewBuilder
    private var firstWeek: some View {
        if let first = weeksGrouped.first {
            VStack(alignment: .leading, spacing: Theme.Space.sm + 2) {
                sectionLabel("YOUR FIRST WEEK")
                WeekStrip(sessions: first.sessions, fill: reduceMotion ? 1 : stripFill)
                    .onScrollVisibilityChange(threshold: 0.5) { visible in
                        guard visible, stripFill == 0, !reduceMotion else { return }
                        withAnimation(.easeOut(duration: 0.75)) { stripFill = 1 }
                    }
                // The week deals itself out, a session at a time. Capped at six beats: past that
                // the last row is waiting on an animation instead of on the reader.
                VStack(spacing: 10) {
                    ForEach(Array(first.sessions.enumerated()), id: \.element.persistentModelID) { i, session in
                        PlanSessionCard(session: session, distanceUnit: distanceUnit)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("onboarding.reveal.session.\(i)")
                            .revealOnScroll(Double(min(i, 6)) * 0.055)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Later weeks — the block outlook

    @ViewBuilder
    private var laterWeeks: some View {
        let rest = Array(weeksGrouped.dropFirst())
        if !rest.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("THE WEEKS AHEAD")
                Text("Your volume and training rhythm through the rest of the block.")
                    .font(.rounded(14, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                let ladderPeak = max(rest.map(weekVolume).max() ?? 1, 0.0001)
                let blockPeak = max(weeksGrouped.map(weekVolume).max() ?? 1, 0.0001)
                VStack(spacing: 0) {
                    ForEach(Array(rest.enumerated()), id: \.element.week) { i, group in
                        if i > 0 {
                            Rectangle()
                                .fill(Theme.hairline)
                                .frame(height: 0.5)
                                .padding(.horizontal, 18)
                        }
                        let v = weekVolume(group)
                        let isPeak = v >= blockPeak - 0.0001
                        VStack(spacing: 14) {
                            HStack(alignment: .top, spacing: Theme.Space.md) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Week \(group.week)")
                                        .font(.rounded(12, weight: .bold))
                                        .tracking(1.2)
                                        .textCase(.uppercase)
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.inkTertiary)
                                    Text(weekDateRange(group))
                                        .font(.rounded(15, weight: .semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.ink)
                                }
                                Spacer(minLength: Theme.Space.sm)
                                if isPeak {
                                    Text("PEAK")
                                        .font(.rounded(9, weight: .bold))
                                        .tracking(0.8)
                                        .foregroundStyle(Theme.purpleDeep)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 5)
                                        .background(Capsule().fill(Theme.purpleTint))
                                }
                                Text(weekSummary(group.sessions))
                                    .font(.display(22, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.ink)
                                    .frame(minWidth: 64, alignment: .trailing)
                            }

                            HStack(spacing: Theme.Space.sm) {
                                Text(weekWorkMix(group.sessions).uppercased())
                                    .font(.rounded(10, weight: .bold))
                                    .tracking(0.65)
                                    .foregroundStyle(Theme.inkTertiary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                Spacer(minLength: Theme.Space.sm)
                                WeekStrip(sessions: group.sessions, compact: true)
                            }

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.hairline)
                                    Capsule()
                                        .fill(isPeak ? Theme.purple : Theme.purple.opacity(0.38))
                                        .frame(width: max(12, geo.size.width * min(1, v / ladderPeak)))
                                }
                            }
                            .frame(height: 3)
                            .allowsHitTesting(false)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("onboarding.reveal.week.\(group.week)")
                    }
                }
                .raised(RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A week's size in the unit the ladder is already showing: metres for a runner, sessions for
    /// everyone else. The bar and the number beside it must never disagree about which week is
    /// biggest, so both read this.
    private func weekVolume(_ group: (week: Int, sessions: [PlannedSession])) -> Double {
        if vm.running {
            let m = group.sessions.compactMap(\.targetDistanceM).reduce(0, +)
            if m > 0 { return m }
        }
        return Double(group.sessions.count)
    }

    private func weekSummary(_ sessions: [PlannedSession]) -> String {
        if vm.running {
            let m = sessions.reduce(0.0) { $0 + ($1.discipline == .running ? ($1.targetDistanceM ?? 0) : 0) }
            if m > 0 { return planDistance(m) }
        }
        return "\(sessions.count) sess."
    }

    /// The block is bucketed from the first generated session, so the dates shown here use that
    /// same seven-day anchor. The label is compact but unambiguous across a month boundary.
    private func weekDateRange(_ group: (week: Int, sessions: [PlannedSession])) -> String {
        guard let planStart = weeksGrouped.first?.sessions.map(\.date).min(),
              let start = Calendar.current.date(byAdding: .day, value: (group.week - 1) * 7,
                                                to: planStart),
              let end = Calendar.current.date(byAdding: .day, value: 6, to: start) else {
            return "UPCOMING"
        }
        let startMonth = start.formatted(.dateTime.month(.abbreviated)).uppercased()
        let endMonth = end.formatted(.dateTime.month(.abbreviated)).uppercased()
        let startDay = start.formatted(.dateTime.day())
        let endDay = end.formatted(.dateTime.day())
        return startMonth == endMonth
            ? "\(startMonth) \(startDay)–\(endDay)"
            : "\(startMonth) \(startDay)–\(endMonth) \(endDay)"
    }

    /// A truthful one-line description of what fills the seven day rhythm beside it.
    private func weekWorkMix(_ sessions: [PlannedSession]) -> String {
        let runs = sessions.filter { $0.discipline == .running }.count
        let strength = sessions.filter { $0.discipline == .strength }.count
        let rides = sessions.filter { $0.discipline == .cycling }.count
        let walks = sessions.filter { $0.discipline == .walking }.count
        var parts: [String] = []
        if runs > 0 { parts.append("\(runs) run\(runs == 1 ? "" : "s")") }
        if strength > 0 { parts.append("\(strength) strength") }
        if rides > 0 { parts.append("\(rides) ride\(rides == 1 ? "" : "s")") }
        if walks > 0 { parts.append("\(walks) walk\(walks == 1 ? "" : "s")") }
        return parts.isEmpty ? "\(sessions.count) sessions" : parts.joined(separator: " · ")
    }

    // MARK: Reveal orchestration

    /// The whole arrival as one timed sequence, in seconds from appear. Every beat is placed
    /// relative to `T`, the moment the overture lifts — which depends on how long the name is,
    /// since each letter takes its own beat to land.
    private func animateIn() {
        guard !arrivalStarted else { return }
        arrivalStarted = true
        guard !reduceMotion else {
            settleArrival()
            return
        }
        Haptics.warm()

        // ACT I — the overture. One linear clock for the letters; each reads its own eased slice.
        let letterCount = max(1, overtureName.count)
        let lettersEnd = RevealOverture.lettersStart + RevealOverture.stagger * Double(letterCount - 1)
            + RevealOverture.letterDuration
        withAnimation(.linear(duration: lettersEnd).delay(0)) { titleLetters = lettersEnd }
        withAnimation(Motion.pen(0.55).delay(lettersEnd - 0.30)) { titleLine = 1 }
        withAnimation(.easeInOut(duration: 0.80).delay(lettersEnd - 0.18)) { titleSheen = 1 }
        // The card lifts away; the page rises under it. They overlap so there is never a frame
        // with nothing on it.
        let T = lettersEnd + 0.34
        withAnimation(.timingCurve(0.55, 0.0, 0.25, 1.0, duration: 0.66).delay(T)) { overtureExit = 1 }
        withAnimation(.spring(response: 0.92, dampingFraction: 0.86).delay(T - 0.06)) { pageIn = 1 }

        // ACT II — the ascent. Acknowledgement, identity, the artifact, then its proof. The card
        // lands before its terrain is run; counters settle in the same direction as their sheen.
        withAnimation(Motion.pen(0.96).delay(T + 0.16)) { heroIn = 1 }
        withAnimation(.easeOut(duration: 0.52).delay(T + 0.26)) { checkDraw = 1 }
        withAnimation(.easeOut(duration: 1.15).delay(T + 0.22)) { arrivalHalo = 1 }
        withAnimation(.easeInOut(duration: 0.92).delay(T + 0.58)) { nameSheen = 1 }
        withAnimation(.spring(response: 0.74, dampingFraction: 0.80).delay(T + 0.46)) { artifactIn = 1 }
        // The tiles: see `startStats` — their beat is here, but they wait to be seen.
        revealClock = Date()
        statsBeat = T + 0.98
        startStats()
        withAnimation(.spring(response: 0.56, dampingFraction: 0.78).delay(T + 1.42)) { ctaIn = 1 }
        withAnimation(.easeInOut(duration: 0.9).delay(T + 1.9)) { ctaSheen = 1 }

        // The haptics belong to the moments: a tick as each letter lands and a press as the page
        // settles. The reveal finishes quietly, in the same restrained grammar as the interview.
        sequence?.cancel()
        sequence = Task { @MainActor in
            let clock = ContinuousClock()
            let start = clock.now
            func at(_ s: Double) async -> Bool {
                let target = start + .seconds(s)
                if target > clock.now { try? await Task.sleep(until: target, clock: clock) }
                return !Task.isCancelled
            }
            for i in 0..<letterCount {
                guard await at(RevealOverture.lettersStart + RevealOverture.stagger * Double(i) + 0.12) else { return }
                Haptics.selection()
            }
            guard await at(T + 0.46) else { return }
            Haptics.light()
            guard await at(T + 0.8) else { return }
            overtureMounted = false
            startPath()
        }
    }

    private func startPath() {
        guard pathReached, !overtureMounted, !pathStarted, !reduceMotion else { return }
        pathStarted = true
        withAnimation(.spring(response: 0.62, dampingFraction: 0.86)) { pathIn = 1 }
        withAnimation(.easeInOut(duration: 1.1)) { artifactGlow = 1 }
        withAnimation(Motion.pen(1.4).delay(0.15)) { curveIn = 1 }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(1.2)) { calloutIn = true }
        withAnimation(.easeOut(duration: 0.72).delay(1.35)) { pathArrival = 1 }
        withAnimation(.easeInOut(duration: 0.86).delay(1.7)) { curveGleam = 1 }
    }

    /// Finish presentation on interruption or an accessibility change. Returning from checkout
    /// never replays the overture or leaves delayed animation state over the readable plan.
    private func settleArrival() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            overtureMounted = false
            shownWeeks = Double(planWeekCount); shownDays = Double(vm.daysPerWeek)
            shownSessions = Double(totalSessions); curveIn = 1; calloutIn = true
            nameSheen = 1; curveGleam = 1; tileSheen = 1; stripFill = 1; ctaSheen = 1
            checkDraw = 1; chipsIn = 1; heroIn = 1; artifactIn = 1; statsIn = 1; ctaIn = 1
            arrivalHalo = 1; artifactGlow = 1; pathArrival = 1; pageIn = 1; pathIn = 1
            statsStarted = true; pathStarted = true
        }
    }
}

// MARK: - Act I: the overture

/// The title card: the athlete's own name, alone, in the display face — each letter rising out
/// of blur into place, a start line drawing outward beneath it, one specular pass through the
/// letterforms. Then the whole card lifts, shrinks and dissolves toward the headline that carries
/// the same name on the page beneath, so the two read as one object changing scale.
///
/// Everything here is a transform on an already-laid-out glyph: blur, opacity, offset and scale.
/// Nothing is typed in, nothing reflows.
private struct RevealOverture: View, Animatable {
    let name: String
    /// The letter clock, in seconds — each letter reads its own eased slice of it.
    var letters: Double
    var line: Double
    var sheen: Double
    var exit: Double

    /// All four clocks interpolate, so every glyph, the line and the exit derive per frame.
    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get { AnimatablePair(AnimatablePair(letters, line), AnimatablePair(sheen, exit)) }
        set { letters = newValue.first.first; line = newValue.first.second
              sheen = newValue.second.first; exit = newValue.second.second }
    }

    static let lettersStart = 0.14
    static let stagger = 0.06
    static let letterDuration = 0.58

    @Environment(\.colorScheme) private var colorScheme

    private var glyphs: [Character] { Array(name) }

    /// A long name gets a smaller face rather than a wrapped or clipped one.
    private var pointSize: CGFloat {
        let n = CGFloat(max(glyphs.count, 1))
        return max(34, min(68, 68 * 6.5 / n))
    }

    /// Eased arrival for glyph `i`: 0 before its beat, 1 once landed.
    private func landed(_ i: Int) -> Double {
        let start = Self.lettersStart + Self.stagger * Double(i)
        let p = min(1, max(0, (letters - start) / Self.letterDuration))
        return 1 - pow(1 - p, 3)
    }

    /// The eyebrow and the line share the letter clock rather than owning animations of their own.
    private var eyebrowIn: Double { min(1, max(0, letters / 0.42)) }

    private var exitEase: Double { exit * exit * (3 - 2 * exit) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                OnboardingStyle.canvas(colorScheme)
                // The paywall's field, faint — the same air the page under this one breathes.
                AiryField(intensity: colorScheme == .dark ? 0.4 : 0.6, paintsBackground: false)
                    .mask(LinearGradient(colors: [.black, .black.opacity(0.4), .clear],
                                         startPoint: .top, endPoint: .bottom))
                VStack(spacing: 22) {
                    Text("YOUR PLAN")
                        .font(.rounded(12, weight: .bold)).tracking(3.2)
                        .foregroundStyle(Theme.inkTertiary)
                        .opacity(eyebrowIn)
                        .offset(y: 8 * (1 - eyebrowIn))
                    nameLine
                        .overlay { SheenBand(clock: sheen, strength: 0.95).mask(nameLine) }
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.purple, Theme.iridescent[1]],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: 120, height: 2)
                        .scaleEffect(x: max(0.001, line), y: 1, anchor: .center)
                        .opacity(min(1, line * 3))
                }
                .padding(.horizontal, Theme.Space.lg)
                // The exit: up toward where the headline will be, smaller, softer, gone.
                .scaleEffect(1 - 0.34 * exitEase)
                .offset(y: -geo.size.height * 0.26 * exitEase)
                .blur(radius: 10 * exitEase)
                .opacity(1 - min(1, exitEase * 1.35))
            }
            .opacity(1 - exitEase)
        }
        .accessibilityHidden(true)
    }

    /// One definition, drawn twice: once as the name, once as the mask its light travels through.
    private var nameLine: some View {
        HStack(spacing: -1) {
            ForEach(Array(glyphs.enumerated()), id: \.offset) { i, ch in
                let p = landed(i)
                Text(String(ch))
                    .font(.display(pointSize, weight: .semibold))
                    .tracking(-1.5)
                    .foregroundStyle(Theme.ink)
                    .opacity(p)
                    .blur(radius: 14 * (1 - p))
                    .scaleEffect(1.10 - 0.10 * p, anchor: .bottom)
                    .offset(y: 26 * (1 - p))
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

}

// MARK: - Per-frame derivation

/// SwiftUI interpolates only `Animatable` data: a value derived in a view's body from an animated
/// state reads its END value on the first frame of the animation, and every stage computed from it
/// collapses into a single fade. Wrapping the subtree in this view — animatable over one clock —
/// makes the closure run per frame with the interpolated value, so staggers, bells and staged
/// entrances actually happen. (`AnimatedCounter` is the same idea, for one number.)
private struct Clocked<Content: View>: View, Animatable {
    var t: Double
    @ViewBuilder let content: (Double) -> Content

    var animatableData: Double {
        get { t }
        set { t = newValue }
    }

    var body: some View { content(t) }
}

/// A narrow specular band travelling left to right, for masking onto whatever should catch the
/// light. `progress` runs 0…1 and the band starts and ends fully off the view, so both ends of the
/// animation are a clean no-op — nothing to fade in or out. With an `index`, the band reads its
/// own slice of a shared clock: one light crossing a row of tiles, each a beat behind the last.
///
/// `plusLighter` rather than a white fill: on the raised tiles it reads as light moving across a
/// surface, and on the name it brightens the gradient instead of painting over it.
private struct SheenBand: View, Animatable {
    var clock: Double
    var index: Int? = nil
    var strength = 0.9

    var animatableData: Double {
        get { clock }
        set { clock = newValue }
    }

    private var progress: Double {
        guard let index else { return clock }
        return min(1, max(0, (clock - Double(index) * 0.11) / 0.62))
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let band = max(56, w * 0.32)
            LinearGradient(colors: [.white.opacity(0), .white.opacity(strength), .white.opacity(0)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: band)
                .offset(x: -band + (w + band * 2) * progress)
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - The tiles standing up

/// A stat tile is dealt onto the page: it stands up from lying almost flat (a perspective tilt
/// about its top edge), rising and brightening as it does. A card that only fades in is a layer;
/// one that stands up is an object being placed.
private struct TileDeal: ViewModifier, Animatable {
    var clock: Double
    let index: Int
    var animatableData: Double {
        get { clock }
        set { clock = newValue }
    }

    /// The tiles are dealt one after another off one clock; each eases into its rest on its own
    /// slice of it.
    private var progress: Double {
        let p = min(1, max(0, (clock - Double(index) * 0.13) / 0.58))
        return 1 - pow(1 - p, 3)
    }

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(-28 * (1 - progress)), axis: (x: 1, y: 0, z: 0),
                              anchor: .top, perspective: 0.7)
            .offset(y: 18 * (1 - progress))
            .opacity(progress)
    }
}

// MARK: - Arrival halo

/// Three quiet rings spend themselves behind the ready seal. This is the reveal's opening breath:
/// a one-shot expansion, never a loop, and fully gone at rest so the final page stays precise.
private struct PlanArrivalHalo: View, Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        ZStack {
            ring(start: 0.00, span: 0.62, lineWidth: 1.2)
            ring(start: 0.16, span: 0.68, lineWidth: 0.9)
            ring(start: 0.34, span: 0.66, lineWidth: 0.7)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func ring(start: Double, span: Double, lineWidth: CGFloat) -> some View {
        let p = min(1, max(0, (progress - start) / max(span, 0.001)))
        let alpha = sin(p * .pi)
        return Capsule()
            .strokeBorder(
                AngularGradient(colors: [Theme.iridescentDeep[1], Theme.purple,
                                         Theme.iridescentDeep[2], Theme.iridescentDeep[0],
                                         Theme.iridescentDeep[1]], center: .center),
                lineWidth: lineWidth
            )
            .scaleEffect(0.48 + p * 0.76)
            .opacity(alpha * 0.46)
    }
}


// MARK: - The ascent curve

/// The block's weekly volume as terrain. A smooth line over an aurora fill, with a runner glyph
/// that RUNS it as it draws — leaning into the climbs, a comet tail behind it, each week's
/// gridline lighting as it is passed and settling faint again, the peak flaring once, the race
/// week flagged, the goal beacon landing as the runner arrives. Every moving part is a path
/// transform (`trim`) or a transform on a placed view; the geometry is computed once per layout.
///
/// Reduce Motion, and the settled page: the finished terrain, the beacon, the pill — no runner,
/// no tail, no light. The final frame has to be a chart you can read.
private struct AscentCurve: View, Animatable {
    let values: [Double]
    let peakIndex: Int
    let raceWeek: Int?
    /// What the peak IS, for its callout: "13.5 mi" or "5 sessions".
    let peakLabel: String
    let destinationLabel: String
    let destinationSystemImage: String
    var progress: Double
    let calloutIn: Bool
    var arrival: Double
    /// A highlight travelling the finished stroke, 0…1 once. Runs AFTER the runner: a line that
    /// is still being run is already the interesting thing on screen, and two lights on one path
    /// read as a glitch rather than as craft.
    var gleam: Double = 1

    /// The run, the arrival and the gleam all interpolate, so the runner's position, the wake and
    /// the flare are read off the line per frame rather than jumping to their end state.
    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(progress, AnimatablePair(arrival, gleam)) }
        set { progress = newValue.first; arrival = newValue.second.first; gleam = newValue.second.second }
    }
    private let inset: CGFloat = 8
    private let top: CGFloat = 40      // room for the destination pill and the peak callout
    private let axis: CGFloat = 22     // room for week labels

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let pts = points(in: CGSize(width: w, height: h))
            let curve = smoothPath(pts)
            let n = values.count
            let destinationIndex = min(max((raceWeek ?? n) - 1, 0), n - 1)
            let stroke = LinearGradient(colors: [Theme.iridescent[1], Theme.purple, Theme.iridescent[0]],
                                        startPoint: .leading, endPoint: .trailing)
            ZStack(alignment: .topLeading) {
                // Week gridlines. Each one lights as the runner passes and settles back to a
                // whisper — the wake of the run, rather than a grid that was always there.
                ForEach(0..<n, id: \.self) { i in
                    let wake = wakeAt(index: i, count: n)
                    Rectangle()
                        .fill(Theme.purple.opacity(0.05 + 0.34 * wake))
                        .frame(width: 1)
                        .frame(height: h - axis - top, alignment: .top)
                        .offset(x: pts[i].x, y: top)
                }
                // Fill under the curve, revealed with the runner. The mask is a TRANSFORM, not a
                // width: `Rectangle().frame(width: w * progress)` inside a mask is a layout change,
                // and it was not clipping at all — the whole fill stood there complete while the
                // line was still being drawn (caught on video, 2026-08-28). Scaling from the
                // leading edge is also the rule this project holds itself to.
                fillPath(curve, base: h - axis, last: pts.last!, first: pts.first!)
                    .fill(LinearGradient(stops: [
                        .init(color: Theme.purple.opacity(0.30), location: 0),
                        .init(color: Theme.iridescent[1].opacity(0.16), location: 0.55),
                        .init(color: Theme.iridescent[1].opacity(0.0), location: 1),
                    ], startPoint: .top, endPoint: .bottom))
                    .mask(alignment: .leading) {
                        Rectangle().scaleEffect(x: max(0.0001, progress), y: 1, anchor: .leading)
                    }
                // The peak flares once, as the runner crests it: a soft pool of light that blooms
                // and is spent, so the highest week is felt as a moment and not marked as a spot.
                let flare = max(0, sin(min(1, max(0, (progress - peakThreshold + 0.02) / 0.22)) * .pi))
                Circle()
                    .fill(RadialGradient(colors: [Theme.purple.opacity(0.42), Theme.iridescent[1].opacity(0.16), .clear],
                                         center: .center, startRadius: 0, endRadius: 40))
                    .frame(width: 80, height: 80)
                    .scaleEffect(0.6 + 0.6 * flare)
                    .opacity(flare)
                    .position(pts[peakIndex])
                    .blendMode(.plusLighter)
                // The line itself.
                curve.trim(from: 0, to: progress)
                    .stroke(stroke, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .shadow(color: Theme.purple.opacity(0.35), radius: 6, y: 3)
                // The comet tail: the last stretch of the line the runner has just covered, lit
                // and softened, so the run has a wake. Gone the moment the runner arrives.
                if progress > 0.01, progress < 1 {
                    curve.trim(from: max(0, progress - 0.11), to: progress)
                        .stroke(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.95)],
                                               startPoint: .leading, endPoint: .trailing),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .blur(radius: 2.2)
                        .blendMode(.plusLighter)
                }
                // The gleam: a short segment of the SAME path, lit. Travels past 1 so it leaves
                // the line cleanly at the end instead of pooling at the last point.
                if progress >= 1, gleam > 0, gleam < 1 {
                    curve.trim(from: max(0, gleam * 1.16 - 0.14), to: min(1, gleam * 1.16))
                        .stroke(Color.white.opacity(0.92),
                                style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                }
                // The runner. Leans into the slope it is on, and hands over to the beacon on
                // arrival rather than standing on top of it.
                if progress > 0.005, arrival < 1 {
                    let track = CurveTrack(controlPoints: pts)
                    let here = track.point(at: progress)
                    let lean = leanAngle(tangent: track.tangent(at: progress))
                    AscentRunner(lean: lean)
                        .position(here)
                        .opacity(1 - min(1, arrival * 1.6))
                        .scaleEffect(1 - 0.3 * min(1, arrival * 1.6))
                }
                // Three quiet beats make the data read as a journey instead of a chart. They are
                // pinned to the real path and appear only when the run reaches them.
                pathBeat("START", point: pts[0], visible: pathVisibility(at: 0, count: n),
                         width: w, chartHeight: h)
                if peakIndex > 0, peakIndex < destinationIndex {
                    peakCallout(point: pts[peakIndex], width: w)
                }
                let destination = pts[destinationIndex]
                PlanGoalBeacon(progress: arrival, systemImage: destinationSystemImage)
                    .position(destination)
                goalPill(width: w, point: destination)
                // Week labels: first, peak, last, plus sparse ticks — each rising in as the runner
                // passes its week.
                ForEach(0..<n, id: \.self) { i in
                    let tickEvery = n <= 8 ? 1 : (n <= 12 ? 2 : 4)
                    if i == 0 || i == n - 1 || i == peakIndex || i.isMultiple(of: tickEvery) {
                        let vis = pathVisibility(at: i, count: n)
                        Text(i == 0 ? "Wk 1" : "\(i + 1)")
                            .font(.rounded(11, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(i == peakIndex ? Theme.ink : Theme.inkTertiary)
                            .opacity(vis)
                            .offset(y: 5 * (1 - vis))
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

    /// Where along the run (0…1) the peak week sits.
    private var peakThreshold: Double {
        Double(peakIndex) / Double(max(values.count - 1, 1))
    }

    /// How lit week `index`'s gridline is right now: a bell around the moment the runner passes
    /// it, so the light arrives with the runner and fades behind. At rest every line is faint.
    private func wakeAt(index: Int, count: Int) -> Double {
        guard progress < 1 else { return 0 }
        let threshold = Double(index) / Double(max(count - 1, 1))
        let d = (progress - threshold) / 0.09
        guard d > -1, d < 1.6 else { return 0 }
        return max(0, d < 0 ? 1 + d : 1 - d / 1.6)
    }

    /// The runner's lean, from the local slope: uphill leans forward, downhill eases back. Screen
    /// y grows downward, so a climb is a negative dy. Clamped so a steep first week never tips the
    /// glyph over.
    private func leanAngle(tangent: CGVector) -> Double {
        guard tangent.dx > 0.001 else { return 0 }
        let slope = atan2(Double(tangent.dy), Double(tangent.dx)) * 180 / .pi     // negative = climbing
        return max(-18, min(12, slope * 0.55))
    }

    /// A path beat comes alive as the run reaches its week. Its final frame is only a dot and a
    /// whisper of type; no animated clock survives the entrance.
    private func pathBeat(_ title: String, point: CGPoint, visible: Double,
                          width: CGFloat, chartHeight: CGFloat) -> some View {
        HStack(spacing: 4) {
            Circle().fill(Theme.purple).frame(width: 4, height: 4)
            Text(title)
                .font(.rounded(9, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(Theme.inkTertiary)
        }
        .fixedSize()
        .position(x: min(max(point.x, 26), width - 26),
                  y: min(chartHeight - axis - 11, point.y + 20))
        .opacity(visible)
        .scaleEffect(0.86 + 0.14 * visible)
    }

    /// The peak's callout: a small raised pill above the highest week, popping in once the
    /// runner has crested it. It says what the peak IS, not just that it is one.
    private func peakCallout(point: CGPoint, width: CGFloat) -> some View {
        let show = calloutIn ? 1.0 : 0.0
        let halfWidth = min(70.0, max(38.0, Double(peakLabel.count) * 3.6 + 22))
        return HStack(spacing: 4) {
            Text("PEAK")
                .font(.rounded(8, weight: .black)).tracking(0.8)
                .foregroundStyle(Theme.purpleDeep)
            Text(peakLabel)
                .font(.rounded(10, weight: .bold)).monospacedDigit()
                .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .raised(Capsule())
        .fixedSize()
        .position(x: min(max(point.x, CGFloat(halfWidth)), width - CGFloat(halfWidth)),
                  y: max(14, point.y - 24))
        .opacity(show)
        .scaleEffect(0.78 + 0.22 * show, anchor: .bottom)
        .animation(.spring(response: 0.5, dampingFraction: 0.72), value: calloutIn)
    }

    private func pathVisibility(at index: Int, count: Int) -> Double {
        let threshold = Double(index) / Double(max(count - 1, 1))
        return min(1, max(0, (progress - threshold + 0.035) / 0.14))
    }

    private func goalPill(width: CGFloat, point: CGPoint) -> some View {
        let reveal = calloutIn ? min(1, max(0, arrival * 1.7)) : 0
        let halfWidth = min(92.0, max(49.0, Double(destinationLabel.count) * 3.7 + 22))
        return HStack(spacing: 5) {
            Text(destinationLabel.uppercased())
                .font(.rounded(10, weight: .bold))
                .tracking(0.65)
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Color(hex: "1C1C1E")))
        .fixedSize()
        .position(x: min(max(point.x, CGFloat(halfWidth)), width - CGFloat(halfWidth)),
                  y: max(14, point.y - 27))
        .opacity(reveal)
        .scaleEffect(0.80 + 0.20 * reveal, anchor: .bottom)
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

}

/// The curve as a run: the same Catmull-Rom segments the stroke draws, flattened once into an
/// arc-length table so a position can be read at any FRACTION OF THE LINE'S LENGTH — the same
/// quantity `trim` uses — and the runner sits exactly on the pen's tip. (`Path.trimmedPath`'s
/// `currentPoint` reports the path's END, not the trim point, which left the runner parked at the
/// destination for the whole draw.)
private struct CurveTrack {
    private var samples: [CGPoint] = []
    private var cumulative: [CGFloat] = []

    init(controlPoints pts: [CGPoint], stepsPerSegment: Int = 24) {
        guard pts.count > 1 else { return }
        samples.reserveCapacity((pts.count - 1) * stepsPerSegment + 1)
        samples.append(pts[0])
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            for s in 1...stepsPerSegment {
                let t = CGFloat(s) / CGFloat(stepsPerSegment), u = 1 - t
                let x = u*u*u*p1.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*p2.x
                let y = u*u*u*p1.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*p2.y
                samples.append(CGPoint(x: x, y: y))
            }
        }
        cumulative.reserveCapacity(samples.count)
        var total: CGFloat = 0
        cumulative.append(0)
        for i in 1..<samples.count {
            total += hypot(samples[i].x - samples[i - 1].x, samples[i].y - samples[i - 1].y)
            cumulative.append(total)
        }
    }

    /// The index of the last sample at or before `fraction` of the total length, and how far
    /// into the following span that fraction falls.
    private func locate(_ fraction: Double) -> (Int, CGFloat) {
        guard samples.count > 1, let total = cumulative.last, total > 0 else { return (0, 0) }
        let target = total * CGFloat(min(1, max(0, fraction)))
        var lo = 0, hi = cumulative.count - 1
        while lo < hi - 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= target { lo = mid } else { hi = mid }
        }
        let span = cumulative[hi] - cumulative[lo]
        return (lo, span > 0 ? (target - cumulative[lo]) / span : 0)
    }

    func point(at fraction: Double) -> CGPoint {
        guard samples.count > 1 else { return samples.first ?? .zero }
        let (i, f) = locate(fraction)
        let a = samples[i], b = samples[min(i + 1, samples.count - 1)]
        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }

    func tangent(at fraction: Double) -> CGVector {
        guard samples.count > 1 else { return CGVector(dx: 1, dy: 0) }
        let (i, _) = locate(fraction)
        let a = samples[max(0, i - 1)], b = samples[min(i + 2, samples.count - 1)]
        return CGVector(dx: b.x - a.x, dy: b.y - a.y)
    }
}

/// The runner on the terrain: a small white disc with a lavender rim and a soft pool of light
/// beneath it, the running figure inside, leaning with the slope. It is the pen of this chart —
/// so it is drawn as the thing the plan is for, not as a dot.
private struct AscentRunner: View {
    let lean: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Theme.purple.opacity(0.55), .clear],
                                     center: .center, startRadius: 0, endRadius: 22))
                .frame(width: 44, height: 44)
                .blendMode(.plusLighter)
            Circle()
                .fill(.white)
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(Theme.purple, lineWidth: 2.2))
                .shadow(color: Theme.purple.opacity(0.35), radius: 5, y: 2)
            Image(systemName: "figure.run")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.purpleDeep)
                .rotationEffect(.degrees(lean))
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }
}

// MARK: - Seven-day strip

/// Mon…Sun as dots — lavender for a run, ink for a lift, sky for anything else, hollow for rest —
/// so a week's shape reads at a glance without a single word.
private struct WeekStrip: View, Animatable {
    let sessions: [PlannedSession]
    var compact = false
    var animatableData: Double {
        get { fill }
        set { fill = newValue }
    }
    /// 0…1 across the seven days — the first week's strip fills in order, so the athlete watches
    /// their week assemble instead of finding it already there. The compact ladder strips below
    /// pass nothing and render finished; seven rows of dots all counting themselves in would be
    /// noise, not craft.
    var fill: Double = 1

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
            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                let lit = min(1, max(0, (fill - Double(i) * 0.085) / 0.3))
                VStack(spacing: 6) {
                    if !compact {
                        Text(day.letter).font(.rounded(11, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    }
                    dot(day.sessions)
                        .scaleEffect(0.72 + 0.28 * lit)
                        .opacity(lit)
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

// MARK: - Complete first-week session card

/// A plan session showing all of the concrete work: every lift's sets/reps, or a run's mileage,
/// pace, rep breakdown and — for long runs — fueling guidance.
private struct PlanSessionCard: View {
    let session: PlannedSession
    let distanceUnit: DistanceUnit

    var body: some View {
        VStack(spacing: 0) {
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

                }
                .padding(.horizontal, 16).padding(.vertical, 14)

                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Divider().overlay(Theme.hairline)
                    if session.discipline == .strength { strengthDetail } else { runDetail }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .onboardingCard()
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
        return session.runType?.planTitle ?? "Session"
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

// MARK: - Tile ghosts

/// The quiet texture under a stat tile's number: a small, TRUE drawing of the thing the number
/// counts. Six weeks are six ticks at the block's real heights, four days a week are the athlete's
/// four actual weekdays, twenty-four sessions are twenty-four marks.
///
/// The paywall's grammar is that every tile is an illustration of its own subject, and this is that
/// idea kept honest: a number with a picture of itself underneath reads as considered, a number
/// with decoration underneath reads as filler. Held at a whisper (ink at 0.06–0.13) so it is
/// texture the eye finds on the second look, never a second chart competing with the first.
private struct RevealTileGhost: View, Animatable {
    enum Kind {
        case weeks([Double])        // the block's real weekly volumes
        case days(Set<Int>)         // 0 = Monday
        case sessions(Int)
    }

    let kind: Kind
    /// The row's shared light clock; the tile's slice of it is derived below, per frame.
    var clock: Double
    let index: Int
    /// Run the loop. False = hold the still frame: off screen, or Reduce Motion.
    var alive: Bool = true

    var animatableData: Double {
        get { clock }
        set { clock = newValue }
    }

    /// 0…1, left to right, sharing the tile's own light so the drawing arrives with it.
    private var draw: Double { min(1, max(0, (clock - Double(index) * 0.11) / 0.62)) }

    @ReducedMotionPreference private var reduceMotion

    /// Each tile keeps its own clock, and the three periods share no common factor. On matched
    /// clocks the row pulses in unison and reads as one metronome — three drifting loops read as
    /// three things quietly doing their own work, which is what the paywall's marquee gets right.
    private var period: Double {
        switch kind {
        case .weeks: 4.4
        case .days: 3.7
        case .sessions: 5.3
        }
    }

    var body: some View {
        if alive && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                marks(wave: (t.truncatingRemainder(dividingBy: period)) / period)
            }
        } else {
            marks(wave: nil)
        }
    }

    @ViewBuilder
    private func marks(wave: Double?) -> some View {
        switch kind {
        case .weeks(let values): weeks(values, wave)
        case .days(let set): days(set, wave)
        case .sessions(let n): sessions(n, wave)
        }
    }

    /// How much the mark at `i` of `n` is lifted by the passing wave, 0…1.
    ///
    /// The head travels 0→1 over the period and the lift falls off either side of it, so what the
    /// eye sees is one soft crest walking the row rather than marks blinking on and off. The head
    /// runs slightly past 1 before wrapping so the crest leaves the row cleanly instead of
    /// reappearing on top of itself.
    private func lift(_ i: Int, _ n: Int, _ wave: Double?) -> Double {
        guard let wave, n > 0 else { return 0 }
        let head = wave * 1.22 - 0.11
        let d = abs(head - Double(i) / Double(max(n - 1, 1)))
        return max(0, 1 - pow(d / 0.22, 2))
    }

    /// Arrival fraction for mark `i` — the row draws itself in the same direction the tile's light
    /// travels, then the loop takes over.
    private func lit(_ i: Int, _ n: Int) -> Double {
        min(1, max(0, (draw * 1.25 - Double(i) / Double(max(n, 1))) * 4))
    }

    /// Six ticks at the block's real weekly heights. The crest walks them in order, so the loop is
    /// literally the block being worked through a week at a time — and the peak week keeps its own
    /// standing emphasis whether the crest is on it or not, because the peak is a fact about the
    /// plan rather than a moment in the animation.
    private func weeks(_ values: [Double], _ wave: Double?) -> some View {
        let maxV = max(values.max() ?? 1, 0.0001)
        let peak = values.firstIndex(of: values.max() ?? 0) ?? 0
        return GeometryReader { geo in
            let h = geo.size.height
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    // Lavender, not grey. The curve above and the ladder below already speak in
                    // `Theme.purple`; a tile art in ink read as a smudge under the label instead of
                    // as the same plan drawn a third way.
                    let base = i == peak ? 0.62 : 0.26
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Theme.purple.opacity(base + 0.34 * lift(i, values.count, wave)))
                        .frame(height: max(3, h * (0.30 + 0.70 * v / maxV)))
                        .scaleEffect(y: lit(i, values.count), anchor: .bottom)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    /// Seven days, the athlete's own training days filled. The crest walks Monday to Sunday, so the
    /// loop is a week going by — and it lifts ONLY the days they actually train, which is what
    /// makes it read as their week rather than as a light show.
    private func days(_ set: Set<Int>, _ wave: Double?) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { i in
                let trains = set.contains(i)
                let l = trains ? lift(i, 7, wave) : 0
                Circle()
                    .fill(trains ? Theme.purple.opacity(0.42 + 0.45 * l)
                                 : Theme.ink.opacity(0.08))
                    .frame(height: 5.5)
                    .scaleEffect(lit(i, 7) * (1 + 0.28 * l))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// Two rows, so twenty-odd marks stay legible at tile width. Capped at 30: past that the marks
    /// stop being countable and become a smear, and an uncountable count is worse than none.
    /// The crest sweeps both rows as one sequence — session 1 through session 24, in order.
    private func sessions(_ n: Int, _ wave: Double?) -> some View {
        let shown = min(n, 30)
        let perRow = Int(ceil(Double(shown) / 2))
        return VStack(spacing: 2.5) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 2.5) {
                    ForEach(0..<perRow, id: \.self) { col in
                        let i = row * perRow + col
                        Circle()
                            .fill(i < shown ? Theme.purple.opacity(0.30 + 0.42 * lift(i, shown, wave))
                                            : .clear)
                            .frame(height: 3.8)
                            .scaleEffect(lit(i, shown))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

/// The destination lands once and then becomes a perfectly still map pin. Its halo is bell-shaped:
/// invisible before the arrival, brightest during it, and fully spent at rest. That gives the
/// reveal one earned focal moment without leaving a pulsing ornament running over the final page.
private struct PlanGoalBeacon: View, Animatable {
    var progress: Double
    let systemImage: String
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    private var p: Double { min(1, max(0, progress)) }
    private var pulse: Double { max(0, sin(p * .pi)) }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    AngularGradient(colors: [Theme.iridescentDeep[1], Theme.purple,
                                             Theme.iridescentDeep[2], Theme.iridescentDeep[0],
                                             Theme.iridescentDeep[1]], center: .center),
                    lineWidth: 1.6
                )
                .frame(width: 18 + 28 * p, height: 18 + 28 * p)
                .opacity(pulse * 0.78)
            Circle()
                .fill(Theme.surface)
                .frame(width: 27, height: 27)
                .overlay(Circle().strokeBorder(Theme.purple, lineWidth: 2.5))
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.purpleDeep)
        }
        .frame(width: 48, height: 48)
        .scaleEffect(0.72 + 0.28 * p)
        .opacity(p)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The PLAN READY tick, drawn rather than stamped: the disc scales in, then the stroke runs
/// through it. Two beats inside one 0…1 so the mark is never ahead of the surface it is written on.
private struct DrawnCheck: View, Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    /// The disc takes the first third, the stroke the rest — a tick that draws onto nothing looks
    /// like a rendering error for the first few frames.
    private var disc: Double { min(1, progress / 0.34) }
    private var stroke: Double { max(0, (progress - 0.30) / 0.70) }

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().fill(Theme.purple).scaleEffect(disc)
                Path { p in
                    p.move(to: CGPoint(x: s * 0.28, y: s * 0.52))
                    p.addLine(to: CGPoint(x: s * 0.44, y: s * 0.68))
                    p.addLine(to: CGPoint(x: s * 0.73, y: s * 0.34))
                }
                .trim(from: 0, to: stroke)
                .stroke(.white, style: StrokeStyle(lineWidth: s * 0.14, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Arriving with the reader

/// Reveal when the view actually SCROLLS INTO VIEW, not when it is created.
///
/// `AnimatedCounter`'s `.reveal()` runs off `onAppear`, which is right for a screen that arrives
/// whole. This page is taller than the screen: inside a non-lazy stack in a `ScrollView`, every
/// child appears at mount, so a delayed cascade on the lower sections played against the inside of
/// the phone and was long finished by the time anyone scrolled down to it. Content already on
/// screen at mount still fires immediately, so this is a superset of the old behaviour rather than
/// a trade.
///
/// Once only: a section that re-animated every time it crossed the fold would turn a plan into a
/// slideshow.
private struct RevealOnScroll: ViewModifier {
    let delay: Double
    @State private var shown = false
    @ReducedMotionPreference private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 16)
            // A low threshold: the trigger should be "its top edge has cleared the fold", not
            // "most of it is on screen" — the taller sections would otherwise wait until they were
            // half read before they agreed to appear.
            .onScrollVisibilityChange(threshold: 0.03) { visible in
                guard visible, !shown, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.5).delay(delay)) { shown = true }
            }
            .onChange(of: reduceMotion) { _, reduced in
                if reduced { shown = true }
            }
    }
}

private extension View {
    func revealOnScroll(_ delay: Double = 0) -> some View { modifier(RevealOnScroll(delay: delay)) }
}
