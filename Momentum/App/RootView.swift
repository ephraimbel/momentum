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
    @Environment(\.requestReview) private var requestReview   // native App Store rating prompt
    @Environment(\.modelContext) private var context
    // Cold-launch recovery (PRD §8.3/§8.4): a workout that was live when the app died. Every sample
    // and set was persisted as it happened — this prompt is how they come back.
    @State private var recoveredWorkout: Workout?
    @State private var showRecoveryPrompt = false
    @State private var recoverySave: PresentedWorkout?
    /// Once per process: a fresh launch is the only moment the marker can't belong to a live workout.
    @MainActor private static var didCheckRecovery = false
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
    #endif

    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--health-e2e") {
            HealthE2EView()
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
                // Login gate (PRD §8.11): Sign in with Apple before anything else.
                SignInView()
            } else {
                ZStack {
                    // Until onboarding is done, show a clean canvas — don't build the Today map yet,
                    // so it can't trigger a location prompt "up front" (PRD §4.1, §11 privacy).
                    if showOnboarding { Theme.background.ignoresSafeArea() } else { tabs }
                }
                // Any locked feature anywhere routes through here (PRD §10 — contextual gates).
                // Full screen (not a sheet): the paywall is a considered, premium moment — it owns
                // the whole canvas, like onboarding.
                .fullScreenCover(item: $paywall.presentedFeature) { feature in
                    PaywallView(feature: feature)
                }
                // Freemium (2026-07-14): the onboarding paywall is now SOFT, so new athletes never set
                // this flag. It only fires for legacy users who force-quit the OLD hard gate — and even
                // then it's dismissible and self-clears, so nobody stays walled out of the free tier.
                .fullScreenCover(isPresented: Binding(
                    get: { paywall.onboardingGatePending && !paywall.isPro && !showOnboarding && !profiles.isEmpty },
                    set: { if !$0 { paywall.onboardingGatePending = false } })) {
                    PaywallView(feature: .fullPlan, hard: false)
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
                            CardioSaveView(workoutId: run.id, workoutType: run.type) { showSaveScreen = false }
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
                recoverySave = PresentedWorkout(id: workout.id, type: workout.type)
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
                CardioSaveView(workoutId: presented.id, workoutType: presented.type) { recoverySave = nil }
            }
        }
        // Onboarding presents from THIS always-installed level, not from the signed-in branch:
        // sign-in flips the branch and raises this flag in the same update, and a cover attached
        // to a view being inserted that instant can silently fail to present (blank canvas).
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingFlow { requestedReview in
                showOnboarding = false
                // The coach says hello the moment there's a plan to explain — a quiet seed the
                // Today button badges, offered at the peak-curiosity moment. Once ever.
                if profiles.first?.plan != nil { CoachProactive.seedPlanIntro(in: context) }
                // The athlete asked to rate on the final onboarding beat — fire the native prompt
                // once the flow's cover has fully dismissed and Today is on screen (presenting it
                // mid-teardown cancels it). System-owned, rate-limited: it shows when iOS allows.
                if requestedReview {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(0.9))
                        requestReview()
                    }
                }
            }
        }
        // Onboarding owns the screen: the coach cover must never stack over it (proactive seeds
        // and deep links suspend until the flow completes). No `initial:` — isSuspended already
        // defaults false, and an initial-render state write can glitch cover presentation.
        .onChange(of: showOnboarding) { _, showing in coach.isSuspended = showing }
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
