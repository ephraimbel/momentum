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
    @State private var router: AppRouter             // cross-tab routing mailbox (Health segment, RECOVERY-HUB-PLAN §2)
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
    @State private var nudges = NudgeStore()
    // Social stores + backend wiring removed 2026-07-16: Community is back-burnered from v1 —
    // the app ships solo-first (Bevel-for-endurance positioning). The stores, feed, and Supabase
    // social backend all remain in the repo, dormant; re-wire here when community returns.

    init() {
        // Error-only, privacy-locked diagnostics. Blank DSN = a complete no-op; in Debug an
        // explicit `--enable-sentry` launch argument is also required, keeping tests and visual
        // iteration out of the free quota. This starts first so launch crashes are observable.
        SentryMonitor.configure()
        #if DEBUG
        MainThreadWatchdog.startIfRequested()   // --community-perf: log main-thread stalls
        #endif
        // One `PaywallController` backs both `services.paywall` (service-layer checks) and the
        // environment (reactive view gating), so entitlement never diverges (PRD §10).
        let controller = PaywallController()
        controller.configure()   // local seams resolve NOW; the RevenueCat bring-up defers itself
        // Apple's own attribution framework. It needs no credentials, no ATT prompt and no privacy
        // disclosure, so it is always on — it is what lets a campaign optimise toward trials
        // instead of the cheapest install. Cheap (UserDefaults + an async postback), so it stays.
        SKANConversion.registerInstall()
        _paywall = State(initialValue: controller)
        let services = Services.live(paywall: controller)
        _services = State(initialValue: services)
        // The router is created HERE, not as a property default, because the notification
        // delegate needs its handle before any tap can arrive (a tap that launches the app is
        // delivered right after this init returns): a tapped notification lands in
        // `router.pendingNotificationRoute`, and the shell opens what it was about.
        let router = AppRouter()
        _router = State(initialValue: router)
        if let notifications = services.notifications as? NotificationService {
            notifications.router = router
            notifications.analytics = services.analytics   // the per-family open rate
        }
        let authController = AuthController()
        // First-ever cloud session (fresh sign-in or guest upgrade): re-mark everything dirty so
        // the personal sync re-uploads local history under the new account (idempotent — upserts
        // are id-keyed). postPublishedAt resets too so a future community return starts honest.
        authController.onFirstCloudSession = {
            guard let context = PersistenceController.shared.availableContainer?.mainContext else { return }
            let workouts = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
            for workout in workouts {
                workout.syncedAt = nil
                workout.postPublishedAt = nil
            }
            try? context.save()
            // The account moment is the registration event ad campaigns optimize on.
            TikTokAdsService.trackRegistration()
            MetaAdsService.trackRegistration()
            SKANConversion.record(.accountCreated)
        }
        // A DIFFERENT real account signing in on this device (shared/hand-me-down) must never see the
        // prior owner's data: wipe local SwiftData so they start clean. RootView re-onboards the
        // moment `profiles.isEmpty` flips true. Guest→real upgrade + first sign-in never reach here.
        authController.onAccountSwitch = {
            services.planSync.prepareForAccountSwitch()
            if let context = PersistenceController.shared.availableContainer?.mainContext {
                DataManager.deleteAllUserData(in: context)
            }
        }
        // Billing follows the account: without this RevenueCat keeps a random anonymous customer id
        // per install, so a reinstall reads as a new customer and revenue can never be joined to a
        // user. Set before `refresh()`, which may itself sign the athlete out.
        authController.onIdentityChange = { [weak controller] userID in
            controller?.identify(userID: userID)
        }
        // Link the already-restored session on a warm launch — `signIn` only fires on a fresh one.
        // (`identify` queues until the deferred RevenueCat bring-up lands, so nothing is lost.)
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
        nudges.backend = services.social
        remoteFeed.reactions = reactions
        remoteFeed.follows = follows
        // A feed refresh is the app's one reliable "there is a session now" moment, so it is what
        // delivers the taps and comments a guest made before signing up (see `CommentStore.pending`).
        remoteFeed.comments = comments
        // A block is also an unfollow, wherever it is tapped from (see `ModerationStore.follows`).
        moderation.follows = follows
        // Wrist sync (Watch Slice 4): the health handle must be wired before any watch message can
        // arrive, but activation itself rides the deferred block below.
        PhoneWatchSync.shared.health = services.health
        // …and the paywall, which is the only half of the wrist's voice-coach gate the watch can't
        // work out for itself (the Pro receipt lives on the phone).
        PhoneWatchSync.shared.paywall = services.paywall
        // BGTask handlers must register before launch completes — scheduling itself rides the
        // deferred block (`runDeferredLaunchWork`).
        MorningReadinessRefresh.register(health: services.health)
    }

    /// Everything the first frame does NOT need, run once shortly after it is on screen. Each of
    /// these used to run synchronously inside `init` — together they put the ads SDKs, Supabase,
    /// WCSession, ActivityKit and MetricKit on the cold-start critical path (perf audit 2026-08-13).
    /// None has a deadline measured in milliseconds; all are one-shots or start listeners.
    @State private var deferredLaunchWork = DeferredLaunchWork()
    private func runDeferredLaunchWork() async {
        await deferredLaunchWork.run([
            .init(phase: .tikTok) { TikTokAdsService.configure() },
            .init(phase: .meta) { MetaAdsService.configure() },
            .init(phase: .auth) { auth.refresh() },
            .init(phase: .metrics) { MetricsMonitor.shared.start(reporting: services.analytics) },
            .init(phase: .quarantine) {
                if let quarantine = PersistenceController.quarantineRecord, !quarantine.reported {
                    services.analytics.log(.storeQuarantined(recovered: quarantine.recovered))
                    SentryMonitor.capture(.storeQuarantined,
                                          tags: ["recovered": String(quarantine.recovered),
                                                 "error_code": quarantine.errorCode ?? "unknown"])
                    PersistenceController.markQuarantineReported()
                }
            },
            .init(phase: .planBackfill) { PersistenceController.shared.scheduleRunningPlanBackfill() },
            .init(phase: .watch) { PhoneWatchSync.shared.activate() },
            .init(phase: .cardioActivities) { CardioActivityController.endOrphans() },
            .init(phase: .restActivities) { RestActivityController.endOrphans() },
            .init(phase: .anatomy) { Task.detached(priority: .utility) { BodyAnatomy.warm() } },
            .init(phase: .readiness) { MorningReadinessRefresh.schedule() },
        ], observe: { phase, began in SentryMonitor.recordLaunchPhase(phase, began: began) })
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
            if let container = PersistenceController.shared.availableContainer {
                root.background {
                    // The white welcome needs dark system chrome. Resume the athlete's saved
                    // appearance as soon as they leave the entry gate; onboarding stays unchanged.
                    AppearanceApplicator(style: !auth.isSignedIn ? .light
                        : (AppAppearance(rawValue: appearanceRaw)?.interfaceStyle ?? .unspecified))
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                }
                .modelContainer(container)
            } else {
                StoreUnavailableView {
                    PersistenceController.shared.retry()
                }
            }
        }
    }

    private var root: some View {
        RootView()
            .environment(services)
            .environment(paywall)
            .environment(auth)
            .environment(coach)
            .environment(router)
            .environment(follows)
            .environment(nudges)
            .environment(reactions)
            .environment(comments)
            .environment(moderation)
            .environment(remoteFeed)
            // Screen + session tracking for every surface that carries `.trackScreen(_:)`. An
            // environment KEY (optional, defaulting to nil) rather than an `@Environment(Services.self)`
            // read inside the modifier: the modifier is applied on sheets and covers that don't
            // always inherit the container, and a missing container must mean "count nothing", not
            // a trap.
            .environment(\.screenTracker, services.screens)
            // The brand lavender as the app-wide tint (rebrand 2026-08-16, was Theme.ink) —
            // links, toggles, pickers, and the selected tab icon all say "alive" in one voice.
            .tint(Theme.purple)
            // Ceiling on Dynamic Type. This clamp dates to the SF Rounded era, when `.rounded()`
            // returned `.system(size:)` and text genuinely scaled. The 2026-06 move to bundled
            // faces switched both helpers to `Font.custom(_:size:)` — which is FROZEN at its point
            // size, `relativeTo:`-less — and scaling silently died app-wide, leaving this modifier
            // capping something that no longer moved. `Typography.swift` restored it 2026-08-21 by
            // passing `relativeTo:`, so the ceiling below is load-bearing again and means what it
            // says. (The old comment here claimed `Font.custom(_:size:)` scales relative to
            // `.body`. It does not; that belief is why the regression went unnoticed for two
            // months.)
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
                services.screens.sceneChanged(phase)
                if phase == .background {
                    // Close the session BEFORE the flush, so `session_end` — and the `last_screen`
                    // that says where this visit stopped — rides out in the same batch. Waiting for
                    // the next foreground to close it would lose exactly the sessions worth having:
                    // an athlete who churns here has no next foreground.
                    services.analytics.flush()
                }
            }
            // Cancel promptly when inactive; foregrounding resumes only unfinished stages.
            // The coordinator waits for first paint and yields between SDK bring-up calls.
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await runDeferredLaunchWork()
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

/// No workout entry is mounted until a durable store is ready.
private struct StoreUnavailableView: View {
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(Theme.inkSecondary)
            Text("Your data couldn’t be opened")
                .font(.display(28, weight: .semibold))
                .multilineTextAlignment(.center)
            Text("Your saved files have been kept for recovery. Try again after unlocking your iPhone or freeing up storage.")
                .font(.rounded(16))
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
            Button("Try again", action: retry)
                .font(.rounded(16, weight: .semibold))
                .foregroundStyle(Theme.background)
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .background(Theme.ink, in: Capsule())
                .accessibilityIdentifier("storage-retry")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .foregroundStyle(Theme.ink)
    }
}
