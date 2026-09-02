import Foundation
import Observation

/// Remote posts for the Community feed (docs/SOCIAL-LAYER.md Slice 6). Pull-based: `refresh` and
/// `loadMore` page through the `feed_page` RPC, resolve each page's photos/avatars through the
/// disk cache, and hand `CommunityView` ready-to-render `FeedItem`s. Empty for guests and dark
/// builds — the seeded community IS the offline experience, so nothing here ever blocks the UI.
@MainActor
@Observable
final class RemoteFeedStore {
    /// Wired once in `MomentumApp`; nil in previews/tests → store stays empty and inert.
    @ObservationIgnored var backend: (any SocialBackending)?
    /// The viewer's reaction state rides in on feed rows and merges here so counts stay exact.
    @ObservationIgnored var reactions: ReactionStore?
    /// The server's follow graph merges in on refresh (cross-device consistency).
    @ObservationIgnored var follows: FollowStore?
    /// Comments written while there was no session (guest, offline) are retried from here —
    /// a feed refresh is the app's one reliable "the backend is reachable now" moment.
    @ObservationIgnored var comments: CommentStore?

    private(set) var items: [FeedItem] = []
    private(set) var isLoading = false
    /// Changes whenever the rendered remote feed changes, even when its row count does not. The
    /// community assembler keys on this rather than `items.count`, so an edited caption/photo,
    /// refreshed reaction total, or same-sized first page cannot remain stale on screen.
    private(set) var revision = 0
    private var cursor: FeedCursor?
    private var scopeLoaded: FeedScope?
    /// Latest refresh owns the store. Scope switches intentionally supersede an in-flight request;
    /// older network/materialization completions are discarded instead of leaking across tabs.
    private var requestGeneration = 0

    static let pageSize = 20

    /// Replace the feed with the first remote page for `scope`. No-op when unavailable.
    func refresh(scope: FeedScope) async {
        requestGeneration += 1
        let generation = requestGeneration
        // This request supersedes any previous owner of the spinner. Reset first so a backend that
        // disappeared during the older request cannot strand the feed in a permanent loading state.
        isLoading = false
        // Switching scope clears immediately. A failed Following fetch therefore shows the honest
        // local Following wall, never remote Everyone rows left over from the request it replaced.
        if scope != scopeLoaded {
            items = []
            cursor = nil
            scopeLoaded = scope
            revision &+= 1
        }
        // Availability can change while the athlete is in the app. Scope ownership still has to
        // move when offline, otherwise the previous scope's cached remote rows bleed into this one.
        guard let backend else { return }
        isLoading = true
        defer {
            if requestGeneration == generation { isLoading = false }
        }
        guard await backend.isAvailable,
              requestGeneration == generation, scopeLoaded == scope, !Task.isCancelled
        else { return }
        if let remoteFollowing = await backend.pullFollowing() {
            guard requestGeneration == generation, !Task.isCancelled else { return }
            follows?.merge(remote: remoteFollowing)
        }
        guard requestGeneration == generation, !Task.isCancelled else { return }
        // Deliver anything the network never saw. Reaching here means a session exists, so this
        // is exactly the moment a guest's taps and typed comments become real for everyone else
        // — the migration the guest-first app promises (see `CommentStore.pending`).
        reactions?.flushPending()
        comments?.flushPending()
        guard let page = await backend.feed(scope: scope, cursor: nil, limit: Self.pageSize) else { return }
        guard requestGeneration == generation, scopeLoaded == scope, !Task.isCancelled else { return }
        let resolved = await materialize(page.rows, backend: backend)
        guard requestGeneration == generation, scopeLoaded == scope, !Task.isCancelled else { return }
        cursor = page.next
        items = resolved
        revision &+= 1
    }

    /// Append the next page (same scope), if any.
    func loadMore(scope: FeedScope) async {
        guard let backend, scope == scopeLoaded, let cursor, !isLoading else { return }
        let generation = requestGeneration
        isLoading = true
        defer {
            if requestGeneration == generation { isLoading = false }
        }
        guard let page = await backend.feed(scope: scope, cursor: cursor, limit: Self.pageSize) else { return }
        guard requestGeneration == generation, scopeLoaded == scope, !Task.isCancelled else { return }
        let existing = Set(items.map(\.id))
        let resolved = await materialize(page.rows.filter { !existing.contains($0.id) }, backend: backend)
        guard requestGeneration == generation, scopeLoaded == scope, !Task.isCancelled else { return }
        self.cursor = page.next
        guard !resolved.isEmpty else { return }
        items += resolved
        revision &+= 1
    }

    /// Materialize one notification target without paging through every newer post first. This is
    /// deliberately read-only: CommunityView owns the one temporary deep-link item so a concurrent
    /// scope refresh cannot erase or duplicate it in this paginated store.
    func resolve(postID: UUID) async -> FeedItem? {
        guard let backend,
              let row = await backend.feedPost(id: postID),
              row.id == postID,
              !Task.isCancelled
        else { return nil }
        return await materialize([row], backend: backend).first
    }

    /// One remote athlete: identity + their RLS-visible posts, with honest aggregates computed
    /// from real posts only (never the synthesized sample body-of-work — that's for badged
    /// community athletes).
    func athlete(handle: String) async -> CommunityAthlete? {
        guard let backend, let page = await backend.athletePage(handle: handle) else { return nil }
        let posts = await materialize(page.rows, backend: backend)
        let avatar = await avatarData(path: page.avatarPath, backend: backend)
        return CommunityAthlete(
            handle: page.handle,
            name: page.displayName.isEmpty ? "Athlete" : page.displayName,
            location: page.location,
            bio: page.bio,
            totalWorkouts: posts.count,
            dayStreak: 0,
            totalDistanceM: 0,
            lat: 0, lon: 0,
            posts: posts,
            avatarData: avatar,
            isSample: false)
    }

    /// Search real, discoverable athletes by name or @handle. Empty for guests/offline/dark —
    /// the seeded community results (searched locally by the caller) are the floor.
    func search(_ query: String) async -> [CommunityAthlete] {
        guard let backend, let hits = await backend.searchAthletes(query: query, limit: 25) else { return [] }
        let rows = hits.enumerated().map { index, hit in
            (index: index, hit: hit,
             avatarURL: hit.avatarPath.flatMap { backend.publicAvatarURL(path: $0) })
        }
        return await withTaskGroup(of: (Int, CommunityAthlete).self) { group in
            for row in rows {
                group.addTask {
                    let avatar = await Self.imageData(path: row.hit.avatarPath, url: row.avatarURL)
                    return (row.index, CommunityAthlete(
                        handle: row.hit.handle,
                        name: row.hit.displayName.isEmpty ? "Athlete" : row.hit.displayName,
                        location: row.hit.location, bio: "",
                        totalWorkouts: 0, dayStreak: 0, totalDistanceM: 0,
                        lat: 0, lon: 0, posts: [],
                        avatarData: avatar, isSample: false))
                }
            }
            var resolved: [(Int, CommunityAthlete)] = []
            for await row in group { resolved.append(row) }
            return resolved.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    // MARK: Row → FeedItem (images through the cache; failures degrade to route/glyph media)

    private func materialize(_ rows: [SocialSyncEngine.FeedRow], backend: any SocialBackending) async -> [FeedItem] {
        guard !rows.isEmpty else { return [] }
        // Merge the viewer's reaction state first so counts render exactly.
        reactions?.merge(viewerReacted: Set(rows.filter(\.viewerReacted).map { $0.id.uuidString }))
        // One signing round trip for the whole page, then cached fetches in parallel.
        let signed = await backend.signedPhotoURLs(paths: rows.flatMap(\.photoPaths))
        let avatarURLs = Dictionary(
            rows.compactMap { row -> (String, URL)? in
                guard let path = row.avatarPath,
                      let url = backend.publicAvatarURL(path: path) else { return nil }
                return (path, url)
            },
            uniquingKeysWith: { first, _ in first })
        var itemsByID: [UUID: FeedItem] = [:]
        await withTaskGroup(of: FeedItem.self) { group in
            for row in rows {
                group.addTask {
                    let photos = await Self.photoData(paths: row.photoPaths, signed: signed)
                    let avatar = await Self.imageData(
                        path: row.avatarPath,
                        url: row.avatarPath.flatMap { avatarURLs[$0] })
                    return SocialSyncEngine.feedItem(from: row, photos: photos, avatar: avatar)
                }
            }
            for await item in group { itemsByID[item.id] = item }
        }
        // TaskGroup order is nondeterministic — restore the RPC's reverse-chronological order.
        return rows.compactMap { itemsByID[$0.id] }
    }

    nonisolated private static func photoData(paths: [String], signed: [String: URL]) async -> [Data] {
        await withTaskGroup(of: (Int, Data?).self) { group in
            for (index, path) in paths.enumerated() {
                guard let url = signed[path] else { continue }
                group.addTask { (index, await imageData(path: path, url: url)) }
            }
            var resolved: [(Int, Data)] = []
            for await (index, data) in group {
                if let data { resolved.append((index, data)) }
            }
            // Downloads finish nondeterministically; authored photo order remains the contract.
            return resolved.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func avatarData(path: String?, backend: any SocialBackending) async -> Data? {
        guard let path, let url = backend.publicAvatarURL(path: path) else { return nil }
        return await Self.imageData(path: path, url: url)
    }

    nonisolated private static func imageData(path: String?, url: URL?) async -> Data? {
        guard let path, !path.isEmpty, let url else { return nil }
        return await RemoteImageCache.shared.data(for: path, fetch: {
            try? await URLSession.shared.data(from: url).0
        })
    }
}
