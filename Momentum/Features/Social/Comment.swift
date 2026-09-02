import Foundation

/// A comment on a feed post (docs/SOCIAL-LAYER.md, Slice 5 — comments). Value type: the user's own
/// comments persist locally; community comments are seeded. Flat (no nested replies) for v1 —
/// replies read as `@handle` mentions inside the same list, which is how threads actually look.
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

// MARK: - What the post is actually about

/// The facts a post carries, parsed out of the `FeedItem` a thread hangs under, so a comment can
/// talk about THIS run instead of any run. "22 miles on a Tuesday??" is a comment; "Strong work!"
/// is a form letter, and a page of form letters is what makes a community read as generated.
///
/// Everything here is derived, never invented: `statLine` is the same string the card prints
/// ("8.4 mi · 1:07:12", "12,400 lb · 14 sets · 52:18", "6.2 mi · 58:03 · 1,240 ft"), so a line that
/// quotes a number is quoting a number the reader can see two inches higher up.
struct PostFacts: Sendable, Hashable {
    var sport: WorkoutType
    var title: String
    /// City without the state suffix ("Austin, TX" → "Austin"). nil when the post has no place.
    var city: String?
    var miles: Double?
    var durationS: Int?
    var climbFt: Int?
    var volumeLb: Int?
    var sets: Int?
    /// The PR badge exactly as the card shows it ("5K PR", "Longest run", "e1RM PR"). nil = no PR.
    var pr: String?
    var hasRoute: Bool
    /// Local hour / weekday / season the post was recorded in.
    var hour: Int
    var weekday: String
    var season: Season

    enum Season: String, Sendable, Hashable { case winter, spring, summer, fall }

    var paceSPerMile: Double? {
        guard let miles, miles > 0.4, let durationS, durationS > 60 else { return nil }
        return Double(durationS) / miles
    }

    /// Whether the timestamp agrees with a time of day named in the title. Titles like "Lunch run"
    /// and "Night run" are drawn independently of the post's hour, so they can disagree; when they
    /// do, nothing should be said about the clock at all. True when the title names no time.
    var clockMatchesTitle: Bool {
        let t = title.lowercased()
        let named: ClosedRange<Int>?
        if t.contains("sunrise") || t.contains("morning") || t.contains("before work")
            || t.contains("out the door early") { named = 4...10 }
        else if t.contains("lunch") || t.contains("midday") { named = 11...14 }
        else if t.contains("night") { named = 19...23 }
        else if t.contains("evening") || t.contains("after dinner") || t.contains("sunset") { named = 16...22 }
        else { named = nil }
        return named.map { $0.contains(hour) } ?? true
    }

    /// A structured session (track reps, tempo, hills) — the title is the only honest signal, and
    /// the generator only ever writes these words on a genuinely structured post.
    var isStructured: Bool {
        let t = title.lowercased()
        return ["track", "tempo", "repeat", "interval", "fartlek", "hill", "400", "800",
                "×", "x1", "5×", "speed", "stride"].contains { t.contains($0) }
    }

    init(sport: WorkoutType, title: String = "", city: String? = nil, miles: Double? = nil,
         durationS: Int? = nil, climbFt: Int? = nil, volumeLb: Int? = nil, sets: Int? = nil,
         pr: String? = nil, hasRoute: Bool = false, hour: Int = 9,
         weekday: String = "Tuesday", season: Season = .fall) {
        self.sport = sport; self.title = title; self.city = city; self.miles = miles
        self.durationS = durationS; self.climbFt = climbFt; self.volumeLb = volumeLb
        self.sets = sets; self.pr = pr; self.hasRoute = hasRoute; self.hour = hour
        self.weekday = weekday; self.season = season
    }

    init(item: FeedItem, calendar: Calendar = .current) {
        let city = item.location.map { String($0.split(separator: ",").first ?? "") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let parsed = Self.parse(statLine: item.statLine)
        let comps = calendar.dateComponents([.hour, .weekday, .month], from: item.date)
        self.init(sport: item.type,
                  title: item.title,
                  city: (city?.isEmpty ?? true) ? nil : city,
                  miles: parsed.miles, durationS: parsed.durationS, climbFt: parsed.climbFt,
                  volumeLb: parsed.volumeLb, sets: parsed.sets,
                  pr: item.prBadge,
                  hasRoute: item.hasRenderableRoute,
                  hour: comps.hour ?? 9,
                  weekday: Self.weekdayNames[max(0, min(6, (comps.weekday ?? 3) - 1))],
                  // Hemisphere reads the METRO, not the town: a Sydney athlete who lives in Manly
                  // still runs a January summer, and no set of southern town names would be
                  // complete (or unambiguous — half of them are also American towns).
                  season: Self.season(month: comps.month ?? 6, city: item.metro ?? item.location))
    }

    // Fixed English names on purpose: these land inside English sentences, and a device set to
    // another locale would otherwise print "mardi" in the middle of one.
    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday",
                              "Friday", "Saturday"]

    /// Cities where December is summer, plus the ones where it is never cold. A "how cold was it"
    /// under a January run in Sydney is the same kind of tell as a fabricated number.
    private static let southern: Set<String> = ["Sydney", "Melbourne", "Auckland", "Cape Town"]
    private static let tropical: Set<String> = ["Singapore", "Miami"]

    static func season(month: Int, city: String?) -> Season {
        let name = city.map { String($0.split(separator: ",").first ?? "") }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if tropical.contains(name) { return .summer }
        let m = southern.contains(name) ? (month + 6 - 1) % 12 + 1 : month
        switch m {
        case 12, 1, 2: return .winter
        case 3, 4, 5: return .spring
        case 6, 7, 8: return .summer
        default: return .fall
        }
    }

    /// Pull the numbers back out of the stat line the card renders. Tokens are " · " separated and
    /// self-describing ("8.4 mi", "1,240 ft", "12,400 lb", "14 sets", "1:07:12").
    static func parse(statLine: String) -> (miles: Double?, durationS: Int?, climbFt: Int?,
                                            volumeLb: Int?, sets: Int?) {
        var miles: Double?, durationS: Int?, climbFt: Int?, volumeLb: Int?, sets: Int?
        for raw in statLine.components(separatedBy: "·") {
            let token = raw.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { continue }
            let number = Double(token.prefix { $0.isNumber || $0 == "." || $0 == "," }
                .replacingOccurrences(of: ",", with: ""))
            let lower = token.lowercased()
            if token.contains(":") {
                durationS = seconds(fromClock: token)
            } else if lower.hasSuffix("mi") {
                miles = number
            } else if lower.hasSuffix("ft") {
                climbFt = number.map { Int($0) }
            } else if lower.hasSuffix("lb") {
                // Pounds only. A kg stat line would leave `volumeLb` nil, so no line quotes a
                // number in the wrong unit: the gates fail closed, never into a wrong fact.
                volumeLb = number.map { Int($0) }
            } else if lower.contains("set") {
                sets = number.map { Int($0) }
            }
        }
        return (miles, durationS, climbFt, volumeLb, sets)
    }

    /// "44:31" or "1:07:12" → seconds.
    static func seconds(fromClock text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }
}

// MARK: - Seeded community threads

/// Seeded community comments so posts feel alive (honest: clearly community content). Deterministic
/// per post id; replaced by real comments once Supabase is configured.
///
/// Three rules hold this together, and breaking any one of them is what makes a feed read as
/// generated:
///
/// 1. **The thread is about the post.** Lines are built from `PostFacts`, so a mileage line only
///    lands where that mileage exists and a PR line only lands on a PR. See `contextualLines`.
/// 2. **The count never depends on the facts.** `threadSize` reads only (post id, reactions,
///    sport) — the exact arguments BOTH call sites already pass — so the rail's badge on
///    `CommunityPager` and the list in `PostCommentsView` can never disagree. A count that
///    contradicts the list it opens is the same fakeness bug as a form-letter comment.
///    ⚠️ Never make `threadSize` read `facts` or the circle.
/// 3. **Commenters are people the poster knows.** They come from `CommunityGraph`'s follower list
///    for that athlete, front-biased, so the same handful of friends recur across their posts.
enum CommunityComments {

    /// The canonical entry point: everything the thread needs comes off the post itself.
    /// `@MainActor` only because the follow graph is (it caches); the count path below is not, so
    /// a rail badge can be computed anywhere.
    @MainActor
    static func seed(for item: FeedItem, now: Date = Date()) -> [Comment] {
        seed(for: item.id, postDate: item.date, now: now, reactions: item.baseReactions,
             type: item.type, authorHandle: item.authorHandle,
             facts: PostFacts(item: item), circle: circle(for: item.authorHandle))
    }

    /// The poster's own audience, most-devoted first, resolved to athletes. Real people are
    /// commented on by people who follow them; a stranger every time reads as a bot farm.
    @MainActor
    static func circle(for handle: String?) -> [CommunityAthlete] {
        guard let handle else { return [] }
        return CommunityGraph.followerHandles(of: handle)
            .prefix(40)
            .compactMap { CommunityDirectory.athlete(handle: $0) }
            .filter(\.isSample)
    }

    /// `reactions`/`type` set the SIZE of the thread; `facts`/`circle` set what it says and who
    /// says it. Both are optional so the size can be computed without touching the directory or
    /// the graph (that is what keeps the rail badge honest — see the type doc).
    static func seed(for postID: UUID, postDate: Date? = nil, now: Date = Date(),
                     reactions: Int = 30, type: WorkoutType? = nil,
                     authorHandle: String? = nil, facts: PostFacts? = nil,
                     circle: [CommunityAthlete] = []) -> [Comment] {
        let base = stableSeed(postID)
        let n = threadSize(base: base, reactions: reactions, type: type)
        guard n > 0 else { return [] }
        // A separate stream from the size draw, so adding a fact can never move the count.
        var rng = SeededRNG(base &* 131 &+ 977)

        // Comments land AFTER their post and cluster in the first hours, thinning after. A
        // three-week-old post whose whole thread is "2 hours ago" is an instant tell, and so is a
        // comment that predates the run it sits under.
        let posted = postDate ?? now.addingTimeInterval(-24 * 3600)
        let age = max(now.timeIntervalSince(posted), 1)
        let window = min(age, 36 * 3600)
        let offsets = (0..<n)
            .map { _ in window * (0.02 + 0.98 * pow(rng.double(0, 1), 3.2)) }
            .sorted()

        // Who talks: the poster's followers first (front-biased, so the same friends recur across
        // their posts), with the occasional passer-by from the wider community.
        let wider = CommunityDirectory.all()
        var used: Set<String> = authorHandle.map { [$0] } ?? []
        // Names as well as handles, and every part of the name. The directory draws from 50 first
        // names and 40 surnames over ~2,900 athletes, so two accounts really can both be
        // "Kofi Lowe", and "Felix Walsh" answering "Amara Walsh" turned up in the very first
        // screenshot. A thread is three or four people: sharing a name in one is what a generator
        // looks like, whatever the handles say.
        var usedTokens: Set<String> = []
        var people: [CommunityAthlete] = []
        func free(_ a: CommunityAthlete) -> Bool {
            guard a.isSample, !used.contains(a.handle) else { return false }
            return !a.name.lowercased().split(separator: " ").contains { usedTokens.contains(String($0)) }
        }
        for _ in 0..<n {
            var who: CommunityAthlete?
            for attempt in 0..<10 {                       // seeded retry keeps the draw deterministic
                let fromCircle = !circle.isEmpty && (rng.int(0...99) < 78 || attempt > 5)
                let candidate: CommunityAthlete? = fromCircle
                    ? circle[min(circle.count - 1, Int(Double(circle.count) * pow(rng.double(0, 1), 1.9)))]
                    : (wider.isEmpty ? nil : wider[rng.int(0...(wider.count - 1))])
                if let candidate, free(candidate) { who = candidate; break }
            }
            // Deterministic backstop so a thread is ALWAYS the size `threadSize` said it was: an
            // unlucky run of rejected draws must not quietly shorten the list under a rail badge
            // that already committed to a number.
            if who == nil, !wider.isEmpty {
                let start = rng.int(0...(wider.count - 1))
                for step in 0..<wider.count {
                    let candidate = wider[(start + step) % wider.count]
                    if free(candidate) { who = candidate; break }
                }
            }
            guard let who else { continue }
            used.insert(who.handle)
            for token in who.name.lowercased().split(separator: " ") { usedTokens.insert(String(token)) }
            people.append(who)
        }
        guard !people.isEmpty else { return [] }

        // What they say, in three tiers. SPECIFIC lines quote something only this post has (the
        // distance, the pace, the PR, the tonnage) and get first shot, because that is what makes
        // a thread read like it was written under THIS run. AMBIENT lines are true of the post but
        // not unique to it (the city, the hour, the route, the sport). GENERAL is the fact-free
        // pool. Weighting matters as much as the words: an earlier pass let ambient lines lead
        // every thread and the wall repeated "see you saturday" six times in fifty posts.
        var specific = specificLines(for: facts)
        var ambient = ambientLines(for: facts)
        var general = generalLines
        var texts: [String] = []
        for k in people.indices {
            let roll = rng.int(0...99)
            let wantsSpecific = roll < (k == 0 ? 70 : 40)
            let wantsAmbient = roll < (k == 0 ? 88 : 66)
            func take(_ pool: inout [String]) -> String { pool.remove(at: rng.int(0...(pool.count - 1))) }
            if wantsSpecific, !specific.isEmpty {
                texts.append(take(&specific))
            } else if wantsAmbient, !ambient.isEmpty {
                texts.append(take(&ambient))
            } else if !general.isEmpty {
                texts.append(take(&general))
            } else if !ambient.isEmpty {
                texts.append(take(&ambient))
            } else if !specific.isEmpty {
                texts.append(take(&specific))
            } else {
                texts.append("nice")
            }
        }

        // A reply, sometimes. Real threads answer each other with two words and then stop, so at
        // most one reply per thread and only once there is something to reply to. It takes a LATER
        // slot than the line it answers, which keeps replies after their parent by construction.
        if people.count >= 3, rng.int(0...99) < 42 {
            let target = rng.int(0...(people.count - 2))
            let replier = rng.int((target + 1)...(people.count - 1))
            if let handle = people[target].handle.isEmpty ? nil : people[target].handle {
                texts[replier] = "@\(handle) " + replyLines[rng.int(0...(replyLines.count - 1))]
            }
        }

        // `magnitude`, not `abs`: `abs(Int.min)` traps, and the seed is a truncated hash.
        let idStem = String(format: "%010d", Int(base.magnitude % 1_000_000_000))
        return people.indices.map { k in
            Comment(
                id: UUID(uuidString: "00000000-0000-0000-0002-\(idStem)\(String(format: "%02d", k))") ?? UUID(),
                postID: postID,
                authorName: people[k].name, authorHandle: people[k].handle, isCommunity: true,
                text: texts[k],
                date: posted.addingTimeInterval(offsets[k]))
        }
    }

    /// How many comments a post draws. **Reads only what every call site passes** (see the type
    /// doc, rule 2). Shape: an audience ceiling, then a decaying ladder — each further comment is
    /// less likely than the last, which is how a thread actually dies out. Most posts land on 0-2;
    /// the ones a lot of people saw (`baseReactions` already carries the generator's PR bump and
    /// the author's audience) grow a real thread.
    static func threadSize(base: Int, reactions: Int, type: WorkoutType?) -> Int {
        // Calibrated against what the athlete actually scrolls, not against the whole directory:
        // the wall shows the newest 400 of ~2,900 posts, and `CommunityGenerator` scales respects
        // by post age. So a typical wall post carries 15 to 60 respects, and those are the numbers
        // that have to produce a page with conversation on it. (The age range those 400 span is set
        // by `CommunityLedger.isLead` — it was under four hours when every athlete's newest session
        // was a post, and is most of a day now that they post only some of what they train. The
        // respect curve's horizon moved with it; see `CommunityGenerator.post`.)
        let cap = reactions < 8 ? 0 : reactions < 28 ? 2 : reactions < 70 ? 4
                : reactions < 150 ? 7 : 11
        guard cap > 0 else { return 0 }
        var p = min(0.90, 0.18 + Double(reactions) / 90)
        // A Tuesday walk or an evening stretch is not a conversation starter, whoever posted it.
        if type == .walk || type == .yoga || type == .pilates || type == .other { p *= 0.5 }
        let decay = 0.44 + min(0.36, Double(reactions) / 420)
        var rng = SeededRNG(base &* 7919 &+ 13)
        var n = 0
        while n < cap, rng.double(0, 1) <= p {
            n += 1
            p *= decay
        }
        return n
    }

    /// Stable FNV-1a seed over the UUID's bytes (Swift's `hashValue` is randomized per process).
    private static func stableSeed(_ id: UUID) -> Int {
        let b = id.uuid
        let bytes = [b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7, b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15]
        var h: UInt64 = 1469598103934665603
        for byte in bytes { h = (h ^ UInt64(byte)) &* 1099511628211 }
        return Int(truncatingIfNeeded: h)
    }

    // MARK: The voice
    //
    // Short. Often lowercase. Half of them skip the full stop. People ask questions, tease each
    // other, and answer with one word. What they do NOT do is write "Strong work! 🔥" or
    // "Consistency is everything 💪" — that register is a press release, and it was the loudest
    // tell in the old pools. No em dashes anywhere (see [[coach-voice]]).

    /// Lines that hold up under any post. Deliberately fact-free: nothing here quotes a number, so
    /// a thin post can still have a thread without the copy inventing anything.
    static let generalLines = [
        "nice", "love this", "ok this is motivating", "day made", "W", "goals honestly",
        "how do you do this every day", "and I thought I trained hard", "you again", "respect",
        "jealous", "needed this today", "stop it haha", "some of us have jobs", "see you out there",
        "👏", "🔥", "my turn tomorrow", "back at it I see", "i need to get back out there",
        "making me want to lace up", "wow ok", "good for you honestly", "you're everywhere",
        "how", "look at you go", "no notes", "this is why i can't keep up with you",
        "okay okay", "again?? we get it haha", "nice one", "yes!!", "ok noted",
        "you make it look easy", "tell me your secret", "thats a lot", "your insane",
        "im tired just reading this", "okay show off haha", "unreal", "👀", "casual",
        "how are you real", "sheesh", "not normal behaviour",
        "one of us has to slow down and it isn't you",
    ]

    /// Two-word answers. Threads trail off, they don't resolve.
    static let replyLines = [
        "same", "right??", "haha you would", "lol", "agreed", "come with us next time",
        "you're next", "we were literally just talking about this", "exactly", "told you",
        "this", "ok fine you win", "don't encourage them",
    ]
    /// Everything that could be said about THIS post: the specific tier plus the ambient one.
    /// Kept as one call for callers (and tests) that just want the whole gated set.
    static func contextualLines(for facts: PostFacts?) -> [String] {
        specificLines(for: facts) + ambientLines(for: facts)
    }

    /// Lines that quote something **only this post has** — its distance, its pace, its climb, its
    /// tonnage, its PR. Nothing here can be reused on the post below it, which is exactly why a
    /// thread built on these reads written-by-a-person and a thread of stock praise does not.
    /// Every branch is gated on a fact the card actually shows.
    static func specificLines(for facts: PostFacts?) -> [String] {
        guard let f = facts else { return [] }
        var out: [String] = []

        // Distance. The single most commented-on fact in any running feed.
        if let miles = f.miles, f.sport.isGPS {
            let m = fmt(miles)
            let onFoot = f.sport == .run || f.sport == .trailRun || f.sport == .walk || f.sport == .hike
            if onFoot {
                if miles >= 26 {
                    out += ["that is a whole marathon", "\(m) miles because it was \(f.weekday)?",
                            "did you enter a race or just decide to", "\(m) miles. i cannot"]
                } else if miles >= 20 {
                    out += ["\(m) miles on a \(f.weekday)??", "\(m) miles is a drive not a run",
                            "how are the legs today", "i would be asleep for three days",
                            "\(m) miles. on purpose."]
                } else if miles >= 15 {
                    out += ["\(m) miles is a long way", "\(m) miles and I did the dishes", "long one",
                            "what do you even think about for \(m) miles", "big \(f.weekday)"]
                } else if miles >= 13 {
                    out += ["\(m) miles casually", "that is a proper distance",
                            "\(m) miles is further than my commute"]
                    if f.hour < 12 { out += ["half marathon before lunch then"] }
                } else if miles >= 9 {
                    out += ["double digits, ok", "\(m) miles no big deal apparently"]
                } else if miles <= 2.6 {
                    out += ["short but it counts", "quick one", "out and back?", "in and out, love it"]
                }
            } else if miles >= 40 {
                out += ["\(m) miles on the bike is a day out", "how long were you out there"]
            } else if miles >= 15 {
                out += ["\(m) miles on the bike, nice", "solo or with the group?"]
            }
        }

        // Pace, on foot only, and only where it is genuinely notable in either direction.
        if let pace = f.paceSPerMile, f.sport == .run || f.sport == .trailRun {
            let p = clock(pace)
            if pace < 390 {
                out += ["\(p) pace is not real", "sub 7 for the whole thing?", "are you being chased",
                        "ok speedy", "\(p) is a race pace for me"]
            } else if pace < 450 {
                out += ["\(p) average is quick", "that is moving", "\(p) and it says easy run. sure"]
            } else if pace > 660 {
                out += ["chatty pace is the best pace", "this is my kind of run",
                        "\(p) is a pace i could actually hold", "easy days easy. respect",
                        "no notes on that pace"]
            }
        }

        // Climb.
        if let ft = f.climbFt, ft > 0 {
            if ft >= 2200 {
                out += ["\(ft.formatted()) ft is a mountain", "that is vert not a run",
                        "\(ft.formatted()) ft. absolutely not"]
            } else if ft >= 1000 {
                out += ["that climb though", "my calves hurt reading this", "\(ft.formatted()) ft, oof"]
            } else if ft >= 500 {
                out += ["hilly one", "\(ft.formatted()) ft is plenty"]
            }
        }

        // The PR. Only ever here. A couple of these imply a distance of their own, so they are
        // gated again on the post's actual mileage: the badge can outrun the run (the generator
        // draws the two separately), and a "you said you'd never go past 10" under a 2.1 mile
        // post makes that mismatch the loudest thing on the page.
        if let pr = f.pr {
            let miles = f.miles ?? .greatestFiniteMagnitude
            switch pr {
            case "5K PR":
                out += ["how long have you been chasing that", "there it is",
                        "you have been threatening this for months"]
                if miles >= 3 { out += ["5k pr!! finally", "the 5k. huge"] }
            case "Fastest mile":
                out += ["fastest mile?? ok", "what did you split it in", "that is flying"]
            case "Longest run":
                out += ["new longest, how did it feel", "furthest yet. wow", "new distance unlocked"]
                if miles >= 10 { out += ["you said you'd never go past 10"] }
            case "Longest ride":
                out += ["longest ride. how were the legs after", "big day on the bike"]
            case "Longest hike":
                out += ["longest hike, what a day out"]
            case "e1RM PR":
                out += ["pr!! what did it move like", "new best, congrats", "that bar moved",
                        "how many attempts"]
            case "Most volume":
                out += ["that is a lot of tonnage", "biggest session yet?"]
            default:
                out += ["pr!!", "there it is"]
            }
            out += ["told you it would go"]
        }

        // The lifting numbers.
        if f.sport.isStrengthStyle {
            if let vol = f.volumeLb, vol >= 18_000 {
                out += ["\(vol.formatted()) lb in one session is wild", "that total though"]
            }
            if let sets = f.sets, sets >= 18 {
                out += ["\(sets) sets. i'd be there all night", "\(sets) sets is a long night"]
            }
            if let d = f.durationS, d >= 70 * 60 {
                out += ["how long were you in there", "did you move in"]
            }
        }

        // A structured session says what it was in the title, so the questions can be specific.
        if f.sport == .run, f.isStructured {
            out += ["how many were you doing", "what were the splits", "intervals fear",
                    "did you hit them all"]
            let t = f.title.lowercased()
            if t.contains("track") { out += ["track night is the worst"] }
            if t.contains("tempo") { out += ["tempo on a \(f.weekday), brave"] }
            if t.contains("hill") { out += ["hills on purpose is a choice"] }
        }

        if f.weekday == "Sunday", f.sport == .run || f.sport == .trailRun, (f.miles ?? 0) >= 12 {
            out += ["sunday long run gang"]
        }
        return out
    }

    /// True of the post but not unique to it: where it happened, when, what sport, whether there is
    /// a route to steal. These carry the everyday threads, so the pools are deliberately wide — a
    /// line a reader meets twice in one scroll is a tell all by itself.
    static func ambientLines(for facts: PostFacts?) -> [String] {
        guard let f = facts else { return [] }
        var out: [String] = []

        // Time of day, but only when the clock and the title agree. Titles name a time of day
        // ("Lunch run", "Night run", "Sunrise miles") and the generator picks the timestamp
        // separately, so the two can contradict each other. When they do, say nothing about the
        // clock: "night miles hit different" under a post titled "Lunch run" is a tell whichever
        // one is right. Caught in a copy read on 2026-08-28.
        if f.clockMatchesTitle {
            switch f.hour {
            case 0...5:
                out += ["who is up at \(f.hour == 0 ? 12 : f.hour)am", "i cannot do mornings",
                        "please tell me you went back to bed", "this is an unholy hour"]
                if f.hour >= 4 { out += ["the 5am thing is a cult and you are in it"] }
            case 6...7:
                out += ["morning people are different", "up before me as always",
                        "you were done before my alarm", "meanwhile i was asleep"]
            case 12...13 where f.sport.isGPS:
                out += ["lunch break well spent", "i just ate a sandwich", "i could never do a midday one"]
            case 17...19:
                out += ["straight from work then", "evening crew"]
            case 21...23:
                out += ["after dinner? brave", "go to bed"]
                if f.sport.isGPS { out += ["night miles hit different"] }
            default:
                break
            }
        }

        // Season, hemisphere-correct.
        if f.sport.isGPS {
            switch f.season {
            case .winter:
                out += ["how cold was it", "layers or nah", "i am not going outside in this",
                        "was it icy", "cold weather people are built different"]
            case .summer:
                out += ["in this heat??", "the humidity must have been brutal", "i'd melt",
                        "did you carry water", "way too hot for me"]
            case .fall:
                out += ["finally decent weather for it", "best time of year for this"]
            case .spring:
                out += ["perfect time of year for this", "nice to see the sun again"]
            }
        }

        // Place.
        if let city = f.city {
            out += ["wait are you in \(city) now", "\(city) suits you", "one day i'll get to \(city)"]
            if f.hasRoute {
                out += ["is that the \(city) loop?", "i'm in \(city) too, where is this",
                        "next time i'm in \(city) you're showing me around"]
            }
        }

        // The route itself.
        if f.hasRoute {
            out += ["route saved for the weekend", "sending this to my group",
                    "dropping a pin on this one", "that loop looks nice", "stealing this route",
                    "adding this to the list", "is that the whole loop or did you cut it",
                    "might do this on saturday", "how flat is that", "that route looks proper",
                    "where does that one start"]
        }

        // Sport talk.
        switch f.sport {
        case .run:
            out += ["what shoes?", "what are you running in these days", "do you ever take a day off",
                    "solo or with someone?", "how is the training going"]
        case .trailRun:
            out += ["which trail is this?", "trails beat roads every time", "any bears",
                    "what shoes for that?", "how technical is it"]
        case .ride, .mountainBikeRide, .gravelRide, .eBikeRide:
            out += ["what bike are you on", "how was the wind", "coffee stop?", "any traffic on that road"]
        case .walk, .hike:
            out += ["walks count", "podcast walk?", "underrated", "the best kind of day off"]
        case .swimming:
            out += ["pool or open water?", "i sink", "how many yards", "chlorine hair all day",
                    "swimming is so much harder than it looks"]
        case .rowing:
            out += ["what split were you holding", "the erg is evil", "meters in the bank",
                    "the erg does not lie"]
        case .yoga, .pilates:
            out += ["i really need to start doing this", "my hips would file a complaint",
                    "how long is the class", "my hamstrings are jealous"]
        case .strength, .crossfit, .hiit:
            out += ["what's your split", "my back hurts reading this", "how many days a week is this"]
            let t = f.title.lowercased()
            if t.contains("leg") || t.contains("lower") { out += ["legs are gone tomorrow", "leg day fear"] }
            if t.contains("push") || t.contains("chest") { out += ["bench going up?"] }
            if t.contains("pull") || t.contains("back") { out += ["pull day is the good day"] }
        default:
            break
        }

        // Friend talk. Nearly everyone in the thread follows this athlete, so they get to be
        // familiar. Still fact-checked: "move to the gym" belongs under a lift, not a swim.
        out += ["stop making the rest of us look bad", "see you saturday", "we are not the same",
                "what are you training for", "leave some for the rest of us", "you're a menace",
                "i'll be there next time, i promise", "how is this a normal week for you",
                "someone stop them", "ok i need to get my act together", "you win this week",
                "consider me shamed haha", "genuinely how do you fit this in"]
        if f.sport.isStrengthStyle { out += ["at this point just move to the gym"] }
        if f.sport.isGPS { out += ["at this point you live out there"] }

        if f.weekday == "Monday" { out += ["monday and you're already ahead of me"] }
        if f.weekday == "Friday" { out += ["friday and you're still going"] }

        return out
    }


    /// "8" not "8.0", "8.4" not "8.40" — the way a person types a distance.
    private static func fmt(_ miles: Double) -> String {
        let r = (miles * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }

    /// Seconds → "7:42".
    private static func clock(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
