# Plan lifecycle, plan creation, plan management, and photo food logging

> Working document for the 2026-09 upgrade. Owner brief: creating, previewing, scheduling and
> switching plans should feel complete; adjusting training should be discoverable in Plan; the
> athlete should be able to photograph food, review an estimate and save a meal; Fuel should read as
> a polished daily tracker connected to running. Runna's plan organisation and Cal AI's logging
> ease are the references for STRUCTURE, never for copy, assets or screens. Keep this file current
> as the stages land; it is the hand-off across context resets.

Baseline at the start of the work: branch `feat/route-suggestion` at `ff1574e` (build 43 of 1.7.5),
clean tree, `build-for-testing` green, **2,104 unit tests in 238 suites passing** on a throwaway
iPhone 17 Pro simulator (UDID `270A0742-E41B-451B-B7D0-415248F2E706`, iOS 26.2). Codex's Sentry and
storage-recovery hardening (`a66d85a`) is in place and is not touched by this work. The native
Mapbox/Meta hang investigation stays open and unverified; nothing here claims it solved.

---

## 1. Findings (capability inventory, verified in the checkout)

### 1.1 Plan lifecycle

**Already implemented and usable**
- One deterministic generator (`PlanEngine.generate`, pure) fed by `PlanInputs`, which
  `PlanService.planInputs(from:startDate:)` builds from the profile. Goals: race, endurance,
  stay consistent, general fitness, leaner, build muscle, stronger. The structural fork is
  `raceDate != nil` (season to race day) vs open-ended six-week rolling blocks with a checkpoint.
- Honest feasibility (`PlanFeasibility.assess` → onTrack / tight / tooShort / noRace with
  `options` when too short), recommended days, intensity tiers.
- Adjustment through one surface: `PlanSettingsSheet` (`.adjust` buffers edits and rebuilds only on
  structural change, `.create` starts a new season). Coach actions (`CoachActions`, 24 intents)
  with preview lines, one-step `CoachUndo`, and the `lastAdaptedAt` one-structural-change-a-week
  latch shared by every adapter. Board-level edits: drag to move or swap, away days
  (`PlanWeekEdit`), push or pull the week, add a session, workout library, self-coached mode.
- Recovery and injury loops (`RecoveryAdaptation`, `InjuryResponse`), race projections and
  briefings, post-race continuation (`PlanService.completeRace`) and block renewal
  (`PlanService.renewBlock`), block reports.
- Replacement discipline: every rebuild goes through `PlanService.transactReplacement` (autosave
  off, one save, rollback on throw), clones this week's completed sessions onto the new plan and
  re-points the workout links, then deletes the old plan. `RunningPlanBackfill.repair` asserts plan
  and session id uniqueness on every launch.

**Implemented but hard to discover**
- "Adjust this plan", "Start a new plan", "Plan it myself", away days and week shifts all live
  behind the small slider glyph in the Plan masthead. Coach chat holds the missed-week, pause,
  injury and ease flows. Nothing on the Plan tab is organised by intent.

**Partially implemented**
- `PlanStore.commit` (idempotent, snapshot-checked, self-coached-protected) exists and is fully
  tested but production never calls it. The running-domain season sidecars carry a
  `draft | active | complete | archived` status, but only for the season, never for a plan the
  athlete can see.

**Missing**
- Any notion of more than one plan. The current plan is exactly `UserProfile.plan` (to-one,
  cascade delete). There is no draft, upcoming, completed or incomplete plan; no preview before
  activation; no scheduling; no way back to a previous plan. There is no `@Query<TrainingPlan>`
  anywhere, which is what makes the design below safe.
- A creation flow for an existing user that does not re-enter everything: `PlanSettingsSheet`
  in `.create` mode is one long form with no preview and it activates immediately.

**Invariants and traps that shape the design**
- `TrainingPlan`, `PlannedSession`, `UserProfile` are released shapes frozen by
  `SchemaVersions.swift`; `RunningSchemaMigrationSpikeTests` opens an archived build-36 store to
  prove it. New per-plan data must be a scalar-keyed sidecar `@Model` under a new schema version
  with a lightweight stage (`PlanAthleteStateRecord` in V3 is the pattern). No property may be
  added to a released model.
- Completed sessions before the current calendar week are dropped from the plan on every rebuild
  (`PlanService.stagePersist`); the `Workout` rows are never touched. Workout history therefore
  survives any switch by construction; only the plan's own ledger of finished sessions moves.
- Plans are local only. `SyncService` pushes workouts, never plans; the Watch and widgets read the
  current plan through `PhoneWatchSync.push` and `WidgetBridge.publish`; notifications through
  `NotificationService.schedulePlannedReminders`. Plan Settings and the renewal card do not call
  those today and rely on the next Today bootstrap.
- `TodayView.bootstrapIfNeeded` (throttled, synchronous half) is the one place the app settles the
  plan against the calendar (`settleRaces`, `reconcileMissed`). It is the natural home for
  "an upcoming plan reached its start date".

### 1.2 Fuel and meal logging

**Already implemented and usable**
- `Meal` model with itemised `MealItem` blob, precise `nutritionData`, `source` tri-state
  (`pending | ai | manual`), `estimateAttempts` retry cap, health-score fields.
- The three-rung resolution ladder (history → staples → AI), dictation, barcode lane
  (`BarcodeScanView` → Open Food Facts → `BarcodeFood`), manual entry, daily totals, hydration,
  history with CSV export, `FuelGoalsSheet`, the nutrition report.
- `FuelEstimator` (text → `meal-estimate` Edge Function), `EstimateGate` (one bill per meal across
  the composer and Siri), `MealNutritionStore` (rollback on failed writes), attempt accounting that
  refunds calls that never left the device, a persisted 429 latch.
- Manual precedence is structural: `FuelEstimator.apply` refuses a manual meal, `Meal.isEstimable`
  refuses to fire for one, and `MealDetailSheet.save` flips to manual on any number change.
- Late-response safety: tasks are retained per meal id and cancelled on delete; the write is
  guarded on `!isDeleted && modelContext != nil` and on the gate token still owning the meal.
- Deterministic fueling: `FuelReadiness` (energy floor = 30 kcal/kg + the day's real burn, carbs by
  session tier, protein 1.4 g/kg, sodium and fluids floors), `FuelWeek`, `FuelTrends`,
  `HealthScore`, `PostWorkoutFuelCue`, `FuelTips`.

**Implemented but dormant**
- `Meal.photoData` (`@Attribute(.externalStorage)`) has been in every schema since V1 and is
  written nowhere. `CameraPicker` (system camera) and `ImageDownsampler.thumbnail` (ImageIO
  thumbnailing with an NSCache) exist for Social. `NSCameraUsageDescription` already names food.

**Missing**
- Any photo path: no capture entry in Fuel, no image field in the request, no vision content in
  either provider call, no server-side validation of the model's answer, no thumbnail rendering in
  the journal. The docs (`FUEL-FLOW.md`, the function header, `FuelEstimator`) record photo
  estimation as a deliberate 2026-07-16 removal. The owner's brief reopens it with explicit
  constraints (visibly approximate, quick correction, no confident non-food entries).
- Date navigation on the Fuel dashboard (today only; History is the only way back).
- Server-side response validation and structured logging in `meal-estimate`.

---

## 2. Product flows

### 2.1 Your plans (Plan tab → masthead menu → "Your plans"; also the empty state)
- **Current**: goal or race, dates, week N of M, sessions this week, progress bar. Actions: Manage
  plan, Preview.
- **Upcoming**: starts on a date; dates, duration, frequency; "Starts in N days". Actions: Edit,
  Preview, Move to drafts, Start now.
- **Drafts**: never auto-start. Actions: Edit, Preview, Schedule, Start now, Delete.
- **Previous** (completed, incomplete): what it was, when, how much was done. Actions: Preview,
  Start again (copies the blueprint into a new draft).
- The primary Plan screen stays the current training week. Your plans is one tap away and never a
  new tab.

### 2.2 Create a plan (Your plans → Create plan; empty state → Build my plan)
Goal → date/distance/time → fitness and experience → availability → preferences → feasibility and
preview → save draft / schedule / start now. Every step opens on the athlete's known values.
Preview is computed off the main actor from the same generator the activation will use, cancelled
on any input change, and never touches the current plan.

### 2.3 Manage plan (Plan masthead → "Manage plan")
Four intents: My schedule · My training · Something changed · My goal. Each action shows what was
asked, the affected dates, before/after, one explanation, the feasibility effect, Apply / Cancel and
Undo where the existing `CoachUndo` supports it. Actions reuse `CoachActions` and `PlanCoaching`.

### 2.4 Photo food logging (Fuel composer → camera glyph → Take a photo / Choose a photo)
Capture → durable local draft (`Meal` with `photoData`, `source = pending`) → estimate → itemised
result with steppers → confirm. Offline drafts retry on appear through the existing bounded cap.

### 2.5 Fuel dashboard
Date strip → energy → carbs / protein / fat → training context line → the composer (the
page's centrepiece: words, camera, barcode, mic) → meals with photos → recents. Floors never ceilings, no over-budget state, unlogged never reads as zero.

---

## 3. Technical approach

### 3.1 Plan lifecycle storage: one current `TrainingPlan`, everything else on the shelf
The invariant every engine and test already assumes, "exactly one `TrainingPlan` row, reachable
only through `profile.plan`", is kept. Non-current plans do not exist as `TrainingPlan` rows.

New sidecar `PlanShelfRecord` (SchemaV5, lightweight stage; scalar keys, no relationships):
`id`, `profileID`, `statusRaw` (`draft | upcoming | completed | incomplete`), `name`, `createdAt`,
`updatedAt`, `scheduledStart`, `startedAt`, `endedAt`, `blueprintData`, `previewData`,
`snapshotData`, `sourcePlanID`, `version`.

- **Blueprint** (`PlanBlueprint`, Codable value type): everything the generator reads that belongs
  to the plan rather than the athlete's body: name, goal, race distance/date/goal time, days,
  preferred weekdays, session minutes, equipment, intensity, weekly ceiling, hybrid priority,
  strength split, declared weekly volume and longest run, experience. `PlanBlueprint(profile:)`
  reads the profile; `apply(to:)` writes it; `inputs(for:startDate:)` produces `PlanInputs`
  without mutating anything (the same mapping as `PlanService.planInputs`).
- **Preview** (`PlanPreview`, pure): built from a `GeneratedPlan` + inputs + feasibility: weeks,
  dates, runs and lifts per week, typical week, weekly time, peak week, longest run, phases,
  outlook. Cached on the record as `previewData` for the cards; recomputed on edit.
- **Previous plans** carry `snapshotData` in the `CoachUndo.Snapshot.PlanState` format (existing,
  tested encoder) so a completed or incomplete plan can be reviewed read-only with its sessions and
  completed-workout ids; the `Workout` rows stay in History untouched.

### 3.2 Lifecycle rules (`PlanLifecycle`, pure, tested)
- At most one current plan: `profile.plan`. A draft never activates on its own; only
  `PlanLifecycleService.activate` changes `profile.plan`, and only the Today bootstrap and the Plan
  tab call `activateDueUpcoming`.
- An upcoming plan whose `scheduledStart` is today or earlier activates on the next settle. It
  starts TODAY (the plan opens with a run the athlete can do today), the current plan is retired as
  `completed` when its own end date has passed, else `incomplete`, and the record is deleted in the
  same transaction as the swap, so a second launch, a retry, or a second sweep finds nothing due.
  Two due at once: the earliest scheduled start wins, the others return to drafts with a notice.
- Overlap: scheduling or starting a plan while the current plan still has open weeks after the
  proposed start asks for a decision, showing the current plan's name, its end date, how many weeks
  and sessions would be cut, and whether the goal race is cut. Choices: replace from that date,
  start after the current plan ends (a computed date), or keep it as a draft. Nothing is discarded
  silently; the retired plan lands in Previous.
- Rebuilds that are adjustments (Adjust this plan, coach changeDays, injuries, renewals) never
  shelve a copy. Shelving happens at explicit switch, at race completion, and at block renewal.

### 3.3 Activation transaction (`PlanLifecycleService.activate`)
Autosave off → snapshot the current plan into a shelf record (status by end date) →
`blueprint.apply(to: profile)` → `PlanConfigurationCommand.legacyUICommand(startsNewSeason: true)`
→ `PlanService.stageRebuild(startDate: today)` → `configuration.apply` →
`RunningPlanBackfill.prepareAfterLegacyPlanMutation` → delete the activated record → one save,
rollback on throw. After the save: `schedulePlannedReminders`, `WidgetBridge.publish`,
`PhoneWatchSync.scheduleRefresh`, an inbox notice routed to the plan.

### 3.4 Photo food logging
- Client: `MealPhoto` (pure: downsample to ≤1280 px, JPEG ≈0.72, strip everything but pixels by
  re-encoding through CGImage; never copies EXIF), `FuelEstimator.estimate(text:imageJPEG:…)` adds
  an `image` field (`{ mime, base64 }`) to the same request; text-only requests are unchanged.
  Capture entry in the composer (camera glyph → menu: Take a photo / Choose a photo), the draft row
  shows the thumbnail through `ImageDownsampler.thumbnail` (cached, never full resolution in the
  list), the detail sheet shows the photo above the items.
- Idempotency and late responses: the meal row is created once and every retry re-estimates that
  row (no second insert); `EstimateGate` tokens and the `isDeleted` guards already stop a late
  response from touching a deleted meal. A non-food or empty answer sets the meal to a plain
  "couldn't read this as a meal" line with the cap exhausted, so it never renders as confident
  nutrition and never re-bills on every visit.
- Retention: the photo lives only in the meal's external-storage blob; deleting the meal deletes
  the photo. Nothing is uploaded to Storage; the image rides the request body and is not logged.
- Portion basis (vision pass, 2026-09-07): every item carries `grams`, the weight the estimate
  assumed (ml for a drink); the client keeps it as `MealItem.gramsG`, shows "≈160 g" on the
  detail sheet's numbers line and scales it with the steppers; `alcohol_g` rides for the
  server's energy identity only. Both optional, so the deployed text-only shape still decodes.
- Server: `meal-estimate` accepts an optional `image` (validated: JPEG/PNG/WEBP, ≤ 4 MB decoded
  base64, ownership by the authenticated caller through the existing rate-limit RPC key), passes it
  as a vision content part to Gemini (`inline_data`) or Claude (`image` block), and now VALIDATES
  the model's answer server-side: item count ≤ 40, finite non-negative numbers within bounds,
  unknown micros preserved as null, `not_food` reason when nothing edible was recognised. Logging
  is structured, counts and provider only, never text or image bytes.

### 3.5 Fuel dashboard
`FuelView` grows a compact date strip (today ± history) and a redesigned top: energy hero with the
floor, three macro rings (carbs / protein / fat), the training context line, the composer as the
one entry point (its own glyphs route to the camera menu, the barcode scanner, dictation and
send; manual entry stays beneath it), meals with thumbnails, and recents. `FuelReadiness` is
unchanged; the readout for a past day is the same engine run over that day's meals and workouts.

---

## 4. Staged checklist

### Stage 1 — Plan home and lifecycle (landed)
- [x] Audit and this document.
- [x] `PlanShelfRecord` (SchemaV5 + lightweight stage), registry test, reset-store and wipe paths.
- [x] `PlanBlueprint`, `PlanPreview`, `PlanLifecycle` (pure) + `PlanLifecycleTests` (20 tests).
- [x] `PlanLifecycleService` (shelf CRUD, schedule/unschedule, activate, activateDueUpcoming,
      retire on race completion and renewal) + SwiftData tests.
- [x] Today bootstrap and Plan tab call `activateDueUpcoming`; activation propagates to
      reminders, the widget, the wrist and the inbox.
- [x] `YourPlansView` with cards and actions; masthead menu entry "Your plans"; empty-state entry.
- [x] Overlap decision sheet (`PlanOverlapSheet`) and the schedule picker (`PlanScheduleSheet`).
- [x] `--seed-plan-shelf`, `--plan-your-plans` recipes.

### Stage 2 — Plan creation and preview (landed)
- [x] `PlanBuilderFlow` (goal → target → where you are → your week → how to train → preview →
      start now / schedule / save draft). Four doors the engine tells apart: race (dated),
      get faster at a distance (rolling blocks shaped for it, checkpoint), start or return
      (stay consistent, gentle), build running fitness (general or farther and faster).
- [x] `PlanReviewView` + `PlanPreviewContent` (outlook, commitment, typical week, phases).
- [x] Debounced (350 ms), token-cancelled preview generation in a task; the preview is the real
      generator run on the blueprint. It runs on the main actor over already-fetched rows
      (engine work of milliseconds); a `@ModelActor` worker was not worth a second context.
- [x] Draft and upcoming edits reopen the builder on the record's blueprint. `--plan-builder`.

### Stage 3 — Manage plan (landed)
- [x] `ManagePlanView` (My schedule · My training · Something changed · My goal), backed by
      `PlanAdjustmentService` over `CoachActions` and `PlanCoaching`; `PlanAdjustmentServiceTests` (7).
- [x] `PlanProposalSheet`: request, what it touches, before/after (computed from the same
      generator), why, race outlook change, Apply / Cancel; receipt with Undo (`CoachUndo`).
- [x] Stale proposals recomputed on Apply (plan signature); throttles explained before the tap.
- [x] Downstream refresh through `schedulePlannedReminders`, `WidgetBridge`, `PhoneWatchSync`.
- [x] `--plan-manage` recipe.

### Stage 4 — Photo food logging (client and server code landed; vision verified live through a canary)
- [x] `MealPhoto` (downsample to 1280 px, re-encode with no metadata, ≤ 2.5 MB) + `MealPhotoTests`.
- [x] `FuelEstimator` image request (`image { mime, base64 }`, omitted when absent), `rejected`
      outcome, `outcome(for:)`, `rejectionLine` + `FuelEstimatorTests`.
- [x] Composer camera glyph (Take a photo / Choose a photo), camera-denied fallback, journal row
      and history thumbnails through `MealPhotoView`, detail-sheet photo, photo-only titles.
- [x] `meal-estimate`: optional image, `validate.ts` request and response validation (bounded
      items and numbers, unknown micros null, `not_food` / `unreadable`, energy reconciled to the
      macros, grams and kcal snapped, photo items largest first), structured logs with counts,
      timings and token usage only; `validate_test.ts` (17 Deno tests pass). NOT deployed to
      `meal-estimate` itself (see §6).
- [x] Vision pass (2026-09-07): weigh-then-compute prompt with per-100 g anchors and a photo
      protocol (inventory, size from in-frame references, hidden fat, labels, words outrank
      pixels, confidence rubric); model PINNED to `gemini-3.8-flash`, fixed `seed`, thinking
      "low", `MEDIA_RESOLUTION_HIGH`; one shared deadline for primary and fallback (15 s photo);
      the Claude fallback only runs when `ANTHROPIC_API_KEY` exists (it does not today); Gemini's
      own error line is logged on a refusal. `scripts/meal_bench.ts` measures repeatability and
      cost against any deployed copy.
- [x] Retry idempotency (one row, re-estimated), delete-then-late-response guards, manual
      precedence are exercised by the existing gate and by `FuelEstimatorTests`.
- [x] Live verification through a temporary canary copy (`meal-estimate-canary`, deleted after):
      14 photos × 3 identical requests — 9 byte-identical, kcal spread ≤ 2.5% elsewhere (one busy
      fry-up 5%), Big Mac 590 kcal vs 563 on the label, a Zero Sugar can read from its label,
      blank wall → `not_food` and blurred plate → `unreadable` 3/3, words-plus-photo cases
      ("two of these", "half of this, no cheese", "plus a flat white") exact; median 2.7 s, p90
      5 s, ≈ $0.004 per photo at 3.8 Flash pricing. Found and fixed live: Gemini 3.8 refuses a
      response schema carrying `maxItems` (bare 400), and `temperature` is deprecated on Gemini 3.
- [ ] Deploy `meal-estimate` itself (owner's call; §6), then one real photo through the app.

### Stage 5 — Fuel dashboard (landed)
- [x] Day strip (thirty days back, the name jumps to today); the whole page is judged for the
      selected day by the same engine (`dayNow` is the last minute of a past day, so its pacing
      reads as final); logging from the page lands on that day; History holds older days.
- [x] Energy hero shows "—" with no meals (unlogged is never "ate nothing"); three macro rings
      (carbs · protein · fat); sodium joined fluids on the quiet floors line; the readout strip
      keeps the training context ("FOR tomorrow's long session"); the composer stays the one
      entry point (owner call: no separate Add food pill) and its glyphs route to the camera
      menu, the barcode scanner, dictation and send, with Add nutrition beneath it; journal rows
      with photo thumbnails; recents chips unchanged.
- [x] Empty-day card for today and for past days, no over-budget state anywhere.
- [ ] Light and dark screenshots on the simulator (below).

### Validation
- [x] `xcodegen generate`, `build-for-testing`, `test-without-building` on the whole
      `MomentumTests` target (UI tests skipped by target, never by suite id): **2,176 tests in
      243 suites, 0 failures** after the hardening pass (baseline 2,104 in 238 +
      `PlanLifecycleTests` 33, `PlanAdjustmentServiceTests` 18, `FuelPhotoJournalTests` 9,
      `MealPhotoTests` 4, `FuelEstimatorTests` 8). `deno test supabase/functions/meal-estimate`:
      17 passing (the validator is co-owned by a parallel session; its grams/alcohol/energy
      reconciliation work is included).
- [x] UI: `PlanShelfUITests` (shelf, builder draft surviving a relaunch, Manage apply + undo) and
      `FuelPhotoLaneUITests` (photo rows + the composer's camera door through `--fuel-photo-demo`,
      the day strip) on a clean simulator, beside `FuelFlowUITests`, `NutritionTrackingUITests`,
      `AddSessionSheetUITests`, `BarcodeScanUITests`, `PlanFlowsUITests`. Known red outside this
      scope: `PlanFlowsUITests.testDraggingASessionOntoAnotherDayMovesIt` looks for the old
      "Rest — two days out" copy, which the block-checkpoint commit (77f30d2) changed.
- [x] Screenshots on the shots simulator (`8561E2EB-F589-4F7C-B803-8FE694912FD7`): Your plans
      populated, the builder's first step and its preview, Manage plan, Fuel populated with photo
      meals and empty, light and dark. Files under the session scratchpad `shots/`.
- [x] Healthy cold launch and `--storage-unavailable` recovery screen unchanged.
- [ ] Not run this session: the `MomentumUITests` target (it needs a clean, uncontended
      simulator and is known to carry container-contamination failures; see memory notes).

---

## 5. Decisions and outstanding dependencies

- **Shelf, not multiple `TrainingPlan` rows** (see 3.1). Reversible later through the same
  blueprint format if a real multi-plan store is ever wanted.
- **Upcoming plans start today when they come due**, never backdated; the notice says which day
  they were scheduled for.
- **Photo estimation is reopened** by the owner's brief; the "never estimate from images" lines in
  `FUEL-FLOW.md`, the function header and `FuelEstimator` are amended to describe the new contract
  rather than deleted from history.
- **Meals stay local**; no Storage bucket, no meal table. Photos never leave the device except
  inside the estimate request body.
- **Deployment**: `meal-estimate` changes are prepared, tested locally, verified live through a
  canary copy, and NOT deployed to the production name. Exact commands are in §6. Vision runs
  on `GEMINI_API_KEY` (set); `ANTHROPIC_API_KEY` is NOT set on the project, so the Claude
  fallback is dormant and the function logs `fallback: false` when Gemini fails.
- **Real-device checks still owed**: camera capture on a physical iPhone (the simulator has no
  camera; the library path is what the simulator exercises), Watch refresh after activation.

## 6. Deployment, real-device checks, limitations

**Edge Function (prepared, verified on a canary, NOT deployed).** From the repo root, once the
owner authorises:
```bash
deno test supabase/functions/meal-estimate
(cd supabase/functions/meal-estimate && deno check index.ts)
supabase functions deploy meal-estimate --project-ref hhhlrqngutmyccfpgdoq
```
No new secrets: `GEMINI_API_KEY` is set (the model is pinned in code to `gemini-3.8-flash`;
`MEAL_MODEL` overrides it, e.g. `gemini-3.5-flash-lite` for half the cost). The bench-only
secrets (`MEAL_DEBUG`, `MEAL_IMAGE_DAILY_LIMIT`, `MEAL_SEED`, `MEAL_MEDIA_RESOLUTION`) were unset
after the canary run so the code defaults apply. After deploy, verify with a real photo through
the app and read the function log for `{"fn":"meal-estimate","outcome":"ok","hasImage":true,
"model":"gemini-3.8-flash","usage":{...},...}`. To re-run the bench against the live function:
`MEAL_BENCH_URL=<url>/functions/v1/meal-estimate MEAL_BENCH_TOKEN=<anon key> deno run
--allow-net --allow-read --allow-env --allow-write scripts/meal_bench.ts --dir <photos> --runs 3`
(a guest address is capped at 30 photos a day). The Anthropic SDK pin moved to `^0.124`, which
knows `output_config`, so `deno check` is clean.

**Schema.** V4 → V5 is a lightweight stage adding one sidecar table; existing stores migrate on
first launch with no data rewrite. `RunningSchemaMigrationSpikeTests` opens the archived build-36
store through V5.

**Real-device checks still owed.** Camera capture on a physical iPhone (the simulator has no
camera; the library path is what the simulator exercises); the Watch receiving a plan switch
(`PhoneWatchSync.scheduleRefresh` is called, the paired-device push is not exercisable here);
notification resync after an activation on device.

**Limitations, plainly.**
- Photo recognition was verified live through a canary, not through the app on a device, and
  `meal-estimate` itself is not yet deployed. Estimates from a photo are shown with the same "≈"
  treatment as text; confidence follows the prompt's rubric (0.3–0.85, label-read products
  highest). Portion weight remains the dominant error in every published study of this method;
  the words-with-photo path ("two of these", "half") is the correction that works, and a
  "fix with words" re-estimate on an already resolved photo meal is not built.
- Previous plans are snapshots (sessions and completed-workout ids), not live relationships; the
  review is read-only by design. Tune-up races do not carry into a shelved blueprint.
- The plan preview runs the engine on the main actor after a debounce (milliseconds per run).
- Manage plan's "My goal" rows open the existing complete Plan Settings form rather than a new
  race flow; the builder covers new plans.
- The composer's placeholder was shortened to make room for the camera glyph.

## 8. Planning gate (owner brief of 2026-09-07, applied)

This section turns the brief into a repository-grounded plan and records where each part now
stands. **Verified** means read in the checkout or proven by a test that ran this session;
**Assumed** means a judgment this plan rests on that the code cannot prove.

### 8.1 Lifecycle decisions, resolved

| Question | Decision | Where | Status |
|---|---|---|---|
| What makes a plan current / upcoming / draft / historical | Current = the one `TrainingPlan` row reached through `UserProfile.plan`. Everything else is a `PlanShelfRecord` whose `status` is `draft` (never starts on its own), `upcoming` (has a `scheduledStart`), `completed` (retired after its own end date or its race) or `incomplete` (retired early). | `PlanLifecycle.swift`, `PlanShelfRecord.swift` | Verified (`PlanLifecycleTests`) |
| The scheduled start passes while the app is closed | Nothing runs in the background. On the next launch or return to the tab, `activateDueUpcoming` (Today bootstrap after `settleRaces`; Plan tab on appear and on scene-active) activates the earliest due record. It starts **today** (tomorrow after the evening cut-off in `PlanService.firstPlanStart`), never backdated; the inbox notice names the day it was scheduled for. Two due at once: the earliest wins, the others return to drafts with a notice. The record is deleted inside the activation save, so a retry or a second sweep finds nothing due. | `PlanLifecycleService.activateDueUpcoming`, `TodayView`, `PlanView` | Verified |
| Activating mid-week | The rebuild anchors on the activation day: `PlanService.stageRebuild(startDate:)` builds weekday-anchored weeks with an opening run on day 0 that is never a day the athlete ruled out. The replaced plan's completed sessions of the current week are cloned onto the new plan and their workout links re-pointed (`transactReplacement`). | `PlanService.swift`, `PlanLifecycleService.activate` | Verified |
| Completed workouts and the original prescriptions | `Workout` rows are never touched by any plan change (History keeps them). The retired plan's sessions, targets, statuses and completed-workout ids are frozen in the record's `snapshotData` (`CoachUndo.Snapshot.PlanState`), so Previous plans review what was prescribed and what was done. | `PlanLifecycleService.retire`, `YourPlansView` (Preview) | Verified |
| Multi-device edits or activation | **Plans do not sync.** `SyncService` pushes workouts only; there is no plan or shelf table. A plan lives on the device that built it; a second device runs its own onboarding plan. This is the smallest complete implementation for a solo-first v1 and is recorded as a limitation, not hidden. | `Services/SyncService.swift` | Verified (no plan sync exists) |
| Sync fails after a local change | Only workouts have a sync leg, and it is a batched sweep that retries on the next run. A plan or meal change has no remote copy to fail against; the local store is the source of truth and is saved in one transaction with rollback on throw. | `SyncService`, `transactReplacement` | Verified |
| Which adjustments touch one session, a range, or the remaining plan | One session: Move a session, skip. A range: This week is heavy / I missed some training (`easeThisWeek`, the next 7 days), Pause (everything upcoming shifts; race day and tune-ups stay). Remaining plan: Ease the rest, Raise the load, Ease my paces, training days, session time, equipment, goal and race (rebuild from today; completed sessions never touched). The proposal sheet states the affected sessions and date span before Apply. | `PlanAdjustmentService.affected` | Verified (`PlanAdjustmentServiceTests`) |
| What Undo restores, and when it is invalid | Undo restores the whole plan state captured before Apply (session dates, statuses, targets, paces, run types, intervals, strength sets, pause, latches, the 5K seed, self-coached flag, athlete state) under the **same plan id**, and re-upserts the athlete-state sidecar. There is one undo point app-wide (`CoachUndo.makeSoleUndoPoint`): a later change from chat or Manage plan retires it. It is invalid, and the receipt says so, once the plan's signature has moved (a session completed, another change applied, a rebuild). | `CoachUndo.swift`, `ManagePlanView.receiptCard` | Verified |

### 8.2 Photo-logging decisions, resolved

| Question | Decision | Where | Status |
|---|---|---|---|
| Where photos and pending drafts live | The `Meal` row **is** the draft (`source == "pending"` until numbers land). The photo lives only in `Meal.photoData` (SwiftData external storage, a V1 slot). No files elsewhere, no cache directory. | `Models/Meal.swift` | Verified |
| Whether and how they sync | Meals never sync and photos never leave the device except inside one estimate request body. No Storage bucket, no meal table, no public URL. | `SyncService` (workouts only) | Verified |
| Authenticated upload and estimation contract | One call: `POST meal-estimate` with the Supabase bearer token, body `{ text, context { session, durationS }, image? { mime, base64 } }`. There is no upload step and nothing is stored server-side; the function validates, asks the model, validates the answer and returns it. | `FuelEstimator.requestBody`, `meal-estimate/validate.ts` | Verified (`FuelEstimatorTests`, `validate_test.ts`) |
| Maximum size and formats | Client: re-encoded JPEG, longest side ≤ 1280 px, ≤ 2.5 MB, no EXIF/GPS/device metadata (`MealPhoto`). Server: JPEG, PNG or WEBP by **magic bytes** (the declared type never outranks the bytes), ≤ 4 MB decoded, strict base64. | `MealPhoto.swift`, `validate.ts` | Verified |
| Retry and duplicate prevention | One row per log; every retry re-estimates that row (`retryPendingEstimates` scans the recent window, five at a time). `EstimateGate` tokens stop two paths billing the same meal; the attempt cap (3) bounds the cost of a meal the model keeps refusing; a request that never left is refunded. The server keys its daily limits on the caller, with a separate image limit (30/day, fail-closed). | `FuelView.estimate`, `EstimateGate`, `index.ts` | Verified |
| The app closes during estimation | The row is already saved; the in-flight task dies with the process. On the next appear the meal is still `pending` under the cap and is retried. A spent attempt whose answer never came back stays spent (bounded cost). | `FuelView.retryPendingEstimates` | Verified |
| A correction protected from a late response | `FuelEstimator.apply` refuses a meal whose `source == "manual"`; the `.rejected` branch now refuses it too (Fuel page and Siri lane). A late answer for a deleted meal is dropped by the `isDeleted` / `modelContext == nil` guards and the gate token. | `FuelEstimator.apply`, `FuelView.estimate`, `SiriMealLogger` | Verified (`FuelPhotoJournalTests`) |
| Cleanup after deletion or abandonment | Deleting the meal deletes its blob (external storage rides the row). An abandoned draft is simply a journal row that says so ("Couldn't estimate, tap to set the numbers", or the server's own refusal line); it never becomes confident nutrition and stops costing anything at the cap. | `MealNutritionStore.delete`, `Meal.rejectionNote` | Verified |
| Old app against the updated backend | The updated function accepts the text-only body byte-for-byte (`validate_test`: "text-only requests keep working exactly as before"); the response keeps every field the shipped decoder reads and adds only optional ones. | `validate.ts`, `FuelEstimator.Estimate` | Verified |
| New app against the old backend | A text+photo meal is estimated from its words (the old function ignores the `image` key); a photo-only meal is answered `400 empty` and lands on the honest fallback with its attempt spent. So: **deploy the function before build 44 ships**, and the window in between degrades to words, never to a wrong number. | §6 | Verified by reading; deploy owed |
| Backend-first or client-first | Backend first, because it is backward compatible and the client is not forward compatible for photo-only meals. | §6 | Decision |

### 8.3 Stage plans

Each stage below lists the eight items the brief asks for. "Reused" names existing code the
stage stands on; everything else was added this session.

#### Stage 1: Your plans (the shelf)
1. **Reused:** `PlanService.transactReplacement`, `stageRebuild`, `completeRace`, `renewBlock`; `CoachUndo.Snapshot.PlanState`; `SchemaVersions` sidecar pattern (`PlanAthleteStateRecord`); `PlanFeasibility`.
2. **Flows and states:** Plan masthead menu → Your plans (also the empty state). Sections: Current (Preview, Manage plan), Upcoming (Edit, Change start date, Start now, Move to drafts, Remove), Drafts (Edit, Schedule, Start now, Delete), Previous (Preview read-only, Start again as a draft, Remove). Empty shelf: the current card and Create a plan. Loading: none needed (local reads). Error: an alert with the service's own line; nothing half-applied. Cancellation: every sheet has Cancel; the overlap sheet's Cancel keeps the draft.
3. **Model and migration:** `PlanShelfRecord` under `SchemaV5`, lightweight stage from V4; `RunningSchemaMigrationSpikeTests` opens the archived build-36 store through V5.
4. **Services and contracts:** `PlanLifecycleService` (saveDraft, update, schedule, moveToDrafts, delete, startAgain, activate, activateDueUpcoming, retire, propagate); `PlanLifecycle` (pure rules: overlap, due, activation day, worth shelving, progress).
5. **Dependencies:** none upstream; Stages 2 and 3 open from it.
6. **Acceptance:** exactly one `TrainingPlan` row at all times; activation is one transaction with rollback; upcoming plans start on the day they come due and never backdate; a retired plan reviews with its sessions; two due at once resolve deterministically.
7. **Regression tests and visual checks:** `PlanLifecycleTests` (unit), `PlanShelfUITests.testShelfListsEveryStatusAndCreateOpensTheBuilder` (UI), light and dark screenshots of the shelf.
8. **Deployment and rollback:** app-only; the schema stage is additive. Rollback = ship without the sidecar table being read (records are ignored, nothing else changes).

#### Stage 2: Create a plan
1. **Reused:** `PlanEngine.generate` through `PlanService.stagePreview`; `PlanFeasibility.assess`; `RaceCatalog`; `OnboardingKit` cards.
2. **Flows and states:** Goal (four doors) → Target (race distance/date/time; distance for "get faster"; nothing for start/return and fitness) → Where you are (weekly volume, longest run, experience) → Your week (days, preferred days with the too-few-days gate, session minutes) → How to train (intensity, strength, equipment) → Preview (outlook, commitment, typical week, phases; "Working it out" while the debounced generator runs) → Start now / Schedule / Save as draft. Leaving with edits asks Save as draft / Discard / Keep editing. Overlap with the current plan opens the decision sheet.
3. **Model:** `PlanBlueprint` (Codable, tolerant decoder with defaults) and `PlanPreview` on the record; no new tables.
4. **Contracts:** `PlanLifecycleService.preview(for:profile:startDate:)` returns the same numbers `activate` will produce (same inputs overlay, same generator).
5. **Dependencies:** Stage 1.
6. **Acceptance:** the preview equals the activated plan; Start is free (like "Start a new plan"); a draft never starts on its own; an evening start lands tomorrow; a scheduled start after race day is refused with a plain line.
7. **Tests and checks:** `PlanLifecycleTests` (preview equality, evening start, undated distance, schedule bounds), `PlanShelfUITests.testBuilderSavesADraftThatSurvivesRelaunch` (persists after relaunch), builder screenshots.
8. **Deployment and rollback:** app-only.

#### Stage 3: Manage plan
1. **Reused:** `CoachActions` (24 intents, receipts), `PlanCoaching` (ease, pause, resume, move), `CoachUndo`, `InjuryReportSheet`, `PlanSettingsSheet`, `WorkoutLibrary`.
2. **Flows and states:** Plan masthead → Manage plan. My schedule (training days, session time, move a session, away days), My training (ease the rest, raise the load, ease paces, strength and equipment, library), Something changed (this week is heavy, missed training, pause/resume, unwell, something hurts), My goal (plan settings, next block now / rebuild from today, switch plans). Each row → proposal sheet: "Working out what changes" → what it touches (sessions and dates; completed never touched), before/after lines, why, race outlook, Apply / Cancel. Rows the plan cannot use right now say why in their subtitle instead of opening a dead sheet. Receipt with Undo; Undo retired with an explanation when the plan moved on.
3. **Model:** none; the one-structural-change-a-week latch (`lastAdaptedAt`) is honoured and explained before the tap.
4. **Contracts:** `PlanAdjustmentService` (`Request`, `Proposal`, `apply` → applied / declined / stale, `undo`, `signature(of:)`).
5. **Dependencies:** Stage 1 for "Switch plans".
6. **Acceptance:** every proposal is computed from the same generator as the plan; a stale proposal is recomputed, never applied blind; reading is free, applying is Pro (`.aiCoach`) and the paywall is hosted inside the sheet (`nestedPaywallHost`) so it never tears the sheet down; fixed-date sessions (race, tune-ups) never move.
7. **Tests and checks:** `PlanAdjustmentServiceTests`, `PlanShelfUITests.testManageProposalAppliesAndUndoes`, Manage and proposal screenshots.
8. **Deployment and rollback:** app-only.

#### Stage 4: Photo food logging
1. **Reused:** `FuelEstimator`, `EstimateGate`, `MealNutritionStore`, `ImageDownsampler`, `CameraPicker`, the `meal-estimate` function and its rate-limit RPC.
2. **Flows and states:** composer camera glyph → Take a photo (camera; denied → the library door and Settings; restricted → the library door only) / Choose a photo (library). Preparing (glyph spins, door shut) → the row lands at once with the thumbnail and "Photo of a meal" → estimating shimmer → numbers, or the server's refusal line (once, as the status line), or the offline fallback. "Couldn't add that photo" is the lane's own alert. Cancellation: dismissing either picker logs nothing.
3. **Model:** `Meal.photoData` (existing V1 slot), no migration.
4. **Contracts:** §8.2. Server validation of the answer: bounded items and numbers, unknown micros null, `not_food` / `unreadable` reasons for photos only, energy reconciled to macros, structured logs with counts only.
5. **Dependencies:** none in the app; the function deploy is the external dependency.
6. **Acceptance:** EXIF/GPS never leaves the device (`MealPhotoTests.preparedBytesCarryNoMetadata…`); retries never insert a second row; a manual correction outranks a late answer; a non-food photo never becomes confident nutrition; the server refuses what the client would refuse.
7. **Tests and checks:** `MealPhotoTests`, `FuelEstimatorTests`, `FuelPhotoJournalTests`, `validate_test.ts`, `FuelPhotoLaneUITests.testPhotoRowsAndTheComposerCameraDoor` (real lane on the simulator through `--fuel-photo-demo`), Fuel screenshots with photo rows.
8. **Deployment and rollback:** deploy the function first (§6). Rollback = redeploy the previous function; the client degrades to words for text+photo meals and to the honest fallback for photo-only meals.

#### Stage 5: Fuel dashboard
1. **Reused:** `FuelReadiness`, `FuelReadoutBuilder`, `FuelTips`, `FuelWeek`, `HealthScore`, the composer, `MealDetailSheet`, `FuelHistoryView`.
2. **Flows and states:** day strip (today ← 30 days; today's name is a heading, a past day's name is the way home; the page follows the calendar over midnight only while resting on today), energy hero ("—" with no meals), readout strip (today: Building / On track / Fueled; a past day: Unlogged / Light day / Near the floor / Fueled; no tips and no refuel banner on a past day), three macro rings, fluids and sodium line, composer, Add nutrition, empty-day card, usuals, the journal with thumbnails. Daily nutrition and Water open on the selected day.
3. **Model:** none.
4. **Contracts:** `FuelReadoutBuilder.readout(meals:plan:workouts:profile:water:now:)` now also keys the carb tier to the day's completed run.
5. **Dependencies:** Stage 4 for the photo rows.
6. **Acceptance:** floors never ceilings, no over-budget or punitive state; a past day is judged as final by the same engine; logging on a past day lands on that day (noon); nothing on the page runs an engine in `body` (cache + memo).
7. **Tests and checks:** `FuelPhotoJournalTests.theBuilderKeepsTheDaysRunInTheCarbTier`, `FuelFlowUITests`, `FuelPhotoLaneUITests.testDayStripStepsBackAndHome`, light and dark screenshots.
8. **Deployment and rollback:** app-only.

### 8.4 Definition of Done, per stage (recorded validation)

The evidence column is filled in §7 as each run lands; a successful build alone is never counted.

| Stage | Main flow end to end | Empty / loading / offline / error / cancel | Persists after relaunch | Existing data intact | Tests | Screenshots | No placeholder control | External deps recorded |
|---|---|---|---|---|---|---|---|---|
| 1 Your plans | `PlanShelfUITests` (1) | shelf empty state; alerts; Cancel on every sheet | SwiftData; UI test 2 relaunches | V4→V5 lightweight; archived-store test | `PlanLifecycleTests` | light + dark | yes | none |
| 2 Create | `PlanShelfUITests` (2) | "Working it out"; preview nil disables Start; discard dialog | draft survives relaunch (UI test 2) | current plan untouched by a draft | `PlanLifecycleTests` | builder steps | yes | none |
| 3 Manage | `PlanShelfUITests` (3) | "Working out what changes"; unavailable rows explain; stale recompute | receipts are transient by design; the plan change persists | completed sessions never touched | `PlanAdjustmentServiceTests` | manage + proposal | yes | Pro entitlement to apply |
| 4 Photo | `FuelPhotoLaneUITests` (1) | preparing; offline fallback; refusal line; "Couldn't add that photo"; picker cancel | the row and its photo persist | text-only journal unchanged | `MealPhotoTests`, `FuelEstimatorTests`, `FuelPhotoJournalTests`, `validate_test.ts` | photo rows | yes | **function deploy** |
| 5 Dashboard | `FuelFlowUITests`, `FuelPhotoLaneUITests` (2) | empty day (today and past); past-day words | selected day is session state by design | meals and water untouched | `FuelReadinessTests`, `FuelPhotoJournalTests` | light + dark | yes | none |

### 8.5 Requirements checklist

| Capability (brief) | Implemented in | Verification | Remaining dependency |
|---|---|---|---|
| Your Plans: current / upcoming / draft / completed / incomplete | `YourPlansView`, `PlanShelfRecord`, `PlanLifecycle` | `PlanLifecycleTests`, `PlanShelfUITests` (1) | none |
| Create, preview, save draft, edit, schedule, switch, previous, remove | `PlanBuilderFlow`, `YourPlansView` menus, `PlanLifecycleService` | `PlanLifecycleTests`, `PlanShelfUITests` (1, 2) | none |
| Plan creation for existing users (goal → date/distance/time → fitness → availability → preferences → feasibility/preview → save/schedule/activate) | `PlanBuilderFlow`, `PlanReviewView`, `PlanLifecycleService.preview/feasibility` | `PlanShelfUITests` (2), builder screenshots | none |
| Discoverable Manage Plan with the four groups | `ManagePlanView` (masthead menu entry) | `PlanShelfUITests` (3), screenshots | none |
| Proposals: affected dates, before/after, explanation, feasibility, Apply / Cancel / Undo | `PlanProposalSheet`, `PlanAdjustmentService` | `PlanAdjustmentServiceTests`, `PlanShelfUITests` (3) | Pro to apply |
| One structural change a week honoured | `lastAdaptedAt` latch, unavailable-row subtitles | `PlanAdjustmentServiceTests` (throttle survives rebuild) | none |
| Photo → meal: client + server contract + persistence + failure states | `MealPhoto`, `FuelEstimator`, `FuelView` photo lane, `validate.ts`, `index.ts` | unit + Deno tests, `FuelPhotoLaneUITests` (1) | deploy `meal-estimate` before build 44 |
| EXIF stripped, no public URLs, idempotent retries, manual outranks late AI, non-food never confident, server validates | as above | `MealPhotoTests`, `FuelPhotoJournalTests`, `validate_test.ts` | none |
| Fuel dashboard: date nav, energy, macros, training context, meals with photos, recents; floors never ceilings; no punitive states | `FuelView` | `FuelFlowUITests`, `FuelPhotoLaneUITests` (2), screenshots | none |
| Persisted plan/progress document | this file | — | none |

**Assumed, not proven:** vision quality of the deployed model on real plates (only the contract and validator are tested); `UIImage` capture on a physical camera (the simulator has none); the Watch receiving a plan switch push; the App Store build (44) has not been made.

## 7. Progress log
- 2026-09-07 — audit complete, document written; Stages 1–5 landed; unit suite green at 2,142.
- 2026-09-07 (later) — hardening pass: seven review agents, fixes across lifecycle, Manage plan, Your plans, builder, the photo lane, the Fuel dashboard and the edge function; §8 planning gate written; 34 regression tests added (`PlanLifecycleTests` +13, `PlanAdjustmentServiceTests` +11, `FuelPhotoJournalTests` 9, `FuelEstimatorTests` +1); unit target green at **2,176 tests, 243 suites, 0 failures** (one pre-existing skip); Deno 17 passing; new UI suites `PlanShelfUITests` (3) and `FuelPhotoLaneUITests` (2); screenshots re-taken (Fuel light and dark with photo rows, Your plans, Manage, builder). Root causes worth naming: a deferred widget publish read the profile after its container was gone (trapped the whole unit run once, now guarded); the Manage signature hashed a to-many relationship in fetch order (undo retired itself the moment the sheet closed); FuelView and PlanView bodies both crossed the type-checker budget (presenters moved into `.background` hosts).
- 2026-09-07 (evening) — polish pass for the refinement build: four review agents over the shelf, the builder, Manage plan, the Fuel page and the seams. Fixed: sheet handoffs now sequence through `onDismiss` (a same-tick swap could leave a shelf flag stuck); Cancel on an edited draft asks first; an upcoming plan previews and saves for its scheduled day; a failed Schedule no longer mints a second draft; "lighten this week" cannot stack; a pause never pushes a session past race day; throttles count calendar days; undo removes a restored plan's ghost shelf record and lifecycle events retire the chat's undo point; a failed rebuild is declined rather than receipted; Manage's receipt outlives the sheet; proposals compute after the sheet lands and re-apply after a purchase; the Fuel page re-judges on every return to the tab, re-anchors the day on rollover, keeps the mic off after a permission prompt, counts photo jobs from the pick, and speaks a row's numbers to VoiceOver; hit targets are 44 pt; chip rows wrap; coach copy on Fuel and the injury sheet lost its dashes. Tests: `PlanPolishRegressionTests` (5); unit target **2,181 tests, 244 suites, 0 failures**.
