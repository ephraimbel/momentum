import SwiftUI
import CoreLocation
import UIKit

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
    /// Set by tapping the social line — pushes this athlete's Followers|Following lists.
    @State private var graphFace: AthleteFollowListView.Face?
    #if DEBUG
    @MainActor private static var didOpenDebugGraph = false
    #endif
    /// The grid's posts: feed post(s) + deterministic history for sample athletes (cached), or
    /// exactly what a real athlete shared. Loaded once on appear.
    @State private var gridPosts: [FeedItem] = []

    var body: some View {
        ScrollViewReader { scroll in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                Group {
                    identity
                    if !athlete.bio.isEmpty {
                        // Centered under the identity block, TikTok-style (owner call 2026-07-30) —
                        // the whole header is a centered column, so a left-flushed bio read as a bug.
                        Text(athlete.bio)
                            .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center).fixedSize(horizontal: false, vertical: true)
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
                Color.clear.frame(height: 1).id("athlete-face-end")
            }
            .padding(.top, Theme.Space.md)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationBarHidden(true)
        #if DEBUG
        // --athlete-highlights: land on the Highlights face (pairs with --athlete-profile
        // [handle]); --athlete-scroll additionally jumps to the bottom — together they make every
        // section of the visited-profile design screenshot-verifiable.
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--athlete-highlights") {
                gridTab = .highlights
            }
            if args.contains("--athlete-scroll") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    withAnimation(nil) { scroll.scrollTo("athlete-face-end", anchor: .bottom) }
                }
            }
            // --athlete-graph: push the Followers list (screenshot verification; one-shot — this
            // onAppear re-fires when the list pops, and re-arming would trap the back button).
            if args.contains("--athlete-graph"), !Self.didOpenDebugGraph {
                Self.didOpenDebugGraph = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { graphFace = .followers }
            }
        }
        #endif
        }
        .safeAreaInset(edge: .top) { header }
        .navigationDestination(item: $graphFace) { face in
            AthleteFollowListView(athlete: athlete, initialFace: face)
        }
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
            AvatarView(photo: athlete.avatarData, name: athlete.name, size: 76,
                       imageName: athlete.communityAvatarAsset, preset: athlete.communityPreset)
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Text(athlete.name).font(.display(26, weight: .black)).foregroundStyle(Theme.ink)
                    // Sample members seal by the same deterministic draw their bylines use, so a
                    // sealed post never opens an unsealed profile (or vice versa). Real network
                    // athletes stay unsealed until the server actually knows their entitlement.
                    if athlete.isSample, CommunityGenerator.isPro(handle: athlete.handle) { proSeal }
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
            socialLine
            statsTrio
            followButton
        }
        .frame(maxWidth: .infinity)
    }

    /// The same quiet "N Followers · M Following" line the athlete's OWN profile leads with,
    /// in the same position (above the trio) — one identity structure everywhere (owner call
    /// 2026-07-29), and TAPPABLE like the own profile's (owner ask 2026-07-30): it pushes this
    /// athlete's Followers|Following lists. Sample athletes carry deterministic sample counts;
    /// real network athletes show only counts we actually know.
    private var socialLine: some View {
        Button { graphFace = .followers } label: {
            HStack(spacing: 5) {
                Text("\(followerCount)").font(.rounded(Theme.FontSize.body, weight: .bold))
                    .monospacedDigit().foregroundStyle(Theme.ink)
                Text("Followers").font(.rounded(Theme.FontSize.body, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
                Circle().fill(Theme.inkTertiary).frame(width: 2.5, height: 2.5)
                Text("\(followingCount)").font(.rounded(Theme.FontSize.body, weight: .bold))
                    .monospacedDigit().foregroundStyle(Theme.ink)
                Text("Following").font(.rounded(Theme.FontSize.body, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(followerCount) followers, \(followingCount) following")
        .accessibilityHint("Shows \(athlete.name)'s followers and following")
    }

    /// Workouts · distance · streak — the athletic ledger in the own profile's exact trio grammar
    /// (different content, same structure).
    private var statsTrio: some View {
        let dist = Formatters.wholeDistance(meters: athlete.totalDistanceM, unit: distanceUnit)
        return HStack(spacing: 0) {
            trioCell("\(athlete.totalWorkouts)", "Workouts")
            trioDivider
            trioCell("\(dist.value)", dist.unit)
            trioDivider
            trioCell("\(athlete.dayStreak)", "Streak")
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

    /// Sample counts come from the SHARED derivation (`sampleFollowerCount` — the same numbers
    /// size the pushed lists, so tapping "141 Followers" opens a list of exactly 141), plus the
    /// viewer's own follow. Real athletes: only what we actually know.
    private var followerCount: Int {
        let mine = follows.isFollowing(athlete.handle) ? 1 : 0
        guard athlete.isSample else { return mine }
        return athlete.sampleFollowerCount + mine
    }

    private var followingCount: Int {
        athlete.isSample ? athlete.sampleFollowingCount : 0
    }

    /// Sits exactly where "Edit profile" sits on the athlete's own page — the one action pill
    /// under the identity. Filled ink while unfollowed (it IS the page's action), hairline once
    /// following (the quiet state, like Edit).
    private var followButton: some View {
        let following = follows.isFollowing(athlete.handle)
        return Button { follows.toggle(athlete.handle); Haptics.light() } label: {
            Text(following ? "Following" : "Follow")
                .font(.rounded(Theme.FontSize.body, weight: .semibold))
                .foregroundStyle(following ? Theme.ink : Theme.background)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.vertical, 8)
                .background {
                    if following {
                        Capsule().stroke(Theme.hairline, lineWidth: 1)
                    } else {
                        Capsule().fill(Theme.ink)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PressableScaleStyle(scale: 0.97))
        .accessibilityLabel(following ? "Following \(athlete.name). Tap to unfollow." : "Follow \(athlete.name)")
    }

    /// The purple Verified-Pro seal — the SAME mark the athlete's own profile and every feed
    /// byline use (owner call 2026-07-30; replaces the old iridescent "Momentum" pill, which was
    /// the pre-redesign badge language). Sized to sit beside the 26pt display name exactly as on
    /// the own-profile header.
    private var proSeal: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(Theme.purple)
            .accessibilityLabel("Verified Pro")
    }

    // MARK: Grid — their posts in the SAME edge-to-edge wall the community and own profile use
    // (owner call 2026-07-29: one grid grammar everywhere; the old rounded padded tiles were the
    // pre-redesign look). Tap → the same full-bleed vertical pager as the wall.

    /// A tapped tile → the pager opens on it.
    private struct PagerStart: Identifiable { let id: UUID }
    @State private var pagerStart: PagerStart?

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
            CommunityFeedGrid(items: gridPosts, zoomNamespace: nil) { id in
                pagerStart = PagerStart(id: id)
            }
            .fullScreenCover(item: $pagerStart) { start in
                // Sliced from the tapped tile (the wall's rule): page one is guaranteed to be the
                // post you tapped. `ownHandle: athlete.handle` keeps the byline inert — you're
                // already ON their profile; a byline push here would stack the page on itself.
                let index = gridPosts.firstIndex(where: { $0.id == start.id }) ?? 0
                CommunityPager(items: Array(gridPosts[index...]), startID: start.id,
                               ownHandle: athlete.handle)
            }
        }
    }

    // MARK: Highlights — the athlete's body of work (sample-gated, same face as own profile)

    /// The seeded derived bundle, computed ONCE per athlete per day (pure value types, so caching
    /// is safe). Every Highlights section read these generator-backed computed properties per
    /// render — worst, the consistency count re-ran the whole `consistencyDays` generator (a
    /// ≤2000-iteration seeded loop) inside its 112-day filter closure, and `consistencyMinutes`
    /// recomputes `consistencyDays` again internally. Non-observed memo box (the FallbackMemo
    /// pattern): filled during body without dirtying SwiftUI state.
    private struct DerivedStats {
        let disciplineCounts: [WorkoutType: Int]
        let consistencyDays: Set<Int>
        let consistencyMinutes: [Int: Double]
        let lifetimeDurationS: Double
        let awardCells: [AwardsShelf.Cell]
        let awardsEarned: Int
    }
    private final class DerivedMemo { var key = ""; var value: DerivedStats? }
    @State private var derivedMemo = DerivedMemo()
    private var derived: DerivedStats {
        let key = "\(athlete.handle)-\(StreakCalculator.localDay(Date()))"
        if derivedMemo.key == key, let cached = derivedMemo.value { return cached }
        let awards = athlete.communityAwards
        let value = DerivedStats(disciplineCounts: athlete.disciplineCounts,
                                 consistencyDays: athlete.consistencyDays,
                                 consistencyMinutes: athlete.consistencyMinutes,
                                 lifetimeDurationS: athlete.lifetimeDurationS,
                                 awardCells: awards.cells,
                                 awardsEarned: awards.earnedCount)
        derivedMemo.key = key
        derivedMemo.value = value
        return value
    }

    @ViewBuilder
    private var highlightsContent: some View {
        // The own-profile Highlights grammar, verbatim (owner call 2026-07-30: EVERY profile wears
        // the redesign): reveal cascade top-down, editorial section rules, count-up heroes, the
        // PenRule, hairline-divided lifetime cells, headlined consistency card with axes.
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            if athlete.isSample {
                lifetimeSection.reveal(0)
                trainSection.reveal(0.08)
                consistencySection.reveal(0.16)
                // No "Personal records" section — the awards shelf superseded the PR cards
                // app-wide (owner call 2026-07-30; PRShelf deleted): the medallions already carry
                // the same milestones, derived from the same numbers. Every profile now reads
                // Lifetime / How they train / Consistency / Awards, exactly like the own page.
                awardsSection.reveal(0.24)
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

    /// The editorial stat block, same as the own profile: one count-up hero, the PenRule, then the
    /// supporting figures hairline-divided, set straight on the canvas (no card). Distance is the
    /// hero only for distance sports — a lifter/yogi headlining "4,200 km covered" contradicted
    /// their whole profile; their body of work is the session count.
    private var lifetimeSection: some View {
        section("Lifetime") {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    if athlete.primaryType.isGPS, athlete.totalDistanceM > 0 {
                        CountUpNumber(value: athlete.totalDistanceM,
                                      format: { Formatters.distance(meters: $0, unit: distanceUnit) },
                                      font: .display(40, weight: .black))
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .accessibilityLabel("Distance covered")
                            .accessibilityValue(Formatters.distance(meters: athlete.totalDistanceM, unit: distanceUnit))
                        Text("distance covered")
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    } else {
                        CountUpNumber(value: Double(athlete.totalWorkouts),
                                      format: { "\(Int($0.rounded()))" },
                                      font: .display(40, weight: .black))
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .accessibilityLabel("Workouts logged")
                            .accessibilityValue("\(athlete.totalWorkouts)")
                        Text("workouts logged")
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    }
                }
                PenRule(delay: 0.3)
                HStack(spacing: 0) {
                    // Lifetime, like every other number in this block — derived from distance +
                    // session mix so it can never contradict them (see `lifetimeDurationS`).
                    lifetimeCell(Formatters.duration(s: derived.lifetimeDurationS), "Time moving")
                    lifetimeDivider
                    lifetimeCell("\(athlete.totalWorkouts)", "Sessions")
                    if athlete.dayStreak > 0 {
                        lifetimeDivider
                        lifetimeCell("\(athlete.dayStreak)", "Day streak")
                    }
                }
            }
        }
    }

    private var trainSection: some View {
        section("How they train") {
            DisciplineBreakdown(counts: derived.disciplineCounts)
                .padding(Theme.Space.lg).background(card)
        }
    }

    /// The same headlined consistency card as the own profile: the one number that summarizes the
    /// grid, then the full heatmap with month/weekday axes.
    private var consistencySection: some View {
        let today = StreakCalculator.localDay(Date())
        let days = derived.consistencyDays   // once — the old closure regenerated the Set 112×
        let active = (0..<(16 * 7)).filter { days.contains(today - $0) }.count
        return section("Consistency") {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    CountUpNumber(value: Double(active), format: { "\(Int($0.rounded()))" },
                                  font: .display(22, weight: .black), delay: 0.15)
                        .accessibilityLabel("Active days, last 16 weeks")
                        .accessibilityValue("\(active)")
                    Text("active days · last 16 weeks")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                }
                ConsistencyHeatmap(countingDays: days,
                                   dayMinutes: derived.consistencyMinutes, showsAxes: true)
            }
            .padding(Theme.Space.lg).background(card)
        }
    }

    private func lifetimeCell(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.display(18, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(0.8)
                .foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lifetimeDivider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 30)
            .padding(.trailing, Theme.Space.md)
    }

    /// The athlete's trophy case — the own profile's awards shelf, verbatim (3-up medallions,
    /// settle-in entrance, "N of M" meta on the rule). Cells derive from the athlete's own
    /// records/stats (`communityAwards`), so this section and "Personal records" always agree.
    /// No "All awards" row: that navigates the viewer's OWN awards book.
    @ViewBuilder
    private var awardsSection: some View {
        let shelf = (cells: derived.awardCells, earnedCount: derived.awardsEarned)
        // A section rule over an empty shelf reads as a broken page. Every athlete has at least a
        // chase cell today (the endurance ladder always has a value), but the shelf is derived —
        // one future ladder change shouldn't be able to ship an empty header.
        if !shelf.cells.isEmpty {
            section("Awards", meta: "\(shelf.earnedCount) of \(AwardsCatalog.all.count)") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.sm), count: 3),
                          spacing: Theme.Space.md) {
                    ForEach(Array(shelf.cells.enumerated()), id: \.element.id) { i, cell in
                        AwardCell(award: cell.award, earnedAt: cell.earnedAt, progress: cell.progress)
                            .modifier(SettleIn(delay: 0.28 + Double(i) * 0.05))
                    }
                }
            }
        }
    }

    /// The own profile's editorial section header, verbatim: small tracked label with a hairline
    /// extending to the margin and optional right-aligned meta ("6 of 45"). One header language
    /// across every profile.
    private func section<Content: View>(_ title: String, meta: String? = nil,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.sm) {
                Text(title.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                    .foregroundStyle(Theme.inkTertiary)
                    .fixedSize()
                Rectangle().fill(Theme.hairline).frame(height: 1)
                if let meta {
                    Text(meta)
                        .font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Theme.inkTertiary)
                        .fixedSize()
                }
            }
            content()
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
    }
}



