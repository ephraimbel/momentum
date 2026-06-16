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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        SocialDebug.resetIfRequested(defaults, keys: [Self.key])
        following = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func isFollowing(_ handle: String) -> Bool { following.contains(handle) }

    func toggle(_ handle: String) {
        guard !handle.isEmpty else { return }
        if following.contains(handle) { following.remove(handle) } else { following.insert(handle) }
        defaults.set(Array(following), forKey: Self.key)
    }

    var count: Int { following.count }
}
