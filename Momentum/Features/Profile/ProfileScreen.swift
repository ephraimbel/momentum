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
    @Environment(AppRouter.self) private var router   // the empty state's one door: Today

    /// The athlete's REAL follower count, refreshed from the backend per appearance. Stays 0 for
    /// guests/offline — a brand-new community account genuinely has no followers yet, and this
    /// line never fabricates on your own profile.
    @State private var followerCount = 0
    @State private var editing = false
    @State private var showingAwards = false
    /// Pushes the follow graph — from the hero's followers line, or `--following-list` in DEBUG.
    @State private var showingFollowList = false
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
    // Armed AFTER the launch beat (see onAppear): set at init it raced the first-run priming /
    // recovery dialog for the presentation slot and lost silently ("while a presentation is in
    // progress").
    @State private var debugSharing = false
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
    /// Last time the follower count was fetched — the call is a network round trip, throttled here.
    @MainActor private static var lastFollowCountsFetch = Date.distantPast

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
                    .safeAreaInset(edge: .top, spacing: 0) { header }
            } else {
                profileBody
            }
        }
        // The REAL follower count, refreshed whenever the screen appears (a follow-back can land
        // any time). Guests/offline keep the honest 0 — `followCounts` returns nil, not a guess.
        .task {
            #if DEBUG
            // --seed-follows-active: the screenshot-run "established account" — a plausible
            // follower count to pair with the seeded following slice. DEBUG-only fiction; the
            // shipping path below never fabricates.
            if ProcessInfo.processInfo.arguments.contains("--seed-follows-active") {
                followerCount = 1_284
                return
            }
            #endif
            guard CommunityAccess.enabled else { return }
            // Throttled: this is a network round trip and the task re-fires on every appearance
            // of the tab — once a minute is plenty for a follow-back to land (perf audit 2026-08-13).
            let now = Date()
            guard now.timeIntervalSince(Self.lastFollowCountsFetch) > 60 else { return }
            Self.lastFollowCountsFetch = now
            if let counts = await services.social.followCounts() {
                followerCount = counts.followers
            }
        }
        .onAppear(perform: routeToCommunityIfNeeded)
        .onChange(of: router.pendingCommunityPostID) { _, _ in routeToCommunityIfNeeded() }
        .onChange(of: router.pendingCommunityAthleteHandle) { _, _ in routeToCommunityIfNeeded() }
    }

    private func routeToCommunityIfNeeded() {
        guard CommunityAccess.enabled,
              router.pendingCommunityPostID != nil || router.pendingCommunityAthleteHandle != nil
        else { return }
        communitySearching = false
        if face != .community {
            withAnimation(.easeOut(duration: 0.2)) { face = .community }
        }
    }

    /// First-visit skeleton (ProgressScreen's `warmup` pattern, perf audit 2026-08-13): before the
    /// aggregate task fills `cachedStats`, `body` used to build ProfileStats AND the awards
    /// snapshot inline on the tab-switch frame — the full-history walk as the price of the first
    /// paint. Quiet surface shapes hold the canvas for the one beat the task needs.
    private var profileWarmup: some View {
        VStack(spacing: Theme.Space.lg) {
            Circle().fill(Theme.surface).frame(width: 96, height: 96)
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface).frame(height: 64)
                .padding(.horizontal, Theme.Space.xl)
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface).frame(height: 420)
        }
        .padding(.top, Theme.Space.md)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.opacity)
    }

    private var profileBody: some View {
        ScrollViewReader { scroll in
        ScrollView {
            if cachedStats == nil && !workouts.isEmpty {
                profileWarmup
            } else {
            // The Grid / Highlights toggle scrolls WITH the content — no `pinnedViews`, so it rides
            // just above the grid and moves off-screen as you scroll (user preference 2026-07-22),
            // rather than sticking under the profile header as a mini-header.
            LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                // Everything above the grid is the identity block (owner call 2026-08-25: the
                // Share Aura structure in our theme — media cover, left-aligned PFP with the 24h
                // ring, trio beside it, name/handle/bio, chips, two pills). It runs edge to edge
                // so the cover can sit under the status bar; the grid below is untouched.
                identity

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
            .padding(.bottom, Theme.Space.xxl)
            }
        }
        .background(Theme.background)
        .navigationBarHidden(true)
        .safeAreaInset(edge: .top, spacing: 0) { header }
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
            if ProcessInfo.processInfo.arguments.contains("--share-card") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { debugSharing = true }
            }
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
            // Let the tab-switch transition land first — this task's first synchronous chunk used
            // to run inside it (perf audit 2026-08-13). Cancellation (data changed mid-sleep,
            // screen left) exits before any engine work.
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            // Award sync first, every visit: new awards can land without a new workout when a plan
            // week is checked off or award criteria change. No-ops when nothing changed.
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
        .navigationDestination(isPresented: $showingFollowList) { FollowingListView() }
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
    /// The top bar, shared by BOTH faces so the slider and the gear never move (owner, 2026-08-27:
    /// switching Profile ↔ Community made them "slightly move up and get smaller"). The two
    /// faces used to draw this through different code — the profile through the hero's chrome,
    /// the community through a bare 32pt row at a different inset — so they could not match.
    /// Now one `ProfileTopBar` at one inset, one control size, with only the leading slot
    /// swapping (share on the profile, search on the community); the capsule and the gear are
    /// literally the same views in the same frame across the flip.
    private var header: some View {
        ProfileTopBar(
            leading: {
                if face == .community {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { communitySearching = true }
                    } label: { ProfileHeroStyle.chromeButton("magnifyingglass", size: 17) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search athletes")
                } else if let card = shareCardImage {
                    ShareLink(item: card, preview: SharePreview("\(displayName) on Momentum", image: card)) {
                        ProfileHeroStyle.chromeButton("square.and.arrow.up")
                    }
                    .accessibilityLabel("Share profile")
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
            },
            center: {
                if CommunityAccess.enabled {
                    SegmentedCapsule(items: ProfileFace.allCases, selection: faceBinding,
                                     scale: .compact) { $0.rawValue }
                }
            },
            trailing: {
                NavigationLink { SettingsView() } label: {
                    ProfileHeroStyle.chromeButton("gearshape.fill", size: 17)
                }
                .accessibilityLabel("Settings")
            })
    }

    // MARK: Identity — the shared ProfileHero (twin of AthleteProfileView's)

    /// Shared inside the last 24 hours — the ring on the PFP. A private workout is training, but it
    /// is not a post and must never light a social presence indicator.
    private var postedToday: Bool {
        guard let w = workouts.first(where: SocialPrivacy.isShared) else { return false }
        let age = Date().timeIntervalSince(w.startedAt)
        return age >= 0 && age < 86_400
    }

    private var identity: some View {
        ProfileHero(
            ringed: postedToday,
            trio: [("\(stats.totalWorkouts)", "Workouts"), (distanceTotalText, distanceUnitLabel), ("\(records.count)", "PRs")],
            name: displayName,
            isPro: paywall.isEntitled(to: .fullPlan),
            handle: profile?.handle ?? "",
            location: profile.flatMap(SocialPrivacy.publicLocation),
            bio: profile?.bio ?? "",
            followLine: CommunityAccess.enabled
                ? .init(followers: followerCount, following: follows.following.count) { showingFollowList = true }
                : nil,
            chips: identityChips,
            chrome: { EmptyView() },   // the bar is `header`, shared with the community face
            avatar: { AvatarView(photo: profile?.avatarData, name: displayName, size: ProfileHeroStyle.avatarSize) },
            pills: {
                // One pill (owner call 2026-08-27): sharing already lives in the top-left chrome
                // button, so the second "Share profile" pill was the same door twice.
                Button { editing = true } label: { ProfileHeroStyle.pill("Edit profile") }
                    .buttonStyle(PressableScaleStyle(scale: 0.97))
                    .accessibilityLabel("Edit profile")
            })
    }

    /// Lifetime GPS distance in the athlete's display unit, whole numbers ("312").
    private var distanceTotalText: String {
        let perUnit = distanceUnit.resolved() == .imperial ? Formatters.metersPerMile : 1000.0
        return "\(Int((stats.totalDistanceM / perUnit).rounded()))"
    }
    private var distanceUnitLabel: String {
        distanceUnit.resolved() == .imperial ? "Miles" : "Kilometers"
    }

    /// Identity chips from data we already hold: the goal race (lavender — it is the thing
    /// happening) and the athlete's disciplines (neutral). Never filters, never a scroller.
    private var identityChips: [ProfileHeroStyle.Chip] {
        var chips: [ProfileHeroStyle.Chip] = []
        if let profile {
            if let m = profile.raceDistanceM, let date = profile.raceDate, date > Date() {
                let day = date.formatted(.dateTime.month(.abbreviated).day())
                chips.append(.init(id: "race", text: "\(RacePredictor.label(forRaceM: m)) · \(day)", accent: true))
            }
            for raw in profile.disciplines {
                guard let d = Discipline(rawValue: raw) else { continue }
                chips.append(.init(id: "d-\(raw)", text: d.rawValue.capitalized))
            }
        }
        return chips
    }

    /// The profile header as a Paper card, rendered on demand for the share sheet. Cached per
    /// (stats, name) so scrolling never re-renders it.
    @State private var shareCardCache: (key: Int, image: Image)?
    private var shareCardImage: Image? {
        var h = Hasher()
        h.combine(displayName); h.combine(stats.totalWorkouts); h.combine(records.count)
        h.combine(distanceTotalText)
        let key = h.finalize()
        if let c = shareCardCache, c.key == key { return c.image }
        let renderer = ImageRenderer(content: ProfileShareCard(
            name: displayName, handle: profile?.handle ?? "", avatar: profile?.avatarData,
            rows: [("\(stats.totalWorkouts)", "Workouts"), (distanceTotalText, distanceUnitLabel),
                   ("\(records.count)", "PRs")],
            chips: identityChips.map(\.text)))
        renderer.scale = 3
        guard let ui = renderer.uiImage else { return nil }
        let img = Image(uiImage: ui)
        DispatchQueue.main.async { shareCardCache = (key, img) }
        return img
    }

    /// Today's prescription, when the coach has written one — the empty state names it instead of
    /// asking for "a workout" from an athlete who already knows what today is.
    private var todaysPlannedBrief: String? {
        guard let plan = profile?.plan else { return nil }
        let cal = Calendar.current
        guard let session = plan.sessions.first(where: { cal.isDateInToday($0.date) }) else { return nil }
        return PlanCoaching.brief(for: session)
    }

    /// What the empty state's button says it will do — the planned sport, else a plain first run.
    private var firstRunTitle: String {
        guard let plan = profile?.plan else { return "Start your first workout" }
        let cal = Calendar.current
        guard let session = plan.sessions.first(where: { cal.isDateInToday($0.date) }) else {
            return "Start your first workout"
        }
        return "Start \(WorkoutType.forPlanned(session).title.lowercased())"
    }

    private var displayName: String {
        let name = profile?.displayName.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "Athlete" : name
    }

    // MARK: First-run (no workouts yet)

    /// The profile before the first workout — see `ProfileEmptyState`. It replaced a flat card
    /// with an icon and two lines of grey text (owner call 2026-08-28): the page's whole job on
    /// day one is to show what it will become and give exactly one way to begin.
    private var firstRunCard: some View {
        ProfileEmptyState(plannedBrief: todaysPlannedBrief, startTitle: firstRunTitle) {
            Haptics.medium()
            router.pendingTab = .today
        }
    }

    // MARK: Building blocks

    private var card: some View {
        Color.clear.raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}
