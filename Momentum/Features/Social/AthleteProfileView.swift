import SwiftUI

/// Another athlete's public profile (docs/SOCIAL-LAYER.md, Slice 2) — identity, body-of-work, a
/// follow button, and their recent public activities. Community athletes are clearly badged. Real
/// network profiles reuse this once Supabase is on.
struct AthleteProfileView: View {
    let athlete: CommunityAthlete
    var distanceUnit: DistanceUnit = .auto
    @Environment(FollowStore.self) private var follows
    @Environment(ModerationStore.self) private var moderation
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingReport = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.xl) {
                identity
                followButton
                if !athlete.bio.isEmpty {
                    Text(athlete.bio)
                        .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                statsCard
                if !athlete.posts.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        Text("RECENT").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
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
                Button(reason.rawValue) { athlete.posts.forEach { moderation.report($0.id) }; Haptics.success() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("We'll review their content and hide it from you.")
        }
    }

    private var identity: some View {
        VStack(spacing: Theme.Space.sm) {
            IridescentOrb(size: 84)
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Text(athlete.name).font(.display(26, weight: .black)).foregroundStyle(Theme.ink)
                    communityBadge
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

    private var statsCard: some View {
        HStack(spacing: 0) {
            stat("\(athlete.totalWorkouts)", "Workouts")
            divider
            stat("\(athlete.dayStreak)", "Day streak")
            divider
            stat(Formatters.distance(meters: athlete.totalDistanceM, unit: distanceUnit), "Distance")
        }
        .padding(.vertical, Theme.Space.lg).frame(maxWidth: .infinity)
        .background(card)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.display(20, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity)
    }
    private var divider: some View { Rectangle().fill(Theme.hairline).frame(width: 1, height: 32) }

    private var communityBadge: some View {
        Text("Momentum").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(0.4).foregroundStyle(Theme.ink)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(IridescentMaterial()).opacity(0.55))
            .overlay(Capsule().stroke(Theme.hairline))
            .accessibilityLabel("Momentum community")
    }

    private var card: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
    }
}
