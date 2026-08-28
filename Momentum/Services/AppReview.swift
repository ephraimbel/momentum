import Foundation

/// Decides WHEN the app may open the rating flow — a styled "Enjoying momentum?" pre-prompt
/// (`RatingPromptView`) whose positive branch fires iOS's native App Store ask.
///
/// App Review guideline 5.6.3: never ask on first launch or during onboarding — only after the
/// athlete has *engaged*. The prompt used to be the last beat of onboarding, which is exactly what
/// got the app rejected. So the ask is gated on genuine core-loop use.
///
/// **Three chances, not one** (owner call 2026-08-28). Until then the latch fired on the ASK, so
/// tapping "Maybe later" once burned the app's only opportunity forever — and with two ratings on
/// the store, that was the wrong thing to spend. The ask now returns at the 1st, 5th and 15th
/// piece of logged work, in EITHER stream (a saved workout or a logged meal), and stops for good
/// the moment the athlete taps through to rate.
///
/// The ceiling is deliberate and it is Apple's own: `requestReview()` shows at most three times per
/// 365 days per app, and iOS decides whether to show anything at all. A fourth ask could not
/// produce a rating — only irritation — which is the nag pattern guideline 1.1.7 exists for. So the
/// cap is three, spaced by `minDaysBetweenAsks` so two milestones landing in one afternoon can't
/// stack two cards.
///
/// **We cannot know whether a review was actually written.** Apple exposes no callback, no receipt
/// and no query — `requestReview()` returns nothing, by design. Tapping "Rate momentum" is the
/// closest signal there is, and this engine treats it as terminal: `recordRated` latches and the
/// athlete is never asked again. (iOS backs this up on its own: it won't re-show the sheet to
/// someone who already rated the current version.)
///
/// This engine owns the counting, the spacing and the latches; the caller owns presenting the
/// pre-prompt and the actual `@Environment(\.requestReview)` call.
///
/// Pure with respect to the injected `UserDefaults` and clock, so every branch is unit-testable.
enum AppReview {

    /// The milestones, in order — the 1st, 5th and 15th logged item. A milestone is cleared by
    /// EITHER stream, so an athlete who only ever logs meals reaches the same three moments as one
    /// who only ever runs. Never more than one ask per milestone; `maxAsks` is `milestones.count`,
    /// which is what makes `asksMade` double as the index of the milestone being worked toward.
    static let milestones = [1, 5, 15]

    /// Apple's own ceiling for `requestReview()` (three per 365 days). Asking past it cannot
    /// produce a rating, so we don't.
    static var maxAsks: Int { milestones.count }

    /// Two milestones can land the same afternoon — a first meal logged an hour after a first run.
    /// The second waits.
    static let minDaysBetweenAsks = 3.0

    /// The first milestone, kept under its old name because it reads well at the call site and the
    /// tests speak in it.
    static var engagementThreshold: Int { milestones[0] }

    private static let savesKey = "com.momentum.review.workoutSaves.v1"
    private static let mealsKey = "com.momentum.review.mealLogs.v1"
    private static let askedKey = "com.momentum.review.asked.v1"        // legacy once-ever latch
    private static let asksKey = "com.momentum.review.asks.v2"
    private static let lastAskKey = "com.momentum.review.lastAsk.v2"
    private static let ratedKey = "com.momentum.review.rated.v2"

    /// Count one genuine save. Call this only when a workout is KEPT — never on discard (a review ask
    /// right after throwing a run away is a sour moment) and never on a HealthKit import (that isn't
    /// engagement with the app's own recording).
    static func recordWorkoutSaved(defaults: UserDefaults = .standard) {
        defaults.set(defaults.integer(forKey: savesKey) + 1, forKey: savesKey)
    }

    /// Count one logged meal — typed, scanned, dictated to Siri, or re-logged from a usual. All of
    /// them are the athlete using the app on purpose, which is the whole bar. Seeded demo meals
    /// never come through here (they're inserted straight into the store), and a deleted meal
    /// doesn't decrement: this counts the act of logging, not the rows that survived.
    static func recordMealLogged(defaults: UserDefaults = .standard) {
        defaults.set(defaults.integer(forKey: mealsKey) + 1, forKey: mealsKey)
    }

    /// The athlete tapped "Rate momentum" and we handed them to the App Store. Terminal: this is the
    /// closest thing to knowing they reviewed, and it stops every future ask.
    static func recordRated(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: ratedKey)
    }

    /// True when the athlete has cleared the next milestone, hasn't rated, is under the cap, and
    /// enough days have passed since the last card. Records the ask on the way out, so the caller
    /// can treat one `true` as one presentation.
    static func shouldRequestReview(defaults: UserDefaults = .standard, now: Date = .now) -> Bool {
        guard !defaults.bool(forKey: ratedKey) else { return false }
        let asks = asksMade(defaults: defaults)
        guard asks < maxAsks else { return false }
        if let last = defaults.object(forKey: lastAskKey) as? Date,
           now.timeIntervalSince(last) < minDaysBetweenAsks * 86_400 { return false }
        // `asks` indexes the milestone being worked toward: 0 → the 1st item, 1 → the 5th, 2 → the
        // 15th. Cleared by whichever stream gets there first, so nothing is missed when a milestone
        // arrives while the spacing rule is still holding the door.
        let target = milestones[asks]
        guard defaults.integer(forKey: savesKey) >= target
                || defaults.integer(forKey: mealsKey) >= target else { return false }
        defaults.set(asks + 1, forKey: asksKey)
        defaults.set(now, forKey: lastAskKey)
        return true
    }

    /// How many cards this install has shown, carrying the pre-2026-08-28 latch across.
    ///
    /// The old scheme stored a single `asked` bool that latched on the ask itself, so an install
    /// that hit "Maybe later" is indistinguishable from one that rated. It's counted as ONE ask
    /// spent, which is the generous-but-bounded reading: those athletes get the 5th and 15th
    /// milestones, and nobody gets more than three cards in total either way.
    private static func asksMade(defaults: UserDefaults) -> Int {
        if let stored = defaults.object(forKey: asksKey) as? Int { return stored }
        return defaults.bool(forKey: askedKey) ? 1 : 0
    }

    // `markAsked` lived here from 2026-07-26 to 2026-08-22, so the onboarding `.rateUs` beat could
    // latch the once-ever guard without passing the engagement gate (it asked before any workout
    // existed). That beat is gone and nothing else may bypass the gate: an ask that hasn't earned
    // its engagement is exactly the 5.6.3 problem. `shouldRequestReview` is the only door.

    #if DEBUG
    /// Test-only reset so fixtures start clean.
    static func reset(defaults: UserDefaults) {
        for key in [savesKey, mealsKey, askedKey, asksKey, lastAskKey, ratedKey] {
            defaults.removeObject(forKey: key)
        }
    }
    #endif
}
