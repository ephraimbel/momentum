import SwiftUI

/// Another athlete's public profile (docs/SOCIAL-LAYER.md, Slice 2) — identity, body-of-work, a
/// follow button, and their recent public activities. Shares the same component scaffold as the
/// athlete's own `ProfileScreen` (StatGrid / DisciplineBreakdown / ConsistencyHeatmap / PRShelf) so
/// the two never diverge. Community athletes are clearly badged; real network profiles reuse this once
/// Supabase is on.
struct AthleteProfileView: View {
    let athlete: CommunityAthlete
    var distanceUnit: DistanceUnit = .auto
    var weightUnit: WeightUnit = .default()
    @Environment(FollowStore.self) private var follows
    @Environment(ModerationStore.self) private var moderation
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingReport = false

    private var records: (prs: [(name: String, e1RMKg: Double)], longestRunM: Double, longestDurationS: Double) {
        athlete.personalRecords
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                identity
                followButton
                if !athlete.bio.isEmpty {
                    Text(athlete.bio)
                        .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                headlineStats
                // The rich body-of-work scaffold is deterministic SAMPLE content — honest only
                // for badged community athletes. Real network athletes show real data only
                // (identity, posts, honest counts); their history isn't ours to invent.
                if athlete.isSample {
                    section("How you train") {
                        DisciplineBreakdown(counts: athlete.disciplineCounts)
                            .padding(Theme.Space.lg).background(card)
                    }
                    section("Consistency") {
                        ConsistencyHeatmap(countingDays: athlete.consistencyDays)
                            .padding(Theme.Space.lg).background(card)
                    }
                    if !records.prs.isEmpty || records.longestRunM > 0 || records.longestDurationS > 0 {
                        section("Personal records") {
                            PRShelf(strengthPRs: records.prs, longestRunM: records.longestRunM,
                                    longestDurationS: records.longestDurationS, weightUnit: weightUnit, distanceUnit: distanceUnit)
                        }
                    }
                }
                if !athlete.posts.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        sectionTitle("Recent")
                        ForEach(athlete.posts) { FeedPostCard(item: $0) }
                    }
                }
            }
            .padding(Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationTitle(athlete.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { confirmingReport = true } label: { Label("Report", systemImage: "flag") }
                    Button(role: .destructive) {
                        moderation.block(athlete.handle)
                        if follows.isFollowing(athlete.handle) { follows.toggle(athlete.handle) }   // also unfollow
                        Haptics.medium()
                        dismiss()
                    } label: { Label("Block \(athlete.name)", systemImage: "hand.raised") }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("More")
            }
        }
        .confirmationDialog("Report \(athlete.name)?", isPresented: $confirmingReport, titleVisibility: .visible) {
            ForEach(ReportReason.allCases) { reason in
                Button(reason.rawValue) { athlete.posts.forEach { moderation.reportPost($0.id, reason: reason) }; Haptics.success() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("We'll review their content and hide it from you.")
        }
    }

    private var identity: some View {
        VStack(spacing: Theme.Space.sm) {
            AvatarView(photo: athlete.avatarData, name: athlete.name, size: 84)
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Text(athlete.name).font(.display(26, weight: .black)).foregroundStyle(Theme.ink)
                    if athlete.isSample { communityBadge }
                }
                Text("@\(athlete.handle)").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                if let location = athlete.location {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var headlineStats: some View {
        // Real athletes: only counts we actually know (their visible posts). Sample athletes
        // keep the full strip — their whole body of work is seeded content.
        StatGrid(cells: athlete.isSample
            ? [
                .init(value: "\(athlete.totalWorkouts)", label: "Workouts"),
                .init(value: "\(athlete.dayStreak)", label: "Day streak"),
                .init(value: Formatters.distance(meters: athlete.totalDistanceM, unit: distanceUnit), label: "Distance"),
            ]
            : [.init(value: "\(athlete.posts.count)", label: "Shared workouts")],
            valueSize: 20)
        .padding(.vertical, Theme.Space.lg)
        .background(card)
    }

    private var followButton: some View {
        let following = follows.isFollowing(athlete.handle)
        return Button { follows.toggle(athlete.handle); Haptics.light() } label: {
            Label(following ? "Following" : "Follow", systemImage: following ? "checkmark" : "plus")
                .font(.rounded(Theme.FontSize.body, weight: .bold))
                .frame(maxWidth: .infinity).frame(height: 48)
                .foregroundStyle(following ? Theme.ink : Theme.background)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .fill(following ? AnyShapeStyle(Theme.surface) : AnyShapeStyle(Theme.ink))
                    if following { RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(following ? "Following \(athlete.name). Tap to unfollow." : "Follow \(athlete.name)")
    }

    private var communityBadge: some View {
        Text("Momentum").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(0.4).foregroundStyle(Theme.ink)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(IridescentMaterial()).opacity(0.55))
            .overlay(Capsule().stroke(Theme.hairline))
            .accessibilityLabel("Momentum community")
    }

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
