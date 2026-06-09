import SwiftUI

/// Plan — unified calendar (PRD §7.7). Phase 0 placeholder.
struct PlanView: View {
    var body: some View {
        PlaceholderScreen(
            title: "Plan",
            symbol: "calendar",
            note: "A calm week that mixes your disciplines."
        )
    }
}

#Preview { PlanView().environment(Services.live()) }
