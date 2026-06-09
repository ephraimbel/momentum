import SwiftUI

/// App shell: a `TabView` with one `NavigationStack` per tab (PRD §13.10).
/// Onboarding will later present as a gated `fullScreenCover` over this.
struct RootView: View {
    @State private var selection: AppTab = .today

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
    }

    @ViewBuilder
    private func screen(for tab: AppTab) -> some View {
        switch tab {
        case .today: TodayView()
        case .plan: PlanView()
        case .history: HistoryView()
        case .you: ProfileView()
        }
    }
}

#Preview {
    RootView()
        .environment(Services.live())
}
