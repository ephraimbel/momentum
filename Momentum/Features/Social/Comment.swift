import Foundation

/// A comment on a feed post (docs/SOCIAL-LAYER.md, Slice 5 — comments). Value type: the user's own
/// comments persist locally; community comments are seeded. Flat (no nested replies) for v1.
struct Comment: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    let postID: UUID
    let authorName: String
    let authorHandle: String?
    let isCommunity: Bool
    let text: String
    let date: Date
}

/// Light comment moderation (intentionally not strict). Trims, caps length, and masks a small set of
/// crude words — it never rejects an otherwise-fine comment, only blocks empty ones.
enum CommentModeration {
    static let maxLength = 280
    /// A short, deliberately-minimal mask list (keep it light, per product direction).
    static let masked = ["fuck", "shit", "bitch", "asshole", "dick", "cunt"]

    /// Returns the cleaned comment, or nil if there's nothing to post (empty after trim).
    static func clean(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var out = String(trimmed.prefix(maxLength))
        for word in masked {
            out = mask(out, word)
        }
        return out
    }

    /// Case-insensitive whole-word-ish mask → bullets of the same length.
    private static func mask(_ text: String, _ word: String) -> String {
        guard !word.isEmpty else { return text }
        let replacement = String(repeating: "•", count: word.count)
        return text.replacingOccurrences(of: word, with: replacement,
                                         options: [.caseInsensitive])
    }
}

/// Seeded community comments so posts feel alive (honest: clearly community content). Deterministic
/// per post id; replaced by real comments once Supabase is configured.
enum CommunityComments {
    static func seed(for postID: UUID, postDate: Date? = nil, now: Date = Date()) -> [Comment] {
        let base = stableSeed(postID)                  // process-stable (UUID.hashValue is randomized)
        var rng = SeededRNG(base)
        let n = rng.int(0...4)
        guard n > 0 else { return [] }
        // Comments land AFTER their post — a two-day-old comment under a twenty-minute-old post
        // is an instant fake tell. Clamp the window to the post's actual age when known.
        let window = min(postDate.map { max(now.timeIntervalSince($0), 120) } ?? 40 * 3600, 40 * 3600)
        return (0..<n).map { k in
            let who = rng.pick(commenters)
            return Comment(
                id: UUID(uuidString: "00000000-0000-0000-0002-\(String(format: "%010d", abs(base) % 1_000_000_000))\(String(format: "%02d", k))") ?? UUID(),
                postID: postID,
                authorName: who.name, authorHandle: who.handle, isCommunity: true,
                text: rng.pick(texts),
                date: now.addingTimeInterval(-rng.double(0.05, 0.9) * window))
        }
    }

    /// Stable FNV-1a seed over the UUID's bytes (Swift's `hashValue` is randomized per process).
    private static func stableSeed(_ id: UUID) -> Int {
        let b = id.uuid
        let bytes = [b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7, b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15]
        var h: UInt64 = 1469598103934665603
        for byte in bytes { h = (h ^ UInt64(byte)) &* 1099511628211 }
        return Int(truncatingIfNeeded: h)
    }

    private static let commenters: [(name: String, handle: String)] = [
        ("Jordan Ellis", "jordane"), ("Sam Park", "samp"), ("Riley Okafor", "rileyo"),
        ("Casey Tan", "caseyt"), ("Morgan Reed", "morganr"), ("Alex Costa", "alexc"),
        ("Taylor Kim", "taylork"), ("Jules Mercer", "julesm"), ("Dana Walsh", "danaw"),
        ("Chris Novak", "chrisn"), ("Robin Iyer", "robini"), ("Ash Flores", "ashf")]
    // Written the way people actually comment — short, warm, no em-dashes (an AI tell).
    private static let texts = [
        "Strong work! 🔥", "Let's go!", "Inspiring pace.", "That route looks brutal. Nice.",
        "Beast mode.", "Consistency is everything 💪", "Huge. Keep it up!", "Love this.",
        "Respect.", "Crushing it lately.", "Solid effort!", "This is the way.",
        "Okay pace!! 👏", "What shoes are you in?", "That elevation though",
        "Making me want to get out there", "Save some PRs for the rest of us",
        "Unreal consistency.", "There it is!!", "Weekend well spent."]
}
