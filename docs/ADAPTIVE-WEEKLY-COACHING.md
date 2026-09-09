# Adaptive weekly coaching

Implementation: 2026-09-09. The product hypothesis is that ongoing, useful coaching improves trial activation and retention. Screenshotting is a hypothesis, not an established explanation for cancellations.

## Experience

- The current week remains fully usable. Future coached weeks show phase, approximate mileage, running days and a long-run estimate instead of individual prescriptions. A phase roadmap remains visible.
- The current week's board leads the page. Future previews use a brief Train → Check in → Adapt transition, with Reduce Motion support. No future-week padlock or upgrade CTA is used.
- At a week boundary, a saved review explains the evidence, goal outlook and actual prescription changes. Opening that review reveals the finalized week.
- Coach Updates retains coaching notices and weekly reviews. Workout save screens collect optional recovery, pain, illness and ability-to-continue responses alongside the existing effort and notes fields.
- Existing users retain their current prescriptions and completed history. Self-coached plans remain under the athlete's control.
- Subscription prices, products, trial configuration and paywall presentation are unchanged. The PaywallController change only reports observed entitlement state for analytics.

## Implementation map

| Area | Main files |
| --- | --- |
| Weekly policy and safe minimum | `Momentum/Engines/AdaptiveTrainingWeek.swift`, `PlanEngine.swift`, `PlanCoaching.swift` |
| Transactional finalization and normalization | `Momentum/Persistence/AdaptivePlanService.swift`, `PlanService.swift` |
| Durable state and feedback | `Momentum/Models/AdaptivePlanRecord.swift`, `CoachMessageReceipt.swift` |
| Plan preview, review and roadmap | `Momentum/Features/Plan/AdaptiveWeekView.swift`, `PlanView.swift`, `SessionDetailSheet.swift` |
| Workout feedback | `Momentum/Features/Summary/WorkoutRecoveryFeedback.swift`, `CardioSaveView.swift`, `StrengthSaveView.swift`, `Momentum/Features/Timed/TimedSaveView.swift` |
| Shared entry points | `RootView.swift`, `TodayView.swift`, `CoachChatViewModel.swift`, `CoachInfoCards.swift`, `CoachWeekRecap.swift` |
| Messaging and notification preferences | `ToastCenter.swift`, `CoachSurface.swift`, `NotificationService.swift`, `NotificationPlanner.swift`, `NotificationPrefs.swift`, `NotificationsView.swift`, `SettingsView.swift`, `CoachMessageLifecycle.swift`, `WeeklyCoachCheckin.swift` |
| Migration and cloud continuity | `SchemaVersions.swift`, `PersistenceController.swift`, `AdaptivePlanSnapshot.swift`, `PlanCloudSnapshot.swift`, `PlanSyncService.swift`, `DataManager.swift` |
| Measurement | `Analytics.swift`, `Features/Paywall/PaywallController.swift`, `supabase/functions/revenuecat-openai-ads/retention.ts`, `supabase/migrations/20260909000001_adaptive_retention.sql` |

## Weekly decision rules

The existing deterministic macrocycle remains the framework and upper bound. Weekly finalization reduces or retains its prescription; a higher future framework week can proceed only when supported by recorded training. It never independently invents a training arc, moves the race date, or skips taper protection.

1. Store the plan's calendar-week configuration and timezone at initialization. Use its local week interval and stable week key thereafter, including DST boundaries. Travel does not create a second version of a week.
2. On app/Today/Plan activity, initialize existing plans without changing their current week. For a due week, obtain available Health recovery signals, then revalidate plan identity after suspension. An active workout defers preparation.
3. Read actual logged runs from the last week and up to four observed weeks of mileage. Preserve the original week's session IDs, dates and targets so moving or deleting a session does not erase its denominator. Preserve an attempted session's original target even if the run was too short to earn completion credit.
4. Check completion, shortening, moved days, actual mileage, effort/plan fit, easy-run overpacing combined with high effort, recovery answers, inability to continue, recent readiness/check-ins and illness/recovery holds. Missing measurements remain unknown.
5. Pain or illness holds prescribe rest and override the normal structural-change throttle. The athlete must explicitly report resolved symptoms before planned running can start again. This is not a diagnosis.
6. Otherwise, preserve a structural adjustment made in the previous seven days. This avoids compounding independent adaptation systems.
7. No recorded running means no increased mileage and easy-only work. Manual check-offs count as attendance; they are not recorded distance. With no completion evidence, the ceiling is half the previous prescribed running volume.
8. Supported weeks allow at most 5% above actual recent running, also bounded by the framework and a baseline capped at 1.3× the recent weekly average. Partial starting weeks do not earn an increase.
9. Incomplete, shortened, strained, excessive-volume or inactive weeks use an easier ceiling of 85% of that baseline. Lowering an interval workout clears its old repetitions; an unscaled interval script must never survive a reduced total.
10. Apply existing time-budget, injury and illness constraints. Never inflate a short dose to meet a display minimum. Every newly generated or changed standalone running session must total at least **1609.344 m**; smaller safe budgets become recovery walking, and zero budgets become rest. Short segments within a valid running workout remain allowed.
11. Save prescriptions, review, original-week baseline, week key and inbox notice in one transaction. Repeated openings do not re-finalize the same week. Failures roll back to the last valid plan and offer retry with a rest/gentle-mobility explanation.

Goal outlook uses the existing feasibility engine with observed volume and time remaining. It does not promise race readiness solely because workouts were checked off. Existing schedule/goal-edit services still own changes to availability, goal date and the macrocycle.

## Persistence and deployment

- SwiftData **V10** adds `AdaptivePlanRecord`, `WorkoutFeedbackRecord` and `CoachMessageReceipt`. Existing released model shapes are preserved; the migration is additive. No workout history or conversation reset is required.
- Cloud snapshots add optional adaptive state and feedback under the existing owner-only plan-sync transport. Old snapshots remain readable. Conflict resolution merges completed-training evidence and newest feedback from both devices, while retaining safety holds. Selected prescriptions and their weekly receipt travel together.
- Local account deletion clears the new sidecars. JSON export schema 3 includes adaptive baselines/reviews, recovery feedback and attempted workout targets, with workout UUIDs for linkage; plan cloud sync also includes this evidence.
- Applied migration **20260909000001** to Supabase project `hhhlrqngutmyccfpgdoq` and recorded it in migration history. `subscription_events` is private with RLS enabled; the `adaptive_trial_cohorts` view is service-role-only. Anon/authenticated roles cannot read or write this billing ledger.
- Deployed `revenuecat-openai-ads` **version 12**, ACTIVE. It writes minimal, idempotent RevenueCat billing events before existing ads-event filtering. It retains the webhook authentication check; a live unauthenticated request returned 401. Write failures return a retriable error instead of dropping billing events.
- A read-only check on September 9 found **1 received production trial-conversion renewal event**. This confirms a real webhook delivery, not a retention rate: collection has no historical trial-start backfill, and a linked, mature cohort is still needed for comparison.
- No new scheduled server job or weekly cron was created. The next week is finalized locally when the app runs. A local reminder invites the athlete back for review; it does not falsely claim a background adaptation already happened.
- No new App Store build, version increment, commit or push is included in this implementation task.

## Coach and notification rules

- All coaching producers share durable message receipts and one presentation path (`CoachMessageLifecycle`, `CoachSurface`, `ToastCenter`). Priority is recovery/safety (100/90), race briefing (85), adapted weekly review (80), other plan changes (60), records (50), weekly check-ins (40), ordinary chat notes (30), then refuel guidance (20). Priority is selected when the screen can actually present the message.
- The foreground allowance is spent only when the toast appears, never when it is generated or queued. Splash, save sheets, root covers and inactive app state hold presentation. Returning from background starts a new opening; persisted seen receipts prevent replay across launches. Lower-priority updates remain available in history.
- Toasts have a tap destination, visible dismiss control, swipe dismissal and a VoiceOver dismissal action. Coaching toasts remain for five seconds. Reduce Motion uses an opacity transition. Automatic timeout is not misreported as an explicit dismissal.
- Receipts track created, scheduled, actually displayed/delivered in the app, opened, explicitly dismissed and expired states. Toasts, visible inbox rows, visible Coach Updates rows and push taps use the same idempotent receipt writer. Reading an update never invokes prescription-normalization engines.
- Expired messages remain available as history but cannot become new interruptions. Week-specific and race-specific notes expire at their relevance boundary; ordinary decisions have a seven-day maximum. A newer note on the same topic supersedes its predecessor.
- Midweek notes run on days 3–4 of the plan's anchored calendar week and state actual completed/planned counts. Days 5–6 invite recovery feedback before the next week. Each kind is generated once per plan/week, and neither claims an unperformed change. Recovery holds and an unread weekly review take precedence. The adaptive weekly review replaces the legacy chat recap for that week.
- Background coaching pushes check authorization, preferences, expiry and quiet hours, then use one shared daily allowance. A failed OS scheduling request or receipt save does not spend it. A failed receipt save restores its previous timestamp and cancels the OS request, allowing a retry. Reading an update removes its matching pending/delivered notification. A push racing an app foreground transition joins the same in-app allowance instead of producing both a banner and a toast.
- Planned reminders expose only finalized/reviewed sessions and exclude missed sessions. Weekly reminders use the plan's next local week boundary at 09:00 and open Plan. Provisional session links resolve to the preview. Message routes are stored in the receipt as well as the legacy inbox route map.
- Quiet hours default to 22:00–06:00; equal endpoints disable them. Plan, coaching, first-run, streak, readiness and refuel notifications respect the window. Preference changes also withdraw already scheduled activity requests in the quiet window. Active rest timers and the promised billing reminder are explicit exceptions described in Settings.
- Refuel guidance now competes within the shared coaching allowance during its existing post-workout reminder window, rather than adding a separate toast and a fixed-delay push. Its own preference remains independent of the coaching toggle; a logged meal expires an unseen refuel hint. Recovery guidance has priority.
- The system records OS scheduling, not guaranteed lock-screen delivery. The coaching notification category requests OS dismissal callbacks, which record dismissal without navigating or counting an open. iOS does not guarantee a callback for every way a notification disappears.

## Measurement and interpretation

New/verified events cover roadmap/current/future views, scheduling/skipping/rescheduling, workout starts/completions, feedback submission, coach-message generation/display/open/dismissal, weekly review, next-week generation/reveal, adjustment views and generation failure. Local scheduling uses `push_notification_scheduled`, not a fabricated delivery event; push-open tracking remains in the existing router.

Events carry `plan_experience=adaptive_weekly_v1`, observed subscription state/environment, completion context and bounded week/reason properties where available. Review/preview events include the typed goal; submitted-feedback events include typed goal, workout type and completion status. A missing entitlement resets analytics to `none` rather than retaining an old paid label. Free-form health answers, workout notes and coach text are not sent in these events.

RevenueCat webhook renewals with an explicit trial-conversion flag are the source of paid conversion. Client entitlement observations are not proof of a paid renewal. The cohort view compares workout completers and non-completers, adapted-week exposure and second-week app sessions; it separates cancellation during a trial from conversion, since both can occur for one customer.

Operational interpretation:

- Use only production trial cohorts with `has_known_trial_window`, `has_known_transaction_chain` and `is_mature` all true. The latter includes a seven-day observation grace after trial end; missing transaction chains are explicitly ineligible, not non-conversions. Wait for webhook retries before calling a missing renewal a non-conversion.
- Alias linkage excludes ambiguous and unlinked customers rather than guessing identities. Report excluded counts alongside any conversion percentage.
- Billing collection begins at deployment. There is no historical RevenueCat backfill in this change; pre-release paid conversion needs separately verified billing history.
- Before/after analytics cohorts are observational, not a randomized test. Compare first-workout completion, review/reveal engagement and mature trial conversion; do not attribute a change to screenshot prevention alone.
- Analytics cannot prove where or why someone uninstalled, or guarantee observation of every force-quit. Notification permission denial and offline periods reduce observable data.

## Automated verification

- `AdaptiveTrainingWeekTests` covers progression/taper caps, pain overriding throttling, missing measured mileage, minimum-distance normalization, DST/week identity, rollout preservation/idempotence, feedback safety persistence and transaction rollback.
- `AdaptiveEvidenceTests` covers shortened-attempt provenance without false completion and quiet-window boundaries.
- `CoachDeliveryTests` exercises priority selection while a save sheet holds presentation, spending the allowance only on display, one message per opening, cross-context seen suppression, receipt route preservation, expiry/dismissal with retained history, reading a queued message elsewhere, and factual calendar-relative weekly notes.
- `AdaptiveCoachFlowUITests` launches the real app to verify the preview/roadmap, priority toast tap → current Plan, no second coaching toast in that opening, and swipe dismissal without navigation. The DEBUG fixture uses the production receipt/selection/routing path.
- Continuity tests exercise both cloud-conflict choices, preserving both devices' workouts and feedback. Existing schema tests migrate a genuine old-store fixture through V10.
- Existing checkpoint, weekly-shape, notification and coach-recap fixtures now assert the new contract. The one-mile checkpoint is exactly 1609.344 m. Walking alternatives are excluded from running-day counts and mileage balance. The pause/resume fixture uses explicitly safe spacing while retaining its exact date/count assertions.
- Coaching-loop unit verification: **2,341 tests across 260 suites passed** in 339.660 seconds after `build-for-testing`. Result bundle: `/tmp/momentum-coach-loop-unit.xcresult`; log: `/tmp/momentum-coach-loop-unit.log`; build: `/tmp/momentum-coach-loop-build5.log`.
- Final UI verification: **3 tests passed, 0 failures** in 33.994 seconds after the final routing fix and a fresh build. Result bundle: `/tmp/momentum-coach-loop-ui3.xcresult`; build: `/tmp/momentum-coach-loop-build6.log`. The tap test caught and now guards a real bug: `.plan` previously selected the tab without resetting a previously selected future week. It now explicitly selects the current week. No tests were disabled to make this pass.
- Deno: **8 tests passed**, including existing ads behavior and new billing parsing/idempotent event mapping.
- PGlite SQL integration: PASS for migration, alias linkage, actual trial conversion, sandbox isolation, cancellation semantics and role restrictions.
- `git diff --check` is part of the final check.

Reproduce the iOS run with an explicit simulator UDID and isolated DerivedData:

```sh
xcodegen generate
xcodebuild build-for-testing -project Momentum.xcodeproj -scheme Momentum -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath /tmp/momentum-adaptive-check
xcodebuild test-without-building -project Momentum.xcodeproj -scheme Momentum -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath /tmp/momentum-adaptive-check -skip-testing:MomentumUITests -resultBundlePath /tmp/momentum-adaptive-check.xcresult
deno test supabase/functions/revenuecat-openai-ads
node scripts/tests/adaptive_retention_sql.mjs /path/to/@electric-sql/pglite/dist/index.js
```

Never treat a wrong `-only-testing` identifier as green: Swift Testing can silently run zero tests. Inspect the actual suite/test count.

## Manual release QA

Verified on an iPhone simulator: current-week board hierarchy and the revised future-week preview layout, including aggregate mileage, running-day count, long-run estimate and absence of padlocks. Automated UI checks also verify roadmap expansion, priority toast routing to the current week, the one-message allowance and swipe dismissal without navigation. Additional simulator screenshots verified the preview in light/dark appearance and at `accessibility-large` text size: preview values and labels wrap without horizontal clipping, with the remaining content available by scrolling. The compact plan-header title intentionally truncates long names. Week numerals now scale with Dynamic Type, and long blocks page before labels collide. Original simulator appearance and text-size settings were restored.

Screenshots: `/tmp/momentum-coach-loop-preview-final.png`, `/tmp/momentum-coach-loop-dark.png`, `/tmp/momentum-coach-loop-large-text.png`. Successful UI-test attachments are in `/tmp/momentum-coach-loop-shots3/`. Physical-device frame-rate, VoiceOver navigation and OS notification delivery still require release QA.

Before shipping, perform the following interactive/device checks in addition to automated coverage:

1. Existing active plan: open Plan, confirm this week's dates/history survive, then select a future week and expand the roadmap. Check a direct future-session link and the coach briefing.
2. Fresh onboarding: verify the first-week reveal and weekly promise; ensure products and trial terms match the current release.
3. Save a run with optional feedback unanswered, then with difficult effort/poor recovery and with pain. Confirm save responsiveness, restored answers and the planned-start safety hold. Resolve symptoms explicitly and confirm prescribed rest remains intact.
4. Advance a test plan over its anchored week boundary: review actual counts and change explanations, reveal the week, relaunch repeatedly and verify one receipt/version. Repeat offline and with no completed workouts.
5. Shorten a planned run before completion, move a session across weeks and delete an uncompleted session; verify original targets still inform the review.
6. Exercise goal-date and schedule edits, a late workout, a return after multiple missed weeks, taper/race proximity, an empty/completed block and both cloud-conflict choices.
7. Test notification denial, quiet-hour edges, viewed-notice dedupe and actual deep links. Confirm a reminder invites review rather than asserting an unperformed adjustment.
8. Check light/dark appearances, larger Dynamic Type, VoiceOver and Reduce Motion on a physical device. Simulator screenshots do not establish frame-rate or accessibility completion.

## Deliberate limits

- The week is anchored to the calendar configuration at plan initialization, preserving the existing calendar-week product model rather than inventing a rolling seven-day start. Travel does not immediately re-anchor an active week.
- Late evidence is retained for subsequent decisions; an already finalized week is not silently regenerated. Symptom safety holds apply immediately.
- Pace and duration comparisons use preserved attempted-session targets, including runs too short to earn completion credit. Saved average HR is compared with the existing personalized HR zones for easy/recovery/long runs; only corroborating reported strain can make that HR signal influence the effort decision. Missing HR or wearable data never produces an invented physiological conclusion. Health remains signals-only; no historical workout import was added.
- Changes are conservative and deterministic. There is no new language-model dependency for numerical progression or weekly availability.
- Production conversion conclusions require real, mature post-deployment billing and app events. A successful deployment/authentication check is not a claim that a real renewal has already been observed.


## Full-prompt acceptance audit — September 9 follow-up

This is the acceptance trace for the original attachment, not a claim of mathematically bug-free software. The existing plan and safety engines are reused; there is no new AI numerical planner.

| # | Prompt contract | Implementation and verification |
| --- | --- | --- |
| 1 | Do not expose every future workout immediately | Shared `showsDetails` rule in Plan board, session sheet, coach context, Today, planned starts, watch handoff and reminders; preview UI test. Completed history and explicitly self-coached plans remain accessible. |
| 2 | Credible complete roadmap | Phase/week roadmap, goal date, current selection, phase focus and qualified readiness language; weekly review includes the existing feasibility verdict. Roadmap expansion UI test. |
| 3 | Full current week | Existing session details retain structure, pace/zones, duration, purpose, coaching, completion and scheduling. New weekly review precedes its reveal; UI test verifies reveal survives relaunch. |
| 4 | Valuable future previews | Dates, phase/focus, estimated total, running-day count, long-run estimate and learning status. No subscription lock or upgrade CTA. Light/dark/large-text screenshots and preview UI test. |
| 5 | Finalize from actual training/recovery | Original targets and schedule baseline, recorded distance/duration, pace, saved HR, effort, feedback, check-ins, readiness, inactivity and existing recovery engine. Evidence and weekly-engine fixtures. |
| 6 | Personalized weekly review | Actual attendance/recorded volume/time, observed struggles, adjustment rationale, phase-specific next focus and goal outlook. No invented training or fitness claims. |
| 7 | Explain changes | Saved before/after session descriptions, explicit reasons and decision evidence; expandable changes and persistent review. Transactions keep explanation and prescription together. |
| 8 | Contextual, nonrepetitive coaching | Durable shared receipt, priority selection after UI holds, one actual presentation per opening, expiry/supersession, explicit dismissal and history. Receipt/queue fixtures plus toast tap/swipe UI tests. |
| 9 | Relevant notification routes | Authorization, quiet hours, anchored week timezone, shared coaching daily allowance, stored route and viewed-message cancellation. Notification fixtures and production-path simulator banner test. |
| 10 | Persistent Coach Updates | Saved inbox messages and weekly reviews; unseen interruptions can expire without deleting history. Cross-context read/dismiss/expiry fixtures. |
| 11 | One-mile standalone running floor | Exactly 1609.344 m for newly generated or changed running prescriptions; safe smaller doses become walking/rest. Segment distances may be shorter. Existing rollout prescriptions/history are preserved deliberately. |
| 12 | Safe progression and goal arc | Existing macrocycle and taper are upper bounds; measured-load cap, conservative repeat/reduce/easy decisions and pain/illness rest. Existing feasibility, time-budget, injury, illness, pace-confirmation and plan-edit engines remain authoritative. |
| 13 | Preserve existing users | Additive SwiftData V10 sidecars, rollout preserves current week, completed history/conversations retained, backward-readable snapshots. Real old-store migration and continuity fixtures. |
| 14 | Idempotent finalization | Stable calendar week key, unique plan record, in-flight plan identity guard, transaction with rollback and matching cloud receipt/prescription. Duplicate/opening/failure/conflict fixtures. |
| 15 | Subscription terms unchanged | Paywall controller diff only observes entitlement state for measurement. No product, price, trial or paywall-presentation edit. |
| 16 | Activation/retention/conversion measurement | App events and adaptation exposure plus authenticated RevenueCat billing ledger and restricted cohort view. Production webhook receipt verified; SQL tests cover aliases, sandbox exclusion, cancellation, eligibility and access controls. Historical conversion backfill and sufficient mature cohorts are operational prerequisites to a valid before/after analysis. |

Additional hardening in this audit:

- Feedback answer removal now persists while preserving attempt provenance and the explicit safety hold. Unchanged edits do not advance the feedback timestamp and override newer cloud answers.
- Recovery menus now show their question labels and have full-row tap targets. The prior SwiftUI menu Pickers rendered only their selected values outside a Form; screenshot QA caught this.
- Review/retry buttons use an explicit contrasting label color. The inherited ink foreground previously made a dark button's text invisible; automated accessibility queries alone did not catch it.
- Review copy omits meaningless zero-count lines; goal outlook is a separate disclosure, with a visible next-week focus. Saved older reviews remain decodable.
- Actual review/preview visibility drives view events. Finished/empty blocks no longer offer an ineffective weekly-finalize action.
- Health-read suspension re-fetches the current profile and validates plan identity, cancellation and active-workout state before mutation.
- Trail runs count as running evidence, and invalid/NaN distance samples contribute no invented distance. Original planned duration now survives uncredited attempts and cloud sync. HR requires corroborating reported effort; it cannot independently assert readiness or justify increasing load.
- Background notification receipt failures restore retry eligibility; explicit OS coaching dismissals update the same receipt without opening the app destination.
- Backgrounding rechecks unseen coaching decisions held behind a save screen. A production-path UI test begins with a held foreground decision, backgrounds the app and opens its actual notification on the current Plan week.
- DEBUG store reset now clears the new sidecars, pending/delivered notifications and the coaching push allowance. The refuel fixture suppresses unrelated demo PR generation and retains the production expiry window; the production priority rules still allow a higher-priority PR to win the daily slot.
- The toast swipe test waits for its entrance frame to settle and re-queries the accessibility tree after dismissal. The failed recording showed XCTest swiping above the visible capsule using a moving frame, then retaining a stale snapshot. Its DEBUG-only fixture extends the automatic expiry to 60 seconds so slow accessibility queries cannot consume the five-second production dwell or pass the gesture test by natural expiry. The dismissal expectation remains five seconds, and production timing/animation is unchanged.
- Weekly reminder date components carry the anchored timezone, avoiding a different instant when the athlete's device timezone changes.
- Applied migration `20260909000002_adaptive_cohort_eligibility.sql` and recorded it in Supabase migration history. It appends explicit transaction-chain and cohort-maturity fields without changing billing collection or exposing the private view.

### Final follow-up verification

- Final `build-for-testing`: PASS, `/tmp/momentum-acceptance-build9.log`. Validation uses `/tmp/momentum-180-test-derived` and iPhone 17 Pro simulator `1DAC0CED-067B-437C-8127-9A19C63624D1` on iOS 26.2.
- Seven distinct UI flows have passing verification: six passed in `/tmp/momentum-acceptance-ui4.xcresult`; the remaining swipe-dismiss test passed **three consecutive iterations, zero failures** in 84.160 seconds in `/tmp/momentum-acceptance-dismiss2.xcresult`. The latter was rebuilt with the isolated dismissal fixture described above. The normal production dwell and other six flows are unchanged. The original failed run is retained rather than reported as a wholly green seven-test invocation.
- UI coverage includes future preview/roadmap, highest-priority toast routing/no second toast, manual swipe dismissal, one-time review/reveal after relaunch, feedback save/restore/clear and its immediate live safety hold, foreground-held coaching → actual background notification → current Plan, and actual refuel notification → Fuel.
- Final light-mode preview/review attachments: `/tmp/momentum-acceptance-shots4/333762CB-B311-4765-88F6-D47E914AB42B.png` and `/tmp/momentum-acceptance-shots4/CD97E1AF-15DB-44BC-932A-B8684D94E352.png`. The latter was visually inspected for button contrast and review layout. Earlier dark/large-text preview checks remain documented above; physical-device frame-rate and VoiceOver are not claimed as verified.
- Final-build dark-mode feedback screenshot: `/tmp/momentum-acceptance-feedback-dark.png`, visually verified after the unit run. All four question labels and selected values are readable, with full-row menus; simulator appearance was restored to light and the test app closed afterward.
- Deno follow-up: **8 passed, 0 failed**, `/tmp/momentum-acceptance-deno.log`.
- SQL follow-up: PASS with both retention migrations, including unknown transaction chains, cohort maturity and role restrictions: `node scripts/tests/adaptive_retention_sql.mjs /tmp/momentum-continuity/pglite/dist/index.js`.

- Final whole-unit regression: **2,347 tests in 260 suites passed, zero failures**, in 761.684 seconds after the final build. Result bundle: `/tmp/momentum-acceptance-unit-final.xcresult`; log: `/tmp/momentum-acceptance-unit-final.log`. The 128-scenario deterministic scheduling matrix completed in 404.133 seconds; it was not skipped or reduced. The adaptive-week, evidence, coaching-delivery, data-export and notification-planner suites all passed. Earlier counts elsewhere in this handoff describe earlier verification passes.
- Final `git diff --check`: PASS. Every adaptive-plan source/test file in the working repository matches the validated isolated source. The five summary/Sentry files listed in the concurrent-work note below are the only source/test differences and are outside this validation claim.


Concurrent work note: another task is editing workout-summary/Sentry code while this audit runs. Validation uses an isolated copy at `/tmp/momentum-weekly-validation`; those separate unfinished edits are not overwritten or represented as verified by this task.

The excluded concurrent files are `CardioSummaryView.swift`, `RunCharts.swift`, `StrengthSummaryView.swift`, `WorkoutWeekSnapshot.swift` and `WorkoutWeekSnapshotTests.swift`. No commit, push or App Store archive was performed by this audit.
