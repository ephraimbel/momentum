import SwiftUI

/// Today / Home (PRD §7.2). Phase 0 placeholder — the calm "what do I do today?"
/// card, streak, week ring, and Start control land in Phase 1/2.
struct TodayView: View {
    var body: some View {
        PlaceholderScreen(
            title: "Today",
            symbol: "bolt.heart",
            note: "Your one calm instruction lands here."
        )
    }
}

#Preview { TodayView().environment(Services.live()) }
