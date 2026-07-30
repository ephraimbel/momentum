import Foundation

/// The seeded community's follow graph — a REAL graph, not per-profile random lists.
///
/// The unit of truth is the EDGE: `follows(a, b)` is a pure function of the two handles, so
/// "Priya follows Maya" is one deterministic fact that Maya's Followers list and Priya's Following
/// list both derive from. That's what makes the graph hold up to the tap-through a curious user
/// will actually do (open a follower → open THEIR following → find the original athlete there).
/// Independent per-profile draws — the first implementation — could not survive that walk
/// (owner bar 2026-07-30: every community member has an actual account with real followers, and
/// they have to be following people).
///
/// Shape: an edge fires with probability ∝ the followee's popularity × the follower's
/// gregariousness, both seeded from the identity the way the old header numbers were — so
/// popular athletes have big audiences, active ones follow widely, and the counts land in the
/// same 20–250 / 15–300 bands the profiles have always shown.
@MainActor
enum CommunityGraph {

    /// One direction of the relationship, usable anywhere ("does a follow b?").
    static func follows(_ a: String, _ b: String) -> Bool {
        guard a != b else { return false }
        return edgeDraw(a, b) < probability(follower: a, followee: b)
    }

    /// Everyone who follows `handle`, most-devoted first (stable order). Cached — one scan of the
    /// directory per athlete per launch.
    static func followerHandles(of handle: String) -> [String] {
        if let hit = followerCache[handle] { return hit }
        let all = CommunityDirectory.all()
        let rows = all
            .filter { $0.handle != handle && follows($0.handle, handle) }
            .map(\.handle)
            .sorted { edgeDraw($0, handle) < edgeDraw($1, handle) }
        followerCache[handle] = rows
        return rows
    }

    /// Everyone `handle` follows (same edge function, other direction).
    static func followingHandles(of handle: String) -> [String] {
        if let hit = followingCache[handle] { return hit }
        let all = CommunityDirectory.all()
        let rows = all
            .filter { $0.handle != handle && follows(handle, $0.handle) }
            .map(\.handle)
            .sorted { edgeDraw(handle, $0) < edgeDraw(handle, $1) }
        followingCache[handle] = rows
        return rows
    }

    static func resolve(_ handles: [String]) -> [CommunityAthlete] {
        handles.compactMap { CommunityDirectory.athlete(handle: $0) }
    }

    private static var followerCache: [String: [String]] = [:]
    private static var followingCache: [String: [String]] = [:]

    // MARK: The edge model

    /// P(a follows b) = popularity(b) × gregariousness(a) / N — expected follower count of b lands
    /// on b's popularity target; expected following count of a scales with a's gregariousness.
    private static func probability(follower a: String, followee b: String) -> Double {
        let n = Double(max(CommunityDirectory.all().count, 1))
        // The same identity-seeded bands the profile header always displayed (20–240 / 15–335),
        // so the emergent counts keep the look the wall has had all along.
        let popularity = 20.0 + Double(popularitySalt(b))
        let gregariousness = (15.0 + Double(gregariousnessSalt(a))) / 175.0   // ≈ mean-1 multiplier
        return min(0.9, popularity * gregariousness / n)
    }

    private static func popularitySalt(_ handle: String) -> Int {
        let s = handle.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF }
        return s % 220
    }

    private static func gregariousnessSalt(_ handle: String) -> Int {
        let s = handle.utf8.reduce(7) { ($0 &* 17 &+ Int($1)) & 0xFFFF }
        return s % 320
    }

    /// Uniform [0,1) from the ORDERED pair — the direction matters (a following b and b following
    /// a are independent facts, like life).
    private static func edgeDraw(_ a: String, _ b: String) -> Double {
        var h: UInt64 = 1469598103934665603
        for byte in a.utf8 { h = (h ^ UInt64(byte)) &* 1099511628211 }
        h = (h ^ 0x2F) &* 1099511628211
        for byte in b.utf8 { h = (h ^ UInt64(byte)) &* 1099511628211 }
        return Double(h % 1_000_000) / 1_000_000
    }
}
