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
    /// `reactions`/`type`/`authorHandle` come from the post so threads cohere with it: length follows
    /// the respect count (nobody comments on a post nobody saw), texts match the sport, and the
    /// author never comments on themselves. Defaults keep older/positional callers compiling.
    static func seed(for postID: UUID, postDate: Date? = nil, now: Date = Date(),
                     reactions: Int = 30, type: WorkoutType? = nil,
                     authorHandle: String? = nil) -> [Comment] {
        let base = stableSeed(postID)                  // process-stable (UUID.hashValue is randomized)
        var rng = SeededRNG(base)
        // Skewed and capped by engagement: quiet posts carry a line or nothing; well-respected
        // posts sprout real threads (owner ask 2026-07-29 — the page should read like humans are
        // actually talking). Still never a long thread under a barely-seen post.
        let cap = reactions < 6 ? 0 : reactions < 15 ? 2 : reactions < 40 ? 4 : reactions < 90 ? 6 : 9
        let n = min(cap, Int(10 * pow(rng.double(0, 1), 1.7)))
        guard n > 0 else { return [] }
        // Comments land AFTER their post — a two-day-old comment under a twenty-minute-old post
        // is an instant fake tell. Clamp the window to the post's actual age when known.
        let window = min(postDate.map { max(now.timeIntervalSince($0), 120) } ?? 40 * 3600, 40 * 3600)
        // Commenters are REAL community athletes from the directory — they carry their own synthetic
        // face and a tappable profile. The old hardcoded dozen existed nowhere, so every thread was
        // the same faceless strangers under a faced poster. No dupes in a thread; never the author.
        let pool = CommunityDirectory.all()
        var used: Set<String> = authorHandle.map { [$0] } ?? []
        var lines = texts(for: type)
        return (0..<n).compactMap { k in
            var who: CommunityAthlete?
            for _ in 0..<8 {   // seeded retry keeps the draw deterministic
                let candidate = pool[rng.int(0...(pool.count - 1))]
                if candidate.isSample, !used.contains(candidate.handle) { who = candidate; break }
            }
            guard let who else { return nil }
            used.insert(who.handle)
            // Sample texts WITHOUT replacement so a thread never repeats a line.
            let text = lines.isEmpty ? "Respect." : lines.remove(at: rng.int(0...(lines.count - 1)))
            return Comment(
                id: UUID(uuidString: "00000000-0000-0000-0002-\(String(format: "%010d", abs(base) % 1_000_000_000))\(String(format: "%02d", k))") ?? UUID(),
                postID: postID,
                authorName: who.name, authorHandle: who.handle, isCommunity: true,
                text: text,
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

    // Written the way people actually comment — short, warm, no em-dashes (an AI tell). Sport-gated:
    // "What shoes are you in?" under a swim or "that elevation though" under a lift read generated.
    private static func texts(for type: WorkoutType?) -> [String] {
        guard let type else { return warmTexts }
        if type.isStrengthStyle { return warmTexts + strengthTexts }
        if type == .yoga { return warmTexts + calmTexts }
        if type.isGPS { return warmTexts + gpsTexts }
        return warmTexts
    }
    private static let warmTexts = [
        "Strong work! 🔥", "Let's go!", "Beast mode.", "Consistency is everything 💪",
        "Huge. Keep it up!", "Love this.", "Respect.", "Crushing it lately.", "Solid effort!",
        "This is the way.", "Unreal consistency.", "There it is!!", "Weekend well spent.",
        "Making me want to get out there", "ok this is motivating", "The streak continues 🙌",
        "You again!! machine.", "day made", "Needed to see this today", "and I thought I trained hard",
        "W", "goals honestly", "Proud of you!", "How do you do this daily", "showing up > everything"]
    private static let gpsTexts = [
        "Inspiring pace.", "That route looks brutal. Nice.", "Okay pace!! 👏",
        "What shoes are you in?", "That elevation though", "Those splits 👀",
        "Perfect morning for it.", "That loop looks fun, dropping a pin", "negative splits?? insane",
        "My knees hurt just looking at this", "That is a spicy pace my friend",
        "Take me next time!!", "The early morning grind 🌅", "route saved for the weekend"]
    private static let strengthTexts = [
        "Save some PRs for the rest of us", "Numbers going up 📈", "That volume is serious.",
        "Strong. Simple as that.", "Gym therapy hits different.", "Sheesh. That total.",
        "Leg day warrior 🫡", "Bar speed must have been flying"]
    private static let calmTexts = [
        "Needed this reminder to slow down.", "Recovery is training too.", "So peaceful.",
        "Balance 🙌"]
}
