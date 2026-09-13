import SwiftUI
import CoreMotion

/// The unified plan reveal (PRD §4.1 step 4, §7.1) — the moment the athlete is sold.
///
/// Rebuilt 2026-09-13 as ONE SCREEN with one hero (owner: "this is your plan", creative, subtle
/// micro-motion, enterprise level). The hero is the athlete's first week drawn as a skyline:
/// seven bars, one per day, each as tall as the session is long, the long run the tallest, rest
/// days a dot on the baseline. It is the honest shape of the week they are about to live, and it
/// grows up in front of them, day by day. Under it, the paces as three pills settling onto their
/// numbers, and the block as one bar of phases ending in what it ends in (race day for a racer,
/// a checkpoint for everyone else). Nothing on the page is a date unless the athlete gave one;
/// every session and every week ahead is one tap away in a sheet.
///
/// Motion: staggered entrances that overlap rather than queue, bars that settle with a touch of
/// overshoot, numerals that roll, a chosen bar that breathes. On a device the week card tilts a
/// few degrees with the hand. Every beat is a transform, it all plays once, and the settled page
/// is still and readable. Reduce Motion: the finished page, no breathing, no tilt.
struct PlanRevealView: View {
    let vm: OnboardingViewModel
    let profile: UserProfile?
    var onContinue: () -> Void

    @State private var arrivalStarted = false
    @State private var checkDraw = 0.0      // the tick beside the chapter word
    @State private var cardIn = 0.0         // the week card placed on the canvas
    @State private var skylineClock = 0.0   // the bars growing, day by day
    @State private var chosenDay: Int?
    @State private var pillClock = 0.0      // the pace pills dealt and settling
    @State private var phaseClock = 0.0     // the block filling in
    @State private var tailIn = 0.0         // the way to every session
    @State private var showingDetails = false
    @State private var stripFill = 0.0
    @State private var chipsIn = 0.0
    @State private var sequence: Task<Void, Never>?
    @State private var motion = MotionTilt()
    @ReducedMotionPreference private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private var totalSessions: Int { profile?.plan?.sessions.count ?? 0 }

    private var distanceUnit: DistanceUnit { DistanceUnit(rawValue: profile?.distanceUnit ?? "auto") ?? .auto }

    /// Grouping the block's sessions into weeks is cheap, but this body renders every frame of a
    /// three-second arrival; computed once and boxed so the animation never re-buckets the plan.
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
    /// The block's first day: every seven-day strip on the page starts on its weekday.
    private var planAnchor: Date? { weeksGrouped.first?.sessions.map(\.date).min() }

    /// The racer's page says the date once; the open-ended athlete's page never says one. This
    /// is the switch every date-bearing element reads.
    private var datedRace: Bool { vm.goal == .raceDistance && vm.hasRace }

    var body: some View {
        OnboardingHeroPage {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                hero
                weekCard
                    .modifier(CardPlacement(progress: reduceMotion ? 1 : cardIn))
                    .padding(.top, Theme.Space.xs)
                if startingPaces != nil { pacePills }
                blockLine
                Button {
                    Haptics.selection()
                    showingDetails = true
                } label: {
                    HStack(spacing: 6) {
                        Text("See every session")
                        Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                    }
                    .font(.rounded(14, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Space.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("onboarding.reveal.details")
                .opacity(reduceMotion ? 1 : tailIn)
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, Theme.Space.lg)
            Spacer(minLength: Theme.Space.sm)
        } actions: {
            VStack(spacing: Theme.Space.sm) {
                // The locker-room line, not a victory line: the promise that a bad week is planned
                // for is what the athlete needs to hear right before they commit.
                Text(datedRace ? "Your plan adapts every week. Your goal stays the same."
                               : "Your plan adapts every week. It starts where you are.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                OnboardingCTA(title: "Continue") { onContinue() }
                    .accessibilityIdentifier("onboarding.reveal.continue")
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, Theme.Space.sm)
            .padding(.bottom, Theme.Space.md)
        }
        .sheet(isPresented: $showingDetails) { detailSheet }
        #if DEBUG
        .task {
            let args = ProcessInfo.processInfo.arguments
            if args.contains(where: { $0.hasPrefix("--reveal-scroll-") }) {
                try? await Task.sleep(for: .milliseconds(400))
                showingDetails = true
            }
        }
        #endif
        .onAppear(perform: animateIn)
        .onDisappear {
            sequence?.cancel()
            motion.stop()
            settleArrival()
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced {
                sequence?.cancel()
                motion.stop()
                settleArrival()
            }
        }
        .trackScreen(.planReveal)
    }

    /// The small chapter word: the pace page's caption, so the page reads as the same product
    /// the questions were.
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.rounded(10, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(Theme.inkSecondary)
    }

    // MARK: Hero — ready

    /// The interview's heading, left-aligned, with the drawn tick beside the chapter word. The
    /// tick is the only ceremony: drawn, not stamped, and small. The plan is named the way a
    /// coach names one, with its shape beside it.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                DrawnCheck(progress: reduceMotion ? 1 : checkDraw).frame(width: 15, height: 15)
                Text("PLAN READY")
                    .font(.rounded(10, weight: .semibold)).tracking(1.4)
                    .foregroundStyle(Theme.purple)
            }
            .onboardingEntrance(0.02, lift: 6)
            VStack(alignment: .leading, spacing: 6) {
                Text("Your plan, \(heroName)")
                    .font(.display(34, weight: .semibold)).tracking(-0.6)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel(planReadyTitle)
                Text(planTitle)
                    .font(.rounded(15, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onboardingEntrance(0.10, lift: 12)
        }
    }

    /// "Half marathon build · 10 weeks · 4 days a week" / "Base block · 6 weeks · 4 days a week".
    private var planTitle: String {
        let name: String
        if vm.goal == .raceDistance, let r = vm.raceDistance {
            name = "\(r.label) build"
        } else {
            switch vm.goal {
            case .endurance:      name = "Endurance block"
            case .stayConsistent: name = "Consistency block"
            case .loseFat:        name = "Fitness block"
            case .buildMuscle, .getStronger: name = vm.running ? "Strength for running block" : "Strength block"
            default:              name = "Base block"
            }
        }
        let weeks = planWeekCount == 1 ? "1 week" : "\(planWeekCount) weeks"
        var line = "\(name) · \(weeks) · \(vm.daysPerWeek) days a week"
        if datedRace { line += " · \(vm.raceDate.formatted(.dateTime.month(.abbreviated).day()))" }
        return line
    }

    private var firstName: String? {
        vm.name.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
    }

    private var heroName: String { firstName.map { "\($0)." } ?? "ready." }

    /// Kept for the walkers, which look for this text on the page.
    private var planReadyTitle: String {
        firstName.map { "Your plan is ready, \($0)" } ?? "Your plan is ready"
    }

    // MARK: The week, as a skyline

    /// The seven days from the opening session. Anchored on the plan's own first day rather than
    /// on Monday: the week the athlete is about to live starts with their first run, and a
    /// Mon-first grid would open on two or three "rest" days that are really just yesterday.
    private var weekDays: [WeekSkyline.Day] {
        guard let first = weeksGrouped.first,
              let start = first.sessions.map(\.date).min() else { return [] }
        let cal = Calendar.current
        let day0 = cal.startOfDay(for: start)
        let runs = first.sessions.filter { $0.discipline == .running }.compactMap(\.targetDistanceM)
        let longest = max(runs.max() ?? 0, 1)
        return (0..<7).map { offset in
            let date = cal.date(byAdding: .day, value: offset, to: day0) ?? day0
            let session = first.sessions.first { cal.isDate($0.date, inSameDayAs: date) }
            // A bar's height is the session's size against the week's biggest run: runs by
            // distance, a lift or a ride by a coach's rule of thumb (about half a long run).
            let load: Double
            if let session {
                if session.discipline == .running, let m = session.targetDistanceM { load = max(0.18, m / longest) }
                else { load = 0.5 }
            } else { load = 0 }
            return WeekSkyline.Day(date: date, session: session, load: load)
        }
    }

    /// The opening session is chosen from the start: the lavender bar is how the skyline says
    /// "this one, and you can choose another", without an instruction printed on the card.
    private var selectedDay: Int? {
        chosenDay ?? weekDays.firstIndex { $0.session != nil }
    }

    private var weekCard: some View {
        let days = weekDays
        let chosen = selectedDay.flatMap { days.indices.contains($0) ? days[$0] : nil }
        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("YOUR FIRST WEEK")
                Spacer(minLength: Theme.Space.sm)
                if let chosen {
                    Text("\(chosen.date.formatted(.dateTime.weekday(.abbreviated))) · \(sessionName(chosen.session))")
                        .font(.rounded(12, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .contentTransition(.opacity)
                        .animation(Motion.crossfade, value: selectedDay)
                        .opacity(reduceMotion ? 1 : min(1, max(0, (skylineClock - 0.75) / 0.25)))
                }
            }
            WeekSkyline(days: days, clock: reduceMotion ? 1 : skylineClock, selected: selectedDay,
                        breathing: !reduceMotion) { index in
                Haptics.selection()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { chosenDay = index }
            }
            .frame(height: 132)
            if let chosen {
                Text(sessionDetail(chosen.session))
                    .font(.rounded(13, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
                    .monospacedDigit()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(selectedDay)
                    .transition(.opacity)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("onboarding.reveal.weekCallout")
                    .accessibilityLabel("\(chosen.date.formatted(.dateTime.weekday(.wide))), \(sessionName(chosen.session)). \(sessionDetail(chosen.session))")
                    .opacity(reduceMotion ? 1 : min(1, max(0, (skylineClock - 0.8) / 0.2)))
            }
        }
        .padding(Theme.Space.md + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCard()
        // On a device the card follows the hand, a few degrees, the way a pass does.
        .rotation3DEffect(.degrees(reduceMotion ? 0 : motion.pitch), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
        .rotation3DEffect(.degrees(reduceMotion ? 0 : motion.roll), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .accessibilityElement(children: .contain)
    }

    private func sessionName(_ session: PlannedSession?) -> String {
        guard let session else { return "Rest" }
        switch session.discipline {
        case .running: return session.runType?.planTitle ?? "Run"
        case .strength: return StrengthSplit.dayTitle(forLabel: session.strengthLabel) ?? "Strength"
        default: return session.workoutType?.title ?? session.discipline.rawValue.capitalized
        }
    }

    private func sessionDetail(_ session: PlannedSession?) -> String {
        guard let session else { return "Rest. The training lands on the days between." }
        return PlanCoaching.brief(for: session, distanceUnit: distanceUnit, dropLeadingType: true)
    }

    // MARK: Your paces

    /// The plan's OWN paces (the calibrated `p5kSPerKm` the engine trained from), falling back
    /// to what the anchor implied while the plan was being built. The numbers on this page are
    /// the numbers the sessions carry; a page that rounded differently would be a second truth.
    private var startingPaces: (easy: Double, steady: Double, repeats: Double)? {
        guard vm.running else { return nil }
        let p5k = profile?.plan?.p5kSPerKm ?? vm.impliedPaces?.p5k
        guard let p5k, p5k.isFinite, p5k > 0 else { return nil }
        return (DanielsPaces.trainingPace(.easy, p5kSPerKm: p5k),
                DanielsPaces.trainingPace(.tempo, p5kSPerKm: p5k),
                DanielsPaces.trainingPace(.intervals, p5kSPerKm: p5k))
    }

    /// Three pills, dealt a beat apart, each settling DOWN onto its number from a slower one:
    /// the plan finding the athlete's pace, not counting up from nothing.
    @ViewBuilder
    private var pacePills: some View {
        if let p = startingPaces {
            HStack(spacing: 8) {
                pacePill("EASY", p.easy, 0)
                pacePill("STEADY", p.steady, 1)
                pacePill("REPEATS", p.repeats, 2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Easy \(Formatters.pace(secPerKm: p.easy, unit: distanceUnit)), steady \(Formatters.pace(secPerKm: p.steady, unit: distanceUnit)), repeats \(Formatters.pace(secPerKm: p.repeats, unit: distanceUnit))")
        }
    }

    private func pacePill(_ label: String, _ secPerKm: Double, _ index: Int) -> some View {
        let deal = reduceMotion ? 1.0 : min(1, max(0, (pillClock - Double(index) * 0.12) / 0.5))
        let settle = 1 - pow(1 - deal, 3)
        return VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.rounded(9, weight: .semibold)).tracking(1.2).foregroundStyle(Theme.inkTertiary)
            AnimatedCounter(value: secPerKm + 70 * (1 - settle)) { Formatters.pace(secPerKm: $0, unit: distanceUnit) }
                .font(.display(17, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raised(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .scaleEffect(0.92 + 0.08 * settle, anchor: .bottom)
        .opacity(settle)
    }

    // MARK: How it grows

    /// The engine's phase per week (`weekPhases`) as one bar filling left to right, ending in
    /// what the block ends in — race day for a racer, a checkpoint that recalibrates the paces
    /// for everyone else (the rolling block, 2026-09-07).
    private var weekPhaseList: [PlanPhase] {
        let stored = (profile?.plan?.weekPhases ?? []).compactMap(PlanPhase.init(rawValue:))
        if stored.count >= planWeekCount { return Array(stored.prefix(max(planWeekCount, 1))) }
        return stored + Array(repeating: .build, count: max(0, planWeekCount - stored.count))
    }

    private var blockLine: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("HOW IT GROWS")
                Spacer(minLength: Theme.Space.sm)
                Text(datedRace ? "TO RACE DAY" : "BLOCK \((profile?.plan?.blockIndex ?? 0) + 1)")
                    .font(.rounded(10, weight: .semibold)).tracking(1.4)
                    .foregroundStyle(Theme.inkTertiary).monospacedDigit()
            }
            PhaseBar(phases: weekPhaseList, end: datedRace ? .race : .checkpoint,
                     clock: reduceMotion ? 1 : phaseClock)
            Text(phaseSentence)
                .font(.rounded(13, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .opacity(reduceMotion ? 1 : min(1, max(0, (phaseClock - 0.5) / 0.4)))
        }
        .padding(.top, Theme.Space.xs)
        .opacity(reduceMotion ? 1 : min(1, phaseClock * 4))
    }

    private var phaseSentence: String {
        var names: [String] = []
        for phase in weekPhaseList where names.last != phase.label { names.append(phase.label) }
        let arc = names.map { $0.replacingOccurrences(of: " week", with: "").lowercased() }
        let arcLine = arc.enumerated().map { $0.offset == 0 ? $0.element.prefix(1).uppercased() + $0.element.dropFirst() : $0.element }
            .joined(separator: ", then ")
        if datedRace, let r = vm.raceDistance {
            return "\(arcLine), then race day. Everything points at your \(r.label.lowercased())."
        }
        return "\(arcLine), then a checkpoint. Your paces update from it and the next block starts from what you ran."
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

    // MARK: Every session — the sheet

    /// Everything that used to make the page long: the briefing, the complete first week, the
    /// weeks ahead. One tap away, in the house sheet grammar, and still every session open.
    private var detailSheet: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("every session")
                    .font(.rounded(15, weight: .semibold)).foregroundStyle(Theme.ink)
                HStack {
                    Spacer()
                    Button {
                        showingDetails = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 34, height: 34)
                            .raised(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, Theme.Space.lg)
            .padding(.bottom, Theme.Space.md)
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Theme.Space.lg) {
                    trainingBriefing
                    detailedPlan
                }
                .padding(.horizontal, Theme.Space.lg)
                .padding(.bottom, Theme.Space.xl)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("onboarding.reveal.scroll")
            #if DEBUG
            .task {
                let args = ProcessInfo.processInfo.arguments
                let target = args.contains("--reveal-scroll-plan") ? "plan"
                    : args.contains("--reveal-scroll-podium") ? "podium"
                    : args.contains("--reveal-scroll-week-one") ? "week-one" : nil
                if let target {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(target, anchor: .top)
                }
            }
            #endif
            }
        }
        .background(OnboardingStyle.canvas(colorScheme))
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
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
                Text("Based on your starting profile and any result you entered. New running evidence refines the estimate.")
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
        let raceM = vm.goal == .raceDistance ? (vm.raceDistance?.meters ?? 5000) : 5000
        guard let seconds = RacePredictor.finishTimeS(raceDistanceM: raceM, p5kSPerKm: p5k) else { return nil }
        let race = vm.goal == .raceDistance ? (vm.raceDistance?.label.lowercased() ?? "5K") : "5K"
        let estimate = "Your starting fitness estimate is \(PlanFeasibility.hms(seconds)) for \(race)."
        if let goal = vm.goalFinishTimeS, vm.goal == .raceDistance {
            return estimate + " Your goal is \(PlanFeasibility.hms(goal)). The plan builds toward it and adjusts to how you respond."
        }
        return estimate + " The plan builds from here; your training shows us when you're ready to progress."
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
                if let opening = first.sessions.first {
                    Text("First up: \(PlanCoaching.brief(for: opening, distanceUnit: vm.distanceUnitChoice.flatMap(DistanceUnit.init(rawValue:)) ?? .auto))")
                        .font(.rounded(14, weight: .medium)).foregroundStyle(Theme.ink)
                        .monospacedDigit().fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("onboarding.reveal.firstSession")
                }
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

    private var detailedPlan: some View {
        VStack(spacing: Theme.Space.lg) {
                firstWeek.id("week-one")
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
                WeekStrip(sessions: first.sessions, fill: reduceMotion ? 1 : stripFill, anchor: planAnchor)
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
                                    Text(datedRace ? weekDateRange(group) : weekPhaseLabel(group.week))
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
                                WeekStrip(sessions: group.sessions, compact: true, anchor: planAnchor)
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

    /// The phase the engine gave this week ("Build", "Recovery week"), for the athlete whose
    /// plan has no date to count toward.
    private func weekPhaseLabel(_ week: Int) -> String {
        let phases = profile?.plan?.weekPhases ?? []
        guard week - 1 < phases.count, let phase = PlanPhase(rawValue: phases[week - 1]) else { return "Building" }
        return phase.label
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

    /// The whole arrival as one timed sequence, in seconds from appear, ~2.6 s and then still.
    /// Beats overlap rather than queue: the heading is still settling as the card is placed, the
    /// bars are still growing as the first pill is dealt. A page that waits for each beat to
    /// finish reads as a slideshow; one that overlaps reads as a thing arriving.
    private func animateIn() {
        guard !arrivalStarted else { return }
        arrivalStarted = true
        guard !reduceMotion else {
            settleArrival()
            return
        }
        Haptics.warm()
        motion.start()

        withAnimation(.easeOut(duration: 0.45).delay(0.12)) { checkDraw = 1 }
        withAnimation(.spring(response: 0.7, dampingFraction: 0.84).delay(0.30)) { cardIn = 1 }
        withAnimation(.easeOut(duration: 1.25).delay(Self.skylineBeatS)) { skylineClock = 1 }
        withAnimation(.easeOut(duration: 1.1).delay(1.45)) { pillClock = 1 }
        withAnimation(.easeInOut(duration: 0.9).delay(1.9)) { phaseClock = 1 }
        withAnimation(.easeOut(duration: 0.5).delay(2.5)) { tailIn = 1 }

        // The haptics belong to the moments: each training day standing up (a selection tick,
        // at most six), the block's end landing (a light tick), then quiet.
        sequence?.cancel()
        let ticks = min(6, weekDays.filter { $0.session != nil }.count)
        sequence = Task { @MainActor in
            let clock = ContinuousClock()
            let start = clock.now
            func at(_ s: Double) async -> Bool {
                let target = start + .seconds(s)
                if target > clock.now { try? await Task.sleep(until: target, clock: clock) }
                return !Task.isCancelled
            }
            for k in 0..<ticks {
                guard await at(Self.skylineBeatS + 0.12 + Double(k) * WeekSkyline.stagger * 1.25) else { return }
                Haptics.selection()
            }
            guard await at(1.9 + 0.85) else { return }
            Haptics.light()
        }
    }

    /// When the bars start standing up, once the card has been placed.
    private static let skylineBeatS = 0.62

    /// Finish presentation on interruption or an accessibility change. Returning from checkout
    /// never replays the arrival or leaves delayed animation state over the readable page.
    private func settleArrival() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            checkDraw = 1; cardIn = 1; skylineClock = 1
            pillClock = 1; phaseClock = 1; tailIn = 1
            stripFill = 1; chipsIn = 1
        }
    }
}

// MARK: - The skyline

/// The first week as seven bars: a training day stands as tall as its session is big, the long
/// run tallest, a rest day a dot on the baseline. The bars stand up in the order the days come,
/// each with a touch of overshoot, the sport's glyph rising to sit on top; the chosen bar wears
/// lavender and breathes, slowly, because it is the one happening. Tap a bar to choose a day.
/// Buttons, never gestures: the page underneath keeps scrolling.
private struct WeekSkyline: View, Animatable {
    struct Day {
        let date: Date
        let session: PlannedSession?
        let load: Double   // 0…1 against the week's biggest run
    }
    let days: [Day]
    var clock: Double
    var selected: Int?
    var breathing: Bool
    var onSelect: (Int) -> Void
    var animatableData: Double {
        get { clock }
        set { clock = newValue }
    }

    /// The clock runs 1.25 s; a training bar starts this fraction after the one before it.
    static let stagger = 0.09

    var body: some View {
        GeometryReader { geo in
            let barMax = geo.size.height - 44   // room for the glyph above and the letter below
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    Button { onSelect(index) } label: {
                        column(day, index: index, barMax: barMax)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityLabel(day))
                    .accessibilityAddTraits(selected == index ? [.isSelected] : [])
                }
            }
        }
    }

    /// Training bars stand up in order; rest dots are present by the time the first one lands.
    private func progress(for index: Int) -> Double {
        let ordinal = days.prefix(index).filter { $0.session != nil }.count
        guard days[index].session != nil else { return min(1, max(0, clock / 0.2)) }
        return min(1, max(0, (clock - 0.05 - Double(ordinal) * Self.stagger) / 0.42))
    }

    /// Ease-out-back: the bar overshoots its height a little and settles, an object placed
    /// rather than a value reached.
    private func settle(_ p: Double) -> Double {
        let c1 = 1.25, c3 = c1 + 1
        return 1 + c3 * pow(p - 1, 3) + c1 * pow(p - 1, 2)
    }

    private func column(_ day: Day, index: Int, barMax: CGFloat) -> some View {
        let p = progress(for: index)
        let chosen = selected == index
        let height = day.session == nil ? 0 : max(14, barMax * day.load)
        return VStack(spacing: 6) {
            Spacer(minLength: 0)
            if let session = day.session {
                Image(systemName: symbol(session))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(chosen ? Theme.purple : Theme.ink)
                    .opacity(min(1, max(0, (p - 0.55) / 0.3)))
                    .offset(y: 4 * (1 - min(1, max(0, (p - 0.55) / 0.3))))
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(chosen ? Theme.purple : Theme.ink)
                    .frame(width: 24, height: height)
                    .scaleEffect(x: 1, y: max(0.001, settle(p)), anchor: .bottom)
                    .opacity(p > 0.02 ? 1 : 0)
                    // The chosen bar breathes: slow, small, the one thing on the page that is
                    // alive once the arrival is over.
                    .modifier(Breathing(on: chosen && breathing && p >= 1))
            } else {
                Circle().fill(Theme.ink.opacity(chosen ? 0.6 : 0.18))
                    .frame(width: 5, height: 5)
                    .padding(.bottom, 4)
                    .scaleEffect(0.4 + 0.6 * p)
                    .opacity(p)
            }
            Text(day.date.formatted(.dateTime.weekday(.narrow)))
                .font(.rounded(11, weight: chosen ? .semibold : .medium))
                .foregroundStyle(chosen ? Theme.ink : Theme.inkTertiary)
                .frame(height: 14)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: chosen)
    }

    private func symbol(_ session: PlannedSession) -> String {
        if let type = session.workoutType { return type.systemImage }
        switch session.discipline {
        case .running: return "figure.run"
        case .strength: return "dumbbell.fill"
        case .cycling: return "bicycle"
        case .walking: return "figure.walk"
        default: return "figure.mixed.cardio"
        }
    }

    private func accessibilityLabel(_ day: Day) -> String {
        let weekday = day.date.formatted(.dateTime.weekday(.wide))
        guard let session = day.session else { return "\(weekday), rest" }
        let name = session.discipline == .running ? (session.runType?.planTitle ?? "Run")
            : session.discipline == .strength ? "Strength" : session.discipline.rawValue.capitalized
        return "\(weekday), \(name)"
    }
}

/// A slow, small breath: opacity only, 3.2 s a cycle, never a size change. Nothing when off.
private struct Breathing: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on {
            content.phaseAnimator([1.0, 0.78]) { view, phase in
                view.opacity(phase)
            } animation: { _ in .easeInOut(duration: 1.6) }
        } else {
            content
        }
    }
}

// MARK: - Placing the card

/// The card comes down onto the canvas: a little perspective off its bottom edge, a rise, and
/// the shadow arriving with it. A card that only fades in is a layer; one that is placed is an
/// object.
private struct CardPlacement: ViewModifier, Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(12 * (1 - progress)), axis: (x: 1, y: 0, z: 0),
                              anchor: .bottom, perspective: 0.7)
            .scaleEffect(0.95 + 0.05 * progress, anchor: .bottom)
            .offset(y: 28 * (1 - progress))
            .opacity(progress)
    }
}

// MARK: - The block bar

/// The block as one bar: a segment per week in the phase's shade of ink, filling left to right
/// off one clock, and the block's end as a small ink disc wearing what it ends in.
private struct PhaseBar: View, Animatable {
    enum End { case race, checkpoint }
    let phases: [PlanPhase]
    let end: End
    var clock: Double
    var animatableData: Double {
        get { clock }
        set { clock = newValue }
    }

    private func shade(_ phase: PlanPhase) -> Double {
        switch phase {
        case .base: 0.28
        case .build: 0.55
        case .peak: 0.9
        case .recovery: 0.16
        case .taper: 0.4
        }
    }

    var body: some View {
        let count = max(1, phases.count)
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(Array(phases.enumerated()), id: \.offset) { i, phase in
                    let lit = min(1, max(0, (clock * Double(count + 1) - Double(i)) / 1.2))
                    Capsule()
                        .fill(Theme.ink.opacity(shade(phase)))
                        .frame(height: 8)
                        .scaleEffect(x: max(0.001, lit), anchor: .leading)
                        .opacity(lit)
                }
            }
            let endLit = min(1, max(0, (clock - 0.8) / 0.2))
            ZStack {
                Circle().fill(Theme.ink)
                Image(systemName: end == .race ? "flag.checkered" : "stopwatch")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 20, height: 20)
            .scaleEffect(0.5 + 0.5 * endLit)
            .opacity(endLit)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Following the hand

/// The card tilts with the device, the way a pass does in Wallet: attitude deltas from the
/// moment the page appears, clamped to a few degrees and smoothed. Nothing on the simulator, and
/// nothing under Reduce Motion (the view never reads it then).
@Observable
private final class MotionTilt {
    private(set) var pitch = 0.0
    private(set) var roll = 0.0
    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var reference: (pitch: Double, roll: Double)?

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let attitude = motion?.attitude else { return }
            if reference == nil { reference = (attitude.pitch, attitude.roll) }
            guard let reference else { return }
            let targetPitch = max(-6, min(6, (attitude.pitch - reference.pitch) * 18))
            let targetRoll = max(-6, min(6, (attitude.roll - reference.roll) * 18))
            withAnimation(.easeOut(duration: 0.12)) {
                self.pitch = targetPitch
                self.roll = targetRoll
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        reference = nil
        pitch = 0; roll = 0
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

    /// The plan's weeks are seven-day buckets from its first day, not calendar weeks, so the
    /// strip starts on that weekday too (the same anchor as the week board above it). A Mon-first
    /// strip under a block that starts on Sunday put the opening run on the last dot.
    var anchor: Date? = nil

    private var days: [(letter: String, sessions: [PlannedSession])] {
        let cal = Calendar.current
        let letters = ["S", "M", "T", "W", "T", "F", "S"]   // index = weekday - 1, Sunday first
        let first = (cal.component(.weekday, from: anchor ?? sessions.map(\.date).min() ?? Date()) - 1)
        var buckets = Array(repeating: [PlannedSession](), count: 7)
        for s in sessions {
            let wd = cal.component(.weekday, from: s.date) - 1
            buckets[(wd - first + 7) % 7].append(s)
        }
        return (0..<7).map { (letters[(first + $0) % 7], buckets[$0]) }
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
