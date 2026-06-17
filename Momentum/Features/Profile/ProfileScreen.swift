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

    private var profile: UserProfile? { profiles.first }
    private var stats: ProfileStats { ProfileStats(workouts: workouts) }
    private var weightUnit: WeightUnit { WeightUnit(rawValue: profile?.weightUnit ?? "kg") ?? .kg }
    private var distanceUnit: DistanceUnit { DistanceUnit(rawValue: profile?.distanceUnit ?? "auto") ?? .auto }

    /// The athlete's own shared workouts, rendered through the feed card (their public posts).
    private var myPosts: [FeedItem] {
        workouts.filter { SocialPrivacy.isShared($0) }.map { FeedAssembler.item(from: $0, profile: profile) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                identity
                headlineStats
                if let profile, !profile.bio.isEmpty {
                    Text(profile.bio)
                        .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                lifetimeTotals
                if !stats.countsByType.isEmpty { breakdownSection }
                consistencySection
                if !trophyShelf.isEmpty { trophySection }
                recentSection
                if let profile { privacyCard(profile) }
            }
            .padding(Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationBarHidden(true)
        .safeAreaInset(edge: .top) { header }
        .sheet(isPresented: $editing) { if let profile { EditProfileView(profile: profile) } }
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
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.sm).padding(.bottom, Theme.Space.sm)
        .background(Theme.background)
    }

    // MARK: Identity

    private var identity: some View {
        VStack(spacing: Theme.Space.sm) {
            AvatarView(photo: profile?.avatarData, name: displayName, size: 88)
            VStack(spacing: 3) {
                Text(displayName).font(.display(28, weight: .black)).foregroundStyle(Theme.ink)
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
        ], valueSize: 22)
        .padding(.vertical, Theme.Space.lg)
        .background(card)
    }

    // MARK: Lifetime totals

    private var lifetimeTotals: some View {
        var cells: [StatGrid.Cell] = [
            .init(value: Formatters.distance(meters: stats.totalDistanceM, unit: distanceUnit), label: "Distance"),
            .init(value: Formatters.duration(s: stats.totalDurationS), label: "Time"),
        ]
        if stats.totalVolumeKg > 0 {
            let vol = weightUnit == .lb ? stats.totalVolumeKg * Formatters.lbPerKg : stats.totalVolumeKg
            cells.append(.init(value: "\(Formatters.compact(vol)) \(weightUnit == .lb ? "lb" : "kg")", label: "Volume"))
        }
        return section("Lifetime") {
            StatGrid(cells: cells, valueSize: 18)
                .padding(.vertical, Theme.Space.md)
                .background(card)
        }
    }

    // MARK: Discipline breakdown

    private var breakdownSection: some View {
        section("How you train") {
            DisciplineBreakdown(counts: stats.countsByType)
                .padding(Theme.Space.lg)
                .background(card)
        }
    }

    // MARK: Consistency

    private var consistencySection: some View {
        section("Consistency") {
            ConsistencyHeatmap(countingDays: stats.countingDays)
                .padding(Theme.Space.lg)
                .background(card)
        }
    }

    // MARK: Trophy case

    private var trophyShelf: [(name: String, e1RMKg: Double)] { stats.strengthPRs }
    private var trophySection: some View {
        section("Personal records") {
            PRShelf(strengthPRs: stats.strengthPRs, longestRunM: stats.longestRunM,
                    longestDurationS: stats.longestDurationS, weightUnit: weightUnit, distanceUnit: distanceUnit)
        }
    }

    // MARK: Recent activities

    @ViewBuilder
    private var recentSection: some View {
        if myPosts.isEmpty {
            section("Recent") {
                VStack(spacing: Theme.Space.sm) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.inkTertiary)
                    Text("Your shared workouts show here").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                    Text("Set a workout to Followers or Everyone and it lands on your profile.")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.xl)
                .background(card)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("Recent")
                ForEach(myPosts) { FeedPostCard(item: $0) }
            }
        }
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

    // MARK: Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            sectionTitle(title)
            content()
        }
    }
    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
    }
    private var card: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
    }
}
