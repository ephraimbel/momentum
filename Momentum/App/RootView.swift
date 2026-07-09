import SwiftUI
import SwiftData

/// App shell: a `TabView` with one `NavigationStack` per tab (PRD §13.10).
/// Onboarding presents as a gated `fullScreenCover` over this on first launch.
struct RootView: View {
    @Query private var profiles: [UserProfile]
    @Environment(PaywallController.self) private var paywall
    @Environment(AuthController.self) private var auth
    @State private var selection: AppTab = {
        #if DEBUG
        // Deterministic deep-links for sim verification (tab-bar taps are unreliable in the sim).
        let args = ProcessInfo.processInfo.arguments
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
                .fullScreenCover(isPresented: $showOnboarding) {
                    OnboardingFlow { showOnboarding = false }
                }
                // Any locked feature anywhere routes through here (PRD §10 — contextual gates).
                .sheet(item: $paywall.presentedFeature) { feature in
                    PaywallView(feature: feature)
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
                #endif
            }
        }
        .onAppear {
            if auth.isSignedIn && profiles.isEmpty { showOnboarding = true }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--onboarding") { showOnboarding = true }
            if ProcessInfo.processInfo.arguments.contains("--paywall") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { paywall.present(for: .aiCoach) }
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
