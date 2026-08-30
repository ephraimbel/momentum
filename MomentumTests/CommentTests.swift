import Testing
import Foundation
@testable import Momentum

/// Comments + light moderation (docs/SOCIAL-LAYER.md).
@MainActor
struct CommentTests {

    @Test func lightModerationTrimsCapsAndMasks() {
        #expect(CommentModeration.clean("  nice run  ") == "nice run")
        #expect(CommentModeration.clean("   ") == nil)               // empty → nothing to post
        #expect(CommentModeration.clean("") == nil)
        // Masks a crude word, leaves the rest (not strict).
        let cleaned = CommentModeration.clean("that is shit fast")
        #expect(cleaned == "that is •••• fast")
        // Length cap.
        let long = String(repeating: "a", count: 400)
        #expect(CommentModeration.clean(long)?.count == CommentModeration.maxLength)
    }

    @Test func addStoresAndPersistsUserComment() {
        let suite = "comments.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let post = UUID()
        let store = CommentStore(defaults: defaults)
        #expect(store.comments(for: post).isEmpty)

        let added = store.add("great session", to: post, authorName: "Me", authorHandle: "me")
        #expect(added != nil)
        #expect(store.comments(for: post).count == 1)
        #expect(store.add("   ", to: post, authorName: "Me", authorHandle: "me") == nil)  // empty ignored
        #expect(store.comments(for: post).count == 1)

        // Reloads from disk.
        #expect(CommentStore(defaults: defaults).comments(for: post).first?.text == "great session")
    }

    @Test func deleteRemovesUserComment() {
        let suite = "comments.del.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let post = UUID()
        let store = CommentStore(defaults: defaults)
        let c = store.add("oops", to: post, authorName: "Me", authorHandle: "me")!
        store.delete(c)
        #expect(store.comments(for: post).isEmpty)
    }

    @Test func seededCommunityCommentsAreStablePerPost() {
        let post = UUID()
        // A well-seen post, so the draw actually produces a thread to compare.
        let a = CommunityComments.seed(for: post, reactions: 260).map(\.text)
        let b = CommunityComments.seed(for: post, reactions: 260).map(\.text)
        #expect(a == b)                                              // deterministic per post id
        #expect(CommunityComments.seed(for: post, reactions: 260).allSatisfy { $0.isCommunity })
    }

    @Test func reportedCommentIsHidden() {
        let suite = "comments.mod.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let mod = ModerationStore(defaults: defaults)
        let c = Comment(id: UUID(), postID: UUID(), authorName: "X", authorHandle: "x",
                        isCommunity: true, text: "hi", date: Date())
        #expect(mod.isVisible(c))
        mod.report(c.id)
        #expect(!mod.isVisible(c))
    }
}


/// The community's comments have to read like people typed them, or the whole page reads generated
/// (owner ask 2026-08-28: "natural copy in comments so it doesn't feel AI"). These run the real
/// seeded wall through checks a human eye misses on the twentieth thread: the register, the volume
/// distribution, who is talking, when they talked, and whether a line quotes a fact the post has.
@MainActor
struct CommunityCommentVoiceTests {

    // MARK: Sample

    /// A slice of the real seeded community: every Nth athlete's latest post.
    private func samplePosts(_ stride: Int = 11) -> [FeedItem] {
        CommunityDirectory.all().enumerated()
            .compactMap { i, a in i.isMultiple(of: stride) ? a.posts.first : nil }
    }

    /// The same posts with a big audience, so tests about what a LONG thread does aren't hostage to
    /// how many of the sample happened to draw one. Only the size changes; every gate is the same.
    private func busy(_ posts: [FeedItem], reactions: Int = 320) -> [FeedItem] {
        posts.map { var p = $0; p.baseReactions = reactions; return p }
    }

    private func threads(_ posts: [FeedItem], now: Date = Date()) -> [(FeedItem, [Momentum.Comment])] {
        posts.map { ($0, CommunityComments.seed(for: $0, now: now)) }
    }

    /// Deterministic stand-in for the generator's own post seed (never `hashValue`, which is
    /// randomized per process and would make a distribution test flaky).
    private func seedOf(_ id: UUID) -> Int {
        id.uuidString.utf8.reduce(17) { ($0 &* 31 &+ Int($1)) & 0x7FFF_FFFF }
    }

    // MARK: The register

    /// The tells the old pools carried. Every one of these shipped on 2026-08-27 ("Strong work! 🔥",
    /// "Beast mode.", "Consistency is everything 💪", "Proud of you!") and every one is a sentence
    /// nobody types under a friend's run.
    static let bannedRegister = [
        "strong work", "beast mode", "keep it up", "keep up the", "crushing it", "solid effort",
        "consistency is everything", "this is the way", "proud of you", "unreal consistency",
        "inspiring", "great job", "well done", "amazing work", "you got this", "you've got this",
        "way to go", "so proud", "nice work", "impressive", "keep going", "every step counts",
        "showing up >", "let's go!", "beast", "monster session", "absolute legend",
        "killing it", "smashed it", "smashing it", "no days off", "warrior",
        "hard work pays", "love to see it", "the grind", "unstoppable",
    ]

    @Test func theVoiceHasNoAssistantTells() {
        let all = threads(samplePosts() + busy(samplePosts(37))).flatMap(\.1)
        #expect(all.count > 150, "Sample produced almost no comments (\(all.count)); nothing was checked.")
        for c in all {
            let lower = c.text.lowercased()
            #expect(!c.text.contains("—") && !c.text.contains("–"), "Em/en dash in a comment: \(c.text)")
            for phrase in Self.bannedRegister where lower.contains(phrase) {
                Issue.record("Motivational-poster register '\(phrase)': \(c.text)")
            }
            #expect(!c.text.contains("!!!"), "Exclamation stacking: \(c.text)")
            #expect(c.text == c.text.trimmingCharacters(in: .whitespacesAndNewlines), "Untrimmed: '\(c.text)'")
            #expect(!c.text.isEmpty)
        }
    }

    @Test func commentsStayShortTheWayTypedTextIs() {
        let texts = threads(samplePosts() + busy(samplePosts(37))).flatMap(\.1).map(\.text)
        #expect(!texts.isEmpty)
        let lengths = texts.map(\.count).sorted()
        let median = lengths[lengths.count / 2]
        #expect((lengths.last ?? 0) <= 72, "A comment ran long: \(texts.max { $0.count < $1.count } ?? "")")
        #expect(median <= 34, "Median comment length \(median) reads like prose, not a comment.")
        // Real threads are mostly lowercase and mostly unpunctuated. Tidy sentences every time
        // would put us straight back in press-release voice.
        let lowercaseStart = texts.filter { $0.first?.isLowercase == true }.count
        #expect(Double(lowercaseStart) / Double(texts.count) > 0.5,
                "Only \(lowercaseStart)/\(texts.count) comments start lowercase.")
        let noTerminalStop = texts.filter { !($0.last.map { ".!?".contains($0) } ?? false) }.count
        #expect(Double(noTerminalStop) / Double(texts.count) > 0.5,
                "Most comments end in punctuation; that reads written, not typed.")
    }

    // MARK: Volume

    /// The instant this distribution is measured at. Any fixed one would do; it is deliberately an
    /// ordinary weekday mid-morning rather than a time picked for the answer it gives.
    static let fixedNow: Date = Calendar.current.date(
        from: DateComponents(year: 2026, month: 6, day: 17, hour: 9, minute: 0))!

    @Test func threadVolumeIsSkewedNotFlat() {
        // Straight off `threadSize`, so the whole community can be measured without the graph.
        //
        // Measured against a FIXED community (`fixture`), never `all()`. `all()` is anchored to
        // the launch instant and a seeded post's respects grow with its own age, so this histogram
        // slides all day: it read 0.34936, then 0.34901, then 0.34866 across three runs ten
        // minutes apart — a straight line in wall-clock time. A bound on a shape cannot be read
        // off a community that is moving underneath it, and a bar tuned against a moving number is
        // tuned against whatever hour it was tuned at.
        let posts = CommunityDirectory.fixture(now: Self.fixedNow).compactMap { $0.posts.first }
        #expect(posts.count > 500)
        var histogram: [Int: Int] = [:]
        for p in posts {
            histogram[CommunityComments.threadSize(base: seedOf(p.id), reactions: p.baseReactions,
                                                   type: p.type), default: 0] += 1
        }
        let total = Double(posts.count)
        let zero = Double(histogram[0] ?? 0) / total
        let upToTwo = Double((0...2).reduce(0) { $0 + (histogram[$1] ?? 0) }) / total
        let long = (6...12).reduce(0) { $0 + (histogram[$1] ?? 0) }
        #expect(zero > 0.35, "Only \(Int(zero * 100))% of posts have no comments; a flat feed reads generated.")
        #expect(zero < 0.80, "\(Int(zero * 100))% of posts have no comments; that is a ghost town.")
        #expect(upToTwo > 0.72, "Only \(Int(upToTwo * 100))% of posts sit at 0 to 2 comments.")
        #expect(long > 0, "Nothing in the community drew a real thread; the tail is missing.")
        #expect(Double(long) / total < 0.06, "Long threads are not rare enough.")
    }

    @Test func aWellSeenPostOutdrawsAQuietOne() {
        // Same ids, different audience. `baseReactions` is where the generator's PR bump (x1.6)
        // and the author's audience already live, so this is how a PR draws a bigger thread.
        let ids = (0..<400).map { UUID(uuidString: "00000000-0000-0000-0009-\(String(format: "%012d", $0))")! }
        func mean(_ reactions: Int, _ type: WorkoutType = .run) -> Double {
            Double(ids.reduce(0) {
                $0 + CommunityComments.threadSize(base: seedOf($1), reactions: reactions, type: type)
            }) / Double(ids.count)
        }
        #expect(mean(6) == 0)                                   // nobody saw it, nobody commented
        #expect(mean(60) > mean(20))
        #expect(mean(300) > mean(60))
        #expect(mean(120, .walk) < mean(120, .run))             // a quiet walk draws less talk
    }

    /// The rail badge on `CommunityPager` and the list in `PostCommentsView` come from two different
    /// call sites, and only one of them passes the post's facts. If the size ever started reading
    /// those facts, the badge would contradict the list it opens. This is the tripwire.
    @Test func theRailCountAndTheOpenedThreadAgree() {
        for item in samplePosts(23) + busy(samplePosts(97)) {
            let opened = CommunityComments.seed(for: item).count
            let rail = CommunityComments.seed(for: item.id, postDate: item.date,
                                              reactions: item.baseReactions, type: item.type,
                                              authorHandle: item.authorHandle).count
            #expect(opened == rail, "Rail says \(rail), thread shows \(opened) on '\(item.title)'.")
        }
    }

    // MARK: Who is talking

    @Test func commentersAreRealMembersNeverThePoster() throws {
        var seen = 0
        for (post, thread) in threads(samplePosts() + busy(samplePosts(37))) {
            var handles: Set<String> = []
            var tokens: Set<String> = []
            for c in thread {
                // Names too, not just handles, and every part of the name: two accounts can share
                // a display name, and "Felix Walsh" answering "Amara Walsh" reads generated even
                // though the handles differ. Compare a commenter's WHOLE name against the names
                // already in the thread, never token by token: "Cole" is in the directory's
                // first-name and surname pools both, so an athlete really is called "Cole Cole"
                // and a token-at-a-time check collides that name with itself.
                let mine = Set(c.authorName.lowercased().split(separator: " ").map(String.init))
                let roster = thread.map(\.authorName).joined(separator: ", ")
                #expect(tokens.isDisjoint(with: mine),
                        "Two commenters share a name in one thread (\(post.title)): \(roster)")
                tokens.formUnion(mine)
                seen += 1
                let handle = try #require(c.authorHandle)
                let athlete = try #require(CommunityDirectory.athlete(handle: handle),
                                           "Comment from a handle in no directory: \(handle)")
                #expect(athlete.isSample)
                #expect(athlete.name == c.authorName, "Commenter name does not match the directory.")
                #expect(handle != post.authorHandle, "The poster commented on their own post.")
                #expect(!handles.contains(handle), "Same person twice in one thread: \(handle)")
                handles.insert(handle)
            }
        }
        #expect(seen > 150)
    }

    @Test func commentersMostlyFollowThePoster() {
        var followers = 0, total = 0
        for (post, thread) in threads(busy(samplePosts(29))) {
            guard let author = post.authorHandle else { continue }
            for c in thread {
                total += 1
                if let h = c.authorHandle, CommunityGraph.follows(h, author) { followers += 1 }
            }
        }
        #expect(total > 100)
        let share = Double(followers) / Double(total)
        #expect(share > 0.6, "Only \(Int(share * 100))% of commenters follow the poster.")
        #expect(share < 0.99, "Every commenter follows the poster; real feeds get passers-by too.")
    }

    @Test func theSameFriendsRecurAcrossOneAthletesPosts() throws {
        let maya = try #require(CommunityDirectory.featured().first { $0.name == "Maya Rivera" })
        let commenters = busy(CommunityDirectory.gridPosts(for: maya))
            .flatMap { CommunityComments.seed(for: $0).compactMap(\.authorHandle) }
        #expect(commenters.count > 10, "Maya's grid produced almost no comments to compare.")
        var counts: [String: Int] = [:]
        for h in commenters { counts[h, default: 0] += 1 }
        #expect(counts.values.contains { $0 >= 2 },
                "Nobody commented twice across a whole grid; that is not a friend group.")
    }

    // MARK: When they talked

    @Test func everyCommentLandsAfterItsPostAndClustersEarly() {
        let now = Date()
        var offsets: [Double] = []
        for (post, thread) in threads(samplePosts() + busy(samplePosts(37)), now: now) {
            let window = min(max(now.timeIntervalSince(post.date), 1), 36 * 3600)
            var previous = post.date
            for c in thread {
                #expect(c.date > post.date, "A comment predates its post: \(c.text)")
                #expect(c.date <= now, "A comment is dated in the future: \(c.text)")
                #expect(c.date >= previous, "Thread is not in time order.")
                previous = c.date
                offsets.append(c.date.timeIntervalSince(post.date) / window)
            }
        }
        #expect(offsets.count > 150)
        let median = offsets.sorted()[offsets.count / 2]
        #expect(median < 0.32,
                "Comments smear evenly across the post's life (median \(median)); real ones bunch up early.")
    }

    @Test func aReplyComesAfterTheLineItAnswers() {
        var replies = 0
        for (_, thread) in threads(busy(samplePosts(19))) {
            for (i, c) in thread.enumerated() where c.text.hasPrefix("@") {
                replies += 1
                let mentioned = String(c.text.dropFirst().prefix { !$0.isWhitespace })
                #expect(thread.prefix(i).compactMap(\.authorHandle).contains(mentioned),
                        "Reply to @\(mentioned) with nothing earlier in the thread to answer.")
                #expect(c.authorHandle != mentioned, "Someone replied to themselves.")
            }
        }
        #expect(replies > 0, "No thread ever answered itself.")
    }

    // MARK: What they say about THIS post

    @Test func aLineNeverQuotesAFactThePostDoesNotHave() throws {
        let pattern = try NSRegularExpression(pattern: "([0-9][0-9,]*(\\.[0-9]+)?)\\s*(miles|mi|lb|ft|sets)\\b")
        var checked = 0
        for (post, thread) in threads(samplePosts(7) + busy(samplePosts(13))) {
            let facts = PostFacts(item: post)
            for c in thread {
                // Drop a reply's "@handle" so a handle's own digits are never read as a number.
                let body = c.text.hasPrefix("@") ? String(c.text.drop { !$0.isWhitespace }) : c.text
                let ns = body as NSString
                for m in pattern.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                    checked += 1
                    let value = Double(ns.substring(with: m.range(at: 1))
                        .replacingOccurrences(of: ",", with: "")) ?? -1
                    let where_ = "'\(c.text)' vs \(post.statLine)"
                    switch ns.substring(with: m.range(at: 3)) {
                    case "mi", "miles":
                        #expect(abs((facts.miles ?? -99) - value) < 0.06, "\(where_)")
                    case "lb":
                        #expect(Double(facts.volumeLb ?? -99) == value, "\(where_)")
                    case "ft":
                        #expect(Double(facts.climbFt ?? -99) == value, "\(where_)")
                    default:
                        #expect(Double(facts.sets ?? -99) == value, "\(where_)")
                    }
                }
                // A PR line under a post that set no PR is the loudest kind of invented context.
                if c.text.range(of: "\\bpr\\b", options: [.regularExpression, .caseInsensitive]) != nil {
                    #expect(post.prBadge != nil, "PR line on a post with no PR: \(c.text)")
                }
                // The route lines offer to save a route; a mapless post has none to save.
                if c.text.contains("route saved") || c.text.contains("dropping a pin") {
                    #expect(facts.hasRoute, "Route line on a post with no route: \(c.text)")
                }
                // Shoes belong under a run, not a swim.
                if c.text.contains("shoes") {
                    #expect(post.type == .run || post.type == .trailRun, "Shoes under a \(post.type): \(c.text)")
                }
            }
        }
        #expect(checked > 0, "No comment quoted a number; the contextual half never fired.")
    }

    @Test func theContextualPoolIsGatedByTheFacts() {
        // A plain evening lift: no distance, no route, no PR, no city.
        let lift = PostFacts(sport: .strength, title: "Push day", durationS: 46 * 60,
                             volumeLb: 9_400, sets: 12, hour: 18, weekday: "Wednesday", season: .fall)
        let liftLines = CommunityComments.contextualLines(for: lift)
        #expect(!liftLines.isEmpty)
        #expect(!liftLines.contains { $0.range(of: "[0-9]+(\\.[0-9])? mi", options: .regularExpression) != nil })
        #expect(!liftLines.contains { $0.range(of: "\\bpr\\b", options: [.regularExpression, .caseInsensitive]) != nil })
        #expect(!liftLines.contains { $0.contains("route saved") })
        #expect(!liftLines.contains { $0.contains("shoes") })
        // 9,400 lb over 12 sets is an ordinary night: no line brags about the numbers.
        #expect(!liftLines.contains { $0.contains("lb") || $0.contains("sets") })

        // The same session, but it set a PR: now, and only now, the PR lines exist.
        var withPR = lift
        withPR.pr = "e1RM PR"
        #expect(CommunityComments.contextualLines(for: withPR)
            .contains { $0.range(of: "\\bpr\\b", options: [.regularExpression, .caseInsensitive]) != nil })

        // A long Tuesday run in Austin with a route: the distance line quotes the real distance.
        let long = PostFacts(sport: .run, title: "Long run", city: "Austin", miles: 22.4,
                             durationS: 3 * 3600 + 12 * 60, hasRoute: true, hour: 6,
                             weekday: "Tuesday", season: .summer)
        let longLines = CommunityComments.contextualLines(for: long)
        #expect(longLines.contains("22.4 miles on a Tuesday??"))
        #expect(longLines.contains("is that the Austin loop?"))
        #expect(longLines.contains { $0.contains("route saved") })
        #expect(longLines.contains { $0.contains("heat") || $0.contains("humidity") || $0.contains("melt") })
        #expect(!longLines.contains { $0.contains("cold") })
        #expect(!longLines.contains { $0.contains("lb") })
        #expect(!longLines.contains { $0.contains("\(24)") }, "A number that is not on the card.")

        // A PR badge can outrun the run it sits on (the generator draws them separately), so the
        // lines that imply a distance are gated on the distance too.
        let shortPR = PostFacts(sport: .run, title: "Quick one before work", miles: 2.1,
                                durationS: 1_280, pr: "Longest run")
        let shortLines = CommunityComments.contextualLines(for: shortPR)
        #expect(!shortLines.contains { $0.contains("never go past 10") })
        #expect(shortLines.contains("new longest, how did it feel"))
        let longPR = PostFacts(sport: .run, title: "Long one", miles: 16.2, durationS: 9_100,
                               pr: "Longest run")
        #expect(CommunityComments.contextualLines(for: longPR).contains { $0.contains("never go past 10") })

        // Nothing to go on still yields a thread, from the fact-free pool.
        #expect(CommunityComments.contextualLines(for: nil).isEmpty)
        #expect(CommunityComments.generalLines.allSatisfy { !$0.contains("mi") })
        #expect(CommunityComments.generalLines.allSatisfy { $0.rangeOfCharacter(from: .decimalDigits) == nil })
    }

    /// Titles name a time of day and the generator picks the timestamp separately, so they can
    /// disagree. When they do, no line may mention the clock at all.
    @Test func noClockLineContradictsTheTitle() {
        let lunchAtNight = PostFacts(sport: .run, title: "Lunch run", miles: 3.7, durationS: 1_950,
                                     hour: 22, weekday: "Thursday", season: .fall)
        #expect(!lunchAtNight.clockMatchesTitle)
        let lines = CommunityComments.contextualLines(for: lunchAtNight)
        #expect(!lines.contains { $0.contains("night") || $0.contains("dinner") || $0.contains("bed") })

        let lunchAtLunch = PostFacts(sport: .run, title: "Lunch run", miles: 3.7, durationS: 1_950,
                                     hour: 12, weekday: "Thursday", season: .fall)
        #expect(lunchAtLunch.clockMatchesTitle)
        #expect(CommunityComments.contextualLines(for: lunchAtLunch).contains("i just ate a sandwich"))

        // A title that names no time never blocks the clock lines.
        #expect(PostFacts(sport: .run, title: "Easy miles", hour: 22).clockMatchesTitle)

        // And across the real wall, a "night"/"morning" title never draws the opposite line.
        for post in samplePosts(7) {
            let facts = PostFacts(item: post)
            let t = post.title.lowercased()
            guard t.contains("night") || t.contains("morning") || t.contains("lunch")
                    || t.contains("sunrise") || t.contains("evening") else { continue }
            for c in CommunityComments.seed(for: post) {
                if t.contains("morning") || t.contains("sunrise") {
                    #expect(!c.text.contains("night miles"), "'\(post.title)' drew: \(c.text)")
                }
                if t.contains("night") || t.contains("evening") {
                    #expect(!c.text.contains("before my alarm"), "'\(post.title)' drew: \(c.text)")
                    #expect(!c.text.contains("morning people"), "'\(post.title)' drew: \(c.text)")
                }
            }
        }
    }

    @Test func seasonsFollowTheHemisphere() {
        #expect(PostFacts.season(month: 1, city: "Boston, MA") == .winter)
        #expect(PostFacts.season(month: 1, city: "Sydney") == .summer)
        #expect(PostFacts.season(month: 7, city: "Melbourne") == .winter)
        #expect(PostFacts.season(month: 1, city: "Singapore") == .summer)
        let sydneyJanuary = PostFacts(sport: .run, miles: 6, durationS: 2_900,
                                      season: PostFacts.season(month: 1, city: "Sydney"))
        #expect(!CommunityComments.contextualLines(for: sydneyJanuary).contains { $0.contains("cold") })
    }

    @Test func postFactsReadTheCardsOwnStatLine() {
        let run = PostFacts.parse(statLine: "8.4 mi · 1:07:12")
        #expect(run.miles == 8.4 && run.durationS == 4_032)
        let trail = PostFacts.parse(statLine: "6.2 mi · 58:03 · 1,240 ft")
        #expect(trail.miles == 6.2 && trail.durationS == 3_483 && trail.climbFt == 1_240)
        let lift = PostFacts.parse(statLine: "12,400 lb · 14 sets · 52:18")
        #expect(lift.volumeLb == 12_400 && lift.sets == 14 && lift.miles == nil)
        let timed = PostFacts.parse(statLine: "42:07")
        #expect(timed.durationS == 2_527 && timed.miles == nil && timed.volumeLb == nil)
        // Pace comes back out of the pair the card already shows.
        #expect(Int(PostFacts(sport: .run, miles: 8.4, durationS: 4_032).paceSPerMile ?? 0) == 480)
    }
}
