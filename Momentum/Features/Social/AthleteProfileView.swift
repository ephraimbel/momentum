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
    @Environment(NudgeStore.self) private var nudges
    @Environment(ModerationStore.self) private var moderation
    @Environment(Services.self) private var services
    @Environment(\.dismiss) private var dismiss
    /// A REAL athlete's public counts, fetched per appearance (`follow_counts_of` — the server
    /// excludes the viewer's own edge, so `+mine` below stays exact). nil until it answers;
    /// sample athletes never fetch (their graph is the deterministic local one).
    @State private var remoteCounts: (followers: Int, following: Int)?
    @State private var confirmingReport = false
    @State private var gridTab: ProfileGridTab = .grid
    /// Set by tapping the social line — pushes this athlete's Followers|Following lists.
    @State private var graphFace: AthleteFollowListView.Face?
    #if DEBUG
    @MainActor private static var didOpenDebugGraph = false
    #endif
    /// The grid's posts: one tile per ledger session for sample athletes, or exactly what a real
    /// athlete shared. Materialized a page at a time — a veteran with 900 sessions has 900 tiles,
    /// and building them all to show nine would make every profile open at the speed of the
    /// slowest athlete in the directory.
    @State private var gridPosts: [FeedItem] = []

    var body: some View {
        ScrollViewReader { scroll in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                // The shared ProfileHero — the same block the athlete's own profile leads with.
                identity

                // The same two-face layout as the athlete's own profile: their training is the hero.
                // One child, not a Section: the stack's 24pt spacing between a Section header and
                // its content read as a gap between the tab strip and the first tile row.
                VStack(spacing: 0) {
                    ProfileGridTabBar(tab: $gridTab)
                    switch gridTab {
                    case .grid: postGrid
                    case .highlights: highlightsContent
                    }
                }
                Color.clear.frame(height: 1).id("athlete-face-end")
            }
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
        .navigationDestination(item: $graphFace) { face in
            AthleteFollowListView(athlete: athlete, initialFace: face)
        }
        .onAppear { if gridPosts.isEmpty { gridPosts = CommunityDirectory.gridPosts(for: athlete) } }
        // A real athlete's actual audience — one fetch per appearance, cancelled with the view.
        .task {
            if !athlete.isSample {
                remoteCounts = await services.social.followCounts(of: athlete.handle)
            }
        }
        .confirmationDialog("Report \(athlete.name)?", isPresented: $confirmingReport, titleVisibility: .visible) {
            ForEach(ReportReason.allCases) { reason in
                Button(reason.rawValue) {
                    // Files the report AND hides them everywhere — the old version reported the
                    // athlete's hand-built sample posts only, so most of their content stayed on
                    // screen after a report that promised otherwise (see `reportAthlete`).
                    moderation.reportAthlete(athlete.handle, reason: reason)
                    Haptics.success()
                    ToastCenter.shared.show(icon: "flag", line: "Reported. You won't see \(athlete.name) again.")
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("We'll review their content and hide it from you.")
        }
    }

    // MARK: Hero — the shared ProfileHero (twin of ProfileScreen's)

    /// Trained in the last 24h — the ring. Derived from their latest post, so it is only ever as
    /// true as what they actually shared.
    private var trainedToday: Bool {
        guard let latest = (gridPosts.isEmpty ? athlete.posts : gridPosts).map(\.date).max() else { return false }
        return Date().timeIntervalSince(latest) < 86_400
    }

    /// Disciplines they actually train, most frequent first — counted over their WHOLE ledger, not
    /// over the page of tiles that happens to be loaded, so the chips don't change as you scroll.
    private var chips: [ProfileHeroStyle.Chip] {
        derived.lifetime.typeCounts.sorted { ($0.value, $0.key.rawValue) > ($1.value, $1.key.rawValue) }
            .prefix(3).map { .init(id: $0.key.rawValue, text: $0.key.title) }
    }

    private var identity: some View {
        // The trio reads the ledger, which is also what the grid below draws: the workouts count is
        // the number of tiles, the distance is their sum, and the streak is the run of days the
        // newest tiles sit on. They cannot disagree (owner report 2026-08-28).
        let life = derived.lifetime
        let dist = Formatters.wholeDistance(meters: life.distanceM, unit: distanceUnit)
        let following = follows.isFollowing(athlete.handle)
        return ProfileHero(
            ringed: trainedToday,
            // Grouped, like every other figure in the app: "2560" beside a tile reading
            // "15,583 lb" is the same page speaking two dialects.
            trio: [(life.sessions.formatted(), "Workouts"), (dist.value.formatted(), dist.unit),
                   (life.streakDays.formatted(), "Streak")],
            name: athlete.name,
            // Sample members seal by the same deterministic draw their bylines use; real network
            // athletes stay unsealed until the server actually knows their entitlement.
            isPro: athlete.isSample && CommunityGenerator.isPro(handle: athlete.handle),
            handle: athlete.handle,
            location: athlete.location,
            bio: athlete.bio,
            followLine: .init(followers: followerCount, following: followingCount) { graphFace = .followers },
            chips: chips,
            chrome: {
                ProfileTopBar(
                    leading: {
                        Button { dismiss() } label: {
                            ProfileHeroStyle.chromeButton("chevron.left", size: 17)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Back")
                    },
                    center: { EmptyView() },
                    trailing: {
                        Menu {
                            Button { confirmingReport = true } label: { Label("Report", systemImage: "flag") }
                            Button(role: .destructive) {
                                // `ModerationStore.block` unfollows too, at every block site in
                                // the app (2026-08-29) — this page no longer has to remember.
                                moderation.block(athlete.handle)
                                Haptics.medium()
                                ToastCenter.shared.show(icon: "hand.raised",
                                                        line: "Blocked \(athlete.name).")
                                dismiss()
                            } label: { Label("Block \(athlete.name)", systemImage: "hand.raised") }
                        } label: {
                            ProfileHeroStyle.chromeButton("ellipsis")
                        }
                        .accessibilityLabel("More")
                    })
            },
            avatar: {
                AvatarView(photo: athlete.avatarData, name: athlete.name,
                           size: ProfileHeroStyle.avatarSize,
                           imageName: athlete.communityAvatarAsset, preset: athlete.communityPreset)
            },
            pills: {
                // Follow is the page's one primary action (filled ink); once following it goes
                // quiet glass, exactly where "Edit profile" sits on your own page.
                Button { follows.toggle(athlete.handle); Haptics.light() } label: {
                    ProfileHeroStyle
                        .pill(following ? "Following" : "Follow", style: following ? .glass : .ink)
                }
                .buttonStyle(PressableScaleStyle(scale: 0.97))
                .accessibilityLabel(following ? "Following \(athlete.name). Tap to unfollow." : "Follow \(athlete.name)")
                // Nudge: a mutual with no ring today (they haven't trained) can be nudged once.
                // Care, not pressure — it never appears on someone who already moved today.
                if following, !trainedToday, nudges.canNudge(athlete.handle, isSample: athlete.isSample) || nudges.nudgedToday(athlete.handle) {
                    let sent = nudges.nudgedToday(athlete.handle)
                    Button {
                        if !sent { nudges.nudge(athlete.handle, isSample: athlete.isSample, name: athlete.name) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: sent ? "checkmark" : "hand.wave.fill")
                                .font(.system(size: 14, weight: .semibold))
                            Text(sent ? "Nudged" : "Nudge")
                        }
                        .font(.rounded(Theme.FontSize.body, weight: .semibold))
                        .foregroundStyle(sent ? Theme.inkTertiary : Theme.ink)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .momentumGlass()
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PressableScaleStyle(scale: 0.97))
                    .disabled(sent)
                    .accessibilityLabel(sent ? "Nudged \(athlete.name) today" : "Nudge \(athlete.name)")
                }
            })
    }

    /// Sample counts come from the SHARED derivation (`sampleFollowerCount` — the same numbers
    /// size the pushed lists, so tapping "141 Followers" opens a list of exactly 141), plus the
    /// viewer's own follow. Real athletes: their ACTUAL audience (`remoteCounts`, which the
    /// server computed excluding the viewer) plus the same +mine — so following anyone, fake or
    /// real, moves their number in the same frame, and unfollowing takes it back.
    /// Blocked athletes are subtracted, because the LIST behind this number already drops them
    /// (`AthleteFollowListView`). "141 Followers" opening a list of 140 rows is the same small lie
    /// as a grid that doesn't add up to its own header — the number has to describe the list under
    /// it (found 2026-08-29). The fast path skips the walk entirely when nothing is blocked, which
    /// is almost always; `CommunityGraph.followerHandles` is cached per athlete either way.
    private var followerCount: Int {
        let mine = follows.isFollowing(athlete.handle) ? 1 : 0
        guard athlete.isSample else { return (remoteCounts?.followers ?? 0) + mine }
        guard !moderation.blockedHandles.isEmpty else { return athlete.sampleFollowerCount + mine }
        return CommunityGraph.followerHandles(of: athlete.handle)
            .filter { !moderation.isBlocked($0) }.count + mine
    }

    private var followingCount: Int {
        guard athlete.isSample else { return remoteCounts?.following ?? 0 }
        guard !moderation.blockedHandles.isEmpty else { return athlete.sampleFollowingCount }
        return CommunityGraph.followingHandles(of: athlete.handle)
            .filter { !moderation.isBlocked($0) }.count
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
            CommunityFeedGrid(items: gridPosts, zoomNamespace: nil, onTileAppear: { index in
                // Continuous scroll: three rows from the bottom, materialize the next page. The
                // grid IS their body of work, so scrolling far enough reaches every session the
                // trio counts — a veteran's 900th tile is real, it just isn't built until asked
                // for. Guarded on the count actually growing, so the last page can't loop.
                guard index >= gridPosts.count - 9 else { return }
                let next = CommunityDirectory.gridPosts(
                    for: athlete, limit: gridPosts.count + CommunityDirectory.gridPageSize)
                if next.count > gridPosts.count { gridPosts = next }
            }) { id in
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
        /// The one fold over the athlete's session ledger — every number on this page comes out
        /// of it, including the hero trio's.
        let lifetime: CommunityLifetime
        let awardCells: [AwardsShelf.Cell]
        let awardsEarned: Int
    }
    private final class DerivedMemo { var key = ""; var value: DerivedStats? }
    @State private var derivedMemo = DerivedMemo()
    private var derived: DerivedStats {
        let key = "\(athlete.handle)-\(StreakCalculator.localDay(Date()))"
        if derivedMemo.key == key, let cached = derivedMemo.value { return cached }
        let awards = athlete.communityAwards
        let value = DerivedStats(lifetime: athlete.lifetime,
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
        let life = derived.lifetime
        return section("Lifetime") {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    if athlete.primaryType.isGPS, life.distanceM > 0 {
                        CountUpNumber(value: life.distanceM,
                                      format: { Formatters.distance(meters: $0, unit: distanceUnit) },
                                      font: .display(40, weight: .black))
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .accessibilityLabel("Distance covered")
                            .accessibilityValue(Formatters.distance(meters: life.distanceM, unit: distanceUnit))
                        Text("distance covered")
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    } else {
                        CountUpNumber(value: Double(life.sessions),
                                      format: { "\(Int($0.rounded()))" },
                                      font: .display(40, weight: .black))
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .accessibilityLabel("Workouts logged")
                            .accessibilityValue("\(life.sessions)")
                        Text("workouts logged")
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    }
                }
                PenRule(delay: 0.3)
                HStack(spacing: 0) {
                    // Lifetime, like every other number in this block — derived from distance +
                    // session mix so it can never contradict them (see `lifetimeDurationS`).
                    lifetimeCell(Formatters.duration(s: life.durationS), "Time moving")
                    lifetimeDivider
                    lifetimeCell("\(life.sessions)", "Sessions")
                    if life.streakDays > 0 {
                        lifetimeDivider
                        lifetimeCell("\(life.streakDays)", "Day streak")
                    }
                }
            }
        }
    }

    private var trainSection: some View {
        section("How they train") {
            DisciplineBreakdown(counts: derived.lifetime.typeCounts)
                .padding(Theme.Space.lg).background(card)
        }
    }

    /// The same headlined consistency card as the own profile: the one number that summarizes the
    /// grid, then the full heatmap with month/weekday axes.
    private var consistencySection: some View {
        let today = StreakCalculator.localDay(Date())
        let days = derived.lifetime.activeDays   // once — the old closure regenerated the Set 112×
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
                                   dayMinutes: derived.lifetime.dayMinutes, showsAxes: true)
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
        Color.clear.raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}



