import SwiftUI
import SwiftData

/// The World tab (docs/SOCIAL-LAYER.md) — the social surface. Slice 1 is the community feed; the
/// globe lands on top in Slice 3. Honest-by-design: the user's own shared workouts + a clearly-
/// labeled Momentum community. Private workouts never appear.
struct WorldView: View {
    enum Segment: String, CaseIterable, Identifiable { case discover = "Discover", following = "Following"; var id: String { rawValue } }

    @Query(sort: \Workout.startedAt, order: .reverse) private var workouts: [Workout]
    @Query private var profiles: [UserProfile]
    @State private var segment: Segment = .discover

    private var profile: UserProfile? { profiles.first }
    private var discoverFeed: [FeedItem] {
        FeedAssembler.feed(userWorkouts: workouts, profile: profile, community: CommunityFeed.seed())
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
                LazyVStack(spacing: Theme.Space.lg) {
                    switch segment {
                    case .discover:
                        ForEach(discoverFeed) { FeedPostCard(item: $0) }
                    case .following:
                        followingEmptyState
                    }
                }
                .padding(.horizontal, Theme.Space.lg)
                .padding(.bottom, Theme.Space.xxl)
            }
        }
        .background(Theme.background)
        .navigationBarHidden(true)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("World").font(.display(34, weight: .black)).foregroundStyle(Theme.ink)
            Spacer()
            // The globe lands here in Slice 3.
            Image(systemName: "globe").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.md).padding(.bottom, Theme.Space.md)
    }

    private var followingEmptyState: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "person.2").font(.system(size: 32, weight: .light)).foregroundStyle(Theme.inkTertiary)
            Text("Follow athletes to see them here").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            Text("Following arrives soon. For now, explore Discover.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, Theme.Space.xxl)
    }
}
