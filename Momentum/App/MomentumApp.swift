import SwiftUI
import SwiftData

/// Entry point. The SwiftData `ModelContainer` is the only singleton; everything
/// else is constructed here and injected via the `Services` environment object.
@main
struct MomentumApp: App {
    @State private var services: Services
    @State private var paywall: PaywallController
    @State private var auth: AuthController
    @State private var follows = FollowStore()
    @State private var reactions = ReactionStore()
    @State private var moderation = ModerationStore()
    @State private var comments = CommentStore()
    @State private var remoteFeed = RemoteFeedStore()

    init() {
        // One `PaywallController` backs both `services.paywall` (service-layer checks) and the
        // environment (reactive view gating), so entitlement never diverges (PRD §10).
        let controller = PaywallController()
        controller.configure()   // RevenueCat/Superwall when linked; no-op local seam otherwise
        _paywall = State(initialValue: controller)
        let services = Services.live(paywall: controller)
        _services = State(initialValue: services)
        let authController = AuthController()
        // First-ever cloud session (fresh sign-in or guest upgrade): re-mark everything dirty so
        // the sync + publish sweeps re-upload local history under the new account (idempotent —
        // upserts are id-keyed).
        authController.onFirstCloudSession = {
            let context = PersistenceController.shared.container.mainContext
            let workouts = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
            for workout in workouts {
                workout.syncedAt = nil
                workout.postPublishedAt = nil
            }
            try? context.save()
            // A guest who onboarded already picked an identity — claim it under the new account
            // (conflicts surface as one inbox notification). No profile yet = gate sign-in before
            // onboarding; that path claims right after onboarding's finish() instead.
            if let profile = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first {
                Task { await services.social.claimProfile(profile, in: context) }
            }
        }
        authController.refresh()   // sign out if the Apple credential was revoked
        _auth = State(initialValue: authController)
        // The social stores stay the UI's source of truth; the backend syncs behind them.
        follows.backend = services.social
        reactions.backend = services.social
        moderation.backend = services.social
        comments.backend = services.social
        remoteFeed.backend = services.social
        remoteFeed.reactions = reactions
        remoteFeed.follows = follows
        MetricsMonitor.shared.start()   // crash + performance monitoring (PRD §13.5)
    }

    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(services)
                .environment(paywall)
                .environment(auth)
                .environment(follows)
                .environment(reactions)
                .environment(moderation)
                .environment(comments)
                .environment(remoteFeed)
                .tint(Theme.ink)
                // Appearance is the athlete's choice (Settings → Appearance). The design system was
                // born dark-hero and re-cut light-hero — both palettes live in the asset catalog,
                // so the whole app re-skins from the same tokens. `nil` follows the system.
                .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme ?? nil)
        }
        .modelContainer(PersistenceController.shared.container)
    }
}
