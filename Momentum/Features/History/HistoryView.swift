import SwiftUI

/// History — mixed activity feed (PRD §7.10). Phase 0 placeholder.
struct HistoryView: View {
    var body: some View {
        PlaceholderScreen(
            title: "History",
            symbol: "list.bullet.rectangle",
            note: "Your whole training life as a calm archive."
        )
    }
}

#Preview { HistoryView().environment(Services.live()) }
