import SwiftUI
import SwiftData

/// App shell: a `TabView` with one `NavigationStack` per tab (PRD §13.10).
/// Onboarding presents as a gated `fullScreenCover` over this on first launch.
struct RootView: View {
    @Query private var profiles: [UserProfile]
    @State private var selection: AppTab = .today
    @State private var showOnboarding = false

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    NavigationStack {
                        screen(for: tab)
                    }
                }
            }
        }
        .background(Theme.background)
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingFlow { showOnboarding = false }
        }
        .onAppear { if profiles.isEmpty { showOnboarding = true } }
    }

    @ViewBuilder
    private func screen(for tab: AppTab) -> some View {
        switch tab {
        case .today: TodayView()
        case .plan: PlanView()
        case .progress: ProgressScreen()
        case .history: HistoryView()
        }
    }
}

#Preview {
    RootView()
        .environment(Services.live())
}
