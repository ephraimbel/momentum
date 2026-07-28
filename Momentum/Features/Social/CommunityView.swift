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
    @Environment(FollowStore.self) private var follows
    @Environment(ModerationStore.self) private var moderation
    @Environment(RemoteFeedStore.self) private var remoteFeed
    @Environment(PaywallController.self) private var paywall
    @Environment(Services.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    /// Last `is_pro` value published to the backend — lets the entitlement-change hook below
    /// skip the initial appearance (launch's `claimProfile` already stamped it).
    @State private var lastPublishedPro: Bool?
    @AppStorage("community.feedScope") private var scopeRaw = CommunityScope.everyone.rawValue
    @State private var selectedAthlete: CommunityAthlete?
    /// Fresh community posts minted by pull-to-refresh (CommunityPulse) — session-scoped.
    @State private var pulsed: [FeedItem] = []
    @State private var showingSearch = false
    /// The masthead avatar → the athlete's own FULL profile page (pushed, back chevron).
    @State private var showOwnProfile = false
    #if DEBUG
    @State private var debugDetailPost: FeedItem?
    #endif

    private var profile: UserProfile? { profiles.first }
    private var scope: CommunityScope { CommunityScope(rawValue: scopeRaw) ?? .everyone }

    init() {
        // `--reset-social` starts UI tests from the default scope, like the social stores.
        SocialDebug.resetIfRequested(.standard, keys: ["community.feedScope"])
    }

    /// Own workouts feeding the assembler — bounded so photo/route blobs of a long history never all
    /// materialize for one screen (older shared posts still live in Profile).
    private static let ownWorkoutCap = 50

    /// The assembled page, held in state. Assembly (map 50 workouts incl. photo blobs + merge/sort
    /// ~950 community items) is far too heavy to run per body evaluation — profiling showed the
    /// main thread saturated with `FeedItem` copies, which also starved accessibility (XCUITest
    /// timeouts). Rebuilt via `.task(id: feedKey)` only when an actual input changes.
    @State private var items: [FeedItem] = []
    @State private var assembledOnce = false

    /// Cheap change signature over every feed input; a change re-runs the assembly task.
    private var feedKey: String {
        "\(scopeRaw)|\(workouts.count)|\(pulsed.count)|\(remoteFeed.items.count)|" +
        "\(follows.following.count)|\(moderation.blockedHandles.count)|\(moderation.reportedPosts.count)|" +
        "\(profile?.handle ?? "")"
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
        let assembled = (pulsed + FeedAssembler.feed(userWorkouts: Array(shared), profile: profile,
                                                     community: CommunityFeed.seed(),
                                                     viewerIsPro: paywall.isEntitled(to: .fullPlan)))
            .sorted { $0.date > $1.date }
            .filter(moderation.isVisible)
        let local = scope == .following
            ? FeedAssembler.scoped(assembled, following: follows.following)
            : Array(assembled.prefix(60))
        // Own published posts come back in the remote feed too — the local copy wins (it has the
        // full-resolution photos and needs no signing round trip).
        let localIDs = Set(local.map(\.id))
        let remote = remoteFeed.items.filter { !localIDs.contains($0.id) }.filter(moderation.isVisible)
        guard !remote.isEmpty else { return local }
        return (local + remote).sorted { $0.date > $1.date }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if items.isEmpty {
                    // No flash of the empty state during the very first assembly pass.
                    if assembledOnce {
                        emptyState
                            .padding(.top, Theme.Space.xxl)
                            .padding(.horizontal, Theme.Space.md)
                    }
                } else {
                    ForEach(items) { item in
                        // Own posts keep an inert byline (no self-profile push from the feed).
                        FeedPostCard(item: item, onOpenAuthor: item.authorHandle == profile?.handle
                            ? nil
                            : { handle in openAthlete(handle) })
                    }
                }
            }
            // No horizontal inset here any more: the card's media is full-bleed, so each card
            // supplies the page margin to its own TEXT blocks instead (media-first redesign).
            .padding(.top, Theme.Space.md)     // breathing room under the masthead — a more spacious feel
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationBarHidden(true)
        .safeAreaInset(edge: .top) { header }
        .navigationDestination(item: $selectedAthlete) { AthleteProfileView(athlete: $0) }
        .navigationDestination(isPresented: $showOwnProfile) { ProfileScreen(showsBackButton: true) }
        .sheet(isPresented: $showingSearch) {
            FindAthletesView { handle in
                showingSearch = false
                // Let the sheet finish dismissing before the navigation push lands.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { openAthlete(handle) }
            }
        }
        .refreshable {
            pulsed = CommunityPulse.refreshed(pulsed)
            await remoteFeed.refresh(scope: remoteScope)
        }
        .task(id: feedKey) {
            // Assemble off the render path — runs on appear and whenever an input signature moves.
            items = assembleFeed()
            assembledOnce = true
        }
        // Tab revisits rebuild too: a share-visibility toggle elsewhere changes no count in
        // `feedKey`, but the athlete expects the feed to reflect it when they come back.
        .onAppear {
            guard assembledOnce else { return }   // first pass belongs to the task above
            items = assembleFeed()
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
            if args.contains("--athlete-profile"), selectedAthlete == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    selectedAthlete = CommunityDirectory.all().first
                }
            }
            // --athlete-profile-strength: first GENERATED strength-primary athlete — verifies the
            // non-runner profile coherence (sport-led grid, workouts-logged hero, no distance claim).
            if args.contains("--athlete-profile-strength"), selectedAthlete == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    selectedAthlete = CommunityDirectory.all().dropFirst(8)
                        .first { $0.posts.first?.type.isStrengthStyle == true }
                }
            }
            if args.contains("--find-athletes") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showingSearch = true }
            }
            if args.contains("--open-first-post") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { debugDetailPost = items.first }
            }
        }
        .fullScreenCover(item: $debugDetailPost) { post in NavigationStack { PostDetailView(item: post) } }
        #endif
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

    // MARK: Header (custom — matches Profile/Progress)

    private var header: some View {
        VStack(spacing: 0) {
            // Centered brand wordmark — the monochrome "momentum" logo, swapping black/white with the
            // appearance so it reads on either canvas (Substack-style masthead, decision 2026-07-15).
            // The athlete's own avatar sits top-left (Substack's pattern mirrored) and opens the FULL
            // profile page, pushed with a back chevron — never a sheet (user call 2026-07-16).
            Image(colorScheme == .dark ? "WordmarkWhite" : "WordmarkBlack")
                .resizable().scaledToFit()
                .frame(height: 17)   // quiet masthead scale (Substack-like) — 30 read as a billboard
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Space.sm)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel("Momentum")
                .overlay(alignment: .leading) {
                    Button { showOwnProfile = true } label: {
                        AvatarView(photo: profile?.avatarData, name: profile?.displayName ?? "", size: 34)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, Theme.Space.md)
                    .accessibilityLabel("Your profile")
                }
            // A real search field (opens athlete search) — the masthead's second row.
            Button { showingSearch = true } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    Text("Search athletes")
                        .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Space.md).frame(height: 42)
                .background(Capsule().fill(Theme.surface))
                .overlay(Capsule().stroke(Theme.hairline))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Space.md)
            .padding(.top, Theme.Space.md)
            .accessibilityLabel("Find athletes")
            scopeBar
        }
        .background(Theme.background)
    }

    /// Following | Everyone — the only "algorithm" is who you chose to follow.
    private var scopeBar: some View {
        HStack(spacing: 0) {
            ForEach(CommunityScope.allCases, id: \.self) { s in
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { scopeRaw = s.rawValue }
                } label: {
                    VStack(spacing: Theme.Space.sm) {
                        Text(s.label).font(.rounded(Theme.FontSize.body, weight: .semibold))
                        ZStack {
                            Color.clear.frame(height: 2)
                            if scope == s { Capsule().fill(Theme.ink).frame(height: 2) }
                        }
                    }
                    .foregroundStyle(scope == s ? Theme.ink : Theme.inkTertiary)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(s.label)
                .accessibilityAddTraits(scope == s ? [.isSelected] : [])
            }
        }
        .padding(.top, Theme.Space.md)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
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
                showingSearch = true
            } label: {
                Text("Find athletes")
                    .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.background)
                    .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.sm)
                    .background(Capsule().fill(Theme.ink))
            }
            .buttonStyle(.plain)
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
        case .following: "Following"
        case .everyone: "Global"   // rawValue stays "everyone" (persisted); label is the Substack-style "Global"
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
