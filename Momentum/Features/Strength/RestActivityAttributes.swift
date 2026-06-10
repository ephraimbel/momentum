import ActivityKit
import Foundation

/// Live Activity payload for the strength rest timer — the lock-screen + Dynamic Island countdown
/// (research: a glanceable rest timer is the in-workout moment that matters). Shared between the app
/// (which starts/updates/ends it) and the `MomentumWidgets` extension (which renders it), so this
/// file is a member of BOTH targets.
struct RestActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// The full rest window — drives the native, self-animating countdown (`Text(timerInterval:)`),
        /// so the timer ticks on the lock screen without the app pushing updates.
        var startedAt: Date
        var endsAt: Date
        /// Running completed-set count, for at-a-glance context.
        var setsDone: Int
    }

    /// The lift you're resting between.
    var exerciseName: String
}
