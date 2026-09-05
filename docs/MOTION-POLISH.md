# Everyday motion and transition reliability

The existing design stays: map-first Today, date-badge Plan, native navigation, raised controls,
and earned-only iridescence. This pass changes response and lifecycle, not visual identity.

## Shared tuning points

- `Momentum/DesignSystem/Motion.swift`: everyday curves, shared `PressFeedback`, and the
  `ReducedMotionPreference` reader. Press down is 100 ms, release uses a heavily damped 240 ms
  spring response, selection 180 ms, panels a heavily damped 280 ms spring response, content
  reveals 220 ms, and crossfades 150 ms. Spring response is a tuning parameter, not a guaranteed
  wall-clock duration.
- `RaisedPressStyle` and `mapSafeTap` both use 0.98 pressed scale and a small opacity change.
  Reduce Motion removes scaling. The map still owns its existing high-priority tap workaround;
  `GestureState` releases feedback on cancellation without allocating timers during a drag.
- `SegmentedCapsule` animates its own selection, not the bound page's entire update transaction.
- `reveal` uses 8 points of travel and the content curve. Pass a stable `once` key for frequently
  revisited sections. A returning section starts visible on its first frame. Plan, Fuel, Profile
  highlights, and the existing Progress sections use this convention.
- Onboarding's pen/travel choreography and earned counters remain separate from everyday motion.

## Handoff rules

1. Record the user's destination before dismissing the current sheet.
2. Consume it once in `onDismiss`, clearing it before presenting the next sheet.
3. Ordinary cancellation must leave no pending destination.
4. Do not replace completion events with a guessed delay.

Applied to Plan's Add → Library, Today's check-in → injury/life sheets, and the blank workout
composer → manual form. Coach navigation waits for its root cover to dismiss; navigation from
notifications still works without a coach cover. Reopening or suspending the coach clears old
destinations. Workout finish keeps the recorder map mounted until the save crossfade completes,
with guards against a completion belonging to an old workout.

## Data and layout

- Plan week changes and completion writes no longer apply a whole-board animation transaction.
  Only the selection, heading, or checkmark animates. Row heights and scroll layout remain native.
- Workout media keeps its current image while the same workout refreshes. A different workout
  clears the old image; cancelled media tasks cannot publish stale results after an await.
- Persist capture data immediately. Never delay workout persistence to accommodate animation.
- Keep Apple's navigation and scroll physics; animate transforms, not layout constraints.

## Verification

Always build for testing before running tests without building. Use an explicit simulator/device
UDID. Do not run UI interactions or another performance suite on the same simulator concurrently.

- `MotionPresentationTests`: deferred coach routing, consume-once semantics, cancellation on
  reopen/suspension, notification routing, and non-consuming entrance reads.
- `MotionHandoffUITests`: Add → Library, check-in → Life happens, composer → manual form,
  repeated map-control toggles, and a cancelled press followed by a successful tap.
- `TodayDeckCollapseUITests`: one Start control after collapse/expand, including reduced motion.
- `PagesScrollPerfUITests` / `TodayScrollPerfUITests`: assert the expected surface exists, capture
  `XCTOSSignpostMetric.scrollingAndDecelerationMetric`, and verify responsiveness after scrolling.
  A missed navigation now fails rather than silently reporting a successful test.
  Setup cancels (never discards) an inherited recovery prompt and requires a full-page scroll
  surface, so a nested carousel or an alert's text cannot be mistaken for the page under test.
- `RunPauseUITests`: live recording remains responsive through pause/resume/finish. Both tests
  finish their synthetic workout instead of leaving a recovery prompt for the next launch.

Use a dedicated QA simulator for deep-link suites: an existing unfinished-workout alert can block
the requested sheet before the test has a chance to dismiss the alert. Preserve the athlete's
existing simulator store rather than clearing it to make a test pass.

The DEBUG-only `--ui-test-reduce-motion` argument exercises the shared motion reader and Today/Plan
branches without changing simulator-wide accessibility settings. It is not a replacement for
testing system Reduce Motion and VoiceOver on a phone, including other screens' native environment
readers. It has no override effect in Release builds.

Simulator timings are diagnostic, not an FPS certification. Establish stable device baselines in
Xcode's performance results, then use Instruments' SwiftUI and Hitches tracks on an optimized
device build to investigate regressions. Cover light/dark appearance, large text, cold/warm launch,
long workout histories, rapid navigation, keyboard presentation, and cancelled gestures. Profile
before changing blur/shadow rendering or adding rasterization; preserve the current materials.

### Validation record — 2026-09-04

- Build-for-testing succeeded. Concurrent onboarding edits were excluded from the isolated motion
  verification copy; they were not reverted or changed by this pass.
- Full unit target: Xcode reports 1,895 passed, one intentionally skipped tuning-grid diagnostic,
  and zero failures. All six new motion/presentation tests passed.
- Fresh iPhone 17 Pro / iOS 26.3.1 simulator: all 16 selected UI tests passed; six collected
  performance metrics. Checked Today and Plan in light and dark appearances by screenshot.
- This simulator reported clock and scrolling/deceleration durations, **not** FPS or hitch ratios.
  No before/after speedup or zero-hitch claim is implied. Physical-device profiling remains pending.
