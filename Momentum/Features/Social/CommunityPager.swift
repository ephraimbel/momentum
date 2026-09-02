import SwiftUI
import SwiftData
import UIKit
import CoreLocation

/// Per-pager reveal bookkeeping. Every routed post gets its own entrance, completion of one post
/// cannot suppress another, and recycled lazy pages stay complete for the rest of this visit.
struct CommunityRouteRevealState {
    private(set) var activated: Set<UUID> = []
    private(set) var completed: Set<UUID> = []

    func isActivated(_ id: UUID) -> Bool { activated.contains(id) }
    func shouldAnimate(_ id: UUID) -> Bool {
        activated.contains(id) && !completed.contains(id)
    }

    @discardableResult
    mutating func activate(_ id: UUID) -> Bool {
        activated.insert(id).inserted
    }

    mutating func complete(_ id: UUID) {
        guard activated.contains(id) else { return }
        completed.insert(id)
    }
}

private struct SharedReplaySelection: Identifiable {
    let id: UUID
    let payload: RouteReplayPayload
}

/// The TikTok moment for the community (owner call 2026-07-29): tap a tile on the Community grid
/// and swipe vertically through everyone's work, full-bleed. The mechanics mirror
/// `ImmersiveWorkoutPager` exactly (full-screen-height pages including safe-area insets — the
/// detail that makes paging snap instead of drift) — what changes is the content: a `FeedItem`
/// page carries its author's byline (with the preset-avatar mix), honest "Momentum community"
/// provenance, and a right rail of respect/comments/report.
struct CommunityPager: View {
    let items: [FeedItem]
    let startID: UUID
    /// The viewer's own handle — their own posts keep an inert byline (no self-profile push).
    var ownHandle: String? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(RemoteFeedStore.self) private var remoteFeed
    @Environment(\.colorScheme) private var colorScheme
    /// Byline tap → the athlete's profile pushes IN PLACE, over the post (the Instagram move).
    /// The old flow dismissed the whole pager, paused, then pushed from the wall — three visible
    /// beats that read as a glitch (owner report 2026-07-29). The pager's cover now carries its
    /// own NavigationStack, so the profile just slides over and back swipes home to the post.
    @State private var selectedAthlete: CommunityAthlete?
    /// Sheets belong to the stable pager root, not a lazily recycled page. A page-owned sheet can
    /// lose its presentation source while vertical paging remounts neighbors, which showed up as
    /// a warped half-sheet (or a dismissed pager) during a long community browse.
    @State private var commentsItem: FeedItem?
    @State private var replaySelection: SharedReplaySelection?
    /// Shared posts already hold their privacy-trimmed route in memory. Build the replay payload
    /// while the post remains visible, then present the finished scene; presenting first caused a
    /// blank full-screen beat while route smoothing ran behind it.
    @State private var replayPreparingID: UUID?
    @State private var replayPreparationTask: Task<Void, Never>?
    @State private var replayPreparationFailed = false
    /// Per-post browsing state survives lazy vertical-page recycling. It never changes the
    /// author's published cover choice; it only remembers what this viewer brought forward.
    @State private var photoHeroOverrides: [UUID: Bool] = [:]
    @State private var photoPageByPost: [UUID: Int] = [:]
    /// Neighboring lazy pages stay in memory, but only the page snapped on screen should own a
    /// live Mapbox view. The others render the cached route preview until they become current.
    @State private var visiblePostID: UUID?
    /// `scrollPosition` can transiently publish nil while a fast page gesture crosses between two
    /// targets. Keep the last real id separately so that gap never reactivates the original post's
    /// Mapbox view underneath the swipe.
    @State private var activePostID: UUID?
    @State private var verticalPrefetchTask: Task<Void, Never>?
    /// Activated and completed are separate so the initial false→true activation can remount a
    /// not-yet-ready Mapbox view, while true→completed does not remount the finished map. This also
    /// prevents a LazyVStack-recycled page from replaying its entrance during the same visit.
    @State private var routeReveals = CommunityRouteRevealState()

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let fullHeight = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                CommunityPostPage(
                                    item: item,
                                    isFirst: item.id == startID,
                                    isActive: (activePostID ?? startID) == item.id,
                                    canOpenAuthor: item.authorHandle != nil && item.authorHandle != ownHandle,
                                    topInset: geo.safeAreaInsets.top, bottomInset: geo.safeAreaInsets.bottom,
                                    photoHeroRequested: photoHeroBinding(for: item),
                                    photoPage: photoPageBinding(for: item.id),
                                    revealRoute: routeReveals.shouldAnimate(item.id),
                                    routeRevealActivated: routeReveals.isActivated(item.id),
                                    isPreparingReplay: replayPreparingID == item.id,
                                    onClose: { dismiss() },
                                    onOpenReplay: { prepareReplay(for: item) },
                                    onOpenComments: { commentsItem = item },
                                    onRouteBecameHero: { claimRouteReveal(for: item.id) },
                                    onRouteRevealCompleted: { completeRouteReveal(for: item.id) },
                                    onOpenAuthor: { openAthlete($0) })
                                .frame(width: geo.size.width, height: fullHeight)
                                .clipped()
                                // LazyVStack keeps neighboring full-screen pages mounted for a
                                // smooth swipe. They must not remain in the accessibility tree,
                                // otherwise VoiceOver (and UI automation) sees duplicate replay,
                                // comment, and close controls from posts that are off screen.
                                .accessibilityHidden((activePostID ?? startID) != item.id)
                                .id(item.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $visiblePostID)
                    .scrollIndicators(.hidden)
                    .ignoresSafeArea()
                    .onAppear {
                        // The tapped post could vanish between tap and present (a refresh
                        // re-minting pulse posts) — close rather than open on the wrong one.
                        guard items.contains(where: { $0.id == startID }) else { dismiss(); return }
                        claimRouteReveal(for: startID)
                        activePostID = startID
                        visiblePostID = startID
                        var tx = Transaction(); tx.disablesAnimations = true
                        withTransaction(tx) { proxy.scrollTo(startID, anchor: .top) }
                    }
                    .onChange(of: visiblePostID, initial: true) { _, id in
                        guard let id else { return }
                        if let activePostID, activePostID != id {
                            // One quiet confirmation when vertical paging actually settles. The
                            // scroll gesture itself stays silent, so a long browse never buzzes
                            // continuously under the athlete's finger.
                            Haptics.selection()
                        }
                        activePostID = id
                        claimRouteReveal(for: id)
                        prefetch(around: id)
                    }
                }
            }
            .background(Theme.background)
            .navigationBarHidden(true)
            .navigationDestination(item: $selectedAthlete) { AthleteProfileView(athlete: $0) }
        }
        .sheet(item: $commentsItem) { item in
            PostCommentsView(item: item)
        }
        .fullScreenCover(item: $replaySelection) { selection in
            SharedRouteReplayView(payload: selection.payload)
        }
        // The pager is a cover, so its Pro replay control needs a paywall host above this context.
        .nestedPaywallHost()
        .onDisappear {
            verticalPrefetchTask?.cancel()
            verticalPrefetchTask = nil
            replayPreparationTask?.cancel()
            replayPreparationTask = nil
            replayPreparingID = nil
        }
        .alert("Replay unavailable", isPresented: $replayPreparationFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This post doesn't include enough route data to replay.")
        }
    }

    private func prepareReplay(for item: FeedItem) {
        guard replayPreparingID == nil else { return }
        replayPreparingID = item.id
        replayPreparationTask?.cancel()
        replayPreparationTask = Task { @MainActor in
            let payload = await Task.detached(priority: .userInitiated) {
                RouteReplayPayload.sharedPost(item)
            }.value
            guard !Task.isCancelled else { return }
            replayPreparingID = nil
            replayPreparationTask = nil
            if let payload {
                replaySelection = .init(id: item.id, payload: payload)
            } else {
                replayPreparationFailed = true
            }
        }
    }

    private func claimRouteReveal(for id: UUID) {
        guard let item = items.first(where: { $0.id == id }),
              item.hasRenderableRoute else { return }
        let photosLead = !item.photosData.isEmpty
            && (photoHeroOverrides[id] ?? item.coverIsPhoto)
        // Reveal once per pager visit. Persisting this forever meant posts opened on a later day
        // skipped the requested entrance entirely; the in-memory sets prevent repeats while the
        // athlete is actively paging without suppressing future post opens.
        guard !photosLead else { return }
        routeReveals.activate(id)
    }

    private func completeRouteReveal(for id: UUID) {
        routeReveals.complete(id)
    }

    /// Warm the current post and one vertical neighbor each way. Photos decode into the shared
    /// cache; route neighbors render a static preview. The live Mapbox surface is still owned only
    /// by the snapped page, so prefetch never creates a second interactive map.
    private func prefetch(around id: UUID) {
        verticalPrefetchTask?.cancel()
        guard let center = items.firstIndex(where: { $0.id == id }) else { return }
        let neighbors = [center, center - 1, center + 1].filter(items.indices.contains)
        let scheme = colorScheme
        verticalPrefetchTask = Task { @MainActor in
            for index in neighbors {
                guard !Task.isCancelled else { return }
                let item = items[index]
                for data in item.photosData.prefix(2) {
                    ImageDownsampler.prefetch(data, maxPixel: 48)
                    ImageDownsampler.prefetch(data, maxPixel: 1400)
                }
                if index != center, let coords = item.routeCoordinates, coords.count > 1 {
                    _ = await FeedRouteSnapshots.image(
                        post: item.id, coordinates: coords, style: item.mapStyle, scheme: scheme,
                        size: CGSize(width: 430, height: 930),
                        endpointDiameter: RouteSnapshotter.EndpointMark.fullBleed)
                }
            }
        }
    }

    private func photoHeroBinding(for item: FeedItem) -> Binding<Bool> {
        Binding(
            get: {
                guard !item.photosData.isEmpty else { return false }
                return photoHeroOverrides[item.id] ?? item.coverIsPhoto
            },
            set: { photoHeroOverrides[item.id] = $0 })
    }

    private func photoPageBinding(for id: UUID) -> Binding<Int> {
        Binding(get: { photoPageByPost[id] ?? 0 },
                set: { photoPageByPost[id] = max(0, $0) })
    }

    /// Seeded athletes resolve locally and push instantly; real athletes fetch their page first
    /// (the same resolution the wall uses). A miss (offline/dark) leaves the post readable.
    private func openAthlete(_ handle: String) {
        if let seeded = CommunityDirectory.athlete(handle: handle) {
            selectedAthlete = seeded
            return
        }
        Task {
            if let remote = await remoteFeed.athlete(handle: handle) {
                selectedAthlete = remote
            }
        }
    }
}

// MARK: - Full-bleed photo paging

/// One attached-photo page inside the horizontal hero carousel.
enum FullBleedPage {
    case photo(Data)
}

/// Swipeable photos for a full-bleed page — the Instagram grammar: horizontal pages inside the
/// vertical feed, a quiet "1/3" counter top-right. The whole carousel trades the hero slot with
/// the route/body visual; photo order remains unchanged. A paging ScrollView, NOT a `.page` TabView:
/// TabView's embedded scroll view swallows the vertical swipe that begins on a photo
/// (`PhotoCarousel` learned this) and would trap the whole vertical pager.
struct FullBleedMediaPager: View {
    let pages: [FullBleedPage]
    @Binding var page: Int
    /// Distance from the very top to the counter pill (pages ignore the safe area, and hosts
    /// with top-right chrome pass extra room so the pill never collides).
    var pillTopPadding: CGFloat = 0

    private var scrollPage: Binding<Int?> {
        Binding(get: { page }, set: { page = max(0, $0 ?? 0) })
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { _, p in
                        pageView(p)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: scrollPage)
            // Warm the pages either side of the one being read, so a swipe lands on a decoded
            // photo instead of a grey placeholder. Free when they are already cached.
            .onChange(of: page, initial: true) { _, current in
                for neighbour in [current - 1, current + 1] where pages.indices.contains(neighbour) {
                    if case .photo(let d) = pages[neighbour] {
                        ImageDownsampler.prefetch(d, maxPixel: 1400)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if pages.count > 1 {
                    Text("\(page + 1)/\(pages.count)")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Theme.surface.opacity(0.85)))
                        .overlay(Capsule().stroke(Theme.hairline))
                        .padding(.top, pillTopPadding)
                        .padding(.trailing, Theme.Space.lg)
                        .accessibilityLabel("Media \(page + 1) of \(pages.count)")
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: pages.count, initial: true) { _, count in
            if count == 0 || page >= count { page = 0 }
        }
    }

    @ViewBuilder
    private func pageView(_ p: FullBleedPage) -> some View {
        switch p {
        case .photo(let data): PagedPhoto(data: data)
        }
    }
}

/// One page's photo, decoded off the first paint (full resolution — this IS the full-bleed view).
///
/// The TikTok treatment (owner call 2026-07-29): the WHOLE image always shows. A 9:16 shot fills
/// the page edge to edge (fit == fill at the page's own ratio); any other ratio aspect-FITS over
/// a blurred fill of itself, so the page still reads full-bleed with nothing cropped away.
struct PagedPhoto: View {
    let data: Data
    @State private var image: UIImage?
    @State private var preview: UIImage?

    var body: some View {
        // `Color.clear` takes EXACTLY the proposed page size; the photo renders as its overlay.
        // Without this containment the `scaledToFill` blur layer reported the image's own width
        // as the view's ideal size, which inflated the post page's ZStack past the screen — and
        // since the page frame centers-then-clips, the byline/title/stats overlay (a ZStack
        // sibling) slid half off the LEFT edge on every wide-photo post (owner screenshot
        // 2026-07-30: cut avatar, "idge loop", clipped close button).
        Color.clear
            .overlay {
                if let image {
                    ZStack {
                        Image(uiImage: image).resizable().scaledToFill()
                            .blur(radius: 40, opaque: true)
                            .overlay(Color.black.opacity(0.10))
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                } else if let preview {
                    Image(uiImage: preview).resizable().scaledToFill()
                        .scaleEffect(1.08)
                        .blur(radius: 28, opaque: true)
                } else {
                    Theme.surface
                }
            }
            .clipped()
            // The photo ARRIVES rather than pops. With the decode cache a revisit is instant and
            // this never plays; on a genuine first decode a 0.2s fade reads as the image resolving
            // instead of the page snapping from grey to photo.
            .animation(.easeOut(duration: 0.2), value: image == nil)
            // Downsampled off-main (the house tool; 1400px matches PhotoCarousel's full-bleed
            // setting) — `UIImage(data:)` in a MainActor task parsed and first-draw-decoded the
            // full-resolution bitmap on the very swipe that landed on this page.
            .task(id: MediaFingerprint.value(data)) {
                preview = nil
                image = nil
                preview = await ImageDownsampler.thumbnail(data, maxPixel: 48)
                guard !Task.isCancelled else { return }
                image = await ImageDownsampler.thumbnail(data, maxPixel: 1400)
            }
    }
}

// MARK: - One page

private struct CommunityPostPage: View {
    let item: FeedItem
    var isFirst: Bool
    var isActive: Bool
    var canOpenAuthor: Bool
    var topInset: CGFloat
    var bottomInset: CGFloat
    @Binding var photoHeroRequested: Bool
    @Binding var photoPage: Int
    var revealRoute: Bool
    var routeRevealActivated: Bool
    var isPreparingReplay: Bool
    var onClose: () -> Void
    var onOpenReplay: () -> Void
    var onOpenComments: () -> Void
    var onRouteBecameHero: () -> Void
    var onRouteRevealCompleted: () -> Void
    var onOpenAuthor: ((String) -> Void)?

    @Environment(ReactionStore.self) private var reactions
    @Environment(CommentStore.self) private var comments
    @Environment(ModerationStore.self) private var moderation
    @Environment(PaywallController.self) private var paywall
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showHint = false
    @State private var confirmingReport = false
    /// Whether THIS post's route is bookmarked — read once on appear, flipped locally on toggle
    /// (a per-page @Query over all saved routes would re-fire on every save anywhere).
    @State private var routeSaved = false
    /// The double-tap heart, mid-flight.
    @State private var burst = false
    /// Shared route pages use the same explorable Mapbox canvas as the owner's profile. The page
    /// owns the re-center control while the map owns gesture state.
    @State private var mapCamera = RouteMapCameraHandle()

    /// The horizontal media pages: the athlete's PHOTOGRAPHS, in order. The post's own visual is
    /// a separate hero/alternate surface, so swapping never breaks photo paging state.
    /// Resolved ONCE at init (the `FeedTileMedia.coords` pattern): as a computed var the body read
    /// it 2–3× per pass, each mapping the whole polyline — and every reaction anywhere invalidates
    /// every realized page (the rail reads the shared ReactionStore).
    private let mediaPages: [FullBleedPage]
    /// Does this post HAVE a visual of its own (a route to draw, muscles to light)? Resolved at
    /// init alongside the pages — it gates the thumbnail, and a mapless trail run has none.
    private let hasOwnVisual: Bool
    private let hasReplayRoute: Bool
    private var photosAreHero: Bool {
        !mediaPages.isEmpty && (photoHeroRequested || !hasOwnVisual)
    }

    init(item: FeedItem, isFirst: Bool, isActive: Bool, canOpenAuthor: Bool, topInset: CGFloat,
         bottomInset: CGFloat, photoHeroRequested: Binding<Bool>, photoPage: Binding<Int>,
         revealRoute: Bool, routeRevealActivated: Bool, isPreparingReplay: Bool,
         onClose: @escaping () -> Void, onOpenReplay: @escaping () -> Void,
         onOpenComments: @escaping () -> Void,
         onRouteBecameHero: @escaping () -> Void,
         onRouteRevealCompleted: @escaping () -> Void,
         onOpenAuthor: ((String) -> Void)?) {
        self.item = item
        self.isFirst = isFirst
        self.isActive = isActive
        self.canOpenAuthor = canOpenAuthor
        self.topInset = topInset
        self.bottomInset = bottomInset
        self._photoHeroRequested = photoHeroRequested
        self._photoPage = photoPage
        self.revealRoute = revealRoute
        self.routeRevealActivated = routeRevealActivated
        self.isPreparingReplay = isPreparingReplay
        self.onClose = onClose
        self.onOpenReplay = onOpenReplay
        self.onOpenComments = onOpenComments
        self.onRouteBecameHero = onRouteBecameHero
        self.onRouteRevealCompleted = onRouteRevealCompleted
        self.onOpenAuthor = onOpenAuthor
        let photos = item.photosData.map { FullBleedPage.photo($0) }
        // Remote arrays are untrusted. Only expose the Pro action when sanitization leaves a real
        // segment; malformed/duplicate-only rows should never lead into a dead replay screen.
        self.hasReplayRoute = RouteReplayPayload.canReplaySharedPost(item)
        self.hasOwnVisual = hasReplayRoute
            || item.muscles?.values.contains(where: { $0 > 0 }) == true
        // Photos stay together as one horizontal set. The author's cover choice decides whether
        // this set or the workout visual starts in the hero slot; the other occupies one explicit
        // swap rectangle above the byline.
        self.mediaPages = photos
    }

    var body: some View {
        ZStack {
            // Grouped so the gesture and the burst attach to the MEDIA, whichever form it took.
            Group {
                if photosAreHero {
                    photoHero
                        .transition(.opacity.combined(with: .scale(scale: 0.992)))
                        .accessibilityIdentifier("post-photos-hero")
                } else {
                    // Off-screen lazy neighbors use their cached preview. This page becomes
                    // interactive as soon as vertical paging snaps; keeping a single live map
                    // avoids GPU churn across the deck.
                    CommunityPageMedia(item: item, interactive: isActive,
                                       mapCameraHandle: mapCamera,
                                       revealRoute: revealRoute,
                                       onRouteRevealCompleted: onRouteRevealCompleted)
                        .id("community-route-\(item.id)-\(routeRevealActivated)")
                        // Keep the live Mapbox platform view in its real container. Moving it
                        // through matched geometry can blank the map and distort the page frame.
                        .transition(.opacity.combined(with: .scale(scale: 0.992)))
                        .accessibilityIdentifier(hasReplayRoute
                                                 ? "communityRouteSurface"
                                                 : "post-workout-visual-hero")
                }
            }
            // Double-tap the photo to like it — the gesture every social app has taught people,
            // and the one this post viewer was missing. It only ever LIKES (never un-likes: a
            // stray double-tap must not silently remove a like), and the rail's heart stays the
            // way to take one back. A tap gesture does not compete with the pager's horizontal
            // scroll, and the rail/thumbnail sit above this and take their own taps first.
            // `.simultaneousGesture`, NOT `.onTapGesture(count: 2)`. As an exclusive recognizer on
            // a full-bleed parent it arbitrated against every control layered above it — taps on
            // the rail were delayed or swallowed while it waited to see whether a second tap was
            // coming (caught bisecting a UI-test failure, 2026-08-29: the comment sheet stopped
            // opening). A simultaneous recognizer claims nothing, so buttons keep their taps and
            // the double-tap still fires.
            .simultaneousGesture(TapGesture(count: 2).onEnded { doubleTapLike() })
            .overlay { burstHeart }

            // ONE soft light scrim, bottom only (owner call 2026-08-20: "scrap the fade from the
            // top" — the media runs clean to the top edge; the bottom fade stays for the text
            // stack). Eased (SoftScrim), not two-stop: over a dark basemap a linear fade "ends
            // in a line" (owner report 2026-07-29).
            GeometryReader { geo in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    // 35% of the page, no more (owner call 2026-08-20 — the old bottomInset+430
                    // hazed half the screen). The reshaped SoftScrim curve reaches real opacity
                    // fast after its silent onset, so the byline at the stack's top still sits
                    // on coverage even though the fade is short.
                    SoftScrim.bottom(Theme.background)
                        .frame(height: geo.size.height * 0.35)
                }
            }

            // Neighbor pages stay mounted so their media is ready for the next swipe, but only
            // the snapped page owns controls. Besides preventing accidental off-screen actions,
            // this gives VoiceOver one Close/Replay/Comment set instead of a duplicate set for
            // every lazy neighbor in memory.
            if isActive {
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    if isFirst, showHint, !reduceMotion { swipeHint.transition(.opacity) }
                    bottomOverlay
                        // Full-screen media is a dense, spatial surface. At accessibility sizes the
                        // global app scale can make one fixed-width badge wider than the viewport,
                        // which shifts the entire overlay (including Close) off screen. Keep the
                        // overlay at the largest standard size while its complete content remains
                        // available to VoiceOver; the comments/profile reading views retain the
                        // app-wide accessibility scale.
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                }
                .padding(.horizontal, Theme.Space.lg)
                .padding(.top, topInset + Theme.Space.sm)
                .padding(.bottom, bottomInset + Theme.Space.lg)
            }
        }
        .contentShape(Rectangle())
        .confirmationDialog("Report this post?", isPresented: $confirmingReport, titleVisibility: .visible) {
            ForEach(ReportReason.allCases) { reason in
                Button(reason.rawValue) { moderation.reportPost(item.id, reason: reason); Haptics.success() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("We'll review it and hide it from your feed.") }
        .onChange(of: mediaPages.count) { _, count in
            if count == 0 { photoHeroRequested = false; photoPage = 0 }
            else if photoPage >= count { photoPage = 0 }
        }
        .task {
            guard isFirst else { return }
            withAnimation(.easeIn(duration: 0.4).delay(0.5)) { showHint = true }
            try? await Task.sleep(for: .seconds(2.6))
            withAnimation(.easeOut(duration: 0.5)) { showHint = false }
        }
    }

    @ViewBuilder
    private var photoHero: some View {
        if mediaPages.count > 1 {
            FullBleedMediaPager(pages: mediaPages, page: $photoPage,
                                pillTopPadding: topInset + Theme.Space.sm)
        } else if case .photo(let data)? = mediaPages.first {
            PagedPhoto(data: data).ignoresSafeArea()
        }
    }

    private func swapHero(toPhotos: Bool) {
        guard !toPhotos || !mediaPages.isEmpty else { return }
        if !toPhotos { onRouteBecameHero() }
        Haptics.selection()
        withAnimation(reduceMotion ? .easeOut(duration: 0.16)
                                   : .spring(response: 0.42, dampingFraction: 0.88)) {
            photoHeroRequested = toPhotos
        }
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                    .frame(width: 36, height: 36).background(Circle().fill(Theme.surface)).overlay(Circle().stroke(Theme.hairline))
            }
            .accessibilityLabel("Close")
            Spacer()
            if !photosAreHero, hasReplayRoute {
                VStack(spacing: Theme.Space.sm) {
                    let locked = !paywall.isEntitled(to: .routeReplay)
                    Button {
                        if locked { paywall.present(for: .routeReplay) }
                        else { onOpenReplay(); Haptics.light() }
                    } label: {
                        Group {
                            if isPreparingReplay {
                                ProgressView().controlSize(.small).tint(Theme.purple)
                            } else {
                                Image(systemName: locked ? "lock.fill" : "play.fill")
                                    .font(.system(size: 14, weight: .bold))
                            }
                        }
                            .foregroundStyle(Theme.ink)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Theme.surface))
                            .overlay(Circle().stroke(locked ? Theme.proLavender.opacity(0.55) : Theme.hairline))
                    }
                    .disabled(isPreparingReplay)
                    .accessibilityIdentifier("routeReplayButton")
                    .accessibilityLabel(isPreparingReplay ? "Preparing route replay"
                                        : (locked ? "Replay route, Pro" : "Replay route"))
                    .accessibilityHint(locked ? "Opens the Pro offer" : "Animates this shared route")
                    if mapCamera.isExplored {
                        Button { mapCamera.recenter() } label: {
                            Image(systemName: "viewfinder")
                                .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Theme.surface))
                                .overlay(Circle().stroke(Theme.hairline))
                        }
                        .accessibilityLabel("Re-center route")
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                }
                .animation(.easeOut(duration: 0.25), value: mapCamera.isExplored)
            }
        }
    }

    private var swipeHint: some View {
        VStack(spacing: 2) {
            Image(systemName: "chevron.compact.up").font(.system(size: 22, weight: .semibold))
            Text("Swipe").font(.rounded(Theme.FontSize.caption, weight: .semibold))
        }
        .foregroundStyle(Theme.inkSecondary)
        .padding(.bottom, Theme.Space.md)
    }

    /// Byline + story bottom-left, actions bottom-right — the TikTok composition, in our type.
    /// Like on double-tap, plus the heart that confirms it. Idempotent by design.
    private func doubleTapLike() {
        if !reactions.hasReacted(item.id) {
            reactions.toggle(item.id)
            Haptics.medium()
        }
        guard !reduceMotion else { return }
        burst = true
        withAnimation(.easeOut(duration: 0.55)) { burst = false }
    }

    /// The confirmation: a heart that swells and fades over the photo. Transform-only, and it
    /// never appears under Reduce Motion — the like still registers, it just doesn't fly.
    @ViewBuilder private var burstHeart: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 96, weight: .bold))
            .foregroundStyle(Theme.like)
            .shadow(color: .black.opacity(0.25), radius: 12)
            .scaleEffect(burst ? 1.0 : 1.5)
            .opacity(burst ? 0.92 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var bottomOverlay: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                // One alternate-media door. Tapping it exchanges the complete photo set and the
                // route/body canvas; it never leaves the post or opens a second viewer.
                if hasOwnVisual, !mediaPages.isEmpty {
                    if photosAreHero {
                        // `FeedTileMedia` is the grid's own compact renderer. The full-page map is
                        // intentionally not shrunk into this card because its camera/annotations
                        // are composed for a screen, not 70 points.
                        PostMediaThumb(label: item.muscles != nil ? "Strength session visual" : "Route map") {
                            FeedTileMedia(item: item, respectsPhotoCover: false)
                        } onTap: { swapHero(toPhotos: false) }
                    } else if let photo = selectedPhoto {
                        PostMediaThumb(label: mediaPages.count == 1 ? "Workout photo" : "Workout photos") {
                            PagedPhoto(data: photo)
                        } onTap: { swapHero(toPhotos: true) }
                    }
                }
                if let context = item.earnedContext, !context.isEmpty {
                    earnedContextPill(context)
                }
                byline
                Text(item.title)
                    .font(.display(26, weight: .black)).foregroundStyle(Theme.ink).lineLimit(2)
                if let caption = item.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.rounded(Theme.FontSize.body, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary).lineLimit(2)
                }
                let cells = item.metrics.map { StatGrid.Cell(value: $0.value, label: $0.label) }
                if !cells.isEmpty {
                    StatGrid(cells: cells, valueSize: 22, leading: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actionRail
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedPhoto: Data? {
        let photos = item.photosData
        return photos.indices.contains(photoPage) ? photos[photoPage] : photos.first
    }

    /// One context line maximum. Records/milestones earn the iridescent mark; plan provenance is
    /// useful but deliberately plain, preserving the app's earned-only accent rule.
    private func earnedContextPill(_ label: String) -> some View {
        let earned = !label.lowercased().hasPrefix("planned ")
        return HStack(spacing: 6) {
            if earned {
                Circle().fill(IridescentMaterial()).frame(width: 7, height: 7)
            } else {
                Image(systemName: "calendar")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.inkSecondary)
            }
            Text(label)
                .font(.rounded(Theme.FontSize.label, weight: .bold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .layoutPriority(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Theme.surface.opacity(0.9)))
        .overlay(Capsule().stroke(Theme.hairline))
        // Accept the post column's width proposal. `fixedSize(horizontal:)` let a scaled badge
        // dictate the width of the full-screen HStack and was the source of the zoomed/off-page
        // profile appearance at large text sizes.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(label)
        .accessibilityIdentifier("post-earned-context")
    }

    /// Who this is — avatar (photo / bundled face / preset look / monogram), name, provenance.
    /// Honest labeling holds in the immersive view too: seeded posts stay unmissably marked.
    @ViewBuilder
    private var byline: some View {
        if canOpenAuthor, let handle = item.authorHandle {
            Button { onOpenAuthor?(handle) } label: { bylineLabel }
                .buttonStyle(.plain)
                .accessibilityLabel("View \(item.authorName)'s profile")
        } else {
            // `.disabled(true)` applies SwiftUI's disabled opacity to the whole label. That made
            // one's own byline—and every byline in a visited athlete's pager—look washed out over
            // pale media. Inert identity remains full-strength and simply is not a button.
            bylineLabel
                .accessibilityElement(children: .combine)
                .accessibilityLabel(item.authorName)
        }
    }

    private var bylineLabel: some View {
        HStack(spacing: Theme.Space.sm) {
            AvatarView(photo: item.avatarData, name: item.authorName, size: 40,
                       imageName: item.communityAvatarAsset, preset: item.communityPreset)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.authorName)
                        .font(.rounded(15, weight: .semibold)).foregroundStyle(Theme.ink)
                        .lineLimit(1).layoutPriority(1)
                    if item.isPro {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.purple)
                            .accessibilityLabel("Verified Pro")
                    }
                    // Full ink, not tertiary gray (owner call 2026-07-30): this line sits on
                    // top of arbitrary media, and tertiary vanished against a pale sky even
                    // with the scrim. Ink adapts white/near-black with the theme; hierarchy
                    // against the name comes from weight, never from fading the text out.
                    Text("· \(item.date.formatted(.relative(presentation: .named)))")
                        .font(.rounded(15, weight: .regular)).foregroundStyle(Theme.ink)
                        .lineLimit(1)
                }
                if !provenance.isEmpty {
                    Text(provenance)
                        .font(.rounded(Theme.FontSize.label, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary).lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
    }

    /// "@handle · City" — the handle leads, straight under the name (owner call 2026-07-30: the
    /// "Momentum community" prefix came out; it pushed the handle mid-line and read as clutter.
    /// Seeded-content provenance is documentation-level truth, not a per-post byline stamp).
    private var provenance: String {
        var parts: [String] = []
        if let handle = item.authorHandle { parts.append("@\(handle)") }
        if let loc = item.location { parts.append(loc) }
        return parts.joined(separator: " · ")
    }

    // MARK: The rail — respect · comments · report

    /// ONE rail, every post (owner call 2026-07-30): heart → comments → save → options, in that
    /// order, always all four. The save used to appear only on route posts, so the rail's shape
    /// jumped from post to post and the whole column read as unstructured. Each control also
    /// carries the same count-line footprint (invisible where a count is meaningless), so the
    /// circle-to-circle rhythm is identical on every page.
    private var actionRail: some View {
        VStack(spacing: Theme.Space.md) {
            respectControl
            commentControl
            saveControl
            Menu {
                Button { confirmingReport = true } label: { Label("Report post", systemImage: "flag") }
                if let handle = item.authorHandle, canOpenAuthor {
                    Button(role: .destructive) { moderation.block(handle); Haptics.medium() } label: {
                        Label("Block \(item.authorName)", systemImage: "hand.raised")
                    }
                }
            } label: {
                railControl(count: nil) {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                }
            }
            .accessibilityLabel("Post options")
        }
    }

    private var respectControl: some View {
        let reacted = reactions.hasReacted(item.id)
        return Button {
            reactions.toggle(item.id); Haptics.light()
        } label: {
            railControl(count: "\(reactions.count(for: item))") {
                Image(systemName: reacted ? "heart.fill" : "heart")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(reacted ? Theme.like : Theme.ink)
                    .scaleEffect(reacted && !reduceMotion ? 1.12 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: reacted)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(reacted ? "Liked" : "Like")
        .accessibilityValue("\(reactions.count(for: item))")
    }

    private var commentControl: some View {
        let count = commentCount   // once — the label + a11y value read it separately
        return Button(action: onOpenComments) {
            railControl(count: count > 0 ? "\(count)" : nil) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Comments")
        .accessibilityValue("\(count)")
        .accessibilityIdentifier("active-post-comments")
    }

    /// Bookmark this post into the athlete's own library. A route post saves as training material
    /// (browsable on a map before a run); a routeless post (a strength day, a swim) still saves —
    /// it keeps the post, rendered by its sport in the library. Saved state reads on appear and
    /// flips locally; the wall's "Saved" link and the list update through their own queries.
    private var saveControl: some View {
        Button {
            toggleSaved()
        } label: {
            railControl(count: nil) {
                Image(systemName: routeSaved ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .scaleEffect(routeSaved && !reduceMotion ? 1.08 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: routeSaved)
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            let id = item.id
            var q = FetchDescriptor<SavedRoute>(predicate: #Predicate { $0.postID == id })
            q.fetchLimit = 1
            routeSaved = ((try? modelContext.fetch(q)) ?? []).isEmpty == false
        }
        .accessibilityLabel(routeSaved ? "Saved. Tap to remove."
                            : (item.hasRenderableRoute ? "Save this route" : "Save this post"))
    }

    private func toggleSaved() {
        let id = item.id
        let q = FetchDescriptor<SavedRoute>(predicate: #Predicate { $0.postID == id })
        let existing = (try? modelContext.fetch(q)) ?? []
        if existing.isEmpty {
            // Routeless posts save too (the rail is identical everywhere) — they keep the post,
            // carried by sport rather than a polyline.
            let pts = item.sanitizedRouteLatLon ?? []
            let km = pts.isEmpty ? 0 : item.distanceKm
            modelContext.insert(SavedRoute(postID: id, title: item.title,
                                           authorName: item.authorName, authorHandle: item.authorHandle,
                                           city: item.location, km: km, pts: pts, mapStyle: item.mapStyle,
                                           sport: item.type))
            routeSaved = true
            Haptics.success()
        } else {
            existing.forEach { modelContext.delete($0) }
            routeSaved = false
            Haptics.light()
        }
        try? modelContext.save()
    }

    /// Visible comment count. Badged community posts: seeded + the viewer's own, minus
    /// moderation-hidden — the card feed's exact arithmetic. REAL posts: the server's count
    /// (never seeded — fabricating comments on a real person's post is the one honesty line the
    /// generator must not cross; caught 2026-07-30), maxed with the locally-pulled/own set so a
    /// just-posted comment shows before the next feed refresh.
    /// The seeded half is memoized per post (non-observed box): `CommunityComments.seed` runs RNG
    /// draws + directory rejection-sampling per comment, and this used to run per render, twice.
    /// Own comments stay live (they're already moderation-filtered above the split).
    private final class SeedCountMemo {
        var id: UUID?
        var count = 0
    }
    @State private var seedCountMemo = SeedCountMemo()
    private var commentCount: Int {
        let own = comments.comments(for: item.id).filter(moderation.isVisible)
        guard item.isCommunity else { return max(item.remoteCommentCount ?? 0, own.count) }
        if seedCountMemo.id != item.id {
            seedCountMemo.id = item.id
            // NOTE (2026-08-28): this re-derives the thread from a subset of the post's fields
            // while `PostCommentsView` builds it from the whole item. The counts agree only because
            // thread SIZE is drawn from its own stream — a badge and the list it opens agreeing by
            // construction rather than by luck wants ONE call. Left alone deliberately: the
            // item-taking overload is a sibling's in-flight API and calling it from here would make
            // this file un-buildable against HEAD.
            seedCountMemo.count = CommunityComments.seed(
                for: item.id, postDate: item.date, reactions: item.baseReactions,
                type: item.type, authorHandle: item.authorHandle)
                .filter(moderation.isVisible).count
        }
        return seedCountMemo.count + own.count
    }

    /// The rail sits over an unpredictable photograph, so it wears the app's GLASS — the same
    /// treatment every map-floating control already uses — instead of a flat `Theme.surface` fill.
    /// A solid light disc vanished into a bright sky and read as a hard white sticker on a dark
    /// night shot; glass adapts to whatever is behind it and stays quiet on both (owner ask
    /// 2026-08-29: "better visible but still subtle"). The hairline goes with it — glass carries
    /// its own rim, and the two together read as a double edge.
    private func railCircle<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: 44, height: 44)
            .momentumGlass(in: Circle())
    }

    /// One rail control = circle + a count line of FIXED height. Controls without a count (save,
    /// options) and zero-count comments keep an invisible line, so every circle sits the same
    /// distance from its neighbors on every post — the rail never re-shapes between pages.
    private func railControl<Content: View>(count: String?,
                                            @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 3) {
            railCircle(content)
            Text(count ?? "0")
                .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
                .foregroundStyle(Theme.ink)
                // The count reads straight over the photograph with no chrome of its own, so it
                // carries a soft shadow the way a caption burned into an image does.
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .opacity(count == nil ? 0 : 1)
                .accessibilityHidden(count == nil)
        }
    }
}

// MARK: - Page media

/// Full-bleed media for one page: photo at full resolution → igniting muscle map → route snapshot
/// (silhouette placeholder, then the shared cached render on the fast lane — the reading-view rule:
/// the page the athlete is looking at never queues behind a backlog) → sport glyph.
private struct CommunityPageMedia: View {
    let item: FeedItem
    var interactive: Bool = false
    var mapCameraHandle: RouteMapCameraHandle? = nil
    var revealRoute: Bool = false
    var onRouteRevealCompleted: () -> Void = {}
    /// Mapped once at view creation — see `FeedTileMedia.coords` (the same hot-getter lesson).
    private let coords: [CLLocationCoordinate2D]?

    init(item: FeedItem, interactive: Bool = false,
         mapCameraHandle: RouteMapCameraHandle? = nil, revealRoute: Bool = false,
         onRouteRevealCompleted: @escaping () -> Void = {}) {
        self.item = item
        self.interactive = interactive
        self.mapCameraHandle = mapCameraHandle
        self.revealRoute = revealRoute
        self.onRouteRevealCompleted = onRouteRevealCompleted
        self.coords = item.routeCoordinates
    }

    @Environment(\.colorScheme) private var colorScheme
    @State private var snapshot: UIImage?

    var body: some View {
        GeometryReader { geo in
            // Already rendered? Draw it on frame one. The pager's `LazyVStack` throws a page's
            // `@State` away as it leaves, so swiping back up used to show the grey silhouette
            // again and crossfade a map that had been in hand the whole time (2026-08-29).
            let cached = FeedRouteSnapshots.cachedImage(
                post: item.id, style: item.mapStyle, scheme: colorScheme,
                size: geo.size == .zero ? CGSize(width: 430, height: 930) : geo.size,
                endpointDiameter: RouteSnapshotter.EndpointMark.fullBleed)
            let map = snapshot ?? cached
            Group {
                if let muscles = item.muscles, muscles.values.contains(where: { $0 > 0 }) {
                    ZStack {
                        IridescentWash()
                        AnatomyGlowView(activation: muscles, sequential: true)
                            .padding(Theme.Space.xl)
                    }
                } else if let coords, coords.count > 1 {
                    ZStack {
                        // This synchronous route is the guarantee: every post has meaningful
                        // pixels on frame one, even with no cached snapshot, no network, or a slow
                        // Mapbox style. A cached render upgrades it when one is already available.
                        routeFallback(map: map, coords: coords, size: geo.size)

                        if interactive {
                            // The live surface fades over the already-painted route only after its
                            // basemap AND both route layers exist. Its loader is transparent so it
                            // can never replace the fallback with a blank rectangle.
                            RouteMapView(coordinates: coords, style: item.mapStyle,
                                         interactive: true, cameraHandle: mapCameraHandle,
                                         revealOnLoad: revealRoute, loadingBackground: .clear,
                                         onRevealCompleted: onRouteRevealCompleted)
                        }
                    }
                } else {
                    // The SAME deal the wall tile drew (2026-08-29). A tile zooms into this page,
                    // so if the tile wears this post's dealt tint and the page wears the canonical
                    // one, the transition crossfades colour mid-flight — the tapped picture and the
                    // one that lands are visibly two pictures. `WashVariation` is seeded from the
                    // post id and its offsets are in units of the symbol's own size, so the tile's
                    // 40pt deal and this page's 96pt one are the same composition at two scales.
                    let deal = WashVariation(seed: item.id)
                    let size = 96 * deal.glyphScale
                    ZStack {
                        IridescentWash(variation: deal)
                        Image(systemName: item.type.systemImage)
                            .font(.system(size: size, weight: .bold))
                            .foregroundStyle(Theme.ink.opacity(deal.glyphInk))
                            .offset(x: size * deal.glyphOffsetX, y: size * deal.glyphOffsetY)
                    }
                }
            }
            .animation(.easeOut(duration: 0.25), value: map != nil)
            .task(id: "\(item.id)-\(colorScheme == .dark)") {
                guard !interactive, let coords, coords.count > 1, map == nil else { return }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-test-social") { return }
                #endif
                // The page being looked at retries for as long as it's on screen — the reading
                // view's rule; a transient tile hiccup must not strand a full-bleed silhouette.
                while !Task.isCancelled, snapshot == nil {
                    snapshot = await FeedRouteSnapshots.image(
                        post: item.id, coordinates: coords, style: item.mapStyle, scheme: colorScheme,
                        size: geo.size == .zero ? CGSize(width: 430, height: 930) : geo.size,
                        urgent: true, endpointDiameter: RouteSnapshotter.EndpointMark.fullBleed)
                    if snapshot == nil { try? await Task.sleep(for: .seconds(2)) }
                }
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func routeFallback(map: UIImage?, coords: [CLLocationCoordinate2D],
                               size: CGSize) -> some View {
        ZStack {
            Theme.background
            if let map {
                Image(uiImage: map).resizable().scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .transition(.opacity)
            } else {
                RouteSilhouette(coords: coords, maxPoints: 800)
                    .stroke(Theme.route,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round,
                                               lineJoin: .round))
                    .padding(Theme.Space.xxl)
                RouteEndpointMarks(coords: coords, inset: Theme.Space.xxl,
                                   diameter: RouteSnapshotter.EndpointMark.fullBleed)
            }
        }
    }
}
