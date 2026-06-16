import Foundation
import Observation

/// The athlete's "respect" reactions (docs/SOCIAL-LAYER.md, Slice 4). Local + persisted for now; the
/// reaction graph syncs to Supabase with the rest of social later. Keyed by post id. The displayed
/// count is the post's seeded baseline plus the viewer's own reaction — the viewer's tap is always
/// real, even before the backend is live.
@MainActor
@Observable
final class ReactionStore {
    private static let key = "com.momentum.social.reactions"
    private let defaults: UserDefaults
    private(set) var reacted: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reacted = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func hasReacted(_ id: UUID) -> Bool { reacted.contains(id.uuidString) }

    func toggle(_ id: UUID) {
        let key = id.uuidString
        if reacted.contains(key) { reacted.remove(key) } else { reacted.insert(key) }
        defaults.set(Array(reacted), forKey: Self.key)
    }

    /// Total respects to show: the post's baseline + 1 if the viewer reacted.
    func count(for item: FeedItem) -> Int {
        item.baseReactions + (hasReacted(item.id) ? 1 : 0)
    }
}
