# Plan creation and adjustment hardening

Implementation work in the September 7–8 side conversation. Existing work in the shared checkout was preserved. The later continuity implementation, additive backend deployment and verification are documented in [PLAN-CONTINUITY.md](PLAN-CONTINUITY.md); no commit or push was performed.

## Product contract

- Keep the animated plan reveal and existing checkout handoff. The payoff is not replaced with a review form.
- Ask name/username, goal, then recent training background. Detailed running and supporting-strength questions follow.
- A race result supplies performance evidence, not training experience. Selecting a distance cannot save a placeholder result.
- Unknown mileage remains unknown. Explain the reference window, permit a real mileage ceiling, and preserve chosen days across interrupted onboarding.
- The deterministic engine owns prescriptions. Model output integrity, save success, and coaching quality are separate checks; none implies that a forecast is guaranteed.

## Implemented

- Buffered benchmark entry with explicit save/cancel; strict clock parsing, including marathon `330` → `3:30:00`.
- Training background separate from speed, earlier in onboarding; lifting experience stays with equipment.
- No automatic 20/40 km mileage answers. Current volume and longest run refer to the last four weeks.
- A numerical mileage ceiling can equal or fall below current mileage. Coach choice is explicit.
- Ordered draft writes, preserved training-day choice, and answer recovery through building/reveal interruptions.
- Throwing plan creation; save failure retains answers and offers retry without a success event or reveal.
- Generated prescription checks before replacement: finite positive targets, valid dates within a week, sequential weeks, and valid strength counts. Invalid calibration is rejected before generation.
- Partial weekday preferences retained while filling remaining training days.
- New accounts do not treat pre-signup weeks as observed zero-mileage weeks. Stale sparse fallback only uses the last four weeks for weekly mileage.
- Three or more overdue sessions are retained as skipped history rather than added to the comeback week's training budget. The existing upcoming week is reduced once.
- V6 additive coaching-state table preserves historical schema checksums; an archived build-36 store and a V5-to-V6 reopen fixture gate migrations.
- Workout-identity confirmation for pace recalibration, evidence freshness checks, completed checkpoint bounds, and recalibration cooldown/evidence preservation across rebuilds.
- Pace easing modifies existing prescriptions, preserving week-specific progression and preventing accidental acceleration.
- Cross-session pace insights use recorded work reps, not interval sessions' whole-run averages. Moved sessions count in race-form projections.
- Road race predictions invert the benchmark seed without an additional marathon duration penalty. The Plan card explicitly calls this a current-fitness estimate.
- Shared pause placement for preview/apply/rebuild; race dates and occupied dates protected. Rebuilding during a pause re-creates provenance for the new session IDs. Resume only pulls back sessions still on their recorded paused dates.
- Undo save failure rolls back instead of reporting success. Goal/race rebuild failures no longer announce success.
- Automatic away-day edits preserve fixed events. Library entry says Add, matching its actual behavior.
- Direct Plan-page edits refresh notifications/watch/widget using the existing propagation service.

## Verification

- September 8 follow-up: completed-session evidence now survives either cloud conflict choice or restoration of an older plan. Device-reset intent survives relaunch, and interrupted deletion blocks sync until completed. Final follow-up build passed 363 unit tests and 6 UI tests; see [PLAN-CONTINUITY.md](PLAN-CONTINUITY.md) for artifacts and remaining release qualification.

New regression cases cover interrupted onboarding, resumed day choices, benchmark parsing and independent background selection, malformed prescriptions, partial weekday preferences, new-account volume, duplicate workout evidence, aborted checkpoints, comeback volume, pause/resume near races, pace easing, interval warmup exclusion, and road-result round trips.

Verification uses an isolated iPhone 17 Pro simulator on iOS 26.2 and isolated DerivedData, leaving the shared development simulators alone.

- `build-for-testing` passed, followed by `test-without-building` against that binary.
- Final unit run excluding `CommunityRouteRealismTests`: **2,228 tests / 246 suites passed**, including archived build-36 migration, V5 → V6 reopen with persisted coaching evidence, and paused rebuilds with new session IDs.
- Three focused onboarding UI tests passed: goal selection/back navigation in both motion modes; generation/reveal after backgrounding in both motion modes; training background independent of optional benchmark, including cancel, clear, and explicit save.
- Screenshots inspected for background selection, benchmark confirmation, and the reveal in both reduced-motion and settled animated states. A separate manual launch waited 12 seconds before capturing `reveal-settled.png`; the reveal finishes and exposes its checkout CTA.
- The unrestricted unit run is blocked by the unrelated community-route suite, which currently fails geometry assertions and crashes converting a non-finite value to an integer. Those files already have separate in-progress edits; they were not changed by this work.
- `git diff --check` passed.

Artifacts: `/tmp/momentum-plan-hardening/UnitTestsVerified.xcresult`, `OnboardingScreensVerified.xcresult`, `screenshots-verified/`, and `reveal-settled.png`.

## Completion pass

The follow-up addresses the engineering gaps above while preserving the animated reveal and checkout handoff.

- **Explicit availability:** usual session length stays simple; optional regular-run and long-run ceilings are stored in a V7 additive profile sidecar. Draft recovery and coach undo preserve them. Settings can change them later. Race events are exempt. Limits describe estimated time at the prescribed effort, not an elapsed-time guarantee in every condition.
- **One workout budget:** generation and live guidance share expansion and fitting. Distance accounts for timed recoveries; duration includes the prescribed warm-up, work, recovery and cooldown. Repeat sessions lose complete repeats when necessary, keeping recoveries intact. A full checkpoint that no longer fits loses its checkpoint label. Library distance-repeat recipes now include recovery distance; stride lead-ins reserve room for all timed strides and recoveries.
- **Limits persist through adaptation:** explicit availability is reapplied within the save transaction after a pace change or manual plan adjustment. Completed workouts and fixed race prescriptions stay protected.
- **Honest availability outlook:** the feasibility assessment compares explicit time ceilings with current-fitness preparation requirements. A constrained goal cannot retain a comfortable “on track” claim or a falsely precise improvement forecast. Onboarding, Settings, Manage Plan and the plan builder use those inputs.
- **Atomic coach/manual edits:** nested saves stage changes until one final commit. The plan, calibration evidence and coaching receipt share that boundary; notification routing and live coaching surfaces run after commit. An isolated undo manager restores already-observed SwiftData values before storage rollback. Existing pending workout edits are saved before the plan transaction starts. Failure injection verifies this separately from ordinary success tests.
- **Success feedback follows saving:** Plan-page moves, swaps, check-offs, self-coached changes and removals report success only after saving. Injury-report and return mutations use the same transaction boundary. Storage failures retain an actionable retry path.
- **Production validation:** the complete legacy invariant validator now gates generation before a saved plan is replaced. Tune-ups are validated against their own requested dates/distances; they are not mistaken for terminal races. Recovery-week comparisons exclude tune-up weeks from the loading baseline, matching the generator. Missing strength prescriptions fail validation; integration tests load the same exercise catalog as app startup.
- **Automatic reflow:** the coach cannot move a demanding session next to another demanding run or lower-body lift. If there is no suitable slot, the missed session remains history. Deliberate manual scheduling retains the existing recovery advice.
- **Real replacement:** Session Detail opens the library in replacement mode. The replacement retains the date and session identity and fits the original dose envelope. Fixed races, completed sessions, long-run roles and easy-day roles are protected. Preview and apply share the same fitted prescription.
- **Forecast provenance:** benchmark date is optional and explicitly saved with the result. The Plan card distinguishes an entered result, an unknown result date, logged calibration and a provisional profile estimate. It uses the plan's personal endurance exponent when available. Time passing alone does not improve the displayed current-fitness prediction.
- **Reveal refinement:** peak and race labels use collision-aware placement; the existing animation and Reduce Motion behavior are preserved.
- **Data lifecycle:** V7 preferences preserve the released profile/plan schemas and survive reopening. Both new sidecars are removed by account-data deletion and debug reset.

### Validation boundaries

Passing these checks establishes the tested engineering contracts. It does not certify every training prescription as clinically appropriate or guarantee race performance or retention.

- The prediction remains a deterministic model; terrain, weather, fueling and individual endurance limitations can change the actual result. Its evidence description is not a statistically calibrated confidence interval.
- The later continuity pass replaces the fixed illness pause with persistent rest and a gated gradual-return workflow. Its conservative product heuristics are not clinical clearance; see [PLAN-CONTINUITY.md](PLAN-CONTINUITY.md).
- Plan/profile/preferences/recovery and bounded training evidence now have a versioned continuity contract and deployed private backend. Full workout-history synchronization remains outside that scope; see [PLAN-CONTINUITY.md](PLAN-CONTINUITY.md) for verified behavior and release qualification.
- Expert review and longitudinal calibration across novice, returning, recreational, advanced and race-specific populations remain release qualification work. No finite fixture suite establishes “perfect for every runner.”

### Completion-pass verification

- The final engine build passed **2,238 tests in 251 suites**, including the 10,000 supported-request invariant sweep, optional budget matrix, failed-commit regression, replacement role/dose checks, V6 → V7 preference migration and archived build-36 upgrade.
- `CommunityRouteRealismTests` remains excluded from this plan-focused run for the previously documented unrelated failure. No claim is made that the excluded suite passed.
- The focused rollback/replacement run also executed all **3 tests**, independently confirming that the filter selected actual tests.
- Engine verification: `/tmp/momentum-plan-completion/Units-4.xcresult`; failure injection: `Rollback-2.xcresult`. The subsequent build changes reveal wording only and is used for final UI verification.
- The final UI build passed **4 onboarding UI tests**: goal/back navigation in both motion modes, generation/reveal after backgrounding in both modes, independent benchmark entry/save/cancel, and optional runner time limits. Results: `/tmp/momentum-plan-completion/Onboarding-1.xcresult`.
- Inspected exported screenshots for time-limit controls, benchmark confirmation, and reduced-motion reveal. A separate animated launch waited 12 seconds before capturing and inspecting `/tmp/momentum-plan-completion/reveal-settled.png`; the peak and marathon labels are separate and the checkout CTA is visible. Test screenshots are under `screenshots/` in the same artifact directory.
- `git diff --check` passed. No commit, push or deployment was performed.



## Reference principles

Runna documents separate running ability/current load and estimated race performance. Apple recommends concise, contextual onboarding. These inform the question structure, not numerical validation of Momentum's training policies.

- https://support.runna.com/en/articles/15231838-how-does-runna-build-your-training-plan-around-your-current-fitness
- https://support.runna.com/en/articles/6205998-adjusting-your-estimated-race-time-and-pace-targets
- https://developer.apple.com/design/human-interface-guidelines/onboarding

## Follow-up: pause/resume calendar safety

- Preserved the onboarding App Store review page, its native review request, and its position immediately after the animated reveal. No review-page or reveal source changes in this pass.
- Pause and early-resume placements now inspect the final proposed calendar, including fixed events, completed sessions and sessions that cannot move. A blocked move can block its neighbors; the calculation resolves that chain before persisting dates. It prevents newly introduced same-day collisions and newly compressed adjacent demanding days, including long runs and lower-body strength. Existing intentionally paired sessions retain their relative spacing when shifted together.
- Preview, affected-session counts, example dates and applied changes share the same resume calculation. Copy no longer promises every session will return to today.
- Early resume moves only still-open sessions whose date exactly matches the recorded pause shift. Skipped/completed work and independent manual date changes are left alone. Repeated pause requests cannot overwrite active pause provenance. Direct pause inputs are bounded to the supported 1–28 days.
- Calendar-day arithmetic preserves local scheduling across daylight saving transitions; per-day offsets are precomputed before conflict checks. No new persisted fields or schema version are required.
- Added `PauseCalendarSafetyTests` for fixed events, conflict cascades/order independence, simultaneous movement, preview/apply parity, early-return recovery, skipped/completed/manual dates, repeated/invalid pauses and both daylight saving transitions.
- Scope remains scheduling. The existing illness action is still a generic pause; neither elapsed pause days nor these tests establish medical readiness. Cloud sync was inspected and currently uploads workouts only; plan/profile cross-device restoration requires a complete sync contract, not an isolated preferences upload.

### Review opportunity bookkeeping

Inspection found that `recordOnboardingAsk` documented cooldown idempotence but incremented the counter on every call. Returning to the page could exhaust the app's own review opportunities before the fifth logged item. The existing cooldown now guards that debit and keeps the original timestamp. The page, placement, animation, Continue behavior and native request call are unchanged. A regression test revisits on the same day and the following two days, then verifies that the fifth-item opportunity remains available after the cooldown. This ledger tracks requests, not whether Apple displayed a sheet or whether anyone submitted a rating.

### Follow-up verification

- Build 2 passed **2,246 unit tests in 252 suites** in 286.062 seconds, including all eight new pause-calendar tests (with four invalid-input and two daylight-saving cases), existing coach/adjustment tests, onboarding ordering checks, migration tests and the 10,000-request invariant sweep. The previously documented unrelated `CommunityRouteRealismTests` exclusion remains.
- All **four `OnboardingReviewUITests` passed** on build 2. Exported and visually inspected the review page: `/tmp/momentum-pause-audit/review-screenshots/B0F0C05B-0C9A-4E4F-A84E-1508E67E58B0.png`.
- Results: `/tmp/momentum-pause-audit/Units.xcresult` and `Review.xcresult`. Build 3 includes only the subsequent review-counter guard and its regression test; its focused verification is recorded below.
- Final build 3 passed all **14 `AppReviewTests`**, including the new re-entry regression, and all **four `OnboardingReviewUITests`** with zero failures. Result: `/tmp/momentum-pause-audit/ReviewFinal.xcresult`. The broad 2,246-test run above precedes only this isolated ledger fix; it is not represented as a repeated full-suite run.
- `git diff --check` passed. Changes remain local; no commit, push or deployment was performed.

## Continuity follow-up — superseded status

The early continuity implementation status previously recorded here is superseded by [PLAN-CONTINUITY.md](PLAN-CONTINUITY.md). Its backend migration was deployed and verified, and subsequent builds passed the documented unit and simulator checks. Real-device and clinical qualification remain separate release gates.

## Runner-cohort and current-fitness follow-up — 2026-09-08

- The in-app builder now distinguishes **Not running (zero)** from **Not sure (unknown)**. Reporting zero weekly running also clears the old longest-run answer. Entering a positive longest run afterward clears the contradictory zero weekly answer.
- Explicit fitness edits carry their actual declaration date in draft JSON and a V9 scalar sidecar. A new answer on an established account is no longer treated as a months-old signup answer. It survives plan activation, ordinary rebuilds, undo, cloud restoration and reopening. Older drafts keep their legacy fallback semantics. Fresh declarations expire using the existing evidence window; selecting a plan does not refresh an old declaration's date.
- The generator treats explicit zero running as the existing starter structure, including its gentle progression, rather than selecting the experienced runner's default mileage. The opening week and base/recovery phases carry no generated quality session for an explicit-zero return; later build phases can introduce progression. Independently supplied pace calibration remains separate from training volume and experience.
- Main-thread generation, background fitness reads, settings and preview use one post-illness evidence rule. New mileage answers cannot bypass that recovery boundary. The logged longest-run read now uses the same trailing four weeks described by the question.
- The builder's mileage ceiling is a menu that permits values at and below the athlete's current volume. A scheduled preview assesses the runway from its scheduled start, not extra weeks before the plan begins.
- The builder explicitly explains that its underlying block remains subject to active illness/injury guidance; starting a plan is not recovery clearance. Its preview is not a prediction that an athlete will have recovered by a scheduled future date.
- V9 adds only `PlanFitnessDeclarationRecord`; earlier entity shapes stay unchanged. Account-data deletion and debug reset remove it. Cloud payloads and undo carry optional declaration provenance without changing the deployed backend schema.

### Cohort coverage

The 48-case matrix combines six runner profiles (first-time, returning at zero, recreational 20 km/week, consistent 40 km/week, experienced 65 km/week, and competitive 90 km/week), four road distances (5K, 10K, half, marathon), and unconstrained versus 30-minute regular/60-minute long-run limits with a weekly ceiling. Each fixture exercises the actual preview and persisted activation and checks their agreement, engine constraints, race placement and the applicable limits. These are test inputs, not recommended doses for every person in those categories.

Additional fixtures cover fresh zero versus unknown answers, higher-volume dose differentiation, conservative restarting, declaration expiry and deletion, worker/preview/rebuild recovery agreement, future scheduling, cloud/undo provenance and V8 → V9 reopening. Existing archived-build migration fixtures now target V9.

The first 48-scenario run passed; its schema-registry assertion required adding the new model to the expected inventory. The broader run then caught a real opening-week quality session for an explicit-zero return; that structure was corrected before final verification.

- Final build: `/tmp/momentum-continuity/cohort-build-7.log`.
- `/tmp/momentum-continuity/CohortsFinal-2.xcresult`: **790 unit tests across 78 suites plus 5 UI tests passed, zero failures or skips**. Includes the 48-case cohort matrix, 10,000 supported requests, dose differentiation, current-fitness/recovery agreement, cloud/undo persistence and archived-build/V8-to-V9 migrations. The 5 final UI tests cover the changed builder flow and all four review-page cases.
- `/tmp/momentum-continuity/CohortsFinal-1.xcresult`: all **20 UI tests passed** (10 onboarding, 4 review, 6 plan shelf/management). Its unit run preceded the opening-week fix and failed only the added regression that exposed it; it is not represented as a wholly passing result bundle.
- Final screenshots of the zero-running controls, smaller mileage options and updated preview wording were exported to `/tmp/momentum-continuity/cohort-final-ui-shots` and visually inspected. Training targets are no longer described as a weekly floor.
- `git diff --check` passed. No commit, push, App Store release or physical-device app replacement was performed. The isolated simulator `D3B1D3EA-B648-4CDF-8834-80C477DBD4BB` (Momentum Runner Cohorts) was removed after verification; shared simulators were left alone.

These fixtures establish the tested software behavior, not prospective prediction accuracy or clinical validation. Real-device acceptance, qualified review of injury/illness guidance, and longitudinal assessment of prediction error and training response remain release qualification work.

## Compact iPhone and enlarged-text onboarding — 2026-09-08

The follow-up used isolated iPhone SE (3rd generation, 375 × 667 points) and iPhone 17 Pro Max simulators on iOS 26.2. It reproduced a real compact-screen failure: the reminder page's `Maybe later` action could be below the screen without a scroll path. A direct enlarged-text screenshot also showed the review page extending beyond the viewport with its action unreachable.

- `OnboardingHeroPage` now gives Health, reminders, location and review content an independently scrolling area while keeping their actions within the available safe area. The standard layout retains its artwork and centered composition.
- Primary and secondary onboarding buttons use minimum heights and grow with their text instead of clipping enlarged labels into fixed-height controls.
- Final screenshot inspection caught a further accessibility issue that tap assertions did not: the five benchmark chips truncated their distance labels and the horizontal time row cropped the typed value. At accessibility text sizes the sheet now uses a native distance menu and a separate full-width time row, with increment/decrement below. Standard-size controls retain their layout. Screenshots verified full `Marathon`, `4:00:00` and typed `22:30` on the compact phone.
- The animated reveal, review page, native review request and permission sequencing remain in place. This pass changes presentation, not plan prescriptions or backend state.
- Five new UI tests cover profile entry with the software keyboard and back navigation at standard/enlarged sizes, scrolling dense questions, typing and saving a benchmark, permission action reachability, and welcome → generated reveal → review with enlarged text. Tests request the largest system accessibility text preference; these are not an assertion that all presentations inherit the root's text-size cap.
- The test scroll helper now moves targets into the visible area above the fixed Continue bar. XCUITest can report a partly covered target as hittable; large swipes can also overshoot a tall row. Those harness problems were separated from the actual non-scrolling permission/review defects. The enlarged-text review layout test suppresses the system sheet only to inspect the page; the existing native-request tests still run.

Verification:

- `native-onboarding-build-2.log`: build-for-testing succeeded. `NativeLarge-2.xcresult`: **19 UI tests passed, zero failures/skips**. `NativeCompact-2.xcresult`: **44 unit tests passed**; its UI run had one remaining test-scroll failure and is not a wholly passing bundle.
- `native-onboarding-build-3.log`: build-for-testing succeeded after a test-helper-only refinement. `NativeCompact-3.xcresult`: **11 UI tests passed, zero failures/skips**. The app implementation is unchanged between builds 2 and 3. Combined final device coverage is 30 successful UI executions, with overlapping cases across devices.
- The subsequent isolated benchmark accessibility fix was built with `native-onboarding-build-4.log`. `NativeBenchmark-4.xcresult` passed **44 unit tests plus both benchmark UI tests (standard and accessibility text), zero failures/skips**. The broader runs above precede only that isolated layout change; they were not rerun in full. Final benchmark screenshots are in `native-benchmark-final-shots`.
- Logs and result bundles are under `/tmp/momentum-continuity/`. Exported screenshots in `native-compact-after-shots`, `native-compact-final-shots`, and `native-large-after-shots` were inspected for the affected layouts.
- `git diff --check` passed. No commit, push, backend deployment, or physical-device app replacement was performed. The audit simulators were removed; the user's separate `Momentum Onboarding — Try It` simulator was left running with its existing app and data.

These checks exercise native SwiftUI/UIKit behavior in the simulator. They do not certify every iOS version, physical-device performance, VoiceOver navigation, or real permission/purchase services on hardware.
