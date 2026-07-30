import SwiftUI
import SwiftData

/// The athlete's follow graph, pushed from the profile's "Followers · Following" line
/// (followers/following returned with the community launch, 2026-07-29). Two faces:
///
/// **Following** is the real local follow set — every handle shows, always. Seeded community
/// handles resolve to full profiles; a handle that can't resolve (a real athlete, or one while
/// offline) still shows as a plain row rather than vanishing. Dropping unresolvable handles is
/// what made the count and the list disagree — "1 Following" over "Nobody yet" (fixed 2026-07-30).
///
/// **Followers** comes from the backend (`pullFollowers`) and stays honest: before the backend can
/// answer, a quiet explainer, never a fabricated crowd.
struct FollowingListView: View {
    /// Which face to open on (the tapped word).
    var initialFace: Face = .following

    enum Face: String, CaseIterable { case followers = "Followers", following = "Following" }
    @State private var face: Face = .following
    @Environment(FollowStore.self) private var follows
    @Environment(Services.self) private var services
    @Environment(RemoteFeedStore.self) private var remoteFeed
    @State private var selectedAthlete: CommunityAthlete?
    /// nil = not answered yet / unavailable (guest, offline, dark build) → honest empty state.
    @State private var followers: [AthleteHit]?
    /// Who was followed when this screen opened. Rows stay on screen for the visit even after an
    /// unfollow, so a mis-tap is one tap to undo instead of a row that vanishes and has to be
    /// searched for again (the behaviour every major app has; owner ask 2026-07-30). Re-snapshot on
    /// appear, so the list is fresh each visit.
    @State private var openedWith: Set<String> = []

    init(initialFace: Face = .following) {
        self.initialFace = initialFace
        _face = State(initialValue: initialFace)
    }

    /// One row's subject. `athlete` is nil when the handle isn't locally resolvable — the row still
    /// renders (and stays unfollowable-able), it just can't push a profile page it doesn't have.
    private struct Person: Identifiable {
        let handle: String
        let displayName: String?
        let athlete: CommunityAthlete?
        var id: String { handle }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                switch face {
                case .following:
                    if followingPeople.isEmpty { emptyFollowing } else { ForEach(followingPeople) { row($0) } }
                case .followers:
                    if followerPeople.isEmpty { emptyFollowers } else { ForEach(followerPeople) { row($0) } }
                }
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            SegmentedCapsule(items: Face.allCases, selection: $face, scale: .page) { $0.rawValue }
                .padding(.horizontal, Theme.Space.lg)
                .padding(.vertical, Theme.Space.sm)
                .background(Theme.background)
        }
        .navigationDestination(item: $selectedAthlete) { AthleteProfileView(athlete: $0) }
        .task { followers = await services.social.pullFollowers() }
        .onAppear { openedWith = follows.following }
    }

    /// Every followed handle, resolved where possible — never filtered. Includes anyone unfollowed
    /// during this visit (see `openedWith`) so their row stays put, showing "Follow" again.
    private var followingPeople: [Person] {
        openedWith.union(follows.following).sorted().map { handle in
            let athlete = CommunityDirectory.athlete(handle: handle)
            return Person(handle: handle, displayName: athlete?.name, athlete: athlete)
        }
    }

    /// Real followers only; a follower who also happens to be a seeded athlete resolves so their
    /// row can open a profile.
    private var followerPeople: [Person] {
        (followers ?? []).map { hit in
            Person(handle: hit.handle, displayName: hit.displayName.isEmpty ? nil : hit.displayName,
                   athlete: CommunityDirectory.athlete(handle: hit.handle))
        }
    }

    private func row(_ person: Person) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Button {
                if let athlete = person.athlete {
                    selectedAthlete = athlete
                } else {
                    // A REAL athlete (no seeded profile): resolve their page from the backend and
                    // push it — the same resolution the pager's byline uses. A miss (offline/dark)
                    // just leaves the list where it is.
                    Task {
                        if let remote = await remoteFeed.athlete(handle: person.handle) {
                            selectedAthlete = remote
                        }
                    }
                }
            } label: {
                HStack(spacing: Theme.Space.sm) {
                    // Presets and monograms, not the synthetic face assets — the same "no stock
                    // photos in a list" call the athlete search follows (2026-07-15).
                    AvatarView(photo: person.athlete?.avatarData,
                               name: person.displayName ?? person.handle, size: 42,
                               preset: person.athlete?.communityPreset)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(person.displayName ?? "@\(person.handle)")
                            .font(.rounded(15, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                        // Only when it isn't already the headline — an unresolved handle shows once.
                        if person.displayName != nil {
                            Text("@\(person.handle)")
                                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                                .foregroundStyle(Theme.inkTertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View \(person.displayName ?? person.handle)'s profile")
            followPill(person)
        }
        .padding(.vertical, Theme.Space.sm + 2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    /// Follow / Following — the same pill the search and profile use, so unfollowing works from
    /// here too (and a follower can be followed back straight from the Followers face).
    private func followPill(_ person: Person) -> some View {
        let following = follows.isFollowing(person.handle)
        let name = person.displayName ?? person.handle
        return Button {
            follows.toggle(person.handle); Haptics.light()
        } label: {
            Text(following ? "Following" : "Follow")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                .foregroundStyle(following ? Theme.ink : Theme.background)
                .padding(.horizontal, Theme.Space.md).padding(.vertical, 6)
                .background(Capsule().fill(following ? AnyShapeStyle(Theme.surface) : AnyShapeStyle(Theme.ink)))
                .overlay(Capsule().stroke(following ? Theme.hairline : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(following ? "Unfollow \(name)" : "Follow \(name)")
    }

    private var emptyFollowing: some View {
        VStack(spacing: Theme.Space.sm) {
            Text("Nobody yet")
                .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
            Text("Follow athletes from the community and they'll show up here.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.xxl)
    }

    /// Honest empty state: follower lists come from the backend; nothing is fabricated here.
    private var emptyFollowers: some View {
        VStack(spacing: Theme.Space.sm) {
            Text("No followers yet")
                .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
            Text("Share a workout to Friends or Everyone — athletes who follow you will appear here.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.xxl)
    }
}

#Preview {
    NavigationStack { FollowingListView() }
        .environment(FollowStore())
        .environment(Services.live())
}

// MARK: - Another athlete's graph

/// The Followers/Following lists behind ANOTHER athlete's social line (owner ask 2026-07-30 — the
/// line was plain text everywhere but your own profile). Sample athletes get their deterministic
/// community graph, sized to exactly the numbers the header shows; when the viewer follows this
/// athlete, they appear at the top of Followers (the Instagram read). Real network athletes show an
/// honest explainer — the backend's privacy model (`follows_read` RLS) deliberately doesn't expose
/// anyone else's graph, so there is nothing truthful to list.
struct AthleteFollowListView: View {
    let athlete: CommunityAthlete
    var initialFace: Face = .followers

    enum Face: String, CaseIterable, Identifiable {
        case followers = "Followers", following = "Following"
        var id: String { rawValue }
    }
    @State private var face: Face
    @Environment(FollowStore.self) private var follows
    @Environment(ModerationStore.self) private var moderation
    @Query private var profiles: [UserProfile]
    @State private var selected: CommunityAthlete?
    /// Resolved once per face — 150–330 rows of directory lookups don't belong in `body`.
    @State private var rows: [CommunityAthlete] = []

    init(athlete: CommunityAthlete, initialFace: Face = .followers) {
        self.athlete = athlete
        self.initialFace = initialFace
        _face = State(initialValue: initialFace)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !athlete.isSample {
                    unavailable
                } else {
                    if face == .followers, follows.isFollowing(athlete.handle), let me = profiles.first {
                        viewerRow(me)
                    }
                    ForEach(rows.filter { !moderation.blockedHandles.contains($0.handle) }) { row($0) }
                }
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationTitle(athlete.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            SegmentedCapsule(items: Face.allCases, selection: $face, scale: .page) { $0.rawValue }
                .padding(.horizontal, Theme.Space.lg)
                .padding(.vertical, Theme.Space.sm)
                .background(Theme.background)
        }
        .navigationDestination(item: $selected) { AthleteProfileView(athlete: $0) }
        .task(id: face) {
            guard athlete.isSample else { return }
            rows = face == .followers ? athlete.sampleFollowers() : athlete.sampleFollowing()
        }
    }

    /// The viewer, leading the Followers face when they follow this athlete — the +1 the header
    /// counts. No pill (you can't follow yourself); tapping goes nowhere (you're already you).
    private func viewerRow(_ me: UserProfile) -> some View {
        HStack(spacing: Theme.Space.sm) {
            AvatarView(photo: me.avatarData, name: me.displayName, size: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text(me.displayName.isEmpty ? "You" : me.displayName)
                    .font(.rounded(15, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(me.handle.isEmpty ? "You" : "@\(me.handle)")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Space.sm + 2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
        .accessibilityElement(children: .combine)
    }

    private func row(_ person: CommunityAthlete) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Button { selected = person } label: {
                HStack(spacing: Theme.Space.sm) {
                    AvatarView(photo: person.avatarData, name: person.name, size: 42,
                               preset: person.communityPreset)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(person.name)
                            .font(.rounded(15, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                        Text("@\(person.handle)")
                            .font(.rounded(Theme.FontSize.caption, weight: .medium))
                            .foregroundStyle(Theme.inkTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View \(person.name)'s profile")
            // The pill is the VIEWER's relationship to this person (the Instagram semantics for
            // someone else's list) — same store, same look, as everywhere else.
            Button {
                follows.toggle(person.handle); Haptics.light()
            } label: {
                let following = follows.isFollowing(person.handle)
                Text(following ? "Following" : "Follow")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                    .foregroundStyle(following ? Theme.ink : Theme.background)
                    .padding(.horizontal, Theme.Space.md).padding(.vertical, 6)
                    .background(Capsule().fill(following ? AnyShapeStyle(Theme.surface) : AnyShapeStyle(Theme.ink)))
                    .overlay(Capsule().stroke(following ? Theme.hairline : .clear))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(follows.isFollowing(person.handle)
                ? "Unfollow \(person.name)" : "Follow \(person.name)")
        }
        .padding(.vertical, Theme.Space.sm + 2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    private var unavailable: some View {
        VStack(spacing: Theme.Space.sm) {
            Text("Not available yet")
                .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
            Text("\(athlete.name)'s follower list isn't shared. You can still follow them and see their posts.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.xxl)
    }
}
