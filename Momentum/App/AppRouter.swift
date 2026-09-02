import Foundation
import Observation

/// Cross-tab routing plumbing (docs/RECOVERY-HUB-PLAN.md §2, amended 2026-07-15).
///
/// The app shell is a `TabView` whose per-tab `NavigationStack`s have no path binding, so a runtime
/// "jump to another tab's screen" has no push mechanism — what it needs is a *value*. `AppRouter` is
/// that value: one instance lives in the environment (injected in `MomentumApp` alongside
/// `CoachPresenter` et al.), any surface may write a pending destination, and exactly one owner
/// consumes each field.
///
/// **Consume-then-nil contract** — each field is a one-shot mailbox, mirroring
/// `CoachPresenter.pendingNav`:
/// - A sender sets the field(s), e.g. Today's readiness line or the shell's `.viewHealth` coach-nav
///   branch sets `pendingTab = .progress` and `pendingProgressSegment = "Health"`.
/// - The owner observes it (`onChange` / `onAppear`), **first nils it out, then acts** — so the same
///   value can be requested again later and a stale request never re-fires on a later appearance.
/// - `RootView` owns `pendingTab`: on change, nil it and set its `selection`.
/// - `ProgressScreen` owns `pendingProgressSegment`: on appear/change, nil it and switch its segment.
///
/// Fields are independent on purpose: a same-tab caller (e.g. the AthletePanel rail inside Progress)
/// may set only the segment; a cross-tab caller sets both and each owner consumes its own half.
@MainActor
@Observable
final class AppRouter {
    /// Tab the shell should switch to. Owner: `RootView` (nils it, then sets `selection`).
    var pendingTab: AppTab?

    /// Segment `ProgressScreen` should land on, as the `ProgressScreen.Segment` raw value
    /// (display word, e.g. `"Health"` — matching `"Trends"`/`"History"`). A `String` rather than the
    /// enum keeps this file free of any compile-time dependency on `ProgressView.swift`; unknown
    /// strings are consumed and ignored, never crash. Owner: `ProgressScreen` (nils it, then
    /// switches its segment).
    var pendingProgressSegment: String?

    /// Social inbox deep links land on Profile's Community face, then open exactly one post or
    /// athlete. ProfileScreen switches faces; CommunityView consumes and clears these mailboxes.
    var pendingCommunityPostID: UUID?
    var pendingCommunityAthleteHandle: String?

    /// The live workout in flight (2026-08-19 shared-map pass). NOT a one-shot mailbox: this is
    /// presentation state — non-nil for the whole recording → save → celebration journey. Writers
    /// are Today's Start controls and the Plan tab's session sheet; the single owner is the ONE
    /// `WorkoutRunner` mounted over the whole tab shell in `RootView`, which nils it when the
    /// journey resolves. It used to be a per-tab `@State` feeding a `.fullScreenCover` — hoisting
    /// it here is what lets the recorder present as a crossfade overlay above the tab bar instead
    /// of a modal slide with its own presentation context.
    var workoutLaunch: TodayLaunch?

    /// The "Enjoying momentum?" soft-ask is on screen (`WorkoutRunner` owns the cover). Surfaced
    /// here so `RootView` can hold the award presenter: both fire after the same first save, and
    /// the award choreography used to play out invisibly UNDER the rating cover's dimmed backdrop —
    /// spent before the athlete could see it.
    var ratingPromptVisible = false
}
