import SwiftUI

/// You / Profile — PRs, streak, analytics (PRD §7.10). Phase 0 placeholder.
struct ProfileView: View {
    var body: some View {
        PlaceholderScreen(
            title: "You",
            symbol: "person",
            note: "PRs, streak, and progress — you vs your past self."
        )
    }
}

#Preview { ProfileView().environment(Services.live()) }
