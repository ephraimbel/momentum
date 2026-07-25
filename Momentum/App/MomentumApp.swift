import SwiftUI
import SwiftData

/// Entry point. The SwiftData `ModelContainer` is the only singleton; everything
/// else is constructed here and injected via the `Services` environment object.
@main
struct MomentumApp: App {
    @State private var services: Services
    @State private var paywall: PaywallController
    @State private var auth: AuthController
    @State private var coach = CoachPresenter()
    @State private var router = AppRouter()          // cross-tab routing mailbox (Health segment, RECOVERY-HUB-PLAN §2)
    // Social stores + backend wiring removed 2026-07-16: Community is back-burnered from v1 —
    // the app ships solo-first (Bevel-for-endurance positioning). The stores, feed, and Supabase
    // social backend all remain in the repo, dormant; re-wire here when community returns.

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
        // the personal sync re-uploads local history under the new account (idempotent — upserts
        // are id-keyed). postPublishedAt resets too so a future community return starts honest.
        authController.onFirstCloudSession = {
            let context = PersistenceController.shared.container.mainContext
            let workouts = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
            for workout in workouts {
                workout.syncedAt = nil
                workout.postPublishedAt = nil
            }
            try? context.save()
        }
        // A DIFFERENT real account signing in on this device (shared/hand-me-down) must never see the
        // prior owner's data: wipe local SwiftData so they start clean. RootView re-onboards the
        // moment `profiles.isEmpty` flips true. Guest→real upgrade + first sign-in never reach here.
        authController.onAccountSwitch = {
            DataManager.deleteAllUserData(in: PersistenceController.shared.container.mainContext)
        }
        // Billing follows the account: without this RevenueCat keeps a random anonymous customer id
        // per install, so a reinstall reads as a new customer and revenue can never be joined to a
        // user. Set before `refresh()`, which may itself sign the athlete out.
        authController.onIdentityChange = { [weak controller] userID in
            controller?.identify(userID: userID)
        }
        authController.refresh()   // sign out if the Apple credential was revoked
        // Link the already-restored session on a warm launch — `signIn` only fires on a fresh one.
        if let existing = authController.userID, !authController.isGuest {
            controller.identify(userID: existing)
        }
        _auth = State(initialValue: authController)
        MetricsMonitor.shared.start()   // crash + performance monitoring (PRD §13.5)
        // Wrist sync (Watch Slice 4): readiness/session/race push out, the morning check-in
        // comes back. Best-effort — no paired watch means these are no-ops.
        PhoneWatchSync.shared.health = services.health
        PhoneWatchSync.shared.activate()
        // A force-quit mid-workout strands its Live Activity — end leftovers before anything can
        // start a new one (the workout itself is recovered separately via WorkoutRecovery).
        CardioActivityController.endOrphans()
        RestActivityController.endOrphans()
    }

    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            // Appearance is the athlete's choice (Settings → Appearance). Explicit Light/Dark
            // installs a concrete preference; System installs NO modifier at all. This is
            // load-bearing: `preferredColorScheme(nil)` is not a no-op — its nil preference
            // writer re-propagates every pass and, with map surfaces reading `colorScheme`,
            // sustains a runaway invalidation loop (the f7e7e5f System-appearance regression:
            // CommunityView.body re-evaluated 333×/4s). Never reintroduce the `?? nil` form.
            if let scheme = AppAppearance(rawValue: appearanceRaw)?.colorScheme {
                root.preferredColorScheme(scheme)
            } else {
                root
            }
        }
        .modelContainer(PersistenceController.shared.container)
    }

    private var root: some View {
        RootView()
            .environment(services)
            .environment(paywall)
            .environment(auth)
            .environment(coach)
            .environment(router)
            .tint(Theme.ink)
            // Backgrounding is the last reliable moment to get a session's events off the device —
            // the batch threshold alone would strand the tail of every session (and the whole of a
            // short one). `.onChange` only reads scenePhase; it installs no preference writer, so
            // it cannot re-trigger the System-appearance invalidation loop noted above.
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { services.analytics.flush() }
            }
    }
}
