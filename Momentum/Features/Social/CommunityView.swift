import SwiftUI
import SwiftData

/// The Community tab (docs/SOCIAL-LAYER.md, 2026-07-09) — the feed stream, returned as a first-class
/// destination. Deliberately a *Substack-for-runners*, not a Strava clone: strictly
/// reverse-chronological, follow-scoped or clearly-badged community, one earned "respect" reaction,
/// flat comments, and nothing algorithmic. The athlete's own shared workouts + the badged seeded
/// community render locally (the offline/dark experience); real athletes' posts pull in through
/// `RemoteFeedStore` when the Supabase backend is configured and the athlete is signed in.
struct CommunityView: View {
    @Query(sort: \Workout.startedAt, order: .reverse) private var workouts: [Workout]
    @Query private var profiles: [UserProfile]
    /// Saved-route count for the wall strip's library door (the door hides at zero).
    @Query private var savedRoutes: [SavedRoute]
    @Environment(FollowStore.self) private var follows
    @Environment(NudgeStore.self) private var nudges
    @Environment(ModerationStore.self) private var moderation
    @Environment(RemoteFeedStore.self) private var remoteFeed
    @Environment(PaywallController.self) private var paywall
    @Environment(Services.self) private var services
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    /// Last `is_pro` value published to the backend — lets the entitlement-change hook below
    /// skip the initial appearance (launch's `claimProfile` already stamped it).
    @State private var lastPublishedPro: Bool?
    @AppStorage("community.feedScope") private var scopeRaw = CommunityScope.everyone.rawValue
    @State private var selectedAthlete: CommunityAthlete?
    /// "+N" on the following row pushes the full list. Its own destination TYPE: ProfileScreen
    /// already declares a `FollowingListView` destination on this stack, and SwiftUI ignores a
    /// second declaration for the same type further down.
    private struct FollowingPush: Identifiable, Hashable { let id = 0 }
    @State private var showingFollowing: FollowingPush?
    /// "Your day" with nothing shared today → share the latest workout (Aura's "select activity
    /// to share: Today"). The composer is the story composer.
    @State private var sharingToday: Workout?
    /// Fresh community posts minted by pull-to-refresh (CommunityPulse) — session-scoped.
    @State private var pulsed: [FeedItem] = []
    /// The in-place athlete-search face. Owned by the HOST (ProfileScreen's header magnifier
    /// toggles it) so chrome and content share one state; the empty state's "Find athletes"
    /// writes the same binding.
    @Binding private var searching: Bool
    /// A tapped tile → the community pager opens on it (Identifiable for `.fullScreenCover(item:)`).
    private struct PagerStart: Identifiable { let id: UUID }
    @State private var immersive: PagerStart?
    /// A ring tap: that person's day (posts in the last 24h, else their latest) in the pager.
    private struct StoryStart: Identifiable { let id: String; let items: [FeedItem] }
    @State private var story: StoryStart?
    /// Instagram-style progressive reveal (owner ask 2026-07-29): the wall renders a WINDOW of
    /// the assembled feed and grows it a page at a time when you reach the bottom — thousands of
    /// posts without ever materializing thousands of tiles.
    ///
    /// **The window is HELD, not re-sliced (2026-08-29).** The wall used to hand the grid
    /// `Array(items.prefix(visibleCount))` straight out of `body`, and `body` runs whenever the
    /// host re-evaluates — ProfileScreen's header, its own `@Query`, a slider animation — measured
    /// at 8–12 passes in the first second of a community open. Each pass copied up to a few hundred
    /// `FeedItem`s, every one carrying five strings and three arrays, to hand back a value that had
    /// not changed. `visibleCount` is now DERIVED from the window rather than driving it, so the
    /// count and the tiles can never disagree, and `reveal(_:)` is the only writer.
    @State private var window: [FeedItem]
    private var visibleCount: Int { window.count }
    /// The opening reveal — ten rows of the 3-wide grid.
    private static let firstWindow = 30
    /// One load = 12 posts — four rows of the 3-wide grid, the Instagram page (owner call
    /// 2026-07-30: "loads another twelve… just continuous"). Small pages keep each reveal
    /// imperceptible; the near-end prefetch below keeps them coming before the bottom is reached.
    private static let windowStep = 12
    /// How deep the Global well reaches into the assembled feed. It DEEPENS by `wellStep` whenever
    /// the reveal window catches up to it (owner ask 2026-07-30: the wall must never dead-end —
    /// reaching the bottom loads more, like pull-to-refresh in reverse); growth is demand-driven.
    ///
    /// **The opening cap is a TIME window, not a row budget (2026-08-28).** The community posts on
    /// a recency-weighted curve, so a 400-row well ended 3.4 hours back: every post the wall could
    /// reach was minutes old, every one of them therefore sat on the engagement model's immaturity
    /// floor, and the whole page read quiet no matter how far you scrolled. 1,200 rows is roughly
    /// the last 24 hours of a 2,863-athlete community — the same day the presence ring uses — so
    /// scrolling actually reaches posts that have had time to gather an audience.
    ///
    /// It is close to free: the assembly already sorts and moderation-filters the WHOLE seed before
    /// this cap is applied (the old comment claimed otherwise), the cap only bounds one array copy
    /// and the `spaced` pass, and the grid still realizes `visibleCount` tiles either way.
    @State private var wellCap = 1_200
    private static let wellStep = 400
    #if DEBUG
    /// --saved-routes: push the library directly (sim verification; the strip link needs a tap).
    @State private var debugSavedRoutes = false
    #endif
    /// Grid tile → pager zoom (the same Instagram open the profile grid ships).
    @Namespace private var tileZoom

    private var profile: UserProfile? { profiles.first }
    private var scope: CommunityScope { CommunityScope(rawValue: scopeRaw) ?? .everyone }

    // Hosted inside ProfileScreen behind the Profile ↔ Community slider (2026-07-29). The host's
    // header carries all identity chrome (slider, magnifier, gear), so this view is pure content:
    // the grid wall, the floating scope pill, and the pager. (The old `embedded` flag was stored
    // but never read — deleted 2026-07-30.)

    /// Once-per-process gate for the init-time debug writes below. A view INIT re-runs on every
    /// parent re-evaluation, and a UserDefaults write there fires KVO even when the value is
    /// unchanged — every `@AppStorage("community.feedScope")` reader invalidates, the tree
    /// re-evaluates, the parent re-inits this view, and the write fires again: a self-sustaining
    /// invalidation storm that saturated the main thread from launch (App body ~345 evals/sec,
    /// diagnosed 2026-07-29 via `_printChanges`; it presented as the "blank wall / frozen
    /// entrance / generic tab icon" launches). View inits must stay PURE — one-shot side effects
    /// only, and only behind this flag.
    @MainActor private static var didApplyLaunchArgs = false
    /// One-shot for the DEBUG athlete-profile hooks — see the `onAppear` note: this view's
    /// `onAppear` re-fires on every pop, so an unguarded hook re-pushes forever.
    @MainActor private static var didOpenDebugAthlete = false

    init(searching: Binding<Bool> = .constant(false)) {
        self._searching = searching
        _items = State(initialValue: Self.sessionFeed)
        _window = State(initialValue: Array(Self.sessionFeed.prefix(Self.firstWindow)))
        _assembledOnce = State(initialValue: !Self.sessionFeed.isEmpty)
        _latestByAuthor = State(initialValue: Self.sessionLatest)
        if !Self.didApplyLaunchArgs {
            Self.didApplyLaunchArgs = true
            // `--reset-social` starts UI tests from the default scope, like the social stores.
            SocialDebug.resetIfRequested(.standard, keys: ["community.feedScope"])
            #if DEBUG
            // --feed-global / --feed-friends: force a scope for sim verification — the scope is
            // @AppStorage (sticky across launches), and outside writes race cfprefsd; a ONE-SHOT
            // in-process write is the form that lands without looping (see didApplyLaunchArgs).
            if ProcessInfo.processInfo.arguments.contains("--feed-global") {
                UserDefaults.standard.set(CommunityScope.everyone.rawValue, forKey: "community.feedScope")
            }
            if ProcessInfo.processInfo.arguments.contains("--feed-friends") {
                UserDefaults.standard.set(CommunityScope.following.rawValue, forKey: "community.feedScope")
            }
            #endif
        }
    }

    /// Own workouts feeding the assembler — bounded so photo/route blobs of a long history never all
    /// materialize for one screen (older shared posts still live in Profile).
    private static let ownWorkoutCap = 50

    /// The assembled page, held in state. Assembly (map 50 workouts incl. photo blobs + merge/sort
    /// ~950 community items) is far too heavy to run per body evaluation — profiling showed the
    /// main thread saturated with `FeedItem` copies, which also starved accessibility (XCUITest
    /// timeouts). Rebuilt via `.task(id: feedKey)` only when an actual input changes.
    ///
    /// Seeded from the SESSION CACHE below: the slider tears this view down on every face switch,
    /// and re-assembling from empty made each return to Community open on a blank beat before the
    /// wall popped in ("feels glitchy" — owner report 2026-07-29). Stale-while-revalidate: last
    /// session's wall renders on the first frame, the task refreshes it in place.
    @State private var items: [FeedItem]
    @State private var assembledOnce: Bool
    /// The feedKey the assembly task last ran for — lets `onAppear` tell a genuine revisit apart
    /// from the first pass of a fresh instance (where assembling again would double the work).
    @State private var lastAssembledKey = ""
    /// Newest post per author, built with the feed — the ring row's only read of it.
    @State private var latestByAuthor: [String: Date]
    /// A real (non-seeded) athlete whose page is being fetched, and one whose fetch just failed —
    /// see `openAthlete`. Both drive `athleteResolveNote`.
    @State private var resolvingAthlete: String?
    @State private var unresolvedAthlete: String?
    /// A notification can point to an older own post outside the first remote feed page. Hold the
    /// directly resolved item for this Community visit so assembly and the pager use the same
    /// normal FeedItem path; at most one item is retained.
    @State private var deepLinkedPost: FeedItem?
    /// The revisit refresh, held so it can be cancelled — see the `onAppear` note below.
    @State private var revisitRefresh: Task<Void, Never>?
    /// Refresh ordering. `snapshotSeq` stamps each set of inputs as it is read; `appliedSeq` is the
    /// stamp of the newest one actually put on screen. Two refreshes can be in flight at once (the
    /// `.task(id:)` one and the `onAppear` revisit one) and they snapshot at different instants —
    /// without this, whichever detached build happened to finish last wrote, so a revisit that
    /// picked up a share-visibility change could be overwritten by an older snapshot that never saw
    /// it. A result older than what is already displayed is dropped, never applied.
    @State private var snapshotSeq = 0
    @State private var appliedSeq = 0
    @MainActor private static var sessionFeed: [FeedItem] = []
    @MainActor private static var sessionLatest: [String: Date] = [:]
    /// Presentation continuity is persisted per scope; this instance owns only the live bindings.
    private let experience = CommunityExperienceStore()
    @State private var wallAnchor: UUID?
    @State private var newBoundaryID: UUID?
    @State private var newPostCount = 0
    @State private var preparedScope: CommunityScope?

    /// Bounded change signature over every feed input; a change re-runs the assembly task. Counts
    /// alone are not enough: editing one existing post, swapping one followed handle for another,
    /// or refreshing a same-sized remote page must still rebuild the wall.
    /// `publicRouteMaps` is a term because own-post route visibility is decided AT assembly
    /// (`FeedAssembler` bakes `routeCoordinates` into the item): a feed assembled before the
    /// profile materialized — or before the routes-on migration ran — cached glyph posts that no
    /// count change would ever refresh.
    private var feedKey: String {
        "\(scopeRaw)|\(localFeedRevision)|\(pulseRevision)|\(remoteFeed.revision)|" +
        "\(setRevision(follows.following))|\(setRevision(moderation.blockedHandles))|" +
        "\(setRevision(moderation.reportedPosts))|\(wellCap)|" +
        "\(deepLinkedPost?.renderSignature ?? 0)"
    }

    /// A successful remote refresh changes the key and retries an unresolved offline lookup;
    /// changing notifications cancels the previous structured task immediately.
    private var pendingPostLookupKey: String {
        "\(router.pendingCommunityPostID?.uuidString ?? "none")|\(remoteFeed.revision)"
    }

    /// Scalars and relationship identities only. Modern photo bytes are intentionally represented
    /// by child ids/order, so a normal parent body pass never faults every album blob. The lone
    /// legacy blob uses the bounded media fingerprint (constant work, not a whole-JPEG hash), since
    /// it has no child identity that can otherwise signal same-sized replacement content.
    private var localFeedRevision: Int {
        Self.computeLocalFeedRevision(profile: profile,
                                      workouts: workouts.prefix(Self.ownWorkoutCap))
    }

    /// Internal for the regression fixture: map matching is an asynchronous same-row mutation,
    /// so its content identity must move this signature even when every relationship count stays
    /// unchanged.
    static func computeLocalFeedRevision<S: Sequence>(profile: UserProfile?, workouts: S) -> Int
    where S.Element == Workout {
        var h = Hasher()
        if let profile {
            h.combine(profile.displayName)
            h.combine(profile.handle)
            h.combine(profile.city)
            h.combine(profile.locationGranularity)
            h.combine(profile.publicRouteMaps)
            h.combine(profile.showExactNumbers)
            h.combine(MediaFingerprint.value(profile.avatarData))
            for record in profile.prs {
                h.combine(record.type)
                h.combine(record.value)
                h.combine(record.workout?.id)
            }
        }
        for workout in workouts {
            h.combine(workout.id)
            h.combine(workout.privacy)
            h.combine(workout.type)
            h.combine(workout.startedAt)
            h.combine(workout.durationS)
            h.combine(workout.title)
            h.combine(workout.note)
            h.combine(workout.aiSummary)
            h.combine(workout.coverIsPhoto)
            h.combine(MediaFingerprint.value(workout.photoData))
            for photo in workout.photos.sorted(by: { $0.order < $1.order }) {
                h.combine(photo.id)
                h.combine(photo.order)
            }
            h.combine(workout.gps?.distanceM)
            h.combine(workout.gps?.mapStyleRaw)
            // Map matching lands asynchronously after the workout row already exists. Include a
            // bounded content identity so same-sized raw inputs can still replace the tile's
            // route with the matched geometry without waiting for another unrelated feed change.
            h.combine(MediaFingerprint.value(workout.gps?.matchedRouteData))
            h.combine(workout.gps?.samples.count)
            h.combine(workout.strength?.exercises.count)
        }
        return h.finalize()
    }

    private var pulseRevision: Int {
        var h = Hasher()
        for item in pulsed {
            h.combine(item.id)
            h.combine(item.renderSignature)
        }
        return h.finalize()
    }

    private func setRevision(_ values: Set<String>) -> Int {
        var h = Hasher()
        for value in values.sorted() { h.combine(value) }
        return h.finalize()
    }

    /// Everything the assembly reads, as plain `Sendable` values.
    ///
    /// This exists so the assembly can leave the main actor (see `refreshFeed`). Only the first
    /// two fields need the main thread at all — the athlete's own SwiftData workouts and the live
    /// stores — and they are cheap; the expensive half (the 2,863-athlete directory behind
    /// `CommunityFeed.seed()`, a merge and sort over ~2,900 posts, and `spaced`) touches none of it.
    struct FeedInputs: Sendable {
        var own: [FeedItem] = []
        var pulsed: [FeedItem] = []
        var remote: [FeedItem] = []
        var following: Set<String> = []
        /// Snapshots of `ModerationStore` — see `isVisible`.
        var blocked: Set<String> = []
        var reported: Set<String> = []
        var scopeIsFollowing = false
        var wellCap = 1_200

        /// `ModerationStore.isVisible`, re-expressed over the snapshot. It has to be re-expressed
        /// rather than called, because the store is `@MainActor` and this runs off it —
        /// `MomentumTests/CommunityFeedAssemblySnapshotTests` pins the two to the same answer on
        /// every combination, so a change to the store can't silently leave this behind.
        func isVisible(_ item: FeedItem) -> Bool {
            !reported.contains(item.id.uuidString)
                && !(item.authorHandle.map(blocked.contains) ?? false)
        }
    }

    /// The main-actor half: read the SwiftData rows and the observable stores into values. Bounded
    /// and cheap — the athlete's own shared posts only, capped at `ownWorkoutCap`.
    @MainActor
    private func feedInputs() -> FeedInputs {
        let shared = workouts.lazy.filter { SocialPrivacy.isShared($0) }.prefix(Self.ownWorkoutCap)
        let isPro = paywall.isEntitled(to: .fullPlan)
        let contexts = FeedEarnedContext.resolve(workouts: workouts, records: profile?.prs ?? [])
        var remote = remoteFeed.items
        if let deepLinkedPost, !remote.contains(where: { $0.id == deepLinkedPost.id }) {
            remote.append(deepLinkedPost)
        }
        return FeedInputs(
            own: shared.map { FeedAssembler.item(from: $0, profile: profile, isPro: isPro,
                                                 earnedContext: contexts[$0.id]) },
            pulsed: pulsed,
            remote: remote,
            following: follows.following,
            blocked: moderation.blockedHandles,
            reported: moderation.reportedPosts,
            scopeIsFollowing: scope == .following,
            wellCap: wellCap)
    }

    /// Assembled once per relevant change (the community seed is ~2,900 athletes' posts — never
    /// filter per row). Moderation runs on the full stream so blocked athletes vanish from both
    /// scopes. Remote posts (real athletes, fetched per-scope so the *server's* follow graph gates
    /// them) merge on top; the local pipeline — including `FeedAssembler.scoped` — is unchanged.
    ///
    /// `nonisolated` and pure, so `refreshFeed` can run it off the main actor. That is the whole
    /// point: on a fresh install this call is the first thing in the process to touch
    /// `CommunityDirectory`, which builds 2,863 athletes and folds each one's whole training
    /// ledger. Measured on the main thread it froze the app for 881 ms — nothing drawn, no tap
    /// accepted — before the first tile could exist.
    nonisolated static func assembleFeed(_ input: FeedInputs) -> [FeedItem] {
        // Pulse posts (minted on pull-to-refresh) merge in ahead of the seed and re-sort — they're
        // minutes old, so they surface at the top exactly like a post that just landed.
        // The page caps at `wellCap`: the seed is thousands of athletes deep, and handing SwiftUI
        // a thousand-row grid bloats memory and grinds accessibility for a tail nobody scrolls to.
        // Follows are exempt from the cap (scoped from the FULL stream) so a followed athlete's
        // post never disappears behind it.
        // The base merge is already date-sorted — the re-sort (a second full pass over ~2,900 fat
        // structs) is only needed when pulse posts actually merged in.
        let base = (input.own + CommunityFeed.seed()).sorted { $0.date > $1.date }
        let assembled = (input.pulsed.isEmpty ? base : (input.pulsed + base).sorted { $0.date > $1.date })
            .filter(input.isVisible)
        let local = input.scopeIsFollowing
            ? FeedAssembler.scoped(assembled, following: input.following)
            : Array(assembled.prefix(input.wellCap))   // demand-deepened well; the WINDOW reveals it 30 at a time
        // Own published posts come back in the remote feed too — the local copy wins (it has the
        // full-resolution photos and needs no signing round trip).
        let localIDs = Set(local.map(\.id))
        let remote = input.remote.filter { !localIDs.contains($0.id) }.filter(input.isVisible)
        let merged = remote.isEmpty ? local : (local + remote).sorted { $0.date > $1.date }
        return spaced(merged)
    }

    /// The newest post per author, in ONE pass — what the Following ring row reads.
    ///
    /// `followedPeople` used to scan the whole assembled feed once per followed athlete, inside
    /// `body`. At 20 follows against a 1,200-post well that is 24,000 comparisons, re-run every
    /// time the wall's body ran — including every reveal of the next twelve tiles, i.e. constantly
    /// while scrolling. Built here instead, off the main actor, alongside the feed it summarises.
    nonisolated static func latestByAuthor(_ items: [FeedItem]) -> [String: Date] {
        var out: [String: Date] = [:]
        for item in items {
            guard let handle = item.authorHandle else { continue }
            if let seen = out[handle], seen >= item.date { continue }
            out[handle] = item.date
        }
        return out
    }

    /// Snapshot inputs on the main actor, assemble off it, hand the finished wall back. The wall
    /// keeps whatever it was already showing until the new one lands, so a refresh never blanks
    /// the page.
    @MainActor
    private func refreshFeed() async {
        let key = feedKey
        let input = feedInputs()
        snapshotSeq += 1
        let seq = snapshotSeq
        #if DEBUG
        let t0 = CFAbsoluteTimeGetCurrent()
        #endif
        let built = await CommunityFeedAssembly.build(key: key, input: input)
        // Two guards, and they answer different questions. `isCancelled` means "this view is gone"
        // (the athlete flipped away mid-build). `seq > appliedSeq` means "a newer snapshot already
        // landed" — the stale-writer race the two refresh paths could otherwise lose.
        guard !Task.isCancelled, seq > appliedSeq else {
            #if DEBUG
            if seq <= appliedSeq { CommunityPerf.mark("STALE refresh seq=\(seq) applied=\(appliedSeq) dropped") }
            #endif
            return
        }
        appliedSeq = seq
        #if DEBUG
        CommunityPerf.mark(String(format: "TIME assembleFeed %.1fms main=%@ (off-actor)",
                                  (CFAbsoluteTimeGetCurrent() - t0) * 1000,
                                  Thread.isMainThread ? "Y" : "N"))
        #endif
        // The very first fill replaces the skeleton, so the two crossfade rather than one
        // disappearing and the other arriving into the gap. Opacity only — a crossfade is what
        // Reduce Motion asks for, not something it has to be spared.
        let firstFill = !assembledOnce
        withAnimation(firstFill ? .easeOut(duration: 0.3) : nil) {
            items = built.items
            // The window is replaced with the feed it is a window ONTO, in the same transaction —
            // the one place a shrinking feed is handled (`reveal` only ever grows).
            window = Array(built.items.prefix(max(Self.firstWindow, window.count)))
            assembledOnce = true
        }
        #if DEBUG
        CommunityPerf.tick("window")
        #endif
        latestByAuthor = built.latest
        lastAssembledKey = key
        Self.sessionFeed = built.items
        Self.sessionLatest = built.latest
        prepareExperienceIfNeeded()
        consumePendingSocialDestination()
    }

    /// What a tile will actually DRAW, as a comparable string — a bundled city loop two neighbours
    /// both ran, two lower-body lifts lighting the identical muscle figure, two yoga posts wearing
    /// the identical glyph.
    ///
    /// **Say the promise precisely (2026-08-29).** It used to read "two tiles with the same
    /// signature are the same picture", and per-post wash variation made that imprecise: two yoga
    /// tiles now wear different tints and different symbol sizes, so they are not the same
    /// *rendering* any more. The promise this actually keeps, and the only one its single consumer
    /// needs, is: **two tiles with the same signature draw the same SUBJECT, and a repeated subject
    /// reads as repetition in the viewport whatever tint it wears.** `spaced` exists to keep
    /// repetition out of the viewport, not to compare bitmaps — see `dealtSignature` below and
    /// `spacingKeysOnTheSubjectNotTheDeal`, which measured the alternative and found it seats 27
    /// same-subject neighbours across a 400-tile wall where this seats 0.
    ///
    /// Photos are always their own subject; a route is fingerprinted by its shape (only three
    /// loops ship per city, so different athletes genuinely draw the same trace); a muscle map by
    /// the groups it lights; everything else by its sport glyph.
    static func mediaSignature(_ i: FeedItem) -> String {
        // The branch ORDER is the tile's, not a convenient one: `FeedTileMedia` covers with the
        // photo only when the author chose it, then muscle, then route, then a photo it has no
        // other visual for. Leading with "has photos at all" claimed a unique picture for a post
        // whose tile actually draws its route — the exact class of lie this function exists to
        // avoid. Seeded community posts carry no photos, so this only ever mattered for the
        // athlete's own posts on their own wall; it is still what the tile draws.
        if i.coverIsPhoto, !i.photosData.isEmpty { return "photo:\(i.id)" }
        if let m = i.muscles, m.values.contains(where: { $0 > 0 }) {
            // COARSE on purpose. Keying on the exact set of lit groups made two figures whose
            // loads differed in one minor group count as different pictures, and they shipped
            // side by side looking identical (a 9,929 lb tile beside a 6,900 lb tile, both
            // chest/shoulders/quads). At tile size only the DOMINANT regions are legible, so the
            // signature is the two heaviest groups. That still separates leg day from push day,
            // which genuinely do look different, while catching the look-alikes.
            let top = m.filter { $0.value > 0 }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
                .prefix(2).map(\.key.rawValue).sorted()
            return "muscle:" + top.joined(separator: ",")
        }
        if let pts = i.routeLatLon, pts.count > 1,
           let first = pts.first, first.count > 1, let last = pts.last, last.count > 1 {
            // Quantized to ~10m so float noise can't split one loop into two signatures.
            // Interpolation, never `String(format:)` — a `%d` there takes a 32-bit CInt and an Int
            // argument is a silent truncation waiting to happen.
            func q(_ v: Double) -> Int { Int((v * 10_000).rounded()) }
            return "route:\(pts.count):\(q(first[0])),\(q(first[1])):\(q(last[0])),\(q(last[1]))"
        }
        if !i.photosData.isEmpty { return "photo:\(i.id)" }
        // The GLYPH, never the sport (2026-08-29). This read `type.rawValue`, but the tile draws
        // `type.systemImage`, and several sports share one: `.run` and `.trailRun` are both
        // `figure.run`, and all four cycling cases are `bicycle`. So a mapless run and a mapless
        // trail run were two different signatures and one identical picture — and `spaced`, being
        // told they differed, shipped them side by side. Caught on a screenshot of the wall at
        // depth 24: two identical running figures in one row, 7.83 mi and 8.44 mi. This whole
        // function's promise is "two tiles with the same signature are the same picture", so it has
        // to key on what is drawn. Same correction as coarsening the muscle key on 2026-08-28.
        //
        // **AND STILL ONLY THE GLYPH, after the tiles stopped being identical (2026-08-29,
        // later).** `WashVariation` now deals every mapless post its own gradient axis, corner
        // light, lead hue, symbol size and offset, so two swims are no longer the same rendering.
        // The obvious follow-through was to put the deal in the key: two tiles that differ are not
        // the same picture, and `spaced` would stop spending displacement budget separating them.
        //
        // Measured, that is a bad trade, and `spacingKeysOnTheSubjectNotTheDeal` holds the numbers.
        // The deal changes a tile's TINT and its symbol's size; it does not change its SUBJECT, and
        // the subject is what the eye sorts a mosaic by at 130pt. Keying on the deal put three
        // running figures side by side in the wall's third row on a real screenshot — visibly worse
        // than the identical-but-separated tiles it replaced. The budget spent separating them is
        // not wasted; it is buying the most legible difference on the tile.
        //
        // So the variation and the spacer do different jobs, and both are needed: the spacer keeps
        // two of one sport apart, and the variation means the pairs it CANNOT keep apart (a run of
        // five swims in date order, the tail of the well) are still two different pictures instead
        // of one rendered twice.
        return "glyph:\(i.type.systemImage)"
    }

    /// The alternative definition of "the same picture", kept so the trade above stays measurable:
    /// the tile's subject AND the tone `WashVariation` deals it. Not what the wall ships — see
    /// `spacingKeysOnTheSubjectNotTheDeal`, which runs both over the real seed and counts.
    static func dealtSignature(_ i: FeedItem) -> String {
        let base = mediaSignature(i)
        guard base.hasPrefix("glyph:") else { return base }
        return base + ":\(WashVariation.tone(for: i.id))"
    }

    static func hasMedia(_ i: FeedItem) -> Bool {
        i.hasRenderableRoute || (i.muscles?.values.contains { $0 > 0 } ?? false) || !i.photosData.isEmpty
    }

    /// Two rules over one pass, both about what the wall LOOKS like:
    ///
    /// 1. **The lead is media** (2026-08-25 realism pass): a post with no route, no muscle map and
    ///    no photo renders as a sport glyph on a wash, and two of those in the top row read as
    ///    placeholder art.
    /// 2. **No two neighbours draw the same picture** (2026-08-28): at depth the wall showed a full
    ///    row of stick figures — yoga, yoga, swim — and pairs of muscle figures lit identically,
    ///    side by side. On screen that reads as a rendering bug, then as a generator. Repetition in
    ///    the viewport is the loudest tell there is.
    ///
    /// "Neighbour" means what the EYE sees on a 3-across mosaic: the tile to the left and the tile
    /// directly above (`columns` back in the flat order), not just the previous index.
    ///
    /// Date order still governs: no post moves more than `maxDrift` slots from its own date
    /// position, in either direction, and when nothing legal is within reach the date wins and the
    /// repeat ships. Pure and O(n) — the well runs to thousands of posts.
    ///
    /// **`maxDrift` is a hard cap, not a hope (2026-08-29).** The displacement bound used to be
    /// incidental: `held` was capped at `lookahead`, but a post sitting in it could be passed over
    /// again and again while legal posts streamed by, so its drift was unbounded in principle and
    /// merely small in practice. Coarsening the glyph signature — a mapless run and a mapless trail
    /// run draw the identical figure and must count as one picture — created enough extra
    /// collisions to expose it, and `everyPostSurvivesAndBarelyMoves` went to a worst drift of 6
    /// against its bound of 4. The head of the queue now goes the moment it has waited its whole
    /// budget, legal or not, which makes reverse-chronology structural: forward drift is capped
    /// here, and backward drift can never exceed `held.count`, itself capped at `lookahead`.
    ///
    /// **`picture` is injectable, and that is not a test hook (2026-08-29).** What counts as "the
    /// same picture" is the one judgement call in this whole file, it has been got wrong twice
    /// (`type.rawValue` vs the glyph; the exact lit muscle set vs the dominant two), and the cost of
    /// getting it wrong in either direction is only visible as a COUNT over a real wall. So a
    /// candidate definition can be run against the seed and compared with the shipped one —
    /// `spacingKeysOnTheSubjectNotTheDeal` does exactly that, and is why the glyph key stayed on
    /// the symbol when the per-post wash variation landed.
    static func spaced(_ items: [FeedItem], lead: Int = 6, lookahead: Int = 4,
                       columns: Int = 3, maxDrift: Int = 4,
                       picture: (FeedItem) -> String = mediaSignature) -> [FeedItem] {
        guard items.count > 2 else { return items }
        // Signatures once per post, never per comparison: the well runs to thousands of rows and
        // each candidate is weighed several times as it waits. `at` is the post's own date
        // position, which is what the drift cap below is measured against.
        typealias Tile = (item: FeedItem, sig: String, media: Bool, at: Int)
        let queue: [Tile] = items.enumerated().map { ($1, picture($1), hasMedia($1), $0) }
        var out: [FeedItem] = []
        out.reserveCapacity(items.count)
        var sigs: [String] = []         // out's signatures, so a neighbour check is a lookup
        var held: [Tile] = []           // deferred, still in date order; never longer than `lookahead`
        var i = 0

        func emit(_ tile: Tile) {
            sigs.append(tile.sig)
            out.append(tile.item)
        }
        func legal(_ tile: Tile) -> Bool {
            guard out.count >= lead || tile.media else { return false }
            // The tile immediately left (unless this one starts a row) and the tile directly
            // above. DELIBERATELY NARROW: a wider neighbourhood (diagonals, the two-left slot)
            // was tried on 2026-08-28 and reverted — it demands more reordering than the
            // "barely moves" promise funds, so the algorithm started shipping TOUCHING repeats
            // to stay inside the displacement budget, which is strictly worse to look at.
            // Diagonal and same-row-with-a-gap repeats remain possible; their real cause is
            // content variety (only 3 route loops ship per city), and that is fixed at the seed,
            // not by rearranging tiles.
            if out.count % columns != 0, sigs.last == tile.sig { return false }
            if out.count >= columns, sigs[out.count - columns] == tile.sig { return false }
            return true
        }

        while i < queue.count || !held.isEmpty {
            // FIRST, always: a post that has waited its whole displacement budget ships now,
            // legal or not. This is the line that makes reverse-chronological order a guarantee
            // rather than an observation — see the note on `maxDrift`. It has to precede the
            // legality scan, because emitting some other held post instead would push this one
            // past its budget.
            if let head = held.first, out.count - head.at >= maxDrift {
                emit(held.removeFirst())
                continue
            }
            // The oldest thing waiting goes the moment it becomes legal — that's what keeps a
            // deferred post near its own date slot.
            if let k = held.firstIndex(where: legal) { emit(held.remove(at: k)); continue }
            if i < queue.count {
                let next = queue[i]
                i += 1
                if legal(next) { emit(next) }
                else if held.count < lookahead { held.append(next) }
                else { emit(held.removeFirst()); held.append(next) }   // out of slack: date wins
                continue
            }
            emit(held.removeFirst())   // tail: nothing legal is left, so keep the order
        }
        return out
    }

    var body: some View {
        #if DEBUG
        let _ = CommunityPerf.tick("wall")
        #endif
        Group {
            if searching {
                // In-place search (owner ask 2026-07-29): the header magnifier opens a search bar
                // where the wall was — no sheet hop — and Cancel returns to the grid.
                FindAthletesView(onOpen: { handle in
                    withAnimation(.easeOut(duration: 0.2)) { searching = false }
                    openAthlete(handle)
                }, embedded: true, onCancel: {
                    withAnimation(.easeOut(duration: 0.2)) { searching = false }
                })
                .transition(.opacity)
            } else {
                gridFace
                    .transition(.opacity)
            }
        }
        .background(Theme.background)
        .overlay(alignment: .bottom) { athleteResolveNote }
        .animation(.easeOut(duration: 0.2), value: resolvingAthlete == nil && unresolvedAthlete == nil)
        .navigationBarHidden(true)
        .navigationDestination(item: $selectedAthlete) { AthleteProfileView(athlete: $0) }
        .navigationDestination(item: $showingFollowing) { _ in FollowingListView() }
        .sheet(item: $sharingToday) { w in
            ShareCardView(workout: w, weightUnit: WeightUnit(rawValue: profile?.weightUnit ?? "kg") ?? .kg,
                          distanceUnit: DistanceUnit(rawValue: profile?.distanceUnit ?? "auto") ?? .auto)
        }
        #if DEBUG
        .navigationDestination(isPresented: $debugSavedRoutes) { SavedRoutesView() }
        #endif
        // The TikTok moment: a tile zooms into the full-bleed vertical pager. Byline taps push
        // the athlete's profile INSIDE the pager's own NavigationStack — over the post, back
        // swipes home (the old dismiss-pause-push read as a glitch, owner report 2026-07-29).
        .fullScreenCover(item: $immersive) { start in
            // Sliced FROM the tapped post: page one is the post you tapped BY CONSTRUCTION, and
            // swiping continues deeper down the feed (TikTok's grid-open). The old whole-array +
            // scrollTo broke silently once the well hit 400 — the lazy stack couldn't jump, so
            // every tile opened page one ("everyone is Bianca", owner report 2026-07-29).
            CommunityPager(items: pagerSlice(from: start.id), startID: start.id,
                           ownHandle: profile?.handle)
                .navigationTransition(.zoom(sourceID: start.id, in: tileZoom))
        }
        .fullScreenCover(item: $story) { start in
            if let first = start.items.first {
                CommunityPager(items: start.items, startID: first.id, ownHandle: profile?.handle)
            }
        }
        #if DEBUG
        .task {
            guard CommunityPerf.enabled else { return }
            CommunityPerf.mark("APPEAR CommunityView")
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                CommunityPerf.dump("1s")
                CommunityPerf.mark(FeedRouteSnapshots.perfLine())
                CommunityPerf.reset()
            }
        }
        #endif
        .task(id: feedKey) {
            // Assemble off the render path — runs on appear and whenever an input signature moves.
            await refreshFeed()
        }
        // Tab revisits rebuild too: a share-visibility toggle elsewhere changes no count in
        // `feedKey`, but the athlete expects the feed to reflect it when they come back. Only on
        // a REAL revisit though — on a fresh instance (every slider flip creates one) the task
        // above hasn't stamped the key yet, and running here too assembled the whole feed TWICE
        // back to back (2026-07-30 perf audit).
        //
        // **Held and cancelled (2026-08-29).** This was a bare unstructured `Task`: nothing owned
        // it, so leaving the wall did not stop it and a second revisit started another beside the
        // first. Two builds then raced the `.task(id:)` one and the last writer won, from whichever
        // snapshot happened to finish last. It is held now, cancelled on the next revisit and on
        // disappear, and `refreshFeed`'s sequence stamp is the backstop for the window where a
        // cancelled build has already passed its last suspension point.
        .onAppear {
            prepareExperienceIfNeeded()
            consumePendingSocialDestination()
            guard assembledOnce, lastAssembledKey == feedKey else { return }
            revisitRefresh?.cancel()
            revisitRefresh = Task { await refreshFeed() }
        }
        .onDisappear {
            revisitRefresh?.cancel()
            revisitRefresh = nil
            experience.finishVisit(items: items, scope: scope)
        }
        .onChange(of: scopeRaw) { oldRaw, _ in
            let oldScope = CommunityScope(rawValue: oldRaw) ?? .everyone
            experience.finishVisit(items: items, scope: oldScope)
            preparedScope = nil
            wallAnchor = nil
            newBoundaryID = nil
            newPostCount = 0
        }
        .task {
            // Who follows back + any nudges/activity that landed while the app was away. The
            // activity bridge is also refreshed by RootView on foreground; its own throttle makes
            // this second entry point cheap while guaranteeing a long-active Community session
            // is never dependent on another tab or a relaunch to populate the bell.
            await nudges.refresh(in: modelContext)
            await SocialActivityInbox.refresh(backend: services.social, in: modelContext)
        }
        .task(id: scopeRaw) {
            // Refetch whenever the scope changes — Following and Everyone are different server
            // queries, so an emptiness guard would leave the previous scope's rows in place and
            // leak un-followed athletes into Following. `refresh` guards !isLoading and swaps
            // items per scope; it's a no-op offline/guest/dark.
            await remoteFeed.refresh(scope: remoteScope)
        }
        .task(id: pendingPostLookupKey) {
            guard let id = router.pendingCommunityPostID,
                  !items.contains(where: { $0.id == id })
            else {
                consumePendingSocialDestination()
                return
            }
            guard let item = await remoteFeed.resolve(postID: id),
                  !Task.isCancelled,
                  router.pendingCommunityPostID == id
            else { return } // offline/not visible: keep the mailbox so a later refresh can retry
            deepLinkedPost = item
            // Updating this state changes feedKey. Its structured task assembles the post into the
            // wall, then consumePendingSocialDestination opens and clears the mailbox.
        }
        .task(id: paywall.isEntitled(to: .fullPlan)) {
            // Entitlement flipped mid-session (purchase, restore, reinstall's async restore):
            // re-publish the profile so the server-side `is_pro` — the checkmark every OTHER
            // athlete sees — updates now, not at the next launch's claimProfile.
            let pro = paywall.isEntitled(to: .fullPlan)
            if let last = lastPublishedPro, last != pro, let profile {
                await services.social.claimProfile(profile, in: modelContext)
            }
            lastPublishedPro = pro
        }
        #if DEBUG
        // --athlete-profile: open the first community athlete directly (deterministic sim
        // verification of the visited-profile design; feed taps are flaky in UI tests).
        // --find-athletes / --open-first-post: same idea for the search sheet and the full-page
        // post detail.
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            // ONE-SHOT (both athlete hooks). This `onAppear` re-fires whenever the pushed profile is
            // popped — and `selectedAthlete` is nil again by then — so without the flag, navigating
            // BACK instantly re-pushed the same athlete. That made the wall look stuck and any test
            // that leaves the profile impossible to write (found 2026-07-30 by the follow-flow test).
            if !Self.didOpenDebugAthlete {
                if let i = args.firstIndex(of: "--athlete-profile") {
                    // Optional trailing handle ("--athlete-profile joonw973") opens that exact member —
                    // generated athletes included — so per-handle traits (e.g. the Pro-seal draw) are
                    // verifiable deterministically. Bare flag keeps opening the first directory athlete.
                    let handle = args.indices.contains(i + 1) && !args[i + 1].hasPrefix("--") ? args[i + 1] : nil
                    Self.didOpenDebugAthlete = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        selectedAthlete = handle.flatMap { CommunityDirectory.athlete(handle: $0) }
                            ?? CommunityDirectory.all().first
                    }
                }
                // --athlete-profile-stale: the first directory athlete with NO post in the last
                // 24h, followed on open — the Nudge pill's only legal state, screenshot-verifiable.
                if args.contains("--athlete-profile-stale") {
                    Self.didOpenDebugAthlete = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        let stale = CommunityDirectory.all().first {
                            ($0.posts.map(\.date).max()).map { Date().timeIntervalSince($0) > 86_400 } ?? true
                        }
                        if let stale, !follows.isFollowing(stale.handle) { follows.toggle(stale.handle) }
                        selectedAthlete = stale
                    }
                }
                // --athlete-profile-strength: first GENERATED strength-primary athlete — verifies the
                // non-runner profile coherence (sport-led grid, workouts-logged hero, no distance claim).
                if args.contains("--athlete-profile-strength") {
                    Self.didOpenDebugAthlete = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        selectedAthlete = CommunityDirectory.all().dropFirst(8)
                            .first { $0.posts.first?.type.isStrengthStyle == true }
                    }
                }
            }
            // --open-ring: tap the first ringed face on the Following row (their day in the
            // pager); --open-your-day: the "Your day" face; --open-following-more: the "+N" face.
            // Taps on the row are unreliable in the sim; these drive the same handlers.
            if args.contains("--open-ring") || args.contains("--open-your-day") || args.contains("--open-following-more") {
                Task { @MainActor in
                    for _ in 0..<30 {
                        if !items.isEmpty {
                            try? await Task.sleep(for: .milliseconds(800))
                            if args.contains("--open-your-day") {
                                let mine = items.filter { $0.authorHandle == ownHandle && !ownHandle.isEmpty }
                                if !mine.isEmpty { story = StoryStart(id: "you", items: Array(mine.prefix(5))) }
                                else if let latest = workouts.first { sharingToday = latest }
                            } else if args.contains("--open-following-more") {
                                showingFollowing = FollowingPush()
                            } else if let person = followedPeople.first(where: \.ringed) {
                                let posts = day(of: person.handle)
                                if !posts.isEmpty { story = StoryStart(id: person.handle, items: posts) }
                            }
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                }
            }
            // --community-friends: land on the Friends scope (the empty-follows state is the one
            // the header used to vanish on).
            if args.contains("--community-friends") { scopeRaw = CommunityScope.following.rawValue }
            if args.contains("--find-athletes") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { searching = true }
            }
            // --seed-saved-route: bookmark the first routed post so the strip's Saved door and
            // the library render for sim verification (taps can't drive the pager reliably).
            // --saved-routes additionally pushes the library itself.
            if args.contains("--seed-saved-route") || args.contains("--saved-routes") {
                Task { @MainActor in
                    for _ in 0..<20 {
                        if let post = items.first(where: \.hasRenderableRoute) {
                            if savedRoutes.isEmpty {
                                modelContext.insert(SavedRoute(
                                    postID: post.id, title: post.title, authorName: post.authorName,
                                    authorHandle: post.authorHandle, city: post.location,
                                    km: 8.8, pts: post.sanitizedRouteLatLon ?? [], mapStyle: post.mapStyle))
                                try? modelContext.save()
                            }
                            if args.contains("--saved-routes") {
                                try? await Task.sleep(for: .milliseconds(400))
                                debugSavedRoutes = true
                            }
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                }
            }
            // --open-post <index>: open the pager on a SPECIFIC tile — verifies the tapped tile
            // and page one always agree (taps are unreliable in the sim).
            if let i = args.firstIndex(of: "--open-post"), args.indices.contains(i + 1),
               let index = Int(args[i + 1]) {
                Task { @MainActor in
                    for _ in 0..<30 {
                        if items.indices.contains(index) {
                            reveal(index + Self.windowStep)
                            try? await Task.sleep(for: .milliseconds(600))
                            immersive = PagerStart(id: items[index].id)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                }
            }
            // Stable cover-swap fixture. Feed spacing and reverse-chronology are allowed to evolve,
            // so an index can never be the contract for "the routed post whose photo leads".
            if args.contains("--open-photo-route-post") {
                Task { @MainActor in
                    for _ in 0..<120 {
                        if let index = items.firstIndex(where: {
                            $0.coverIsPhoto && !$0.photosData.isEmpty && $0.hasRenderableRoute
                        }) {
                            reveal(index + Self.windowStep)
                            try? await Task.sleep(for: .milliseconds(600))
                            immersive = PagerStart(id: items[index].id)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
            }
            // --open-first-route-post: deterministic replay/route-loading verification. Feed
            // ordering and authored photo covers can change without silently steering a route
            // regression onto a routeless post.
            if args.contains("--open-first-route-post") {
                Task { @MainActor in
                    for _ in 0..<120 {
                        // Prefer a routed post with a neighbour on both sides so UI tests can make
                        // a deterministic one-page round trip instead of hitting a deck boundary.
                        let interior = items.indices.dropFirst().dropLast()
                        let routed = interior.first(where: { items[$0].hasRenderableRoute })
                            .map { items[$0] }
                            ?? items.first(where: \.hasRenderableRoute)
                        if let routed, let index = items.firstIndex(where: { $0.id == routed.id }) {
                            reveal(index + Self.windowStep)
                            try? await Task.sleep(for: .milliseconds(600))
                            immersive = PagerStart(id: routed.id)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
            }
            // --open-first-post-dark: first DARK-basemap post — the scrim-over-dark-map case.
            if args.contains("--open-first-post-dark") {
                Task { @MainActor in
                    for _ in 0..<30 {
                        if let dark = items.first(where: { $0.mapStyle == .dark && $0.hasRenderableRoute }) {
                            try? await Task.sleep(for: .milliseconds(600))
                            immersive = PagerStart(id: dark.id)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                }
            }
            if args.contains("--open-first-post") {
                // Waits for assembly rather than firing at a fixed delay — a cold seed build can
                // outlast any guess, and a missed one-shot reads as "the pager is broken". The
                // extra settle beat lets the grid lay out and register the zoom SOURCE first:
                // presenting a `.zoom` cover whose matchedTransitionSource doesn't exist yet
                // leaves the cover stuck semi-transparent (a real tap can never race this).
                Task { @MainActor in
                    for _ in 0..<30 {
                        if let first = items.first {
                            try? await Task.sleep(for: .milliseconds(600))
                            immersive = PagerStart(id: first.id)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                }
            }
        }
        #endif
    }

    /// The wall: header → Friends | Global text tabs → tiles, one structured column (the stacked
    /// floating-pill arrangement read as chrome piled on chrome — owner call 2026-07-29). The tabs
    /// strip is a safe-area inset with its own hairline, and the grid starts one gutter below it —
    /// the profile grid's exact relationship to its Grid/Highlights bar.
    private var gridFace: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // The page header ALWAYS renders (2026-08-25): find people → the faces you follow,
                // ringed when they posted today → Explore. It used to live inside the non-empty
                // branch, so opening Friends with nobody followed took the search field, the ring
                // row and the scope tabs off screen with the wall — the one state where finding
                // people matters most had no way to find people, and the header jumped.
                followingRow
                    .padding(.top, Theme.Space.md)
                HStack {
                    Text("Explore")
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                    Spacer()
                    savedRoutesDoor
                }
                .padding(.horizontal, Theme.Space.md)
                .padding(.top, Theme.Space.lg)
                CommunityScopeTabs(scopeRaw: $scopeRaw)

                if items.isEmpty {
                    // No flash of the empty state during the very first assembly pass.
                    if assembledOnce {
                        emptyState
                            .padding(.top, Theme.Space.xl)
                            .padding(.horizontal, Theme.Space.md)
                    } else {
                        wallSkeleton
                    }
                } else {
                    CommunityFeedGrid(items: window,
                                      zoomNamespace: tileZoom,
                                      newBoundaryID: newBoundaryID,
                                      newPostCount: newPostCount,
                                      onTileAppear: { index in
                                          // The Instagram trick: the next page is requested when a
                                          // tile TWO ROWS from the end scrolls in, not when the
                                          // bottom is hit — by the time the athlete gets there, the
                                          // next 12 already exist and the scroll never stalls.
                                          if index >= visibleCount - 6 { loadNextPage() }
                                      }) { id in
                        immersive = PagerStart(id: id)
                    }
                    .transition(.opacity)   // crossfades with the skeleton it replaces
                    // Reaching the bottom loads more, always (owner ask 2026-07-30 — the mirror of
                    // pull-to-refresh): grow the local window a page (the Instagram reveal), DEEPEN
                    // the well itself once the window catches up to its cap (the assembled feed is
                    // thousands of posts deep — the wall must never dead-end), and pull the next
                    // REMOTE page as the well runs low (cursor-driven; `loadMore` guards
                    // scope/cursor/in-flight, and a dark backend no-ops).
                    //
                    // The spinner below is honest, not theater: the instant local reveal still
                    // lands the same frame (no artificial delay), and the spinner marks the beats
                    // that ARE async — the well re-assembly and the remote fetch. It hides only at
                    // the feed's true end, which is the one place scrolling should quietly stop.
                    bottomLoader
                        .onAppear { loadNextPage() }   // backstop for a scroll that outruns prefetch
                        .padding(.bottom, Theme.Space.xxl)
                }
            }
            .scrollPosition(id: $wallAnchor, anchor: .top)
            .onChange(of: wallAnchor) { _, id in
                guard let id, let item = items.first(where: { $0.id == id }) else { return }
                experience.saveAnchor(item, scope: scope)
            }
            #if DEBUG
            // --wall-scroll <index>: jump the wall to a tile index for sim verification — content
            // audits need to SEE deep rows, and simctl can't scroll.
            .onAppear {
                let args = ProcessInfo.processInfo.arguments
                if let i = args.firstIndex(of: "--wall-scroll"), args.indices.contains(i + 1),
                   let index = Int(args[i + 1]) {
                    // Waits for assembly (the --open-first-post lesson): a one-shot delay races
                    // the cold seed build and silently no-ops. Grows the reveal window first —
                    // a tile outside it doesn't exist to scroll to.
                    Task { @MainActor in
                        for _ in 0..<20 {
                            if !items.isEmpty {
                                reveal(index + Self.windowStep)
                                try? await Task.sleep(for: .milliseconds(500))
                                let target = items.indices.contains(index) ? items[index] : items[items.count - 1]
                                withAnimation { proxy.scrollTo(target.id, anchor: .top) }
                                return
                            }
                            try? await Task.sleep(for: .milliseconds(300))
                        }
                    }
                }
            }
            #endif
        }
        .refreshable {
            pulsed = CommunityPulse.refreshed(pulsed)
            async let feedRefresh: Void = remoteFeed.refresh(scope: remoteScope)
            async let inboxRefresh: Void = SocialActivityInbox.refresh(
                backend: services.social, in: modelContext, force: true)
            _ = await (feedRefresh, inboxRefresh)
        }
    }

    /// Prepare one stable visit snapshot per scope. Restoration grows the lazy window far enough
    /// for its anchor before assigning the scroll binding; doing those in the opposite order makes
    /// `scrollPosition` silently drop an id whose tile does not exist yet.
    private func prepareExperienceIfNeeded() {
        guard assembledOnce, !items.isEmpty, preparedScope != scope else { return }
        let visit = experience.visit(items: items, scope: scope)
        if let restore = visit.restoreID,
           let index = items.firstIndex(where: { $0.id == restore }) {
            reveal(index + Self.windowStep)
        }
        newBoundaryID = visit.boundaryID
        newPostCount = visit.newCount
        preparedScope = scope
        guard let restore = visit.restoreID else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { wallAnchor = restore }
    }

    /// The bell inbox leaves a one-shot mailbox on `AppRouter`. Consume only when the target can
    /// actually open; a cold remote refresh may need to finish first, and dropping the id earlier
    /// would turn a valid notification into a dead tap.
    private func consumePendingSocialDestination() {
        if let id = router.pendingCommunityPostID,
           items.contains(where: { $0.id == id }) {
            router.pendingCommunityPostID = nil
            immersive = PagerStart(id: id)
            return
        }
        if let handle = router.pendingCommunityAthleteHandle, !handle.isEmpty {
            router.pendingCommunityAthleteHandle = nil
            openAthlete(handle)
        }
    }

    /// One page of continuous scroll: reveal the next 12 tiles (instant — a state flip over
    /// already-assembled items), and keep the slower feeders primed WELL ahead of the reveal —
    /// the well deepens and the next remote page fetches while there are still ~4 pages in hand,
    /// so their async cost lands behind rows the athlete hasn't reached yet. Idempotent per state:
    /// a burst of near-end tile appearances in one frame advances at most one page, because the
    /// first advance moves the threshold the rest are compared against.
    private func loadNextPage() {
        reveal(visibleCount + Self.windowStep)
        let remaining = items.count - visibleCount
        // (`items.count >= wellCap` proves the assembled feed still had more; once assembly
        // returns fewer than the cap, the seed is exhausted and the cap stops growing.)
        if scope == .everyone, items.count >= wellCap, remaining <= Self.windowStep * 4 {
            wellCap += Self.wellStep
        }
        if remaining <= Self.windowStep * 4 {
            Task { await remoteFeed.loadMore(scope: remoteScope) }
        }
    }

    /// The ONLY writer of `window` outside `refreshFeed` — so the revealed count and the revealed
    /// tiles are one fact rather than two that can drift. Grows only (every caller is a reveal);
    /// a shrinking feed is handled where the feed itself is replaced. Idempotent: asking for a
    /// window that is already open costs one comparison and allocates nothing.
    private func reveal(_ count: Int) {
        let target = min(max(count, window.count), items.count)
        guard target != window.count else { return }
        window = Array(items.prefix(target))
        #if DEBUG
        CommunityPerf.tick("window")
        #endif
    }

    /// True while scrolling further down can still produce content: window not fully revealed,
    /// the well still at its cap (deeper posts exist), or a remote page in flight.
    private var hasMoreBelow: Bool {
        visibleCount < items.count
            || (scope == .everyone && items.count >= wellCap)
            || remoteFeed.isLoading
    }

    /// The bottom-of-wall beat: a small quiet spinner while there's more to come, nothing at the
    /// true end. Doubles as the on-appear sentinel that drives the window/well/remote growth.
    @ViewBuilder
    private var bottomLoader: some View {
        if hasMoreBelow {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.inkTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.lg)
                .accessibilityLabel("Loading more")
        } else {
            Color.clear.frame(height: 1)
        }
    }

    /// The wall's first beat, before there is a wall: the mosaic's own geometry in quiet surface
    /// panes (ProfileScreen's `profileWarmup` pattern, perf audit 2026-08-13).
    ///
    /// It only ever shows on the FIRST community open of a process — every later one is seeded
    /// from `sessionFeed` and renders real tiles on frame one. That first open is the expensive
    /// one: the whole 2,863-athlete directory and its ledgers are built behind this. Deliberately
    /// still and unlabelled — no spinner, no "Loading" — so the page reads as a page arriving
    /// rather than as a machine working, and the real grid crossfades in over it at the same
    /// gutter, same aspect, same top inset, so nothing moves when it lands.
    private var wallSkeleton: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: ProfileGrid.gutter),
                                 count: 3),
                  spacing: ProfileGrid.gutter) {
            ForEach(0..<12, id: \.self) { _ in
                Color.clear
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .overlay(Theme.surface)
            }
        }
        .padding(.top, ProfileGrid.gutter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.opacity)
    }

    /// The saved-route library's door, tucked into the scope-tabs strip's trailing edge. This used
    /// to live in a "pulse strip" between the tabs and the wall ("2,863 athletes · 217 moving
    /// now") — the owner cut that line entirely (2026-07-30) so the grid runs full-bleed from the
    /// tabs down; the bookmark is the only part that had a job, and it kept it.
    @ViewBuilder
    private var savedRoutesDoor: some View {
        if !savedRoutes.isEmpty {
            NavigationLink { SavedRoutesView() } label: {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(savedRoutes.count == 1 ? "1 saved route" : "\(savedRoutes.count) saved routes")
        }
    }

    /// The feed from the tapped post onward — from the FULL well, not the reveal window, so the
    /// pager keeps going past what the wall had rendered.
    // MARK: Following row

    private var ownHandle: String { profile?.handle ?? "" }

    /// Posted in the last 24h — your own ring, the same rule the profile hero uses. Private work
    /// stays private all the way through the visual language; it cannot light a social ring.
    private var youPostedToday: Bool {
        guard let w = workouts.first(where: SocialPrivacy.isShared) else { return false }
        let age = Date().timeIntervalSince(w.startedAt)
        return age >= 0 && age < 86_400
    }

    /// A followed athlete's posts through the 24h window; falls back to their newest post so a
    /// tap always shows *something* of theirs rather than a dead ring.
    private func day(of handle: String) -> [FeedItem] {
        let theirs = items.filter { $0.authorHandle == handle }
        let pool = theirs.isEmpty ? (CommunityDirectory.athlete(handle: handle)?.posts ?? []) : theirs
        let recent = pool.filter { Date().timeIntervalSince($0.date) < 86_400 }
        let chosen = recent.isEmpty ? Array(pool.prefix(1)) : recent
        return chosen.sorted { $0.date > $1.date }
    }

    private var followedPeople: [FollowingRow.Person] {
        // `following` is a Set, so the map's order is arbitrary and Swift's sort is not stable —
        // without the handle tiebreak below, two people with the same ring state and the same last
        // post swapped places between renders.
        let newest = latestByAuthor
        return follows.following.filter { $0 != ownHandle }.sorted().map { handle in
            let athlete = CommunityDirectory.athlete(handle: handle)
            // One dictionary lookup, not a scan of the whole well per followed athlete — see
            // `latestByAuthor`. This runs inside `body`, and `body` runs on every reveal of the
            // next twelve tiles.
            let latest = newest[handle] ?? athlete?.posts.map(\.date).max()
            let ringed = latest.map { Date().timeIntervalSince($0) < 86_400 } ?? false
            let label = athlete?.name.split(separator: " ").first.map(String.init) ?? handle
            // `label` is the caption (a first name fits under a 64pt face); `fullName` is what the
            // avatar draws its initials from. Passing the caption made Theo Bennett a "T" here and
            // a "TB" in search and in every follow list — one person reading as two, the exact bug
            // `CommunityAvatars` promises can't happen (2026-08-28).
            return FollowingRow.Person(handle: handle, label: label,
                                       fullName: athlete?.name ?? handle,
                                       ringed: ringed, lastActive: latest,
                                       avatarData: athlete?.avatarData,
                                       imageName: athlete?.communityAvatarAsset,
                                       preset: athlete?.communityPreset)
        }
    }

    private var followingRow: some View {
        FollowingRow(
            // "Your day" is the caption, never the name: with no profile photo the avatar drew its
            // initials from the caption and the athlete's own face on the community home read
            // "YD" (2026-08-28).
            you: .init(handle: ownHandle, label: "Your day",
                       fullName: FeedAssembler.displayName(profile),
                       ringed: youPostedToday, avatarData: profile?.avatarData),
            people: followedPeople,
            onFind: { withAnimation(.easeOut(duration: 0.2)) { searching = true } },
            onYou: {
                // Your day: your newest shared post, in the same pager everyone else's opens in.
                let mine = items.filter { $0.authorHandle == ownHandle && !ownHandle.isEmpty }
                if !mine.isEmpty { story = StoryStart(id: "you", items: Array(mine.prefix(5))) }
                else if let latest = workouts.first { sharingToday = latest }
            },
            onPerson: { person in
                let posts = day(of: person.handle)
                if !posts.isEmpty { story = StoryStart(id: person.handle, items: posts) }
                else { openAthlete(person.handle) }
            },
            onMore: { showingFollowing = FollowingPush() })
    }

    private func pagerSlice(from id: UUID) -> [FeedItem] {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return items }
        return Array(items[index...])
    }

    private var remoteScope: FeedScope { scope == .following ? .following : .everyone }

    /// Community (seeded) athletes resolve locally and push instantly; real athletes need a round
    /// trip first.
    ///
    /// **The tap always answers (2026-08-29).** A miss used to do nothing at all — no spinner while
    /// the fetch ran, no word when it failed, no navigation — so on a slow or dark connection the
    /// athlete tapped a name and the app sat there. A control that does nothing is the most
    /// fake-feeling thing on a social page, which is the whole point of this pass. Same treatment
    /// as `FollowingListView`: a quiet spinner for as long as it takes, then one plain line if it
    /// can't be had. The toast clears itself, so nothing is left to dismiss.
    private func openAthlete(_ handle: String) {
        if let seeded = CommunityDirectory.athlete(handle: handle) {
            selectedAthlete = seeded
            return
        }
        resolvingAthlete = handle
        Task {
            let remote = await remoteFeed.athlete(handle: handle)
            guard resolvingAthlete == handle else { return }   // a newer tap owns the spinner now
            resolvingAthlete = nil
            if let remote {
                selectedAthlete = remote
            } else {
                unresolvedAthlete = handle
                try? await Task.sleep(for: .seconds(3))
                if unresolvedAthlete == handle { unresolvedAthlete = nil }
            }
        }
    }

    /// The resolve's own beat, over the wall: a spinner while a real athlete's page is fetched and
    /// one honest line when it can't be. Deliberately a small floating capsule rather than a sheet
    /// or an alert — the tap was a navigation, not a decision, so failing it must not demand one.
    @ViewBuilder
    private var athleteResolveNote: some View {
        if resolvingAthlete != nil || unresolvedAthlete != nil {
            HStack(spacing: Theme.Space.sm) {
                if resolvingAthlete != nil {
                    ProgressView().controlSize(.small).tint(Theme.inkSecondary)
                    Text("Opening profile")
                } else {
                    Text("Profile isn't available right now.")
                }
            }
            .font(.rounded(Theme.FontSize.label, weight: .semibold))
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().stroke(Theme.hairline))
            .padding(.bottom, Theme.Space.xl)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    // MARK: Empty state (Following with no follows yet — no-shame, one obvious next step)

    private var emptyState: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: "person.2")
                .font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            Text("Your people will show up here")
                .font(.display(20, weight: .bold)).foregroundStyle(Theme.ink)
            Text("Follow athletes you care about, or share your next workout. It lands here too.")
                .font(.rounded(Theme.FontSize.body, weight: .regular)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
            Button {
                withAnimation(.easeOut(duration: 0.2)) { searching = true }
            } label: {
                Text("Find athletes")
                    .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.background)
                    .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.sm + 2)
                    .raised(Capsule(), tone: .ink)
            }
            .buttonStyle(RaisedPressStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.xl)
    }
}

/// One assembly per distinct set of inputs, however many callers ask for it at once.
///
/// **The flip storm (2026-08-29).** The Profile ↔ Community slider tears `CommunityView` down and
/// builds a new one on every switch, and each new one starts its own `.task(id: feedKey)`. During
/// the ~650 ms first build — the one that constructs the 2,863-athlete directory and folds every
/// ledger — flipping back and forth spawned a detached task per flip, each re-sorting and
/// re-`spaced`ing ~2,900 posts while competing with the others for cores. The results were
/// identical (the assembly is a pure function of its input), so every copy but one was work the
/// athlete waited through for nothing. The first caller now starts the build and everyone else
/// waits on that same task.
///
/// Keyed on `feedKey`, the assembly's whole change signature, so two callers only ever share a
/// build when they would have computed the same wall. Internal rather than file-private only so
/// `CommunitySurfacePerfTests` can hold it to that.
@MainActor
enum CommunityFeedAssembly {
    typealias Wall = (items: [FeedItem], latest: [String: Date])
    private static var inFlight: (key: String, task: Task<Wall, Never>)?

    #if DEBUG
    /// Builds actually run, against callers served — the coalescer's own measurement.
    private(set) static var builds = 0
    private(set) static var requests = 0
    static func resetCounters() { builds = 0; requests = 0 }
    #endif

    static func build(key: String, input: CommunityView.FeedInputs) async -> Wall {
        #if DEBUG
        requests += 1
        #endif
        // Nothing suspends between the lookup and the store below, so two callers on the main
        // actor cannot both miss and both start a build.
        if let running = inFlight, running.key == key { return await running.task.value }
        #if DEBUG
        builds += 1
        #endif
        let task = Task.detached(priority: .userInitiated) { () -> Wall in
            let items = CommunityView.assembleFeed(input)
            return (items, CommunityView.latestByAuthor(items))
        }
        inFlight = (key, task)
        let wall = await task.value
        // Only clear our own: a build for a NEWER key may already have replaced the slot, and
        // clearing it then would let the next caller start a duplicate of that one.
        if inFlight?.key == key { inFlight = nil }
        return wall
    }
}

/// Which slice of the feed is shown. Persisted — the tab reopens where the athlete left it.
enum CommunityScope: String, CaseIterable {
    case following, everyone
    var label: String {
        switch self {
        case .following: "Friends"   // relabeled from "Following" with the grid redesign (2026-07-29)
        case .everyone: "Global"     // rawValue stays "everyone" (persisted); label is the Substack-style "Global"
        }
    }
}

#Preview {
    NavigationStack { CommunityView() }
        .environment(FollowStore())
        .environment(ReactionStore())
        .environment(CommentStore())
        .environment(ModerationStore())
        .environment(RemoteFeedStore())
        .environment(PaywallController())
}
