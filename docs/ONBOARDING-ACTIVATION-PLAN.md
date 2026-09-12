# Shorter onboarding and a useful first session

Status: implemented and simulator-verified locally, September 11, 2026. Onboarding code not released. See the later September 11 pricing decision below.

Owner correction, September 11: retain name/username and require sex, age, height, and weight before
plan generation. Give questions distinct, choice-responsive native illustrations with consistent
materials and motion. This supersedes the original proposal to defer identity/body inputs. The
running-only path now has seven core questions for beginners and eight for established runners.

Implemented locally: branch-aware flow and draft migration; saved reveal → optional review ask → checkout → Today;
nonblocking reveal actions; contextual notification setup; safe legacy Fuel/profile handling; versioned
activation events, planned workout flags, and a read-only 24-hour cohort query. Current build and final simulator checks pass. The full unit run passed 2,363 tests in 263 suites;
a subsequent build passed 39 focused onboarding/draft/coaching tests, including the new missing-body
draft regression. See verification evidence below.

External verification remains separate: live RevenueCat webhook event subscriptions/backfill and a
physical-device StoreKit purchase have not been verified. The read-only live cohort query executes and
returns no activation_v2 cohort before release. Production cancellation/expiration coverage cannot be
inferred from missing ledger rows. The onboarding implementation itself changed no billing settings or production data; the subsequent
September 11 owner-authorized subscription change is documented separately below.

## Later review and motion correction — September 11

The owner explicitly restored the review page immediately after the reveal. Keep Apple's native ask,
one request per page presentation, and an immediately usable Continue. Backgrounding or leaving the
page cancels a pending request. Neither checkout nor entry depends on whether StoreKit displayed a sheet
or the athlete wrote a review. Track `reveal_continue` and `review_continue` at their actual taps.
Required identity/body inputs, contextual permissions, and checkout → Today remain unchanged.

Question illustrations now respond to the athlete's actual choices, including strength equipment,
muscle focus, returning-runner background, all four body details, day count, and training approach.
Use bounded transform/opacity animations, no repeating timers or decorative touch interception.
The welcome animation stays intact. This correction supersedes the earlier direct reveal-to-checkout proposal.

## Later pricing decision — September 11

After the onboarding work was verified, the owner separately authorized $39.99/year and a seven-day
trial, scheduled in App Store Connect for September 13 (earliest accepted price-change date). Monthly
stays $14.99 without a trial. The original fixed-price experiment below describes the earlier scope;
release analysis must record this pricing change and cannot attribute conversion changes to onboarding alone.

## Subsequent monthly pricing decision — September 11

The owner then authorized $9.99/month (no trial), replacing the $14.99 monthly target above.
It is scheduled for September 13 alongside the annual rollout. Annual remains $39.99 with a
seven-day introductory trial for eligible athletes. Local paywall defaults and billing-copy tests
use the new pair; production prices and eligibility continue to come from StoreKit via RevenueCat.
This is another pricing variable to record when evaluating onboarding conversion.

## Final annual pricing decision — September 11

The owner subsequently authorized $29.99/year with the same seven-day introductory trial,
keeping monthly at $9.99 without a trial. This replaces the earlier $39.99 annual price schedule
for September 13 on the existing annual product. The annual equivalent is $2.50/month;
localized billing terms and trial eligibility remain store-sourced. Record this final price pair
when measuring conversion; earlier prices in this document describe the decision history.

## Objective and evidence

Help new installs reach their personal plan, understand the subscription offer, and enter Today with one useful next action. Improve activation without weakening the deterministic plan engine or hiding payment terms.

The September 10 Supabase snapshot contains 49 recorded new installs on builds 44 and 46: 43 began onboarding, 35 generated a plan, 26 viewed a paywall, 10 attempted checkout, and 6 recorded a purchase/trial callback. Therefore 14 had not generated a plan: six before onboarding and eight during it. Nine generated a plan without an observed paywall; their last onboarding step was reveal. Generation is not proof that the reveal rendered successfully.

These are incomplete cohorts: 30 arrived on September 10; only 16 had 24 hours of follow-up. They establish investigation points, not causes or final conversion rates. Across first observed conversion events since September 1, 4 of 19 eligible installs completed a workout within 24 hours. A rest day or an externally recorded run must not be described as athlete failure.

Screen tracking is only two days old. Four production trial starts are in the new billing ledger, but the current billing-to-activity identity view links none of them. We cannot yet attribute subscription cancellation to a page or conclude that users screenshot plans and cancel.

## Product decision

Test a shorter path while keeping the current subscription price and trial duration unchanged. A pricing experiment comes afterward so its effect is not mixed with onboarding changes.

Proposed path:

Welcome → name/username → goal → current running → training constraints → body details → weekly schedule → optional supporting strength → actual plan generation → personal first-week reveal → optional review ask → checkout → Today.

Keep returning-user sign-in available. Account creation remains optional after purchase and must not become another mandatory gate.

This proposal changes the ordering prescribed in ONBOARDING-EXPERIENCE.md: permission previews move into the app, profile styling remains optional/later, identity/body inputs remain required, and supporting configuration is progressive. Preserve the existing welcome design and animation, typefaces, colors, and native interaction language. Once implemented, update that document to the shipped experience rather than leaving conflicting specifications.

## 1. Ask only what the initial plan needs

Use seven core question screens for a beginning running-only athlete, with conditional race and strength detail. This is a design target, not permission to drop required inputs or cram small text into one screen.

1. **Goal.** Start with what the user came for: first 5K, faster running, race preparation, or consistency. Preserve supported existing goals and draft migration. Ask race distance/date only when relevant; allow no fixed date. Target finish time stays optional and must not determine training experience.
2. **Current running.** Ask new / returning / regular experience independently from pace. Ask recent weekly volume and longest recent run for returning/established runners. An optional recent result can refine paces. Unknown baseline must remain unknown and produce a conservative start, not fabricated mileage or speed.
3. **Training constraints.** Keep the existing injury-history and feasibility protections before generation. Do not silently skip a restriction to reduce page count. Preserve the current constraint model; this project does not introduce medical diagnosis or invent a new clearance system.
4. **Weekly schedule.** Keep days, preferred weekdays, regular-session time limits, and a separate long-run limit where relevant. Combine related choices only when they remain clear on a compact iPhone with large text. Recommended values must be visible, editable, and never presented as answers the athlete supplied.
5. **Supporting activities, when wanted.** Present strength as an optional supporting choice. If enabled, retain experience/equipment/split and hybrid priority inputs that change the prescription. Preserve existing non-running branches; do not funnel every existing draft into running.

Before removing any field, trace its consumers in PlanService, PlanEngine, baseline/feasibility engines, HR zones and Fuel. Unknown body measurements must not become arbitrary defaults shown as personalized prescriptions. If a deferred field is needed for a specific output, ask at that feature or label/withhold that output appropriately.

Move these out of the mandatory interview:

- Profile styling: optional completion after entry. Name and username remain the opening question. Preserve legacy nameless profiles, avoid invented public handles, and retain profile validation and sync safeguards.
Required before generation: sex, age, height, and weight. Preserve supplied legacy answers and support older profiles with missing details; never fill missing measurements with silent personal defaults.
- Apple Health explanation/permission: keep the existing preview, offered contextually in Today/Progress for recovery signals. Connecting Health must still import no workouts or history.
- Notifications: request when the athlete chooses a session reminder or trial reminder. Do not prompt during an active workout or immediately after another system prompt.
- Location: request when route recording or location-dependent map behavior is invoked, with a usable default map before permission. Denial must not block seeing a plan or entering the app.
- Intensity preferences: default only to an explicit, conservative coach recommendation; retain feasibility output and allow editing. Do not silently increase training load.

## 2. Make generation and reveal a reliable handoff

Relevant files: OnboardingFlow.swift, BuildingPlanView.swift, PlanRevealView.swift, OnboardingViewModel.swift, OnboardingDraft.swift.

- Start real plan generation as soon as required answers are complete. Current build pacing waits through status lines before calling generation; remove artificial lead-in as a dependency of the work.
- Show status reflecting actual work. Do not add pretend analysis or a percentage that implies unmeasured progress.
- Preserve existing reveal visual design. Decorative animations must not block scrolling, reading, or the membership CTA once the saved plan is ready. Do not replay the reveal on background/foreground or a restored draft.
- Distinguish generation started, generation succeeded, reveal visible, and reveal continued in analytics. Measure generation duration separately from time the athlete spends reading.
- Ensure the first useful viewport contains the goal, next session, weekly schedule summary and a short reason the starting load fits the athlete. Keep the complete first week accessible; future weeks remain the truthful adaptive roadmap, with no invented locked-week framing.
- Provide a persistent Continue leading to the dedicated optional review page, then checkout (owner correction, September 11). The review page must never require a rating or delay Continue.
- Preserve atomic save/rollback, double-tap protection, retry, and draft resume. An interrupted generation must not create two profiles or duplicate plans. Do not clear recovery state until the corresponding persisted route can resume correctly.

## 3. Make the purchase-to-app transition immediate

Relevant files: PaywallController.swift, PaywallView.swift, PaywallComponents.swift, OnboardingPaywallFlow.swift and the root onboarding/account router.

- Keep live StoreKit/RevenueCat prices, trial duration, eligibility checks, renewal disclosure, Restore and cancellation/error handling.
- Keep current price and trial settings fixed for this experiment. No remote subscription change is part of implementation.
- On verified entitlement, enter Today without a mandatory profile, permissions, feature tour, or review interruption. Offer optional account/backup setup later without losing RevenueCat identity reconciliation.
- Maintain the existing persisted hard gate for users who have not purchased, plus its bounded genuine-store-failure recovery. Do not grant Pro based on an analytics callback.
- Test already-subscribed users, Restore, an abandoned Apple checkout, a delayed entitlement callback, returning users, offline relaunch and purchase followed immediately by force-quit.

## 4. Give Today one useful next action

Relevant files: TodayView.swift and shared plan/session navigation.

- Use the actual generated schedule. If a workout is due, show its title, duration or distance, one-line purpose and Start/View Session action. If today is rest, explain that briefly and show the next scheduled session.
- Do not auto-start GPS or push the athlete into an unsuitable workout just to raise an activation metric.
- Keep the map and current Today composition. Add no takeover tutorial or stack of checklist cards.
- Offer at most one optional setup prompt at a natural moment. Persist dismissal; do not repeat on every launch. Permission denial and incomplete profile details remain supported states.
- When the next session is scheduled for later, an athlete-selected reminder is a useful action. Measure it separately from actual workout completion.
- Preserve completed workouts and plan continuity when the user adds deferred information. Re-evaluate through existing bounded adaptation rules; do not rebuild completed history or silently replace the current plan.

## 5. Repair measurement before judging the result

Relevant files: Analytics.swift, AnalyticsSink.swift, onboarding screen tracking, revenuecat-openai-ads/retention.ts, and scripts/analysis/onboarding_activation.sql (read-only reporting; no migration needed).

- Add a persisted `onboarding_flow_version` and coarse goal/experience branch to relevant events. Preserve historical step IDs; keep current position/total accurate for the actual branch.
- Record step entry/continue, generation start/success/failure, reveal visible/continue, paywall view/attempt/outcome, first Today entry and first planned-session start/completion. Reuse existing events where their semantics match. Do not double-count retries.
- Capture duration and bounded error categories, never free-text health details, raw answers, routes, name, email or location.
- Keep diagnostics separate from foreground activity for retention. A background event or recovered session ending is not a user return or a crash diagnosis.
- Report known production, sandbox/test and unknown coverage separately. Do not silently call all unknown traffic production. Preserve DEBUG egress guards and deliberately marked test exclusions.
- Verify that the live RevenueCat webhook subscribes to cancellation, uncancellation, expiration, renewal and relevant billing states. Backfill available history through supported mechanisms separately from live ingest, keeping stable event IDs for idempotency.
- Investigate why anonymous billing identities do not resolve after login. Use verified RevenueCat aliases and authenticated identity links; never fuzzy-match by timestamps, name or email. Guests who cannot be safely linked remain explicitly unlinked rather than being forced to create an account.
- Keep billing records/reporting owner-only with RLS and server-side credentials. Do not add an anonymous endpoint that can claim someone else's subscriber identity.

Reporting contract:

- Primary: share of recorded new installs that reaches Today after verified entitlement within 24 hours; use only fully elapsed windows and report identity coverage.
- Diagnostic: onboarding start → actual reveal view → paywall → purchase attempt → verified entitlement → Today. Also report time to reveal and stalled/failed generation separately.
- Activation: completed workout within 24 hours, within seven days, and completion of the first scheduled session after its scheduled window. Publish each denominator; rest-day users must not count as missed scheduled workouts before their session is due.
- Business: mature production trial-to-paid conversion and net proceeds per acquired install, with refunds and incomplete billing history visible. Client paywall_convert is not verified paid conversion.
- Distinguish cancellation of renewal, subscription expiration, and inactivity. Last page is an association, not the reason someone canceled.

## 6. Rollout and success criteria

- Ship this as a versioned onboarding change in a reviewed app update. Do not try to remotely alter the existing hardcoded interview.
- Keep ad angles/traffic mix and pricing as stable as practical. Record material changes when they cannot stay stable.
- Default to a transparent release-cohort comparison; do not call it a causal A/B test. If a stable assignment mechanism is actually available, use sticky install assignment and label variants explicitly. Do not build a large experimentation platform for this one change.
- Preserve old drafts and completed users. Users already partway through setup resume at the closest valid step with their answers intact; do not bounce them through a new interview.
- First check: all key events arrive correctly and checkout/entitlement integrity holds. Then wait for fully elapsed 24-hour and seven-day windows and enough traffic per branch. The present 49-install sample is exploratory; no arbitrary sample count guarantees statistical significance.
- Winning direction: more installs reach the actual app, median time to the reveal falls, generation/purchase errors do not increase, and scheduled-session completion does not deteriorate. Validate paid conversion after trials mature before expanding acquisition spend.
- Stop or fix immediately for lost drafts, duplicate plans, inaccessible controls, incorrect billing text, broken Restore or blocked entitled users. Low Health permission acceptance by itself is not a rollback reason if people are activating successfully.

## 7. Verification and implementation order

1. Trace input dependencies and identity-link failure; define the versioned event contract and baseline queries.
2. Implement the shorter branching flow and migrate saved drafts; add deferred setup entry points.
3. Remove artificial blocking from generation/reveal and make checkout → Today continuous.
4. Add the first useful Today action and contextual permissions.
5. Verify instrumentation and billing joins in a controlled test environment; keep production tests explicitly identifiable and free of fabricated customer activity.
6. Run relevant deterministic fixtures, then the full Swift Testing scheme with build-for-testing followed by test-without-building. Check actual executed test counts; do not accept a zero-test `-only-testing` result.
7. Verify simulator flows on an explicit UDID and physical-device purchase/permission behavior where needed. Regenerate the Xcode project with XcodeGen if file membership changes; do not hand-edit the project.

Required coverage:

- New, returning, established, race-goal, no-race, running-only, hybrid and supported non-running branches; conservative unknown baseline and injury constraints.
- Schedule limits, preferred days, race feasibility, optional benchmark and all unit conversions.
- Old drafts at removed steps; backtracking from a race or hybrid choice; missing name/body metrics redirect to the appropriate question; stale answers cannot affect an abandoned branch.
- Denied/not-determined Health, location and notifications; no pre-value permission stack; no workout import.
- Generation error, repeated Continue, background/foreground, cold relaunch and saved-profile/draft consistency.
- Trial eligibility, actual seven-day/three-day metadata rendering, existing subscribers, Restore, failed/cancelled purchase and delayed entitlement.
- Compact display, accessibility text, VoiceOver, Reduce Motion, keyboard avoidance, visible CTA and responsive main thread.
- First Today view on a workout day and a rest day; reminder opt-in; deferred setup does not destroy plan continuity.

Use and extend existing OnboardingFlowTests, OnboardingDraftTests, BaselineEstimatorTests, PlanFeasibilityTests, PaywallTests, AnalyticsTests and AnalyticsSinkTests. Update OnboardingPaywallUITests, OnboardingLocationHandoffUITests, OnboardingPerfUITests and relevant motion/review routing tests for the intended new flow rather than weakening assertions to make them pass.

## Completion definition

The implementation is ready when a new athlete can supply the inputs genuinely needed for an appropriate first week, see the saved plan without avoidable waiting, complete or restore a purchase, and land in Today with a clear next session. Optional setup is available contextually, drafts and workouts are preserved, measurements distinguish behavior from billing, and the required checks have actual passing results. Improved conversion remains a hypothesis until release data supports it.

## Verification evidence — September 11

- Latest build-for-testing: `/tmp/momentum-personal-final-build.log` — succeeded.
- Full unit run: `/tmp/momentum-personal-unit.xcresult` — 2,363 tests in 263 suites, zero failures.
- After the final illustration refinements and additional draft regression:
  `/tmp/momentum-personal-unit-final.xcresult` — 39 tests in three suites, zero failures.
  These are OnboardingDraftTests, OnboardingFlowTests, and CoachInfoCardsTests. The Analytics tests
  are named AnalyticsEventTests, not their filename; their coverage is in the full target run.
- Initial UI run verified real welcome → name/body answers → saved reveal → mock purchase → Today →
  persisted relaunch, large text, Reduce Motion, scrolling, and hard-gate recovery. It was interrupted
  after rebuilding changed tests; its log is supporting evidence, not a completed green suite.
- A location test initially could not hit Start in a launch that allowed live billing.
  Its isolated recording launch now uses `--debug-pro` to keep billing hermetic while retaining
  real GPS authorization (unlike `--ui-test-route`, which bypasses GPS consent).
- Benchmark clear and welcome resume assertions failed during the initial concurrent run, then
  passed unchanged in substance in the final isolated checks; screenshots were added for diagnosis.
- UI destinations: iPhone 17 Pro / iOS 26.2 and iPhone 16e / iOS 26.3. Body details and schedule were
  also manually screenshot-checked on iPhone SE (3rd generation) / iOS 26.2.
- Final UI artifacts: `/tmp/momentum-personal-ui-final.xcresult` and
  `/tmp/momentum-personal-compact-ui.xcresult` — 10 and 3 tests respectively, zero failures.
  The final runs cover every core question’s controls, full-flow responsiveness, stored identity/body
  details across relaunch, optional strength/time limits, keyboard edits, welcome resume, and GPS consent.
- Physical-device purchases, live webhook subscription configuration, billing backfill, and actual
  conversion uplift remain unverified. This onboarding pass was local; the separately authorized
  pricing rollout is recorded above and in MONETIZATION-SETUP.md.

## Review and interactive motion verification — September 11

- Build-for-testing: `/tmp/momentum-review-motion-final-build.log` — succeeded.
- Unit result: `/tmp/momentum-review-motion-unit-final.xcresult` — 49 tests in five suites passed
  (OnboardingFlowTests, OnboardingDraftTests, AnalyticsEventTests, PaywallTests, TrialReminderPolicyTests).
- The backward-walk fixture now starts at Review, the actual final flow step. Checkout UI assertions
  verify the underlying review action is not hittable; its presence beneath a full-screen cover is valid.
  The first run exposed those outdated contracts, which were corrected rather than suppressing failures.
- The review CTA has no entrance opacity/offset. Revealing its page retires the outgoing plan layer
  immediately; only the review artwork animates. Continue cancels the pending native ask but remains
  reusable after an unexpected checkout dismissal; the flow deduplicates checkout and completion.
- Native-sheet presentation is controlled by StoreKit. Automated route tests suppress the system
  sheet with `--review-no-ask`; they do not prove that Apple will display it to every production user.
- Screenshots: `/tmp/momentum-review-restored.png`, `/tmp/momentum-approach-interactive.png`,
  `/tmp/momentum-equipment-dark-system.png`. Onboarding intentionally retains its light presentation
  even when the simulator's system appearance is dark. The user's Try It simulator was left untouched.
- Final UI result: `/tmp/momentum-review-motion-ui-final.xcresult` — eight tests passed, zero
  failures/skips: large-text welcome/reveal/review/checkout, contextual GPS consent, four hard-paywall
  cases, full-flow responsiveness, and review first-tap continuation in both motion modes.
- Seven additional distinct cases passed in `/tmp/momentum-review-motion-ui.xcresult`: the complete
  guest journey with persisted answers; goal/back navigation; equipment/approach stability; injury
  selection stability; full reveal scrolling with normal and reduced motion; and review → Today.
  That initial bundle also contains the two superseded fixture failures described above; it is not
  an all-green bundle. Across both runs, all 15 distinct UI cases have a passing result.

## Coach-led question design — September 11

The primary recent-running question now asks for current weekly distance and longest run only.
Unknown and zero recent running remain distinct answers. The coach determines future progression;
an athlete who needs a firm weekly ceiling can still set one under Schedule → Session time.
Existing draft ceilings survive and appear in the schedule summary until explicitly removed.

Goals use a six-card gallery. Each page assembles a distinct native illustration from actual inputs:
a personal plan card, destination, starting background, recent-running/next-weeks panels, protective
rings, measurement stamps, race bib, calendar, strength setup, hybrid balance, and plan brief.
The main approach screen proposes one recommendation; all four intensities remain available through
Adjust approach. Strength split is an optional preference, defaulting to the coach's choice.
Name, username, sex, age, height, weight, deterministic plan generation, review-after-reveal, and
checkout behavior remain part of the flow.

The compact injury screen reserves more room for the controls by shortening its decorative scene.
Its final action must fit above Continue without a scroll at standard text size. At larger sizes the
question content can scroll, while Continue stays pinned. Artwork uses fixed typography inside its
scaled decorative composition; accessible questions and controls retain Dynamic Type.

Validation uses `/tmp/momentum-coach-design-final-build.log` (build-for-testing succeeded).
The final test run executes 51 tests in OnboardingFlowTests, OnboardingDraftTests,
PlanFeasibilityTests, and BaselineEstimatorTests; all passed. The new draft regression verifies that
unknown recent volume cannot erase an explicit future limit or strength split on restore.
The initial UI run found the compact injury overlap and a UI-query timeout. It was stopped for the
layout correction and is not an all-green suite. Final UI evidence (completed September 12):

- `/tmp/momentum-coach-design-final-compact.xcresult`: four tests passed, zero failures/skips.
  Covers standard-size injury controls, large-text overflow, schedule backtracking and units,
  and the last controls on all ten primary/deep-linked question variations.
- `/tmp/momentum-coach-design-final-tests.xcresult`: all 51 unit tests passed. Four UI cases passed:
  goal/back navigation in both motion modes, recent-running/unknown inputs, full flow to checkout,
  and first-tap review continuation. Three optional-sheet test failures were diagnosed separately;
  this bundle is not an all-green UI run.
- `/tmp/momentum-coach-sheets-tests.xcresult`: all three remaining UI cases passed, zero failures/skips.
  The harness now operates the native strength picker wheel and scrolls the active sheet, rather
  than treating a picker as buttons or tapping controls below the visible viewport. It verifies
  strength/approach choices in both motion modes, regular/long-run limits, and weekly-limit
  persistence plus explicit removal. No application assertions were weakened.
- `/tmp/momentum-coach-sheets-build.log`: final build-for-testing succeeded; this last rebuild changed
  the test harness only. Across these completed runs, all 11 distinct focused UI cases passed.
- Real simulator screenshots were inspected for goal, identity, race, measurements, schedule,
  recent running, and approach. Final examples: `/tmp/momentum-coach-goal-final.png`,
  `/tmp/momentum-coach-volume-verified.png`, and `/tmp/momentum-coach-intensity-verified.png`.
  The owner's separate Try It simulator was left untouched; the QA simulator contains the new build.
- These checks establish tested simulator behavior, not a measured physical-device frame rate or
  a guaranteed conversion uplift. Release cohort measurement remains necessary.


## Mobbin reference pass — September 12, 2026

Reviewed public Headspace, Revolut, and Ahead onboarding screenshots on Mobbin; direct references
and interpretation limits are in ONBOARDING-EXPERIENCE.md. Applied composition variety, focused
input pages, and choice-driven illustration using original native SwiftUI components. No artwork
or fabricated social proof was imported, and no reference motion timings were claimed from stills.

- Name and race introduce their personal card/bib before the question. Goal uses an abstract
  running track with choice feedback. Background choices carry their own symbols and coaching line.
- Schedule combines actual training frequency and interactive preferred weekdays in one card.
  All weekday buttons keep 44-point targets; narrow layouts can use two rows. Compact inspection
  found an unnecessary wrap at 390 points, fixed by reducing inter-button spacing.
- Approach combines the actual goal, day count, intensity and feasibility into one personal brief.
  Weekly-cap shortfalls remain visible. A three-part coaching explanation introduces first week,
  feedback and next-week review. Existing optional adjustments and deterministic prescriptions remain.
- Entrances are finite; choice feedback is local. Continue stays pinned and the welcome animation
  is unchanged. No required pages or artificial generation delays were added.
- Accessibility testing caught an application bug: ignoring a Button's children created an outer
  accessibility element while leaving the inner weekday button named only by its initial. Removed
  that wrapper and labeled the weekday text explicitly; retained button selection traits. Tests
  continue to require full weekday names and persisted selected states.

Evidence collected in this pass:

- `/tmp/momentum-mobbin-tests.xcresult`: 51 unit tests across four suites and five UI tests passed,
  zero failures/skips. Covers flow/draft/feasibility/baseline logic, selections/back navigation in both
  motion modes, equipment/approach editing, profile entry, benchmark editing and reveal/review traversal.
- `/tmp/momentum-mobbin-compact.xcresult`: large-text dense questions and reachability across ten
  question variants passed. Both calendar cases exposed the accessibility bug above; this bundle
  is not all green.
- `/tmp/momentum-mobbin-accessibility.xcresult`: corrected weekday selection, units and sheet
  persistence passed on iPhone 16e; background/benchmark interactions also passed. The new large-text
  case reached the assessment sheet but queried its title as a navigation-bar title; the component
  renders a content heading. Corrected that query to the heading and retained the visible Done check.
- `/tmp/momentum-mobbin-accessibility-build.log` and `/tmp/momentum-mobbin-harness-build.log`:
  build-for-testing succeeded. The latter rebuild changed only the test query.
- Inspected actual compact screenshots of goal, background, name, race, schedule and approach,
  plus the large-text brief. The separate owner Try It simulator was not modified.
- `/tmp/momentum-mobbin-large-final.xcresult`: the full large-text calendar/personal-brief case
  passed with zero failures/skips, including selected-day persistence, assessment opening/dismissal,
  optional approach reachability and the pinned Continue action. All nine distinct focused UI cases
  in this pass now have passing results, alongside the 51 unit tests.
- These results establish tested simulator behavior; physical-device frame pacing and conversion
  impact still require device profiling and production cohort measurement.


## Final onboarding audit — September 12, 2026

Preserved the approved standard-size design and welcome animation. Audited navigation guards,
conditional questions, draft restore, generation/save/retry, purchase handoff and the measurement
inputs. This pass found and fixed:

1. Explicit approach selection was remembered only by the view's touched-step set and the last
   restored page. Selecting an approach, backing up and restarting could therefore apply a new
   recommendation. `intensityChosen` now persists in the draft; new/untouched answers still receive
   recommendations, and old drafts retain the existing at-or-past restoration behavior. Raising
   frequency to satisfy an explicitly selected approach also persists as a chosen day count.
2. On iPhone SE with accessibility XXXL text, the personal-detail rows forced the whole question
   wider than the viewport, clipping both content and navigation. Accessibility-size rows now stack
   labels, units and number controls, and the sex choices stack with content-driven heights.
   Standard-size composition is retained.
3. A two-part imperial-height paste could overflow Int when multiplying feet by 12. Parsing now
   uses finite Double values before the existing bounds; normal feet/inches and bare-inch input
   keep the same stored-centimeter conversion.

Initial evidence: `/tmp/momentum-onboarding-audit.xcresult` passed all 71 checks (62 unit tests and
nine UI cases), including guest creation/purchase/relaunch, review first-tap behavior, returning
runners, welcome drag stability, backgrounded generation and the persistent checkout gate.
`/tmp/momentum-onboarding-audit-fix.xcresult` passed all 67 checks (65 unit tests and two UI cases),
including three new choice-restoration regressions and the new explicit-approach backtracking UI
case. Both bundles have zero failures/skips. Final measurement/layout checks are recorded below.

`/tmp/momentum-onboarding-audit-final-ui.xcresult` passed the full guest-answer/purchase/relaunch
case and the ten-variant control-reachability case. `/tmp/momentum-onboarding-audit-se.xcresult`
passed goal/back navigation at both text sizes, oversized-height input followed by correction,
and required personal-detail completion at accessibility XXXL on iPhone SE. The benchmark keyboard
case failed at its final Save-button visibility check; this bundle is not all green. Its recording
confirmed the fixed-height action truncated the visible title to “Use this re…”. The button now
opts into content-driven height (`OversizedButton.expandsForText`); other call sites keep their
fixed-height default. No UI visibility assertions or test bounds were loosened.

Final verification: `/tmp/momentum-onboarding-audit-capture-build.log` records a successful
build-for-testing of the final app and test harness. The subsequent
`/tmp/momentum-onboarding-audit-benchmark-final.xcresult` passed the previously failing benchmark
keyboard/save case on iPhone SE at accessibility XXXL (one executed test, zero failures/skips).
Its `large-text-benchmark-save` screenshot was inspected: the complete action label wraps cleanly
inside the expanded pill. `/tmp/momentum-onboarding-audit-benchmark-normal.xcresult` also passed
the normal-size background/benchmark interaction on iPhone 17 Pro (one test, zero failures/skips).

Across the audit bundles, 65 relevant unit tests and 17 distinct UI cases have passing results;
these are focused runs, not a claim that the entire app suite ran in one bundle. The earlier SE
failure remains in its original evidence bundle and is resolved by the final rerun above.
Coverage includes required profile details, selection persistence, back navigation, keyboard
editing, small screens, maximum text size, both motion modes, generation/backgrounding,
reveal/review and the guest checkout handoff. Standard-size design and the welcome animation
remain unchanged. Real-device animation frame pacing and live StoreKit charging are outside
these simulator checks; purchase tests use the existing DEBUG seam.
