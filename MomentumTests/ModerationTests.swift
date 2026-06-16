import Testing
import Foundation
@testable import Momentum

/// Block + report moderation (docs/SOCIAL-LAYER.md, Slice 5).
@MainActor
struct ModerationTests {
    private func item(_ handle: String?, id: UUID = UUID()) -> FeedItem {
        FeedItem(id: id, authorName: "A", authorHandle: handle, location: nil, isCommunity: true,
                 type: .run, date: Date(), title: "Run", caption: nil, statLine: "5 mi",
                 prBadge: nil, routeNorm: nil)
    }
    private func freshStore() -> (ModerationStore, String) {
        let suite = "mod.test.\(UUID().uuidString)"
        return (ModerationStore(defaults: UserDefaults(suiteName: suite)!), suite)
    }

    @Test func blockingHidesAnAthletesPosts() {
        let (store, suite) = freshStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let post = item("mayaruns")
        #expect(store.isVisible(post))
        store.block("mayaruns")
        #expect(store.isBlocked("mayaruns"))
        #expect(!store.isVisible(post))
        store.unblock("mayaruns")
        #expect(store.isVisible(post))
    }

    @Test func reportingHidesASinglePost() {
        let (store, suite) = freshStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let a = item("x"), b = item("x")
        store.report(a.id)
        #expect(!store.isVisible(a))     // reported one hidden
        #expect(store.isVisible(b))      // the other still shows
    }

    @Test func blocksAndReportsPersist() {
        let suite = "mod.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let s1 = ModerationStore(defaults: defaults); s1.block("coachtheo"); s1.report(id)
        let s2 = ModerationStore(defaults: defaults)
        #expect(s2.isBlocked("coachtheo"))
        #expect(s2.isReported(id))
    }

    @Test func emptyHandleBlockIgnored() {
        let (store, suite) = freshStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        store.block("")
        #expect(store.blockedHandles.isEmpty)
    }
}
