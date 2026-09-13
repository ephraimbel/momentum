# Onboarding: a personal training introduction

Current implementation: activation_v2, September 12, 2026. This keeps the personal introduction and body inputs while replacing the mandatory
permission/account sequence. The owner restored the optional review ask after the reveal on September 11. Product rationale and rollout criteria:
[ONBOARDING-ACTIVATION-PLAN.md](ONBOARDING-ACTIVATION-PLAN.md).

## Experience arc

1. **Welcome.** Keep the photographic welcome, returning-account door, ink action, and existing
   gallery/handoff animation. Start with name and username so the experience can address the athlete personally.
2. **Goal and starting point.** Goal → running background → **your pace** → recent volume for
   established/returning runners → injury constraints. The pace page (September 12) is the one number
   the plan hangs on and every runner answers it: an easy pace they set themselves (never prefilled),
   a recent result entered inline, or how a run feels. The page opens on the way that fits their
   background and echoes the easy / steady / repeats paces the anchor implies as they set it. The
   background alone never seeds a pace. Race distance/date/time appears only for a race goal. Pace calibration
   never answers training background. Unknown recent volume remains unknown, producing the existing
   conservative starting prescription. The main page asks only about recent running, never how much
   the athlete is willing to build. Future progression belongs to the coach. Required personal details collect sex, age, height, and weight
   before generation. Empty measurements display “Add” and cannot silently become personal defaults.
3. **Schedule.** Training days and preferred weekdays share one page. A visible Session time row opens
   regular-session duration, optional weekly-distance limit, optional regular-run cap, and separate
   long-run cap in a native sheet. Existing mileage limits remain visible in the schedule summary.
   Default caps are described as coach choices, not as athlete answers. Supporting activities are
   optional on the goal page; selecting strength retains equipment, experience, split, and hybrid
   emphasis. The split lives in an optional Strength preferences sheet; Coach's pick remains the default.
   Muscle emphasis remains conditional on the goal.
4. **Approach.** The last question shows the deterministic feasibility assessment and an editable
   recommended intensity as one proposed plan. Adjust approach opens an optional sheet with all four
   tiers; selecting Podium still enforces its minimum days. No tier selection is required to proceed. The running-only path has seven core questions for beginners, eight for
   established runners; race and strength add only their relevant questions.
5. **Build and reveal.** Save the real plan immediately. No simulated analysis or timed checklist
   delays generation. The reveal (redesigned September 12) opens on the athlete, the road (the
   block's terrain, run by a runner glyph, hold-to-scrub afterwards) and the numbers; the opening
   schedule, honest starting-effort line, first week and the weeks ahead read below the fold. Keep the chart, complete first week,
   adaptive future-week explanation, premium materials, and local earned animation. The CTA is
   visible immediately and stays available while scrolling. No full-page overture blocks reading.
6. **Review → checkout → Today.** The reveal's Continue opens a dedicated review page. After its
   entrance, request Apple's native review sheet once while the app is active. Apple decides whether
   a sheet appears; there are no custom stars or rating-dependent branches. Continue is live immediately,
   cancels any pending ask, and opens personalized checkout (or Today for entitled athletes).
   Store prices, eligibility, subscription duration, Restore, entitlement verification, persisted hard
   gate, and bounded store-outage deferral remain. Purchase/Restore enters Today for guests and signed-in
   athletes alike. A relaunch after plan save cannot bypass the subscription gate.

## Contextual setup

Name, username, and body details are collected during onboarding (owner correction, September 11).
Profile appearance and later edits remain available in Profile/Settings. Legacy profiles with missing
identity remain supported; an empty handle must never accidentally claim a public identity. Health connection remains
in the existing recovery/settings surfaces and imports no workouts or history. Location is requested
when the athlete starts a GPS activity or invokes location-dependent map behavior.

Today uses the actual pending session, or explains a rest day and the next scheduled session. There
is no new takeover tutorial. A new athlete on a rest day may see one dismissible training-day reminder
option in the existing utility row; its tap owns notification permission. Injury context takes priority.

For legacy profiles, Fuel labels targets as estimates while body inputs are missing and offers body setup there. Missing
measurements remain nil. Saving a fueling goal cannot convert example measurements into personal data;
the athlete must explicitly confirm the body details first. Adding Fuel/profile details does not rebuild
completed workout history.

## Motion and visual character

Each page assembles a different part of the athlete's plan. A personal card with their name and
initials leads the introduction; a race bib leads the race question. The goal gallery sits below an
abstract running track that responds to the selected goal. Running-background choices carry their
own icons and selection feedback. The schedule's calendar is the actual weekday control, with
44-point tap targets and a two-row fallback on narrow screens. The final personal brief combines
the goal, approach, day count, and honest feasibility assessment, followed by a first-week → feedback
→ next-week-review explanation. Recent-running panels, protective rings, measurement confirmations,
equipment cards, and hybrid balance retain their individual compositions. Artwork responds to actual choices.
It does not invent GPS routes, training history, fitness charts, or preferred weekdays.

Scenes enter through finite staggered transforms, then respond to selection. The outgoing scene
captures its step by value so it cannot suddenly show the next page's artwork. Artwork has a fixed
composition and shrinks at accessibility sizes; the meaningful question and controls retain Dynamic
Type and accessibility labels. Shared typography, white paper materials, spacing, ink controls, and
restrained lavender keep the pages consistent.

Every scene does three things (motion pass, September 12): it assembles once, it answers each choice
with one acknowledgement tied to the question's meaning, and its single hero object breathes. The
goal page runs a lavender lap around its track for every goal picked and settles to a trace; the race
bib rolls its number, prints the athlete's name, stamps the date and sways on its pins; the recent-running
figures roll and push the arrow forward; each area to train around sends one protective ripple out
from the figure; each body detail stamps in and the figure follows the sex answer; the hybrid page is a
balance beam that tips toward the emphasis; the approach page's coaching loop lights week → feedback →
review once and rests on the first week; the day count and the Continue pill lift the moment they
change. Hover is a slow autoreversing drift on the illustration only, never on a control; there are no
timed delays before input and no fake processing. Decorative scenes do not intercept touches. Reduce
Motion shows settled illustrations, crossfades, and no hover or ripple.
The existing welcome animation and earned plan-reveal materials remain intact. Compact screens retain
scrolling and a pinned Continue button rather than shrinking readable controls to fit.

### Reference review — September 12

Reviewed publicly available onboarding screenshots from Mobbin's
[Headspace](https://mobbin.com/explore/flows/7cdc08c0-3bcb-4882-90dd-5cf92019616f),
[Revolut](https://mobbin.com/explore/flows/835f959d-7928-45a7-a4f7-fdec964e7270), and
[Ahead](https://mobbin.com/explore/flows/57e41d19-30db-4443-ab36-b19c8c20dfe4) sequences.
Headspace's changes in artwork scale informed the composition variety; Revolut's focused input
pages informed reducing repeated decoration; Ahead's illustrated choices informed making the
interaction itself carry visual feedback. These are design interpretations of still screenshots,
not claims about their animation timing or conversion results. No reference artwork, mascots,
match percentages, or social-proof claims were imported into Momentum.

## State and measurement

Historical step IDs stay stable. Drafts retain all answers, including whether the athlete explicitly chose a training approach, and map retired identity to Name,
activity/units pages to Goal, session details to Schedule, and permissions to Approach. Missing required
identity or body answers are collected on resume without losing training answers. Output drafts without a persisted
profile rebuild from preserved answers. Missing required goal/background/race inputs still need answers.
Generation remains an atomic SwiftData save/rollback and retry reuses a saved profile.

`onboarding_flow_version=activation_v2` is persisted at first install or entry into the new flow; old
installs are not silently relabeled by an app update. Events distinguish generation start/success/failure,
actual reveal entry, reveal continuation, step continuation, first entitled Today entry, and explicit
reminder choice. They contain coarse branches and elapsed milliseconds, not free-text or health answers.

Use `scripts/analysis/onboarding_activation.sql` for fully elapsed 24-hour install cohorts. It reports
production-observed, sandbox/mixed, and unknown coverage separately. Client purchase/entitlement events
are not proof of a paid renewal. RevenueCat's billing ledger and verified identity linkage remain the
source for trial conversion. Missing cancellation events do not establish zero churn.

## Verification

Use build-for-testing followed by test-without-building on an explicit simulator UDID. Run the full
MomentumTests target and relevant onboarding, guest-entry, accessibility, motion, and paywall UI suites.
Check actual executed test counts; a misspelled `-only-testing` identifier can run zero tests.

Keep overflow scrolling at large text sizes, pinned CTAs, state-preserving back navigation, Reduce Motion,
first-tap response, guest purchase/relaunch, Restore, and outage deferral covered. At accessibility
text sizes, personal-detail labels, units and controls stack to prevent horizontal page overflow.
Imperial height parsing uses bounded floating-point conversion so oversized pasted feet/inches
cannot overflow an integer before validation. Final evidence and any
external validation still needed are recorded in ONBOARDING-ACTIVATION-PLAN.md.
