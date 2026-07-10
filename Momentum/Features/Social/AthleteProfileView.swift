import SwiftUI
import CoreLocation

/// Another athlete's profile (docs/SOCIAL-LAYER.md, Slice 2) — structured EXACTLY like the
/// athlete's own `ProfileScreen` so visiting someone feels like visiting a peer, not a different
/// app: identity → posts/followers/following trio → follow → bio → the Grid|Highlights faces with
/// the same tile grammar. Community athletes stay clearly badged; real network athletes show only
/// honest data (a sample body-of-work is never invented for them).
struct AthleteProfileView: View {
    let athlete: CommunityAthlete
    var distanceUnit: DistanceUnit = .auto
    var weightUnit: WeightUnit = .default()

    @Environment(FollowStore.self) private var follows
    @Environment(ModerationStore.self) private var moderation
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingReport = false
    @State private var gridTab: ProfileGridTab = .grid
    /// The grid's posts: feed post(s) + deterministic history for sample athletes (cached), or
    /// exactly what a real athlete shared. Loaded once on appear.
    @State private var gridPosts: [FeedItem] = []

    private var records: (prs: [(name: String, e1RMKg: Double)], longestRunM: Double, longestDurationS: Double) {
        athlete.personalRecords
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                Group {
                    identity
                    followButton
                    if !athlete.bio.isEmpty {
                        Text(athlete.bio)
                            .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Theme.Space.md)

                // The same two-face layout as the athlete's own profile: their training is the hero.
                Section {
                    switch gridTab {
                    case .grid: postGrid
                    case .highlights: highlightsContent
                    }
                } header: {
                    ProfileGridTabBar(tab: $gridTab)
                }
            }
            .padding(.top, Theme.Space.md)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationBarHidden(true)
        .safeAreaInset(edge: .top) { header }
        .onAppear { if gridPosts.isEmpty { gridPosts = CommunityDirectory.gridPosts(for: athlete) } }
        .confirmationDialog("Report \(athlete.name)?", isPresented: $confirmingReport, titleVisibility: .visible) {
            ForEach(ReportReason.allCases) { reason in
                Button(reason.rawValue) { athlete.posts.forEach { moderation.reportPost($0.id, reason: reason) }; Haptics.success() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("We'll review their content and hide it from you.")
        }
    }

    // MARK: Header — the same quiet chrome as ProfileScreen (back + actions, no duplicate title)

    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink)
            }
            .accessibilityLabel("Back")
            Spacer()
            Menu {
                Button { confirmingReport = true } label: { Label("Report", systemImage: "flag") }
                Button(role: .destructive) {
                    moderation.block(athlete.handle)
                    if follows.isFollowing(athlete.handle) { follows.toggle(athlete.handle) }   // also unfollow
                    Haptics.medium()
                    dismiss()
                } label: { Label("Block \(athlete.name)", systemImage: "hand.raised") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.xs).padding(.bottom, Theme.Space.xs)
        .background(Theme.background)
    }

    // MARK: Identity — mirrors ProfileScreen.identity

    private var identity: some View {
        VStack(spacing: Theme.Space.md) {
            AvatarView(photo: athlete.avatarData, name: athlete.name, size: 76)
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Text(athlete.name).font(.display(26, weight: .black)).foregroundStyle(Theme.ink)
                    if athlete.isSample { communityBadge }
                }
                HStack(spacing: 6) {
                    Text("@\(athlete.handle)")
                        .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    if let location = athlete.location {
                        Circle().fill(Theme.inkTertiary).frame(width: 2.5, height: 2.5)
                        Label(location, systemImage: "mappin.and.ellipse")
                            .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    }
                }
            }
            socialTrio
        }
        .frame(maxWidth: .infinity)
    }

    /// The same posts · followers · following strip the athlete sees on their own profile.
    /// Sample athletes carry deterministic sample counts (their entire presence is seeded content,
    /// clearly badged); real network athletes show only counts we actually know.
    private var socialTrio: some View {
        HStack(spacing: 0) {
            trioCell("\(max(gridPosts.count, athlete.posts.count))", "Posts")
            trioDivider
            trioCell("\(followerCount)", "Followers")
            trioDivider
            trioCell("\(followingCount)", "Following")
        }
        .padding(.horizontal, Theme.Space.xl)
    }

    private func trioCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.display(20, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1)
                .foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var trioDivider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 28)
    }

    /// Deterministic per-athlete sample counts (stable across launches — hashed from the handle),
    /// plus the viewer's own follow. Real athletes: only what we actually know.
    private var followerCount: Int {
        let mine = follows.isFollowing(athlete.handle) ? 1 : 0
        guard athlete.isSample else { return mine }
        let seed = athlete.handle.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF }
        return 40 + seed % 860 + mine
    }

    private var followingCount: Int {
        guard athlete.isSample else { return 0 }
        let seed = athlete.handle.utf8.reduce(7) { ($0 &* 17 &+ Int($1)) & 0xFFFF }
        return 15 + seed % 320
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

    // MARK: Grid — their posts in the same 3-column tile grammar as the athlete's own grid

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Theme.Space.sm), count: 3)

    @ViewBuilder
    private var postGrid: some View {
        if gridPosts.isEmpty {
            VStack(spacing: Theme.Space.sm) {
                Image(systemName: "square.grid.3x3").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.inkTertiary)
                Text("No shared workouts yet")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.xxl)
        } else {
            LazyVGrid(columns: columns, spacing: Theme.Space.sm) {
                ForEach(gridPosts) { post in
                    NavigationLink { PostDetailView(item: post) } label: {
                        PostTile(item: post)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.top, Theme.Space.md)
        }
    }

    // MARK: Highlights — the athlete's body of work (sample-gated, same face as own profile)

    @ViewBuilder
    private var highlightsContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            if athlete.isSample {
                section("Lifetime") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Formatters.distance(meters: athlete.totalDistanceM, unit: distanceUnit))
                            .font(.display(40, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text("distance covered")
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                section("How they train") {
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
            } else {
                // Real athletes: we don't invent a body of work. Their grid speaks for them.
                Text("Highlights appear as \(athlete.name) shares more.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Theme.Space.xxl)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.lg)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(title.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                .foregroundStyle(Theme.inkTertiary)
            content()
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
    }
}

// MARK: - Post tile (a FeedItem in the own-grid's tile grammar)

/// One shared workout as a grid tile — identical grammar to the own profile's `WorkoutTile`
/// (3:4, radius 12, hairline, bottom metric strip) so visited grids read as the same product.
/// Media priority mirrors `WorkoutTileMedia`: photo → muscle map → route silhouette → glyph.
private struct PostTile: View {
    let item: FeedItem

    var body: some View {
        Color.clear
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay { media }
            .overlay(alignment: .bottom) { metricStrip }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(item.type.title), \(metric)")
    }

    @ViewBuilder
    private var media: some View {
        if let data = item.photoData, let ui = UIImage(data: data) {
            Image(uiImage: ui).resizable().scaledToFill()
        } else if let muscles = item.muscles, !muscles.isEmpty {
            ZStack {
                Theme.surface
                MuscleMapView(activation: muscles, forceStatic: true)
                    .padding(Theme.Space.sm)
            }
        } else if let route = routeCoords, route.count > 1 {
            ZStack {
                Theme.background
                RouteSilhouette(coords: route)
                    .stroke(Theme.route, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .padding(Theme.Space.md)
            }
        } else {
            ZStack {
                LinearGradient(colors: Theme.iridescent.map { $0.opacity(0.25) },
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: item.type.systemImage)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Theme.ink.opacity(0.85))
            }
        }
    }

    private var routeCoords: [CLLocationCoordinate2D]? {
        item.routeLatLon?.compactMap { pair in
            pair.count == 2 ? CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1]) : nil
        }
    }

    private var metricStrip: some View {
        HStack(spacing: 4) {
            Image(systemName: item.type.systemImage).font(.system(size: 10, weight: .bold))
            Text(metric).font(.rounded(11, weight: .bold)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Theme.Space.sm).padding(.vertical, Theme.Space.chipV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom))
    }

    /// The stat line's headline number (it reads "5.2 mi · 8:41 /mi" — the tile shows the first).
    private var metric: String {
        item.statLine.components(separatedBy: "·").first?.trimmingCharacters(in: .whitespaces) ?? item.statLine
    }
}
