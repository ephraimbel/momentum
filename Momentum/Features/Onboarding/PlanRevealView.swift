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
    // Three one-shot lights, each travelling 0…1 exactly once. The paywall's rule holds here:
    // a lit object that moves ONCE reads as expensive, one that keeps moving reads as a spinner.
    // At rest every band has travelled off its own view, so "finished" is also "invisible".
    @State private var nameSheen = 0.0      // specular pass across the athlete's own name
    @State private var curveGleam = 0.0     // a highlight running the drawn curve, after the pen
    @State private var tileSheen = 0.0      // light crossing the stat tiles, left to right
    @State private var stripFill = 0.0      // the first week's day dots lighting in order
    @State private var checkDraw = 0.0      // the PLAN READY tick drawing itself
    @State private var chipsIn = 0.0        // "built around you" arriving one chip at a time
    /// The celebration haptic, held so it can be cancelled if the page goes away mid-sequence.
    @State private var celebrate: Task<Void, Never>?
    /// Whether the stat tiles are on screen. Their loops are the only continuous clocks on this
    /// page, and a `TimelineView` running behind six weeks of plan the athlete has scrolled to is
    /// pure heat — the paywall gates its own tile arts the same way.
    @State private var tilesOnScreen = true
    /// Same rule for the curve card, which carries the peak beacon — the page's other clock.
    @State private var curveOnScreen = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.requestReview) private var requestReview
    /// The review line is spent once — tapping it hands the athlete to the App Store, and the row
    /// settles into a thank-you rather than sitting there asking twice.
    @State private var reviewTapped = false

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

    /// A quiet, opt-in line above the reveal's CTA (owner call 2026-08-28, twice, with the 5.6.3
    /// rejection history spelled out both times): "Leave a review to help more runners join
    /// momentum."
    ///
    /// Tapping it raises Apple's own rating sheet in place — the athlete rates without ever leaving
    /// onboarding, which is the whole point (owner: "just popup the review so they can do it in app
    /// really easy"). It shipped for one afternoon as a link out to the App Store; the round trip
    /// cost more athletes than the guideline risk was ever going to.
    ///
    /// What keeps this as far from the rejected beat as it can get while still being an in-app
    /// sheet: it is never raised on its own. Nothing appears until the athlete taps a line they had
    /// to choose to read, Continue is live the whole time and gated on nothing, and there is no
    /// screen of its own — the reveal is still a plan reveal. The removed beat was a full step that
    /// stood between the reveal and the checkout and asked without being asked.
    ///
    /// Tapping latches `recordRated`, so an athlete who rates here is never asked again after a
    /// workout or a meal. iOS still owns whether the sheet actually appears (three per 365 days),
    /// so the line settles into its thank-you either way — there is no way to know, and a tap that
    /// visibly did nothing would read as broken.
    /// A narrow specular band travelling left to right, for masking onto whatever should catch the
    /// light. `progress` runs 0…1 and the band starts and ends fully off the view, so both ends of
    /// the animation are a clean no-op — nothing to fade in or out.
    ///
    /// `plusLighter` rather than a white fill: on the raised tiles it reads as light moving across
    /// a surface, and on the name it brightens the gradient instead of painting over it.
    private func sheenBand(_ progress: Double) -> some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let band = max(56, w * 0.32)
            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.9), .white.opacity(0)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: band)
                .offset(x: -band + (w + band * 2) * progress)
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }

    /// The line's whole behaviour, in one place so the DEBUG hook exercises the real thing.
    private func tapReview() {
        guard !reviewTapped else { return }
        Haptics.light()
        AppReview.recordRated()
        withAnimation(Motion.standard) { reviewTapped = true }
        // After the row has settled, or the sheet arrives over a view mid-animation and iOS
        // quietly drops it (the same beat `WorkoutRunner` waits out).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.45))
            requestReview()
        }
    }

    @ViewBuilder
    private var reviewLine: some View {
        if reviewTapped {
            Text("Thanks for helping momentum grow.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .transition(.opacity)
        } else {
            Button { tapReview() } label: {
                Text("Leave a review to help more runners join momentum")
                    .font(.rounded(Theme.FontSize.label, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Leave a review for momentum on the App Store")
        }
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
                blockCurveCard.reveal(0.18)
                statTiles.reveal(0.24)
                // Below the fold, everything arrives WHEN THE ATHLETE DOES. `.reveal()` runs off
                // `onAppear`, and in a non-lazy stack inside a ScrollView that fires for every
                // child at mount — so the chips, the first week and the whole ladder used to play
                // their entrance against the inside of the screen, seconds before anyone scrolled
                // to them. Arriving to find it already finished is the difference between a page
                // that assembles for you and a page that was assembled before you got there.
                if let weeks = vm.weeksToRace { raceCountdown(weeks).revealOnScroll() }
                reflectionChips.revealOnScroll()
                if vm.intensity == .podium, vm.running { podiumOutlook.revealOnScroll().id("podium") }
                firstWeek.revealOnScroll()
                laterWeeks.id("plan").revealOnScroll()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, topInset + Theme.Space.sm)
            .padding(.bottom, Theme.Space.lg)
            // The crown: the PAYWALL'S OWN FIELD, falling from the very top of the screen and
            // part of the CONTENT, so it still scrolls away with the hero (owner call 2026-08-27:
            // not sticky, subtle). It was a three-stop lavender ramp until 2026-08-28; the owner
            // asked for the paywall's premium feel here, and `AiryField` IS that feel — separated
            // hues reading as air rather than as one purple wash. Same component, so the two pages
            // cannot drift apart again, and `paintsBackground: false` keeps onboarding's lighter
            // canvas underneath. The mask dissolves it into that canvas exactly where the old ramp
            // ended.
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
            // `--reveal-review`: fire the review line's action on arrival. simctl can't tap, and
            // the sheet it raises is a system surface, so this is the only way to see the beat in
            // the sim: `--seed-demo --onboarding --onboarding-reveal --reveal-review`.
            if ProcessInfo.processInfo.arguments.contains("--reveal-review") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { tapReview() }
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
            VStack(spacing: Theme.Space.sm) {
                reviewLine
                OnboardingCTA(title: "This looks great") { onContinue() }
            }
                .reveal(0.4)
                .padding(.horizontal, Theme.Space.lg)
                .padding(.top, Theme.Space.md)
                .padding(.bottom, Theme.Space.sm)
                // ONE fade, owned by the inset: clear → canvas rising above it, bled past the
                // column and under the home indicator. (A separate scroll-edge overlay plus an
                // opaque button background left a hairline seam between the two while scrolling —
                // owner report 2026-08-27.) The stop is pulled all the way up to 0.24 — roughly
                // where the inset's own content starts, given the `-xl` bleed above it — so the
                // fade is SPENT before the review line rather than around it. At 0.55 the plan's
                // mileage scrolled straight through the words; at 0.35 a section header and a card
                // edge still ghosted behind them. The line needs a clean bed, not a lighter one.
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
                // Drawn, not stamped. This badge is the first thing on the page and its whole job
                // is to say "done" — so it does the gesture rather than asserting it. An SF Symbol
                // that fades in says the same words with none of the meaning.
                DrawnCheck(progress: checkDraw).frame(width: 14, height: 14)
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
    /// One definition, drawn twice: once as the name, once as the mask its light travels through.
    private var heroNameText: some View {
        Text(heroName).font(.display(40, weight: .semibold))
    }

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
                            peakLabel: peakLabel(maxV), progress: curveIn, calloutIn: calloutIn,
                            gleam: curveGleam, alive: curveOnScreen)
                    .frame(height: 170)
                    .onScrollVisibilityChange(threshold: 0.2) { curveOnScreen = $0 }
                if !data.caption.isEmpty {
                    // "Peaks at 13.5 mi in week 6" is the pill's own sentence, so it arrives WITH
                    // the pill. Reading the caption before the chart has said anything is reading
                    // the answer before the question.
                    Text(data.caption)
                        .font(.rounded(Theme.FontSize.caption, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(calloutIn ? 1 : 0)
                }
            }
            .padding(Theme.Space.md + 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .raised(RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous))
        }
    }

    private func peakLabel(_ v: Double) -> String {
        vm.running ? planDistance(v) : "\(Int(v.rounded())) sessions"
    }

    /// A planned weekly volume, written the way a coach writes one.
    ///
    /// `Formatters.distance` carries significant precision because it is built for LOGGED runs,
    /// where 5.03 mi is a fact. A week's planned volume is a target, so two decimals on it claim
    /// an accuracy the plan does not have and never intended: the page was printing "Peaks at
    /// 20.32 mi in week 6" above a ladder reading "15 mi · 16.5 mi", which is one quantity in two
    /// precisions on one screen. Half-unit steps below ten, whole units above — the same grammar
    /// `RunRounding` already uses for the sessions these totals are made of.
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
        .onScrollVisibilityChange(threshold: 0.2) { tilesOnScreen = $0 }
    }

    /// The light's arrival for tile `index` — one wave crossing the row, each tile a beat behind
    /// the last, so the group reads as one surface catching it rather than five separate flashes.
    private func tileLight(_ index: Int) -> Double {
        min(1, max(0, (tileSheen - Double(index) * 0.11) / 0.62))
    }

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
        VStack(spacing: 4) {
            AnimatedCounter(value: value, format: format)
                .font(.display(30, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label).font(.rounded(10, weight: .bold)).tracking(1.0).foregroundStyle(Theme.inkTertiary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity).frame(height: 84)
        .background(alignment: .bottom) {
            if let kind = ghost(for: label) {
                // Sized to the strip of tile that the number and its label DON'T use. At 22pt the
                // drawing ran up through the label and read as damage rather than as texture.
                RevealTileGhost(kind: kind, draw: tileLight(index), alive: tilesOnScreen)
                    .frame(height: 12).padding(.horizontal, 14).padding(.bottom, 7)
            }
        }
        .raised(tileShape())
        .overlay { sheenBand(tileLight(index)).clipShape(tileShape()) }
    }

    private func textTile(_ value: String, _ label: String, _ index: Int) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.display(24, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.rounded(10, weight: .bold)).tracking(1.0).foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity).frame(height: 78)
        .raised(tileShape())
        .overlay { sheenBand(tileLight(index)).clipShape(tileShape()) }
    }

    // MARK: Reflections

    private var reflectionChips: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm + 2) {
            sectionLabel("BUILT AROUND YOU")
            // One at a time, in order. These are the athlete's own answers handed back to them,
            // and a block of them appearing at once reads as a list that was already written.
            // Arriving one after another reads as the plan being assembled out of what they said.
            FlowLayout(spacing: 10) {
                ForEach(Array(vm.reflections().enumerated()), id: \.element) { i, chip in
                    let lit = min(1, max(0, (chipsIn - Double(i) * 0.09) / 0.34))
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

    // MARK: Week 1 — the seven-day strip + the sessions

    @ViewBuilder
    private var firstWeek: some View {
        if let first = weeksGrouped.first {
            VStack(alignment: .leading, spacing: Theme.Space.sm + 2) {
                sectionLabel("YOUR FIRST WEEK")
                WeekStrip(sessions: first.sessions, fill: stripFill)
                    .onScrollVisibilityChange(threshold: 0.5) { visible in
                        guard visible, stripFill == 0, !reduceMotion else { return }
                        withAnimation(.easeOut(duration: 0.75)) { stripFill = 1 }
                    }
                // The week deals itself out, a session at a time. Capped at six beats: past that
                // the last row is waiting on an animation instead of on the reader.
                VStack(spacing: 10) {
                    ForEach(Array(first.sessions.enumerated()), id: \.element.persistentModelID) { i, session in
                        SessionDisclosureRow(session: session, profile: profile, distanceUnit: distanceUnit,
                                             startExpanded: i == 0)
                            .revealOnScroll(Double(min(i, 6)) * 0.055)
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
                // Each row carries its own week as a BAR, scaled against the block's peak. Six rows
                // of "10.5 mi / 11.5 mi / 8 mi" is a list you have to read and hold in your head;
                // the same six with a bar behind them is the build, the down week and the peak,
                // read in one glance — the shape the curve at the top of the page already drew,
                // repeated where the detail lives. Same lavender, same peak emphasis.
                let ladderPeak = max(rest.map(weekVolume).max() ?? 1, 0.0001)
                VStack(spacing: 0) {
                    ForEach(Array(rest.enumerated()), id: \.element.week) { i, group in
                        if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 18) }
                        let v = weekVolume(group)
                        let isPeak = v >= ladderPeak - 0.0001
                        HStack(spacing: Theme.Space.md) {
                            Text("Week \(group.week)")
                                .font(.rounded(15, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.ink)
                            Spacer(minLength: Theme.Space.sm)
                            WeekStrip(sessions: group.sessions, compact: true)
                            Text(weekSummary(group.sessions))
                                .font(.rounded(13, weight: .medium)).monospacedDigit()
                                .foregroundStyle(isPeak ? Theme.ink : Theme.inkSecondary)
                                .frame(width: 64, alignment: .trailing)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background {
                            // Bottom-anchored and 2pt tall: a baseline the row sits on, not a fill
                            // behind the type. A bar tall enough to read as a background would put
                            // tinted ground under half the rows and none under the others.
                            //
                            // Measured off the ROW, not `containerRelativeFrame` — that reports the
                            // scroll container's width, so the peak week's bar ran the full page
                            // and out through the side of the card it lives in.
                            GeometryReader { geo in
                                let full = max(0, geo.size.width - 36)
                                Capsule()
                                    .fill(isPeak ? Theme.purple.opacity(0.55) : Theme.purple.opacity(0.22))
                                    .frame(width: max(10, full * (v / ladderPeak)), height: 2)
                                    .padding(.leading, 18)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                                    .padding(.bottom, 4)
                            }
                            .allowsHitTesting(false)
                        }
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

    // MARK: Reveal orchestration

    /// The arrival, as one sequence rather than a pile of independent fades.
    ///
    /// Order is the point: the numbers settle, the block draws itself, the name catches the light,
    /// the peak is called out, the line is polished, the tiles catch the same light in turn, and
    /// the week assembles last. Each beat lands in a quiet moment left by the one before it —
    /// two lights running at once is where this stops reading as craft.
    private func animateIn() {
        guard !reduceMotion else {
            shownWeeks = Double(planWeekCount); shownDays = Double(vm.daysPerWeek)
            shownSessions = Double(totalSessions); curveIn = 1; calloutIn = true
            // Every band ends off its own view, so the finished frame is simply the still page.
            nameSheen = 1; curveGleam = 1; tileSheen = 1; stripFill = 1
            checkDraw = 1; chipsIn = 1
            Haptics.celebration()
            return
        }
        // The three counters land in the SAME ORDER the light crosses them. They used to share one
        // animation and finish together while the sheen was still travelling, so the row's two
        // motions disagreed with each other — the kind of half-beat that reads as cheap without
        // anyone being able to say why.
        withAnimation(.easeOut(duration: 1.1).delay(0.30)) { shownWeeks = Double(planWeekCount) }
        withAnimation(.easeOut(duration: 1.1).delay(0.41)) { shownDays = Double(vm.daysPerWeek) }
        withAnimation(.easeOut(duration: 1.1).delay(0.52)) { shownSessions = Double(totalSessions) }
        withAnimation(Motion.pen(1.4).delay(0.35)) { curveIn = 1 }
        withAnimation(.easeOut(duration: 0.55).delay(0.20)) { checkDraw = 1 }
        withAnimation(.easeInOut(duration: 0.95).delay(0.55)) { nameSheen = 1 }
        withAnimation(.easeInOut(duration: 1.25).delay(1.05)) { tileSheen = 1 }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(1.5)) { calloutIn = true }
        withAnimation(.easeInOut(duration: 0.9).delay(1.8)) { curveGleam = 1 }
        // The celebration belongs to the MOMENT, not to the function call. It used to fire here,
        // synchronously — at t=0, against a blank page with every counter still reading zero, a
        // full second and a half before the plan's peak was called out. A success haptic with
        // nothing on screen to succeed at is just a buzz.
        celebrate?.cancel()
        celebrate = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.55))
            guard !Task.isCancelled else { return }
            Haptics.celebration()
        }
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
    /// A highlight travelling the finished stroke, 0…1 once. Runs AFTER the pen: a line that is
    /// still being drawn is already the interesting thing on screen, and two lights on one path
    /// read as a glitch rather than as craft.
    var gleam: Double = 1
    /// Run the peak beacon's loop. False once the card has scrolled away — a breathing halo six
    /// weeks of plan above the athlete's eyeline is heat with nobody to see it.
    var alive: Bool = true

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
                // Fill under the curve, revealed with the pen. The mask is a TRANSFORM, not a
                // width: `Rectangle().frame(width: w * progress)` inside a mask is a layout change,
                // and it was not clipping at all — the whole fill stood there complete while the
                // line was still being drawn, which is the one thing a self-drawing chart must not
                // do (caught on video, 2026-08-28). Scaling from the leading edge is also the rule
                // this project already holds itself to: animate transforms, never layout.
                fillPath(curve, base: h - axis, last: pts.last!, first: pts.first!)
                    .fill(LinearGradient(colors: [Theme.purple.opacity(0.22), Theme.purple.opacity(0.0)],
                                         startPoint: .top, endPoint: .bottom))
                    .mask(alignment: .leading) {
                        Rectangle().scaleEffect(x: max(0.0001, progress), y: 1, anchor: .leading)
                    }
                // The curve itself.
                curve.trim(from: 0, to: progress)
                    .stroke(stroke, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .shadow(color: Theme.purple.opacity(0.35), radius: 6, y: 3)
                // The gleam: a short segment of the SAME path, lit. Travels past 1 so it leaves
                // the line cleanly at the end instead of pooling at the last point.
                if progress >= 1, gleam > 0, gleam < 1 {
                    curve.trim(from: max(0, gleam * 1.16 - 0.14), to: min(1, gleam * 1.16))
                        .stroke(Color.white.opacity(0.92),
                                style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                }
                // Pen head.
                if progress < 1 {
                    Circle().fill(.white).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Theme.purple, lineWidth: 2.5))
                        .position(pointAlong(curve, progress))
                }
                // Peak: dot + pill. The dot is the ONE thing on this page that keeps moving —
                // a slow beacon on the block's summit, which is exactly what motion is reserved
                // for here (the peak is the achievement the whole plan is shaped around). Every
                // other light on the reveal travels once and stops; a second looping thing would
                // turn considered into busy.
                let p = pts[peakIndex]
                PeakBeacon(active: calloutIn && alive)
                    .position(p)
                    .opacity(calloutIn ? 1 : 0)   // the DOT follows the callout; only the halo follows `alive`
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
private struct RevealTileGhost: View {
    enum Kind {
        case weeks([Double])        // the block's real weekly volumes
        case days(Set<Int>)         // 0 = Monday
        case sessions(Int)
    }

    let kind: Kind
    /// 0…1, left to right, sharing the tile's own light so the drawing arrives with it.
    let draw: Double
    /// Run the loop. False = hold the still frame: off screen, or Reduce Motion.
    var alive: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    let base = i == peak ? 0.13 : 0.055
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Theme.ink.opacity(base + 0.16 * lift(i, values.count, wave)))
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
                    .fill(Theme.ink.opacity((trains ? 0.20 : 0.045) + 0.22 * l))
                    .frame(height: 5)
                    .scaleEffect(lit(i, 7) * (1 + 0.30 * l))
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
                            .fill(i < shown ? Theme.ink.opacity(0.11 + 0.20 * lift(i, shown, wave)) : .clear)
                            .frame(height: 3.5)
                            .scaleEffect(lit(i, shown))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

/// The peak week's marker: the same white dot with a purple rim the chart always had, plus a halo
/// that breathes out and fades, once every few seconds.
///
/// Slow on purpose. A fast pulse on a data point reads as "loading"; one that takes three and a
/// half seconds to open and dissolve reads as a light left on at the summit. Reduce Motion holds
/// the dot with no halo at all — the halo carries no information, so there is nothing to preserve.
private struct PeakBeacon: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let period: Double = 3.5

    var body: some View {
        ZStack {
            if active, !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let u = (t.truncatingRemainder(dividingBy: period)) / period
                    // Ease out, so it opens quickly and spends most of the loop dissolving.
                    let e = 1 - pow(1 - u, 2)
                    Circle()
                        .stroke(Theme.purple.opacity(0.34 * (1 - e)), lineWidth: 2)
                        .frame(width: 12 + 22 * e, height: 12 + 22 * e)
                }
            }
            Circle().fill(.white).frame(width: 12, height: 12)
                .overlay(Circle().stroke(Theme.purple, lineWidth: 3))
        }
        .frame(width: 34, height: 34)
        .allowsHitTesting(false)
    }
}

/// The PLAN READY tick, drawn rather than stamped: the disc scales in, then the stroke runs
/// through it. Two beats inside one 0…1 so the mark is never ahead of the surface it is written on.
private struct DrawnCheck: View {
    let progress: Double

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    }
}

private extension View {
    func revealOnScroll(_ delay: Double = 0) -> some View { modifier(RevealOnScroll(delay: delay)) }
}
