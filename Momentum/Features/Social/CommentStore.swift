import Foundation
import Observation

/// The user's own comments (docs/SOCIAL-LAYER.md). Local + persisted (UserDefaults JSON); syncs to
/// Supabase with the rest of social later. Keyed by post id. Light moderation runs on add.
@MainActor
@Observable
final class CommentStore {
    private static let key = "com.momentum.social.comments"
    private let defaults: UserDefaults
    private(set) var byPost: [String: [Comment]]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        SocialDebug.resetIfRequested(defaults, keys: [Self.key])
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: [Comment]].self, from: data) {
            byPost = decoded
        } else {
            byPost = [:]
        }
    }

    func comments(for postID: UUID) -> [Comment] { byPost[postID.uuidString] ?? [] }

    /// Add the user's comment after light moderation. Returns the added comment, or nil if it was
    /// empty after cleaning (nothing to post).
    @discardableResult
    func add(_ raw: String, to postID: UUID, authorName: String, authorHandle: String?,
             now: Date = Date()) -> Comment? {
        guard let text = CommentModeration.clean(raw) else { return nil }
        let comment = Comment(id: UUID(), postID: postID, authorName: authorName,
                              authorHandle: authorHandle, isCommunity: false, text: text, date: now)
        byPost[postID.uuidString, default: []].append(comment)
        persist()
        return comment
    }

    func delete(_ comment: Comment) {
        byPost[comment.postID.uuidString]?.removeAll { $0.id == comment.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(byPost) { defaults.set(data, forKey: Self.key) }
    }
}
