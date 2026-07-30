import ActivityKit
import Foundation

/// Drives the rest-timer Live Activity lifecycle from the app. Every call no-ops gracefully when
/// Live Activities are disabled by the user or unavailable (e.g. a simulator without support), so
/// the logger never depends on it. One rest timer is live at a time.
@MainActor
final class RestActivityController {
    private var activity: Activity<RestActivityAttributes>?
    /// ActivityKit calls are async but unstructured `Task`s carry no ordering guarantee — two rapid
    /// ±15s taps racing could land oldest-last and freeze the countdown on a stale end time. Every
    /// push chains on the previous one, so content always lands in issue order and `end` runs after
    /// any in-flight update.
    private var pushChain: Task<Void, Never>?

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
        let content = ActivityContent(state: state, staleDate: endsAt.addingTimeInterval(60))
        pushChain = Task { [pushChain] in
            await pushChain?.value
            await activity.update(content)
        }
    }

    /// End the rest Live Activity immediately (skip, next set, or workout finished). Chained after
    /// any in-flight update so a straggler push can't target an already-ended activity.
    func end() {
        guard let activity else { return }
        self.activity = nil
        pushChain = Task { [pushChain] in
            await pushChain?.value
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// End rest timers left over from a previous process (force-quit mid-session) — see
    /// `CardioActivityController.endOrphans`. Called once at launch; the orphan list is snapshotted
    /// synchronously so a late-running task can never sweep a legitimate new timer.
    static func endOrphans() {
        let orphans = Activity<RestActivityAttributes>.activities
        guard !orphans.isEmpty else { return }
        Task {
            for orphan in orphans {
                await orphan.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
