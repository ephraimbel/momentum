import SwiftUI
import SwiftData

/// The World tab (docs/SOCIAL-LAYER.md) — the social surface. Slice 1 is the community feed; the
/// globe lands on top in Slice 3. Honest-by-design: the user's own shared workouts + a clearly-
/// labeled Momentum community. Private workouts never appear.
struct WorldView: View {
    enum Segment: String, CaseIterable, Identifiable { case discover = "Discover", following = "Following"; var id: String { rawValue } }
    /// Pushed destinations within the World tab's NavigationStack.
    enum WorldRoute: Hashable { case athlete(String), me }

    @Query(sort: \Workout.startedAt, order: .reverse) private var workouts: [Workout]
    @Query private var profiles: [UserProfile]
    @Environment(FollowStore.self) private var follows
    @Environment(ModerationStore.self) private var moderation
    @State private var segment: Segment = .discover
    #if DEBUG
    @State private var debugGlobe = ProcessInfo.processInfo.arguments.contains("--social-globe")
    #endif

    private var profile: UserProfile? { profiles.first }
    private var discoverFeed: [FeedItem] {
        FeedAssembler.feed(userWorkouts: workouts, profile: profile, community: CommunityFeed.seed())
            .filter(moderation.isVisible)
    }
    /// Posts from athletes the user follows, newest first.
    private var followingFeed: [FeedItem] {
        CommunityFeed.seed()
            .filter { follows.isFollowing($0.authorHandle ?? "") && moderation.isVisible($0) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $segment) {
                ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Space.lg).padding(.bottom, Theme.Space.sm)

            ScrollView {
                LazyVStack(spacing: 0) {       // editorial feed — rows carry their own padding + divider
                    switch segment {
                    case .discover:
                        feedList(discoverFeed)
                    case .following:
                        if followingFeed.isEmpty { followingEmptyState } else { feedList(followingFeed) }
                    }
                }
                .padding(.horizontal, Theme.Space.lg)
                .padding(.bottom, Theme.Space.xxl)
            }
        }
        .background(Theme.background)
        .navigationBarHidden(true)
        .navigationDestination(for: WorldRoute.self) { route in
            switch route {
            case .athlete(let handle):
                if let athlete = CommunityDirectory.athlete(handle: handle) {
                    AthleteProfileView(athlete: athlete)
                }
            case .me:
                ProfileView()
            }
        }
        #if DEBUG
        // Deterministic deep link for sim verification (small toolbar buttons are unreliable to tap).
        .fullScreenCover(isPresented: $debugGlobe) {
            NavigationStack {
                GlobeView().toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Close") { debugGlobe = false } }
                }
            }
        }
        #endif
    }

    /// A list of feed cards; community authors are tappable through to their profile.
    @ViewBuilder
    private func feedList(_ items: [FeedItem]) -> some View {
        ForEach(items) { item in
            if item.isCommunity, let handle = item.authorHandle {
                FeedPostCard(item: item, navValue: .athlete(handle))
            } else {
                FeedPostCard(item: item, navValue: .me)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("World").font(.display(34, weight: .black)).foregroundStyle(Theme.ink)
            Spacer()
            NavigationLink { GlobeView() } label: {
                Image(systemName: "globe").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Globe")
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.md).padding(.bottom, Theme.Space.md)
    }

    private var followingEmptyState: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "person.2").font(.system(size: 32, weight: .light)).foregroundStyle(Theme.inkTertiary)
            Text("Follow athletes to see them here").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            Text("Tap an athlete in Discover, then Follow — their posts land here.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, Theme.Space.xxl)
    }
}
