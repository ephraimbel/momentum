import ActivityKit
import Foundation

/// Drives the rest-timer Live Activity lifecycle from the app. Every call no-ops gracefully when
/// Live Activities are disabled by the user or unavailable (e.g. a simulator without support), so
/// the logger never depends on it. One rest timer is live at a time.
@MainActor
final class RestActivityController {
    private var activity: Activity<RestActivityAttributes>?

    /// Begin (or replace) the rest Live Activity for a freshly-finished set.
    func start(exerciseName: String, startedAt: Date, endsAt: Date, setsDone: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()   // never stack two rest timers
        let attributes = RestActivityAttributes(exerciseName: exerciseName)
        let state = RestActivityAttributes.ContentState(startedAt: startedAt, endsAt: endsAt, setsDone: setsDone)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: endsAt.addingTimeInterval(60)))
        } catch {
            activity = nil   // requests can fail (budget, disabled) — stay silent, the in-app ring still works
        }
    }

    /// Reflect a ±15s adjustment on the live countdown.
    func update(startedAt: Date, endsAt: Date, setsDone: Int) {
        guard let activity else { return }
        let state = RestActivityAttributes.ContentState(startedAt: startedAt, endsAt: endsAt, setsDone: setsDone)
        Task { await activity.update(.init(state: state, staleDate: endsAt.addingTimeInterval(60))) }
    }

    /// End the rest Live Activity immediately (skip, next set, or workout finished).
    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
