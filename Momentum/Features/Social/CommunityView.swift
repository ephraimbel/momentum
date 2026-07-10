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
    @AppStorage("community.feedScope") private var scopeRaw = CommunityScope.everyone.rawValue
    @State private var selectedAthlete: CommunityAthlete?

    private var profile: UserProfile? { profiles.first }
    private var scope: CommunityScope { CommunityScope(rawValue: scopeRaw) ?? .everyone }

    init() {
        // `--reset-social` starts UI tests from the default scope, like the social stores.
        SocialDebug.resetIfRequested(.standard, keys: ["community.feedScope"])
    }

    /// Own workouts feeding the assembler — bounded so photo/route blobs of a long history never all
    /// materialize for one screen (older shared posts still live in Profile).
    private static let ownWorkoutCap = 50

    /// Assembled once per relevant change (the community seed is ~250 athletes' posts — never filter
    /// per row). Moderation runs on the full stream so blocked athletes vanish from both scopes.
    /// Remote posts (real athletes, fetched per-scope so the *server's* follow graph gates them)
    /// merge on top; the local pipeline — including `FeedAssembler.scoped` — is unchanged.
    private var feed: [FeedItem] {
        let shared = workouts.lazy.filter { SocialPrivacy.isShared($0) }.prefix(Self.ownWorkoutCap)
        let full = FeedAssembler.feed(userWorkouts: Array(shared), profile: profile,
                                      community: CommunityFeed.seed())
            .filter(moderation.isVisible)
        let local = scope == .following ? FeedAssembler.scoped(full, following: follows.following) : full
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
                let items = feed
                if items.isEmpty {
                    emptyState.padding(.top, Theme.Space.xxl)
                } else {
                    ForEach(items) { item in
                        // Own posts keep an inert byline (no self-profile push from the feed).
                        FeedPostCard(item: item, onOpenAuthor: item.authorHandle == profile?.handle
                            ? nil
                            : { handle in openAthlete(handle) })
                    }
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationBarHidden(true)
        .safeAreaInset(edge: .top) { header }
        .navigationDestination(item: $selectedAthlete) { AthleteProfileView(athlete: $0) }
        .refreshable { await remoteFeed.refresh(scope: remoteScope) }
        .task(id: scopeRaw) {
            // First load per scope — pull-to-refresh handles the rest. No-op offline/guest/dark.
            if remoteFeed.items.isEmpty { await remoteFeed.refresh(scope: remoteScope) }
        }
        #if DEBUG
        // --athlete-profile: open the first community athlete directly (deterministic sim
        // verification of the visited-profile design; feed taps are flaky in UI tests).
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--athlete-profile"), selectedAthlete == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    selectedAthlete = CommunityDirectory.all().first
                }
            }
        }
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
            HStack(alignment: .firstTextBaseline) {
                Text("Community").font(.display(34, weight: .black)).foregroundStyle(Theme.ink)
                Spacer()
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.top, Theme.Space.sm)
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
            Text("Follow athletes you care about, or share your next workout — it lands here too.")
                .font(.rounded(Theme.FontSize.body, weight: .regular)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
            Button {
                withAnimation(.easeOut(duration: 0.2)) { scopeRaw = CommunityScope.everyone.rawValue }
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
        case .everyone: "Everyone"
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
}
