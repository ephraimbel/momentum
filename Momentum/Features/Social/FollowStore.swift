import Foundation
import Observation

/// Who the athlete follows (docs/SOCIAL-LAYER.md). Local + persisted (UserDefaults), pushed to
/// Supabase behind the tap. Handles are the stable key (community + real users alike).
///
/// The local set is the UI's truth — a tap flips it immediately, so the button, the profile's
/// "Following" count, and the Friends wall all update in the same frame regardless of network.
/// The server is authoritative only for follows it has actually acknowledged; see `merge`.
@MainActor
@Observable
final class FollowStore {
    private static let key = "com.momentum.social.following"
    private static let pendingKey = "com.momentum.social.followingPending"
    private let defaults: UserDefaults
    private(set) var following: Set<String>

    /// Handles whose server write hasn't been acknowledged — an offline tap, a guest, or a seeded
    /// community athlete (no server profile to point at). Persisted, because a force-quit before
    /// the network returns must not turn a real follow into one the next pull prunes. `merge`
    /// protects these and retries them.
    private(set) var pending: Set<String>

    /// Wired once in `MomentumApp`; nil in tests/previews → the store stays purely local.
    @ObservationIgnored var backend: (any SocialBackending)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        SocialDebug.resetIfRequested(defaults, keys: [Self.key, Self.pendingKey])
        following = Set(defaults.stringArray(forKey: Self.key) ?? [])
        pending = Set(defaults.stringArray(forKey: Self.pendingKey) ?? [])
        #if DEBUG
        // One store per process (`@State` in MomentumApp), so this runs once — no init side-effect
        // loop of the kind that stormed CommunityView (see its `didApplyLaunchArgs` note).
        let seeded = SocialDebug.seededFollows()
        if !seeded.isEmpty, !seeded.isSubset(of: following) {
            following.formUnion(seeded)
            defaults.set(Array(following), forKey: Self.key)
        }
        #endif
    }

    func isFollowing(_ handle: String) -> Bool { following.contains(handle) }

    func toggle(_ handle: String) {
        guard !handle.isEmpty else { return }
        let isFollowing: Bool
        if following.contains(handle) { following.remove(handle); isFollowing = false }
        else { following.insert(handle); isFollowing = true }
        // Only REAL athletes can be pending: a seeded community handle has no server profile, so
        // its push can never succeed — marking it pending would keep it in the retry set forever
        // and fire a futile profile lookup on every feed refresh. `merge` protects seeded follows
        // unconditionally anyway (see `seedFollows`), so nothing is lost by leaving them out.
        if CommunityDirectory.athlete(handle: handle) == nil { pending.insert(handle) }
        persist()
        Task { await push(handle, following: isFollowing) }
    }

    /// Push one intent and clear it from `pending` only on a confirmed write. A seeded community
    /// athlete never confirms (there's no server profile), which is correct: `merge` keeps seeded
    /// follows anyway, so the pending entry is harmless and self-limiting.
    private func push(_ handle: String, following isFollowing: Bool) async {
        guard let backend else { pending.remove(handle); persist(); return }   // local-only build
        if await backend.setFollow(handle: handle, following: isFollowing) {
            pending.remove(handle)
            persist()
        }
    }

    /// Adopt the server's follow graph on pull.
    ///
    /// The server is authoritative only for what it can know. Two classes of local truth survive:
    /// **seeded community follows** (those athletes have no server profile, so the server will
    /// never list them) and **pending intents** (a follow made offline is kept and retried; an
    /// unfollow made offline is not resurrected just because the server still lists it).
    func merge(remote: Set<String>) {
        let seedFollows = following.filter { CommunityDirectory.athlete(handle: $0) != nil }
        let pendingFollows = pending.intersection(following)        // followed here, not yet pushed
        let pendingUnfollows = pending.subtracting(following)       // unfollowed here, not yet pushed
        let merged = remote.union(seedFollows).union(pendingFollows).subtracting(pendingUnfollows)
        if merged != following {
            following = merged
            persist()
        }
        // Retry whatever the server still hasn't taken (iterating a value-type snapshot).
        for handle in pending {
            Task { await push(handle, following: following.contains(handle)) }
        }
    }

    private func persist() {
        defaults.set(Array(following), forKey: Self.key)
        defaults.set(Array(pending), forKey: Self.pendingKey)
    }

    var count: Int { following.count }
}
