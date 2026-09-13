import SwiftUI
import SwiftData

/// Plan — a calm weekly command center (PRD §7.7). A week hero with a completion ring, an optional
/// "tune this week" nudge from the coach, then each day as a date badge + quiet session cards. Tap a
/// session to adjust/move/remove it; tap its circle to check it off (earned iridescent). Missed work
/// moves with a one-line note. No red, no guilt.
struct PlanView: View {
    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services
    @Environment(PaywallController.self) private var paywall
    @Environment(CoachPresenter.self) private var coach
    @Environment(AppRouter.self) private var router   // workoutLaunch — the shell-level recorder
    @ReducedMotionPreference private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var weekNumberSize: CGFloat = 15
    @Query private var profiles: [UserProfile]
    @Query private var workouts: [Workout]
    /// The closing block's report for the renewal card (`PlanBlockReview`), refreshed with the
    /// derived state so `body` never walks the journal.
    @State private var blockReview: BlockReport.Text?
    // The season sidecars, live: a few rows each, so the next tune-up is a filter, not a fetch
    // in the body (2026-09-03).
    @Query private var seasonRecords: [RunningSeasonRecord]
    @Query private var eventRecords: [RunningEventRecord]
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
    @State private var libraryAfterAdd = false
    @State private var addDay = Date()
    @State private var editing: EditingSession?
    @State private var adjusted = false
    @State private var propagatedPlanSignature: Int?
    @State private var pendingStart: PlannedSession?     // start after the detail sheet dismisses
    /// Created on first cardio start, not at init: this view is constructed on every RootView
    /// body pass (the TabView content builder runs eagerly), and a `CLLocationManager` per pass
    /// for a one-shot authorization ask was pure launch cost (perf audit 2026-08-13). Held in
    /// @State so the manager outlives the authorization prompt it raises.
    @State private var showSettings = false
    @State private var showNewPlan = false
    /// Your plans (2026-09-07): current, upcoming, drafts, previous. Hosted on its own background
    /// presenter below, off this view's already-long presentation chain.
    @State private var showYourPlans = false
    /// A sheet's request for what opens after it has gone (see `shelfPresenters`).
    @State private var shelfFollowUp: ShelfFollowUp?
    /// Manage plan's last receipt, kept here so Done and a reopen keep its Undo.
    @State private var manageReceipt: ManageReceipt?
    /// The `--plan-*` presentation hooks fire once, not on every return to the tab.
    @State private var debugHooksFired = false
    /// The day the race settle and the upcoming-plan sweep last ran on appear.
    @State private var settledOn: Date?
    /// Manage plan (2026-09-07): every adjustment by intent, each as a proposal with Apply / Undo.
    @State private var showManage = false
    /// The plan builder, opened from Your plans on a fresh blueprint or an existing draft.
    @State private var composing: PlanComposeTarget?
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
    @State private var derivedPlanID: PersistentIdentifier?
    @State private var isVisible = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var weekIndexCache: [Date: Int] = [:]
    @State private var weekBarBaseLabels: [String] = []
    /// The tune proposal uses the load-only engine path; chart series are never built here.
    @State private var tuneProposal: PlanCoaching.Proposal?
    // — Drag to move (2026-09-05) —
    /// The day row currently under a dragged session, and the session row that would trade days
    /// with it. Only one is ever set: a hovered session outranks the day beneath it, so the board
    /// never shows a move target and a swap target at once.
    @State private var dropDay: Date?
    @State private var swapTargetID: UUID?
    /// The transient placement note for the session the athlete just moved (`PlanMoveAdvice`).
    /// Deliberately not persisted onto `rationale` — the sentence is true about a week the next
    /// drag can change, so it lives beside the session until the athlete moves on.
    @State private var moveNote: (id: UUID, text: String)?
    @State private var showAwayDays = false

    private struct CoachsReadModel: Equatable {
        var hasRacePrediction = false
        var paceResult: PaceInsights.Result?
        var hybridInsight: String?
        var intensityMix: IntensityMix.Mix?
        var hasContent: Bool {
            hasRacePrediction || paceResult != nil || hybridInsight != nil || intensityMix != nil
        }
    }

    /// Identifiable wrapper so `.sheet(item:)` works regardless of the model's own conformance.
    private struct EditingSession: Identifiable {
        let session: PlannedSession
        /// Open straight into the sheet's "Move to" strip — the pointer-free path to the same
        /// reschedule the board's drag performs (context menu, and the VoiceOver action).
        var startInMove = false
        var id: PersistentIdentifier { session.persistentModelID }
    }

    private var plan: TrainingPlan? { profiles.first?.plan }

    /// The notification mailboxes (`AppRouter.pendingPlanWeek` / `pendingPlanSessionID`): jump to
    /// the week, then open the session once the tab switch has settled (a sheet presented in the
    /// same update as a tab change is dropped on the floor). A week still behind the Pro boundary
    /// stays there: the board lands on the current week and the sheet is not forced past the gate
    /// the + button and a menu move already respect.
    private func consumeNotificationMailboxes() {
        let cal = planCalendar
        if let date = router.pendingPlanWeek {
            router.pendingPlanWeek = nil
            if let start = cal.dateInterval(of: .weekOfYear, for: date)?.start {
                weekStart = start
            }
        }
        guard let id = router.pendingPlanSessionID else { return }
        router.pendingPlanSessionID = nil
        guard let session = plan?.sessions.first(where: { $0.id == id }),
              let start = cal.dateInterval(of: .weekOfYear, for: session.date)?.start else { return }
        guard AdaptivePlanService.showsDetails(session, plan: plan) else { weekStart = start; return }
        weekStart = start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            // The same appear may have activated an upcoming plan and cascade-deleted this
            // session; a sheet on a deleted model traps.
            guard !session.isDeleted, session.modelContext != nil else { return }
            editing = EditingSession(session: session)
        }
    }
    private var planCalendar: Calendar { plan?.adaptiveState?.calendar ?? .current }
    private var distanceUnit: DistanceUnit {
        DistanceUnit(rawValue: profiles.first?.distanceUnit ?? "auto") ?? .auto
    }

    /// The live current week — the tune card and renewal prompt only make sense here.
    private var isCurrentWeek: Bool {
        planCalendar.isDate(weekStart, inSameDayAs: currentWeekStart)
    }
    /// Future weeks are adaptive previews for every subscription tier.
    private var isFutureWeek: Bool { weekStart > currentWeekStart }
    private var awaitingWeeklyReview: Bool {
        guard isCurrentWeek, let state = plan?.adaptiveState else { return false }
        guard plan?.sessions.contains(where: { planCalendar.isDate($0.date, equalTo: currentWeekStart, toGranularity: .weekOfYear) }) == true else { return false }
        if state.lastWeekStart < currentWeekStart { return true }
        return state.reviews.last(where: { $0.id == state.lastWeekKey }).map { $0.viewedAt == nil } ?? false
    }
    private var days: [Date] {
        daysCacheWeek == weekStart ? daysCache : Self.computeDays(from: weekStart, calendar: planCalendar)
    }
    private static func computeDays(from weekStart: Date, calendar: Calendar) -> [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }
    /// The week's sessions grouped by day. Returns the memoized cache while its signature matches the
    /// live plan; otherwise recomputes fresh (cheap, one pass over `plan.sessions`) — so it never
    /// reads a cascade-deleted/removed session, and never flashes an empty board on the first frame.
    private var liveWeekMap: [Date: [PlannedSession]] {
        let map = weekMapToken == currentWeekToken ? weekMap : computeWeekMap()
        return map.mapValues { $0.filter(PlanSessionPresentation.isLive) }
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
        let cal = planCalendar
        let weekDays = Set(days.map { cal.startOfDay(for: $0) })
        var map: [Date: [PlannedSession]] = [:]
        for s in plan.sessions where PlanSessionPresentation.isLive(s) {
            if isCurrentWeek && s.status == .missed { continue }
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
                        .onScrollVisibilityChange(threshold: 0.5) { visible in
                            if visible, isCurrentWeek {
                                services.analytics.log(.adaptive(action: "current_week_viewed", week: AdaptiveTrainingWeek.key(weekStart, calendar: planCalendar), reason: "plan"))
                            }
                        }
                    if showRenewalPrompt { renewalCard.reveal(0.02, once: "plan.renewal") }
                    // Self-coached: no tune proposals — the coach never suggests inside their plan.
                    if isCurrentWeek, plan?.isSelfCoached != true { tuneSection }
                    if plan?.isSelfCoached == true || (!isFutureWeek && !awaitingWeeklyReview) {
                        weekBoard.reveal(0.02, once: "plan.board")
                    }
                    if let plan, !plan.isSelfCoached {
                        AdaptiveWeekView(plan: plan, weekStart: weekStart, unit: distanceUnit)
                    }
                    if !isFutureWeek { coachsRead }
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

    private var observedPlanContent: some View {
        planContent
        .onAppear { isVisible = true; rebuildDerived() }
        .onDisappear { isVisible = false; moveNote = nil }
        // Page changes only refresh week data; structural/data changes refresh the whole readout.
        // The just-moved note is scoped to the week the athlete moved it in, and to this visit.
        .onChange(of: weekStart) { moveNote = nil; rebuildDerived(refreshPlan: false) }
        .onChange(of: plan?.persistentModelID) { rebuildDerived() }
        .onChange(of: plan?.sessions.count) { rebuildDerived() }
        // Counts are not revisions: a date, pace, completed run or unit can change without adding
        // a row. Refresh after saves, never during scrolling/press feedback or unrelated renders.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            // The global recorder can cover a still-mounted Plan tab. Never rebuild analytics
            // for every persisted GPS sample underneath it; refresh once when it closes.
            if isVisible, router.workoutLaunch == nil {
                rebuildDerived()
                let signature = PlanAdjustmentService.signature(of: plan)
                if propagatedPlanSignature != signature, let profile = profiles.first {
                    propagatedPlanSignature = signature
                    PlanAdjustmentService.propagate(profile: profile, workouts: workouts,
                                                    notifications: services.notifications)
                }
            }
        }
        .onChange(of: router.workoutLaunch == nil) { _, recorderClosed in
            if recorderClosed, isVisible {
                rebuildDerived()
                Task { await AdaptivePlanService.prepare(profile: profiles.first, services: services, in: context) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, isVisible else { return }
            // Parked on Plan overnight: a race settles and a due plan starts here too, exactly as
            // on appear (both are idempotent, one predicate fetch when nothing is due).
            if let p = profiles.first {
                Task { await AdaptivePlanService.prepare(profile: p, services: services, in: context) }
                PlanService.settleRaces(for: p, today: Date(), in: context)
                if let activation = PlanLifecycleService.activateDueUpcoming(for: p, today: Date(), in: context) {
                    PlanLifecycleService.propagate(activation, profile: p, workouts: workouts,
                                                   notifications: services.notifications, in: context)
                    weekStart = currentWeekStart
                }
            }
            rebuildDerived()
        }
    }

    var body: some View {
        observedPlanContent
        .background(Theme.background)
        .navigationBarHidden(true)
        .sheet(isPresented: $showingAdd, onDismiss: {
            let openLibrary = libraryAfterAdd
            libraryAfterAdd = false
            if openLibrary { showLibrary = true }
        }) {
            if let plan {
                AddSessionSheet(plan: plan, defaultDate: addDay, onDone: { showingAdd = false },
                                onOpenLibrary: {
                    libraryAfterAdd = true
                    showingAdd = false
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
                               startInMove: item.startInMove,
                               onRemove: { delete(item.session) },
                               onStart: { pendingStart = $0 })
        }
        // The recorder is no longer attached per-tab: `start(_:)` writes `router.workoutLaunch`
        // and the ONE `WorkoutRunner` overlay in `RootView` presents it (shared-map pass 2026-08-19).
        .confirmationDialog("Plan it yourself?", isPresented: $confirmingSelfCoached, titleVisibility: .visible) {
            Button("Take over my plan") { goSelfCoached() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Upcoming prescribed sessions are removed. Everything you've completed stays. You write your own weeks from here (add sessions, use the library), and the coach stops prescribing or adjusting. You can ask for a new plan anytime.")
        }
        .sheet(isPresented: $showAwayDays) {
            let cal = planCalendar
            let weekDays = days
            let busy = Set(weekSessions.filter { $0.status != .completed }.compactMap { session in
                weekDays.firstIndex { cal.isDate($0, inSameDayAs: session.date) }
            })
            AwayDaysSheet(days: weekDays, daysWithSessions: busy) { blocked in
                applyAwayDays(blocked)
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: { rebuildDerived() }) {
            // No plan yet → the sheet must open in CREATE mode, or Save quietly rebuilds nothing
            // and dismisses with a success buzz (the coach's "set up your plan" card hit this).
            if let p = profiles.first {
                PlanSettingsSheet(profile: p, mode: p.plan == nil ? .create : .adjust) { showSettings = false }
            }
        }
        // "Start a new plan" — the same complete form, framed as a beginning: blank name, always
        // rebuilds, honest about replacing the current block (completed work + calibration carry).
        .sheet(isPresented: $showNewPlan, onDismiss: { rebuildDerived() }) {
            if let p = profiles.first { PlanSettingsSheet(profile: p, mode: .create) { showNewPlan = false } }
        }
        // Your plans, Manage plan and the builder get their OWN hosts: this view already chains
        // several presentations, and from the fourth onward a sheet on the same chain can silently
        // fail to present (the same trap RootView and FuelView document). One background view
        // holds all three so the body's modifier chain stays type-checkable.
        .background { shelfPresenters }
        // A coach nav card asked for plan settings — open the sheet the shell steered us toward
        // (onChange covers the case where Plan was already the visible tab).
        .onChange(of: coach.wantsPlanSettings) { _, wants in
            guard wants else { return }
            coach.wantsPlanSettings = false
            showSettings = true
        }
        // A notification about a session (notification pass 2026-09-06): land on its week and open
        // its sheet. `initial: true` covers the tab being built by the switch itself; the change
        // covers Plan already being on screen. Consume-then-nil, like the coach mailbox above.
        .onChange(of: router.pendingPlanSessionID, initial: true) { _, _ in consumeNotificationMailboxes() }
        .onChange(of: router.pendingPlanWeek, initial: true) { _, _ in consumeNotificationMailboxes() }
        .onAppear {
            if coach.wantsPlanSettings {
                coach.wantsPlanSettings = false
                showSettings = true
            }
            // An upcoming plan whose day has come starts here too (Today's bootstrap is the usual
            // door; an athlete who opens straight onto Plan should not see last week's plan).
            // Once per local day on appear (the scene-active path covers a night parked here):
            // `onAppear` re-fires on every tab return and sheet dismissal, and the settle is three
            // fetches each time for a result that cannot change within the day.
            let today = planCalendar.startOfDay(for: Date())
            if settledOn != today, let p = profiles.first {
                settledOn = today
                Task { await AdaptivePlanService.prepare(profile: p, services: services, in: context) }
                PlanService.settleRaces(for: p, today: Date(), in: context)
                if let activation = PlanLifecycleService.activateDueUpcoming(for: p, today: Date(), in: context) {
                    PlanLifecycleService.propagate(activation, profile: p, workouts: workouts,
                                                   notifications: services.notifications, in: context)
                    weekStart = currentWeekStart
                    rebuildDerived()
                }
            }
            #if DEBUG
            // Latched: `onAppear` re-fires on every return to the tab and every sheet dismissal,
            // and an unlatched hook would re-present forever (the Fuel hooks latch the same way).
            let debugHooks = !debugHooksFired
            debugHooksFired = true
            // --plan-your-plans: open the shelf (screenshot verification).
            if debugHooks, ProcessInfo.processInfo.arguments.contains("--plan-your-plans") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showYourPlans = true }
            }
            // --plan-manage: open Manage plan (screenshot verification).
            if debugHooks, ProcessInfo.processInfo.arguments.contains("--plan-manage") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showManage = true }
            }
            // --plan-builder: open the plan builder on a fresh blueprint.
            if debugHooks, ProcessInfo.processInfo.arguments.contains("--plan-builder") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { composing = PlanComposeTarget(record: nil) }
            }
            // --plan-settings: open the plan-settings sheet (screenshot verification; sim can't tap).
            if debugHooks, ProcessInfo.processInfo.arguments.contains("--plan-settings") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showSettings = true }
            }
            // --plan-new: open the start-a-new-plan flow directly.
            if debugHooks, ProcessInfo.processInfo.arguments.contains("--plan-new") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showNewPlan = true }
            }
            // --plan-add: open the plan-a-session sheet directly (screenshot verification).
            if debugHooks, ProcessInfo.processInfo.arguments.contains("--plan-add") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { presentAdd(for: Date()) }
            }
            // --plan-away: open the "I'm away" week editor directly (screenshot verification).
            if debugHooks, ProcessInfo.processInfo.arguments.contains("--plan-away") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showAwayDays = true }
            }
            // --plan-library: open the workout library directly (screenshot verification — the
            // catalog is browsed several levels in, and sim taps through two sheets are unreliable).
            if debugHooks, ProcessInfo.processInfo.arguments.contains("--plan-library") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showLibrary = true }
            }
            // --plan-self-coached: take over the seeded plan (screenshot verification of the mode).
            if ProcessInfo.processInfo.arguments.contains("--plan-self-coached") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { goSelfCoached() }
            }
            // --plan-locked-week: land on next week (the Pro-locked state) for lock-pill verification.
            if ProcessInfo.processInfo.arguments.contains("--plan-locked-week"),
               let next = planCalendar.date(byAdding: .weekOfYear, value: 1, to: weekStart) {
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
        if t.isStrengthStyle { router.workoutLaunch = .strength(type: t, planned: session) }
        else if t.isTimed { router.workoutLaunch = .timed(type: t) }
        else {
            // The SHARED service (2026-08-28) — one grant, seen by every surface incl. Today's map.
            services.location.requestAuthorization()
            router.workoutLaunch = .cardio(type: t, goalMeters: session.targetDistanceM, planned: session, guideRoute: [])
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
        let saved = PlanMutation.attempt(in: context, fallback: false) {
            let upcoming = plan.sessions.filter { $0.status != .completed && $0.completedWorkout == nil }
            plan.sessions.removeAll { s in upcoming.contains { $0.id == s.id } }
            upcoming.forEach(context.delete)
            plan.isSelfCoached = true
            plan.weekPhases = []                 // no macrocycle claim on weeks we didn't write
            plan.pendingP5kSPerKm = nil          // no banked recalibration evidence to apply later
            plan.pendingP5kAt = nil
            return true
        }
        guard saved else { return }
        rebuildDerived()
        Haptics.success()
        // Reminders, the widget and the wrist describe sessions that no longer exist.
        if let profile = profiles.first {
            PlanAdjustmentService.propagate(profile: profile, workouts: workouts, notifications: services.notifications)
        }
    }

    /// The brand-new athlete who never wants prescriptions: an empty self-coached container, ready
    /// for their own sessions. `p5kSPerKm` keeps the model default — library workouts still price
    /// paces conservatively until a real run calibrates nothing (self-coached never recalibrates).
    private func startSelfCoached() {
        guard let profile = profiles.first, profile.plan == nil else { return }
        let saved = PlanMutation.attempt(in: context, fallback: false) {
            let plan = TrainingPlan()
            plan.isSelfCoached = true
            plan.goal = profile.goal
            plan.disciplines = profile.disciplines
            plan.blockStart = planCalendar.startOfDay(for: Date())
            context.insert(plan)
            profile.plan = plan
            return true
        }
        guard saved else { return }
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
            .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Your week, sequenced. \(insight)")
        }
    }

    /// The cross-discipline read for the displayed week — nil unless it pairs a leg day with a hard/long
    /// run. Infers "leg day" from a strength session's lower-body primary muscles.
    private var hybridWeekInsight: String? {
        guard let plan else { return nil }
        let cal = planCalendar
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

    /// The easy-versus-quality split of the athlete's recent RUNNING (`IntensityMix`). The engine
    /// has been built and tested since the endurance pivot and rendered on no surface at all — this
    /// is the page it belongs on, because it is the one number that says whether the week you are
    /// looking at is the week you have actually been running.
    ///
    /// Six weeks of runs, priced against the athlete's own calibrated 5k; a session the plan
    /// prescribed as quality counts as quality regardless of the pace it came out at. Nil until
    /// there are enough runs to mean anything (`IntensityMix.minRuns`).
    private func recentIntensityMix(p5k: Double, calendar cal: Calendar) -> IntensityMix.Mix? {
        guard p5k > 0, let since = cal.date(byAdding: .day, value: -42, to: Date()) else { return nil }
        let inputs: [IntensityMix.RunInput] = workouts
            .filter { $0.type == .run && $0.startedAt >= since }
            .compactMap { workout in
                guard let pace = workout.gps?.avgPaceSPerKm, pace > 0 else { return nil }
                return .init(paceSPerKm: pace,
                             plannedQuality: workout.plannedSession?.runType?.isQuality)
            }
        return IntensityMix.analyze(runs: inputs, p5kSPerKm: p5k)
    }

    @ViewBuilder
    private var intensityCard: some View {
        if let mix = coachsReadModel.intensityMix {
            let easyPct = Int((mix.easyFraction * 100).rounded())
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text("YOUR RECENT MIX").font(.rounded(Theme.FontSize.label, weight: .bold))
                        .tracking(1.2).foregroundStyle(Theme.inkTertiary)
                    Text("\(easyPct)% easy · \(100 - easyPct)% quality")
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Theme.ink)
                    Text(mix.blurb)
                        .font(.rounded(Theme.FontSize.caption, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // The sample, said plainly. A split off six runs is not the same claim as a
                    // split off thirty, and the card should never let it read like one.
                    Text("Last 6 weeks · \(mix.easyCount + mix.hardCount) runs")
                        .font(.rounded(Theme.FontSize.label, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                        .padding(.top, 1)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.md).frame(maxWidth: .infinity, alignment: .leading)
            .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Your recent mix. \(easyPct) percent easy. \(mix.blurb)")
        }
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
                                       p5kSPerKm: plan.p5kSPerKm, distanceUnit: distanceUnit,
                                       exponent: PlanAthleteStateRecord.fetch(planID: plan.id, in: context)?.riegelExponent ?? RacePredictor.riegelExponent,
                                       evidenceNote: raceEvidenceNote(plan))
                }
                if let result = coachsReadModel.paceResult {
                    PaceInsightCard(result: result)
                }
                intensityCard
                hybridCard
            }
        }
    }

    private func raceEvidenceNote(_ plan: TrainingPlan) -> String {
        if let observed = plan.lastRecalibratedAt {
            return "Paces last calibrated from a logged effort on \(observed.formatted(date: .abbreviated, time: .omitted))."
        }
        if let preferences = profiles.first?.planPreferences, preferences.benchmarkTimeS != nil {
            if let date = preferences.benchmarkPerformedAt {
                return "Starting estimate from your result on \(date.formatted(date: .abbreviated, time: .omitted)); it may differ from today's fitness."
            }
            return "Starting estimate from your entered result. Its date is unknown."
        }
        return "Provisional estimate from your starting profile. Logged efforts help refine it."
    }

    // MARK: Moving a session (drag on the board, or the Move menu)

    /// The Move submenu — the same three destinations the drag covers, reachable without one.
    /// "Next week" is the only door here that leaves the displayed week, so it is the only one that
    /// meets the Pro boundary the board itself draws over future weeks.
    @ViewBuilder
    private func moveMenu(_ session: PlannedSession) -> some View {
        Menu {
            Button { shift(session, byDays: 1) } label: { Label("To tomorrow", systemImage: "arrow.right") }
            Button { shift(session, byDays: 7) } label: { Label("To next week", systemImage: "arrow.uturn.right") }
            Button { editing = EditingSession(session: session, startInMove: true) } label: {
                Label("Pick a day…", systemImage: "calendar")
            }
        } label: {
            Label("Move", systemImage: "calendar")
        }
    }

    // MARK: Week-shaped edits (the whole week at once)

    /// Every still-open session in the displayed week slides a day. Completed work never moves —
    /// a finished day is a record of what happened, not a plan.
    private func shiftDisplayedWeek(by days: Int) {
        let cal = planCalendar
        let movable = weekSessions.filter { $0.status != .completed && !PlanCoaching.isFixedDate($0) }
        guard !movable.isEmpty else {
            ToastCenter.shared.show(icon: "calendar", line: "Nothing to move this week")
            return
        }
        let targets = movable.compactMap { cal.date(byAdding: .day, value: days, to: $0.date) }
        // Sliding forward can push the last day of the week over the Pro boundary, where the
        // athlete could not see where it went. Same gate the + button and a menu move already use.
        if let furthest = targets.max(),
           let week = cal.dateInterval(of: .weekOfYear, for: furthest)?.start,
           week > currentWeekStart, plan?.isSelfCoached != true {
            ToastCenter.shared.show(icon: "calendar", line: "Future weeks adapt after this week. Choose a day in your current week.")
            return
        }
        guard PlanMutation.edit(in: context, {
            PlanCoaching.reschedule(movable.compactMap { session in
                cal.date(byAdding: .day, value: days, to: session.date).map { (session, $0) }
            }, in: context)
        }) else { return }
        withAnimation(reduceMotion ? nil : Motion.standard) {
            moveNote = nil
            rebuildDerived(refreshPlan: false)
        }
        Haptics.success()
        ToastCenter.shared.show(icon: "calendar",
                                line: days > 0 ? "Week pushed on a day" : "Week pulled back a day")
    }

    /// Take days out of the week and let the work find the nearest open day around them
    /// (`PlanWeekEdit`). Anything with nowhere to go stays put and is named, never stacked onto a
    /// day that is already carrying a session.
    private func applyAwayDays(_ blocked: Set<Int>) {
        guard !blocked.isEmpty else { return }
        let cal = planCalendar
        let weekDays = days.map { cal.startOfDay(for: $0) }
        let movable = weekSessions.filter { $0.status != .completed && !PlanCoaching.isFixedDate($0) }
        let indexed: [(id: UUID, dayIndex: Int)] = movable.compactMap { session in
            guard let index = weekDays.firstIndex(of: cal.startOfDay(for: session.date)) else { return nil }
            return (session.id, index)
        }
        let placements = PlanWeekEdit.awayPlacements(sessions: indexed, blocked: blocked)
        let strandedCount = indexed.filter { blocked.contains($0.dayIndex) && placements[$0.id] == nil }.count

        guard !placements.isEmpty else {
            ToastCenter.shared.show(
                icon: "airplane",
                line: strandedCount > 0 ? "No free days left to move to" : "Nothing planned on those days")
            return
        }
        guard PlanMutation.edit(in: context, {
            PlanCoaching.reschedule(movable.compactMap { session in
                guard let index = placements[session.id], index < weekDays.count else { return nil }
                return (session, weekDays[index])
            }, in: context)
        }) else { return }
        withAnimation(reduceMotion ? nil : Motion.standard) {
            moveNote = nil
            rebuildDerived(refreshPlan: false)
        }
        Haptics.success()
        let moved = placements.count
        // Say what actually happened, including the part that did not work out.
        let line = strandedCount > 0
            ? "Moved \(moved), \(strandedCount) stayed put"
            : (moved == 1 ? "Moved 1 session" : "Moved \(moved) sessions")
        ToastCenter.shared.show(icon: "airplane", line: line)
    }

    /// Repeat a session onto later weeks. The three answers athletes actually give when asked how
    /// often: once more, for a month, or all the way to the end of the block.
    @ViewBuilder
    private func repeatMenu(_ session: PlannedSession) -> some View {
        Menu {
            Button { repeatSession(session, weeks: 1) } label: { Label("Next week", systemImage: "arrow.uturn.right") }
            Button { repeatSession(session, weeks: 4) } label: { Label("Every week for 4 weeks", systemImage: "repeat") }
            if remainingBlockWeeks(after: session) > 4 {
                Button { repeatSession(session, weeks: remainingBlockWeeks(after: session)) } label: {
                    Label("Every week to the end of the block", systemImage: "flag.checkered")
                }
            }
        } label: {
            Label("Repeat", systemImage: "plus.square.on.square")
        }
    }

    /// Whole weeks left in the block after this session's own week — the ceiling on "to the end".
    private func remainingBlockWeeks(after session: PlannedSession) -> Int {
        let cal = planCalendar
        guard let last = planWeekStarts.last,
              let week = cal.dateInterval(of: .weekOfYear, for: session.date)?.start,
              let span = cal.dateComponents([.weekOfYear], from: week, to: last).weekOfYear else { return 0 }
        return max(0, span)
    }

    private func repeatSession(_ session: PlannedSession, weeks: Int) {
        guard weeks > 0 else { return }
        // Every copy lands on a future week, which is the Pro boundary the board already draws.
        guard plan?.isSelfCoached == true else {
            ToastCenter.shared.show(icon: "calendar", line: "Your coach will shape future weeks from your training. You can move sessions within this week.")
            return
        }
        let cal = planCalendar
        let days = (1...weeks).compactMap { cal.date(byAdding: .weekOfYear, value: $0, to: session.date) }
        let written = PlanCoaching.duplicate(session, onto: days, to: plan, in: context)
        guard written > 0 else {
            // Every target day already held this session. Say so rather than buzzing success at a
            // no-op — the athlete asked for something that was already true.
            ToastCenter.shared.show(icon: "checkmark", line: "Already on those weeks")
            return
        }
        withAnimation(reduceMotion ? nil : Motion.standard) { rebuildDerived() }
        Haptics.success()
        ToastCenter.shared.show(icon: "plus.square.on.square",
                                line: written == 1 ? "Repeated next week" : "Added to \(written) weeks")
    }

    /// Move a session relative to its own date (not to today — "tomorrow" means the day after the
    /// session, which is what "move this on by a day" means when you are looking at a future week).
    private func shift(_ session: PlannedSession, byDays days: Int) {
        guard let target = planCalendar.date(byAdding: .day, value: days, to: session.date) else { return }
        let targetDay = planCalendar.startOfDay(for: target)
        // Landing behind the Pro frost would drop the session where the athlete cannot see it —
        // the same reason the + button routes to the paywall on a locked week.
        if let week = planCalendar.dateInterval(of: .weekOfYear, for: targetDay)?.start,
           week > currentWeekStart, plan?.isSelfCoached != true {
            ToastCenter.shared.show(icon: "calendar", line: "Future weeks adapt after this week. Choose a day in your current week.")
            return
        }
        move(session, to: targetDay)
    }

    /// Resolve a dropped payload against the live plan and move it. Returns false (the drop is
    /// refused, and the session springs back) when the payload names nothing we hold or the session
    /// is already on that day, so an accidental drop on the row it started in is a no-op.
    @discardableResult
    private func move(sessionID: UUID, to day: Date) -> Bool {
        guard let session = plan?.sessions.first(where: { $0.id == sessionID }),
              planCalendar.startOfDay(for: session.date) != day else { return false }
        move(session, to: day)
        return true
    }

    private func move(_ session: PlannedSession, to day: Date) {
        // Read the landing spot BEFORE the move, so the moved session is not counted as its own
        // neighbour, then write the note against the week as it will actually be.
        let advice = placementNote(for: session, landingOn: day)
        guard PlanMutation.edit(in: context, { PlanCoaching.reschedule(session, to: day, in: context) }) else { return }
        withAnimation(reduceMotion ? nil : Motion.standard) {
            // A move changes neither the session count nor the displayed week, so the week map's
            // signature does not flip on its own — rebuild explicitly or the board keeps drawing
            // the session on the day it left.
            rebuildDerived(refreshPlan: false)
            moveNote = advice.map { (session.id, $0) }
        }
        Haptics.success()
        ToastCenter.shared.show(icon: "calendar",
                                line: "Moved to \(day.formatted(.dateTime.weekday(.wide)))")
    }

    /// Trade two sessions' days. The move athletes actually ask for, and the reason dropping onto a
    /// session reads differently from dropping onto its day.
    @discardableResult
    private func swap(sessionID: UUID, with target: PlannedSession) -> Bool {
        guard sessionID != target.id,
              let source = plan?.sessions.first(where: { $0.id == sessionID }),
              planCalendar.startOfDay(for: source.date) != planCalendar.startOfDay(for: target.date)
        else { return false }
        guard PlanMutation.edit(in: context, { PlanCoaching.swapDays(source, target, in: context) }) else { return false }
        withAnimation(reduceMotion ? nil : Motion.standard) {
            rebuildDerived(refreshPlan: false)
            // A swap moves two sessions and leaves no single "here is where it landed" to annotate.
            moveNote = nil
        }
        Haptics.success()
        ToastCenter.shared.show(icon: "arrow.left.arrow.right", line: "Swapped days")
        return true
    }

    /// `PlanMoveAdvice` fed from the live plan: what the landing day already holds, and what sits on
    /// either side of it. The moved session is excluded from its own landing day so it can never be
    /// its own reason for a "two hard sessions" note.
    private func placementNote(for session: PlannedSession, landingOn day: Date) -> String? {
        guard let plan else { return nil }
        let cal = planCalendar
        func kinds(_ offset: Int) -> RestDayLine.Neighbor {
            guard let d = cal.date(byAdding: .day, value: offset, to: day) else { return .none }
            let target = cal.startOfDay(for: d)
            return RestDayLine.strongest(plan.sessions
                .filter { $0.id != session.id && cal.startOfDay(for: $0.date) == target }
                .map(neighborKind))
        }
        return PlanMoveAdvice.note(moved: neighborKind(session), sameDay: kinds(0),
                                   dayBefore: kinds(-1), dayAfter: kinds(1))
    }

    private func delete(_ session: PlannedSession) {
        guard PlanSessionPresentation.isLive(session) else { return }
        let wasOpen = session.status != .completed
        // Invalidate before save publishes the deletion, not after SwiftUI observes it.
        weekMap = [:]
        weekMapToken = 0
        let saved = PlanMutation.attempt(in: context, fallback: false) {
            plan?.sessions.removeAll { $0.id == session.id }
            context.delete(session)
            return true
        }
        guard saved else { rebuildDerived(); return }
        if wasOpen { services.analytics.log(.adaptive(action: "workout_skipped", week: AdaptiveTrainingWeek.key(weekStart, calendar: planCalendar), reason: "removed")) }
        rebuildDerived()
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
                        // Week-shaped edits, scoped by name to the week on screen. Travel and
                        // illness take DAYS, not sessions, and doing that one drag at a time was
                        // five gestures for a long weekend.
                        Section(weekTitle) {
                            Button { shiftDisplayedWeek(by: 1) } label: {
                                Label("Push the week on a day", systemImage: "arrow.right")
                            }
                            Button { shiftDisplayedWeek(by: -1) } label: {
                                Label("Pull the week back a day", systemImage: "arrow.left")
                            }
                            Button { showAwayDays = true } label: {
                                Label("I'm away some days…", systemImage: "airplane")
                            }
                        }
                        Button { PerfMark.start("manage-open"); showManage = true } label: {
                            Label("Manage plan", systemImage: "wrench.and.screwdriver")
                        }
                        if plan?.isSelfCoached != true {
                            Button { showSettings = true } label: {
                                Label("Adjust this plan", systemImage: "slider.horizontal.3")
                            }
                        }
                        Button { showNewPlan = true } label: {
                            Label(plan?.isSelfCoached == true ? "Build me a plan" : "Start a new plan",
                                  systemImage: "arrow.triangle.2.circlepath")
                        }
                        Button { PerfMark.start("your-plans-open"); showYourPlans = true } label: {
                            Label("Your plans", systemImage: "square.stack")
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

    /// The three shelf-related sheets on their own presenters (see the body's `.background`).
    /// A sheet that opens another sheet never flips both flags in one tick: it records what
    /// should follow and dismisses, and the follow-up runs from `onDismiss` once the outgoing
    /// presentation has actually gone. Two presentations changing in the same transaction is
    /// exactly the case UIKit refuses (and does not retry), which left a flag set and the sheet
    /// unable to reopen.
    private var shelfPresenters: some View {
        ZStack {
            Color.clear.sheet(isPresented: $showYourPlans, onDismiss: shelfSheetDismissed) { yourPlansSheet }
            Color.clear.sheet(isPresented: $showManage, onDismiss: shelfSheetDismissed) { manageSheet }
            Color.clear.sheet(item: $composing, onDismiss: shelfSheetDismissed) { target in builderSheet(target) }
        }
    }

    /// What a shelf sheet asked for on its way out.
    private enum ShelfFollowUp {
        case yourPlans, manage, settings, awayDays, library
        case compose(PlanComposeTarget)
    }

    private func shelfSheetDismissed() {
        // No rebuild here: the tab's own `onAppear` follows every sheet dismissal and does it.
        guard let next = shelfFollowUp else { return }
        shelfFollowUp = nil
        switch next {
        case .yourPlans: showYourPlans = true
        case .manage: showManage = true
        case .settings: showSettings = true
        case .awayDays: showAwayDays = true
        case .library: showLibrary = true
        case .compose(let target): PerfMark.start("builder-open"); composing = target
        }
    }

    @ViewBuilder
    private var yourPlansSheet: some View {
        if let p = profiles.first {
            YourPlansView(profile: p, distanceUnit: distanceUnit, workouts: workouts,
                          onManageCurrent: { shelfFollowUp = .manage; showYourPlans = false },
                          onCompose: { record in
                              shelfFollowUp = .compose(PlanComposeTarget(record: record, fromShelf: true))
                              showYourPlans = false
                          },
                          onPlanChanged: { planChangedFromShelf() })
        }
    }

    @ViewBuilder
    private var manageSheet: some View {
        if let p = profiles.first {
            ManagePlanView(profile: p, distanceUnit: distanceUnit,
                           onOpenSettings: { shelfFollowUp = .settings; showManage = false },
                           onOpenYourPlans: { shelfFollowUp = .yourPlans; showManage = false },
                           onAwayDays: { shelfFollowUp = .awayDays; showManage = false },
                           onOpenLibrary: { shelfFollowUp = .library; showManage = false },
                           onPlanChanged: { planChangedFromShelf() },
                           applied: $manageReceipt)
        }
    }

    @ViewBuilder
    private func builderSheet(_ target: PlanComposeTarget) -> some View {
        if let p = profiles.first {
            PlanBuilderFlow(profile: p, draft: target.record, distanceUnit: distanceUnit, workouts: workouts) { outcome in
                if outcome == .activated {
                    planChangedFromShelf()
                } else if outcome != .cancelled || target.fromShelf {
                    // Back to the shelf the athlete came from, including after a Cancel.
                    shelfFollowUp = .yourPlans
                }
                composing = nil
            }
        }
    }

    /// A plan switched or reshaped from a shelf surface: land on the current week and re-read.
    private func planChangedFromShelf() {
        weekStart = currentWeekStart
        rebuildDerived()
    }

    /// The masthead title: the athlete's plan name as typed; the unnamed default joins the
    /// lowercase page-word family ("plan", like "fuel" and "progress").
    private var planTitleText: String {
        let name = planDisplayName
        return name == "Plan" ? "plan" : name
    }

    /// The soonest planned tune-up on the athlete's active season, off the live `@Query` rows.
    private var nextTuneUp: PlanRaceEvent? {
        guard let profile = profiles.first else { return nil }
        let mine = seasonRecords.filter { $0.profileID == profile.id }
        let season = mine.first { $0.activePlanID == profile.plan?.id }
            ?? mine.first { $0.statusRaw == RunningSeasonStatus.active.rawValue }
        guard let season else { return nil }
        return eventRecords
            .filter {
                $0.seasonID == season.id && $0.statusRaw == RunningEventStatus.planned.rawValue
                    && $0.priorityRaw != RunningEventPriority.a.rawValue && ($0.distanceM ?? 0) > 0
                    && $0.date > Date()
            }
            .sorted { $0.date < $1.date }
            .first
            .flatMap { record in
                RunningEventPriority(rawValue: record.priorityRaw).map {
                    PlanRaceEvent(id: record.id, date: record.date, distanceM: record.distanceM ?? 0,
                                  priority: $0, goalTimeS: record.durationS)
                }
            }
    }

    /// One quiet line of what this plan is FOR — the race and its countdown when one is set, else
    /// the goal. The plan page should never make you wonder what it's building toward.
    private var planContextLine: String? {
        guard let profile = profiles.first else { return nil }
        // Self-coached wears its mode openly — the athlete writes the weeks, the app carries them.
        if plan?.isSelfCoached == true { return "Self-coached · your plan, your call" }
        if let raceM = profile.raceDistanceM, raceM > 0, let raceDate = profile.raceDate, raceDate > Date() {
            let label = RaceDistance.nearest(toMeters: raceM).label
            let goalLabel = profile.goalFinishTimeS.map { "\(PlanFeasibility.hms($0)) \(label)" } ?? label
            let cal = planCalendar
            // A tune-up nearer than the goal race is the next start line (2026-09-03): say it, and
            // keep the goal's countdown behind it so the block's destination never disappears.
            if let next = nextTuneUp, next.date > Date(), next.date < raceDate {
                let tuneLabel = RaceDistance.nearest(toMeters: next.distanceM).label
                let tuneDays = cal.dateComponents([.day], from: cal.startOfDay(for: Date()),
                                                  to: cal.startOfDay(for: next.date)).day ?? 0
                let goalDays = cal.dateComponents([.day], from: cal.startOfDay(for: Date()),
                                                  to: cal.startOfDay(for: raceDate)).day ?? 0
                return "Tune-up \(tuneLabel) · \(Formatters.raceCountdown(days: tuneDays)) · \(goalLabel) \(Formatters.raceCountdown(days: goalDays))"
            }
            // Count actual days-to-race (not `.weekOfYear`, which crosses week boundaries and mislabels
            // a race 8–13 days out as "race week"). ≤7 days = race week; otherwise weeks, rounded up.
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()),
                                          to: cal.startOfDay(for: raceDate)).day ?? 0
            let day = raceDate.formatted(.dateTime.month(.abbreviated).day())
            // One countdown grammar everywhere (Formatters.raceCountdown) — this header and the
            // race-projection card lower on the SAME page must never disagree about the distance
            // to the race ("2 weeks" vs "9 days").
            return "\(goalLabel) · \(day) · \(Formatters.raceCountdown(days: days))"
        }
        // The strip and this counter read the same array by construction — `rebuildDerived` starts
        // the strip at the block, so carried history can't inflate "of N" or offset a chip.
        let goalLabel = profile.goal.planLabel
        guard let idx = planWeekIndex(of: currentWeekStart), planWeekStarts.count > 1 else { return goalLabel }
        // Open-ended (no race): a rolling block that renews when it wraps — say so, so "Week 6 of 6"
        // reads as a checkpoint, not a plan running out.
        if plan?.raceDate == nil {
            return "\(goalLabel) · Week \(idx + 1) of \(planWeekStarts.count)"
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
        let today = planCalendar.startOfDay(for: Date())
        if let m = Self.weekStartMemo, m.day == today { return m.start }
        let start = planCalendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
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
            if isFutureWeek && plan?.isSelfCoached != true {
                ToastCenter.shared.show(icon: "calendar", line: "Future weeks adapt after this week. Choose a day in your current week.")
                return
            }
            presentAdd(for: isCurrentWeek ? Date() : weekStart)
        } label: {
            Image(systemName: "plus").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.background)
                .frame(width: 40, height: 40).raised(Circle(), tone: .ink)
                .contentShape(Circle())
        }
        .buttonStyle(RaisedPressStyle(scale: 0.92))
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
    /// The arc draws at ANY length — a 27-week marathon build just gets thinner bars, never the
    /// old horizontally-scrolling chip strip (killed 2026-08-20: it broke both the block-shape
    /// aesthetic and the vertical-only rule the moment a race sat >26 weeks out). Long blocks
    /// drop to sparse numerals (every 5th week + the current one) so labels never collide;
    /// chevron paging still covers plans with no derivable weeks.
    @ViewBuilder
    private var weekStrip: some View {
        let weeks = planWeekStarts
        if weeks.count > 1 {
            weekArc(weeks)
        }
    }

    /// The micro block-arc. Bars share the width equally (no scrolling — the shape only means
    /// something whole), with a 10 pt floor so a strength-only or empty week stays present and
    /// tappable rather than vanishing.
    private func weekArc(_ weeks: [Date]) -> some View {
        let volumes = weekVolumesCache.count == weeks.count ? weekVolumesCache
            : Array(repeating: 0, count: weeks.count)   // first frame before rebuildDerived lands
        let maxV = volumes.max() ?? 0
        // Blocks that fit draw as ONE row (the whole shape at a glance). Longer builds — a
        // marathon 27+ weeks out — keep the SAME single row but page it (owner call
        // 2026-08-21): seven weeks per swipe, each swipe locked to its group like a carousel,
        // never a stacked grid and never a free-scrolling strip.
        return Group {
            // Keep labels legible instead of compressing a long plan into overlapping numerals.
            // Accessibility sizes use the existing paged presentation sooner.
            if weeks.count <= (dynamicTypeSize.isAccessibilitySize ? 7 : 14) {
                HStack(alignment: .bottom, spacing: weeks.count > 16 ? 2 : 3) {
                    ForEach(Array(weeks.enumerated()), id: \.element) { i, start in
                        weekBar(index: i, start: start, volume: volumes[i], maxVolume: maxV)
                    }
                }
            } else {
                pagedArc(weeks, volumes: volumes, maxVolume: maxV)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Training block, \(weeks.count) weeks")
    }

    /// The long-block arc: identical bars, paged seven weeks at a swipe — a locked carousel
    /// (`TabView(.page)`, the one primitive whose paging never fights nested scrolling). Follows
    /// the selected week: arriving on the page (or tapping into another week) lands the strip on
    /// the right group, the way the old chip strip centered itself.
    @State private var arcPage = 0
    private func pagedArc(_ weeks: [Date], volumes: [Double], maxVolume: Double) -> some View {
        let pageSize = 7
        let pages: [[Int]] = stride(from: 0, to: weeks.count, by: pageSize).map {
            Array($0..<min($0 + pageSize, weeks.count))
        }
        return TabView(selection: $arcPage) {
            ForEach(Array(pages.enumerated()), id: \.offset) { p, indices in
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(indices, id: \.self) { i in
                        weekBar(index: i, start: weeks[i],
                                volume: volumes[i], maxVolume: maxVolume)
                    }
                    // A short last page keeps the same column rhythm as full ones —
                    // spacers stand in for the missing weeks instead of stretching.
                    ForEach(0..<(pageSize - indices.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                    }
                }
                .tag(p)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: 43 + weekNumberSize)
        .onAppear {
            if let idx = planWeekIndex(of: weekStart) { arcPage = idx / pageSize }
        }
        .onChange(of: weekStart) {
            if let idx = planWeekIndex(of: weekStart) {
                withAnimation(reduceMotion ? nil : Motion.selection) { arcPage = idx / pageSize }
            }
        }
    }

    private func weekBar(index: Int, start: Date, volume: Double, maxVolume: Double) -> some View {
        let cal = planCalendar
        let selected = cal.isDate(start, inSameDayAs: weekStart)
        let isCurrent = cal.isDate(start, inSameDayAs: currentWeekStart)
        let isPast = start < currentWeekStart
        // Flat-block fallback: a plan with no distance targets anywhere (pure strength) has no
        // shape to draw, so every bar takes a uniform mid height and the arc degrades to a clean
        // tappable pager rather than a row of stubs.
        let h: CGFloat = maxVolume > 0 ? 10 + 24 * CGFloat(volume / maxVolume) : 22
        return Button {
            guard !selected else { return }
            Haptics.selection()
            // The board updates immediately, without animating row heights or the scroll offset.
            // Selection feedback belongs to this bar, not to the model/cache rebuild.
            weekStart = start
        } label: {
            VStack(spacing: 4) {
                // Width-capped inside a full-width tap column: short blocks would otherwise
                // stretch each bar to ~46 pt slabs that read as a loading skeleton, not a chart.
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(selected
                          ? AnyShapeStyle(LinearGradient(colors: [Theme.purple, Theme.purple.opacity(0.65)],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(LinearGradient(colors: [Theme.ink.opacity(isPast ? 0.30 : 0.16),
                                                                  Theme.ink.opacity(isPast ? 0.18 : 0.08)],
                                                         startPoint: .top, endPoint: .bottom)))
                    .frame(maxWidth: 26)
                    .frame(height: h)
                    .shadow(color: selected ? Theme.purple.opacity(0.35) : .clear, radius: 6, y: 3)
                // Every bar carries its week number — the one job the chips did that heights
                // can't. The current calendar week wears the board's own "today" convention (an
                // ink pill, like the date column below) instead of the chips' floating dot, so
                // the two surfaces mark "now" the same way.
                Text("\(index + 1)")
                    .font(.rounded(9, weight: selected || isCurrent ? .heavy : .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isCurrent ? Theme.background
                                     : (selected ? Theme.purpleDeep : Theme.inkTertiary))
                    .frame(minWidth: weekNumberSize, minHeight: weekNumberSize)
                    .background {
                        if isCurrent { Capsule().fill(Theme.ink) }
                    }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 43 + weekNumberSize, alignment: .bottom)
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : Motion.selection, value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(weekBarLabel(index: index, volume: volume,
                                         isCurrent: isCurrent, selected: selected))
        .accessibilityIdentifier("planWeek.\(index)")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                    .animation(Motion.crossfade, value: weekStart)
                    // The row now carries a phase chip, the This-week pill and two chevrons; the
                    // title yields first rather than pushing any of them off the edge.
                    .lineLimit(1).minimumScaleFactor(0.7).layoutPriority(1)
                if let phase = weekPhase {
                    Text(phase.label.uppercased())
                        .font(.rounded(9, weight: .black)).tracking(1)
                        .fixedSize()
                        // Phase chips wear the lavender tint (rebrand 2026-08-16, per the
                        // application map); taper keeps the ink chip — it's the week that shouts.
                        .foregroundStyle(phase == .taper ? Theme.background : Theme.purpleDeep)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background {
                            Capsule().fill(phase == .taper ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.purpleTint))
                            if phase != .taper { Capsule().stroke(Theme.purple.opacity(0.25)) }
                        }
                }
                Spacer(minLength: 0)
                // Back to now, one tap, and only when the athlete has browsed away. Without it,
                // returning from week 12 meant finding the ink-pilled numeral among a row of 27.
                if !isCurrentWeek {
                    Button {
                        Haptics.selection()
                        weekStart = currentWeekStart
                    } label: {
                        Text("This week")
                            .font(.rounded(Theme.FontSize.label, weight: .bold))
                            .foregroundStyle(Theme.purpleDeep)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background {
                                Capsule().fill(Theme.purpleTint)
                                Capsule().stroke(Theme.purple.opacity(0.25))
                            }
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to this week")
                }
                // Step a week either way. These used to render ONLY on plans with no derivable
                // weeks (`count <= 1`) — which is to say, almost never — leaving every real plan
                // to navigate by tapping an arc bar. Those bars sit in tap columns barely 13 pt
                // wide on a marathon block, well under the 44 pt minimum, for the most common
                // action on the page. The arc stays for jumping far; these are for next and back.
                chevron("chevron.left", enabled: canShift(-1)) { shiftWeek(-1) }
                chevron("chevron.right", enabled: canShift(1)) { shiftWeek(1) }
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
                            Capsule().fill(Theme.ink.opacity(0.07))
                            Capsule()
                                .fill(done == total ? AnyShapeStyle(IridescentMaterial())
                                                    : AnyShapeStyle(LinearGradient(colors: [Theme.purple, Theme.iridescent[0]],
                                                                                   startPoint: .leading, endPoint: .trailing)))
                                .frame(width: max(6, geo.size.width * CGFloat(frac)))
                                .shadow(color: Theme.purple.opacity(done == total ? 0 : 0.35), radius: 4, y: 1)
                        }
                    }
                    .frame(height: 6)
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
        .accessibilityLabel("\(weekTitle), \(weekPhase.map { "\($0.label) phase. \($0.intent)" } ?? summary), \(done) of \(total) sessions done")
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

    /// Rebuild on actual data changes. Week paging only updates week-scoped values. The expensive
    /// chart construction is gone, so the arc and coaching no longer need a delayed second paint.
    private func rebuildDerived(refreshPlan: Bool = true) {
        let cal = planCalendar
        currentWeekStartCacheRefresh()
        daysCache = Self.computeDays(from: weekStart, calendar: planCalendar)
        daysCacheWeek = weekStart
        guard let plan else {
            weekMap = [:]; weekStartsCache = []; planFirstWeek = nil; weekMapToken = 0
            weekVolumesCache = []; weekDoneMetersCache = 0; weekPhaseCache = nil
            weekIndexCache = [:]; weekBarBaseLabels = []; liftLinesCache = [:]
            tuneProposal = nil; derivedPlanID = nil
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

        if refreshPlan || derivedPlanID != plan.persistentModelID {
            derivedPlanID = plan.persistentModelID
            rebuildPlanScoped(plan: plan, calendar: cal)
        }
        weekPhaseCache = computeWeekPhase()
        coachsReadModel.hybridInsight = hybridWeekInsight
        refreshBlockReview(plan: plan, calendar: cal)
    }

    /// The block report for the renewal card, computed with the derived state (never in `body`):
    /// the closing block's real numbers, or nil while the card is not showing.
    private func refreshBlockReview(plan: TrainingPlan, calendar cal: Calendar) {
        guard showRenewalPrompt else { blockReview = nil; return }
        let snapshots = (try? context.fetch(FetchDescriptor<FitnessSnapshot>(
            sortBy: [SortDescriptor(\.weekStart)]))) ?? []
        blockReview = BlockReport.text(
            PlanBlockReview.summary(plan: plan, workouts: workouts, snapshots: snapshots, calendar: cal),
            unit: distanceUnit)
    }

    private func rebuildPlanScoped(plan: TrainingPlan, calendar cal: Calendar) {
        // Load-only evaluation; no chart construction or historical GPS decoding.
        tuneProposal = PlanCoaching.proposeAdjustment(plan, workouts: workouts)
        var model = CoachsReadModel()
        if let raceM = profiles.first?.raceDistanceM, raceM > 0, plan.p5kSPerKm > 0 {
            model.hasRacePrediction = true
        }
        let runs = PaceInsights.recentQualityRuns(plan)
        if !runs.isEmpty { model.paceResult = PaceInsights.evaluate(runs) }
        model.intensityMix = recentIntensityMix(p5k: plan.p5kSPerKm, calendar: cal)
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
            ?? planWeekStarts.firstIndex { planCalendar.isDate($0, inSameDayAs: week) }
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
        let idx = planCalendar.dateComponents([.weekOfYear], from: firstWeek, to: weekStart).weekOfYear ?? -1
        guard idx >= 0, idx < plan.weekPhases.count else { return nil }
        return PlanPhase(rawValue: plan.weekPhases[idx])
    }

    private func chevron(_ system: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.light(); action() } label: {
            Image(systemName: system).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 36, height: 36).background(Circle().fill(Theme.background)).overlay(Circle().stroke(Theme.hairline))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.25)
    }

    /// A day already gone. Days are compared at start-of-day so "today" is never past.
    private func isPastDay(_ day: Date) -> Bool {
        let cal = planCalendar
        return cal.startOfDay(for: day) < cal.startOfDay(for: Date())
    }

    /// Is there a week to step to in that direction, inside the block the arc draws? Stepping past
    /// either end would land on an empty board that looks like a plan with nothing in it, so the
    /// ends dim instead. Plans with no derivable weeks page freely — the arc is hidden for those,
    /// and the chevrons are then the only navigation there is.
    private func canShift(_ delta: Int) -> Bool {
        guard planWeekStarts.count > 1,
              let first = planWeekStarts.first, let last = planWeekStarts.last,
              let target = planCalendar.date(byAdding: .weekOfYear, value: delta, to: weekStart)
        else { return true }
        return target >= first && target <= last
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
                        .raised(Capsule(), tone: .ink)
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
              let lastWeek = planCalendar.dateInterval(of: .weekOfYear, for: end)?.start else { return false }
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
                    if let blockReview, !blockReview.lines.isEmpty {
                        // The block in numbers: the checkpoint, the estimate, the volume, the long
                        // run, the sessions. Each line is one true thing the athlete did.
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(blockReview.lines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                            }
                        }
                        .padding(.top, 4)
                        .accessibilityElement(children: .combine)
                    }
                }
                Spacer(minLength: 0)
            }
            Button { renewBlock() } label: {
                Text("Build my next block")
                    .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.background)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .raised(Capsule(), tone: .ink)
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
        // The review first, while the closing block's sessions are still the plan's.
        if let plan = profile.plan {
            PlanBlockReview.post(PlanBlockReview.summary(plan: plan, in: context), unit: distanceUnit, in: context)
        }
        PlanService.renewBlock(for: profile, in: context)
        Haptics.success()
        withAnimation(reduceMotion ? nil : Motion.standard) {
            weekStart = currentWeekStart
            rebuildDerived()
        }
        PlanAdjustmentService.propagate(profile: profile, workouts: workouts, notifications: services.notifications)
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
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private static let dateColWidth: CGFloat = 42

    private func boardDayRow(_ day: Date, map: [Date: [PlannedSession]]) -> some View {
        let dayKey = planCalendar.startOfDay(for: day)
        let sessions = (map[dayKey] ?? []).filter(PlanSessionPresentation.isLive)
        let isToday = planCalendar.isDateInToday(day)
        // A hovered session owns the drop (the two trade days); the day beneath it stands down, so
        // the board never offers both readings of the same gesture at once.
        let isMoveTarget = dropDay == dayKey && swapTargetID == nil
        return HStack(alignment: .top, spacing: Theme.Space.md) {
            boardDateColumn(day, isToday: isToday, hasSessions: !sessions.isEmpty)
            Group {
                if sessions.isEmpty {
                    boardRestLine(day, map: map)
                } else {
                    VStack(spacing: Theme.Space.sm + 2) {
                        ForEach(sessions, id: \.persistentModelID) { session in
                            if PlanSessionPresentation.isLive(session) {
                            // Long press belongs to the DRAG, and only the drag. `.contextMenu` on
                            // the same view competes for that gesture and wins nondeterministically
                            // — measured on the simulator, the identical press either lifted the
                            // session, opened the menu and froze there, or did nothing at all, run
                            // to run. A move you cannot trust is worse than no drag, so the quick
                            // menu moved onto the row's own icon chip (`sessionMenu`), which is a
                            // deliberate, unambiguous target and leaves the body of the row free.
                            sessionLine(session)
                                .planSwapTarget(swapTargetID == session.id)
                                .modifier(DraggableSessionModifier(
                                    session: session, distanceUnit: distanceUnit,
                                    enabled: session.status != .completed))
                                // A completed session is not a swap target either: trading days with
                                // finished work would move the record of a run that already happened.
                                // The drop falls through to the day row beneath, which is a plain move.
                                .dropDestination(for: PlannedSessionTransfer.self) { items, _ in
                                    guard PlanSessionPresentation.isLive(session), session.status != .completed, let dropped = items.first else { return false }
                                    return swap(sessionID: dropped.id, with: session)
                                } isTargeted: { targeted in
                                    guard PlanSessionPresentation.isLive(session), session.status != .completed else { return }
                                    withAnimation(reduceMotion ? nil : Motion.selection) {
                                        if targeted { swapTargetID = session.id }
                                        else if swapTargetID == session.id { swapTargetID = nil }
                                    }
                                }
                            }
                        }
                        // Adding a SECOND session to a day used to be impossible from that day:
                        // the per-day "+" lives on the rest line, which only renders when the day
                        // is empty, so a lift alongside Tuesday's run meant the header "+" and
                        // then re-picking Tuesday in the sheet while looking straight at Tuesday.
                        //
                        // Today and forward only. A line on all seven rows added real height to a
                        // board whose whole job is reading the week at a glance, and you plan
                        // FORWARD — a past day is a record of what happened, and work done then
                        // gets logged, not planned.
                        if !isPastDay(day) {
                            Button { presentAdd(for: day) } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 10, weight: .bold))
                                    Text("Add")
                                        .font(.rounded(Theme.FontSize.label, weight: .semibold))
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(Theme.inkTertiary.opacity(0.5))
                                .frame(height: 20)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add another session on \(day.formatted(.dateTime.weekday(.wide).month().day()))")
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
        .planDropTarget(isMoveTarget)
        // The whole row is the target, rest days included — an open day is the commonest place a
        // session goes, and it would be perverse to make the emptiest rows the hardest to hit.
        .dropDestination(for: PlannedSessionTransfer.self) { items, _ in
            guard let dropped = items.first else { return false }
            return move(sessionID: dropped.id, to: dayKey)
        } isTargeted: { targeted in
            withAnimation(reduceMotion ? nil : Motion.selection) {
                if targeted { dropDay = dayKey } else if dropDay == dayKey { dropDay = nil }
            }
        }
    }

    /// The day's anchor: weekday + date, left-aligned. Today fills an ink pill; days with work read
    /// full-ink; rest days recede to tertiary. Sits slightly below the divider so it aligns with the
    /// first session's title rather than the icon top.
    private func boardDateColumn(_ day: Date, isToday: Bool, hasSessions: Bool) -> some View {
        VStack(spacing: 0) {
            // One line each, shrinking before they truncate: "MON" must never read "M…" at
            // accessibility type sizes inside the fixed date column.
            Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.rounded(9.5, weight: .black)).tracking(0.4)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(day.formatted(.dateTime.day()))
                .font(.display(19, weight: .heavy)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
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
            // The drag handle. It lives OUTSIDE the row's button-and-context-menu subtree on
            // purpose: `.contextMenu` and `.draggable` on one view fight over the long press and
            // resolve differently run to run, so each gesture gets its own target instead. Grab the
            // session's own glyph and carry it to another day.
            Image(systemName: PlanCoaching.icon(for: session))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(done ? Theme.inkTertiary : Theme.ink)
                .frame(width: 34, height: 34)
                .background { Circle().fill(Theme.background); Circle().stroke(Theme.hairline) }
                // A 34pt glyph is under the 44pt touch minimum, so the grabbable area is padded out
                // to the row's full height without moving a pixel of the drawing.
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .modifier(DraggableSessionModifier(
                    session: session, distanceUnit: distanceUnit,
                    enabled: session.status != .completed))
                .accessibilityHidden(true)   // the row's own element carries the session and its actions
            Button { editing = EditingSession(session: session) } label: {
                HStack(spacing: Theme.Space.sm + 2) {
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
                        // What the athlete just did with this session, said once. Transient by
                        // design (`PlanMoveAdvice`): it describes a week the next drag can change,
                        // so it is never written to `rationale` where it would go quietly stale.
                        if !done, moveNote?.id == session.id, let note = moveNote?.text {
                            HStack(spacing: 4) {
                                Image(systemName: "calendar")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.purple)
                                Text(note)
                                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                                    .foregroundStyle(Theme.inkSecondary)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                            }
                            .transition(.opacity)
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
            // The quick menu stays exactly where it shipped — on the body of the row — because the
            // drag now lives on the glyph beside it and the two no longer contend.
            .contextMenu {
                if session.status != .completed {
                    Button { Haptics.medium(); start(session) } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                }
                Button {
                    if PlanMutation.edit(in: context, { PlanCoaching.setCompletion(session, done: session.status != .completed, in: context) }) { Haptics.success() }
                } label: {
                    Label(session.status == .completed ? "Mark not done" : "Mark done",
                          systemImage: session.status == .completed ? "arrow.uturn.left" : "checkmark")
                }
                // Move without a drag — the pointer-free path, and the only one that reaches
                // another week.
                moveMenu(session)
                repeatMenu(session)
                // "Adjust…" collided with the header menu's "Adjust this plan" — one word, two
                // scopes, on one screen. This one opens ONE session, so it says so.
                Button { editing = EditingSession(session: session) } label: { Label("Edit session…", systemImage: "slider.horizontal.3") }
                Button(role: .destructive) { delete(session) } label: { Label("Remove", systemImage: "trash") }
            }
            // Drag is a pointing gesture and reaches no assistive technology, so the same
            // reschedule surface hangs off the row's own accessibility element as a rotor action.
            // It sits on the body BUTTON, not the enclosing stack: an action on a container that
            // is not itself an element never surfaces in VoiceOver.
            .accessibilityAction(named: "Move to another day") {
                editing = EditingSession(session: session, startInMove: true)
            }
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

    /// "30 to 60 g carbs/hr", the same deterministic gate as the Today deck and the session sheet
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
        return "\(carbs.lowerBound) to \(carbs.upperBound) g carbs/hr"
    }

    /// The session's TYPE as a quiet eyebrow ("TEMPO RUN", "LONG RUN", "STRENGTH") — the Runna
    /// pattern: what KIND of day it is reads before the numbers do.
    private func sessionKindLabel(_ session: PlannedSession) -> String? {
        if session.discipline == .strength { return "STRENGTH" }
        if let wt = session.workoutType, wt != .run, !wt.isStrengthStyle { return wt.title.uppercased() }
        if let rt = session.runType {
            if rt == .race { return "RACE DAY" }        // the season's crown — never "RACE RUN"
            return rt.planTitle.uppercased()
        }
        return nil
    }

    private func checkButton(_ session: PlannedSession, done: Bool) -> some View {
        Button {
            if PlanMutation.edit(in: context, { PlanCoaching.setCompletion(session, done: !done, in: context) }) {
                if done { Haptics.selection() } else { Haptics.success() }
            }
        } label: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(done ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.inkTertiary.opacity(0.7)))
                .contentTransition(.opacity)
                .animation(Motion.crossfade, value: done)
                .frame(width: 34, height: 44, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(RaisedPressStyle())
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
        let cal = planCalendar
        func neighbor(_ offset: Int) -> RestDayLine.Neighbor {
            guard let d = cal.date(byAdding: .day, value: offset, to: day) else { return .none }
            let sessions = map[cal.startOfDay(for: d)] ?? []
            return RestDayLine.strongest(sessions.map(neighborKind))
        }
        return RestDayLine.line(yesterday: neighbor(-1), tomorrow: neighbor(1),
                                dayAfter: neighbor(2), phase: weekPhase)
    }

    private func neighborKind(_ s: PlannedSession) -> RestDayLine.Neighbor {
        PlanSessionPresentation.neighbor(s)
    }

    /// Never a dead end: the tab's whole job is the plan, so the empty state carries the way to one.
    /// (The old copy said "finish onboarding" — wrong for anyone who wiped data or hit an edge case
    /// post-onboarding — and the header's "Start a new plan" menu doesn't render in this branch.)
    private var emptyState: some View {
        VStack(spacing: Theme.Space.lg) {
            BrandMark(size: 72)
            Text("No plan yet").font(.display(Theme.FontSize.headline, weight: .heavy)).foregroundStyle(Theme.ink)
            Text("Tell us your goal and we'll build a week that fits, race or no race.")
                .font(.rounded(Theme.FontSize.body, weight: .regular)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
            if profiles.first != nil {
                Button { Haptics.light(); showNewPlan = true } label: {
                    Text("Build my plan")
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.background)
                        .padding(.horizontal, Theme.Space.xl).padding(.vertical, 14)
                        .raised(Capsule(), tone: .ink)
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
                .accessibilityLabel("Plan it myself, no coach plan")
                // Drafts and previous plans live on the shelf even when nothing is current.
                Button { Haptics.light(); showYourPlans = true } label: {
                    Text("Your plans")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Your plans")
            }
        }
        .padding(Theme.Space.xl).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Derived

    /// One map read for the whole list — reading `liveWeekMap` per day re-evaluated the token
    /// (two plan-relationship faults each) seven times over.
    private var weekSessions: [PlannedSession] {
        let map = liveWeekMap
        let cal = planCalendar
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
        if done == total { return "All done. Every session landed." }
        return "\(done) done · \(total - done) to go"
    }

    private var weekLabel: String {
        let end = planCalendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        return "\(weekStart.formatted(.dateTime.month().day())) – \(end.formatted(.dateTime.month().day()))"
    }

    private func shiftWeek(_ delta: Int) {
        if let d = planCalendar.date(byAdding: .weekOfYear, value: delta, to: weekStart) { weekStart = d }
    }

    private var card: some View {
        ZStack {
            Color.clear.raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }
}


/// `.sheet(item:)` needs an Identifiable; a nil record is a fresh plan. The id is captured at
/// init: activation deletes the record in the same save, and the sheet's dismissal diff must
/// never read a deleted model.
struct PlanComposeTarget: Identifiable {
    let record: PlanShelfRecord?
    /// Opened from Your plans: a Cancel returns there rather than to the board.
    var fromShelf = false
    let id: String

    init(record: PlanShelfRecord?, fromShelf: Bool = false) {
        self.record = record
        self.fromShelf = fromShelf
        self.id = record?.id.uuidString ?? "new"
    }
}
