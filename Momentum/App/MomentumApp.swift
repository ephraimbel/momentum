import SwiftUI
import SwiftData

/// Entry point. The SwiftData `ModelContainer` is the only singleton; everything
/// else is constructed here and injected via the `Services` environment object.
@main
struct MomentumApp: App {
    @State private var services = Services.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(services)
                .tint(Theme.ink)
                .preferredColorScheme(.light) // light/white is the hero aesthetic
        }
        .modelContainer(PersistenceController.shared.container)
    }
}
