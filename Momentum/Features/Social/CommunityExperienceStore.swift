import Foundation

/// Durable, deliberately small memory for the Community wall.
///
/// The feed itself remains reverse-chronological and server/local-data driven. This store remembers
/// only durable presentation continuity: where the athlete stopped and which post divided new from
/// already-seen work. Route entrances are deliberately session-scoped in `CommunityPager`; a post
/// opened tomorrow should still animate, while a recycled page in today's pager should not repeat.
/// UserDefaults is the right scope here: none of this is training data or sync truth.
@MainActor
final class CommunityExperienceStore {
    struct Visit: Equatable {
        var restoreID: UUID?
        var boundaryID: UUID?
        var newCount: Int
    }

    private let defaults: UserDefaults
    private let prefix = "com.momentum.community.experience"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Resolve one visit against the feed currently available. A missing anchor falls back to the
    /// closest post at or before its saved date, so deleted/moderated posts never strand restoration.
    func visit(items: [FeedItem], scope: CommunityScope) -> Visit {
        let seen = defaults.double(forKey: key("seenDate", scope))
        let anchorRaw = defaults.string(forKey: key("anchorID", scope))
        let anchorDate = defaults.double(forKey: key("anchorDate", scope))

        let exact = anchorRaw.flatMap(UUID.init(uuidString:)).flatMap { id in
            items.contains(where: { $0.id == id }) ? id : nil
        }
        let fallback = anchorDate > 0
            ? items.first(where: { $0.date.timeIntervalSince1970 <= anchorDate })?.id
            : nil

        guard seen > 0 else {
            return Visit(restoreID: exact ?? fallback, boundaryID: nil, newCount: 0)
        }
        let newCount = items.prefix { $0.date.timeIntervalSince1970 > seen }.count
        let boundary = items.indices.contains(newCount) && newCount > 0 ? items[newCount].id : nil
        return Visit(restoreID: exact ?? fallback, boundaryID: boundary, newCount: newCount)
    }

    func saveAnchor(_ item: FeedItem, scope: CommunityScope) {
        defaults.set(item.id.uuidString, forKey: key("anchorID", scope))
        defaults.set(item.date.timeIntervalSince1970, forKey: key("anchorDate", scope))
    }

    /// A visit is considered seen when the athlete leaves that scope, not when it first paints.
    /// That keeps the divider stable for the whole visit and avoids a refresh erasing it mid-scroll.
    func finishVisit(items: [FeedItem], scope: CommunityScope) {
        guard let newest = items.first else { return }
        defaults.set(newest.id.uuidString, forKey: key("seenID", scope))
        defaults.set(newest.date.timeIntervalSince1970, forKey: key("seenDate", scope))
    }

    private func key(_ field: String, _ scope: CommunityScope) -> String {
        "\(prefix).\(scope.rawValue).\(field)"
    }
}
