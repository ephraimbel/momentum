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

    private(set) var items: [FeedItem] = []
    private(set) var isLoading = false
    private var cursor: FeedCursor?
    private var scopeLoaded: FeedScope?

    static let pageSize = 20

    /// Replace the feed with the first remote page for `scope`. No-op when unavailable.
    func refresh(scope: FeedScope) async {
        guard let backend, await backend.isAvailable, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if let remoteFollowing = await backend.pullFollowing() {
            follows?.merge(remote: remoteFollowing)
        }
        // Switching scope: drop the old scope's rows up front so a failed fetch yields an empty
        // correct-scope list, never stale cross-scope athletes (e.g. Everyone's under Following).
        if scope != scopeLoaded {
            items = []
            scopeLoaded = scope
        }
        guard let page = await backend.feed(scope: scope, cursor: nil, limit: Self.pageSize) else { return }
        cursor = page.next
        scopeLoaded = scope
        items = await materialize(page.rows, backend: backend)
    }

    /// Append the next page (same scope), if any.
    func loadMore(scope: FeedScope) async {
        guard let backend, scope == scopeLoaded, let cursor, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        guard let page = await backend.feed(scope: scope, cursor: cursor, limit: Self.pageSize) else { return }
        self.cursor = page.next
        let existing = Set(items.map(\.id))
        items += await materialize(page.rows.filter { !existing.contains($0.id) }, backend: backend)
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
        var out: [CommunityAthlete] = []
        for hit in hits {
            let avatar = await avatarData(path: hit.avatarPath, backend: backend)
            out.append(CommunityAthlete(
                handle: hit.handle,
                name: hit.displayName.isEmpty ? "Athlete" : hit.displayName,
                location: hit.location, bio: "",
                totalWorkouts: 0, dayStreak: 0, totalDistanceM: 0,
                lat: 0, lon: 0, posts: [],
                avatarData: avatar, isSample: false))
        }
        return out
    }

    // MARK: Row → FeedItem (images through the cache; failures degrade to route/glyph media)

    private func materialize(_ rows: [SocialSyncEngine.FeedRow], backend: any SocialBackending) async -> [FeedItem] {
        guard !rows.isEmpty else { return [] }
        // Merge the viewer's reaction state first so counts render exactly.
        reactions?.merge(viewerReacted: Set(rows.filter(\.viewerReacted).map { $0.id.uuidString }))
        // One signing round trip for the whole page, then cached fetches in parallel.
        let signed = await backend.signedPhotoURLs(paths: rows.flatMap(\.photoPaths))
        var itemsByID: [UUID: FeedItem] = [:]
        await withTaskGroup(of: FeedItem.self) { group in
            for row in rows {
                group.addTask { @MainActor [weak self] in
                    let photos = await self?.photoData(paths: row.photoPaths, signed: signed) ?? []
                    let avatar = await self?.avatarData(path: row.avatarPath, backend: backend)
                    return SocialSyncEngine.feedItem(from: row, photos: photos, avatar: avatar)
                }
            }
            for await item in group { itemsByID[item.id] = item }
        }
        // TaskGroup order is nondeterministic — restore the RPC's reverse-chronological order.
        return rows.compactMap { itemsByID[$0.id] }
    }

    private func photoData(paths: [String], signed: [String: URL]) async -> [Data] {
        var out: [Data] = []
        for path in paths {   // ordered — first is the hero
            guard let url = signed[path] else { continue }
            if let data = await RemoteImageCache.shared.data(for: path, fetch: {
                try? await URLSession.shared.data(from: url).0
            }) { out.append(data) }
        }
        return out
    }

    private func avatarData(path: String?, backend: any SocialBackending) async -> Data? {
        guard let path, !path.isEmpty, let url = backend.publicAvatarURL(path: path) else { return nil }
        return await RemoteImageCache.shared.data(for: path, fetch: {
            try? await URLSession.shared.data(from: url).0
        })
    }
}
