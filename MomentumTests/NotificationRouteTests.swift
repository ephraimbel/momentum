import Foundation
import Testing
@testable import Momentum

/// The route every notification carries (notification pass 2026-09-06): it must survive the trip
/// through a plist `userInfo` and the inbox's UserDefaults map, and an unknown string from a
/// future version must decode to nil, never crash.
struct NotificationRouteTests {

    private let sessionID = UUID()

    private var every: [NotificationRoute] {
        [.today, .plan, .planWeek(Calendar.current.startOfDay(for: Date())), .planSession(sessionID),
         .progress("Health"), .progress("Trends"), .coach, .fuel, .settings]
    }

    @Test func everyRouteRoundTripsThroughItsRawValue() {
        for route in every {
            #expect(NotificationRoute(rawValue: route.rawValue) == route, "\(route)")
        }
    }

    /// `userInfo` is a plist dictionary at runtime; this mirrors the delegate's read.
    @Test func everyRouteRoundTripsThroughUserInfo() {
        for route in every {
            let info: [AnyHashable: Any] = [NotificationRoute.userInfoKey: route.rawValue,
                                            NotificationRoute.familyKey: NotificationFamily.session.rawValue]
            #expect(NotificationRoute(userInfo: info) == route, "\(route)")
        }
    }

    @Test func unknownAndMalformedStringsDecodeToNil() {
        #expect(NotificationRoute(rawValue: "") == nil)
        #expect(NotificationRoute(rawValue: "moon") == nil)
        #expect(NotificationRoute(rawValue: "plan.session:not-a-uuid") == nil)
        #expect(NotificationRoute(rawValue: "plan.session") == nil)
        #expect(NotificationRoute(rawValue: "plan.week:soon") == nil)
        #expect(NotificationRoute(rawValue: "progress:") == nil)
        #expect(NotificationRoute(userInfo: [:]) == nil)
        #expect(NotificationRoute(userInfo: ["momentum.route": 42]) == nil)
    }

    @Test func routesKnowTheirTab() {
        #expect(NotificationRoute.today.tab == .today)
        #expect(NotificationRoute.plan.tab == .plan)
        #expect(NotificationRoute.planSession(sessionID).tab == .plan)
        #expect(NotificationRoute.progress("Health").tab == .progress)
        #expect(NotificationRoute.fuel.tab == .fuel)
        #expect(NotificationRoute.settings.tab == .profile)
        #expect(NotificationRoute.coach.tab == nil)   // a cover over whatever tab is showing
    }

    /// Easings and recovery days open the Health hub; a recalibration opens the board; a move
    /// opens the moved session when the decision knows it, else the board.
    @Test func coachingKindsLandWhereTheirReasonLives() {
        #expect(NotificationRoute.forCoaching(.ease) == .progress("Health"))
        #expect(NotificationRoute.forCoaching(.recover) == .progress("Health"))
        #expect(NotificationRoute.forCoaching(.recalibrate) == .plan)
        #expect(NotificationRoute.forCoaching(.moved) == .plan)
        #expect(NotificationRoute.forCoaching(.moved, focusSessionID: sessionID) == .planSession(sessionID))
        // A focus only means something for a move.
        #expect(NotificationRoute.forCoaching(.ease, focusSessionID: sessionID) == .progress("Health"))
    }

    @Test func everyFamilyHasAThread() {
        for family in NotificationFamily.allCases {
            #expect(family.thread.hasPrefix("momentum."), "\(family.rawValue)")
        }
        #expect(NotificationFamily.session.thread == NotificationFamily.catchUp.thread)   // the plan's own thread
        #expect(NotificationFamily.coaching.thread == NotificationFamily.readiness.thread)
    }
}

/// The inbox's route map: id-keyed, last write wins, pruned oldest-first past the cap.
struct NotificationRouteStoreTests {

    private func freshDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "notification-route-store-tests")!
        d.removePersistentDomain(forName: "notification-route-store-tests")
        return d
    }

    @Test func roundTripsAndOverwrites() {
        let d = freshDefaults()
        let id = UUID()
        #expect(NotificationRouteStore.route(for: id, in: d) == nil)
        NotificationRouteStore.set(.fuel, for: id, in: d)
        #expect(NotificationRouteStore.route(for: id, in: d) == .fuel)
        NotificationRouteStore.set(.planSession(id), for: id, in: d)
        #expect(NotificationRouteStore.route(for: id, in: d) == .planSession(id))
        // Overwriting never grows the map.
        #expect((d.array(forKey: NotificationRouteStore.key) as? [[String]])?.count == 1)
    }

    @Test func prunesOldestPastTheCap() {
        let d = freshDefaults()
        let first = UUID()
        NotificationRouteStore.set(.today, for: first, in: d)
        for _ in 0..<NotificationRouteStore.cap { NotificationRouteStore.set(.plan, for: UUID(), in: d) }
        #expect((d.array(forKey: NotificationRouteStore.key) as? [[String]])?.count == NotificationRouteStore.cap)
        #expect(NotificationRouteStore.route(for: first, in: d) == nil)   // the oldest is the one dropped
    }

    @Test func garbageEntriesAreIgnored() {
        let d = freshDefaults()
        let id = UUID()
        d.set([[id.uuidString, "moon"], ["lonely"]], forKey: NotificationRouteStore.key)
        #expect(NotificationRouteStore.route(for: id, in: d) == nil)
    }
}

/// Notification copy carries no dash marks (owner call 2026-09-06). The scrubber turns the coach's
/// em-dash idiom into sentences and hyphenated words into plain ones.
struct NotificationCopyTests {

    @Test func emDashesBecomeSentenceBreaks() {
        #expect(NotificationCopy.clean("Push day — 4 exercises") == "Push day. 4 exercises")
        #expect(NotificationCopy.clean("Easy run 8 km – still on track") == "Easy run 8 km. Still on track")
    }

    @Test func hyphensBecomeSpaces() {
        #expect(NotificationCopy.clean("A 5-day streak, warm-up first") == "A 5 day streak, warm up first")
    }

    @Test func cleanStringsPassUntouched() {
        let s = "Easy run 8 km ~6:10 /km. It's on the map whenever you are."
        #expect(NotificationCopy.clean(s) == s)
        #expect(NotificationCopy.isClean(s))
        #expect(!NotificationCopy.isClean("week-in-review"))
        #expect(!NotificationCopy.isClean("a — b"))
    }

    @Test func streakBodySpeaksWithoutDashes() {
        let body = NotificationService.streakBody(streak: 6)
        #expect(NotificationCopy.isClean(body))
        #expect(body.contains("6 days"))
        #expect(!body.contains("!"))   // no cheerleading
    }
}
