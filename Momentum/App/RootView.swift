import SwiftUI
import SwiftData
import StoreKit

/// App shell: a `TabView` with one `NavigationStack` per tab (PRD §13.10).
/// Onboarding presents as a gated `fullScreenCover` over this on first launch.
struct RootView: View {
    @Query private var profiles: [UserProfile]
    @Environment(PaywallController.self) private var paywall
    @Environment(AuthController.self) private var auth
    @Environment(CoachPresenter.self) private var coach
    @Environment(AppRouter.self) private var router           // cross-tab mailbox — RootView owns pendingTab
    @Environment(Services.self) private var services          // crash-recovery completion runs the live pipeline
    @Environment(\.modelContext) private var context
    // Cold-launch recovery (PRD §8.3/§8.4): a workout that was live when the app died. Every sample
    // and set was persisted as it happened — this prompt is how they come back.
    @State private var recoveredWorkout: Workout?
    @State private var showRecoveryPrompt = false
    @State private var recoverySave: PresentedWorkout?
    /// Once per process: a fresh launch is the only moment the marker can't belong to a live workout.
    @MainActor private static var didCheckRecovery = false
    /// The athlete's chosen unit, for the save screens presented from here — they default to `.auto`,
    /// which resolves off locale and ignores an explicit metric/imperial preference.
    private var distanceUnit: DistanceUnit {
        DistanceUnit(rawValue: profiles.first?.distanceUnit ?? "auto") ?? .auto
    }
    @State private var selection: AppTab = {
        #if DEBUG
        // Deterministic deep-links for sim verification (tab-bar taps are unreliable in the sim).
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--fuel") || args.contains("--fuel-tab") { return .fuel }
        if args.contains("--profile-tab") { return .profile }
        if args.contains("--plan-tab") { return .plan }
        if args.contains("--progress-tab") { return .progress }
        #endif
        return .today
    }()
    @State private var showOnboarding = false
    /// Second phase of the onboarding hard gate: they subscribed from the RELAUNCH wall (having
    /// force-quit onboarding at the paywall), so they never reached onboarding's `.account` beat and
    /// would otherwise land in the app as a paying permanent guest — anonymous to RevenueCat, with
    /// no cloud copy of anything they paid for. Rides the SAME cover as the wall rather than adding a
    /// fifth presentation modifier to this chain (see the ceiling note above).
    @State private var gateAccountBeat = false
    #if DEBUG
    // Open the most recent run's detail (for verifying the guided-run Reps breakdown).
    @Query(sort: \Workout.startedAt, order: .reverse) private var recentWorkouts: [Workout]
    @State private var showRunDetail = ProcessInfo.processInfo.arguments.contains("--ui-test-run-detail")
    // Flipped AFTER insertion (onAppear + delay) — a cover whose isPresented is already true while
    // the view is being inserted can silently fail to present (see the onboarding note below).
    @State private var showSaveScreen = false
    // Straight to Settings (screenshot verification of the settings surface).
    @State private var showSettingsDeepLink = false
    @State private var showWidgetPreview = ProcessInfo.processInfo.arguments.contains("--widget-preview")
    // Straight into the planned-lift checklist (screenshot verification of the live strength flow).
    @State private var showStrengthLivePlanned = false
    #endif

    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--health-e2e") {
            HealthE2EView()
        } else if ProcessInfo.processInfo.arguments.contains("--community") {
            // Design-only door onto the dormant Community feed (back-burnered 2026-07-16, still
            // unreachable in Release — there is no AppTab case and no other entry point). Rendered
            // at the root rather than as a cover: this chain is already at the documented
            // 4-presentation-modifier ceiling. Pair with --seed-demo for a populated feed.
            NavigationStack { CommunityView() }
        } else {
            mainBody
        }
        #else
        mainBody
        #endif
    }

    private var mainBody: some View {
        @Bindable var paywall = paywall
        @Bindable var coach = coach
        @Bindable var auth = auth
        return Group {
            if !auth.isSignedIn {
                // The welcome (2026-07-27): brand only, no account. "Get started" enters setup
                // local-only and the account is offered on the LAST beat of onboarding. Told
                // whether training already lives on this device so it can offer to resume it
                // rather than run a second athlete through setup on top of it.
                SignInView(hasLocalProfile: !profiles.isEmpty,
                           existingName: profiles.first?.displayName)
            } else {
                ZStack {
                    // Until onboarding is done, show a clean canvas — don't build the Today map yet,
                    // so it can't trigger a location prompt "up front" (PRD §4.1, §11 privacy).
                    if showOnboarding { Theme.background.ignoresSafeArea() } else { tabs }
                }
                // Award unlocks meet the athlete wherever they land — awards can arrive from any
                // path (save flows, Health import, a plan week completing), so the presenter sits
                // once at the root rather than on each surface. Paused while a root cover owns the
                // screen (the overlay renders UNDER covers — presenting then would play the whole
                // celebration invisibly behind them).
                .awardUnlocks(paused: paywall.presentedFeature != nil || coach.isPresented
                              || showOnboarding || showRecoveryPrompt || recoverySave != nil)
                // Any locked feature anywhere routes through here (PRD §10 — contextual gates).
                // Full screen (not a sheet): the paywall is a considered, premium moment — it owns
                // the whole canvas, like onboarding.
                // Stand down while the coach chat is up: the coach is itself a fullScreenCover, so
                // this root cover can't present on top of it — CoachChatView hosts its OWN paywall
                // cover for the "gate on send" moment. Both binding to `presentedFeature` fired the
                // paywall TWICE (root + coach) with a dark flash in between; gating on
                // `coach.isPresented` leaves exactly one host live at a time.
                .fullScreenCover(item: Binding(
                    get: { coach.isPresented ? nil : paywall.presentedFeature },
                    set: { paywall.presentedFeature = $0 })) { feature in
                    PaywallView(feature: feature)
                }
                // The onboarding hard gate (2026-07-28). `finishOnboarding` sets the flag when setup
                // reaches the paywall un-entitled, and only a purchase/restore clears it — so the wall
                // is re-raised on every launch and force-quitting it is never a way into the app.
                // Athletes who finished onboarding BEFORE the flip never set the flag and keep the
                // free tier they already had; this walls new signups only.
                // `set` deliberately does NOT clear `onboardingGatePending` — only an entitlement
                // does (`setPro(true)`). It used to self-clear, from the freemium era when this cover
                // was dismissible and the worst case was walling someone out of a free tier; with a
                // hard gate that would make one dismissal a permanent bypass. The store-unreachable
                // escape is the one non-purchase way out, and it defers via `storeUnreachableDeferral`
                // — unpersisted, so the wall is back on the next launch.
                .fullScreenCover(isPresented: Binding(
                    get: { gateAccountBeat
                        || (paywall.onboardingGatePending && !paywall.isPro && !paywall.storeUnreachableDeferral
                            && !showOnboarding && !profiles.isEmpty) },
                    set: { if !$0 { gateAccountBeat = false } })) {
                    if gateAccountBeat {
                        AccountOptionsView(
                            presentation: .onboardingBeat,
                            onSkip: { gateAccountBeat = false },
                            onSignedIn: {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { gateAccountBeat = false }
                            })
                        .environment(\.colorScheme, .dark)   // same dark sequence onboarding runs in
                    } else {
                        PaywallView(feature: .fullPlan, hard: true, onEntitled: {
                            // A purchase landed HERE, so onboarding's own paywall → `.account`
                            // hand-off never ran. Swap this cover to the account beat instead of
                            // letting the paywall dismiss — flipping `gateAccountBeat` keeps `get`
                            // true, so the cover is never torn down and there is no re-presentation
                            // to lose under load. If they already have a real account there's nothing
                            // to offer: leave it alone and `get` goes false on its own.
                            guard !(auth.isSignedIn && !auth.isGuest) else { return }
                            gateAccountBeat = true
                        })
                    }
                }
                // The ONE coach chat surface — every entry point (Today's floating button, Settings)
                // opens the same thread through `CoachPresenter`. Free to talk; Apply is the Pro gate.
                .fullScreenCover(isPresented: $coach.isPresented) {
                    CoachChatView { coach.close() }
                }
                // A nav card tapped in the chat: the chat dismissed itself; steer the shell.
                .onChange(of: coach.pendingNav) { _, nav in
                    guard let nav else { return }
                    coach.pendingNav = nil
                    switch nav {
                    case .startToday: selection = .today
                    case .viewPlanWeek, .raceBriefing: selection = .plan
                    case .planSettings: selection = .plan   // PlanView opens its settings sheet (coachWantsSettings)
                    case .viewProgress: selection = .progress
                    case .viewHealth:                       // Progress → Health segment (RECOVERY-HUB-PLAN §2)
                        selection = .progress
                        router.pendingProgressSegment = "Health"
                    }
                    if nav == .planSettings { coach.wantsPlanSettings = true }
                }
                // Cross-tab requests (Today's morning readout → Progress · Health). Consume-then-nil:
                // the same destination can be asked for again later, and a stale one never re-fires.
                .onChange(of: router.pendingTab) { _, tab in
                    guard let tab else { return }
                    router.pendingTab = nil
                    selection = tab
                }
                #if DEBUG
                .fullScreenCover(isPresented: $showRunDetail) {
                    // Prefer a run with a reps breakdown (this hook exists to verify guided-run
                    // surfaces) — an interrupted stub from an earlier UI test must never win.
                    let runs = recentWorkouts.filter { $0.type == .run && $0.gps != nil }
                    if let run = runs.first(where: { $0.gps?.structuredRepsData != nil }) ?? runs.first {
                        NavigationStack { WorkoutDetailView(workout: run) }
                    }
                }
                // --save-screen: the post-run save editor for the newest seeded GPS run —
                // deterministic verification of map styles/photos/Pro gate without choreographing
                // a live run through XCUITest. Hosted on its OWN background view: from the 4th
                // chained presentation modifier onward, covers on this chain silently stop
                // presenting (--ui-test-run-detail is affected too).
                .background {
                    Color.clear.fullScreenCover(isPresented: $showSaveScreen) {
                        if let run = recentWorkouts.first(where: { $0.type.isGPS && $0.gps != nil }) {
                            // Reads the real week through the shared reader, so this harness verifies
                            // the ring the finish flow actually draws — not a lookalike. `--ring-demo`
                            // substitutes a mid-week reading, because the seed's run is the only one
                            // in its week and so exercises only the baseline-of-zero case.
                            CardioSaveView(workoutId: run.id, distanceUnit: distanceUnit,
                                           workoutType: run.type,
                                           weekRing: debugFlag("--ring-demo")
                                               ? WeekRing.reading(justFinishedM: 7_000, earlierThisWeekM: 19_000,
                                                                  targetM: 32_000)
                                               : WeekRingReader.reading(for: run, plan: profiles.first?.plan,
                                                                        profile: profiles.first, in: context)) {
                                showSaveScreen = false
                            }
                        }
                    }
                }
                // --strength-live-planned: the planned-lift checklist (nearest strength day with
                // targets from the seeded plan) — deterministic verification of the prescription
                // header + target rows. Own background view (same 4th-modifier gotcha as above).
                .background {
                    Color.clear.fullScreenCover(isPresented: $showStrengthLivePlanned) {
                        if let session = profiles.first?.plan?.sessions
                            .filter({ $0.discipline == .strength && !$0.strengthTargets.isEmpty
                                      && $0.status != .completed })
                            .sorted(by: { abs($0.date.timeIntervalSinceNow) < abs($1.date.timeIntervalSinceNow) })
                            .first {
                            StrengthLiveView(container: context.container, type: .strength,
                                             plannedSession: session) { _ in
                                showStrengthLivePlanned = false
                            }
                        }
                    }
                }
                #endif
            }
        }
        .alert("Unfinished \(recoveredWorkout?.type.title.lowercased() ?? "workout") found",
               isPresented: $showRecoveryPrompt, presenting: recoveredWorkout) { workout in
            Button("Save it") {
                WorkoutRecovery.finalizePending(in: context)
                // A recovered workout is a real workout: it runs the SAME completion pipeline as a
                // live finish. Without this it landed in history uncredited — the session the
                // athlete had actually just run still sat open on their plan, and the plan never
                // learned from it (no pace recalibration, no protective easing, stale reminders).
                let id = workout.id, type = workout.type
                if let recovered = WorkoutCompletion.fetch(id, in: context) {
                    WorkoutCompletion.credit(recovered, launched: nil, plan: profiles.first?.plan,
                                             profile: profiles.first, in: context)
                    // Deferred like the live path — heavy main-actor SwiftData work that nothing
                    // on screen is waiting for.
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(0.6))
                        guard let w = WorkoutCompletion.fetch(id, in: context) else { return }
                        WorkoutCompletion.adapt(w, plan: profiles.first?.plan, profile: profiles.first,
                                                unit: distanceUnit, services: services, in: context)
                    }
                }
                recoverySave = PresentedWorkout(id: id, type: type)
                recoveredWorkout = nil
            }
            Button("Discard", role: .destructive) {
                WorkoutRecovery.discardPending(in: context)
                recoveredWorkout = nil
            }
        } message: { _ in
            Text("Looks like the app closed mid-workout. Everything you recorded is safe — keep it?")
        }
        .fullScreenCover(item: $recoverySave) { presented in
            if presented.type.isStrengthStyle {
                StrengthSaveView(workoutId: presented.id) { recoverySave = nil }
            } else if presented.type.isTimed {
                TimedSaveView(workoutId: presented.id) { recoverySave = nil }
            } else {
                CardioSaveView(workoutId: presented.id, distanceUnit: distanceUnit,
                               workoutType: presented.type) { recoverySave = nil }
            }
        }
        // Onboarding presents from THIS always-installed level, not from the signed-in branch:
        // sign-in flips the branch and raises this flag in the same update, and a cover attached
        // to a view being inserted that instant can silently fail to present (blank canvas).
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingFlow {
                showOnboarding = false
                // The coach says hello the moment there's a plan to explain — a quiet seed the
                // Today button badges, offered at the peak-curiosity moment. Once ever.
                if profiles.first?.plan != nil { CoachProactive.seedPlanIntro(in: context) }
                // No rating ask here any more (guideline 5.6.3 — never on first launch / onboarding).
                // The prompt moved to the finished-workout moment, gated on real engagement — see
                // `AppReview` and `WorkoutRunner.dismissSummary`.
            }
            // First-run onboarding is a dark, cinematic sequence regardless of the athlete's
            // appearance setting (user call 2026-07-28) — it flows straight into the paywall, which
            // has been unconditionally dark since 2026-07-10, so a light setup followed by a dark
            // wall was a visible seam. `.environment(\.colorScheme)`, NOT `.preferredColorScheme`:
            // the latter is a PREFERENCE that flows UP to the hosting window, which would leave the
            // whole app stuck dark after onboarding finishes and quietly override Settings →
            // Appearance. Setting the environment styles only onboarding's own subtree. Every
            // `Theme` token is an asset colorset, so they all resolve dark from this one line.
            .environment(\.colorScheme, .dark)
        }
        // Onboarding owns the screen: the coach cover must never stack over it (proactive seeds
        // and deep links suspend until the flow completes). No `initial:` — isSuspended already
        // defaults false, and an initial-render state write can glitch cover presentation.
        .onChange(of: showOnboarding) { _, showing in
            coach.isSuspended = showing
            // The account is the last beat of onboarding now, so a sign-in can land with a freshly
            // built profile and plan on disk — `noteRealSignIn` must not read that as a
            // hand-me-down account switch and delete it.
            auth.isOnboarding = showing || gateAccountBeat
        }
        // The relaunch gate's account beat is that SAME last beat, just hosted here instead of by
        // `OnboardingFlow` — so it needs the identical protection. Without this, an athlete who
        // force-quit at the wall, subscribed on relaunch, and then signed in with an account that
        // differs from the last real one this device saw would trip `onAccountSwitch` and have the
        // profile and plan they just built deleted underneath them, moments after paying for it.
        .onChange(of: gateAccountBeat) { _, showing in
            auth.isOnboarding = showing || showOnboarding
        }
        #if DEBUG
        .fullScreenCover(isPresented: $showWidgetPreview) {
            WidgetPreviewHarness()
        }
        .fullScreenCover(isPresented: $showSettingsDeepLink) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showSettingsDeepLink = false }
                        }
                    }
            }
        }
        #endif
        // Supabase auth links (momentum://auth-callback) — today that's the password-recovery
        // email; the link signs the athlete in, then `needsNewPassword` raises the sheet below.
        // momentum://today is the Home Screen widget's tap target: land on Today.
        .onOpenURL { url in
            if url.host == "today" { selection = .today; return }
            auth.handleAuthCallback(url)
        }
        .sheet(isPresented: $auth.needsNewPassword) { SetNewPasswordView() }
        .onAppear {
            // A Siri receipt posted under quiet provisional delivery → ask properly (once) so
            // the next "Logged to Fuel" actually banners.
            NotificationService.promoteReceiptAuthorizationIfNeeded()
            if auth.isSignedIn && profiles.isEmpty { showOnboarding = true }
            // One check per cold launch (onAppear re-fires on cover dismissals, when the marker may
            // belong to a legitimately live workout), and never over the sign-in/onboarding gates —
            // the marker survives until handled, so deferring a launch loses nothing.
            if auth.isSignedIn, !profiles.isEmpty, !Self.didCheckRecovery {
                Self.didCheckRecovery = true
                if let pending = WorkoutRecovery.checkOnLaunch(in: context) {
                    recoveredWorkout = pending
                    showRecoveryPrompt = true
                }
                // Heal recent workouts whose route snapshot failed to render at finish — History
                // thumbnails recover on launch instead of showing bare silhouettes forever.
                Task { await WorkoutSnapshotHealer.sweep(in: context) }
                // Mint the record book on LAUNCH, not on a tab visit. This is one-shot (versioned
                // flag) and dedupes per (type, workout), but it used to run only inside
                // `ProgressView` — so an athlete who imported a history from Apple Health and went
                // straight to Profile read a flat "0 PRS" until they happened to open Progress.
                // The trio is one of the first things anyone sees; it has to be true on arrival.
                // Deferred a beat so the replay never competes with first paint.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.8))
                    RecordsBook.backfillIfNeeded(in: context)
                }
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--onboarding") { showOnboarding = true }
            if ProcessInfo.processInfo.arguments.contains("--paywall") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { paywall.present(for: .aiCoach) }
            }
            if ProcessInfo.processInfo.arguments.contains("--coach") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { coach.open() }
            }
            if ProcessInfo.processInfo.arguments.contains("--save-screen") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { showSaveScreen = true }
            }
            if ProcessInfo.processInfo.arguments.contains("--strength-live-planned") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { showStrengthLivePlanned = true }
            }
            if ProcessInfo.processInfo.arguments.contains("--coach-card") {
                // Deterministic proposal in the thread (no network) — screenshot the card + Apply flow.
                CoachDemo.seedProposalIfNeeded(in: context)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { coach.open() }
            }
            if ProcessInfo.processInfo.arguments.contains("--coach-badge") {
                // Seed WITHOUT opening the chat — verifies the unseen-news dot on Today's button.
                CoachDemo.seedProposalIfNeeded(in: context)
            }
            if ProcessInfo.processInfo.arguments.contains("--settings") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showSettingsDeepLink = true }
            }
            // --siri-log: exercise the Siri logging path end-to-end (meal + receipt notification)
            // without Siri — the intent's perform() runs this exact code.
            if ProcessInfo.processInfo.arguments.contains("--siri-log") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    if let receipt = await SiriMealLogger.logAndEstimate(
                        text: "energy gel and a banana", in: context) {
                        SiriMealLogger.postReceipt(receipt)
                    }
                }
            }
            #endif
        }
        // Just signed in (new athlete) → straight into onboarding.
        .onChange(of: auth.isSignedIn) { _, signedIn in if signedIn && profiles.isEmpty { showOnboarding = true } }
        // Returning to onboarding after a data wipe (Settings → Delete all data).
        .onChange(of: profiles.isEmpty) { _, empty in if empty && auth.isSignedIn { showOnboarding = true } }
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    tabContent(tab)
                }
            }
        }
        .background(Theme.background)
        // Publish the athlete's own body figure once (and on any sex change), so every muscle map —
        // including the ones inside covers, which don't inherit the environment — shows the right
        // anatomy. `.task(id:)` re-fires when the sex changes, keeping Profile → Edit live.
        .task(id: profiles.first?.sex) { AthleteFigure.sex = BodySex(profileSex: profiles.first?.sex) }
    }

    @ViewBuilder
    private func tabContent(_ tab: AppTab) -> some View {
        NavigationStack { screen(for: tab) }
    }

    @ViewBuilder
    private func screen(for tab: AppTab) -> some View {
        switch tab {
        case .today: TodayView()
        case .plan: PlanView()
        case .progress: ProgressScreen()
        case .fuel: FuelView(showsDone: false)   // tab-hosted: the tab bar is the way out, no Done
        case .profile: ProfileScreen()
        }
    }
}

#Preview {
    RootView()
        .environment(Services.live())
        .environment(PaywallController(isPro: false))
        .environment(AuthController(userID: "preview"))
}
