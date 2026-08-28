import SwiftUI
import SwiftData

/// The Community tab (docs/SOCIAL-LAYER.md, 2026-07-09) — the feed stream, returned as a first-class
/// destination. Deliberately a *Substack-for-runners*, not a Strava clone: strictly
/// reverse-chronological, follow-scoped or clearly-badged community, one earned "respect" reaction,
/// flat comments, and nothing algorithmic. The athlete's own shared workouts + the badged seeded
/// community render locally (the offline/dark experience); real athletes' posts pull in through
/// `RemoteFeedStore` when the Supabase backend is configured and the athlete is signed in.
struct CommunityView: View {
    @Query(sort: \Workout.startedAt, order: .reverse) private var workouts: [Workout]
    @Query private var profiles: [UserProfile]
    /// Saved-route count for the wall strip's library door (the door hides at zero).
    @Query private var savedRoutes: [SavedRoute]
    @Environment(FollowStore.self) private var follows
    @Environment(NudgeStore.self) private var nudges
    @Environment(ModerationStore.self) private var moderation
    @Environment(RemoteFeedStore.self) private var remoteFeed
    @Environment(PaywallController.self) private var paywall
    @Environment(Services.self) private var services
    @Environment(\.modelContext) private var modelContext
    /// Last `is_pro` value published to the backend — lets the entitlement-change hook below
    /// skip the initial appearance (launch's `claimProfile` already stamped it).
    @State private var lastPublishedPro: Bool?
    @AppStorage("community.feedScope") private var scopeRaw = CommunityScope.everyone.rawValue
    @State private var selectedAthlete: CommunityAthlete?
    /// "+N" on the following row pushes the full list. Its own destination TYPE: ProfileScreen
    /// already declares a `FollowingListView` destination on this stack, and SwiftUI ignores a
    /// second declaration for the same type further down.
    private struct FollowingPush: Identifiable, Hashable { let id = 0 }
    @State private var showingFollowing: FollowingPush?
    /// "Your day" with nothing shared today → share the latest workout (Aura's "select activity
    /// to share: Today"). The composer is the story composer.
    @State private var sharingToday: Workout?
    /// Fresh community posts minted by pull-to-refresh (CommunityPulse) — session-scoped.
    @State private var pulsed: [FeedItem] = []
    /// The in-place athlete-search face. Owned by the HOST (ProfileScreen's header magnifier
    /// toggles it) so chrome and content share one state; the empty state's "Find athletes"
    /// writes the same binding.
    @Binding private var searching: Bool
    /// A tapped tile → the community pager opens on it (Identifiable for `.fullScreenCover(item:)`).
    private struct PagerStart: Identifiable { let id: UUID }
    @State private var immersive: PagerStart?
    /// A ring tap: that person's day (posts in the last 24h, else their latest) in the pager.
    private struct StoryStart: Identifiable { let id: String; let items: [FeedItem] }
    @State private var story: StoryStart?
    /// Instagram-style progressive reveal (owner ask 2026-07-29): the wall renders a WINDOW of
    /// the assembled feed and grows it a page at a time when you reach the bottom — thousands of
    /// posts without ever materializing thousands of tiles.
    @State private var visibleCount = 30
    /// One load = 12 posts — four rows of the 3-wide grid, the Instagram page (owner call
    /// 2026-07-30: "loads another twelve… just continuous"). Small pages keep each reveal
    /// imperceptible; the near-end prefetch below keeps them coming before the bottom is reached.
    private static let windowStep = 12
    /// How deep the Global well reaches into the assembled feed. Starts at one page's worth of
    /// scrolling and DEEPENS by `wellStep` whenever the reveal window catches up to it (owner ask
    /// 2026-07-30: the wall must never dead-end — reaching the bottom loads more, like pull-to-
    /// refresh in reverse). The cap exists so a cold open never sorts/filters thousands of rows it
    /// may never show; growth is demand-driven.
    @State private var wellCap = 400
    private static let wellStep = 400
    #if DEBUG
    /// --saved-routes: push the library directly (sim verification; the strip link needs a tap).
    @State private var debugSavedRoutes = false
    #endif
    /// Grid tile → pager zoom (the same Instagram open the profile grid ships).
    @Namespace private var tileZoom

    private var profile: UserProfile? { profiles.first }
    private var scope: CommunityScope { CommunityScope(rawValue: scopeRaw) ?? .everyone }

    // Hosted inside ProfileScreen behind the Profile ↔ Community slider (2026-07-29). The host's
    // header carries all identity chrome (slider, magnifier, gear), so this view is pure content:
    // the grid wall, the floating scope pill, and the pager. (The old `embedded` flag was stored
    // but never read — deleted 2026-07-30.)

    /// Once-per-process gate for the init-time debug writes below. A view INIT re-runs on every
    /// parent re-evaluation, and a UserDefaults write there fires KVO even when the value is
    /// unchanged — every `@AppStorage("community.feedScope")` reader invalidates, the tree
    /// re-evaluates, the parent re-inits this view, and the write fires again: a self-sustaining
    /// invalidation storm that saturated the main thread from launch (App body ~345 evals/sec,
    /// diagnosed 2026-07-29 via `_printChanges`; it presented as the "blank wall / frozen
    /// entrance / generic tab icon" launches). View inits must stay PURE — one-shot side effects
    /// only, and only behind this flag.
    @MainActor private static var didApplyLaunchArgs = false
    /// One-shot for the DEBUG athlete-profile hooks — see the `onAppear` note: this view's
    /// `onAppear` re-fires on every pop, so an unguarded hook re-pushes forever.
    @MainActor private static var didOpenDebugAthlete = false

    init(searching: Binding<Bool> = .constant(false)) {
        self._searching = searching
        _items = State(initialValue: Self.sessionFeed)
        _assembledOnce = State(initialValue: !Self.sessionFeed.isEmpty)
        if !Self.didApplyLaunchArgs {
            Self.didApplyLaunchArgs = true
            // `--reset-social` starts UI tests from the default scope, like the social stores.
            SocialDebug.resetIfRequested(.standard, keys: ["community.feedScope"])
            #if DEBUG
            // --feed-global / --feed-friends: force a scope for sim verification — the scope is
            // @AppStorage (sticky across launches), and outside writes race cfprefsd; a ONE-SHOT
            // in-process write is the form that lands without looping (see didApplyLaunchArgs).
            if ProcessInfo.processInfo.arguments.contains("--feed-global") {
                UserDefaults.standard.set(CommunityScope.everyone.rawValue, forKey: "community.feedScope")
            }
            if ProcessInfo.processInfo.arguments.contains("--feed-friends") {
                UserDefaults.standard.set(CommunityScope.following.rawValue, forKey: "community.feedScope")
            }
            #endif
        }
    }

    /// Own workouts feeding the assembler — bounded so photo/route blobs of a long history never all
    /// materialize for one screen (older shared posts still live in Profile).
    private static let ownWorkoutCap = 50

    /// The assembled page, held in state. Assembly (map 50 workouts incl. photo blobs + merge/sort
    /// ~950 community items) is far too heavy to run per body evaluation — profiling showed the
    /// main thread saturated with `FeedItem` copies, which also starved accessibility (XCUITest
    /// timeouts). Rebuilt via `.task(id: feedKey)` only when an actual input changes.
    ///
    /// Seeded from the SESSION CACHE below: the slider tears this view down on every face switch,
    /// and re-assembling from empty made each return to Community open on a blank beat before the
    /// wall popped in ("feels glitchy" — owner report 2026-07-29). Stale-while-revalidate: last
    /// session's wall renders on the first frame, the task refreshes it in place.
    @State private var items: [FeedItem]
    @State private var assembledOnce: Bool
    /// The feedKey the assembly task last ran for — lets `onAppear` tell a genuine revisit apart
    /// from the first pass of a fresh instance (where assembling again would double the work).
    @State private var lastAssembledKey = ""
    @MainActor private static var sessionFeed: [FeedItem] = []

    /// Cheap change signature over every feed input; a change re-runs the assembly task.
    /// `publicRouteMaps` is a term because own-post route visibility is decided AT assembly
    /// (`FeedAssembler` bakes `routeCoordinates` into the item): a feed assembled before the
    /// profile materialized — or before the routes-on migration ran — cached glyph posts that no
    /// count change would ever refresh.
    private var feedKey: String {
        "\(scopeRaw)|\(workouts.count)|\(pulsed.count)|\(remoteFeed.items.count)|" +
        "\(follows.following.count)|\(moderation.blockedHandles.count)|\(moderation.reportedPosts.count)|" +
        "\(profile?.handle ?? "")|\(wellCap)|\(profile?.publicRouteMaps == true)"
    }

    /// Assembled once per relevant change (the community seed is ~950 athletes' posts — never filter
    /// per row). Moderation runs on the full stream so blocked athletes vanish from both scopes.
    /// Remote posts (real athletes, fetched per-scope so the *server's* follow graph gates them)
    /// merge on top; the local pipeline — including `FeedAssembler.scoped` — is unchanged.
    private func assembleFeed() -> [FeedItem] {
        let shared = workouts.lazy.filter { SocialPrivacy.isShared($0) }.prefix(Self.ownWorkoutCap)
        // Pulse posts (minted on pull-to-refresh) merge in ahead of the seed and re-sort — they're
        // minutes old, so they surface at the top exactly like a post that just landed.
        // The page caps at the ~150 most recent: the seed is 950 athletes deep, and handing SwiftUI
        // a thousand-row LazyVStack bloats memory and grinds accessibility for a tail nobody
        // scrolls to. Follows are exempt from the cap (scoped from the FULL stream) so a followed
        // athlete's post never disappears behind it.
        // `FeedAssembler.feed` already returns date-sorted rows — the re-sort (a second full pass
        // over ~2,900 fat structs) is only needed when pulse posts actually merged in.
        let base = FeedAssembler.feed(userWorkouts: Array(shared), profile: profile,
                                      community: CommunityFeed.seed(),
                                      viewerIsPro: paywall.isEntitled(to: .fullPlan))
        let assembled = (pulsed.isEmpty ? base : (pulsed + base).sorted { $0.date > $1.date })
            .filter(moderation.isVisible)
        let local = scope == .following
            ? FeedAssembler.scoped(assembled, following: follows.following)
            : Array(assembled.prefix(wellCap))   // demand-deepened well; the WINDOW reveals it 30 at a time
        // Own published posts come back in the remote feed too — the local copy wins (it has the
        // full-resolution photos and needs no signing round trip).
        let localIDs = Set(local.map(\.id))
        let remote = remoteFeed.items.filter { !localIDs.contains($0.id) }.filter(moderation.isVisible)
        let merged = remote.isEmpty ? local : (local + remote).sorted { $0.date > $1.date }
        return Self.mediaFirst(merged)
    }

    /// The wall's first impression is media (2026-08-25 realism pass): a post with no route, no
    /// muscle map and no photo renders as a sport glyph on a wash, and two of those in the top
    /// row read as placeholder art. Date order is kept; glyph-only posts just can't occupy the
    /// first two rows while a media post exists to take the slot.
    static func mediaFirst(_ items: [FeedItem]) -> [FeedItem] {
        let lead = 6
        guard items.count > lead else { return items }
        func hasMedia(_ i: FeedItem) -> Bool {
            (i.routeLatLon?.count ?? 0) > 1 || (i.muscles?.values.contains { $0 > 0 } ?? false) || !i.photosData.isEmpty
        }
        var head: [FeedItem] = [], deferred: [FeedItem] = [], rest: [FeedItem] = []
        for item in items {
            if head.count < lead {
                if hasMedia(item) { head.append(item) } else { deferred.append(item) }
            } else {
                rest.append(item)
            }
        }
        // Not enough media posts to fill the lead? Let the deferred ones back in, in order.
        while head.count < lead, !deferred.isEmpty { head.append(deferred.removeFirst()) }
        return head + deferred + rest
    }

    var body: some View {
        Group {
            if searching {
                // In-place search (owner ask 2026-07-29): the header magnifier opens a search bar
                // where the wall was — no sheet hop — and Cancel returns to the grid.
                FindAthletesView(onOpen: { handle in
                    withAnimation(.easeOut(duration: 0.2)) { searching = false }
                    openAthlete(handle)
                }, embedded: true, onCancel: {
                    withAnimation(.easeOut(duration: 0.2)) { searching = false }
                })
                .transition(.opacity)
            } else {
                gridFace
                    .transition(.opacity)
            }
        }
        .background(Theme.background)
        .navigationBarHidden(true)
        .navigationDestination(item: $selectedAthlete) { AthleteProfileView(athlete: $0) }
        .navigationDestination(item: $showingFollowing) { _ in FollowingListView() }
        .sheet(item: $sharingToday) { w in
            ShareCardView(workout: w, weightUnit: WeightUnit(rawValue: profile?.weightUnit ?? "kg") ?? .kg,
                          distanceUnit: DistanceUnit(rawValue: profile?.distanceUnit ?? "auto") ?? .auto)
        }
        #if DEBUG
        .navigationDestination(isPresented: $debugSavedRoutes) { SavedRoutesView() }
        #endif
        // The TikTok moment: a tile zooms into the full-bleed vertical pager. Byline taps push
        // the athlete's profile INSIDE the pager's own NavigationStack — over the post, back
        // swipes home (the old dismiss-pause-push read as a glitch, owner report 2026-07-29).
        .fullScreenCover(item: $immersive) { start in
            // Sliced FROM the tapped post: page one is the post you tapped BY CONSTRUCTION, and
            // swiping continues deeper down the feed (TikTok's grid-open). The old whole-array +
            // scrollTo broke silently once the well hit 400 — the lazy stack couldn't jump, so
            // every tile opened page one ("everyone is Bianca", owner report 2026-07-29).
            CommunityPager(items: pagerSlice(from: start.id), startID: start.id,
                           ownHandle: profile?.handle)
                .navigationTransition(.zoom(sourceID: start.id, in: tileZoom))
        }
        .fullScreenCover(item: $story) { start in
            if let first = start.items.first {
                CommunityPager(items: start.items, startID: first.id, ownHandle: profile?.handle)
            }
        }
        .task(id: feedKey) {
            // Assemble off the render path — runs on appear and whenever an input signature moves.
            items = assembleFeed()
            assembledOnce = true
            lastAssembledKey = feedKey
            Self.sessionFeed = items
        }
        // Tab revisits rebuild too: a share-visibility toggle elsewhere changes no count in
        // `feedKey`, but the athlete expects the feed to reflect it when they come back. Only on
        // a REAL revisit though — on a fresh instance (every slider flip creates one) the task
        // above hasn't stamped the key yet, and running here too assembled the whole feed TWICE
        // back to back (2026-07-30 perf audit).
        .onAppear {
            guard assembledOnce, lastAssembledKey == feedKey else { return }
            items = assembleFeed()
            Self.sessionFeed = items
        }
        .task {
            // Who follows back + any nudges that landed while the app was away (throttled).
            await nudges.refresh(in: modelContext)
        }
        .task(id: scopeRaw) {
            // Refetch whenever the scope changes — Following and Everyone are different server
            // queries, so an emptiness guard would leave the previous scope's rows in place and
            // leak un-followed athletes into Following. `refresh` guards !isLoading and swaps
            // items per scope; it's a no-op offline/guest/dark.
            await remoteFeed.refresh(scope: remoteScope)
        }
        .task(id: paywall.isEntitled(to: .fullPlan)) {
            // Entitlement flipped mid-session (purchase, restore, reinstall's async restore):
            // re-publish the profile so the server-side `is_pro` — the checkmark every OTHER
            // athlete sees — updates now, not at the next launch's claimProfile.
            let pro = paywall.isEntitled(to: .fullPlan)
            if let last = lastPublishedPro, last != pro, let profile {
                await services.social.claimProfile(profile, in: modelContext)
            }
            lastPublishedPro = pro
        }
        #if DEBUG
        // --athlete-profile: open the first community athlete directly (deterministic sim
        // verification of the visited-profile design; feed taps are flaky in UI tests).
        // --find-athletes / --open-first-post: same idea for the search sheet and the full-page
        // post detail.
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            // ONE-SHOT (both athlete hooks). This `onAppear` re-fires whenever the pushed profile is
            // popped — and `selectedAthlete` is nil again by then — so without the flag, navigating
            // BACK instantly re-pushed the same athlete. That made the wall look stuck and any test
            // that leaves the profile impossible to write (found 2026-07-30 by the follow-flow test).
            if !Self.didOpenDebugAthlete {
                if let i = args.firstIndex(of: "--athlete-profile") {
                    // Optional trailing handle ("--athlete-profile joonw973") opens that exact member —
                    // generated athletes included — so per-handle traits (e.g. the Pro-seal draw) are
                    // verifiable deterministically. Bare flag keeps opening the first directory athlete.
                    let handle = args.indices.contains(i + 1) && !args[i + 1].hasPrefix("--") ? args[i + 1] : nil
                    Self.didOpenDebugAthlete = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        selectedAthlete = handle.flatMap { CommunityDirectory.athlete(handle: $0) }
                            ?? CommunityDirectory.all().first
                    }
                }
                // --athlete-profile-stale: the first directory athlete with NO post in the last
                // 24h, followed on open — the Nudge pill's only legal state, screenshot-verifiable.
                if args.contains("--athlete-profile-stale") {
                    Self.didOpenDebugAthlete = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        let stale = CommunityDirectory.all().first {
                            ($0.posts.map(\.date).max()).map { Date().timeIntervalSince($0) > 86_400 } ?? true
                        }
                        if let stale, !follows.isFollowing(stale.handle) { follows.toggle(stale.handle) }
                        selectedAthlete = stale
                    }
                }
                // --athlete-profile-strength: first GENERATED strength-primary athlete — verifies the
                // non-runner profile coherence (sport-led grid, workouts-logged hero, no distance claim).
                if args.contains("--athlete-profile-strength") {
                    Self.didOpenDebugAthlete = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        selectedAthlete = CommunityDirectory.all().dropFirst(8)
                            .first { $0.posts.first?.type.isStrengthStyle == true }
                    }
                }
            }
            // --open-ring: tap the first ringed face on the Following row (their day in the
            // pager); --open-your-day: the "Your day" face; --open-following-more: the "+N" face.
            // Taps on the row are unreliable in the sim; these drive the same handlers.
            if args.contains("--open-ring") || args.contains("--open-your-day") || args.contains("--open-following-more") {
                Task { @MainActor in
                    for _ in 0..<30 {
                        if !items.isEmpty {
                            try? await Task.sleep(for: .milliseconds(800))
                            if args.contains("--open-your-day") {
                                let mine = items.filter { $0.authorHandle == ownHandle && !ownHandle.isEmpty }
                                if !mine.isEmpty { story = StoryStart(id: "you", items: Array(mine.prefix(5))) }
                                else if let latest = workouts.first { sharingToday = latest }
                            } else if args.contains("--open-following-more") {
                                showingFollowing = FollowingPush()
                            } else if let person = followedPeople.first(where: \.ringed) {
                                let posts = day(of: person.handle)
                                if !posts.isEmpty { story = StoryStart(id: person.handle, items: posts) }
                            }
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                }
            }
            // --community-friends: land on the Friends scope (the empty-follows state is the one
            // the header used to vanish on).
            if args.contains("--community-friends") { scopeRaw = CommunityScope.following.rawValue }
            if args.contains("--find-athletes") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { searching = true }
            }
            // --seed-saved-route: bookmark the first routed post so the strip's Saved door and
            // the library render for sim verification (taps can't drive the pager reliably).
            // --saved-routes additionally pushes the library itself.
            if args.contains("--seed-saved-route") || args.contains("--saved-routes") {
                Task { @MainActor in
                    for _ in 0..<20 {
                        if let post = items.first(where: { $0.routeLatLon != nil }) {
                            if savedRoutes.isEmpty {
                                modelContext.insert(SavedRoute(
                                    postID: post.id, title: post.title, authorName: post.authorName,
                                    authorHandle: post.authorHandle, city: post.location,
                                    km: 8.8, pts: post.routeLatLon ?? [], mapStyle: post.mapStyle))
                                try? modelContext.save()
                            }
                            if args.contains("--saved-routes") {
                                try? await Task.sleep(for: .milliseconds(400))
                                debugSavedRoutes = true
                            }
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                }
            }
            // --open-post <index>: open the pager on a SPECIFIC tile — verifies the tapped tile
            // and page one always agree (taps are unreliable in the sim).
            if let i = args.firstIndex(of: "--open-post"), args.indices.contains(i + 1),
               let index = Int(args[i + 1]) {
                Task { @MainActor in
                    for _ in 0..<30 {
                        if items.indices.contains(index) {
                            visibleCount = max(visibleCount, min(index + Self.windowStep, items.count))
                            try? await Task.sleep(for: .milliseconds(600))
                            immersive = PagerStart(id: items[index].id)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                }
            }
            // --open-first-post-dark: first DARK-basemap post — the scrim-over-dark-map case.
            if args.contains("--open-first-post-dark") {
                Task { @MainActor in
                    for _ in 0..<30 {
                        if let dark = items.first(where: { $0.mapStyle == .dark && $0.routeLatLon != nil }) {
                            try? await Task.sleep(for: .milliseconds(600))
                            immersive = PagerStart(id: dark.id)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                }
            }
            if args.contains("--open-first-post") {
                // Waits for assembly rather than firing at a fixed delay — a cold seed build can
                // outlast any guess, and a missed one-shot reads as "the pager is broken". The
                // extra settle beat lets the grid lay out and register the zoom SOURCE first:
                // presenting a `.zoom` cover whose matchedTransitionSource doesn't exist yet
                // leaves the cover stuck semi-transparent (a real tap can never race this).
                Task { @MainActor in
                    for _ in 0..<30 {
                        if let first = items.first {
                            try? await Task.sleep(for: .milliseconds(600))
                            immersive = PagerStart(id: first.id)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                }
            }
        }
        #endif
    }

    /// The wall: header → Friends | Global text tabs → tiles, one structured column (the stacked
    /// floating-pill arrangement read as chrome piled on chrome — owner call 2026-07-29). The tabs
    /// strip is a safe-area inset with its own hairline, and the grid starts one gutter below it —
    /// the profile grid's exact relationship to its Grid/Highlights bar.
    private var gridFace: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // The page header ALWAYS renders (2026-08-25): find people → the faces you follow,
                // ringed when they trained today → Explore. It used to live inside the non-empty
                // branch, so opening Friends with nobody followed took the search field, the ring
                // row and the scope tabs off screen with the wall — the one state where finding
                // people matters most had no way to find people, and the header jumped.
                followingRow
                    .padding(.top, Theme.Space.md)
                HStack {
                    Text("Explore")
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                    Spacer()
                    savedRoutesDoor
                }
                .padding(.horizontal, Theme.Space.md)
                .padding(.top, Theme.Space.lg)
                CommunityScopeTabs(scopeRaw: $scopeRaw)

                if items.isEmpty {
                    // No flash of the empty state during the very first assembly pass.
                    if assembledOnce {
                        emptyState
                            .padding(.top, Theme.Space.xl)
                            .padding(.horizontal, Theme.Space.md)
                    }
                } else {
                    CommunityFeedGrid(items: Array(items.prefix(visibleCount)),
                                      zoomNamespace: tileZoom,
                                      onTileAppear: { index in
                                          // The Instagram trick: the next page is requested when a
                                          // tile TWO ROWS from the end scrolls in, not when the
                                          // bottom is hit — by the time the athlete gets there, the
                                          // next 12 already exist and the scroll never stalls.
                                          if index >= visibleCount - 6 { loadNextPage() }
                                      }) { id in
                        immersive = PagerStart(id: id)
                    }
                    // Reaching the bottom loads more, always (owner ask 2026-07-30 — the mirror of
                    // pull-to-refresh): grow the local window a page (the Instagram reveal), DEEPEN
                    // the well itself once the window catches up to its cap (the assembled feed is
                    // thousands of posts deep — the wall must never dead-end), and pull the next
                    // REMOTE page as the well runs low (cursor-driven; `loadMore` guards
                    // scope/cursor/in-flight, and a dark backend no-ops).
                    //
                    // The spinner below is honest, not theater: the instant local reveal still
                    // lands the same frame (no artificial delay), and the spinner marks the beats
                    // that ARE async — the well re-assembly and the remote fetch. It hides only at
                    // the feed's true end, which is the one place scrolling should quietly stop.
                    bottomLoader
                        .onAppear { loadNextPage() }   // backstop for a scroll that outruns prefetch
                        .padding(.bottom, Theme.Space.xxl)
                }
            }
            #if DEBUG
            // --wall-scroll <index>: jump the wall to a tile index for sim verification — content
            // audits need to SEE deep rows, and simctl can't scroll.
            .onAppear {
                let args = ProcessInfo.processInfo.arguments
                if let i = args.firstIndex(of: "--wall-scroll"), args.indices.contains(i + 1),
                   let index = Int(args[i + 1]) {
                    // Waits for assembly (the --open-first-post lesson): a one-shot delay races
                    // the cold seed build and silently no-ops. Grows the reveal window first —
                    // a tile outside it doesn't exist to scroll to.
                    Task { @MainActor in
                        for _ in 0..<20 {
                            if !items.isEmpty {
                                visibleCount = max(visibleCount, min(index + Self.windowStep, items.count))
                                try? await Task.sleep(for: .milliseconds(500))
                                let target = items.indices.contains(index) ? items[index] : items[items.count - 1]
                                withAnimation { proxy.scrollTo(target.id, anchor: .top) }
                                return
                            }
                            try? await Task.sleep(for: .milliseconds(300))
                        }
                    }
                }
            }
            #endif
        }
        .refreshable {
            pulsed = CommunityPulse.refreshed(pulsed)
            await remoteFeed.refresh(scope: remoteScope)
        }
    }

    /// One page of continuous scroll: reveal the next 12 tiles (instant — a state flip over
    /// already-assembled items), and keep the slower feeders primed WELL ahead of the reveal —
    /// the well deepens and the next remote page fetches while there are still ~4 pages in hand,
    /// so their async cost lands behind rows the athlete hasn't reached yet. Idempotent per state:
    /// a burst of near-end tile appearances in one frame advances at most one page, because the
    /// first advance moves the threshold the rest are compared against.
    private func loadNextPage() {
        if visibleCount < items.count {
            visibleCount = min(visibleCount + Self.windowStep, items.count)
        }
        let remaining = items.count - visibleCount
        // (`items.count >= wellCap` proves the assembled feed still had more; once assembly
        // returns fewer than the cap, the seed is exhausted and the cap stops growing.)
        if scope == .everyone, items.count >= wellCap, remaining <= Self.windowStep * 4 {
            wellCap += Self.wellStep
        }
        if remaining <= Self.windowStep * 4 {
            Task { await remoteFeed.loadMore(scope: remoteScope) }
        }
    }

    /// True while scrolling further down can still produce content: window not fully revealed,
    /// the well still at its cap (deeper posts exist), or a remote page in flight.
    private var hasMoreBelow: Bool {
        visibleCount < items.count
            || (scope == .everyone && items.count >= wellCap)
            || remoteFeed.isLoading
    }

    /// The bottom-of-wall beat: a small quiet spinner while there's more to come, nothing at the
    /// true end. Doubles as the on-appear sentinel that drives the window/well/remote growth.
    @ViewBuilder
    private var bottomLoader: some View {
        if hasMoreBelow {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.inkTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.lg)
                .accessibilityLabel("Loading more")
        } else {
            Color.clear.frame(height: 1)
        }
    }

    /// The saved-route library's door, tucked into the scope-tabs strip's trailing edge. This used
    /// to live in a "pulse strip" between the tabs and the wall ("2,863 athletes · 217 moving
    /// now") — the owner cut that line entirely (2026-07-30) so the grid runs full-bleed from the
    /// tabs down; the bookmark is the only part that had a job, and it kept it.
    @ViewBuilder
    private var savedRoutesDoor: some View {
        if !savedRoutes.isEmpty {
            NavigationLink { SavedRoutesView() } label: {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(savedRoutes.count) saved routes")
        }
    }

    /// The feed from the tapped post onward — from the FULL well, not the reveal window, so the
    /// pager keeps going past what the wall had rendered.
    // MARK: Following row

    private var ownHandle: String { profile?.handle ?? "" }

    /// Trained in the last 24h — your own ring, the same rule the profile hero uses.
    private var youTrainedToday: Bool {
        guard let w = workouts.first else { return false }
        return Date().timeIntervalSince(w.startedAt.addingTimeInterval(w.durationS)) < 86_400
    }

    /// A followed athlete's posts through the 24h window; falls back to their newest post so a
    /// tap always shows *something* of theirs rather than a dead ring.
    private func day(of handle: String) -> [FeedItem] {
        let theirs = items.filter { $0.authorHandle == handle }
        let pool = theirs.isEmpty ? (CommunityDirectory.athlete(handle: handle)?.posts ?? []) : theirs
        let recent = pool.filter { Date().timeIntervalSince($0.date) < 86_400 }
        let chosen = recent.isEmpty ? Array(pool.prefix(1)) : recent
        return chosen.sorted { $0.date > $1.date }
    }

    private var followedPeople: [FollowingRow.Person] {
        follows.following.filter { $0 != ownHandle }.map { handle in
            let athlete = CommunityDirectory.athlete(handle: handle)
            let latest = items.lazy.filter { $0.authorHandle == handle }.map(\.date).max()
                ?? athlete?.posts.map(\.date).max()
            let ringed = latest.map { Date().timeIntervalSince($0) < 86_400 } ?? false
            let label = athlete?.name.split(separator: " ").first.map(String.init) ?? handle
            return FollowingRow.Person(handle: handle, label: label, ringed: ringed, lastActive: latest,
                                       avatarData: athlete?.avatarData,
                                       imageName: athlete?.communityAvatarAsset,
                                       preset: athlete?.communityPreset)
        }
    }

    private var followingRow: some View {
        FollowingRow(
            you: .init(handle: ownHandle, label: "Your day", ringed: youTrainedToday,
                       avatarData: profile?.avatarData),
            people: followedPeople,
            onFind: { withAnimation(.easeOut(duration: 0.2)) { searching = true } },
            onYou: {
                // Your day: your newest shared post, in the same pager everyone else's opens in.
                let mine = items.filter { $0.authorHandle == ownHandle && !ownHandle.isEmpty }
                if !mine.isEmpty { story = StoryStart(id: "you", items: Array(mine.prefix(5))) }
                else if let latest = workouts.first { sharingToday = latest }
            },
            onPerson: { person in
                let posts = day(of: person.handle)
                if !posts.isEmpty { story = StoryStart(id: person.handle, items: posts) }
                else { openAthlete(person.handle) }
            },
            onMore: { showingFollowing = FollowingPush() })
    }

    private func pagerSlice(from id: UUID) -> [FeedItem] {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return items }
        return Array(items[index...])
    }

    private var remoteScope: FeedScope { scope == .following ? .following : .everyone }

    /// Community (seeded) athletes resolve locally; real athletes fetch their page from the
    /// backend. Nothing happens on a miss (offline/dark) — the feed card is still fully readable.
    private func openAthlete(_ handle: String) {
        if let seeded = CommunityDirectory.athlete(handle: handle) {
            selectedAthlete = seeded
            return
        }
        Task {
            if let remote = await remoteFeed.athlete(handle: handle) {
                selectedAthlete = remote
            }
        }
    }

    // MARK: Empty state (Following with no follows yet — no-shame, one obvious next step)

    private var emptyState: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: "person.2")
                .font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            Text("Your people will show up here")
                .font(.display(20, weight: .bold)).foregroundStyle(Theme.ink)
            Text("Follow athletes you care about, or share your next workout. It lands here too.")
                .font(.rounded(Theme.FontSize.body, weight: .regular)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
            Button {
                withAnimation(.easeOut(duration: 0.2)) { searching = true }
            } label: {
                Text("Find athletes")
                    .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.background)
                    .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.sm + 2)
                    .raised(Capsule(), tone: .ink)
            }
            .buttonStyle(RaisedPressStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.xl)
    }
}

/// Which slice of the feed is shown. Persisted — the tab reopens where the athlete left it.
enum CommunityScope: String, CaseIterable {
    case following, everyone
    var label: String {
        switch self {
        case .following: "Friends"   // relabeled from "Following" with the grid redesign (2026-07-29)
        case .everyone: "Global"     // rawValue stays "everyone" (persisted); label is the Substack-style "Global"
        }
    }
}

#Preview {
    NavigationStack { CommunityView() }
        .environment(FollowStore())
        .environment(ReactionStore())
        .environment(CommentStore())
        .environment(ModerationStore())
        .environment(RemoteFeedStore())
        .environment(PaywallController())
}
