import Foundation

/// Decides WHEN the app may open the rating flow — a styled "Enjoying momentum?" pre-prompt
/// (`RatingPromptView`) whose positive branch fires iOS's native App Store ask.
///
/// App Review guideline 5.6.3: never ask on first launch or during onboarding — only after the
/// athlete has *engaged*. The prompt used to be the last beat of onboarding, which is exactly what
/// got the app rejected. So the ask is gated on genuine core-loop use: it fires only after the athlete
/// has SAVED (not discarded, not imported) a workout through the app, and only once, ever.
///
/// This engine owns the counting and the once-ever guard; the caller owns presenting the pre-prompt
/// and the actual `@Environment(\.requestReview)` call. iOS additionally rate-limits the native
/// prompt to a few times a year and may show nothing — that's expected. The latch fires on our
/// REQUEST, not on whether iOS honoured it, so we never nag.
///
/// Pure with respect to the injected `UserDefaults`, so every branch is unit-testable.
enum AppReview {

    /// Genuine in-app workout saves before the app is entitled to ask. One kept workout is real
    /// core-loop engagement — you cannot save a workout during onboarding or on first launch, so
    /// this clears the 5.6.3 bar — and it catches the goodwill peak while it's still warm.
    static let engagementThreshold = 1

    private static let savesKey = "com.momentum.review.workoutSaves.v1"
    private static let askedKey = "com.momentum.review.asked.v1"

    /// Count one genuine save. Call this only when a workout is KEPT — never on discard (a review ask
    /// right after throwing a run away is a sour moment) and never on a HealthKit import (that isn't
    /// engagement with the app's own recording).
    static func recordWorkoutSaved(defaults: UserDefaults = .standard) {
        defaults.set(defaults.integer(forKey: savesKey) + 1, forKey: savesKey)
    }

    /// True exactly once — the first time the athlete has saved `engagementThreshold` workouts and
    /// hasn't been asked before. Latches `asked` on that call, so a second call returns false even if
    /// iOS declined to actually show the prompt.
    static func shouldRequestReview(defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: askedKey) else { return false }
        guard defaults.integer(forKey: savesKey) >= engagementThreshold else { return false }
        defaults.set(true, forKey: askedKey)
        return true
    }

    // `markAsked` lived here from 2026-07-26 to 2026-08-22, so the onboarding `.rateUs` beat could
    // latch the once-ever guard without passing the engagement gate (it asked before any workout
    // existed). That beat is gone and nothing else may bypass the gate: an ask that hasn't earned
    // its engagement is exactly the 5.6.3 problem. `shouldRequestReview` is the only door.

    #if DEBUG
    /// Test-only reset so fixtures start clean.
    static func reset(defaults: UserDefaults) {
        defaults.removeObject(forKey: savesKey)
        defaults.removeObject(forKey: askedKey)
    }
    #endif
}
