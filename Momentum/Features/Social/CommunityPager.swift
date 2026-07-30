import SwiftUI
import SwiftData
import UIKit
import CoreLocation

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
    /// Byline tap → the athlete's profile pushes IN PLACE, over the post (the Instagram move).
    /// The old flow dismissed the whole pager, paused, then pushed from the wall — three visible
    /// beats that read as a glitch (owner report 2026-07-29). The pager's cover now carries its
    /// own NavigationStack, so the profile just slides over and back swipes home to the post.
    @State private var selectedAthlete: CommunityAthlete?

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
                                    canOpenAuthor: item.authorHandle != nil && item.authorHandle != ownHandle,
                                    topInset: geo.safeAreaInsets.top, bottomInset: geo.safeAreaInsets.bottom,
                                    onClose: { dismiss() },
                                    onOpenAuthor: { openAthlete($0) })
                                .frame(width: geo.size.width, height: fullHeight)
                                .clipped()
                                .id(item.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollIndicators(.hidden)
                    .ignoresSafeArea()
                    .onAppear {
                        // The tapped post could vanish between tap and present (a refresh
                        // re-minting pulse posts) — close rather than open on the wrong one.
                        guard items.contains(where: { $0.id == startID }) else { dismiss(); return }
                        var tx = Transaction(); tx.disablesAnimations = true
                        withTransaction(tx) { proxy.scrollTo(startID, anchor: .top) }
                    }
                }
            }
            .background(Theme.background)
            .navigationBarHidden(true)
            .navigationDestination(item: $selectedAthlete) { AthleteProfileView(athlete: $0) }
        }
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

/// One horizontal page of a full-bleed post: the activity's own visual, or one attached photo.
enum FullBleedPage {
    case primary(AnyView)
    case photo(Data)
}

/// Swipeable media for a full-bleed page — the Instagram grammar: horizontal pages inside the
/// vertical feed, a quiet "1/3" counter top-right. The COVER RULE (owner call 2026-07-29) rides
/// on page order: the activity's own visual (route/muscle) is page one and photos page behind
/// it, unless the author flipped "Photo as cover". A paging ScrollView, NOT a `.page` TabView:
/// TabView's embedded scroll view swallows the vertical swipe that begins on a photo
/// (`PhotoCarousel` learned this) and would trap the whole vertical pager.
struct FullBleedMediaPager: View {
    let pages: [FullBleedPage]
    /// Distance from the very top to the counter pill (pages ignore the safe area, and hosts
    /// with top-right chrome pass extra room so the pill never collides).
    var pillTopPadding: CGFloat = 0

    @State private var page: Int? = 0

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
            .scrollPosition(id: $page)
            .overlay(alignment: .topTrailing) {
                if pages.count > 1 {
                    Text("\((page ?? 0) + 1)/\(pages.count)")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Theme.surface.opacity(0.85)))
                        .overlay(Capsule().stroke(Theme.hairline))
                        .padding(.top, pillTopPadding)
                        .padding(.trailing, Theme.Space.lg)
                        .accessibilityLabel("Media \((page ?? 0) + 1) of \(pages.count)")
                }
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func pageView(_ p: FullBleedPage) -> some View {
        switch p {
        case .primary(let view): view
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
                } else {
                    Theme.surface
                }
            }
            .clipped()
            // Downsampled off-main (the house tool; 1400px matches PhotoCarousel's full-bleed
            // setting) — `UIImage(data:)` in a MainActor task parsed and first-draw-decoded the
            // full-resolution bitmap on the very swipe that landed on this page.
            .task { image = await ImageDownsampler.thumbnail(data, maxPixel: 1400) }
    }
}

// MARK: - One page

private struct CommunityPostPage: View {
    let item: FeedItem
    var isFirst: Bool
    var canOpenAuthor: Bool
    var topInset: CGFloat
    var bottomInset: CGFloat
    var onClose: () -> Void
    var onOpenAuthor: ((String) -> Void)?

    @Environment(ReactionStore.self) private var reactions
    @Environment(CommentStore.self) private var comments
    @Environment(ModerationStore.self) private var moderation
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showHint = false
    @State private var showingComments = false
    @State private var confirmingReport = false
    /// Whether THIS post's route is bookmarked — read once on appear, flipped locally on toggle
    /// (a per-page @Query over all saved routes would re-fire on every save anywhere).
    @State private var routeSaved = false

    /// The horizontal media pages, cover rule applied: the activity's own visual leads and
    /// photos ride behind it — flipped when the author chose a photo cover; photos alone when
    /// the post has no route/muscle visual (mapless trail runs).
    /// Resolved ONCE at init (the `FeedTileMedia.coords` pattern): as a computed var the body read
    /// it 2–3× per pass, each mapping the whole polyline — and every reaction anywhere invalidates
    /// every realized page (the rail reads the shared ReactionStore).
    private let mediaPages: [FullBleedPage]

    init(item: FeedItem, isFirst: Bool, canOpenAuthor: Bool, topInset: CGFloat,
         bottomInset: CGFloat, onClose: @escaping () -> Void, onOpenAuthor: ((String) -> Void)?) {
        self.item = item
        self.isFirst = isFirst
        self.canOpenAuthor = canOpenAuthor
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.onClose = onClose
        self.onOpenAuthor = onOpenAuthor
        let photos = item.photosData.map { FullBleedPage.photo($0) }
        let hasOwnVisual = (item.routeCoordinates?.count ?? 0) > 1
            || item.muscles?.values.contains(where: { $0 > 0 }) == true
        if !hasOwnVisual {
            self.mediaPages = photos
        } else {
            let primary = [FullBleedPage.primary(AnyView(CommunityPageMedia(item: item)))]
            self.mediaPages = item.coverIsPhoto ? photos + primary : primary + photos
        }
    }

    var body: some View {
        ZStack {
            if mediaPages.count > 1 {
                FullBleedMediaPager(pages: mediaPages, pillTopPadding: topInset + Theme.Space.sm)
            } else if case .photo(let data)? = mediaPages.first {
                PagedPhoto(data: data).ignoresSafeArea()
            } else {
                CommunityPageMedia(item: item)
            }

            // Soft light scrims keep ink legible over any media. Eased (SoftScrim), not two-stop:
            // over a dark basemap a linear fade "ends in a line" (owner report 2026-07-29).
            VStack(spacing: 0) {
                SoftScrim.top(Theme.background)
                    .frame(height: topInset + 150)
                Spacer(minLength: 0)
                // Taller than the profile pager's: this overlay stacks byline + title + caption +
                // stats, and a busy basemap's POI labels bled through the byline at 320.
                SoftScrim.bottom(Theme.background)
                    .frame(height: bottomInset + 430)
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if isFirst, showHint, !reduceMotion { swipeHint.transition(.opacity) }
                bottomOverlay
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, topInset + Theme.Space.sm)
            .padding(.bottom, bottomInset + Theme.Space.lg)
        }
        .contentShape(Rectangle())
        .sheet(isPresented: $showingComments) { PostCommentsView(item: item) }
        .confirmationDialog("Report this post?", isPresented: $confirmingReport, titleVisibility: .visible) {
            ForEach(ReportReason.allCases) { reason in
                Button(reason.rawValue) { moderation.reportPost(item.id, reason: reason); Haptics.success() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("We'll review it and hide it from your feed.") }
        .task {
            guard isFirst else { return }
            withAnimation(.easeIn(duration: 0.4).delay(0.5)) { showHint = true }
            try? await Task.sleep(for: .seconds(2.6))
            withAnimation(.easeOut(duration: 0.5)) { showHint = false }
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
    private var bottomOverlay: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
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
    }

    /// Who this is — avatar (photo / bundled face / preset look / monogram), name, provenance.
    /// Honest labeling holds in the immersive view too: seeded posts stay unmissably marked.
    private var byline: some View {
        Button {
            if canOpenAuthor, let handle = item.authorHandle { onOpenAuthor?(handle) }
        } label: {
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
        .buttonStyle(.plain)
        .disabled(!canOpenAuthor)
        .accessibilityLabel(canOpenAuthor ? "View \(item.authorName)'s profile" : item.authorName)
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
        return Button { showingComments = true } label: {
            railControl(count: count > 0 ? "\(count)" : nil) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Comments")
        .accessibilityValue("\(count)")
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
                            : (item.routeLatLon != nil ? "Save this route" : "Save this post"))
    }

    private func toggleSaved() {
        let id = item.id
        let q = FetchDescriptor<SavedRoute>(predicate: #Predicate { $0.postID == id })
        let existing = (try? modelContext.fetch(q)) ?? []
        if existing.isEmpty {
            // Routeless posts save too (the rail is identical everywhere) — they keep the post,
            // carried by sport rather than a polyline.
            let pts = item.routeLatLon ?? []
            // The stat's leading token is "5.5 mi" — take the number, convert back to km.
            let miToken = item.metrics.first?.value.split(separator: " ").first.map(String.init)
            let km = pts.isEmpty ? 0 : (miToken.flatMap(Double.init).map { $0 / 0.621371 } ?? 0)
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
            seedCountMemo.count = CommunityComments.seed(
                for: item.id, postDate: item.date, reactions: item.baseReactions,
                type: item.type, authorHandle: item.authorHandle)
                .filter(moderation.isVisible).count
        }
        return seedCountMemo.count + own.count
    }

    private func railCircle<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: 44, height: 44)
            .background(Circle().fill(Theme.surface))
            .overlay(Circle().stroke(Theme.hairline))
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
                .foregroundStyle(Theme.inkSecondary)
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
    /// Mapped once at view creation — see `FeedTileMedia.coords` (the same hot-getter lesson).
    private let coords: [CLLocationCoordinate2D]?

    init(item: FeedItem) {
        self.item = item
        self.coords = item.routeCoordinates
    }

    @Environment(\.colorScheme) private var colorScheme
    @State private var snapshot: UIImage?

    var body: some View {
        GeometryReader { geo in
            Group {
                if let muscles = item.muscles, muscles.values.contains(where: { $0 > 0 }) {
                    ZStack {
                        IridescentWash()
                        AnatomyGlowView(activation: muscles, sequential: true)
                            .padding(Theme.Space.xl)
                    }
                } else if let coords, coords.count > 1 {
                    ZStack {
                        Theme.background
                        if let snapshot {
                            Image(uiImage: snapshot).resizable().scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .transition(.opacity)
                        } else {
                            RouteSilhouette(coords: coords)
                                .stroke(Theme.route, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                                .padding(Theme.Space.xxl)
                            RouteEndpointMarks(coords: coords, inset: Theme.Space.xxl,
                                               diameter: RouteSnapshotter.EndpointMark.fullBleed)
                        }
                    }
                } else {
                    ZStack {
                        IridescentWash()
                        Image(systemName: item.type.systemImage)
                            .font(.system(size: 96, weight: .bold))
                            .foregroundStyle(Theme.ink.opacity(0.85))
                    }
                }
            }
            .animation(.easeOut(duration: 0.25), value: snapshot != nil)
            .task(id: "\(item.id)-\(colorScheme == .dark)") {
                guard let coords, coords.count > 1 else { return }
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
}
