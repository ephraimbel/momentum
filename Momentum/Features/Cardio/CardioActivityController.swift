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
        } catch {
            activity = nil   // request can fail (budget, disabled) — stay silent, the live screen still works
        }
    }

    /// Reflect the latest snapshot. Throttled, but a pause/resume transition always pushes now.
    func update(_ state: CardioActivityAttributes.ContentState) {
        guard let activity else { return }
        let pauseChanged = state.paused != lastPaused
        guard pauseChanged || Date().timeIntervalSince(lastPush) >= Self.minInterval else { return }
        lastPush = Date()
        lastPaused = state.paused
        Task { await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(180))) }
    }

    /// End the activity immediately (workout finished or cancelled).
    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
