import ActivityKit
import Foundation

/// Drives the live-cardio Live Activity lifecycle from the app. Every call no-ops gracefully when
/// Live Activities are disabled or unavailable (e.g. a simulator without support), so recording
/// never depends on it. One cardio activity is live at a time.
///
/// The lock-screen clock ticks natively (`Text(timerInterval:)`), so we don't push per-second
/// updates — `update` is throttled to roughly every couple of seconds, except a pause/resume always
/// pushes immediately so the frozen/running state is never stale.
@MainActor
final class CardioActivityController {
    private var activity: Activity<CardioActivityAttributes>?
    private var lastPush = Date.distantPast
    private var lastPaused = false
    private var lastGPSLost = false
    private var lastStep: String?
    /// ActivityKit calls are async but unstructured `Task`s carry no ordering guarantee — two pushes
    /// racing could land oldest-last and freeze the card on stale numbers until the next throttle
    /// window. Every push chains on the previous one, so content always lands in issue order and
    /// `end` runs after any in-flight update.
    private var pushChain: Task<Void, Never>?
    /// Minimum spacing between throttled content pushes (distance/pace changes).
    private static let minInterval: TimeInterval = 2

    /// Begin the cardio Live Activity when recording arms (after the countdown).
    func start(title: String, symbol: String, state: CardioActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()   // never stack two
        let attributes = CardioActivityAttributes(title: title, symbol: symbol)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: Date().addingTimeInterval(180)))
            lastPush = Date()
            lastPaused = state.paused
            lastStep = state.stepText
        } catch {
            activity = nil   // request can fail (budget, disabled) — stay silent, the live screen still works
        }
    }

    /// Reflect the latest snapshot. Throttled, but a pause/resume, GPS lost/recovered, or structured
    /// step transition always pushes now — a state flip must never wait out the throttle.
    func update(_ state: CardioActivityAttributes.ContentState) {
        guard let activity else { return }
        let stateFlipped = state.paused != lastPaused || state.gpsLost != lastGPSLost || state.stepText != lastStep
        guard stateFlipped || Date().timeIntervalSince(lastPush) >= Self.minInterval else { return }
        lastPush = Date()
        lastPaused = state.paused
        lastGPSLost = state.gpsLost
        lastStep = state.stepText
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(180))
        pushChain = Task { [pushChain] in
            await pushChain?.value
            await activity.update(content)
        }
    }

    /// End the activity immediately (workout finished or cancelled). Chained after any in-flight
    /// update so a straggler push can't target an already-ended activity.
    func end() {
        guard let activity else { return }
        self.activity = nil
        pushChain = Task { [pushChain] in
            await pushChain?.value
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// End activities left over from a previous process. After a force-quit mid-run the lock-screen
    /// card would otherwise keep ticking its native clock with nothing recording behind it — and
    /// linger for hours. Called once at launch. The orphan list is snapshotted synchronously, before
    /// this process could possibly start a legitimate activity — so a deep-link launch that goes
    /// straight into a run can never have its fresh card swept by this task running late.
    static func endOrphans() {
        let orphans = Activity<CardioActivityAttributes>.activities
        guard !orphans.isEmpty else { return }
        Task {
            for orphan in orphans {
                await orphan.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
