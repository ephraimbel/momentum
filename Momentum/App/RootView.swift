import SwiftUI
import SwiftData

/// App shell: a `TabView` with one `NavigationStack` per tab (PRD §13.10).
/// Onboarding presents as a gated `fullScreenCover` over this on first launch.
struct RootView: View {
    @Query private var profiles: [UserProfile]
    @Environment(PaywallController.self) private var paywall
    @Environment(AuthController.self) private var auth
    @State private var selection: AppTab = .today
    @State private var showOnboarding = false

    var body: some View {
        @Bindable var paywall = paywall
        Group {
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
            }
        }
        .onAppear { if auth.isSignedIn && profiles.isEmpty { showOnboarding = true } }
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
        switch tab {
        case .coach:
            // The Coach is its own immersive chat (own NavigationStack), with the tab bar hidden so it
            // reads as a dedicated AI surface; its back arrow returns to the app.
            CoachChatView { selection = .today }
        default:
            NavigationStack { screen(for: tab) }
        }
    }

    @ViewBuilder
    private func screen(for tab: AppTab) -> some View {
        switch tab {
        case .today: TodayView()
        case .plan: PlanView()
        case .progress: ProgressScreen()
        case .world: WorldView()
        case .coach: EmptyView()   // routed by tabContent
        }
    }
}

#Preview {
    RootView()
        .environment(Services.live())
        .environment(PaywallController(isPro: false))
        .environment(AuthController(userID: "preview"))
}
