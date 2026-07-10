import Foundation
import Observation

/// Who the athlete follows (docs/SOCIAL-LAYER.md). Local + persisted (UserDefaults) for now — the
/// graph syncs to Supabase with the rest of social later. Handles are the stable key (community +
/// real users alike).
@MainActor
@Observable
final class FollowStore {
    private static let key = "com.momentum.social.following"
    private let defaults: UserDefaults
    private(set) var following: Set<String>

    /// Wired once in `MomentumApp`; nil in tests/previews → the store stays purely local.
    @ObservationIgnored var backend: (any SocialBackending)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        SocialDebug.resetIfRequested(defaults, keys: [Self.key])
        following = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func isFollowing(_ handle: String) -> Bool { following.contains(handle) }

    func toggle(_ handle: String) {
        guard !handle.isEmpty else { return }
        let isFollowing: Bool
        if following.contains(handle) { following.remove(handle); isFollowing = false }
        else { following.insert(handle); isFollowing = true }
        defaults.set(Array(following), forKey: Self.key)
        // Fire-and-forget push; seeded community handles have no server profile and no-op there.
        let backend = backend
        Task { await backend?.setFollow(handle: handle, following: isFollowing) }
    }

    /// Adopt the server's follow graph on pull. Follows of seeded community athletes only exist
    /// locally (they have no server profile), so they're preserved verbatim — the server is
    /// authoritative only for real athletes.
    func merge(remote: Set<String>) {
        let seedFollows = following.filter { CommunityDirectory.athlete(handle: $0) != nil }
        let merged = remote.union(seedFollows)
        guard merged != following else { return }
        following = merged
        defaults.set(Array(following), forKey: Self.key)
    }

    var count: Int { following.count }
}
