import Foundation

/// Decides WHEN the app may ask iOS to show the native App Store rating prompt.
///
/// App Review guideline 5.6.3: never ask on first launch or during onboarding — only after the
/// athlete has *engaged*. The prompt used to be the last beat of onboarding, which is exactly what
/// got the app rejected. So the ask is gated on genuine core-loop use: it fires only after the athlete
/// has SAVED (not discarded, not imported) some workouts through the app, and only once, ever.
///
/// This engine owns the counting and the once-ever guard; the caller owns the actual
/// `@Environment(\.requestReview)` call. iOS additionally rate-limits the prompt to a few times a
/// year and may show nothing — that's expected. `markRequested` fires regardless, so we never nag.
///
/// Pure with respect to the injected `UserDefaults`, so every branch is unit-testable.
enum AppReview {

    /// Genuine in-app workout saves before the app is entitled to ask. Three is clearly past
    /// first-launch and past onboarding — repeated use of the thing the app is for — without waiting
    /// so long the goodwill moment has passed.
    static let engagementThreshold = 3

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

    #if DEBUG
    /// Test-only reset so fixtures start clean.
    static func reset(defaults: UserDefaults) {
        defaults.removeObject(forKey: savesKey)
        defaults.removeObject(forKey: askedKey)
    }
    #endif
}
