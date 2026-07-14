import ActivityKit
import Foundation

/// Live Activity payload for a live cardio session — the lock-screen + Dynamic Island readout of a
/// run, ride, or walk so the athlete can glance at distance/time/pace with the phone locked (PRD
/// §23). Shared between the app (which starts/updates/ends it) and the `MomentumWidgets` extension
/// (which renders it), so this file is a member of BOTH targets.
struct CardioActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Anchor for the native, self-animating count-up clock (`Text(timerInterval:)`) — set to
        /// `now − elapsed` on each push, so the timer ticks on the lock screen between throttled
        /// updates without the app pushing every second.
        var timerStart: Date
        /// While paused (manual or GPS auto-pause) the native clock can't freeze, so we show this
        /// pre-formatted frozen elapsed instead.
        var paused: Bool
        /// Signal dropout (tunnel, urban canyon). The card flags it honestly instead of presenting
        /// frozen distance/pace as current — same contract as the in-app signal chip.
        var gpsLost: Bool
        var elapsedText: String
        /// Distance, pace/speed — pre-formatted by the app's `Formatters` so the widget needs no
        /// unit logic and the numbers match the live screen exactly.
        var distanceText: String
        var paceText: String
        var paceLabel: String
        /// Goal progress 0…1 when the session has a distance goal; nil otherwise.
        var goalFraction: Double?
        /// The guided step in progress ("Rep 3 of 6", "Tempo", …) for a structured run; nil on a
        /// free session. Pushed immediately on step transitions so the lock screen tracks the plan.
        var stepText: String?
        /// The route so far as interleaved x,y pairs normalized into the unit square (aspect-true,
        /// centered, y already screen-down) — the widget just scales and strokes. Downsampled and
        /// rounded app-side to stay far under the ActivityKit payload budget. nil until the trace
        /// has shape (2+ points).
        var route: [Double]?
    }

    /// The discipline being recorded — title ("Run") + SF Symbol, fixed for the session.
    var title: String
    var symbol: String
}
