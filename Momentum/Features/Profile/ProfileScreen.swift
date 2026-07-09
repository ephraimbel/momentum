import SwiftUI
import SwiftData

/// The athlete's dedicated Profile tab (docs/SOCIAL-LAYER.md) — the public projection of who they
/// are, now a first-class destination rather than a push off Progress. Identity → headline counts →
/// lifetime body-of-work (discipline mix, consistency grid, trophy case) → recent shared activities,
/// with Edit + privacy and Settings in the header. Visiting another athlete reuses the same body via
/// `AthleteProfileView`.
struct ProfileScreen: View {
    /// When pushed (e.g. tapping your own post in World) we show a back chevron; as a tab root we don't.
    var showsBackButton: Bool = false

    @Query private var profiles: [UserProfile]
    @Query(sort: \Workout.startedAt, order: .reverse) private var workouts: [Workout]
    @Environment(FollowStore.self) private var follows
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var gridTab: ProfileGridTab = .grid
    @State private var immersive: ImmersiveStart?

    private var profile: UserProfile? { profiles.first }
    private var stats: ProfileStats { ProfileStats(workouts: workouts, plan: profile?.plan) }
    private var highlights: ProfileHighlights {
        ProfileHighlights(stats: stats, workouts: workouts, weightUnit: weightUnit, distanceUnit: distanceUnit)
    }
    private var weightUnit: WeightUnit { WeightUnit(rawValue: profile?.weightUnit ?? "kg") ?? .kg }
    private var distanceUnit: DistanceUnit { DistanceUnit(rawValue: profile?.distanceUnit ?? "auto") ?? .auto }

    /// A tapped tile/highlight to open the immersive pager on (Identifiable for `.fullScreenCover(item:)`).
    private struct ImmersiveStart: Identifiable { let id: UUID }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.lg, pinnedViews: [.sectionHeaders]) {
                Group {
                    identity
                    headlineStats
                    if let profile, !profile.bio.isEmpty {
                        Text(profile.bio)
                            .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Theme.Space.md)

                if stats.totalWorkouts == 0 {
                    Group {
                        firstRunCard
                        if let profile { privacyCard(profile) }
                    }
                    .padding(.horizontal, Theme.Space.md)
                } else {
                    // The grid rides high — the athlete's training is the hero. Lifetime totals,
                    // discipline mix, and consistency now live one tap away under "Highlights".
                    Section {
                        ProfileGrid(workouts: workouts, stats: stats, highlights: highlights,
                                    weightUnit: weightUnit, distanceUnit: distanceUnit, tab: gridTab) { id in
                            immersive = ImmersiveStart(id: id)
                        }
                    } header: {
                        ProfileGridTabBar(tab: $gridTab)
                    }
                    if gridTab == .highlights, let profile {
                        privacyCard(profile).padding(.horizontal, Theme.Space.md)
                    }
                }
            }
            .padding(.top, Theme.Space.md)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationBarHidden(true)
        .safeAreaInset(edge: .top) { header }
        .sheet(isPresented: $editing) { if let profile { EditProfileView(profile: profile) } }
        .fullScreenCover(item: $immersive) { start in
            ImmersiveWorkoutPager(workouts: workouts, startID: start.id,
                                  weightUnit: weightUnit, distanceUnit: distanceUnit)
        }
    }

    // MARK: Header (custom — matches Progress/World)

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            if showsBackButton {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink)
                }
                .accessibilityLabel("Back")
            }
            Text("Profile").font(.display(34, weight: .black)).foregroundStyle(Theme.ink)
            Spacer()
            Button { editing = true } label: {
                Text("Edit").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
            }
            NavigationLink { SettingsView() } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.sm).padding(.bottom, Theme.Space.sm)
        .background(Theme.background)
    }

    // MARK: Identity

    private var identity: some View {
        VStack(spacing: Theme.Space.sm) {
            AvatarView(photo: profile?.avatarData, name: displayName, size: 72)
            VStack(spacing: 3) {
                Text(displayName).font(.display(26, weight: .black)).foregroundStyle(Theme.ink)
                if let handle = handleText {
                    Text(handle).font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                }
                if let location = profile.flatMap(SocialPrivacy.publicLocation) {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var displayName: String {
        let name = profile?.displayName.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "Athlete" : name
    }
    private var handleText: String? {
        guard let h = profile?.handle, !h.isEmpty else { return nil }
        return "@\(h)"
    }

    // MARK: Headline counts

    private var headlineStats: some View {
        StatGrid(cells: [
            .init(value: "\(stats.totalWorkouts)", label: "Workouts"),
            .init(value: "\(stats.currentStreak)", label: "Day streak"),
            .init(value: "\(follows.count)", label: "Following"),
        ], valueSize: 20)
        .padding(.vertical, Theme.Space.md)
        .background(card)
    }

    // MARK: Privacy chip

    private func privacyCard(_ profile: UserProfile) -> some View {
        Button { editing = true } label: {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: SocialPrivacy.defaultVisibility(profile).icon)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Privacy").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(SocialPrivacy.exposureSummary(profile))
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkTertiary)
            }
            .padding(Theme.Space.lg)
            .background(card)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Edit your sharing and privacy settings")
    }

    // MARK: First-run (no workouts yet)

    private var firstRunCard: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "figure.run.circle").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.inkTertiary)
            Text("Your story starts here").font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
            Text("Log your first workout and your distance, streak, muscle map, and records fill in.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.xl).padding(.horizontal, Theme.Space.lg)
        .background(card)
    }

    // MARK: Building blocks

    private var card: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
    }
}
