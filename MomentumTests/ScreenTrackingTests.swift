import Foundation
import Testing
@testable import Momentum

/// `ScreenTracker` — the session/screen half of the funnel.
///
/// What is pinned here is the set of properties the drop-off views depend on. If one of these
/// breaks, the SQL still runs and still returns rows; the rows are just quietly wrong, which is
/// worse than an outage. Each test names the query it protects.
@MainActor
struct ScreenTrackingTests {

    /// Records what was logged, in order. The tracker's whole job is emitting the right events with
    /// the right dimensions, so the double only has to remember them.
    final class Recorder: AnalyticsServing {
        var events: [AnalyticsEvent] = []
        func log(_ event: AnalyticsEvent) { events.append(event) }
        func flush() {}
        func northStarStatus() -> NorthStarFunnel.Status { .pending }

        var names: [String] { events.map(\.name) }
        func params(_ name: String) -> [[String: String]] {
            events.filter { $0.name == name }.map(\.parameters)
        }
    }

    /// Isolated defaults per test — `.standard` would leak an open session between cases and into
    /// the app itself.
    private func freshDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func tracker(_ recorder: Recorder, _ defaults: UserDefaults) -> ScreenTracker {
        ScreenTracker(analytics: recorder, defaults: defaults, recoverStaleSession: false)
    }

    // MARK: - screen_view

    /// One event per entry, carrying the closed-vocabulary name. `screen_reach` counts distinct
    /// installs per `params->>'screen'`, so a wrong or missing name is a room that vanishes.
    @Test func logsAScreenViewPerEntry() {
        let rec = Recorder()
        let t = tracker(rec, freshDefaults())
        t.enter(.today)
        t.enter(.plan)

        #expect(rec.names == ["screen_view", "screen_view"])
        #expect(rec.params("screen_view").map { $0["screen"] } == ["today", "plan"])
    }

    /// `seq` is what `screen_exit_rate` and `screen_paths` order by inside a session. If it did not
    /// increment, `lead(screen)` would pair the wrong screens and every path in the report would be
    /// fiction.
    @Test func sequenceIncrementsWithinASession() {
        let rec = Recorder()
        let t = tracker(rec, freshDefaults())
        t.enter(.today)
        t.enter(.plan)
        t.enter(.today)

        #expect(rec.params("screen_view").map { $0["seq"] } == ["1", "2", "3"])
        // One session, so one id throughout — the partition key for both path views.
        let ids = Set(rec.params("screen_view").compactMap { $0["session"] })
        #expect(ids.count == 1)
    }

    /// SwiftUI fires `onAppear` more than once for one view in several layouts. Two entries into the
    /// same screen a few milliseconds apart are one view; counting them twice would inflate exactly
    /// the denominator `exit_pct` divides by, making busy screens look healthier than they are.
    @Test func absorbsDuplicateAppearForTheSameScreen() {
        let rec = Recorder()
        let t = tracker(rec, freshDefaults())
        let t0 = Date()
        t.enter(.today, at: t0)
        t.enter(.today, at: t0.addingTimeInterval(0.05))

        #expect(rec.params("screen_view").count == 1)
    }

    /// …but leaving and coming back IS two views. Tab → away → back is the single most common shape
    /// in the app, and collapsing it would erase most of the path data.
    @Test func reEnteringLaterCountsAgain() {
        let rec = Recorder()
        let t = tracker(rec, freshDefaults())
        let t0 = Date()
        t.enter(.today, at: t0)
        t.enter(.plan, at: t0.addingTimeInterval(5))
        t.enter(.today, at: t0.addingTimeInterval(10))

        #expect(rec.params("screen_view").count == 3)
    }

    // MARK: - session_end

    /// The drop-off signal itself: the LAST screen, the depth, and honest wall-clock. `last_screen`
    /// is what `session_dropoff` and `churn_screen` both group by.
    @Test func sessionEndCarriesTheLastScreen() {
        let rec = Recorder()
        let t = tracker(rec, freshDefaults())
        let t0 = Date()
        t.enter(.today, at: t0)
        t.enter(.plan, at: t0.addingTimeInterval(20))
        t.enter(.planSession, at: t0.addingTimeInterval(40))
        t.endSession(at: t0.addingTimeInterval(60))

        let end = rec.params("session_end").first
        #expect(end?["last_screen"] == "plan_session")
        #expect(end?["views"] == "3")
        #expect(end?["duration_s"] == "60")
        #expect(end?["reason"] == "background")
    }

    /// Ending twice must not emit twice. `endSession` is called from a `scenePhase` change, which
    /// SwiftUI can deliver more than once; a duplicate would double-count one athlete's exit in
    /// every ranking the report prints.
    @Test func endingAnAlreadyClosedSessionIsANoOp() {
        let rec = Recorder()
        let t = tracker(rec, freshDefaults())
        t.enter(.today)
        t.endSession()
        t.endSession()

        #expect(rec.params("session_end").count == 1)
    }

    /// No screens seen means no session to close — a background transition during a cold launch
    /// must not invent a zero-length session and pollute `median_seconds`.
    @Test func endingWithoutAnyScreenEmitsNothing() {
        let rec = Recorder()
        let t = tracker(rec, freshDefaults())
        t.endSession()

        #expect(rec.events.isEmpty)
    }

    /// After a session closes, the next screen opens a NEW one — a fresh id and `seq` back to 1.
    /// Without this the second visit's screens would be appended to the first session's path.
    @Test func aNewSessionStartsAfterTheOldOneEnds() {
        let rec = Recorder()
        let t = tracker(rec, freshDefaults())
        t.enter(.today)
        let first = t.currentSessionID
        t.endSession()
        t.enter(.fuel)

        #expect(t.currentSessionID != first)
        #expect(rec.params("screen_view").last?["seq"] == "1")
    }

    // MARK: - the abandoned case

    /// THE ONE THAT MATTERS MOST. A crash or a force-quit while the app is in the foreground means
    /// `endSession` never runs — and those are the sessions most worth reading. The next launch
    /// finds the persisted session and closes it, stamped `abandoned`.
    @Test func aSessionKilledMidFlightIsRecoveredOnTheNextLaunch() {
        let defaults = freshDefaults()
        let first = Recorder()
        let t0 = Date()
        // A session that never gets to end — the process dies here.
        let dying = ScreenTracker(analytics: first, defaults: defaults, recoverStaleSession: false)
        dying.enter(.workoutRecorder, at: t0)
        dying.enter(.workoutSave, at: t0.addingTimeInterval(30))
        #expect(first.params("session_end").isEmpty)

        // Next launch, same defaults.
        let second = Recorder()
        _ = ScreenTracker(analytics: second, defaults: defaults)

        let end = second.params("session_end").first
        #expect(end?["reason"] == "abandoned")
        #expect(end?["last_screen"] == "workout_save")
        // Stamped at the last screen view, NOT at recovery time. Using `now` would report every
        // crashed session as lasting until the athlete happened to reopen the app — which could be
        // days, and would wreck every duration average in the report.
        #expect(end?["duration_s"] == "30")
    }

    /// A recovered session is consumed, not replayed. A second launch must not report it again, or
    /// one crash would count as churn on every subsequent launch.
    @Test func aRecoveredSessionIsOnlyReportedOnce() {
        let defaults = freshDefaults()
        let dying = ScreenTracker(analytics: Recorder(), defaults: defaults, recoverStaleSession: false)
        dying.enter(.today)

        _ = ScreenTracker(analytics: Recorder(), defaults: defaults)
        let third = Recorder()
        _ = ScreenTracker(analytics: third, defaults: defaults)

        #expect(third.events.isEmpty)
    }

    /// A clean exit leaves nothing behind, so the next launch has no stale session to recover.
    @Test func aCleanlyEndedSessionIsNotRecovered() {
        let defaults = freshDefaults()
        let t = ScreenTracker(analytics: Recorder(), defaults: defaults, recoverStaleSession: false)
        t.enter(.today)
        t.endSession()

        let next = Recorder()
        _ = ScreenTracker(analytics: next, defaults: defaults)
        #expect(next.events.isEmpty)
    }

    /// A long gap without a clean background transition rolls the session over rather than gluing
    /// yesterday's screens to today's — `sessions_per_install` depends on the boundary being real.
    @Test func aLongGapStartsAFreshSession() {
        let rec = Recorder()
        let t = tracker(rec, freshDefaults())
        let t0 = Date()
        t.enter(.today, at: t0)
        t.enter(.plan, at: t0.addingTimeInterval(ScreenTracker.inactivityWindow + 60))

        let end = rec.params("session_end").first
        #expect(end?["reason"] == "timed_out")
        #expect(end?["last_screen"] == "today")
        #expect(rec.params("screen_view").last?["seq"] == "1")   // the new session restarts the count
    }

    // MARK: - the vocabulary

    @Test func foregroundReturnTracksTheStillVisibleScreenWithoutAnotherAppear() {
        let rec = Recorder(), t0 = Date()
        let t = tracker(rec, freshDefaults()), id = UUID()
        t.appeared(.today, id: id, at: t0)
        let first = t.currentSessionID
        t.sceneChanged(.background, at: t0.addingTimeInterval(5))
        t.sceneChanged(.active, at: t0.addingTimeInterval(10))
        #expect(t.currentSessionID != first)
        #expect(rec.params("screen_view").map { $0["screen"] } == ["today", "today"])
        #expect(rec.params("screen_view").last?["seq"] == "1")
    }

    @Test func dismissingASheetRestoresTheUnderlyingScreen() {
        let rec = Recorder()
        let subject = tracker(rec, freshDefaults()), root = UUID(), sheet = UUID()
        subject.appeared(.fuel, id: root)
        subject.appeared(.mealDetail, id: sheet)
        subject.disappeared(id: sheet)
        subject.endSession()
        #expect(rec.params("screen_view").map { $0["screen"] } == ["fuel", "meal_detail", "fuel"])
        #expect(rec.params("session_end").last?["last_screen"] == "fuel")
    }

    @Test func parentDisappearingAfterChildAppearsDoesNotStealItsScreen() {
        let rec = Recorder(), root = UUID(), child = UUID()
        let t = tracker(rec, freshDefaults())
        t.appeared(.plan, id: root)
        t.appeared(.planSettings, id: child)
        t.disappeared(id: root)
        t.sceneChanged(.inactive)
        #expect(rec.params("session_end").isEmpty)
        t.sceneChanged(.background)
        t.appeared(.plan, id: UUID()) // background UI changes must not open a new visit
        #expect(t.currentSessionID == nil)
        #expect(rec.params("session_end").last?["last_screen"] == "plan_settings")
    }

    @Test func duplicateAppearAfterOneSecondDoesNotInflateViews() {
        let rec = Recorder(), t0 = Date()
        let t = tracker(rec, freshDefaults())
        t.enter(.today, at: t0)
        t.enter(.today, at: t0.addingTimeInterval(5))
        #expect(rec.params("screen_view").count == 1)
    }

    /// Screen names are the join key of every view in `20260907000001_screen_dropoff.sql` and they
    /// are compared across builds. Renaming one silently re-labels history — the exact trap
    /// `onboarding_funnel` had to be re-keyed on `build` to escape. Uniqueness and snake_case are
    /// the cheap half of keeping that honest.
    @Test func screenNamesAreUniqueAndStable() {
        let raws = AppScreen.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
        for raw in raws {
            #expect(raw == raw.lowercased())
            #expect(!raw.contains(" "))
            #expect(!raw.contains("-"))
        }
    }

    /// The four screens `app_journey` names in SQL must exist here under exactly these strings, and
    /// the Progress rooms must keep the `progress` prefix the view's `like 'progress%'` matches.
    @Test func theJourneyViewsScreenNamesResolve() {
        #expect(AppScreen.today.rawValue == "today")
        #expect(AppScreen.plan.rawValue == "plan")
        #expect(AppScreen.fuel.rawValue == "fuel")
        #expect(AppScreen.progress.rawValue == "progress")
        for s in [AppScreen.progressTrends, .progressHealth, .progressHistory] {
            #expect(s.rawValue.hasPrefix("progress"))
        }
    }
}
