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
    // The five community stores — injected in EVERY configuration since 2026-07-29 (the launch
    // gate's step 1, docs/COMMUNITY-FEED-REDESIGN.md §6): each is UserDefaults-backed with no
    // network on init, and `RemoteFeedStore` keeps a nil backend until community actually flips,
    // so in the solo app they are inert. What this buys is safety: every social view reads them
    // via @Environment, and DEBUG-only injection meant any Release path that ever reached a
    // community surface would trap at runtime. Visibility is governed by `CommunityAccess`, never
    // by whether these exist.
    @State private var follows = FollowStore()
    @State private var reactions = ReactionStore()
    @State private var comments = CommentStore()
    @State private var moderation = ModerationStore()
    @State private var remoteFeed = RemoteFeedStore()
    // Social stores + backend wiring removed 2026-07-16: Community is back-burnered from v1 —
    // the app ships solo-first (Bevel-for-endurance positioning). The stores, feed, and Supabase
    // social backend all remain in the repo, dormant; re-wire here when community returns.

    init() {
        // One `PaywallController` backs both `services.paywall` (service-layer checks) and the
        // environment (reactive view gating), so entitlement never diverges (PRD §10).
        let controller = PaywallController()
        controller.configure()   // RevenueCat/Superwall when linked; no-op local seam otherwise
        TikTokAdsService.configure()   // TikTok ads attribution — dark until Secrets.xcconfig keys are set
        MetaAdsService.configure()     // Meta ads attribution — same dark-seam contract
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
            // The account moment is the registration event ad campaigns optimize on.
            TikTokAdsService.trackRegistration()
            MetaAdsService.trackRegistration()
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
        // The community's transport (2026-07-29, the launch wiring): every social store pushes its
        // mutations through `services.social` and pulls remote state in behind them. The stores
        // were BUILT for this hookup ("wired once in MomentumApp") but shipped dark through the
        // solo era — with a guest or an unconfigured backend `isAvailable` is false and every call
        // no-ops, so offline/guest behavior stays byte-identical.
        follows.backend = services.social
        reactions.backend = services.social
        comments.backend = services.social
        moderation.backend = services.social
        remoteFeed.backend = services.social
        remoteFeed.reactions = reactions
        remoteFeed.follows = follows
        MetricsMonitor.shared.start()   // crash + performance monitoring (PRD §13.5)
        // A previous launch could not open the store and moved it aside (`PersistenceController`).
        // Report it exactly once — it is the only signal that a shipped migration broke somebody's
        // install — but leave the record in place, because Settings goes on offering the file back
        // until the athlete dismisses it themselves.
        if let quarantine = PersistenceController.quarantineRecord, !quarantine.reported {
            services.analytics.log(.storeQuarantined(recovered: quarantine.recovered))
            PersistenceController.markQuarantineReported()
        }
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
            // Appearance is the athlete's choice (Settings → Appearance). Three shapes of this
            // code have failed; the constraints they discovered are all load-bearing:
            //
            // 1. `preferredColorScheme(scheme ?? nil)` — the nil preference writer re-propagates
            //    every pass and, with map surfaces reading `colorScheme`, sustained a runaway
            //    invalidation loop (f7e7e5f: CommunityView.body re-evaluated 333×/4s).
            // 2. `if let scheme { root.preferredColorScheme(scheme) } else { root }` — the two
            //    ViewBuilder arms are DIFFERENT structural identities, so crossing System ↔
            //    Light/Dark tore RootView down: every @State reset, tab selection snapped back to
            //    Today, and the athlete was dumped out of Settings (owner report, 2026-07-29).
            // 3. A conditional `Color.clear.preferredColorScheme(scheme)` leaf in root's
            //    background — leaf CREATION propagated (System→Dark went dark), but value changes
            //    and removal did not re-fire the preference: the window stuck on the first
            //    explicit scheme forever (verified by pixel, same day).
            //
            // So the mechanism leaves SwiftUI's preference system entirely:
            // `window.overrideUserInterfaceStyle`, set by an always-mounted zero-size probe.
            // Value-driven (no conditional structure, so RootView identity never changes), no
            // preference writer at all (so no invalidation loop), and the window override is what
            // UIKit itself honors — status bar, sheets, and covers all follow.
            root.background {
                AppearanceApplicator(style: AppAppearance(rawValue: appearanceRaw)?.interfaceStyle
                                            ?? .unspecified)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
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
            .environment(follows)
            .environment(reactions)
            .environment(comments)
            .environment(moderation)
            .environment(remoteFeed)
            .tint(Theme.ink)
            // Ceiling on Dynamic Type. `Font.custom(_:size:)` scales relative to `.body`, so every
            // string in the app grows with the athlete's text-size setting — unbounded, until this.
            // At the largest accessibility sizes the dense surfaces stopped being readable rather
            // than becoming more readable: Today's primary button truncated to "Start…", Progress's
            // streak pill landed on top of the title, and VO₂ MAX rendered as "3…" — the number the
            // stat exists for was the part that got cut.
            // accessibility1 still allows roughly double the default size, which is the range that
            // actually helps; past it these layouts lose more information than the larger type adds.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            // Backgrounding is the last reliable moment to get a session's events off the device —
            // the batch threshold alone would strand the tail of every session (and the whole of a
            // short one). `.onChange` only reads scenePhase; it installs no preference writer, so
            // it cannot re-trigger the System-appearance invalidation loop noted above.
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { services.analytics.flush() }
            }
    }
}

/// Applies the athlete's appearance choice at the WINDOW level. See the long comment at the call
/// site for why this is a UIKit override and not a SwiftUI preference — three SwiftUI shapes
/// failed before it.
private struct AppearanceApplicator: UIViewRepresentable {
    let style: UIUserInterfaceStyle

    func makeUIView(context: Context) -> ProbeView { ProbeView(style: style) }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.style = style
        view.applyToWindow()
    }

    /// The probe has no window at `makeUIView` time — `didMoveToWindow` is the first moment the
    /// override can land, and `updateUIView` handles every change after that.
    final class ProbeView: UIView {
        var style: UIUserInterfaceStyle
        init(style: UIUserInterfaceStyle) {
            self.style = style
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError() }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyToWindow()
        }
        func applyToWindow() {
            guard let window, window.overrideUserInterfaceStyle != style else { return }
            window.overrideUserInterfaceStyle = style
        }
    }
}
