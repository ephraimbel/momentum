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
    @Environment(\.colorScheme) private var colorScheme   // the tab-bar monogram bakes it in
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
    /// True for ~one dismiss-animation beat after onboarding completes, so the tab shell (and its
    /// Mapbox map) is built AFTER the cover has left the screen, not during its dismissal.
    @State private var holdTabsForOnboardingDismiss = false
    /// The athlete's photo, drawn as the Profile tab's icon. Nil until rendered, and while nil the
    /// tab falls back to its SF Symbol — so a profile with no photo behaves exactly as before.
    @State private var profileTabIcon: UIImage?
    /// Second phase of the onboarding hard gate: they subscribed from the RELAUNCH wall (having
    /// force-quit onboarding at the paywall), so they never reached onboarding's `.account` beat and
    /// would otherwise land in the app as a paying permanent guest — anonymous to RevenueCat, with
    /// no cloud copy of anything they paid for. Rides the SAME cover as the wall rather than adding a
    /// fifth presentation modifier to this chain (see the ceiling note above).
    @State private var gateAccountBeat = false
    #if DEBUG
    /// One-shot latch for the launch-arg deep links in `onAppear` — see the guard there.
    @MainActor private static var didFireDebugArgs = false
    /// Newest-first, bounded — see `recentWorkouts` below.
    private static let recentWorkoutsDescriptor: FetchDescriptor<Workout> = {
        var d = FetchDescriptor<Workout>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        d.fetchLimit = 24
        return d
    }()
    // Open the most recent run's detail (for verifying the guided-run Reps breakdown).
    // Bounded: this lives in the app SHELL, so an unbounded query re-materialized the entire
    // workout table on every store change and inflated every tab switch in debug builds — the
    // deep links it feeds only ever want something recent.
    @Query(RootView.recentWorkoutsDescriptor) private var recentWorkouts: [Workout]
    @State private var showRunDetail = ProcessInfo.processInfo.arguments.contains("--ui-test-run-detail")
    // Flipped AFTER insertion (onAppear + delay) — a cover whose isPresented is already true while
    // the view is being inserted can silently fail to present (see the onboarding note below).
    @State private var showSaveScreen = false
    // Straight to Settings (screenshot verification of the settings surface).
    @State private var showSettingsDeepLink = false
    #if DEBUG
    /// --explainer-demo: presents the hrZones MetricDetailSheet directly — deterministic screenshot
    /// of the citation card (App Review 1.4.1) without fighting chart-ⓘ tap coordinates.
    @State private var showExplainerDemo = false
    #endif
    // The onboarding paywall flow, presented directly for screenshot verification.
    @State private var showOnboardingPaywallFlow = false
    // --timed-save-ebike: the stationary e-bike save screen over a minted session.
    @State private var showTimedSaveEbike = false
    @State private var ebikeDebugWorkout: Workout?
    @State private var showWidgetPreview = ProcessInfo.processInfo.arguments.contains("--widget-preview")
    // Straight into the planned-lift checklist (screenshot verification of the live strength flow).
    @State private var showStrengthLivePlanned = false
    @State private var showStrengthSave = false
    #endif

    /// The splash rides over EVERYTHING for ~1.15s at cold launch (owner ask 2026-08-20) — it
    /// mirrors the static launch screen exactly, so system frame → splash → app reads as one
    /// continuous moment. State starts true once per process; unmounted after its fade.
    @State private var showSplash = true

    var body: some View {
        #if DEBUG
        mainBody
            .overlay { if showSplash { SplashView { showSplash = false } } }
        #else
        mainBody
            .overlay { if showSplash { SplashView { showSplash = false } } }
        #endif
    }

    /// A root fullScreenCover owns the screen — pause under-cover overlays (awards, toasts).
    private var rootCoverOwnsScreen: Bool {
        paywall.presentedFeature != nil || coach.isPresented
            || showOnboarding || showRecoveryPrompt || recoverySave != nil
    }

    private var mainBody: some View {
        @Bindable var paywall = paywall
        @Bindable var coach = coach
        @Bindable var auth = auth
        @Bindable var router = router
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
                    // The hold keeps the canvas one beat longer after onboarding completes: swapping
                    // in `tabs` the instant the flag flips built the whole shell — Mapbox included —
                    // in the same frame the cover's dismiss animation started, and that stutter was
                    // the athlete's very last impression of setup (perf audit 2026-08-13).
                    if showOnboarding || holdTabsForOnboardingDismiss {
                        Theme.background.ignoresSafeArea()
                    } else {
                        // The ONE workout recorder, mounted over the whole shell (tab bar included)
                        // so a run started from Today or Plan crossfades up over the map rather
                        // than sliding a modal cover with a second presentation context
                        // (shared-map pass 2026-08-19). Launch state lives on the router.
                        tabs.workoutRunner(launch: $router.workoutLaunch)
                    }
                }
                // Award unlocks meet the athlete wherever they land — awards can arrive from any
                // path (save flows, Health import, a plan week completing), so the presenter sits
                // once at the root rather than on each surface. Paused while a root cover owns the
                // screen (the overlay renders UNDER covers — presenting then would play the whole
                // celebration invisibly behind them).
                // Also paused while the workout overlay owns the screen: awards are queued at the
                // save moment, and with the recorder now an overlay (not a cover) the presenter
                // could otherwise draw a medallion OVER the live run. They present the moment the
                // recorder fades out — exactly the old "as the save cover clears" beat.
                .awardUnlocks(paused: rootCoverOwnsScreen || router.workoutLaunch != nil)
                // The app-wide toast capsule (enterprise pass 2026-08-15) — one host, over the tab
                // shell. Same under-covers reality as awards: while a root cover owns the screen the
                // center is held, so a coaching toast waits for the athlete instead of expiring
                // invisibly behind onboarding or the paywall.
                .overlay(alignment: .top) { ToastHost() }
                .onChange(of: rootCoverOwnsScreen, initial: true) { _, covered in
                    if covered { ToastCenter.shared.hold("root-cover") }
                    else { ToastCenter.shared.release("root-cover") }
                }
                // Any locked feature anywhere routes through here (PRD §10 — contextual gates).
                // Full screen (not a sheet): the paywall is a considered, premium moment — it owns
                // the whole canvas, like onboarding.
                // Stand down while the coach chat is up: the coach is itself a fullScreenCover, so
                // this root cover can't present on top of it — CoachChatView hosts its OWN paywall
                // cover for the "gate on send" moment. Both binding to `presentedFeature` fired the
                // paywall TWICE (root + coach) with a dark flash in between; gating on
                // `coach.isPresented` leaves exactly one host live at a time.
                // Also stands down while a workout save context owns the screen: CardioSaveView
                // hosts its OWN paywall cover (a save screen can itself sit inside a cover — the
                // crash-recovery save, the --save-screen harness — where this root cover cannot
                // present on top). One live host per context, never two bound to one item (the
                // double-present bug).
                .fullScreenCover(item: Binding(
                    get: { coach.isPresented || router.workoutLaunch != nil || recoverySave != nil
                        ? nil : paywall.presentedFeature },
                    set: { paywall.presentedFeature = $0 })) { feature in
                    PaywallView(feature: feature)
                }
                // The onboarding gate — SOFT since 2026-08-06 (user call). `finishOnboarding` still
                // sets the flag when setup reaches the paywall un-entitled, so a force-quit at the
                // wall re-raises it here once; but the wall's X now clears the flag and moves on,
                // so no one is ever locked out. Anyone left mid-gate by the hard era (the flag
                // persisted) gets the same X on their next launch.
                // `set` still does NOT clear `onboardingGatePending` — the clears are an entitlement
                // (`setPro(true)`) and the flow's own close(), both of which run before this cover
                // resolves, so a dismissal here never needs to. The store-unreachable deferral
                // (`storeUnreachableDeferral`, unpersisted) remains as a belt-and-braces escape.
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
                        // Re-enters the three-page flow AT the checkout page — the athlete saw
                        // the try-free and reminder pages before force-quitting; re-telling the
                        // story would read as a loop.
                        OnboardingPaywallFlow(startAtCheckout: true, onEntitled: {
                            // A purchase landed HERE, so onboarding's own paywall → `.account`
                            // hand-off never ran. Swap this cover to the account beat instead of
                            // letting the paywall dismiss — flipping `gateAccountBeat` keeps `get`
                            // true, so the cover is never torn down and there is no re-presentation
                            // to lose under load. If they already have a real account there's nothing
                            // to offer: leave it alone and `get` goes false on its own.
                            guard !(auth.isSignedIn && !auth.isGuest) else { return }
                            gateAccountBeat = true
                        }, onClose: {
                            // The X (soft gate): they skipped paying, but they also never reached
                            // onboarding's account beat — offer it the same cover-swapping way.
                            // close() already cleared the gate flag, so for a signed-in athlete
                            // `get` goes false on its own and the cover resolves.
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
                        // --save-screen-ride narrows to the seeded ride — the summary reads a ride
                        // in speed (chart + splits), and that branch is unreachable from a run.
                        let wantRide = ProcessInfo.processInfo.arguments.contains("--save-screen-ride")
                        if let run = recentWorkouts.first(where: {
                            $0.type.isGPS && $0.gps != nil && (!wantRide || $0.type.isCycling) }) {
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
                // --strength-save: the post-lift save editor for the newest seeded strength
                // session — deterministic verification of the summary's Strava-shaped order
                // (muscle-map identity card, exercise volume bars, week tonnage card). Own
                // background view (same 4th-modifier gotcha as above).
                .background {
                    Color.clear.fullScreenCover(isPresented: $showStrengthSave) {
                        if let lift = recentWorkouts.first(where: { $0.strength != nil }) {
                            StrengthSaveView(workoutId: lift.id) { showStrengthSave = false }
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
                // Claim the just-picked identity (@handle, name, avatar) on the backend NOW —
                // waiting for the next cold launch's claim would leave the handle unprotected
                // for the whole first session. No-op for guests/dark builds; a lost race posts
                // the deduped "handle taken" notification.
                if CommunityAccess.enabled, let fresh = profiles.first {
                    Task { await services.social.claimProfile(fresh, in: context) }
                }
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
            if !showing {
                // Onboarding just finished: hold the tab shell until the cover's dismiss animation
                // has the screen to itself (see the canvas branch above).
                holdTabsForOnboardingDismiss = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(550))
                    holdTabsForOnboardingDismiss = false
                }
            }
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
        // --paywall-onboarding [--paywall-onboarding-2]: the two-page onboarding wall, for
        // screenshot verification without driving the whole onboarding. -2 enters at checkout,
        // the relaunch-gate framing.
        .fullScreenCover(isPresented: $showOnboardingPaywallFlow) {
            OnboardingPaywallFlow(
                startAtCheckout: ProcessInfo.processInfo.arguments.contains("--paywall-onboarding-2"))
        }
        // --timed-save-ebike: mints a finished 25-minute stationary e-bike session and opens its
        // save screen — verifies the console-readout rows (distance/elevation/avg speed) without
        // driving a live session.
        .fullScreenCover(isPresented: $showTimedSaveEbike) {
            if let w = ebikeDebugWorkout {
                TimedSaveView(workoutId: w.id) { showTimedSaveEbike = false }
            }
        }
        #if DEBUG
        .sheet(isPresented: $showExplainerDemo) {
            MetricDetailSheet(explainer: MetricExplainers.hrZones)
                .presentationDetents([.large])
        }
        #endif
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
        // Own background host (the 4th-chained-presentation gotcha documented above): this sheet
        // sat 4th on the outer chain in Release, exactly where covers silently stop presenting —
        // the recovery email's whole payoff could fail to appear, leaving the athlete signed in
        // but never asked for a new password. A separate host also stops it fighting the
        // onboarding cover for one slot when a recovery link lands on a profile-less install
        // (both raise in the same update). (Audit 2026-08-11.)
        .background {
            Color.clear.sheet(isPresented: $auth.needsNewPassword) { SetNewPasswordView() }
        }
        .onAppear {
            // A Siri receipt posted under quiet provisional delivery → ask properly (once) so
            // the next "Logged to Fuel" actually banners.
            NotificationService.promoteReceiptAuthorizationIfNeeded()
            if auth.isSignedIn && profiles.isEmpty { showOnboarding = true }
            // Ad-tracking consent (2026-08-13). Deliberately NOT at cold launch of a fresh install:
            // ATT gives each install exactly one prompt, and spending it on someone who has not yet
            // seen the app converts far worse than asking a runner who is already set up. Reaching
            // here with a profile means onboarding is behind them. `requestOnce` no-ops forever
            // after either answer, so this costs nothing on every later launch.
            if auth.isSignedIn, !profiles.isEmpty { AdTrackingConsent.requestOnce() }
            // One check per cold launch (onAppear re-fires on cover dismissals, when the marker may
            // belong to a legitimately live workout), and never over the sign-in/onboarding gates —
            // the marker survives until handled, so deferring a launch loses nothing.
            if auth.isSignedIn, !profiles.isEmpty, !Self.didCheckRecovery {
                Self.didCheckRecovery = true
                if let pending = WorkoutRecovery.checkOnLaunch(in: context) {
                    recoveredWorkout = pending
                    showRecoveryPrompt = true
                }
                // (The `--save-screen` deep link lives ONLY in the arg block below, presenting
                // through `showSaveScreen`'s dedicated cover. A second copy here queued the SAME
                // editor through `recoverySave` — it couldn't present while the dedicated cover
                // was up, so it fired the moment Done dismissed it, re-opening the save screen
                // right after the celebration. Removed 2026-08-07.)
                // Heal recent workouts whose route snapshot failed to render at finish — History
                // thumbnails recover on launch instead of showing bare silhouettes forever.
                // Deferred well past first paint: each heal constructs a full Mapbox Snapshotter
                // (its own map engine pulling tiles), and unthrottled it raced Today's map for the
                // network + main thread at the exact moment of first render (perf audit 2026-08-13).
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    await WorkoutSnapshotHealer.sweep(in: context)
                }
                // Claim/refresh the athlete's public identity once per launch (handle, name, bio,
                // avatar, Pro checkmark) — the community-era hook restored with the launch wiring
                // (2026-07-29). No-op for guests and dark builds (`isAvailable` gate inside).
                if CommunityAccess.enabled, let profile = profiles.first {
                    // One-shot: pre-2026-08-06 profiles stored routes-off under a default no UI
                    // could change — their shared runs rendered glyphs on the wall forever.
                    if SocialPrivacy.migrateRouteMapsDefault(profile) { try? context.save() }
                    Task { await services.social.claimProfile(profile, in: context) }
                }
                // Mint the record book on LAUNCH, not on a tab visit. This is one-shot (versioned
                // flag) and dedupes per (type, workout), but it used to run only inside
                // `ProgressView` — so an athlete who imported a history from Apple Health and went
                // straight to Profile read a flat "0 PRS" until they happened to open Progress.
                // The trio is one of the first things anyone sees; it has to be true on arrival.
                // Deferred so the replay never competes with first paint — 0.8 s turned out to be
                // exactly when the athlete starts scrolling, so it moved to 3 s (2026-08-13). A
                // Progress visit inside that window is covered: its own first task runs the same
                // one-shot backfill before it snapshots the PR shelf.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    RecordsBook.backfillIfNeeded(in: context)
                }
            }
            #if DEBUG
            // ONE-SHOT per process: `onAppear` re-fires every time a cover dismisses (see the
            // recovery note above), so an unguarded deep-link arg here re-triggered itself forever
            // — `--save-screen` re-presented the save editor 0.8s after the celebration closed it
            // (caught 2026-08-07: CardioSaveMapStyleUITests could only pass by racing the re-present),
            // and `--timed-save-ebike` minted a duplicate workout per dismissal.
            guard !Self.didFireDebugArgs else { return }
            Self.didFireDebugArgs = true
            if ProcessInfo.processInfo.arguments.contains("--onboarding") { showOnboarding = true }
            if ProcessInfo.processInfo.arguments.contains("--paywall") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { paywall.present(for: .aiCoach) }
            }
            if ProcessInfo.processInfo.arguments.contains("--coach") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { coach.open() }
            }
            if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--save-screen") }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { showSaveScreen = true }
            }
            if ProcessInfo.processInfo.arguments.contains("--strength-live-planned") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { showStrengthLivePlanned = true }
            }
            if ProcessInfo.processInfo.arguments.contains("--strength-save") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { showStrengthSave = true }
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
            if ProcessInfo.processInfo.arguments.contains("--explainer-demo") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showExplainerDemo = true }
            }
            if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--paywall-onboarding") }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showOnboardingPaywallFlow = true }
            }
            if ProcessInfo.processInfo.arguments.contains("--timed-save-ebike") {
                let w = Workout()
                w.type = .eBikeRide
                w.durationS = 25 * 60
                w.elapsedS = 25 * 60
                context.insert(w)
                try? context.save()
                ebikeDebugWorkout = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showTimedSaveEbike = true }
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
                Tab(value: tab) {
                    tabContent(tab)
                } label: {
                    tabLabel(tab)
                }
            }
        }
        .background(Theme.background)
        // The bar condenses on scroll-down and restores on scroll-up (iOS 26 native; no-op below).
        .minimizingTabBar()
        // Rendered here, never in `body`: this view re-evaluates continuously under a panning
        // Mapbox map, and the redraw is keyed so it only reruns when the photo or the selection
        // actually changes.
        .task(id: ProfileIconKey(avatar: profiles.first?.avatarData,
                                 name: profiles.first?.displayName ?? "",
                                 scheme: colorScheme,
                                 selected: selection == .profile)) {
            profileTabIcon = ProfileTabIcon.make(from: profiles.first?.avatarData,
                                                 name: profiles.first?.displayName ?? "",
                                                 colorScheme: colorScheme,
                                                 selected: selection == .profile)
        }
        // Publish the athlete's own body figure once (and on any sex change), so every muscle map —
        // including the ones inside covers, which don't inherit the environment — shows the right
        // anatomy. `.task(id:)` re-fires when the sex changes, keeping Profile → Edit live.
        .task(id: profiles.first?.sex) { AthleteFigure.sex = BodySex(profileSex: profiles.first?.sex) }
    }

    /// The Instagram-style tab item: outline glyph at rest, its filled sibling when selected, the
    /// athlete's own photo for Profile, and **no visible caption** — the icons carry the bar, which
    /// is most of what makes that bar read clean. Names still exist for assistive tech: the empty
    /// visible text is paired with an explicit `accessibilityLabel`, so VoiceOver announces
    /// "Progress", not silence.
    @ViewBuilder
    private func tabLabel(_ tab: AppTab) -> some View {
        let selected = selection == tab
        Label {
            // The REAL title, then `.iconOnly` below to hide it. An empty caption was tried first
            // and broke selection outright — with five identical empty titles the UIKit bridge
            // collapsed tab identity and every launch landed on Profile. The title is identity;
            // the label style is presentation.
            Text(tab.title)
        } icon: {
            if tab == .profile, let icon = profileTabIcon {
                // Pre-rendered `.alwaysOriginal` UIImage so the bar cannot tint the photo into a
                // silhouette (see `ProfileTabIcon`); its selected ring is baked into the render.
                Image(uiImage: icon)
            } else {
                Image(systemName: selected ? tab.selectedImage : tab.systemImage)
            }
        }
        // The bar upgrades every SF Symbol to `.fill` on its own, which would erase the
        // outline-at-rest half of the state change. Opting out here is what lets `map` actually
        // render as an outline until it is chosen.
        .environment(\.symbolVariants, .none)
        .labelStyle(.iconOnly)
        .accessibilityLabel(tab.title)
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

/// What the profile tab icon depends on. A struct rather than two `.task(id:)` modifiers so the
/// redraw fires once when either half changes, not twice.
private struct ProfileIconKey: Equatable {
    let avatar: Data?
    let name: String
    let scheme: ColorScheme
    let selected: Bool
}

#Preview {
    RootView()
        .environment(Services.live())
        .environment(PaywallController(isPro: false))
        .environment(AuthController(userID: "preview"))
}
