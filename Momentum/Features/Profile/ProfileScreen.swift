import SwiftUI
import SwiftData

/// The athlete's dedicated Profile tab (docs/SOCIAL-LAYER.md) — the public projection of who they
/// are, now a first-class destination rather than a push off Progress. Identity → headline counts →
/// lifetime body-of-work (discipline mix, consistency grid, trophy case) → recent shared activities,
/// with Edit + privacy and Settings in the header. Visiting another athlete reuses the same body via
/// `AthleteProfileView`.
///
/// **There is exactly ONE instance of this screen: the Profile tab root** (2026-07-30). It used to
/// take `showsBackButton` / `onClose` so Today's header avatar could push or sheet its own copy —
/// and those flags gated the Profile ↔ Community slider off, so the copy was a strictly lesser
/// profile. Every entry point now selects the tab (`AppRouter.pendingTab = .profile`); if a new
/// surface needs to reach the profile, route it there too rather than re-adding a variant.
struct ProfileScreen: View {
    @Query private var profiles: [UserProfile]
    @Query(sort: \Workout.startedAt, order: .reverse) private var workouts: [Workout]
    /// PR shelf — tiles whose workout holds a current record carry the earned iridescent mark.
    @Query private var records: [PersonalRecord]
    /// The awards ledger — feeds the Highlights trophy case and the gallery push.
    @Query private var earnedAwards: [EarnedAward]
    @Environment(PaywallController.self) private var paywall
    @Environment(FollowStore.self) private var follows
    @Environment(Services.self) private var services
    @Environment(\.modelContext) private var context

    /// The athlete's REAL follower count, refreshed from the backend per appearance. Stays 0 for
    /// guests/offline — a brand-new community account genuinely has no followers yet, and this
    /// line never fabricates on your own profile.
    @State private var followerCount = 0
    @State private var editing = false
    @State private var showingAwards = false
    #if DEBUG
    /// `--following-list`: push the follow graph for screenshot verification (the social line is
    /// a tap target simctl can't reliably hit).
    @State private var showingFollowList = false
    #endif
    // Persisted rather than @State so the Grid/Highlights face the athlete chose is still the one
    // they get on the next launch (it dates from the era of two live instances, where per-instance
    // @State meant picking Highlights on the tab and then seeing Grid again via Today's avatar).
    @AppStorage("com.momentum.profile.gridTab") private var gridTabRaw = ProfileGridTab.grid.rawValue
    private var gridTab: Binding<ProfileGridTab> {
        Binding(get: { ProfileGridTab(rawValue: gridTabRaw) ?? .grid },
                set: { gridTabRaw = $0.rawValue })
    }
    @State private var immersive: ImmersiveStart?
    /// Drives the grid-tile → pager zoom (the Instagram open). Tiles register as
    /// `matchedTransitionSource` under their workout id; the cover zooms from whichever was tapped.
    @Namespace private var tileZoom
    #if DEBUG
    // One-shot for --awards-gallery (static: both ProfileScreen instances share it, and the
    // auto-push must never re-arm on the onAppear that follows popping the gallery).
    @MainActor private static var didAutoOpenAwards = false
    #if DEBUG
    @MainActor private static var didAutoOpenFollowList = false
    #endif
    // --share-card: open the share composer on the latest workout for sim verification.
    @State private var debugSharing = ProcessInfo.processInfo.arguments.contains("--share-card")
    // --analytics-lab: preview the Pro Trends analytics section in isolation for sim verification.
    @State private var debugAnalytics = ProcessInfo.processInfo.arguments.contains("--analytics-lab")
    #endif

    private var profile: UserProfile? { profiles.first }

    // Cached per data change — as computed vars these walked every workout (and its sets) on every
    // property access, and the body touches them repeatedly. The fallback keeps the first frame
    // correct before the refresh task lands.
    @State private var cachedStats: ProfileStats?
    @State private var cachedShelf: AwardsShelf?
    /// Memo for the PRE-task fallback: the first body pass reads `stats`/`awardsShelf` several
    /// times across the header, grid, and highlights sections — each access re-walked the full
    /// history before `refreshAggregates()` landed, all on the main actor before the first frame.
    /// A plain reference box (fields not observed), so filling it mid-body is invisible to SwiftUI.
    private final class FallbackMemo {
        var count = -1
        var stats: ProfileStats?
        var shelf: AwardsShelf?
    }
    @State private var memo = FallbackMemo()
    /// PR-marked workout ids, memoized per records change — the inline `Set(records.compactMap
    /// { $0.workout?.id })` faulted every PersonalRecord's workout relationship on every body pass.
    private final class PRMemo {
        var count = -1
        var ids: Set<UUID> = []
    }
    @State private var prMemo = PRMemo()
    private var prWorkoutIds: Set<UUID> {
        if prMemo.count != records.count {
            prMemo.count = records.count
            prMemo.ids = Set(records.compactMap { $0.workout?.id })
        }
        return prMemo.ids
    }
    /// The signature the grid keys on — snapshotted by the aggregate task rather than recomputed
    /// as a second full-table walk in every body pass.
    @State private var signatureSnapshot = 0
    /// Cheap content signature over already-materialized scalars. Keying the caches on COUNT
    /// alone missed equal-count changes (edit a saved workout's sport on the save screen, or
    /// delete one + import another): lifetime totals, discipline mix, and month grouping stayed
    /// stale until the count next moved. Scalars only — no relationship faulting.
    private var workoutsSignature: Int {
        var h = Hasher()
        h.combine(workouts.count)
        for w in workouts {
            h.combine(w.startedAt)
            h.combine(w.type.rawValue)
            h.combine(w.durationS)
        }
        return h.finalize()
    }

    private var stats: ProfileStats {
        if let cachedStats { return cachedStats }
        let sig = workoutsSignature
        if memo.count != sig { memo.count = sig; memo.stats = nil; memo.shelf = nil }
        if let s = memo.stats { return s }
        let s = ProfileStats(workouts: workouts, plan: profile?.plan)
        memo.stats = s
        return s
    }
    private var awardsShelf: AwardsShelf {
        if let cachedShelf { return cachedShelf }
        let sig = workoutsSignature
        if memo.count != sig { memo.count = sig; memo.stats = nil; memo.shelf = nil }
        if let s = memo.shelf { return s }
        let s = AwardsShelf(earned: earnedAwards,
                            snapshot: AwardsBook.snapshot(workouts: workouts, records: records,
                                                          plan: profile?.plan))
        memo.shelf = s
        return s
    }

    @State private var aggregatedForCount = -1   // matches the count the caches were built for
    @State private var shelfForAwardCount = -1   // awards can land without a new workout (plan check-offs)

    private func refreshAggregates() {
        cachedStats = ProfileStats(workouts: workouts, plan: profile?.plan)
        // Fetch the earned rows directly — when this runs right after a sync, the @Query array
        // can still be the pre-sync capture and the just-earned coin would miss the shelf.
        let earnedRows = (try? context.fetch(FetchDescriptor<EarnedAward>())) ?? Array(earnedAwards)
        cachedShelf = AwardsShelf(earned: earnedRows,
                                  snapshot: AwardsBook.snapshot(workouts: workouts, records: records,
                                                                plan: profile?.plan))
    }
    private var weightUnit: WeightUnit { WeightUnit(rawValue: profile?.weightUnit ?? "kg") ?? .kg }
    private var distanceUnit: DistanceUnit { DistanceUnit(rawValue: profile?.distanceUnit ?? "auto") ?? .auto }

    /// A tapped tile/highlight to open the immersive pager on (Identifiable for `.fullScreenCover(item:)`).
    private struct ImmersiveStart: Identifiable { let id: UUID }

    // MARK: Profile ↔ Community

    /// Which face of the page is showing — the athlete's own profile, or the community feed that
    /// lives behind the header slider (owner call 2026-07-29: community returns INSIDE Profile,
    /// not as a tab). `.you` is the resting state; the slider only renders when
    /// `CommunityAccess.enabled`, so the solo app cannot even represent the second face.
    private enum ProfileFace: String, CaseIterable {
        case you = "Profile", community = "Community"
    }
    @State private var face: ProfileFace = {
        #if DEBUG
        // --profile-community: launch on the feed face for sim verification. Seeded at init, not
        // onAppear — the profile face's onAppear re-fires every time the slider comes back to
        // Profile, and an onAppear hook would bounce the athlete straight back to Community.
        if ProcessInfo.processInfo.arguments.contains("--profile-community") { return .community }
        #endif
        return .you
    }()
    /// The community face's in-place athlete search — toggled by the header magnifier, rendered by
    /// the embedded `CommunityView` (which owns the results list and the athlete push).
    @State private var communitySearching = false
    /// Face switches route through here so the capsule's pill slide and the page crossfade share
    /// one animation — the default transition for a structural swap is exactly the fade we want.
    /// Leaving Community always closes the search face; coming back starts at the wall.
    private var faceBinding: Binding<ProfileFace> {
        Binding(get: { face },
                set: { new in
                    if new == .you { communitySearching = false }
                    withAnimation(.easeOut(duration: 0.22)) { face = new }
                })
    }

    var body: some View {
        Group {
            if CommunityAccess.enabled, face == .community {
                // The community wall wearing this screen's chrome: ProfileScreen's header
                // (magnifier + slider + gear) stacks above the grid's own Friends | Global tabs.
                CommunityView(searching: $communitySearching)
                    .safeAreaInset(edge: .top) { header }
            } else {
                profileBody
            }
        }
        // The REAL follower count, refreshed whenever the screen appears (a follow-back can land
        // any time). Guests/offline keep the honest 0 — `followCounts` returns nil, not a guess.
        .task {
            guard CommunityAccess.enabled else { return }
            if let counts = await services.social.followCounts() {
                followerCount = counts.followers
            }
        }
    }

    private var profileBody: some View {
        ScrollViewReader { scroll in
        ScrollView {
            // The Grid / Highlights toggle scrolls WITH the content — no `pinnedViews`, so it rides
            // just above the grid and moves off-screen as you scroll (user preference 2026-07-22),
            // rather than sticking under the profile header as a mini-header.
            LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                Group {
                    identity
                    if let profile, !profile.bio.isEmpty {
                        // Centered under the identity block, TikTok-style (owner call 2026-07-30) —
                        // matches the community athlete pages so the two profile faces stay twins.
                        Text(profile.bio)
                            .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Theme.Space.md)

                if stats.totalWorkouts == 0 {
                    firstRunCard
                        .padding(.horizontal, Theme.Space.md)
                } else {
                    // The grid rides high — the athlete's training is the hero. Lifetime totals,
                    // discipline mix, and consistency live one tap away under "Highlights". The
                    // toggle and grid are plain siblings (no Section header) so the bar scrolls with
                    // the tiles instead of pinning.
                    // One child, not two: as siblings the parent's 24pt spacing sat between the tab
                    // bar and the first tile row, which reads as a gap in the wall now that the
                    // mosaic is edge to edge. Instagram's tab strip sits a hair above its grid.
                    VStack(spacing: 0) {
                        ProfileGridTabBar(tab: gridTab)
                        ProfileGrid(workouts: workouts, stats: stats, awardsShelf: awardsShelf, dataKey: signatureSnapshot,
                                    weightUnit: weightUnit, distanceUnit: distanceUnit, tab: gridTab.wrappedValue,
                                    prWorkoutIds: prWorkoutIds,
                                    onOpen: { id in immersive = ImmersiveStart(id: id) },
                                    onOpenAwards: { showingAwards = true },
                                    zoomNamespace: tileZoom)
                    }
                }
            }
            .padding(.top, Theme.Space.md)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationBarHidden(true)
        .safeAreaInset(edge: .top) { header }
        #if DEBUG
        // --profile-scroll-badges: bring the trophy case on screen for sim verification.
        .onAppear {
            // --profile-highlights: open on the Highlights face for sim verification (the tab
            // choice is @AppStorage-shared now, so the arg forces it rather than seeding init).
            if ProcessInfo.processInfo.arguments.contains("--profile-highlights") {
                gridTabRaw = ProfileGridTab.highlights.rawValue
            }
            if ProcessInfo.processInfo.arguments.contains("--profile-scroll-badges") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation { scroll.scrollTo("profile-badges", anchor: .top) }
                }
            }
            // --awards-gallery: push the full trophy room for sim verification. Once per process:
            // onAppear re-fires when the gallery pops back to the profile, and re-arming the push
            // here trapped the back button in a loop (pop → 0.8s → pushed right back in).
            if ProcessInfo.processInfo.arguments.contains("--awards-gallery"), !Self.didAutoOpenAwards {
                Self.didAutoOpenAwards = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { showingAwards = true }
            }
            // --profile-edit: open the edit sheet (preset-avatar strip verification — the Edit
            // button is unreachable by simctl).
            if ProcessInfo.processInfo.arguments.contains("--profile-edit") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { editing = true }
            }
            // --following-list: push the follow graph. One-shot for the same reason the awards
            // gallery is: re-arming on the pop traps the back button in a loop.
            if ProcessInfo.processInfo.arguments.contains("--following-list"), !Self.didAutoOpenFollowList {
                Self.didAutoOpenFollowList = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { showingFollowList = true }
            }
            // --profile-open-run: open the immersive pager on the first GPS workout — the
            // route-fit camera can only be verified inside the real pager (its lazy sizing is
            // exactly what the initialViewport race needed).
            if ProcessInfo.processInfo.arguments.contains("--profile-open-run") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if let run = workouts.first(where: { $0.type.isGPS && ($0.gps?.distanceM ?? 0) > 0 }) {
                        immersive = ImmersiveStart(id: run.id)
                    }
                }
            }
            // --profile-open-strength: pager on the first strength workout — the muscle-map page's
            // IridescentWash backdrop is only verifiable full-bleed, in both schemes.
            if ProcessInfo.processInfo.arguments.contains("--profile-open-strength") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if let lift = workouts.first(where: { $0.strength != nil }) {
                        immersive = ImmersiveStart(id: lift.id)
                    }
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--profile-scroll-consistency") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation { scroll.scrollTo("profile-consistency", anchor: .bottom) }
                }
            }
        }
        #endif
        }
        .sheet(isPresented: $editing) { if let profile { EditProfileView(profile: profile) } }
        #if DEBUG
        .sheet(isPresented: $debugSharing) {
            if let latest = workouts.first(where: { $0.gps != nil }) ?? workouts.first {
                ShareCardView(workout: latest, weightUnit: weightUnit, distanceUnit: distanceUnit)
            }
        }
        .sheet(isPresented: $debugAnalytics) {
            ScrollView {
                VStack(spacing: Theme.Space.lg) {
                    ProTrendsSection(workouts: workouts, distanceUnit: distanceUnit)
                    StrengthProgressSection(workouts: workouts, weightUnit: weightUnit)
                }
                .padding(Theme.Space.md)
            }
            .background(Theme.background)
            // --metric-info: auto-open a detail sheet to verify the "how it's calculated" design.
            .overlay {
                if ProcessInfo.processInfo.arguments.contains("--metric-info") {
                    Color.clear.sheet(isPresented: .constant(true)) {
                        MetricDetailSheet(explainer: MetricExplainers.fitnessFreshness)
                            .presentationDetents([.medium, .large])
                    }
                }
            }
        }
        #endif
        .task(id: workoutsSignature) {
            // Award sync first, every visit: new awards can land without a new workout (a plan
            // week checked off, a Health import elsewhere). No-ops when nothing changed.
            AwardsBook.sync(in: context)
            // The @Query array was captured BEFORE the sync above — an award earned by this very
            // visit wouldn't be in `earnedAwards.count` yet, and the shelf would miss it until
            // the next visit. Count the store directly instead.
            let earnedCount = (try? context.fetchCount(FetchDescriptor<EarnedAward>()))
                ?? earnedAwards.count
            // .task(id:) re-fires on every tab visit; the stats walk only needs to re-run
            // when the data actually moved — re-walking per switch read as tab-change jank.
            let sig = workoutsSignature
            signatureSnapshot = sig   // the grid's dataKey — never recomputed in body
            guard aggregatedForCount != sig || shelfForAwardCount != earnedCount
            else { return }
            refreshAggregates()
            aggregatedForCount = sig
            shelfForAwardCount = earnedCount
        }
        .navigationDestination(isPresented: $showingAwards) { AwardsGalleryView() }
        #if DEBUG
        .navigationDestination(isPresented: $showingFollowList) { FollowingListView() }
        #endif
        .fullScreenCover(item: $immersive) { start in
            ImmersiveWorkoutPager(workouts: workouts, startID: start.id,
                                  weightUnit: weightUnit, distanceUnit: distanceUnit,
                                  // Your own byline over your own media — the grid tile stays
                                  // chip-free, but opened content names its author like every
                                  // community post does (owner call 2026-07-30).
                                  byline: WorkoutByline(profile: profile,
                                                        isPro: paywall.isEntitled(to: .fullPlan)))
                // The zoom grows out of the tapped tile and settles back into it on dismiss —
                // keyed on the workout id (never a grid index; LazyVGrid reorders). The persisted
                // snapshot is the same artwork on both sides, which is what makes it read as one
                // object changing size. Reduce Motion degrades to a crossfade for free.
                .navigationTransition(.zoom(sourceID: start.id, in: tileZoom))
        }
    }

    // MARK: Header (custom — matches Progress/World)

    /// Quiet chrome only — no screen title. The athlete's name IS the page title; a "Profile"
    /// headline above it just said the same thing twice.
    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            // No back chevron: this is a tab root, always. (It used to carry one for the pushed
            // Today-avatar copy — see the type doc.)
            // The community face's subtle search entry (owner ask 2026-07-29): a quiet magnifier in
            // the leading slot that opens the in-place search bar.
            if CommunityAccess.enabled, face == .community {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { communitySearching = true }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Search athletes")
            }
            Spacer()
            NavigationLink { SettingsView() } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.xs).padding(.bottom, Theme.Space.xs)
        .overlay {
            // Profile ↔ Community — the top-center slider (owner call 2026-07-29). An overlay so
            // the magnifier/gear row's layout never shifts when community flips on; centered in
            // the full row, exactly where a navigation title would sit.
            if CommunityAccess.enabled {
                SegmentedCapsule(items: ProfileFace.allCases, selection: faceBinding,
                                 scale: .compact) { $0.rawValue }
            }
        }
        .background(Theme.background)
    }

    // MARK: Identity

    private var identity: some View {
        VStack(spacing: Theme.Space.md) {
            VStack(spacing: Theme.Space.sm) {
                AvatarView(photo: profile?.avatarData, name: displayName, size: 76)
                // The edit affordance lives LITERALLY under the photo it edits (owner call
                // 2026-07-29), and quietly — caption scale, tertiary ink, hairline. The identity
                // below is the content; this is just the door.
                Button { editing = true } label: {
                    Text("Edit profile")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .padding(.horizontal, Theme.Space.md)
                        .padding(.vertical, 5)
                        .background(Capsule().stroke(Theme.hairline, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableScaleStyle(scale: 0.97))
                .accessibilityLabel("Edit profile")
            }
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName).font(.display(26, weight: .black)).foregroundStyle(Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)   // long names shrink; the seal stays put
                    // Verified Pro — the same checkmark the feed shows everyone else.
                    if paywall.isEntitled(to: .fullPlan) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Theme.purple)
                            .accessibilityLabel("Verified Pro")
                    }
                }
                // The @handle — the identity the community knows you by (claimed at onboarding,
                // changeable in Edit Profile), in exactly the position athlete pages show theirs,
                // with your optional location beside it in their exact grammar (dot + pin). Blank
                // until you fill it in: nobody gets placed by a default.
                HStack(spacing: 6) {
                    let handle = profile?.handle ?? ""
                    if !handle.isEmpty {
                        Text("@\(handle)")
                            .font(.rounded(Theme.FontSize.body, weight: .semibold))
                            .foregroundStyle(Theme.inkTertiary)
                    }
                    if let location = profile.flatMap(SocialPrivacy.publicLocation) {
                        if !handle.isEmpty {
                            Circle().fill(Theme.inkTertiary).frame(width: 2.5, height: 2.5)
                        }
                        Label(location, systemImage: "mappin.and.ellipse")
                            .font(.rounded(Theme.FontSize.caption, weight: .medium))
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
            }
            // Followers · Following returned with the community launch (owner call 2026-07-29,
            // reversing the solo-era removal) and sits ABOVE the athletic trio (owner call, same
            // day — the social identity leads, the training ledger follows). A quiet, tappable
            // line; the numbers are REAL (the local follow set; followers stay 0 until the
            // backend serves a true list — never fabricated on your own profile).
            if CommunityAccess.enabled {
                NavigationLink { FollowingListView() } label: {
                    HStack(spacing: 5) {
                        Text("\(followerCount)").font(.rounded(Theme.FontSize.body, weight: .bold))
                            .monospacedDigit().foregroundStyle(Theme.ink)
                        Text("Followers").font(.rounded(Theme.FontSize.body, weight: .medium))
                            .foregroundStyle(Theme.inkTertiary)
                        Circle().fill(Theme.inkTertiary).frame(width: 2.5, height: 2.5)
                        Text("\(follows.following.count)").font(.rounded(Theme.FontSize.body, weight: .bold))
                            .monospacedDigit().foregroundStyle(Theme.ink)
                        Text("Following").font(.rounded(Theme.FontSize.body, weight: .medium))
                            .foregroundStyle(Theme.inkTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(followerCount) followers, \(follows.following.count) following")
            }
            statTrio
        }
        .frame(maxWidth: .infinity)
    }

    /// The athlete's own ledger (solo-first, 2026-07-16 — followers/following left with the
    /// community back-burner): volume, distance, achievement. Bare numbers on the canvas,
    /// hairline-divided — no boxed card competing with the grid below.
    private var statTrio: some View {
        HStack(spacing: 0) {
            trioCell("\(stats.totalWorkouts)", "Workouts")
            trioDivider
            trioCell(distanceTotalText, distanceUnitLabel)
            trioDivider
            trioCell("\(records.count)", "PRs")
        }
        .padding(.horizontal, Theme.Space.xl)
    }

    /// Lifetime GPS distance in the athlete's display unit, whole numbers ("312").
    private var distanceTotalText: String {
        let perUnit = distanceUnit.resolved() == .imperial ? Formatters.metersPerMile : 1000.0
        return "\(Int((stats.totalDistanceM / perUnit).rounded()))"
    }
    private var distanceUnitLabel: String {
        distanceUnit.resolved() == .imperial ? "Miles" : "Kilometers"
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

    private var displayName: String {
        let name = profile?.displayName.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "Athlete" : name
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
