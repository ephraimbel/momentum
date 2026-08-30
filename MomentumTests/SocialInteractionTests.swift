import Testing
import Foundation
@testable import Momentum

/// The interaction contract for the community surfaces (2026-08-29): a tap does something real,
/// it survives a relaunch, and every surface showing that state agrees. These pin the three ways
/// a social page reads as fake — a control that no-ops, a control that forgets, and a control
/// whose effect one screen shows and another doesn't.
@MainActor
struct SocialInteractionTests {

    // MARK: Nudges — a one-a-day rule that only lasted as long as the process

    /// The regression that started this: `sentToday` lived in memory, so force-quitting the app
    /// re-armed the nudge and the pill that read "Nudged" was back to "Nudge".
    @Test func nudgeSurvivesRelaunch() {
        let (defaults, suite) = freshDefaults("nudge.persist")
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = NudgeStore(defaults: defaults)
        #expect(first.canNudge("mayaruns", isSample: true))
        first.nudge("mayaruns", isSample: true)
        #expect(first.nudgedToday("mayaruns"))
        #expect(!first.canNudge("mayaruns", isSample: true))

        let second = NudgeStore(defaults: defaults)          // cold launch
        #expect(second.nudgedToday("mayaruns"))
        #expect(!second.canNudge("mayaruns", isSample: true))
    }

    /// A stale day resets the allowance — the rule is one per DAY, not one forever.
    @Test func nudgeAllowanceRollsOverOnANewDay() {
        let (defaults, suite) = freshDefaults("nudge.roll")
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["mayaruns"], forKey: "com.momentum.social.nudgesSentToday")
        defaults.set(StreakCalculator.localDay(Date()) - 1, forKey: "com.momentum.social.nudgesSentDay")
        let store = NudgeStore(defaults: defaults)
        #expect(!store.nudgedToday("mayaruns"))
        #expect(store.canNudge("mayaruns", isSample: true))
    }

    /// Only mutuals (or seeded members) can be nudged. A real athlete who doesn't follow back is
    /// not offered the gesture at all.
    @Test func onlyMutualsAndSeededMembersCanBeNudged() {
        let (defaults, suite) = freshDefaults("nudge.mutual")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NudgeStore(defaults: defaults)
        #expect(!store.canNudge("realstranger", isSample: false))
        #expect(store.canNudge("seededfriend", isSample: true))
    }

    /// A refused send rolls back AND says why — an undo with no explanation is the same as a
    /// broken button.
    @Test func refusedNudgeRollsBackAndExplains() async {
        let (defaults, suite) = freshDefaults("nudge.refuse")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NudgeStore(defaults: defaults)
        let backend = RefusingBackend()
        store.backend = backend
        store.nudge("realathlete", isSample: false, name: "Real Athlete")
        for _ in 0..<80 where store.nudgedToday("realathlete") { await Task.yield() }
        #expect(!store.nudgedToday("realathlete"))
        #expect(store.takeRefusal()?.contains("Real Athlete") == true)
        #expect(store.takeRefusal() == nil)                  // consumed
        _ = backend
    }

    // MARK: Reactions — a guest's tap must not evaporate

    /// A tap made with no session is held and retried, so signing up later delivers it. Losing it
    /// silently is the worst outcome on a social page.
    @Test func guestReactionIsHeldAndSurvivesRelaunch() async {
        let (defaults, suite) = freshDefaults("react.pending")
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let first = ReactionStore(defaults: defaults)
        first.backend = UnavailableBackend()                 // guest / offline
        first.toggle(id)
        for _ in 0..<80 where first.pending.isEmpty { await Task.yield() }
        #expect(first.pending.contains(id.uuidString))

        let second = ReactionStore(defaults: defaults)        // cold launch
        #expect(second.hasReacted(id))
        #expect(second.pending.contains(id.uuidString))
    }

    /// …and the retry actually lands once there is a session (the sign-up migration).
    @Test func flushDeliversAHeldReaction() async {
        let (defaults, suite) = freshDefaults("react.flush")
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let store = ReactionStore(defaults: defaults)
        store.backend = UnavailableBackend()
        store.toggle(id)
        // Let the first (doomed) push settle before swapping the backend. A queued push reads
        // `backend` when it RUNS, not when it was queued, so swapping underneath an in-flight one
        // makes the call count ambiguous — in the app the backend is wired once and never swaps.
        for _ in 0..<120 { await Task.yield() }
        #expect(store.pending.contains(id.uuidString))

        let confirming = ConfirmingBackend()
        store.backend = confirming
        store.flushPending()
        for _ in 0..<120 where !store.pending.isEmpty { await Task.yield() }
        #expect(store.pending.isEmpty)
        #expect(confirming.reactions.contains(id))
    }

    /// A seeded community post has no server row, so a live session refuses it — and that refusal
    /// is permanent. It must NOT join the retry set, or every wall tap costs a futile round trip
    /// on every refresh forever.
    @Test func refusedReactionByALiveBackendIsNotRetriedForever() async {
        let (defaults, suite) = freshDefaults("react.refused")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReactionStore(defaults: defaults)
        store.backend = RefusingBackend()                     // available, but says no
        let id = UUID()
        store.toggle(id)
        for _ in 0..<80 { await Task.yield() }
        #expect(store.pending.isEmpty)
        #expect(store.hasReacted(id))                         // the local tap still stands
    }

    /// A page that carries `viewer_reacted` must not resurrect an un-react still waiting to push.
    @Test func mergeDoesNotResurrectAnUnpushedUnreact() async {
        let (defaults, suite) = freshDefaults("react.merge")
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let store = ReactionStore(defaults: defaults)
        store.backend = UnavailableBackend()
        store.toggle(id)                                       // react (pending)
        store.toggle(id)                                       // un-react (still pending)
        for _ in 0..<80 where store.pending.isEmpty { await Task.yield() }
        #expect(!store.hasReacted(id))
        store.merge(viewerReacted: [id.uuidString])            // server still thinks we reacted
        #expect(!store.hasReacted(id))
    }

    // MARK: Comments — text the athlete typed is the one thing that must never vanish

    @Test func guestCommentIsHeldAndSurvivesRelaunch() async {
        let (defaults, suite) = freshDefaults("comment.pending")
        defer { defaults.removePersistentDomain(forName: suite) }
        let post = UUID()
        let first = CommentStore(defaults: defaults)
        first.backend = UnavailableBackend()
        let added = first.add("first 20 miler", to: post, authorName: "Me", authorHandle: "me")
        #expect(added != nil)
        for _ in 0..<80 where first.pending.isEmpty { await Task.yield() }
        #expect(first.pending.count == 1)

        let second = CommentStore(defaults: defaults)          // cold launch
        #expect(second.comments(for: post).first?.text == "first 20 miler")
        #expect(second.pending.count == 1)
    }

    @Test func flushDeliversAHeldComment() async {
        let (defaults, suite) = freshDefaults("comment.flush")
        defer { defaults.removePersistentDomain(forName: suite) }
        let post = UUID()
        let store = CommentStore(defaults: defaults)
        store.backend = UnavailableBackend()
        store.add("nice splits", to: post, authorName: "Me", authorHandle: "me")
        // Let the first (doomed) push settle before swapping — see the reaction twin above.
        for _ in 0..<120 { await Task.yield() }
        #expect(store.pending.count == 1)

        let confirming = ConfirmingBackend()
        store.backend = confirming
        store.flushPending()
        for _ in 0..<120 where !store.pending.isEmpty { await Task.yield() }
        #expect(store.pending.isEmpty)
        #expect(confirming.comments.map(\.text) == ["nice splits"])
    }

    @Test func refusedCommentByALiveBackendIsNotHeld() async {
        let (defaults, suite) = freshDefaults("comment.refused")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CommentStore(defaults: defaults)
        store.backend = RefusingBackend()
        store.add("on a seeded post", to: UUID(), authorName: "Me", authorHandle: "me")
        for _ in 0..<80 { await Task.yield() }
        #expect(store.pending.isEmpty)
    }

    @Test func deletingAHeldCommentClearsIt() async {
        let (defaults, suite) = freshDefaults("comment.delete")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CommentStore(defaults: defaults)
        store.backend = UnavailableBackend()
        guard let c = store.add("oops", to: UUID(), authorName: "Me", authorHandle: "me") else {
            Issue.record("comment was not added"); return
        }
        for _ in 0..<80 where store.pending.isEmpty { await Task.yield() }
        store.delete(c)
        #expect(store.pending.isEmpty)
        #expect(store.comments(for: c.postID).isEmpty)
    }

    // MARK: The comment badge and the thread it opens

    /// The rail's comment count and the thread `PostCommentsView` draws come from two different
    /// `CommunityComments.seed` overloads — the pager passes five loose fields, the sheet passes
    /// the whole item. They agree because thread SIZE is drawn from its own stream and reads only
    /// (postID, reactions, type), but that is a property nobody was checking. A badge that says 4
    /// over a list of 6 is the same class of thing as a follower count that disagrees with its
    /// list, so it gets a tripwire rather than a comment saying it should be fine.
    @Test func theCommentBadgeAgreesWithTheThreadItOpens() {
        let now = Date()
        for item in CommunityFeed.seed().prefix(40) {
            let viaItem = CommunityComments.seed(for: item, now: now).count
            let viaFields = CommunityComments.seed(for: item.id, postDate: item.date, now: now,
                                                   reactions: item.baseReactions, type: item.type,
                                                   authorHandle: item.authorHandle).count
            #expect(viaItem == viaFields,
                    "\(item.authorHandle ?? "?")'s post: badge says \(viaFields), thread has \(viaItem)")
        }
    }

    /// An unsent comment is not thrown away when the sheet closes. The composer is `@State` on a
    /// sheet, so a swipe-down or an interruption mid-sentence used to lose the text outright.
    @Test func anUnsentCommentIsKept() {
        let (defaults, suite) = freshDefaults("comment.draft")
        defer { defaults.removePersistentDomain(forName: suite) }
        let post = UUID()
        let store = CommentStore(defaults: defaults)
        #expect(store.draft(for: post).isEmpty)
        store.setDraft("that climb at mile 8", for: post)
        #expect(store.draft(for: post) == "that climb at mile 8")
        // …and it is still there on the next launch.
        #expect(CommentStore(defaults: defaults).draft(for: post) == "that climb at mile 8")
        // Sending clears it — a draft that outlives its own comment would re-fill the composer.
        store.setDraft("", for: post)
        #expect(store.draft(for: post).isEmpty)
        #expect(CommentStore(defaults: defaults).draft(for: post).isEmpty)
    }

    /// Drafts on a pull-to-refresh post are not kept either: that id belongs to a different
    /// workout next launch, so restoring the text would put it in a stranger's composer.
    @Test func aDraftOnAPulsePostIsNotKept() {
        let (defaults, suite) = freshDefaults("comment.draft.ephemeral")
        defer { defaults.removePersistentDomain(forName: suite) }
        let ephemeral = UUID(uuidString: "00000000-0000-0000-0001-900000000050")!
        let store = CommentStore(defaults: defaults)
        store.setDraft("typed on a pulse", for: ephemeral)
        #expect(store.draft(for: ephemeral) == "typed on a pulse")   // still fine in-session
        #expect(CommentStore(defaults: defaults).draft(for: ephemeral).isEmpty)
    }

    // MARK: Blocking — it has to remove them from everywhere, not just the feed

    /// Blocking someone you follow must unfollow them, wherever the block was tapped. Only the
    /// athlete-profile menu used to do this by hand, so a block from the pager or a comment left
    /// them in the ring row, in the follow list, and in the Following count.
    @Test func blockingAlsoUnfollows() {
        let (modDefaults, modSuite) = freshDefaults("mod.unfollow")
        let (followDefaults, followSuite) = freshDefaults("mod.unfollow.follows")
        defer {
            modDefaults.removePersistentDomain(forName: modSuite)
            followDefaults.removePersistentDomain(forName: followSuite)
        }
        let follows = FollowStore(defaults: followDefaults)
        let moderation = ModerationStore(defaults: modDefaults)
        moderation.follows = follows
        follows.toggle("mayaruns")
        #expect(follows.isFollowing("mayaruns"))
        moderation.block("mayaruns")
        #expect(!follows.isFollowing("mayaruns"))
        #expect(follows.count == 0)
    }

    /// Unblocking does not re-follow — a block is a decision, undoing it is not consent.
    @Test func unblockingDoesNotRefollow() {
        let (modDefaults, modSuite) = freshDefaults("mod.unblock")
        let (followDefaults, followSuite) = freshDefaults("mod.unblock.follows")
        defer {
            modDefaults.removePersistentDomain(forName: modSuite)
            followDefaults.removePersistentDomain(forName: followSuite)
        }
        let follows = FollowStore(defaults: followDefaults)
        let moderation = ModerationStore(defaults: modDefaults)
        moderation.follows = follows
        follows.toggle("mayaruns")
        moderation.block("mayaruns")
        moderation.unblock("mayaruns")
        #expect(!follows.isFollowing("mayaruns"))
    }

    /// Reporting an athlete hides them for real. It used to report their hand-built sample posts
    /// only, so the ledger-materialized tiles the grid and the wall actually draw stayed put.
    @Test func reportingAnAthleteHidesEverythingTheyPosted() {
        let (defaults, suite) = freshDefaults("mod.reportAthlete")
        defer { defaults.removePersistentDomain(forName: suite) }
        let moderation = ModerationStore(defaults: defaults)
        let post = FeedItem(id: UUID(), authorName: "Maya", authorHandle: "mayaruns", location: nil,
                            isCommunity: true, type: .run, date: Date(), title: "Run",
                            caption: nil, statLine: "5 mi", prBadge: nil)
        #expect(moderation.isVisible(post))
        moderation.reportAthlete("mayaruns", reason: .spam)
        #expect(moderation.isBlocked("mayaruns"))
        #expect(!moderation.isVisible(post))
        // A post they publish later is hidden too — the block is by author, not by post id.
        let later = FeedItem(id: UUID(), authorName: "Maya", authorHandle: "mayaruns", location: nil,
                             isCommunity: true, type: .run, date: Date(), title: "Another",
                             caption: nil, statLine: "6 mi", prBadge: nil)
        #expect(!moderation.isVisible(later))
    }

    // MARK: Search ranking — "sensible order" is what separates search from a filter

    private static let index: [AthleteSearch.Entry] = [
        .init(index: 0, name: "Ubennettson Clark", handle: "zebra"),
        .init(index: 1, name: "Maya Fields", handle: "mayafields"),
        .init(index: 2, name: "Theo Bennett", handle: "bennettbuilt"),
        .init(index: 3, name: "Maya Rivera", handle: "maya"),
        .init(index: 4, name: "Sam Kim", handle: "runswithmaya"),
    ]

    @Test func exactHandleWins() {
        let hits = AthleteSearch.matches(Self.index, query: "maya")
        #expect(hits.first?.handle == "maya")
    }

    @Test func prefixBeatsSubstring() {
        let hits = AthleteSearch.matches(Self.index, query: "maya").map(\.handle)
        // maya (exact) → mayafields (prefix) → runswithmaya (substring)
        #expect(hits.firstIndex(of: "mayafields")! < hits.firstIndex(of: "runswithmaya")!)
    }

    /// A surname must find the person, not the stranger whose handle merely contains it.
    @Test func aNameWordPrefixOutranksAStrayContains() {
        let hits = AthleteSearch.matches(Self.index, query: "bennett").map(\.handle)
        #expect(hits.first == "bennettbuilt")
        #expect(hits.contains("zebra"))                       // "Ubennettson" still matches
        #expect(hits.firstIndex(of: "bennettbuilt")! < hits.firstIndex(of: "zebra")!)
    }

    @Test func aTypedAtSignIsPartOfTheHandleNotTheQuery() {
        #expect(AthleteSearch.normalize("  @Maya  ") == "maya")
        #expect(AthleteSearch.matches(Self.index, query: "@maya").first?.handle == "maya")
    }

    @Test func noMatchIsEmptyNotEverything() {
        #expect(AthleteSearch.matches(Self.index, query: "qqqq").isEmpty)
        #expect(AthleteSearch.matches(Self.index, query: "   ").isEmpty)
    }

    /// The real directory answers the search it advertises: every featured athlete is findable by
    /// their own handle, and lands first.
    @Test func everyFeaturedAthleteIsFindableByHandle() {
        let entries = CommunityDirectory.all().enumerated()
            .map { AthleteSearch.Entry(index: $0.offset, name: $0.element.name, handle: $0.element.handle) }
        for athlete in CommunityDirectory.featured() {
            let hits = AthleteSearch.matches(entries, query: athlete.handle)
            #expect(hits.first?.handle == athlete.handle.lowercased(),
                    "@\(athlete.handle) is not the top hit for its own handle")
        }
    }

    // MARK: Helpers

    private func freshDefaults(_ prefix: String) -> (UserDefaults, String) {
        let suite = "\(prefix).\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}

// MARK: - Backend spies

/// No session at all — a guest, or offline. Every push fails and `isAvailable` is false.
@MainActor
private final class UnavailableBackend: StubSocialBackend {}

/// Reachable, but the write is refused (no server row for a seeded post, or an RLS denial).
@MainActor
private final class RefusingBackend: StubSocialBackend {
    override var isAvailable: Bool { true }
}

/// Reachable and accepting; records what it took.
@MainActor
private final class ConfirmingBackend: StubSocialBackend {
    // `Comment` must be module-qualified in a file that imports Testing: Swift Testing ships its
    // own `Comment` type (the one `@Test("…")` takes), so the bare name is ambiguous here.
    private(set) var reactions: Set<UUID> = []
    private(set) var comments: [Momentum.Comment] = []
    override var isAvailable: Bool { true }
    override func setReaction(postID: UUID, reacted: Bool) async -> Bool {
        if reacted { reactions.insert(postID) } else { reactions.remove(postID) }
        return true
    }
    override func pushComment(_ comment: Momentum.Comment) async -> Bool {
        comments.append(comment)
        return true
    }
}
