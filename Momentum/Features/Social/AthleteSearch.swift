import Foundation

/// Ranking for the athlete search (2026-08-29). Pure and unit-tested, because "sensible order" is
/// the whole difference between a search field and a filter.
///
/// The old behaviour was a bare `contains` scan in DIRECTORY order, so typing a name returned
/// whoever the generator happened to emit first. Searching "maya" put @mayafields — a substring
/// hit deep in the list — above @maya, and typing someone's exact handle could leave them below
/// three strangers who merely contain it. On a page whose entire job is finding one specific
/// person, that reads as a search that does not work.
///
/// The order is the obvious one: the person you named, then people whose name or handle STARTS
/// with what you typed, then everyone who merely contains it. Ties break on the shortest handle
/// (a plain @maya beats @mayaruns222) and then alphabetically, so the list is stable between
/// keystrokes instead of reshuffling under the thumb.
enum AthleteSearch {

    /// One indexed athlete. Kept to three small strings on purpose: a keystroke scans these, it
    /// never copies athlete structs (their posts carry whole route polylines).
    struct Entry: Sendable, Equatable {
        let index: Int
        /// Lowercased display name.
        let name: String
        /// Lowercased handle, without the leading @.
        let handle: String

        init(index: Int, name: String, handle: String) {
            self.index = index
            self.name = name.lowercased()
            self.handle = handle.lowercased()
        }
    }

    /// Lower is better; nil means "not a match at all".
    static func rank(_ entry: Entry, query q: String) -> Int? {
        guard !q.isEmpty else { return nil }
        if entry.handle == q { return 0 }
        if entry.name == q { return 1 }
        if entry.handle.hasPrefix(q) { return 2 }
        if entry.name.hasPrefix(q) { return 3 }
        // "bennett" should find "Theo Bennett" ahead of "Ubennettson".
        if entry.name.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 4 }
        if entry.handle.contains(q) { return 5 }
        if entry.name.contains(q) { return 6 }
        return nil
    }

    /// Matching entries, best first. `limit` caps the work: nobody scrolls past the first screen
    /// of a name search, and the caller merges remote hits behind these.
    static func matches(_ entries: [Entry], query rawQuery: String, limit: Int = 30) -> [Entry] {
        let q = normalize(rawQuery)
        guard !q.isEmpty else { return [] }
        return entries
            .compactMap { entry -> (Entry, Int)? in rank(entry, query: q).map { (entry, $0) } }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                // Shortest handle wins: @maya is more likely who you meant than @mayaruns222.
                if a.0.handle.count != b.0.handle.count { return a.0.handle.count < b.0.handle.count }
                return a.0.handle < b.0.handle
            }
            .prefix(limit)
            .map(\.0)
    }

    /// What the field's text means as a query: trimmed, case-folded, and with a leading @ dropped
    /// so typing someone's handle the way it is written finds them.
    static func normalize(_ raw: String) -> String {
        var q = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while q.hasPrefix("@") { q.removeFirst() }
        return q
    }
}
