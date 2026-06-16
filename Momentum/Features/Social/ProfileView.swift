import SwiftUI
import SwiftData

/// The athlete's own profile — the public projection of who they are (PRD §4.10, docs/SOCIAL-LAYER.md).
/// Shows the brand orb/identity, lifetime body-of-work, and a clear privacy chip; Edit opens the
/// editor + privacy matrix. Others' profiles (Slice 2) reuse the same body without the editing chrome.
struct ProfileView: View {
    @Query private var profiles: [UserProfile]
    @Query private var workouts: [Workout]
    @State private var editing = false

    private var profile: UserProfile? { profiles.first }
    private var stats: ProfileStats { ProfileStats(workouts: workouts) }
    private var distanceUnit: DistanceUnit {
        DistanceUnit(rawValue: profile?.distanceUnit ?? "auto") ?? .auto
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.xl) {
                identity
                if let profile, !profile.bio.isEmpty {
                    Text(profile.bio)
                        .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                statsCard
                if let profile { privacyCard(profile) }
            }
            .padding(Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { editing = true }.fontWeight(.semibold)
            }
        }
        .sheet(isPresented: $editing) {
            if let profile { EditProfileView(profile: profile) }
        }
    }

    // MARK: Identity

    private var identity: some View {
        VStack(spacing: Theme.Space.sm) {
            IridescentOrb(size: 84)
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

    // MARK: Body of work

    private var statsCard: some View {
        HStack(spacing: 0) {
            stat("\(stats.totalWorkouts)", "Workouts")
            divider
            stat("\(stats.currentStreak)", "Day streak")
            divider
            stat(Formatters.distance(meters: stats.totalDistanceM, unit: distanceUnit), "Distance")
        }
        .padding(.vertical, Theme.Space.lg)
        .frame(maxWidth: .infinity)
        .background(card)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.display(22, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity)
    }
    private var divider: some View { Rectangle().fill(Theme.hairline).frame(width: 1, height: 32) }

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

    private var card: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
    }
}
