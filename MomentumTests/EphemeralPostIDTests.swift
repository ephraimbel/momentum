import Testing
import Foundation
@testable import Momentum

/// Pull-to-refresh ("pulse") posts and the engagement keyed to them (2026-08-29).
///
/// `CommunityGenerator.postID`'s pulse branch is `900_000_000_000 + (pulse * 50 + slot)` and does
/// not read the handle, while `CommunityPulse.pulse` is a per-process counter that restarts at
/// zero. So the same UUID is handed out to different posts on different launches, and anything
/// persisted against it can resurface under a post the athlete never opened. These pin the defect
/// itself and the store-side guard that keeps it off disk.
@MainActor
struct EphemeralPostIDTests {

    private var now: Date { Date() }

    private func twoAthletes() -> (CommunityAthlete, CommunityAthlete)? {
        let all = CommunityDirectory.all()
        guard all.count > 20 else { return nil }
        return (all[9], all[17])
    }

    // MARK: The defect

    /// The defect, now inverted into the property that replaced it (2026-08-29).
    ///
    /// `postID`'s pulse branch used to be `900_000_000_000 + (pulse * 50 + slot)` with the
    /// `handle` parameter in scope and never read, so two different athletes pulsed at the same
    /// (pulse, slot) were handed the SAME UUID — no relaunch required. The generator now folds the
    /// handle into the hash, so the id says who posted it. This asserts the fixed property rather
    /// than the old bug: the coverage stays, pointed the right way.
    @Test func twoAthletesPulsedAtTheSameSlotGetDifferentIDs() {
        guard let (a, b) = twoAthletes() else { Issue.record("directory too small"); return }
        let now = now
        let postA = CommunityGenerator.freshPost(
            for: a, session: CommunityGenerator.freshSession(for: a, pulse: 1, slot: 0, now: now),
            pulse: 1, slot: 0, now: now)
        let postB = CommunityGenerator.freshPost(
            for: b, session: CommunityGenerator.freshSession(for: b, pulse: 1, slot: 0, now: now),
            pulse: 1, slot: 0, now: now)
        #expect(postA.authorHandle != postB.authorHandle, "picked the same athlete twice")
        #expect(postA.id != postB.id,
                """
                Two athletes' pulse posts share a UUID again. Anything keyed to that id — a \
                comment, a reaction, the +1 it adds to a respect count — belongs to whichever \
                post was minted last. Re-check the handle fold in CommunityGenerator.postID.
                """)
        // Same athlete, different slot: still distinct, or one athlete's own two pulses collide.
        let postA2 = CommunityGenerator.freshPost(
            for: a, session: CommunityGenerator.freshSession(for: a, pulse: 1, slot: 1, now: now),
            pulse: 1, slot: 1, now: now)
        #expect(postA.id != postA2.id)
    }

    /// A LEDGER tile's id is identity-bound and stable: the same athlete + slot always, and never
    /// shared with another athlete. This is what makes a comment on a normal community post safe
    /// to keep, and it is the contract `CommunityPostID` sorts by.
    @Test func ledgerTileIDsAreIdentityBoundAndStable() {
        guard let (a, b) = twoAthletes() else { Issue.record("directory too small"); return }
        let first = CommunityDirectory.gridPosts(for: a, limit: 3)
        let again = CommunityDirectory.gridPosts(for: a, limit: 3)
        let other = CommunityDirectory.gridPosts(for: b, limit: 3)
        #expect(!first.isEmpty)
        #expect(first.map(\.id) == again.map(\.id), "the same athlete's tiles changed id between reads")
        #expect(Set(first.map(\.id)).isDisjoint(with: Set(other.map(\.id))),
                "two athletes' ledger tiles share an id")
    }

    // MARK: The classifier, pinned against ids the real generator actually mints

    @Test func classifierSortsRealMintedIDs() {
        guard let (a, _) = twoAthletes() else { Issue.record("directory too small"); return }
        let now = now
        let pulsed = CommunityGenerator.freshPost(
            for: a, session: CommunityGenerator.freshSession(for: a, pulse: 3, slot: 2, now: now),
            pulse: 3, slot: 2, now: now)
        #expect(CommunityPostID.isEphemeral(pulsed.id),
                "a real pulse post's id was not recognised as ephemeral — the id format drifted")
        for tile in CommunityDirectory.gridPosts(for: a, limit: 5) {
            #expect(!CommunityPostID.isEphemeral(tile.id),
                    "a ledger tile was treated as ephemeral — its engagement would be thrown away")
        }
        // A real athlete's server-side post id is a plain random UUID and must never be caught.
        #expect(!CommunityPostID.isEphemeral(UUID()))
    }

    // MARK: The guard — ephemeral engagement works, then goes away with the post

    @Test func aReactionOnAPulsePostWorksNowAndIsGoneNextLaunch() {
        let (defaults, suite) = freshDefaults("react.ephemeral")
        defer { defaults.removePersistentDomain(forName: suite) }
        let ephemeral = UUID(uuidString: "00000000-0000-0000-0001-900000000050")!
        let durable = UUID(uuidString: "00000000-0000-0000-0001-000012345678")!

        let store = ReactionStore(defaults: defaults)
        store.toggle(ephemeral)
        store.toggle(durable)
        #expect(store.hasReacted(ephemeral))     // real for as long as the post is on screen
        #expect(store.hasReacted(durable))

        let next = ReactionStore(defaults: defaults)   // cold launch
        #expect(!next.hasReacted(ephemeral), "a pulse-post reaction survived and can now land on someone else's post")
        #expect(next.hasReacted(durable), "a normal community reaction was thrown away")
    }

    @Test func aCommentOnAPulsePostWorksNowAndIsGoneNextLaunch() {
        let (defaults, suite) = freshDefaults("comment.ephemeral")
        defer { defaults.removePersistentDomain(forName: suite) }
        let ephemeral = UUID(uuidString: "00000000-0000-0000-0001-900000000050")!
        let durable = UUID(uuidString: "00000000-0000-0000-0001-000012345678")!

        let store = CommentStore(defaults: defaults)
        store.add("on a pulse", to: ephemeral, authorName: "Me", authorHandle: "me")
        store.add("on a tile", to: durable, authorName: "Me", authorHandle: "me")
        #expect(store.comments(for: ephemeral).count == 1)

        let next = CommentStore(defaults: defaults)
        #expect(next.comments(for: ephemeral).isEmpty,
                "a comment on a pull-to-refresh post survived and can now appear under a post the athlete never opened")
        #expect(next.comments(for: durable).map(\.text) == ["on a tile"])
    }

    /// An install that already carries a poisoned key is cleaned on LOAD, not on the next write —
    /// otherwise the filled heart sits on a stranger's post until something else happens to save.
    @Test func alreadyPoisonedStateIsPurgedOnLaunch() {
        let (defaults, suite) = freshDefaults("purge.onload")
        defer { defaults.removePersistentDomain(forName: suite) }
        let ephemeral = "00000000-0000-0000-0001-900000000100"
        defaults.set([ephemeral, "00000000-0000-0000-0001-000000000042"],
                     forKey: "com.momentum.social.reactions")
        let store = ReactionStore(defaults: defaults)
        #expect(!store.hasReacted(UUID(uuidString: ephemeral)!))
        #expect(store.hasReacted(UUID(uuidString: "00000000-0000-0000-0001-000000000042")!))
        // …and the purge was written through, so a later reader sees the clean set too.
        #expect(defaults.stringArray(forKey: "com.momentum.social.reactions")?.contains(ephemeral) == false)
    }

    /// Nothing ephemeral may enter the retry sets: those ids have no server row, ever, so a
    /// pending entry would be a futile round trip on every refresh forever.
    @Test func ephemeralWritesNeverEnterTheRetrySets() async {
        let (rDefaults, rSuite) = freshDefaults("react.noretry")
        let (cDefaults, cSuite) = freshDefaults("comment.noretry")
        defer {
            rDefaults.removePersistentDomain(forName: rSuite)
            cDefaults.removePersistentDomain(forName: cSuite)
        }
        let ephemeral = UUID(uuidString: "00000000-0000-0000-0001-900000000050")!
        let reactions = ReactionStore(defaults: rDefaults)
        reactions.backend = StubSocialBackend()          // unavailable — would normally hold it
        reactions.toggle(ephemeral)
        let comments = CommentStore(defaults: cDefaults)
        comments.backend = StubSocialBackend()
        comments.add("no server row", to: ephemeral, authorName: "Me", authorHandle: "me")
        for _ in 0..<80 { await Task.yield() }
        #expect(reactions.pending.isEmpty)
        #expect(comments.pending.isEmpty)
    }

    private func freshDefaults(_ prefix: String) -> (UserDefaults, String) {
        let suite = "\(prefix).\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}
