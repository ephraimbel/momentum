import SwiftUI
import SwiftData

/// Plan — a calm weekly command center (PRD §7.7). A week hero with a completion ring, an optional
/// "tune this week" nudge from the coach, then each day as a date badge + quiet session cards. Tap a
/// session to adjust/move/remove it; tap its circle to check it off (earned iridescent). Missed work
/// moves with a one-line note. No red, no guilt.
struct PlanView: View {
    @Environment(\.modelContext) private var context
    @Environment(PaywallController.self) private var paywall
    @Environment(CoachPresenter.self) private var coach
    @Query private var profiles: [UserProfile]
    @Query private var workouts: [Workout]
    /// Coach-button badge. Newest coach turn only — "any coach message newer than lastSeen" is
    /// decided entirely by the newest one, and an unbounded ChatMessage query materialized the
    /// whole thread on the Plan tab AND re-rendered the board on every user keystroke-send.
    @Query(PlanView.newestCoachMessage) private var newestCoachTurn: [ChatMessage]
    static var newestCoachMessage: FetchDescriptor<ChatMessage> {
        var d = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.roleRaw == "coach" },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        d.fetchLimit = 1
        return d
    }
    @State private var weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
    @State private var showingAdd = false
    @State private var showLibrary = false
    @State private var addDay = Date()
    @State private var editing: EditingSession?
    @State private var adjusted = false
    @State private var launch: TodayLaunch?
    @State private var pendingStart: PlannedSession?     // start after the detail sheet dismisses
    /// Created on first cardio start, not at init: this view is constructed on every RootView
    /// body pass (the TabView content builder runs eagerly), and a `CLLocationManager` per pass
    /// for a one-shot authorization ask was pure launch cost (perf audit 2026-08-13). Held in
    /// @State so the manager outlives the authorization prompt it raises.
    @State private var locator: LocationService?
    @State private var showSettings = false
    @State private var showNewPlan = false
    /// "Plan it myself" confirmation — dropping the coach's prescriptions deserves one honest ask.
    @State private var confirmingSelfCoached = false
    // Derived plan data, memoized so `body` stops re-filtering the whole session list dozens of
    // times per render (a marathon plan is ~150 sessions; the board alone did 30-40 full scans).
    // Rebuilt only when the week or the plan actually changes.
    @State private var weekMap: [Date: [PlannedSession]] = [:]
    @State private var weekStartsCache: [Date] = []
    @State private var planFirstWeek: Date?
    // The (plan-identity, session-count, week) signature the `weekMap` cache was built for. When the
    // current signature no longer matches — a regenerated plan (cascade-deletes old sessions), a
    // removed session, a new week, or the very first frame — `liveWeekMap` recomputes fresh from the
    // live `plan.sessions` instead of touching the stale cache, which can hold deleted objects.
    @State private var weekMapToken: Int = 0
    // Coach's-read insights are real engine work (quality-run pace eval + hybrid sequencing, both
    // faulting session→workout→exercise). Memoized here so `body` never recomputes them on an
    // unrelated re-render — notably opening the coach, which flips the presenter's `lastSeenAt` and
    // would otherwise re-run all of it mid-cover-animation (the "opening the coach felt laggy" bug).
    @State private var coachsReadModel = CoachsReadModel()
    // The masthead arc's data (planned metres per plan week) and the displayed week's real recorded
    // mileage — both memoized in `rebuildDerived` beside the other derived plan data. The mileage
    // sum walks the whole workouts query, which is exactly the per-body work that page never does.
    @State private var weekVolumesCache: [Double] = []
    @State private var weekDoneMetersCache: Double = 0
    // Week-scoped memos (rebuilt with the week map): the displayed week's phase, day list, and the
    // strength rows' lift lines — each was recomputed per render (the phase up to ~11×, faulting
    // the plan relationship each time; the lift lines faulting one Exercise per lift per row).
    @State private var weekPhaseCache: PlanPhase?
    @State private var daysCache: [Date] = []
    @State private var daysCacheWeek = Date.distantPast
    @State private var liftLinesCache: [PersistentIdentifier: String] = [:]
    // Plan-scoped memos (rebuilt only when the plan/workouts actually change, NOT on week paging —
    // paging previously re-ran PaceInsights + hybrid sequencing + full min/max scans per tap):
    @State private var planScopeToken = 0
    @State private var weekIndexCache: [Date: Int] = [:]
    @State private var weekBarBaseLabels: [String] = []
    /// The tune-this-week proposal, computed off the render path. As a body-time call it built
    /// `ProgressInsights` (≈18 full passes over the workout table) on EVERY render of the current
    /// week — the single heaviest thing on this page.
    @State private var tuneProposal: PlanCoaching.Proposal?

    private struct CoachsReadModel: Equatable {
        var hasRacePrediction = false
        var paceResult: PaceInsights.Result?
        var hybridInsight: String?
        var hasContent: Bool { hasRacePrediction || paceResult != nil || hybridInsight != nil }
    }

    /// Identifiable wrapper so `.sheet(item:)` works regardless of the model's own conformance.
    private struct EditingSession: Identifiable {
        let session: PlannedSession
        var id: PersistentIdentifier { session.persistentModelID }
    }

    private var plan: TrainingPlan? { profiles.first?.plan }
    private var distanceUnit: DistanceUnit {
        DistanceUnit(rawValue: profiles.first?.distanceUnit ?? "auto") ?? .auto
    }

    /// The live current week — the tune card and renewal prompt only make sense here.
    private var isCurrentWeek: Bool {
        Calendar.current.isDate(weekStart, inSameDayAs: currentWeekStart)
    }
    /// Free tier sees the current week AND everything already trained — an athlete's own completed
    /// work is never paywalled. Only weeks still ahead are the Pro tease (PRD §10/§13.10).
    private var isFutureWeek: Bool { weekStart > currentWeekStart }
    private var days: [Date] {
        daysCacheWeek == weekStart ? daysCache : Self.computeDays(from: weekStart)
    }
    private static func computeDays(from weekStart: Date) -> [Date] {
        (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: weekStart) }
    }
    /// The week's sessions grouped by day. Returns the memoized cache while its signature matches the
    /// live plan; otherwise recomputes fresh (cheap, one pass over `plan.sessions`) — so it never
    /// reads a cascade-deleted/removed session, and never flashes an empty board on the first frame.
    private var liveWeekMap: [Date: [PlannedSession]] {
        weekMapToken == currentWeekToken ? weekMap : computeWeekMap()
    }
    /// A cheap signature of everything the map depends on: plan identity, session count, and the week.
    /// A regenerated plan (new id), an added/removed session (count), or a week change all flip it.
    private var currentWeekToken: Int {
        var h = Hasher()
        h.combine(plan?.persistentModelID)
        h.combine(plan?.sessions.count ?? 0)
        h.combine(weekStart)
        return h.finalize()
    }
    private func computeWeekMap() -> [Date: [PlannedSession]] {
        guard let plan else { return [:] }
        let cal = Calendar.current
        let weekDays = Set(days.map { cal.startOfDay(for: $0) })
        var map: [Date: [PlannedSession]] = [:]
        for s in plan.sessions {
            let d = cal.startOfDay(for: s.date)
            if weekDays.contains(d) { map[d, default: []].append(s) }
        }
        for k in map.keys { map[k]?.sort { $0.date < $1.date } }
        return map
    }

    // Extracted from `body` so the long modifier chain below (sheets, onChange, onAppear) applies to
    // a resolved view type — inlining the whole tree tipped the type-checker into a timeout.
    @ViewBuilder
    private var planContent: some View {
        if plan == nil {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    header
                    weekStrip
                    if showRenewalPrompt { renewalCard.reveal(0.04) }
                    // Self-coached: no tune proposals — the coach never suggests inside their plan.
                    if isCurrentWeek, plan?.isSelfCoached != true { tuneSection }
                    weekBoard
                        .reveal(0.06)
                        .proLocked(.fullPlan, active: isFutureWeek)
                    coachsRead
                    // App Review 1.4.1: the citations door where the training prescriptions live —
                    // paces, zones, and load caps all trace to the sources behind this link.
                    SourcesFooterLink()
                        .padding(.top, Theme.Space.sm)
                }
                .padding(Theme.Space.md)
                .padding(.bottom, Theme.Space.xxl)
            }
            .scrollIndicators(.hidden)
        }
    }

    var body: some View {
        planContent
        .onAppear { rebuildDerived() }
        // One trigger for the whole board: `currentWeekToken` hashes plan identity + session count +
        // week, so a saved/new plan (new id, often same count), an added/removed session, or a week
        // change each rebuild the memoized maps. (Date-moves that keep all three are covered by the
        // editing-sheet `onDismiss` below.)
        .onChange(of: currentWeekToken) { rebuildDerived() }
        .background(Theme.background)
        .navigationBarHidden(true)
        .sheet(isPresented: $showingAdd) {
            if let plan {
                AddSessionSheet(plan: plan, defaultDate: addDay, onDone: { showingAdd = false },
                                onOpenLibrary: {
                    // Sheet swap with the house 0.35 s beat — let this one finish dismissing
                    // before the library presents (the CheckinSheet → injury-sheet pattern).
                    showingAdd = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showLibrary = true }
                })
            }
        }
        .sheet(isPresented: $showLibrary) {
            if let plan {
                WorkoutLibrarySheet(plan: plan, defaultDate: addDay) { showLibrary = false }
            }
        }
        .sheet(item: $editing, onDismiss: {
            rebuildDerived()   // an edit may move a session's date without changing the count
            if let s = pendingStart { pendingStart = nil; start(s) }
        }) { item in
            SessionDetailSheet(session: item.session, distanceUnit: distanceUnit, profile: profiles.first,
                               onRemove: { delete(item.session) },
                               onStart: { pendingStart = $0 })
        }
        .workoutRunner(launch: $launch)
        .confirmationDialog("Plan it yourself?", isPresented: $confirmingSelfCoached, titleVisibility: .visible) {
            Button("Take over my plan") { goSelfCoached() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Upcoming prescribed sessions are removed — everything you've completed stays. You write your own weeks from here (add sessions, use the library), and the coach stops prescribing or adjusting. You can ask for a new plan anytime.")
        }
        .sheet(isPresented: $showSettings, onDismiss: rebuildDerived) {
            // No plan yet → the sheet must open in CREATE mode, or Save quietly rebuilds nothing
            // and dismisses with a success buzz (the coach's "set up your plan" card hit this).
            if let p = profiles.first {
                PlanSettingsSheet(profile: p, mode: p.plan == nil ? .create : .adjust) { showSettings = false }
            }
        }
        // "Start a new plan" — the same complete form, framed as a beginning: blank name, always
        // rebuilds, honest about replacing the current block (completed work + calibration carry).
        .sheet(isPresented: $showNewPlan, onDismiss: rebuildDerived) {
            if let p = profiles.first { PlanSettingsSheet(profile: p, mode: .create) { showNewPlan = false } }
        }
        // A coach nav card asked for plan settings — open the sheet the shell steered us toward
        // (onChange covers the case where Plan was already the visible tab).
        .onChange(of: coach.wantsPlanSettings) { _, wants in
            guard wants else { return }
            coach.wantsPlanSettings = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showSettings = true }
        }
        .onAppear {
            if coach.wantsPlanSettings {
                coach.wantsPlanSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showSettings = true }
            }
            #if DEBUG
            // --plan-settings: open the plan-settings sheet (screenshot verification; sim can't tap).
            if ProcessInfo.processInfo.arguments.contains("--plan-settings") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showSettings = true }
            }
            // --plan-new: open the start-a-new-plan flow directly.
            if ProcessInfo.processInfo.arguments.contains("--plan-new") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showNewPlan = true }
            }
            // --plan-add: open the plan-a-session sheet directly (screenshot verification).
            if ProcessInfo.processInfo.arguments.contains("--plan-add") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { presentAdd(for: Date()) }
            }
            // --plan-self-coached: take over the seeded plan (screenshot verification of the mode).
            if ProcessInfo.processInfo.arguments.contains("--plan-self-coached") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { goSelfCoached() }
            }
            // --plan-locked-week: land on next week (the Pro-locked state) for lock-pill verification.
            if ProcessInfo.processInfo.arguments.contains("--plan-locked-week"),
               let next = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: weekStart) {
                weekStart = next
            }
            // Open the first long run's detail (fuel-section verification; sim taps are unreliable).
            if ProcessInfo.processInfo.arguments.contains("--plan-detail-long"),
               let long = plan?.sessions.filter({ $0.runType == .long && $0.status == .planned })
                   .min(by: { $0.date < $1.date }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { editing = EditingSession(session: long) }
            }
            #endif
        }
    }

    /// Launch the right recorder for a planned session (uses its precise sport; requests GPS for cardio).
    private func start(_ session: PlannedSession) {
        let t = session.workoutType ?? workoutType(for: session.discipline)
        if t.isStrengthStyle { launch = .strength(type: t, planned: session) }
        else if t.isTimed { launch = .timed(type: t) }
        else {
            let loc = locator ?? LocationService()
            locator = loc
            loc.requestAuthorization()
            launch = .cardio(type: t, goalMeters: session.targetDistanceM, planned: session, guideRoute: [])
        }
    }

    private func workoutType(for d: Discipline) -> WorkoutType {
        switch d { case .strength: .strength; case .cycling: .ride; case .walking: .walk; case .running: .run }
    }

    private func presentAdd(for day: Date) { addDay = day; showingAdd = true }

    /// The athlete takes the pen (owner call 2026-07-30). The plan OBJECT survives — Today's deck,
    /// plan credit, notifications, and the board all read through it — but every un-run prescription
    /// goes, and `isSelfCoached` stands the coach down everywhere (generation, tune, renewal,
    /// auto-adapt, rebuild-week, recalibration). Completed sessions keep their workout links.
    private func goSelfCoached() {
        guard let plan else { return }
        withAnimation(Motion.standard) {
            let upcoming = plan.sessions.filter { $0.status != .completed && $0.completedWorkout == nil }
            plan.sessions.removeAll { s in upcoming.contains { $0.id == s.id } }
            upcoming.forEach(context.delete)
            plan.isSelfCoached = true
            plan.weekPhases = []                 // no macrocycle claim on weeks we didn't write
            plan.pendingP5kSPerKm = nil          // no banked recalibration evidence to apply later
            plan.pendingP5kAt = nil
            try? context.save()
        }
        rebuildDerived()
        Haptics.success()
    }

    /// The brand-new athlete who never wants prescriptions: an empty self-coached container, ready
    /// for their own sessions. `p5kSPerKm` keeps the model default — library workouts still price
    /// paces conservatively until a real run calibrates nothing (self-coached never recalibrates).
    private func startSelfCoached() {
        guard let profile = profiles.first, profile.plan == nil else { return }
        let plan = TrainingPlan()
        plan.isSelfCoached = true
        plan.goal = profile.goal
        plan.disciplines = profile.disciplines
        plan.blockStart = Calendar.current.startOfDay(for: Date())
        context.insert(plan)
        profile.plan = plan
        try? context.save()
        rebuildDerived()
        Haptics.success()
    }

    /// R4 coach intelligence: a race-day projection (when a race goal is set) + a Pace Insight reading
    /// "Your week, sequenced" — surfaces the cross-discipline coaching moment: how the week's runs and
    /// lifts are spaced so hard efforts land on fresh legs. Shown only on genuinely hybrid weeks.
    @ViewBuilder
    private var hybridCard: some View {
        if let insight = coachsReadModel.hybridInsight {
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                Image(systemName: "figure.run.circle").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text("YOUR WEEK, SEQUENCED").font(.rounded(Theme.FontSize.label, weight: .bold))
                        .tracking(1.2).foregroundStyle(Theme.inkTertiary)
                    Text(insight).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.md).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Your week, sequenced. \(insight)")
        }
    }

    /// The cross-discipline read for the displayed week — nil unless it pairs a leg day with a hard/long
    /// run. Infers "leg day" from a strength session's lower-body primary muscles.
    private var hybridWeekInsight: String? {
        guard let plan else { return nil }
        let cal = Calendar.current
        let items: [HybridSequencing.Item] = plan.sessions.compactMap { s in
            guard let dayIndex = cal.dateComponents([.day], from: weekStart, to: cal.startOfDay(for: s.date)).day,
                  (0...6).contains(dayIndex) else { return nil }
            if s.discipline == .running {
                let hard = s.runType.map { $0.isQuality || $0 == .long } ?? false
                return .init(dayIndex: dayIndex, runType: s.runType, isHardRun: hard, isLegDay: false)
            }
            if s.discipline == .strength {
                let isLeg = s.strengthTargets.contains { pe in
                    (pe.exercise?.primaryMuscles ?? []).contains { HybridSequencing.Item.legMuscles.contains($0) }
                }
                return .init(dayIndex: dayIndex, runType: nil, isHardRun: false, isLegDay: isLeg)
            }
            return nil
        }
        return HybridSequencing.weekInsight(items)
    }

    /// The coach's read, grouped BELOW the week (the schedule is the page's job; analysis supports
    /// it): race projection, quality-pace verdict, and the hybrid sequencing note.
    @ViewBuilder
    private var coachsRead: some View {
        if coachsReadModel.hasContent {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("COACH'S READ")
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                    .foregroundStyle(Theme.inkTertiary)
                    .padding(.top, Theme.Space.sm)
                if coachsReadModel.hasRacePrediction, let plan, let raceM = profiles.first?.raceDistanceM {
                    RacePredictionCard(raceDistanceM: raceM,
                                       raceDate: profiles.first?.raceDate ?? plan.raceDate,
                                       p5kSPerKm: plan.p5kSPerKm, distanceUnit: distanceUnit)
                }
                if let result = coachsReadModel.paceResult {
                    PaceInsightCard(result: result)
                }
                hybridCard
            }
        }
    }

    private func delete(_ session: PlannedSession) {
        withAnimation(Motion.standard) {
            context.delete(session)
            try? context.save()
        }
        Haptics.light()
    }

    // MARK: Header

    private var header: some View {
        // The shared masthead language (fuel / plan / progress): a small centered title in the
        // display face — the athlete's own plan name when they gave it one — with the coach on
        // the left and the plan actions on the right. The context line sits centered beneath.
        ZStack {
            VStack(spacing: 1) {
                Text(planTitleText)
                    .font(.display(20, weight: .bold)).foregroundStyle(Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .accessibilityAddTraits(.isHeader)
                if let context = planContextLine {
                    Text(context)
                        .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .padding(.horizontal, 92)   // stay clear of the flanking clusters
            HStack(alignment: .center, spacing: Theme.Space.xs) {
                coachButton
                Spacer()
                if plan != nil {
                    // Three distinct intents, named plainly: tune what exists, begin again, or take
                    // the pen (owner call 2026-07-30 — some athletes want the whole app WITHOUT a
                    // coach's plan; self-coached keeps every surface and drops every prescription).
                    // Goals change — starting over is a first-class move, never buried.
                    Menu {
                        if plan?.isSelfCoached != true {
                            Button { showSettings = true } label: {
                                Label("Adjust this plan", systemImage: "slider.horizontal.3")
                            }
                        }
                        Button { showNewPlan = true } label: {
                            Label(plan?.isSelfCoached == true ? "Build me a plan" : "Start a new plan",
                                  systemImage: "arrow.triangle.2.circlepath")
                        }
                        if plan?.isSelfCoached != true {
                            Button { confirmingSelfCoached = true } label: {
                                Label("Plan it myself", systemImage: "pencil.and.outline")
                            }
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                            .frame(width: 40, height: 40).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Plan options")
                }
                addButton
            }
        }
        .padding(.top, Theme.Space.sm)
    }

    /// The masthead title: the athlete's plan name as typed; the unnamed default joins the
    /// lowercase page-word family ("plan", like "fuel" and "progress").
    private var planTitleText: String {
        let name = planDisplayName
        return name == "Plan" ? "plan" : name
    }

    /// One quiet line of what this plan is FOR — the race and its countdown when one is set, else
    /// the goal. The plan page should never make you wonder what it's building toward.
    private var planContextLine: String? {
        guard let profile = profiles.first else { return nil }
        // Self-coached wears its mode openly — the athlete writes the weeks, the app carries them.
        if plan?.isSelfCoached == true { return "Self-coached · your plan, your call" }
        if let raceM = profile.raceDistanceM, raceM > 0, let raceDate = profile.raceDate, raceDate > Date() {
            let label = RaceDistance.nearest(toMeters: raceM).label
            let cal = Calendar.current
            // Count actual days-to-race (not `.weekOfYear`, which crosses week boundaries and mislabels
            // a race 8–13 days out as "race week"). ≤7 days = race week; otherwise weeks, rounded up.
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()),
                                          to: cal.startOfDay(for: raceDate)).day ?? 0
            let day = raceDate.formatted(.dateTime.month(.abbreviated).day())
            // One countdown grammar everywhere (Formatters.raceCountdown) — this header and the
            // race-projection card lower on the SAME page must never disagree about the distance
            // to the race ("2 weeks" vs "9 days").
            return "\(label) · \(day) · \(Formatters.raceCountdown(days: days))"
        }
        // The strip and this counter read the same array by construction — `rebuildDerived` starts
        // the strip at the block, so carried history can't inflate "of N" or offset a chip.
        guard let idx = planWeekIndex(of: currentWeekStart), planWeekStarts.count > 1 else { return nil }
        // Open-ended (no race): a rolling block that renews when it wraps — say so, so "Week 6 of 6"
        // reads as a checkpoint, not a plan running out.
        if plan?.raceDate == nil {
            return "Rolling block \((plan?.blockIndex ?? 0) + 1) · Week \(idx + 1) of \(planWeekStarts.count)"
        }
        let prefix = (plan?.name.isEmpty ?? true) ? "Training plan · " : ""
        return "\(prefix)Week \(idx + 1) of \(planWeekStarts.count)"
    }

    /// The athlete's name for the block is the page title ("Austin Marathon"); unnamed plans stay "Plan".
    private var planDisplayName: String {
        let name = plan?.name.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "Plan" : name
    }

    /// Memoized per calendar day (non-observed static — filling it mid-body is invisible to
    /// SwiftUI): the raw `dateInterval` form ran ~60×/render across bars, chips, and headers.
    @MainActor private static var weekStartMemo: (day: Date, start: Date)?
    private var currentWeekStart: Date {
        let today = Calendar.current.startOfDay(for: Date())
        if let m = Self.weekStartMemo, m.day == today { return m.start }
        let start = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        Self.weekStartMemo = (today, start)
        return start
    }

    /// Ask the coach anything, right from the plan — the bare app icon (same brand identity as Today's
    /// entry), no container, sized to sit level with the adjuster and add button. Free to chat; plan
    /// changes still gate on Pro at Apply time inside the thread. A quiet dot marks an unseen seed.
    private var coachButton: some View {
        let unseen = hasUnseenCoachNews
        return Button { Haptics.light(); coach.open() } label: {
            BrandMark(size: 32)
                .frame(width: 40, height: 40)
                .overlay(alignment: .topTrailing) {
                    if unseen {
                        Circle().fill(Theme.ink)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Theme.background, lineWidth: 1.5))
                            .offset(x: 2, y: -2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask your coach")
        .accessibilityValue(unseen ? "New message waiting" : "")
    }

    /// A coach message landed after the chat was last on screen (proactive seeds arrive closed).
    private var hasUnseenCoachNews: Bool {
        newestCoachTurn.first.map { $0.createdAt > coach.lastSeenAt } ?? false
    }

    private var addButton: some View {
        Button {
            // A free athlete viewing a Pro-locked future week: adding would drop the session
            // behind the frosted board where they can't see it land — route to the paywall
            // instead, the same boundary the board itself draws.
            if isFutureWeek && !paywall.isEntitled(to: .fullPlan) {
                paywall.present(for: .fullPlan)
                return
            }
            presentAdd(for: isCurrentWeek ? Date() : weekStart)
        } label: {
            Image(systemName: "plus").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.background)
                .frame(width: 40, height: 40).background(Circle().fill(Theme.ink))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add session")
    }

    // MARK: Week strip + hero

    /// The plan's spine — no longer a row of numbered chips but the block's actual SHAPE: one bar
    /// per training week, height scaled to that week's planned volume, whole block visible at once.
    /// Build weeks climb, cutbacks visibly dip (so a down week reads as designed, not as the plan
    /// losing interest), the peak stands tallest, and the taper falls away toward the race — the
    /// periodization `PlanEngine` computes, finally legible on the page it governs. Tap a bar to
    /// jump; the ink bar is the displayed week, the dot anchors the current calendar week.
    ///
    /// The old chip strip remains only as the fallback for blocks too long for tappable bars
    /// (>26 weeks — edge-of-cap plans), and chevron paging still covers plans with no derivable
    /// weeks. The chips' one job the arc keeps: position — the board header now names the week
    /// ("Week 5") so the bars don't need numerals.
    @ViewBuilder
    private var weekStrip: some View {
        let weeks = planWeekStarts
        if weeks.count > 1, weeks.count <= 26 {
            weekArc(weeks)
        } else if weeks.count > 1 {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: Theme.Space.sm) {
                        ForEach(Array(weeks.enumerated()), id: \.element) { i, start in
                            weekChip(index: i, start: start)
                                .id(i)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    if let idx = planWeekIndex(of: weekStart) { proxy.scrollTo(idx, anchor: .center) }
                }
                .onChange(of: weekStart) {
                    if let idx = planWeekIndex(of: weekStart) {
                        withAnimation(Motion.standard) { proxy.scrollTo(idx, anchor: .center) }
                    }
                }
            }
        }
    }

    /// The micro block-arc. Bars share the width equally (no scrolling — the shape only means
    /// something whole), with a 10 pt floor so a strength-only or empty week stays present and
    /// tappable rather than vanishing.
    private func weekArc(_ weeks: [Date]) -> some View {
        let volumes = weekVolumesCache.count == weeks.count ? weekVolumesCache
            : Array(repeating: 0, count: weeks.count)   // first frame before rebuildDerived lands
        let maxV = volumes.max() ?? 0
        return HStack(alignment: .bottom, spacing: weeks.count > 16 ? 2 : 3) {
            ForEach(Array(weeks.enumerated()), id: \.element) { i, start in
                weekBar(index: i, start: start, volume: volumes[i], maxVolume: maxV)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Training block, \(weeks.count) weeks")
    }

    private func weekBar(index: Int, start: Date, volume: Double, maxVolume: Double) -> some View {
        let cal = Calendar.current
        let selected = cal.isDate(start, inSameDayAs: weekStart)
        let isCurrent = cal.isDate(start, inSameDayAs: currentWeekStart)
        let isPast = start < currentWeekStart
        // Flat-block fallback: a plan with no distance targets anywhere (pure strength) has no
        // shape to draw, so every bar takes a uniform mid height and the arc degrades to a clean
        // tappable pager rather than a row of stubs.
        let h: CGFloat = maxVolume > 0 ? 10 + 24 * CGFloat(volume / maxVolume) : 22
        return Button {
            Haptics.selection()
            withAnimation(Motion.standard) { weekStart = start }
        } label: {
            VStack(spacing: 4) {
                // Width-capped inside a full-width tap column: short blocks would otherwise
                // stretch each bar to ~46 pt slabs that read as a loading skeleton, not a chart.
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Theme.ink)
                                   : AnyShapeStyle(Theme.ink.opacity(isPast ? 0.28 : 0.15)))
                    .frame(maxWidth: 26)
                    .frame(height: h)
                // Every bar carries its week number — the one job the chips did that heights
                // can't. The current calendar week wears the board's own "today" convention (an
                // ink pill, like the date column below) instead of the chips' floating dot, so
                // the two surfaces mark "now" the same way.
                Text("\(index + 1)")
                    .font(.rounded(9, weight: selected || isCurrent ? .heavy : .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isCurrent ? Theme.background
                                     : (selected ? Theme.ink : Theme.inkTertiary))
                    .frame(width: 15, height: 15)
                    .background {
                        if isCurrent { Circle().fill(Theme.ink) }
                    }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58, alignment: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(weekBarLabel(index: index, volume: volume,
                                         isCurrent: isCurrent, selected: selected))
    }

    /// VoiceOver carries everything the bar's height encodes — volume, a recovery/taper week's
    /// nature, position — since a silent height difference is invisible to a screen reader.
    /// Base string precomputed in `rebuildPlanScoped` (the eager label argument re-faulted
    /// `plan.weekPhases` per bar per render); only the live current/selected suffixes append here.
    private func weekBarLabel(index: Int, volume: Double, isCurrent: Bool, selected: Bool) -> String {
        var label = index < weekBarBaseLabels.count ? weekBarBaseLabels[index] : "Week \(index + 1)"
        if isCurrent { label += ", current" }
        if selected { label += ", selected" }
        return label
    }

    private func weekChip(index: Int, start: Date) -> some View {
        let selected = Calendar.current.isDate(start, inSameDayAs: weekStart)
        let isPast = start < currentWeekStart
        let isCurrent = Calendar.current.isDate(start, inSameDayAs: currentWeekStart)
        return Button {
            Haptics.selection()
            withAnimation(Motion.standard) { weekStart = start }
        } label: {
            VStack(spacing: 2) {
                Text("WK").font(.rounded(8, weight: .black)).tracking(0.8)
                Text("\(index + 1)").font(.display(15, weight: .heavy)).monospacedDigit()
            }
            .foregroundStyle(selected ? Theme.background : (isPast ? Theme.inkTertiary : Theme.ink))
            .frame(width: 44, height: 44)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Theme.ink : Theme.surface)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Color.clear : Theme.hairline)
            }
            .overlay(alignment: .bottom) {
                // The current calendar week keeps a quiet anchor dot even when browsing elsewhere.
                if isCurrent && !selected {
                    Circle().fill(Theme.ink).frame(width: 3.5, height: 3.5).offset(y: -4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Week \(index + 1)\(isCurrent ? ", current" : "")\(selected ? ", selected" : "")")
    }

    /// The board's header: the week's story (title, phase, intent) and its progress. Lives INSIDE
    /// the board card now — no surface of its own — so the week reads as one object: story on top,
    /// schedule below, a single hairline between them.
    private var boardHeader: some View {
        // One map read + one ledger build for the whole header — these were recomputed 2–5× per
        // render across the ring, the volume line, and the accessibility label.
        let sessions = weekSessions
        let done = sessions.filter { $0.status == .completed }.count
        let total = sessions.count
        let ledger = weekLedger(sessions)
        let summary = weekSummary(done: done, total: total)
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                Text(weekTitle).font(.display(20, weight: .black)).foregroundStyle(Theme.ink)
                    .contentTransition(.opacity)
                if let phase = weekPhase {
                    Text(phase.label.uppercased())
                        .font(.rounded(9, weight: .black)).tracking(1)
                        .fixedSize()
                        .foregroundStyle(phase == .taper ? Theme.background : Theme.inkSecondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background {
                            Capsule().fill(phase == .taper ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.surface))
                            if phase != .taper { Capsule().stroke(Theme.hairline) }
                        }
                }
                Spacer(minLength: 0)
                if planWeekStarts.count <= 1 {
                    chevron("chevron.left") { shiftWeek(-1) }
                    chevron("chevron.right") { shiftWeek(1) }
                }
            }
            Text(weekPhase?.intent ?? summary)
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .contentTransition(.opacity)
            // One slim bar tells the week's story; the numbers make it exact. The bar fills by
            // VOLUME banked, not sessions checked (`PlanWeekLedger.fraction` — two of four done is
            // not "half the week" when the long run is one of the two left); iridescence stays the
            // completed week's earned moment.
            if total > 0 {
                let frac = ledger.fraction
                HStack(spacing: Theme.Space.sm) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.hairline.opacity(0.7))
                            Capsule()
                                .fill(done == total ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.ink))
                                .frame(width: max(5, geo.size.width * CGFloat(frac)))
                        }
                    }
                    .frame(height: 5)
                    Text("\(done) of \(total)")
                        .font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Theme.inkTertiary)
                        .fixedSize()
                    if let volume = weekVolumeText(ledger) {
                        Text("· \(volume)")
                            .font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
                            .foregroundStyle(Theme.inkTertiary)
                            .fixedSize()
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.md)
        .padding(.bottom, Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(weekTitle), \(weekPhase.map { "\($0.label) phase — \($0.intent)" } ?? summary), \(done) of \(total) sessions done")
    }

    /// The displayed week's planned-vs-done ledger — sessions live (check-offs re-render models
    /// directly), actual mileage from the memoized sum (`rebuildDerived`; workouts only change
    /// off-page, so appear/week-change refreshes are exact). Takes the caller's already-resolved
    /// session list so the header builds it exactly once per render.
    private func weekLedger(_ sessions: [PlannedSession]) -> PlanWeekLedger.Ledger {
        PlanWeekLedger.ledger(
            sessions: sessions.map { .init(targetDistanceM: $0.targetDistanceM,
                                           completed: $0.status == .completed) },
            actualCardioM: weekDoneMetersCache)
    }

    /// The volume story: prospective until miles land ("13.2 mi planned"), then the honest ledger
    /// ("4.1 of 13.2 mi"). Quiet ink either way — under-volume is information, never a verdict.
    private func weekVolumeText(_ ledger: PlanWeekLedger.Ledger) -> String? {
        guard ledger.plannedM > 0 else { return nil }
        let planned = Formatters.distance(meters: ledger.plannedM, unit: distanceUnit)
        // Under ~100 m recorded there is nothing meaningful to compare — stay prospective.
        guard ledger.doneM >= 100 else { return "\(planned) planned" }
        let value = distanceUnit.resolved() == .imperial
            ? ledger.doneM / Formatters.metersPerMile : ledger.doneM / 1000
        return "\(Formatters.distanceNumeral(value)) of \(planned)"
    }

    /// Recompute the memoized derived data. Split in two scopes (2026-07-30 perf audit): the
    /// WEEK-scoped part runs on every trigger (cheap — one pass over the sessions), while the
    /// PLAN-scoped part (PaceInsights faulting workouts, ProgressInsights' ~18 workout-table
    /// passes for the tune proposal, full min/max scans, the arc volumes) is guarded by its own
    /// token — so paging weeks with the arc no longer re-runs any of it.
    private func rebuildDerived() {
        let cal = Calendar.current
        currentWeekStartCacheRefresh()
        daysCache = Self.computeDays(from: weekStart)
        daysCacheWeek = weekStart
        guard let plan else {
            weekMap = [:]; weekStartsCache = []; planFirstWeek = nil; weekMapToken = 0
            weekVolumesCache = []; weekDoneMetersCache = 0; weekPhaseCache = nil
            weekIndexCache = [:]; weekBarBaseLabels = []; liftLinesCache = [:]
            tuneProposal = nil; planScopeToken = 0
            coachsReadModel = CoachsReadModel(); return
        }
        // — Week scope —
        weekMap = computeWeekMap()
        weekMapToken = currentWeekToken
        // The displayed week's real recorded mileage — every GPS workout in the window, planned or
        // not, because unplanned miles are still miles the athlete ran (the ledger's "done" side).
        if let end = cal.date(byAdding: .day, value: 7, to: weekStart) {
            weekDoneMetersCache = workouts
                .filter { $0.type.isGPS && $0.startedAt >= weekStart && $0.startedAt < end }
                .reduce(0) { $0 + ($1.gps?.distanceM ?? 0) }
        } else {
            weekDoneMetersCache = 0
        }
        liftLinesCache = [:]
        for s in weekMap.values.joined() where s.discipline == .strength {
            if let line = Self.buildLiftLine(s) { liftLinesCache[s.persistentModelID] = line }
        }
        // Week-dependent halves of the coach's read + phase (planFirstWeek is plan-scoped but the
        // phase lookup keys off weekStart, so it refreshes here AFTER the plan scope runs below).

        // — Plan scope (identity + session count + workouts + unit) —
        var h = Hasher()
        h.combine(plan.persistentModelID); h.combine(plan.sessions.count)
        h.combine(workouts.count); h.combine(profiles.first?.distanceUnit ?? "")
        let planTok = h.finalize()
        if planTok != planScopeToken {
            planScopeToken = planTok
            // Deferred one beat (perf audit 2026-08-13): this is the expensive half — the tune
            // proposal's ~18 workout-table passes, PaceInsights faulting session→workout→gps, the
            // arc volumes — and running it inline meant the Plan tab's FIRST frame paid all of it
            // before anything appeared. The board above renders immediately; the tune card, the
            // coach's read and the arc fill in a beat later. A newer rebuild supersedes via the
            // token guard; the week-scoped `weekPhase`/hybrid refresh below re-runs after it lands
            // because both read plan-scoped caches.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard planScopeToken == planTok, let livePlan = self.plan else { return }
                rebuildPlanScoped(plan: livePlan, calendar: cal)
                weekPhaseCache = computeWeekPhase()
                coachsReadModel.hybridInsight = hybridWeekInsight
            }
            return
        }
        weekPhaseCache = computeWeekPhase()
        coachsReadModel.hybridInsight = hybridWeekInsight
    }

    private func rebuildPlanScoped(plan: TrainingPlan, calendar cal: Calendar) {
        // The tune proposal — ProgressInsights walks the whole workout table ~18 times; this must
        // never run on the render path (it used to, on every current-week render).
        tuneProposal = PlanCoaching.proposeAdjustment(plan, workouts: workouts)
        var model = CoachsReadModel()
        if let raceM = profiles.first?.raceDistanceM, raceM > 0, plan.p5kSPerKm > 0 {
            model.hasRacePrediction = true
        }
        let runs = PaceInsights.recentQualityRuns(plan)
        if !runs.isEmpty { model.paceResult = PaceInsights.evaluate(runs) }
        model.hybridInsight = coachsReadModel.hybridInsight
        coachsReadModel = model

        // The Monday of every week the plan spans — the strip's data, plus the plan's first week.
        guard let first = plan.sessions.map(\.date).min(),
              let last = plan.sessions.map(\.date).max(),
              let start = cal.dateInterval(of: .weekOfYear, for: first)?.start else {
            weekStartsCache = []; planFirstWeek = nil; weekVolumesCache = []
            weekIndexCache = [:]; weekBarBaseLabels = []; return
        }
        // The BLOCK's first week is `blockStart`; legacy plans have no `blockStart` and fall back to
        // the earliest session, which is what they were built on.
        let blockWeek = plan.blockStart.flatMap { cal.dateInterval(of: .weekOfYear, for: $0)?.start } ?? start
        planFirstWeek = blockWeek
        // The strip starts THERE, not at the earliest session. Carried history (a completed race from
        // the week before the block) would otherwise prepend a chip, so the header read "Week 1 of 6"
        // while the highlighted chip beneath it read "WK 2" — and a long-tenured athlete carrying an
        // old race could push the block past the 64-week cap entirely, leaving the counter blank.
        var out: [Date] = []
        var d = blockWeek
        while d <= last, out.count < 64 {
            out.append(d)
            guard let next = cal.date(byAdding: .weekOfYear, value: 1, to: d) else { break }
            d = next
        }
        weekStartsCache = out
        weekIndexCache = Dictionary(uniqueKeysWithValues: out.enumerated().map { ($0.element, $0.offset) })
        // The arc's bars: planned metres per plan week. Same one-pass discipline as the rest of
        // this function — the strip must never trigger per-render session scans.
        weekVolumesCache = PlanWeekLedger.plannedMetersByWeek(
            sessions: plan.sessions.map { ($0.date, $0.targetDistanceM) },
            weekStarts: out, calendar: cal)
        // The bars' VoiceOver base labels ("Week 3, 24 mi planned, recovery") — the eager
        // `.accessibilityLabel(...)` argument built these per bar per render, faulting
        // `plan.weekPhases` each time. Current/selected suffixes stay live in `weekBar`.
        let phases = plan.weekPhases
        weekBarBaseLabels = weekVolumesCache.enumerated().map { i, volume in
            var parts = ["Week \(i + 1)"]
            if volume > 0 { parts.append("\(Formatters.distance(meters: volume, unit: distanceUnit)) planned") }
            if i < phases.count, let phase = PlanPhase(rawValue: phases[i]),
               phase == .recovery || phase == .taper {
                parts.append(phase.label.lowercased())
            }
            return parts.joined(separator: ", ")
        }
    }

    private func currentWeekStartCacheRefresh() {
        Self.weekStartMemo = nil   // day may have rolled since the memo filled
        _ = currentWeekStart
    }

    /// The Monday of every week the plan spans — the strip's data (memoized in `weekStartsCache`).
    private var planWeekStarts: [Date] { weekStartsCache }

    private func planWeekIndex(of week: Date) -> Int? {
        // Exact-date dictionary first (week starts are canonical `dateInterval` values, so equal
        // weeks are equal Dates); the linear calendar-compare scan stays as the safety net.
        weekIndexCache[week]
            ?? planWeekStarts.firstIndex { Calendar.current.isDate($0, inSameDayAs: week) }
    }

    /// The macrocycle phase of the displayed week (nil off-plan or for legacy plans without
    /// phases). Cache-guarded like `liveWeekMap`: the raw form faulted the plan relationship and
    /// decoded `weekPhases` up to ~11× per render (header ×3 + once per rest row).
    private var weekPhase: PlanPhase? {
        weekMapToken == currentWeekToken ? weekPhaseCache : computeWeekPhase()
    }
    private func computeWeekPhase() -> PlanPhase? {
        guard let plan = profiles.first?.plan, !plan.weekPhases.isEmpty,
              let firstWeek = planFirstWeek else { return nil }
        let idx = Calendar.current.dateComponents([.weekOfYear], from: firstWeek, to: weekStart).weekOfYear ?? -1
        guard idx >= 0, idx < plan.weekPhases.count else { return nil }
        return PlanPhase(rawValue: plan.weekPhases[idx])
    }

    private func chevron(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.light(); action() } label: {
            Image(systemName: system).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 36, height: 36).background(Circle().fill(Theme.background)).overlay(Circle().stroke(Theme.hairline))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Tune this week (coach proposal)

    @ViewBuilder
    private var tuneSection: some View {
        if adjusted {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ink)
                Text("Plan updated for this week.").font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.md)
            .background(card)
        } else if let proposal = tuneProposal {
            Button {
                // Free to see the coach's thinking, Pro to apply it — the same boundary as chat's
                // Apply and the post-run cards, so the monetization line never drifts per surface.
                guard paywall.isEntitled(to: .aiCoach) else { paywall.present(for: .aiCoach); return }
                let changed = PlanCoaching.apply(proposal.rec, to: plan, in: context)
                if changed > 0 { Haptics.success(); withAnimation(Motion.standard) { adjusted = true } }
            } label: {
                HStack(spacing: Theme.Space.md) {
                    Image(systemName: "wand.and.stars").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(width: 38, height: 38).background(Circle().fill(IridescentMaterial()).opacity(0.32))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(proposal.headline).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                        Text(proposal.detail).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Text("Apply").font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.background)
                        .padding(.horizontal, Theme.Space.md).padding(.vertical, 8)
                        .background(Capsule().fill(Theme.ink))
                }
                .padding(Theme.Space.md)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.card).fill(IridescentMaterial()).opacity(0.12)
                    RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Rolling-block renewal — the "we'll see where you're at" checkpoint

    /// True when an open-ended (no-race) plan's current block is on its last week or has lapsed —
    /// the honest moment to reassess and build the next block. Only on the live current week
    /// (browsing history never nags), and never for dated-race plans (they run to race day).
    private var showRenewalPrompt: Bool {
        guard let plan, !plan.isSelfCoached, plan.raceDate == nil, isCurrentWeek else { return false }
        // Prefer the memoized week span; fall back to the live sessions so the very first frame —
        // before `rebuildDerived` fills the cache — never flashes the card on a brand-new block.
        let blockEnd = planWeekStarts.last ?? plan.sessions.map(\.date).max()
        guard let end = blockEnd,
              let lastWeek = Calendar.current.dateInterval(of: .weekOfYear, for: end)?.start else { return false }
        return currentWeekStart >= lastWeek
    }

    /// A quiet earned-iridescent card that closes one block and opens the next. Completing a block is
    /// an achievement (so it earns the accent), and the copy is honest — the next block is built from
    /// what the athlete actually ran, and nothing is locked in.
    private var renewalCard: some View {
        let lapsed = planWeekStarts.last.map { currentWeekStart > $0 } ?? true
        let block = (plan?.blockIndex ?? 0) + 1
        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
                    .frame(width: 40, height: 40).background(Circle().fill(IridescentMaterial()).opacity(0.32))
                VStack(alignment: .leading, spacing: 3) {
                    Text(lapsed ? "Block \(block) complete" : "Last week of block \(block)")
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                    Text("Let’s see where you’re at and build your next block around what you’ve actually been running. Nothing’s locked in.")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            Button { renewBlock() } label: {
                Text("Build my next block")
                    .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.background)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Capsule().fill(Theme.ink))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Build my next block")
        }
        .padding(Theme.Space.md)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(IridescentMaterial()).opacity(0.12)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
    }

    /// Reassess recent training and regenerate the next rolling block from today (its week 1 becomes
    /// the current week, so the board repopulates immediately).
    private func renewBlock() {
        guard let profile = profiles.first else { return }
        PlanService.renewBlock(for: profile, in: context)
        Haptics.success()
        withAnimation(Motion.standard) {
            weekStart = currentWeekStart
            rebuildDerived()
        }
    }

    // MARK: The week board — the whole week as one organized object

    /// A single card holding all seven days as rows, hairline-separated, today banded and pilled.
    /// Zooming the week out into one surface makes the schedule read at a glance and binds every
    /// session unmistakably to its day (same row, date anchored left). Replaces the old free-floating
    /// day rows.
    private var weekBoard: some View {
        // ONE map + day-list resolution for all seven rows — per-row `liveWeekMap` reads paid the
        // token check (plan faults) ~55× per render before this hoist.
        let map = liveWeekMap
        let weekDays = days
        return VStack(spacing: 0) {
            boardHeader
            // A full-bleed hairline splits the week's story from its schedule.
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            ForEach(Array(weekDays.enumerated()), id: \.element) { i, day in
                boardDayRow(day, map: map)
                if i < weekDays.count - 1 {
                    Rectangle().fill(Theme.hairline)
                        .frame(height: 0.5)
                        .padding(.leading, Self.dateColWidth + Theme.Space.md * 2)
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).stroke(Theme.hairline)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private static let dateColWidth: CGFloat = 42

    private func boardDayRow(_ day: Date, map: [Date: [PlannedSession]]) -> some View {
        let sessions = map[Calendar.current.startOfDay(for: day)] ?? []
        let isToday = Calendar.current.isDateInToday(day)
        return HStack(alignment: .top, spacing: Theme.Space.md) {
            boardDateColumn(day, isToday: isToday, hasSessions: !sessions.isEmpty)
            Group {
                if sessions.isEmpty {
                    boardRestLine(day, map: map)
                } else {
                    VStack(spacing: Theme.Space.sm + 2) {
                        ForEach(sessions, id: \.persistentModelID) { session in
                            sessionLine(session)
                                .contextMenu {
                                    if session.status != .completed {
                                        Button { Haptics.medium(); start(session) } label: {
                                            Label("Start", systemImage: "play.fill")
                                        }
                                    }
                                    Button { PlanCoaching.setCompletion(session, done: session.status != .completed, in: context); Haptics.success() } label: {
                                        Label(session.status == .completed ? "Mark not done" : "Mark done",
                                              systemImage: session.status == .completed ? "arrow.uturn.left" : "checkmark")
                                    }
                                    Button { editing = EditingSession(session: session) } label: { Label("Adjust…", systemImage: "slider.horizontal.3") }
                                    Button(role: .destructive) { delete(session) } label: { Label("Remove", systemImage: "trash") }
                                }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, sessions.isEmpty ? 11 : 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Today wears a whisper of tint so the eye lands on it inside the week.
        .background(isToday ? Theme.ink.opacity(0.045) : Color.clear)
    }

    /// The day's anchor: weekday + date, left-aligned. Today fills an ink pill; days with work read
    /// full-ink; rest days recede to tertiary. Sits slightly below the divider so it aligns with the
    /// first session's title rather than the icon top.
    private func boardDateColumn(_ day: Date, isToday: Bool, hasSessions: Bool) -> some View {
        VStack(spacing: 0) {
            Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.rounded(9.5, weight: .black)).tracking(0.4)
            Text(day.formatted(.dateTime.day()))
                .font(.display(19, weight: .heavy)).monospacedDigit()
        }
        .foregroundStyle(isToday ? Theme.background : (hasSessions ? Theme.ink : Theme.inkTertiary))
        .frame(width: Self.dateColWidth, height: 44)
        .background {
            if isToday {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.ink)
            }
        }
        .padding(.top, 1)
    }

    /// A session, flattened onto the board (no card of its own — the board provides the surface).
    /// Tap the body to adjust/move; tap the trailing circle to check it off. Completed reads with a
    /// soft strike so the week's progress is legible at a glance.
    private func sessionLine(_ session: PlannedSession) -> some View {
        let done = session.status == .completed
        return HStack(spacing: Theme.Space.sm + 2) {
            Button { editing = EditingSession(session: session) } label: {
                HStack(spacing: Theme.Space.sm + 2) {
                    Image(systemName: PlanCoaching.icon(for: session))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(done ? Theme.inkTertiary : Theme.ink)
                        .frame(width: 34, height: 34)
                        .background { Circle().fill(Theme.background); Circle().stroke(Theme.hairline) }
                    VStack(alignment: .leading, spacing: 2) {
                        let kind = sessionKindLabel(session)
                        if let kind {
                            Text(kind)
                                .font(.rounded(9, weight: .black)).tracking(1)
                                .foregroundStyle(Theme.inkTertiary)
                        }
                        // The eyebrow already names the kind, so the line drops it ("4 mi ~8:05 /mi",
                        // not "Tempo 4 mi…" under "TEMPO RUN").
                        Text(PlanCoaching.brief(for: session, distanceUnit: distanceUnit,
                                                dropLeadingType: kind != nil))
                            .font(.rounded(Theme.FontSize.body, weight: .semibold))
                            .foregroundStyle(done ? Theme.inkTertiary : Theme.ink)
                            .strikethrough(done, color: Theme.inkTertiary)
                            .lineLimit(1).minimumScaleFactor(0.85)
                            .multilineTextAlignment(.leading)
                        // A strength day names its lifts — "Squat · RDL · Split Squat · Row" reads
                        // in a way "4 exercises" never will (recognition beats abstraction; you
                        // know instantly whether it's a day you like). Replaces the generator's
                        // filler rationale ("Full Body day."), which said nothing the eyebrow and
                        // count hadn't.
                        if !done, session.discipline == .strength, let lifts = liftNamesLine(session) {
                            Text(lifts).font(.rounded(Theme.FontSize.caption, weight: .regular))
                                .foregroundStyle(Theme.inkTertiary)
                                .lineLimit(1).minimumScaleFactor(0.85)
                                .multilineTextAlignment(.leading)
                        }
                        // ANY session with a why explains itself on the board — eased, deload,
                        // rebuild-week, and injury-converted sessions carry rationales while still
                        // `.planned`; showing them only when `.moved` left a mystery "Ride 40m"
                        // with its explanation written but never rendered. The one exception: the
                        // strength generator's "Full Body day." filler, whose slot the lift names
                        // now occupy — a REAL strength rationale (an adaptation's why) still shows.
                        if !done, let why = session.rationale, !why.isEmpty,
                           !(session.discipline == .strength && Self.isGenericStrengthFiller(why)) {
                            Text(why).font(.rounded(Theme.FontSize.caption, weight: .regular))
                                .foregroundStyle(Theme.inkTertiary)
                                .lineLimit(2).multilineTextAlignment(.leading)
                        }
                        // The long run is the keystone session of an endurance week, and it now
                        // wears its fuel plan on the board — the same deterministic FuelingGuide
                        // line the Today deck and the detail sheet already show (≥1 h runs only,
                        // so ordinary days stay slim). Fueling, not dieting.
                        if !done, let fuel = planFuelLine(session) {
                            HStack(spacing: 4) {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.purple)
                                Text(fuel)
                                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                                    .foregroundStyle(Theme.inkSecondary)
                                    .lineLimit(1).minimumScaleFactor(0.85)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            checkButton(session, done: done)
        }
        .frame(maxWidth: .infinity)
    }

    /// The strength generator writes its filler rationale as "\(label) day." ("Full Body day.",
    /// "Push day."). The label itself isn't persisted on `PlannedSession`, so the filler is
    /// recognized by its shape — a short letters-and-spaces head before " day." — which a real
    /// adaptation rationale ("Eased after your 8/10 day.") never matches.
    static func isGenericStrengthFiller(_ why: String) -> Bool {
        guard why.hasSuffix(" day.") else { return false }
        let head = why.dropLast(5)
        return !head.isEmpty && head.count <= 16
            && head.allSatisfy { $0.isLetter || $0 == " " || $0 == "&" }
    }

    /// The first few lift names, joined the way a lifter scans them; overflow stays honest
    /// ("Back Squat · Bench Press · Row +2") instead of truncating mid-name. Equipment prefixes
    /// drop for density — on a one-line board "Barbell Back Squat" spends a third of its width
    /// saying barbell, which is coach shorthand nobody needs ("Back Squat" IS the barbell lift);
    /// the detail sheet keeps full names.
    private func liftNamesLine(_ session: PlannedSession) -> String? {
        // Cache hit for the displayed week (built in rebuildDerived — the raw walk faults one
        // Exercise object per lift, per row, per render); fresh compute stays as the fallback so
        // a stale frame renders correctly rather than blank.
        liftLinesCache[session.persistentModelID] ?? Self.buildLiftLine(session)
    }
    private static func buildLiftLine(_ session: PlannedSession) -> String? {
        let prefixes = ["Barbell ", "Dumbbell ", "Machine ", "Cable ", "Kettlebell "]
        let names = session.strengthTargets
            .sorted { $0.order < $1.order }
            .compactMap { $0.exercise?.name }
            .map { name in
                prefixes.first(where: name.hasPrefix).map { String(name.dropFirst($0.count)) } ?? name
            }
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(3).joined(separator: " · ")
        return names.count > 3 ? "\(shown) +\(names.count - 3)" : shown
    }

    /// "30–60 g carbs/hr" — the same deterministic gate as the Today deck and the session sheet
    /// (running, ≥1 h estimated), so the surfaces can never disagree. The board keeps just the
    /// number (the row is a glance line and "· drink to thirst" clipped it); the sheet carries
    /// the full guidance.
    private func planFuelLine(_ session: PlannedSession) -> String? {
        guard session.discipline == .running,
              let dur = FuelingGuide.estimatedDurationS(distanceM: session.targetDistanceM,
                                                        paceSPerKm: session.targetPaceSPerKm,
                                                        durationS: session.targetDurationS) else { return nil }
        let g = FuelingGuide.guidance(durationS: dur, isRace: session.runType == .race)
        guard let carbs = g.carbsPerHour else { return nil }
        return "\(carbs.lowerBound)–\(carbs.upperBound) g carbs/hr"
    }

    /// The session's TYPE as a quiet eyebrow ("TEMPO RUN", "LONG RUN", "STRENGTH") — the Runna
    /// pattern: what KIND of day it is reads before the numbers do.
    private func sessionKindLabel(_ session: PlannedSession) -> String? {
        if session.discipline == .strength { return "STRENGTH" }
        if let wt = session.workoutType, wt != .run, !wt.isStrengthStyle { return wt.title.uppercased() }
        if let rt = session.runType {
            if rt == .race { return "RACE DAY" }        // the season's crown — never "RACE RUN"
            return rt == .intervals ? "INTERVALS" : "\(rt.rawValue.uppercased()) RUN"
        }
        return nil
    }

    private func checkButton(_ session: PlannedSession, done: Bool) -> some View {
        Button {
            Haptics.success()
            withAnimation(Motion.standard) { PlanCoaching.setCompletion(session, done: !done, in: context) }
        } label: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(done ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.inkTertiary.opacity(0.7)))
                .frame(width: 34, height: 44, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(done ? "Completed. Tap to undo." : "Mark done")
    }

    /// A rest day stays quiet but no longer says nothing: one deterministic line of WHY it sits
    /// where it does (`RestDayLine` — fresh legs for tomorrow's long run, absorbing yesterday's
    /// intervals, the taper doing its work), falling back to the plain "Rest day" when no rule
    /// fires. Half the board's rows are rest in a normal week; they were the page's only rows
    /// carrying zero information. Still recedes, still tappable to add a session.
    private func boardRestLine(_ day: Date, map: [Date: [PlannedSession]]) -> some View {
        // Once, not twice — the accessibility label is an eagerly-evaluated argument, so reading
        // `restLine` there re-ran the whole engine call for every rest row.
        let line = restLine(for: day, in: map) ?? "Rest day"
        return Button { presentAdd(for: day) } label: {
            HStack(spacing: Theme.Space.sm) {
                Text(line)
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary.opacity(0.75))
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.inkTertiary.opacity(0.55))
            }
            .frame(minHeight: 34)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(line) Tap to add a session.")
    }

    /// Feed `RestDayLine` from the board's own memoized week map. Neighbours outside the displayed
    /// week read as `.none` on purpose — the board is the week as one object, and a Sunday rest
    /// explaining itself off last week's board would be reaching outside the frame.
    private func restLine(for day: Date, in map: [Date: [PlannedSession]]) -> String? {
        let cal = Calendar.current
        func neighbor(_ offset: Int) -> RestDayLine.Neighbor {
            guard let d = cal.date(byAdding: .day, value: offset, to: day) else { return .none }
            let sessions = map[cal.startOfDay(for: d)] ?? []
            return RestDayLine.strongest(sessions.map(neighborKind))
        }
        return RestDayLine.line(yesterday: neighbor(-1), tomorrow: neighbor(1),
                                dayAfter: neighbor(2), phase: weekPhase)
    }

    private func neighborKind(_ s: PlannedSession) -> RestDayLine.Neighbor {
        if s.discipline == .strength { return .strength }
        guard let rt = s.runType else { return .easy }
        if rt == .race { return .race }
        if rt == .long { return .long }
        return rt.isQuality ? .quality : .easy
    }

    /// Never a dead end: the tab's whole job is the plan, so the empty state carries the way to one.
    /// (The old copy said "finish onboarding" — wrong for anyone who wiped data or hit an edge case
    /// post-onboarding — and the header's "Start a new plan" menu doesn't render in this branch.)
    private var emptyState: some View {
        VStack(spacing: Theme.Space.lg) {
            BrandMark(size: 72)
            Text("No plan yet").font(.display(Theme.FontSize.headline, weight: .heavy)).foregroundStyle(Theme.ink)
            Text("Tell us your goal and we'll build a week that fits — race or no race.")
                .font(.rounded(Theme.FontSize.body, weight: .regular)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
            if profiles.first != nil {
                Button { Haptics.light(); showNewPlan = true } label: {
                    Text("Build my plan")
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.background)
                        .padding(.horizontal, Theme.Space.xl).padding(.vertical, 14)
                        .background(Capsule().fill(Theme.ink))
                }
                .buttonStyle(.plain)
                .padding(.top, Theme.Space.sm)
                .accessibilityLabel("Build my plan")
                // The other door (owner call 2026-07-30): no prescriptions, ever — an empty
                // self-coached week the athlete fills with their own sessions and the library.
                Button { Haptics.light(); startSelfCoached() } label: {
                    Text("I'll plan it myself")
                        .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, Theme.Space.xl).padding(.vertical, 13)
                        .background(Capsule().stroke(Theme.ink, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Plan it myself — no coach plan")
            }
        }
        .padding(Theme.Space.xl).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Derived

    /// One map read for the whole list — reading `liveWeekMap` per day re-evaluated the token
    /// (two plan-relationship faults each) seven times over.
    private var weekSessions: [PlannedSession] {
        let map = liveWeekMap
        let cal = Calendar.current
        return days.flatMap { map[cal.startOfDay(for: $0)] ?? [] }
    }

    private var weekTitle: String {
        if isCurrentWeek { return "This week" }
        // Named by position, not date range: the arc's bars carry no numerals, so this title is
        // where "which week am I looking at" lives — and the board's own rows already show dates.
        if let idx = planWeekIndex(of: weekStart) { return "Week \(idx + 1)" }
        return weekLabel
    }

    private func weekSummary(done: Int, total: Int) -> String {
        guard total > 0 else { return "Open week · tap + to plan" }
        if done == total { return "All done — strong week." }
        return "\(done) done · \(total - done) to go"
    }

    private var weekLabel: String {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        return "\(weekStart.formatted(.dateTime.month().day())) – \(end.formatted(.dateTime.month().day()))"
    }

    private func shiftWeek(_ delta: Int) {
        withAnimation(Motion.standard) {
            if let d = Calendar.current.date(byAdding: .weekOfYear, value: delta, to: weekStart) { weekStart = d }
        }
    }

    private var card: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
    }
}
