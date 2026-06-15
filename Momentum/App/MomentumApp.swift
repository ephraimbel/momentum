import SwiftUI
import SwiftData

/// Entry point. The SwiftData `ModelContainer` is the only singleton; everything
/// else is constructed here and injected via the `Services` environment object.
@main
struct MomentumApp: App {
    @State private var services: Services
    @State private var paywall: PaywallController

    init() {
        // One `PaywallController` backs both `services.paywall` (service-layer checks) and the
        // environment (reactive view gating), so entitlement never diverges (PRD §10).
        let controller = PaywallController()
        controller.configure()   // RevenueCat/Superwall when linked; no-op local seam otherwise
        _paywall = State(initialValue: controller)
        _services = State(initialValue: Services.live(paywall: controller))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(services)
                .environment(paywall)
                .tint(Theme.ink)
                .preferredColorScheme(.light) // light/white is the hero aesthetic
        }
        .modelContainer(PersistenceController.shared.container)
    }
}
